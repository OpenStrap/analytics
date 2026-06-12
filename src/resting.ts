// §1 Resting HR — 5th percentile of HR in the sleep window. Tier HIGH.
import type { Minute, Metric, RestingHrValue } from './types';
import { isHrUsable, percentile, clamp, round } from './util';

export interface SleepWindow {
  onset_ts: number | null;
  wake_ts: number | null;
}

/**
 * calcRestingHR(minutes, sleepWindow?)
 *
 * Restrict to the night's sleep window; take worn minutes with hr_avg>0;
 * RHR = 5th percentile of hr_avg (robust low, not the noisy absolute min).
 * confidence = clamp(worn_sleep_minutes / 240, 0, 1).
 *
 * Fallback when no sleep window: 5th pctile of the lowest contiguous 30-min worn
 * stretch of the day, with confidence capped at 0.5.
 *
 * Confidence formula: coverage = worn_sleep_min/240 (full night ≈ 4h worn = 1.0);
 *   fallback path multiplies by the 0.5 cap (lower input completeness).
 */
export function calcRestingHR(
  minutes: Minute[],
  sleepWindow?: SleepWindow
): Metric<RestingHrValue> {
  const hasWindow =
    !!sleepWindow && sleepWindow.onset_ts != null && sleepWindow.wake_ts != null;

  if (hasWindow) {
    const onset = sleepWindow!.onset_ts as number;
    const wake = sleepWindow!.wake_ts as number;
    const inWindow = minutes.filter(
      (m) => m.ts >= onset && m.ts <= wake && isHrUsable(m)
    );
    const hrs = inWindow.map((m) => m.hr_avg);
    const rhr = percentile(hrs, 5);
    const confidence = clamp(inWindow.length / 240, 0, 1);
    return {
      resting_hr: rhr == null ? null : round(rhr, 1),
      confidence: round(rhr == null ? 0 : confidence, 4),
      tier: 'HIGH',
      inputs_used: ['hr_avg', 'sleep_window'],
    };
  }

  // Fallback: lowest contiguous 30-min worn stretch of the day.
  const best = lowestContiguousStretch(minutes, 30);
  if (!best) {
    return {
      resting_hr: null,
      confidence: 0,
      tier: 'HIGH',
      inputs_used: ['hr_avg'],
    };
  }
  const rhr = percentile(best.hrs, 5);
  // confidence ≤ 0.5: scale coverage of the 30-min stretch, then cap.
  const confidence = Math.min(0.5, clamp(best.hrs.length / 30, 0, 1) * 0.5);
  return {
    resting_hr: rhr == null ? null : round(rhr, 1),
    confidence: round(rhr == null ? 0 : confidence, 4),
    tier: 'HIGH',
    inputs_used: ['hr_avg', 'fallback_30min'],
  };
}

/** Lowest-mean contiguous worn stretch of `windowMin` consecutive worn minutes. */
function lowestContiguousStretch(
  minutes: Minute[],
  windowMin: number
): { hrs: number[] } | null {
  const worn = minutes
    .filter(isHrUsable)
    .sort((a, b) => a.ts - b.ts);
  if (worn.length === 0) return null;
  if (worn.length < windowMin) return { hrs: worn.map((m) => m.hr_avg) };

  let bestMean = Infinity;
  let bestHrs: number[] = [];
  for (let i = 0; i + windowMin <= worn.length; i++) {
    const slice = worn.slice(i, i + windowMin);
    const m = slice.reduce((s, x) => s + x.hr_avg, 0) / windowMin;
    if (m < bestMean) {
      bestMean = m;
      bestHrs = slice.map((s) => s.hr_avg);
    }
  }
  return { hrs: bestHrs };
}
