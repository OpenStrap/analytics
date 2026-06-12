// coach.ts — deterministic coaching engine. NO AI: pure math + rules.
// Turns a day's physiological state into a ranked, EXPLAINABLE "what to do"
// plan, a recommended strain target, a readiness-contributor decomposition,
// and a one-line narrative. Every suggestion carries the math that fired it
// (`why`) so the UI can show *why*, honouring the project's honesty contract.

import { clamp, round } from './util';

export interface CoachInputs {
  readiness: number | null; // 0..100 (est.)
  readiness_components?: { rhr: number; sleep_debt: number; sleep_quality: number } | null; // 0..1 each
  resting_hr: number | null; // today
  baseline_rhr: number | null;
  rhr_recent: number[]; // recent daily RHRs, most-recent LAST (for z-score)
  strain_today: number | null; // 0..21
  acwr: number | null; // acute:chronic load ratio
  sleep_last_min: number | null; // last night asleep minutes
  sleep_need_min: number; // baseline need (already plausibility-floored upstream)
  sleep_debt_min: number; // cumulative debt over recent real nights (≥0)
  sleep_efficiency: number | null; // 0..1
  sri: number | null; // sleep regularity 0..100
  fitness_direction: string | null; // 'rising' | 'flat' | 'declining' | ...
  anomaly: { signal: boolean; kind?: string; note?: string } | null;
}

export interface Why { label: string; value: string; detail?: string }
export interface Suggestion {
  id: string;
  category: 'recovery' | 'sleep' | 'load' | 'health' | 'activity';
  title: string;
  body: string;
  severity: number; // 0 info … 3 urgent — drives ordering + colour
  why: Why[];
  target?: string;
}
export interface Contributor {
  key: string;
  label: string;
  value: number | null;
  baseline: number | null;
  impact: number; // signed points contributed to the 0..100 readiness score
  note: string;
}
export interface CoachOutput {
  strain_target: { value: number; low: number; high: number; rationale: string } | null;
  plan: Suggestion[];
  readiness_contributors: Contributor[];
  summary: string;
}

const mean = (xs: number[]) => xs.reduce((s, v) => s + v, 0) / xs.length;
const std = (xs: number[]) => {
  if (xs.length < 2) return 0;
  const m = mean(xs);
  return Math.sqrt(xs.reduce((s, v) => s + (v - m) ** 2, 0) / xs.length);
};
const hm = (min: number) => `${Math.floor(min / 60)}h ${Math.round(min % 60)}m`;

/** Recommended strain target from readiness, capped by load + health flags. */
function strainTarget(i: CoachInputs): CoachOutput['strain_target'] {
  if (i.readiness == null) return null;
  let base = 6 + (clamp(i.readiness, 0, 100) / 100) * 12; // readiness 0→6, 100→18
  const reasons: string[] = [`recovery ${Math.round(i.readiness)}`];
  if (i.acwr != null && i.acwr > 1.3) {
    base = Math.min(base, 10);
    reasons.push(`load high (ACWR ${i.acwr.toFixed(2)})`);
  }
  if (i.anomaly?.signal) {
    base = Math.min(base, 8);
    reasons.push('body-strain signal');
  }
  const v = round(base, 1);
  return {
    value: v,
    low: round(Math.max(0, v - 2), 1),
    high: round(Math.min(21, v + 2), 1),
    rationale: reasons.join(' · '),
  };
}

