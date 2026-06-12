// §9 Training load / fitness trend. Tier HIGH (trend only — never a VO2max number).
import type {
  DailyStrain,
  DayHistory,
  Metric,
  LoadValue,
  FitnessTrendValue,
} from './types';
import { mean, linregSlope, round } from './util';

/**
 * calcLoad(dailyStrain[])
 *
 * ACWR = acute/chronic. acute = mean daily strain last 7d; chronic = mean last 28d.
 * Bands: <0.8 detraining, 0.8–1.3 optimal, 1.3–1.5 caution, >1.5 high-risk.
 *
 * Confidence formula: clamp(days_available/28, 0, 1) — chronic needs ~28d to be
 *   meaningful; fewer days → lower confidence. Needs ≥7d for any acwr.
 */
export function calcLoad(dailyStrain: DailyStrain[]): Metric<LoadValue> {
  const sorted = [...dailyStrain].sort((a, b) => a.ts - b.ts);
  const days = sorted.length;

  if (days < 7) {
    return {
      acwr: null,
      acute: 0,
      chronic: 0,
      band: 'unknown',
      confidence: round(Math.min(1, days / 28), 4),
      tier: 'HIGH',
      inputs_used: ['daily_strain'],
    };
  }

  const last7 = sorted.slice(-7).map((d) => d.strain);
  const last28 = sorted.slice(-28).map((d) => d.strain);
  const acute = mean(last7);
  const chronic = mean(last28);
  const acwr = chronic > 0 ? acute / chronic : null;

  let band: LoadValue['band'] = 'unknown';
  if (acwr != null) {
    if (acwr < 0.8) band = 'detraining';
    else if (acwr <= 1.3) band = 'optimal';
    else if (acwr <= 1.5) band = 'caution';
    else band = 'high-risk';
  }

  return {
    acwr: acwr == null ? null : round(acwr, 3),
    acute: round(acute, 3),
    chronic: round(chronic, 3),
    band,
    confidence: round(Math.min(1, days / 28), 4),
    tier: 'HIGH',
    inputs_used: ['daily_strain'],
  };
}

/**
 * calcFitnessTrend(daily[])
 *
 * Rolling 7d RHR and rolling 7d session-HRR60 over the history. Fitness improving
 * when RHR slope < 0 AND HRR slope > 0 over ~4 weeks. Output direction + the two
 * slopes. NEVER emits an absolute VO2max number.
 *
 * Confidence formula: min(0.8, (days/21)*0.8) — spec pins ≥21 days → 0.8; below
 *   that it ramps linearly. 'unknown' until ≥7 days & ≥3 RHR points.
 */
export function calcFitnessTrend(daily: DayHistory[]): Metric<FitnessTrendValue> {
  const rhrSeries: number[] = [];
  const hrrSeries: number[] = [];
  for (const d of daily) {
    if (d.resting_hr != null) rhrSeries.push(d.resting_hr);
    if (d.hrr60 != null) hrrSeries.push(d.hrr60);
  }

  const days = daily.length;
  if (days < 7 || rhrSeries.length < 3) {
    return {
      direction: 'unknown',
      rhr_slope: 0,
      hrr_slope: 0,
      days_used: days,
      confidence: round(Math.min(0.8, (days / 21) * 0.8), 4),
      tier: 'HIGH',
      inputs_used: ['resting_hr', 'hrr60'],
    };
  }

  const rhrRoll = rollingMean(rhrSeries, 7);
  const hrrRoll = hrrSeries.length >= 3 ? rollingMean(hrrSeries, 7) : [];

  const rhrSlope = linregSlope(rhrRoll);
  const hrrSlope = hrrRoll.length >= 2 ? linregSlope(hrrRoll) : 0;

  let direction: FitnessTrendValue['direction'];
  if (rhrSlope < 0 && hrrSlope > 0) direction = 'improving';
  else if (rhrSlope > 0 && (hrrSlope < 0 || hrrRoll.length < 2)) direction = 'declining';
  else direction = 'flat';

  const confidence = Math.min(0.8, (days / 21) * 0.8);

  return {
    direction,
    rhr_slope: round(rhrSlope, 5),
    hrr_slope: round(hrrSlope, 5),
    days_used: days,
    confidence: round(confidence, 4),
    tier: 'HIGH',
    inputs_used: ['resting_hr', 'hrr60'],
  };
}

/** Trailing rolling mean of window w; output length = input length (ramps in). */
function rollingMean(values: number[], w: number): number[] {
  const out: number[] = [];
  for (let i = 0; i < values.length; i++) {
    const start = Math.max(0, i - w + 1);
    out.push(mean(values.slice(start, i + 1)));
  }
  return out;
}
