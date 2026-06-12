// §4 Active Calories — Keytel kcal/min over HR-elevated minutes, sex-averaged
// when unknown. Tier ESTIMATE. This is ACTIVE energy expenditure (HR-driven),
// NOT total daily expenditure (no BMR/RMR term) — surfaced as "active calories".
import type { Minute, Profile, Metric, CaloriesValue } from './types';
import { isHrUsable, round } from './util';

/**
 * calcCalories(minutes, profile)
 *
 * Keytel et al. (2005) HR-based energy expenditure, kcal/min:
 *   male   = (−55.0969 + 0.6309*hr + 0.1988*w + 0.2017*age)/4.184
 *   female = (−20.4022 + 0.4472*hr − 0.1263*w + 0.0740*age)/4.184
 * Use sex if present, else the mean of male & female. Sum max(0, kcal/min) over
 * worn minutes (per-minute rollups → ×1, no /60). ALWAYS labeled "(est.)".
 *
 * Confidence formula: 0.5 base (wrist HR + no/uncertain sex), scaled by
 *   input_completeness = (#known of {age,weight,sex})/3 clamped to ≥0.5×base floor.
 *   With nothing known, confidence stays 0.5 × coverage. Spec pins base 0.5.
 */
export function calcCalories(
  minutes: Minute[],
  profile: Profile
): Metric<CaloriesValue> {
  const worn = minutes.filter(isHrUsable);
  const age = profile.age ?? 30; // population default ONLY for the formula term
  const w = profile.weight_kg ?? 70; // population default weight

  let kcal = 0;
  for (const m of worn) {
    const hr = m.hr_avg;
    const male = (-55.0969 + 0.6309 * hr + 0.1988 * w + 0.2017 * age) / 4.184;
    const female = (-20.4022 + 0.4472 * hr - 0.1263 * w + 0.074 * age) / 4.184;
    let perMin: number;
    if (profile.sex === 'm') perMin = male;
    else if (profile.sex === 'f') perMin = female;
    else perMin = (male + female) / 2;
    kcal += Math.max(0, perMin);
  }

  const inputs_used = ['hr_avg'];
  if (profile.age != null) inputs_used.push('profile.age');
  if (profile.weight_kg != null) inputs_used.push('profile.weight_kg');
  if (profile.sex != null) inputs_used.push('profile.sex');

  // Spec fixes base at 0.5. Scale by coverage so a near-empty day isn't 0.5.
  const coverage = Math.min(1, worn.length / 30);
  const confidence = 0.5 * coverage;

  return {
    kcal: round(kcal, 1),
    label: '≈ active kcal (est.)',
    confidence: round(confidence, 4),
    tier: 'ESTIMATE',
    inputs_used,
  };
}