/** Decompose the readiness score into signed point contributions. */
function contributors(i: CoachInputs): Contributor[] {
  const c = i.readiness_components;
  if (!c) return [];
  // Renormalize the published weights across present components.
  const W = { rhr: 0.5, sleep_debt: 0.3, sleep_quality: 0.2 };
  const wSum = W.rhr + W.sleep_debt + W.sleep_quality;
  // Each component's "lost points" = weight*100*(1 - component). Impact is the
  // signed deviation from a neutral (all-perfect) contribution.
  const pts = (w: number, comp: number) => round(-((w / wSum) * 100 * (1 - comp)), 1);
  const note = (comp: number, good: string, bad: string) =>
    comp >= 0.85 ? good : bad;
  return [
    {
      key: 'rhr',
      label: 'Resting HR',
      value: i.resting_hr,
      baseline: i.baseline_rhr,
      impact: pts(W.rhr, c.rhr),
      note: note(c.rhr, 'at/below baseline — supporting recovery',
        'elevated vs baseline — dragging recovery down'),
    },
    {
      key: 'sleep_debt',
      label: 'Sleep duration',
      value: i.sleep_last_min,
      baseline: i.sleep_need_min,
      impact: pts(W.sleep_debt, c.sleep_debt),
      note: note(c.sleep_debt, 'met your sleep need',
        'short vs your need — costing recovery'),
    },
    {
      key: 'sleep_quality',
      label: 'Sleep quality',
      value: i.sleep_efficiency == null ? null : round(i.sleep_efficiency * 100, 0),
      baseline: null,
      impact: pts(W.sleep_quality, c.sleep_quality),
      note: note(c.sleep_quality, 'efficient + consistent',
        'fragmented or irregular'),
    },
  ];
}

