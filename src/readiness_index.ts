// §Composite Readiness — a transparent, weighted blend of the autonomic + sleep
// signals we already compute. NOT a black box and NOT claiming to be WHOOP's score:
// it's an honest aggregate that abstains until HRV-recovery exists, and ships its
// component breakdown as drivers so the user sees exactly what moved it.
import type { Metric, ReadinessIndexValue, Driver } from './types';
import { clamp, round } from './util';

export interface ReadinessInputs {
  recovery: number | null;       // 0..100 — Plews HRV recovery (the anchor)
  sleepDurationMin: number | null;
  sleepNeedMin: number | null;
  dipPct: number | null;         // nocturnal HR dip, fraction (0.10 = 10%)
  sleepStress: number | null;    // 0..100 nocturnal arousal load (higher = worse)
}

// Weights (sum 1) over whatever components are present; recovery anchors it.
const W = { recovery: 0.5, sleep: 0.2, dip: 0.15, arousal: 0.15 };

/**
 * calcReadinessIndex — weighted mean of the available components, renormalized
 * over present weights. Abstains (score=null) if HRV-recovery is absent, because
 * without the autonomic anchor the rest is just sleep accounting.
 */
export function calcReadinessIndex(inp: ReadinessInputs): Metric<ReadinessIndexValue> {
  const components = {
    recovery: inp.recovery,
    sleep: (inp.sleepDurationMin != null && inp.sleepNeedMin && inp.sleepNeedMin > 0)
      ? round(clamp((inp.sleepDurationMin / inp.sleepNeedMin) * 100, 0, 100), 0) : null,
    // A nocturnal dip of ~10%+ is healthy → map 0..0.10 onto 0..100.
    dip: inp.dipPct != null ? round(clamp((inp.dipPct / 0.10) * 100, 0, 100), 0) : null,
    // Arousal is "worse when higher" → invert to a 0..100 calmness score.
    arousal: inp.sleepStress != null ? round(clamp(100 - inp.sleepStress, 0, 100), 0) : null,
  };

  if (components.recovery == null) {
    return {
      score: null, components,
      note: 'Building baseline — needs nocturnal HRV',
      confidence: 0, tier: 'ESTIMATE', inputs_used: [],
    };
  }

  let wsum = 0, acc = 0;
  const used: string[] = [];
  const drivers: Driver[] = [];
  const add = (key: keyof typeof components, w: number, label: string) => {
    const v = components[key];
    if (v == null) return;
    wsum += w; acc += w * v; used.push(key);
    drivers.push({
      label,
      contribution: round((w * (v - 50)) / 50, 3), // signed vs neutral 50
      detail: `${v}/100`,
      ref: { metric: key === 'recovery' ? 'recovery' : key === 'sleep' ? 'sleep' : 'hrv', scale: 'day' },
    });
  };
  add('recovery', W.recovery, 'HRV recovery');
  add('sleep', W.sleep, 'Sleep vs need');
  add('dip', W.dip, 'Nocturnal HR dip');
  add('arousal', W.arousal, 'Sleep calmness');

  const score = wsum > 0 ? Math.round(acc / wsum) : null;
  drivers.sort((a, b) => Math.abs(b.contribution) - Math.abs(a.contribution));

  return {
    score,
    components,
    note: 'Composite (HRV + sleep) — a guide, not a diagnosis',
    confidence: round(clamp(wsum, 0, 1), 3),
    tier: 'ESTIMATE',
    inputs_used: used,
    drivers,
  };
}
