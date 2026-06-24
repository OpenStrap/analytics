// §11 Baselines — rolling 30-day medians feeding everything.
import type { DayHistory, Profile, Metric, BaselinesValue } from './types';
import { median, round, clamp } from './util';

/** Population/profile-prior baselines for a brand-new user (see seedBaselines). */
export interface SeededBaselines {
  resting_hr: number;
  max_hr: number | null;
  sleep_need_min: number;
  hrv_rmssd: number;
  sleeping_hr: number;
  resp_rate: number;
  hrv_si: number;
}

/**
 * seedBaselines(profile?)
 *
 * Population/profile PRIORS for a user with no measured history yet. These are
 * low-confidence anchors, NOT measured truth — they let strain/HR-zones use a
 * personal resting/max HR from day 1, and warm-start the EWMA-rolled autonomic
 * baselines (RMSSD, sleeping-HR, SI) from physiological norms instead of cold,
 * self-referential seeding on night 1. Every value is overwritten by real data as
 * it accrues: calcBaselines' rolling medians, the nightly EWMA rolls, and the
 * ≥5-night gated scores (recovery/stress) — which still require real nights and
 * are never fabricated by these priors.
 *
 * Population medians (healthy adults):
 *   resting HR  — ~62 (m) / ~66 (f) (HUNT3 / NHANES adult medians).
 *   max HR      — Tanaka 208 − 0.7·age (Tanaka et al., JACC 2001).
 *   sleep need  — 8 h adult default (NSF 2015), nudged at age extremes.
 *   RMSSD       — age-declining (Umetani et al., JACC 1998): 60 − 0.6·age, 18–60 ms.
 *   sleeping HR — resting − ~7 (typical nocturnal dip).
 *   resp rate   — 15 br/min (normal resting adult).
 *   Baevsky SI  — ~90 (normal resting sympathetic tone).
 */
export function seedBaselines(profile?: Profile): SeededBaselines {
  const age = profile?.age && profile.age > 0 ? profile.age : 35;
  const sex = profile?.sex;
  const restingHr = sex === 'f' ? 66 : sex === 'm' ? 62 : 64;
  const maxHr = Math.round(208 - 0.7 * age);
  const sleepNeed = age < 25 ? 510 : age >= 65 ? 450 : 480;
  const rmssd = clamp(round(60 - 0.6 * age, 0), 18, 60);
  return {
    resting_hr: restingHr,
    max_hr: maxHr > 0 ? maxHr : null,
    sleep_need_min: sleepNeed,
    hrv_rmssd: rmssd,
    sleeping_hr: restingHr - 7,
    resp_rate: 15,
    hrv_si: 90,
  };
}

/**
 * calcBaselines(history, profile?)
 *
 * Rolling 30-day medians of: RHR, sleep duration (→ sleep_need_min), skin_temp
 * (RELATIVE), per-zone time, daily strain (chronic, for ACWR).
 * maxHR = max observed session hr_max (else 220−age).
 * Seed from first ~3 days with wide confidence bands.
 *
 * Confidence formula: clamp(days_used/30, 0, 1) — a full 30-day window → 1.0;
 *   the first few seed days yield low confidence (wide bands).
 */
