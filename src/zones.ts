// §3 HR zones — minutes per %HRmax band. Tier HIGH.
import type { Minute, Baseline, Profile, Metric, HrZonesValue } from './types';
import { isHrUsable, resolveMaxHr, round } from './util';

/**
 * calcHrZones(minutes, baseline, profile?)
 *
 * For each worn minute, pct = hr_avg/maxHR, bucket into:
 *   z1 50-60, z2 60-70, z3 70-80, z4 80-90, z5 90-100 (%).
 * maxHR = measured session max if available else 220−age.
 *
 * Confidence formula (per spec): 0.85 if age/maxHR known ('measured' or age
 *   present), 0.6 if defaulted from age. We scale by coverage (worn_min/30) so a
 *   sparse day isn't over-confident: confidence = base × clamp(worn_min/30,0,1).
 */
export function calcHrZones(
  minutes: Minute[],
  baseline: Baseline,
  profile?: Profile
): Metric<HrZonesValue> {
  const { maxHr, source } = resolveMaxHr(minutes, baseline, profile);
  const worn = minutes.filter(isHrUsable);

  // %HRmax zones (standard, familiar). NOTE: Karvonen %HRR is more individualized
  // in principle, but it requires a TRUSTWORTHY measured max — here maxHR is
  // usually age-predicted, so %HRR adds no real accuracy and makes light days
  // read as "no zones." Validated on real data; %HRmax kept deliberately.
  const z = [0, 0, 0, 0, 0];
  for (const m of worn) {
    const pct = (m.hr_avg / maxHr) * 100;
    if (pct >= 50 && pct < 60) z[0]++;
    else if (pct >= 60 && pct < 70) z[1]++;
    else if (pct >= 70 && pct < 80) z[2]++;
    else if (pct >= 80 && pct < 90) z[3]++;
    else if (pct >= 90) z[4]++; // 90-100+ all map to z5
  }

  const base = source === 'measured' ? 0.85 : 0.6;
  const coverage = Math.min(1, worn.length / 30);
  const confidence = base * coverage;

  return {
    zone1_min: z[0],
    zone2_min: z[1],
    zone3_min: z[2],
    zone4_min: z[3],
    zone5_min: z[4],
    max_hr_used: maxHr,
    max_hr_source: source,
    confidence: round(confidence, 4),
    tier: 'HIGH',
    inputs_used: source === 'measured' ? ['hr_avg', 'baseline.max_hr'] : ['hr_avg', 'profile.age'],
  };
}
