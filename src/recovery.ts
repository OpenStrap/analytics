// §8 HR recovery (HRR60). Tier HIGH.
// §Recovery — nocturnal-HRV recovery score (Plews et al., Sports Med 2013):
//   compare tonight's ln(RMSSD) to a rolling personal baseline (mean ± sd of
//   ln RMSSD). This is the validated, non-heuristic replacement for the old
//   weighted "readiness" composite. No HRV → null (honest), never a fallback blend.
import type { Minute, Baseline, Metric, HrRecoveryValue, RecoveryValue, Driver, MetricRef } from './types';
import { isHrUsable, resolveMaxHr, round, mean, stddev } from './util';

/**
 * calcRecovery(rmssdToday, baselineRmssd[], opts?)
 *
 * Plews lnRMSSD method: z = (ln RMSSD_today − mean ln RMSSD_baseline) / sd.
 * score = clamp(50 + 25·z, 0, 100) — each baseline SD ≈ 25 points; above your
 * own baseline → green, below → compromised. Needs ≥5 baseline nights, else null.
 * Tier HIGH (HRV is the gold-standard autonomic recovery signal).
 */
export function calcRecovery(
  rmssdToday: number | null,
  baselineRmssd: number[],
  opts: { date?: string } = {},
): Metric<RecoveryValue> {
  const NOTE = 'HRV-based';
  const usableBaseline = baselineRmssd.filter((x) => x > 0);
  const none = (): Metric<RecoveryValue> => ({
    score: null, rmssd: rmssdToday, baseline_rmssd: null, z: null, note: NOTE,
    confidence: 0, tier: 'HIGH', inputs_used: ['hrv_rmssd'],
  });
  if (rmssdToday == null || rmssdToday <= 0 || usableBaseline.length < 5) return none();

  const lnBase = usableBaseline.map((x) => Math.log(x));
  const m = mean(lnBase);
  const sd = stddev(lnBase);
  const baseRmssd = Math.exp(m);
  // Degenerate baseline (no spread) → can't z-score; report value, low confidence.
  if (sd <= 0) {
    return {
      score: null, rmssd: round(rmssdToday, 1), baseline_rmssd: round(baseRmssd, 1),
      z: null, note: NOTE, confidence: 0.2, tier: 'HIGH', inputs_used: ['hrv_rmssd'],
    };
  }
  const z = (Math.log(rmssdToday) - m) / sd;
  const score = Math.max(0, Math.min(100, Math.round(50 + 25 * z)));
  const ref: MetricRef = { metric: 'hrv', date: opts.date, scale: 'day' };
  const drivers: Driver[] = [{
    label: 'Nocturnal HRV (RMSSD)',
    contribution: round(25 * z, 1),
    detail: `${round(rmssdToday, 0)} ms vs baseline ${round(baseRmssd, 0)} ms`,
    ref,
  }];
  // confidence rises with baseline length (≥21 nights → full).
  const confidence = Math.min(1, usableBaseline.length / 21);
  return {
    score, rmssd: round(rmssdToday, 1), baseline_rmssd: round(baseRmssd, 1),
    z: round(z, 2), note: NOTE,
    confidence: round(confidence, 4), tier: 'HIGH', inputs_used: ['hrv_rmssd', 'baseline.hrv_rmssd'],
    drivers,
  };
}

/**
 * calcHrRecovery(sessionMinutes, baseline, profile?)
 *
 * Find the session's peak hr_max. HRR60 = peak − hr_avg of the minute ~1 min
 * after the peak (minute resolution). Bigger drop = fitter.
 * confidence = 0.7 if a clear elevated peak (≥ RHR + 40% reserve) exists, else
 *   the result is null with confidence 0.
 *
 * Confidence formula: 0.7 when an elevated peak (≥ RHR+0.4*reserve) and a valid
 *   post-peak minute both exist; otherwise 0 (insufficient signal).
 */
export function calcHrRecovery(
  sessionMinutes: Minute[],
  baseline: Baseline,
  profile?: { age?: number }
): Metric<HrRecoveryValue> {
  const sorted = [...sessionMinutes].sort((a, b) => a.ts - b.ts);
  const worn = sorted.filter(isHrUsable);

  const none = (): Metric<HrRecoveryValue> => ({
    hrr60: null,
    peak_hr: null,
    confidence: 0,
    tier: 'HIGH',
    inputs_used: ['hr_max', 'hr_avg'],
  });
  if (worn.length === 0) return none();

  const { maxHr } = resolveMaxHr(sorted, baseline, profile);
  const rhr = baseline.resting_hr;
  const threshold = rhr + 0.4 * (maxHr - rhr);

  // Peak = the worn minute with the highest hr_max.
  let peakIdxInSorted = -1;
  let peakVal = -Infinity;
  for (let i = 0; i < sorted.length; i++) {
    if (!isHrUsable(sorted[i])) continue;
    if (sorted[i].hr_max > peakVal) {
      peakVal = sorted[i].hr_max;
      peakIdxInSorted = i;
    }
  }

  if (peakIdxInSorted < 0 || peakVal < threshold) return none();

  // Minute ~1 min after the peak: prefer the immediate next worn minute whose
  // ts is ~60s after the peak (tolerant of gaps).
  const peakTs = sorted[peakIdxInSorted].ts;
  let after: Minute | null = null;
  for (let i = peakIdxInSorted + 1; i < sorted.length; i++) {
    if (!isHrUsable(sorted[i])) continue;
    const dt = sorted[i].ts - peakTs;
    if (dt >= 45 && dt <= 90) {
      after = sorted[i];
      break;
    }
    if (dt > 90) break;
  }
  if (!after) return none();

  const hrr60 = peakVal - after.hr_avg;
  return {
    hrr60: round(hrr60, 1),
    peak_hr: round(peakVal, 1),
    confidence: 0.7,
    tier: 'HIGH',
    inputs_used: ['hr_max', 'hr_avg', 'baseline.resting_hr'],
  };
}
