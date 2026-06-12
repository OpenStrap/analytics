// §6 Sleep regularity (SRI). Tier HIGH (≥3 nights).
import type { NightSummary, Metric, SleepRegularityValue } from './types';
import { stddev, round } from './util';

const DAY_MIN = 24 * 60;

/** minute-of-day (0..1439) from a unix-seconds timestamp, UTC-based & deterministic. */
function minuteOfDay(ts: number): number {
  const totalMin = Math.floor(ts / 60);
  return ((totalMin % DAY_MIN) + DAY_MIN) % DAY_MIN;
}

/**
 * calcSleepRegularity(nights[])
 *
 * For each night compute onset/wake minute-of-day.
 *   SRI = max(0, 100 − (avg(std_onset, std_wake)/120)*100).
 * confidence = 0 if <3 nights, else 0.7.
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

  const onsetStd = stddev(onsets);
  const wakeStd = stddev(wakes);
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
