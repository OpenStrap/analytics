// §14 Notification engine — deterministic (NO AI) per-user nudges derived from
// the SAME signals the coach/alerts already compute. The server generates them;
// the client pulls + presents them (local notifications + in-app inbox). This
// keeps ALL intelligence server-side and avoids any closed push dependency.
//
// Each notification is idempotent by id = `${date}:${kind}` so regenerating a day
// converges (no duplicates). The engine is honest — it only fires on real signals
// and inherits the "signal, not a diagnosis" framing for health cues.

export interface NotifyInputs {
  date: string; // YYYY-MM-DD
  readiness: number | null;
  coach_summary: string;
  coach_top: { title: string; body: string } | null;
  body_alert: { kind: string; note: string } | null;
  stress_score: number | null;
  nocturnal_elevated: boolean;
  sleep_debt_min: number;
  acwr: number | null;
  strain_today: number | null;
  strain_target_low: number | null;
  strain_target_high: number | null;
  // Optional engagement inputs (from records/streaks); empty when not supplied.
  streaks?: { wear?: number; strain_target?: number; sleep?: number };
  new_records?: string[]; // human labels of PRs set on this date
}

export type NotifyCategory = 'recovery' | 'sleep' | 'load' | 'health' | 'activity' | 'milestone';
export type NotifyWindow = 'morning' | 'midday' | 'evening' | 'any';

export interface AppNotification {
  id: string;            // `${date}:${kind}` — stable, idempotent
  kind: string;
  category: NotifyCategory;
  priority: number;      // 0 (fyi) .. 3 (urgent)
  title: string;
  body: string;
  window: NotifyWindow;  // preferred delivery window
  quiet_ok: boolean;     // safe to deliver during quiet hours (e.g. overnight)
}

const MILESTONES = new Set([3, 7, 14, 21, 30, 50, 75, 100, 150, 200, 365]);
const MAX_NOTIFICATIONS = 6;

const hm = (min: number): string => {
  const m = Math.max(0, Math.round(min));
  const h = Math.floor(m / 60), r = m % 60;
  if (h === 0) return `${r}m`;
  if (r === 0) return `${h}h`;
  return `${h}h ${r}m`;
};

/**
 * buildNotifications(inputs) — deterministic ranked list (≤6) for one day.
 * Pure: same inputs → identical output. Ordered by priority desc, then a fixed
 * kind order so ties are stable.
 */
export function buildNotifications(i: NotifyInputs): AppNotification[] {
  const out: AppNotification[] = [];
  const push = (n: Omit<AppNotification, 'id'>) =>
    out.push({ id: `${i.date}:${n.kind}`, ...n });

  // 1. Health signal (illness / overtraining / elevated overnight HR) — highest.
  if (i.body_alert) {
    const k = i.body_alert.kind;
    const title = k === 'overtraining' ? 'High training load'
      : k === 'both' ? 'Recovery + load signal'
      : 'Recovery signal';
    push({
      kind: 'body_alert', category: 'health', priority: 3, window: 'morning',
      quiet_ok: false, title, body: i.body_alert.note,
    });
  } else if (i.nocturnal_elevated) {
    // Standalone overnight-HR cue (when not already folded into body_alert).
    push({
      kind: 'overnight_hr', category: 'health', priority: 3, window: 'morning',
      quiet_ok: false, title: 'Overnight heart rate was high',
      body: 'Your sleeping heart rate ran above your baseline — often an early cue of '
        + 'under-recovery or fighting something off. Consider an easier day. A signal, not a diagnosis.',
    });
  }

  // 2. New personal records (celebrate) — high engagement value.
  for (const label of i.new_records ?? []) {
    push({
      kind: `record_${label.toLowerCase().replace(/[^a-z0-9]+/g, '_')}`,
      category: 'milestone', priority: 2, window: 'any', quiet_ok: false,
      title: 'New personal record 🎉', body: `${label} — a new best. Nice work.`,
    });
  }

  // 3. Morning readiness + today's plan.
  if (i.readiness != null) {
    const r = Math.round(i.readiness);
    const tip = i.coach_top
      ? `${i.coach_top.title}: ${i.coach_top.body}`
      : (i.coach_summary || 'Carry on with your day.');
    push({
      kind: 'morning_readiness', category: 'recovery', priority: 1, window: 'morning',
      quiet_ok: false, title: `Recovery ${r}/100`, body: tip,
    });
  }

  // 4. Sleep debt nudge (evening).
  if (i.sleep_debt_min >= 120) {
    push({
      kind: 'sleep_debt', category: 'sleep', priority: 2, window: 'evening',
      quiet_ok: false,
      title: `You're carrying ${hm(i.sleep_debt_min)} of sleep debt`,
      body: 'An earlier night would help you pay it down. Aim to wind down soon.',
    });
  }

  // 5. High-arousal day (evening wind-down).
  if (i.stress_score != null && i.stress_score >= 70) {
    push({
      kind: 'high_stress', category: 'health', priority: 1, window: 'evening',
      quiet_ok: false, title: 'A high-arousal day',
      body: `Stress read ${Math.round(i.stress_score)}/100 — some downtime or slow breathing tonight could help you settle.`,
    });
  }

  // 6. Strain target progress (midday) — only when we have room to push or are close.
  if (i.strain_target_low != null && i.strain_today != null) {
    if (i.strain_today < i.strain_target_low - 1) {
      push({
        kind: 'strain_room', category: 'activity', priority: 0, window: 'midday',
        quiet_ok: false, title: 'Room to move today',
        body: `You're at ${i.strain_today.toFixed(1)} — your target is around ${i.strain_target_low.toFixed(0)}–${(i.strain_target_high ?? i.strain_target_low).toFixed(0)}.`,
      });
    }
  }

  // 7. Streak milestones (celebrate at meaningful counts).
  const s = i.streaks ?? {};
  if (s.wear && MILESTONES.has(s.wear)) {
    push({
      kind: 'streak_wear', category: 'milestone', priority: 1, window: 'any',
      quiet_ok: false, title: `${s.wear}-day wear streak 🔥`,
      body: `You've worn your strap ${s.wear} days running. Consistency is the whole game.`,
    });
  }
  if (s.strain_target && MILESTONES.has(s.strain_target)) {
    push({
      kind: 'streak_strain', category: 'milestone', priority: 1, window: 'any',
      quiet_ok: false, title: `${s.strain_target} days on target 🔥`,
      body: `You've hit your strain target ${s.strain_target} days in a row.`,
    });
  }

  // Rank: priority desc, then a stable kind order (insertion order as tiebreak).
  const order = new Map(out.map((n, idx) => [n.id, idx]));
  out.sort((a, b) => b.priority - a.priority || order.get(a.id)! - order.get(b.id)!);
  return out.slice(0, MAX_NOTIFICATIONS);
}
