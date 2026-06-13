// §2 Strain — Banister TRIMP over HR reserve, log-scaled to 0..21. Tier HIGH.
import type { Minute, Baseline, Profile, Metric, StrainValue } from './types';
import { isHrUsable, resolveMaxHr, clamp, round } from './util';

/**
 * calcStrain(minutes, baseline, profile?)
 *
 * Per worn minute with hr_avg>0:
 *   ratio = clamp((hr_avg − RHR)/(maxHR − RHR), 0, 1)
 *   trimp += ratio * k * e^(b*ratio)
 * where (k,b) are Banister's sex-specific weights: men (0.64, 1.92), women
 *   (0.86, 1.67). Sex unknown → men's weights (the classic default; keeps prior
 *   behaviour for sex-less profiles).
 * score = min(21, log(trimp+1)/log(1.5)), rounded to 0.01.
 * maxHR = measured session max if available else 220−age (see resolveMaxHr).
 *
 * Confidence formula: clamp(worn_min / 30, 0, 1)
 *   (coverage proxy: 1.0 once ≥30 worn minutes are present; degrades linearly).
 */
export function calcStrain(
  minutes: Minute[],
  baseline: Baseline,
  profile?: Profile
): Metric<StrainValue> {
  const { maxHr, source } = resolveMaxHr(minutes, baseline, profile);
  const rhr = baseline.resting_hr;
  const worn = minutes.filter(isHrUsable);

  // Banister TRIMP weights: women (0.86, 1.67), men / unknown (0.64, 1.92).
  const [k, b] = profile?.sex === 'f' ? [0.86, 1.67] : [0.64, 1.92];
  let trimp = 0;
  const denom = maxHr - rhr;
  for (const m of worn) {
    if (denom <= 0) continue;
    const ratio = clamp((m.hr_avg - rhr) / denom, 0, 1);
    trimp += ratio * k * Math.exp(b * ratio);
  }

  const score = Math.min(21, Math.log(trimp + 1) / Math.log(1.5));
  const confidence = clamp(worn.length / 30, 0, 1);

  const inputs_used = ['hr_avg', 'baseline.resting_hr'];
  inputs_used.push(source === 'measured' ? 'baseline.max_hr' : 'profile.age');

  return {
    score: round(score, 2),
    trimp: round(trimp, 4),
    max_hr_used: maxHr,
    max_hr_source: source,
    confidence: round(confidence, 4),
    tier: 'HIGH',
    inputs_used,
  };
}