export function calcBaselines(
  history: DayHistory[],
  profile?: Profile
): Metric<BaselinesValue> {
  // Use the most-recent 30 days.
  const window = history.slice(-30);
  const days = window.length;

  const rhrs = window.map((d) => d.resting_hr).filter((x): x is number => x != null);
  const sleeps = window
    .map((d) => d.sleep_duration_min)
    .filter((x): x is number => x != null);
  const temps = window.map((d) => d.skin_temp).filter((x): x is number => x != null);
  const strains = window
    .map((d) => d.daily_strain)
    .filter((x): x is number => x != null);

  const rhr = median(rhrs);
  // Sleep need = median of REAL nights only. 0-duration nights (off-wrist / no
  // sleep detected) would drag the median to garbage (e.g. median([299,0,0,1])≈0
  // → "0.0h need"). Require ≥2h to count, and reject an implausible result
  // (<4h) as "no baseline yet" → null, so callers fall back to the 8h default.
  const realNights = sleeps.filter((s) => s >= 120);
  const sleepNeedRaw = median(realNights);
  // Personalize only with ≥3 real nights AND a plausible (≥4h) result; else
  // null → callers fall back to the 8h default (avoids 1-sample noise / garbage).
  const sleepNeed =
      realNights.length >= 3 && sleepNeedRaw != null && sleepNeedRaw >= 240
          ? sleepNeedRaw
          : null;
  const temp = median(temps);
  const chronic = strains.length ? mean(strains) : null;

  // Per-zone medians.
  const zoneCols: number[][] = [[], [], [], [], []];
  for (const d of window) {
    if (d.zone_min) for (let z = 0; z < 5; z++) zoneCols[z].push(d.zone_min[z]);
  }
  const zoneMed = zoneCols.every((c) => c.length > 0)
    ? (zoneCols.map((c) => median(c) ?? 0) as [number, number, number, number, number])
    : null;

  // maxHR: the highest per-day peak observed across the window. BUT a daily peak
  // on a sedentary day is just a quiet high (e.g. 120 bpm), NOT a true HRmax —
  // trusting it as the zone/strain denominator under-states the scale and inflates
  // those metrics. So we only treat the observed peak as a real 'measured' max when
  // it EXCEEDS the age-predicted Tanaka floor (208−0.7·age, JACC 2001 — a genuine
  // hard effort); otherwise the age floor wins. Mirrors resolveMaxHr (util.ts) so
  // the baseline and the per-day denominator agree.
  const observedMax = window
    .map((d) => d.session_hr_max)
    .filter((x): x is number => x != null);
  const observedPeak = observedMax.length > 0 ? Math.max(...observedMax) : 0;
  const ageMax =
    profile?.age && profile.age > 0 ? Math.round(208 - 0.7 * profile.age) : null;
  let maxHr: number | null;
  let maxHrSource: 'measured' | 'age';
  if (ageMax != null) {
    if (observedPeak > ageMax) {
      maxHr = observedPeak; // genuine above-age effort → trust it
      maxHrSource = 'measured';
    } else {
      maxHr = ageMax; // a quiet daily peak can't shrink the scale
      maxHrSource = 'age';
    }
  } else if (observedPeak > 0) {
    // No age to floor against: the observed peak is the best available, but flag it
    // 'age' (an unverified within-window peak, not a true measured HRmax) so callers
    // down-weight confidence.
    maxHr = observedPeak;
    maxHrSource = 'age';
  } else {
    maxHr = null; // honest: no measured max, no age → cannot derive
    maxHrSource = 'age';
  }

  const confidence = Math.min(1, days / 30);

  const inputs_used: string[] = [];
  if (rhrs.length) inputs_used.push('resting_hr');
  if (sleeps.length) inputs_used.push('sleep_duration_min');
  if (temps.length) inputs_used.push('skin_temp');
  if (strains.length) inputs_used.push('daily_strain');
  if (maxHrSource === 'measured') inputs_used.push('session_hr_max');
  else if (profile?.age) inputs_used.push('profile.age');

  return {
    resting_hr: rhr == null ? null : round(rhr, 1),
    sleep_need_min: sleepNeed == null ? null : round(sleepNeed, 0),
    skin_temp: temp == null ? null : round(temp, 2),
    max_hr: maxHr == null ? null : round(maxHr, 0),
    max_hr_source: maxHrSource,
    chronic_strain: chronic == null ? null : round(chronic, 3),
    zone_min: zoneMed,
    days_used: days,
    confidence: round(days === 0 ? 0 : confidence, 4),
    tier: 'HIGH',
    inputs_used,
  };
}

function mean(xs: number[]): number {
  return xs.length ? xs.reduce((a, b) => a + b, 0) / xs.length : 0;
}
