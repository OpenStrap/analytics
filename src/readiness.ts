// §10 Anomaly signal (RHR-elevation rule). The old weighted "readiness" composite
// was REMOVED — recovery is now HRV-based (see calcRecovery in recovery.ts). This
// keeps only the simple, rule-based RHR anomaly (Radin et al., Lancet Digit Health
// 2020); the richer multivariate illness signal lives in illness.ts (Mahalanobis).
import type { Baseline, Metric, AnomalyValue } from './types';
import type { CyclePhase } from './cycle';
import { round } from './util';

export interface AnomalyInputs {
  /** recent RHR series, most-recent LAST, used for the ≥2 consecutive-day rule */
  recent_rhr: number[];
  skin_temp?: number | null; // today RELATIVE
  sleep_efficiency?: number | null; // today
  baseline_sleep_efficiency?: number | null; // prior typical efficiency
}
export interface AnomalyOpts {
  /** menstrual-cycle phase if tracked — gates phase-expected RHR rises */
  cyclePhase?: CyclePhase | null;
}

/**
 * calcAnomaly(inputs, baseline)
 *
 * Fires when RHR ≥ baseline+7% for ≥2 consecutive days, OR (RHR↑ AND temp
 * Δ>+0.5 vs baseline AND sleep efficiency↓). Output boolean signal + which
 * inputs triggered + "signal, not a diagnosis". Never alarmist. confidence ≤0.5.
 *
 * Confidence formula: ESTIMATE, capped at 0.5; scaled by how many distinct
 *   trigger conditions are evaluable (more corroborating signals → up to 0.5).
 */
export function calcAnomaly(
  inputs: AnomalyInputs,
  baseline: Baseline,
  opts?: AnomalyOpts
): Metric<AnomalyValue> {
  let NOTE = 'signal, not a diagnosis';
  const triggers: string[] = [];
  const used: string[] = [];

  const rhrThreshold = baseline.resting_hr * 1.07;

  // Rule A: RHR ≥ baseline+7% for ≥2 consecutive (trailing) days.
  let consecutive = 0;
  if (inputs.recent_rhr.length > 0) {
    used.push('recent_rhr', 'baseline.resting_hr');
    for (let i = inputs.recent_rhr.length - 1; i >= 0; i--) {
      if (inputs.recent_rhr[i] >= rhrThreshold) consecutive++;
      else break;
    }
  }
  const ruleA = consecutive >= 2;
  if (ruleA) triggers.push('rhr_elevated_2d');

  // Rule B: RHR↑ AND temp Δ>+0.5 AND sleep efficiency↓.
  const latestRhr = inputs.recent_rhr.length
    ? inputs.recent_rhr[inputs.recent_rhr.length - 1]
    : null;
  const rhrUp = latestRhr != null && latestRhr >= rhrThreshold;
  let tempUp = false;
  if (inputs.skin_temp != null && baseline.skin_temp != null) {
    used.push('skin_temp', 'baseline.skin_temp');
    tempUp = inputs.skin_temp - baseline.skin_temp > 0.5;
  }
  let effDown = false;
  if (
    inputs.sleep_efficiency != null &&
    inputs.baseline_sleep_efficiency != null
  ) {
    used.push('sleep_efficiency', 'baseline_sleep_efficiency');
    effDown = inputs.sleep_efficiency < inputs.baseline_sleep_efficiency;
  }
  const ruleB = rhrUp && tempUp && effDown;
  if (ruleB) triggers.push('rhr_temp_efficiency');

  // Cycle-aware gate: through the luteal/menstrual phase a RHR (and temp) rise is
  // normal physiology. Suppress the pure-RHR rule A then; rule B keeps firing because
  // its sleep-efficiency drop is NOT explained by the cycle. (Wilcox 2000.)
  const inCyclePhase = opts?.cyclePhase === 'luteal' || opts?.cyclePhase === 'menstruation';
  const signal = (ruleA && !inCyclePhase) || ruleB;
  if (ruleA && inCyclePhase && !ruleB) {
    NOTE = 'signal, not a diagnosis (an elevated resting HR can be expected in this phase of your cycle)';
  }

  // Confidence scales with how many corroborating inputs were evaluable.
  const evaluable = [
    inputs.recent_rhr.length >= 2,
    inputs.skin_temp != null && baseline.skin_temp != null,
    inputs.sleep_efficiency != null && inputs.baseline_sleep_efficiency != null,
  ].filter(Boolean).length;
  const confidence = Math.min(0.5, (evaluable / 3) * 0.5);

  return {
    signal,
    triggers,
    note: NOTE,
    confidence: round(confidence, 4),
    tier: 'ESTIMATE',
    inputs_used: Array.from(new Set(used)),
  };
}
