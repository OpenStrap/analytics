// §6 Sleep timing regularity. Tier HIGH (≥3 nights).
//
// HONEST SCOPE: this is the circular variability of sleep-ONSET and WAKE clock-times
// (how much your bed/wake times wander night to night), scaled 0–100. It is a
// legitimate, useful regularity measure — but it is NOT the Phillips et al. 2017
// Sleep Regularity Index (Sci Rep 7:3216), which is an epoch-by-epoch probability
// that two time points 24 h apart are in the same sleep/wake state. We don't plumb
// minute-level sleep/wake state across consecutive days, so we don't claim the SRI
// name. If that state is ever wired in, implement the real SRI and relabel.
import type { NightSummary, Metric, SleepRegularityValue } from './types';
import { round } from './util';

const DAY_MIN = 24 * 60;

/** minute-of-day (0..1439) from a unix-seconds timestamp, UTC-based & deterministic. */
function minuteOfDay(ts: number): number {
  const totalMin = Math.floor(ts / 60);
  return ((totalMin % DAY_MIN) + DAY_MIN) % DAY_MIN;
}

/**
 * Circular standard deviation (in MINUTES) of a set of minute-of-day values.
 *
 * Clock time is cyclic: 23:50 and 00:10 are 20 min apart, not ~1430. A LINEAR
 * stddev of minute-of-day blows up for any bedtime straddling midnight and floors
 * SRI to 0 for people who simply sleep around midnight. We instead map each time
 * to an angle θ = 2π·m/1440, take the mean resultant length R, and derive the
 * circular std σ = √(−2·ln R) (Mardia), converted back to minutes. Identical
 * times → R=1 → σ=0; uniformly scattered → R→0 → σ→∞ (clamped by the caller).
 */
function circularStdMin(minutesOfDay: number[]): number {
  if (minutesOfDay.length < 2) return 0;
  let sumCos = 0;
  let sumSin = 0;
  for (const m of minutesOfDay) {
    const theta = (2 * Math.PI * m) / DAY_MIN;
    sumCos += Math.cos(theta);
    sumSin += Math.sin(theta);
  }
  const n = minutesOfDay.length;
  const r = Math.sqrt(sumCos * sumCos + sumSin * sumSin) / n;
  // R∈(0,1]; guard R→0 (fully scattered) so ln stays finite.
  const rClamped = Math.max(1e-9, Math.min(1, r));
  const sigmaRad = Math.sqrt(-2 * Math.log(rClamped));
  return sigmaRad * (DAY_MIN / (2 * Math.PI));
}

/**
 * calcSleepRegularity(nights[])
 *
 * For each night compute onset/wake minute-of-day.
 *   score = max(0, 100 − (avg(circ_std_onset, circ_std_wake)/120)*100).
 * Uses CIRCULAR std (see circularStdMin) so midnight-straddling bedtimes don't
 * spuriously read as irregular. confidence = 0 if <3 nights, else 0.7.
 *
 * NOTE: the returned `sri` field is this onset/wake timing-regularity score, NOT
 * the Phillips epoch-agreement Sleep Regularity Index — see the file header.
 *
 * Confidence formula: pinned 0.7 once ≥3 nights with both onset & wake present;
 *   0 below that threshold (input incompleteness).
 */
export function calcSleepRegularity(
  nights: NightSummary[]
): Metric<SleepRegularityValue> {
  const valid = nights.filter((nn) => nn.onset_ts != null && nn.wake_ts != null);
  const onsets = valid.map((nn) => minuteOfDay(nn.onset_ts as number));
  const wakes = valid.map((nn) => minuteOfDay(nn.wake_ts as number));

  if (valid.length < 3) {
    return {
      sri: 0,
      onset_std_min: 0,
      wake_std_min: 0,
      nights_used: valid.length,
      confidence: 0,
      tier: 'HIGH',
      inputs_used: ['nights.onset_ts', 'nights.wake_ts'],
    };
  }

  const onsetStd = circularStdMin(onsets);
  const wakeStd = circularStdMin(wakes);
  const avgStd = (onsetStd + wakeStd) / 2;
  const sri = Math.max(0, 100 - (avgStd / 120) * 100);

  return {
    sri: round(sri, 2),
    onset_std_min: round(onsetStd, 2),
    wake_std_min: round(wakeStd, 2),
    nights_used: valid.length,
    confidence: 0.7,
    tier: 'HIGH',
    inputs_used: ['nights.onset_ts', 'nights.wake_ts'],
  };
}
