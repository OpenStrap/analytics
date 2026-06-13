// §4 Active Calories — Keytel kcal/min ABOVE resting, sex-averaged when unknown.
// Tier ESTIMATE. This is ACTIVE energy expenditure (the HR-driven burn over and
// above the resting metabolic baseline) — NOT total daily expenditure. We subtract
// the resting-HR Keytel value per minute so quiet/sleep minutes contribute ≈0;
// without this subtraction Keytel's large weight/age constant stays positive even
// at rest and balloons a full-wear day to thousands of "active" kcal.
import type { Minute, Profile, Metric, CaloriesValue } from './types';
import { isHrUsable, percentile, round } from './util';

/**
 * calcCalories(minutes, profile, restingHr?)
 *
 * Keytel et al. (2005) HR→energy, kcal/min:
 *   male   = (−55.0969 + 0.6309*hr + 0.1988*w + 0.2017*age)/4.184
 *   female = (−20.4022 + 0.4472*hr − 0.1263*w + 0.0740*age)/4.184
 * Use sex if present, else the mean of male & female. ACTIVE kcal/min =
 *   max(0, perMin(hr) − perMin(restingHr)); summed over worn minutes (per-minute
 *   rollups → ×1). `restingHr` should be the user's baseline RHR; if absent we use
 *   the worn-HR 5th percentile as the resting floor. ALWAYS labeled "(est.)".
 *
 * Confidence formula: 0.5 base, scaled by coverage (worn_min/30 clamped).
 */
export function calcCalories(
  minutes: Minute[],
  profile: Profile,
  restingHr?: number,
  maxHr?: number
): Metric<CaloriesValue> {
  const worn = minutes.filter(isHrUsable);
  const age = profile.age ?? 30; // population default ONLY for the formula term
  const w = profile.weight_kg ?? 70; // population default weight

  const perMin = (hr: number): number => {
    const male = (-55.0969 + 0.6309 * hr + 0.1988 * w + 0.2017 * age) / 4.184;
    const female = (-20.4022 + 0.4472 * hr - 0.1263 * w + 0.074 * age) / 4.184;
    if (profile.sex === 'm') return male;
    if (profile.sex === 'f') return female;
    return (male + female) / 2;
  };

  // Resting reference: the user's RHR (preferred) or the worn-HR 5th percentile.
  const restRef = (restingHr != null && restingHr > 0)
    ? restingHr
    : (percentile(worn.map((m) => m.hr_avg), 5) ?? 50);
  const restPerMin = perMin(restRef);

  // Activity gate: Keytel's HR→kcal slope is calibrated for EXERCISE; applied to
  // all-day low-grade elevation (sitting at 75 bpm) it over-counts badly. Only
  // accrue active calories once HR is genuinely in an active zone — Zone 1 onset
  // = 50% of max HR (matches calcHrZones). Below that, the burn is sedentary/NEAT,
  // not "active". When maxHr is unknown we don't gate (caller should pass it).
  const activeFloor = (maxHr != null && maxHr > restRef) ? 0.5 * maxHr : restRef;

  let kcal = 0;
  for (const m of worn) {
    if (m.hr_avg < activeFloor) continue; // sedentary minute → not active calories
    kcal += Math.max(0, perMin(m.hr_avg) - restPerMin); // active = above resting
  }

  const inputs_used = ['hr_avg'];
  if (restingHr != null && restingHr > 0) inputs_used.push('baseline.resting_hr');
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
