// §8 HR recovery (HRR60). Tier HIGH.
import type { Minute, Baseline, Metric, HrRecoveryValue } from './types';
import { isHrUsable, resolveMaxHr, round } from './util';

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