/** The rule library. Each returns a Suggestion or null. Order-independent. */
function rules(i: CoachInputs): Suggestion[] {
  const out: (Suggestion | null)[] = [];
  const tgt = strainTarget(i);
  const recovery = i.readiness;
  const acwrHigh = i.acwr != null && i.acwr > 1.3;
  const acwrLow = i.acwr != null && i.acwr < 0.8;

  // RHR z-score (today vs recent).
  let rhrZ: number | null = null;
  if (i.rhr_recent.length >= 3 && i.resting_hr != null) {
    const prior = i.rhr_recent.slice(0, -1);
    const s = std(prior);
    if (s > 0) rhrZ = (i.resting_hr - mean(prior)) / s;
  }

  // ── HEALTH ──
  if (i.anomaly?.signal) {
    out.push({
      id: 'health.anomaly',
      category: 'health',
      title: i.anomaly.kind === 'overtraining' ? 'Back off — high load' : 'Recovery flag',
      body: i.anomaly.note ||
        'Your body is showing strain signals. Prioritise rest, hydration and easy movement today. A signal, not a diagnosis.',
      severity: 3,
      why: [
        ...(i.resting_hr != null && i.baseline_rhr != null
          ? [{ label: 'Resting HR', value: `${Math.round(i.resting_hr)} bpm`, detail: `baseline ${Math.round(i.baseline_rhr)}` }] : []),
        ...(i.acwr != null ? [{ label: 'Load (ACWR)', value: i.acwr.toFixed(2) }] : []),
      ],
      target: tgt ? `Keep strain ≤ ${tgt.high}` : undefined,
    });
  }

  // ── LOAD ──
  if (acwrHigh && !i.anomaly?.signal) {
    out.push({
      id: 'load.high',
      category: 'load',
      title: 'Ease off the gas',
      body: `Your acute training load is well above your 28-day baseline. Stack an easy or rest day to let it settle before pushing again.`,
      severity: 2,
      why: [{ label: 'Load (ACWR)', value: i.acwr!.toFixed(2), detail: 'optimal 0.8–1.3' }],
      target: tgt ? `Target strain ${tgt.low}–${tgt.value}` : undefined,
    });
  }
  if (acwrLow && (recovery == null || recovery >= 55)) {
    out.push({
      id: 'load.low',
      category: 'activity',
      title: 'Room to push',
      body: `You're fresh and your recent load is light. A solid session today moves your fitness forward without overreaching.`,
      severity: 1,
      why: [{ label: 'Load (ACWR)', value: i.acwr!.toFixed(2), detail: '< 0.8 = detraining zone' }],
      target: tgt ? `Aim for strain ${tgt.value}–${tgt.high}` : undefined,
    });
  }

  // ── RECOVERY ──
  if (recovery != null && recovery < 40 && !i.anomaly?.signal) {
    out.push({
      id: 'recovery.low',
      category: 'recovery',
      title: 'Take it easy today',
      body: `Recovery is low. Favour light movement, mobility or a walk over hard training, and protect tonight's sleep.`,
      severity: 2,
      why: [{ label: 'Recovery', value: `${Math.round(recovery)}`, detail: '(est.) — not HRV-based' }],
      target: tgt ? `Keep strain ≤ ${tgt.value}` : undefined,
    });
  }
  if (recovery != null && recovery >= 70 && !acwrHigh && !i.anomaly?.signal) {
    out.push({
      id: 'recovery.high',
      category: 'activity',
      title: 'Green light',
      body: `Recovery is strong — your body's ready for a harder effort if you want it.`,
      severity: 0,
      why: [{ label: 'Recovery', value: `${Math.round(recovery)}` }],
      target: tgt ? `You can target strain up to ${tgt.high}` : undefined,
    });
  }
  if (rhrZ != null && rhrZ > 1.5 && !i.anomaly?.signal) {
    out.push({
      id: 'recovery.rhr_spike',
      category: 'recovery',
      title: 'Resting HR is up',
      body: `Your resting HR is notably above your recent norm — often a sign of incomplete recovery, stress, alcohol or oncoming illness. Keep today gentle.`,
      severity: 2,
      why: [{ label: 'Resting HR', value: `${Math.round(i.resting_hr!)} bpm`, detail: `+${rhrZ.toFixed(1)}σ vs recent` }],
    });
  }

  // ── SLEEP ──
  if (i.sleep_debt_min >= 90) {
    const earlier = Math.min(90, Math.round(i.sleep_debt_min / 3 / 5) * 5);
    out.push({
      id: 'sleep.debt',
      category: 'sleep',
      title: 'Pay down sleep debt',
      body: `You're carrying about ${hm(i.sleep_debt_min)} of sleep debt. Going to bed ~${earlier} min earlier tonight will start closing the gap.`,
      severity: 2,
      why: [{ label: 'Sleep debt', value: hm(i.sleep_debt_min), detail: `need ${hm(i.sleep_need_min)}/night` }],
    });
  }
  if (i.sri != null && i.sri < 70) {
    out.push({
      id: 'sleep.consistency',
      category: 'sleep',
      title: 'Anchor your sleep timing',
      body: `Your sleep schedule is inconsistent. Going to bed and waking within the same ~30-min window — even on weekends — is one of the biggest levers on recovery.`,
      severity: 1,
      why: [{ label: 'Sleep regularity', value: `${Math.round(i.sri)}/100`, detail: 'higher = steadier' }],
    });
  }
  if (i.sleep_last_min != null && i.sleep_efficiency != null && i.sleep_efficiency < 0.8 && i.sleep_last_min > 120) {
    out.push({
      id: 'sleep.efficiency',
      category: 'sleep',
      title: 'Restless night',
      body: `You spent a good chunk of last night awake in bed. A cooler, darker room and no screens before bed usually lift efficiency.`,
      severity: 1,
      why: [{ label: 'Sleep efficiency', value: `${Math.round(i.sleep_efficiency * 100)}%`, detail: 'target ≥ 85%' }],
    });
  }

  return out.filter((s): s is Suggestion => s != null);
}

/** Deterministic one-line narrative built from the dominant signals. */
function narrative(i: CoachInputs): string {
  const parts: string[] = [];
  if (i.readiness != null) {
    const w = i.readiness >= 70 ? 'Strong' : i.readiness >= 40 ? 'Moderate' : 'Low';
    parts.push(`${w} recovery`);
  }
  if (i.sleep_last_min != null && i.sleep_last_min > 0) parts.push(`slept ${hm(i.sleep_last_min)}`);
  if (i.acwr != null) {
    const w = i.acwr > 1.3 ? 'high load' : i.acwr < 0.8 ? 'light load' : 'balanced load';
    parts.push(w);
  }
  return parts.length ? parts.join(' · ') : 'Wear your strap and sync to see your daily read.';
}

export function buildCoach(i: CoachInputs): CoachOutput {
  const plan = rules(i)
    .sort((a, b) => b.severity - a.severity)
    .slice(0, 5);
  return {
    strain_target: strainTarget(i),
    plan,
    readiness_contributors: contributors(i),
    summary: narrative(i),
  };
}
