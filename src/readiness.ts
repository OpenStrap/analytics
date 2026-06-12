// §10 Readiness + health signals. Tier ESTIMATE. ALWAYS "(est.) — not HRV-based".
import type {
  Baseline,
  Metric,
  ReadinessValue,
  AnomalyValue,
} from './types';
import { clamp, round } from './util';

export interface ReadinessInputs {
  resting_hr: number | null; // today's RHR
  sleep_duration_min: number | null; // last night asleep minutes
  sleep_efficiency: number | null; // 0..1
  sleep_regularity?: number | null; // SRI 0..100
  skin_temp?: number | null; // today's RELATIVE temp (same scale as baseline)
}

/**
 * calcReadiness(inputs, baseline)
 *
 * Weighted ESTIMATE (NOT HRV-based):
 *   50% RHR-vs-baseline  : 1 − clamp(rhr_dev/0.2, 0, 1), rhr_dev = (rhr−base)/base
 *   30% sleep-debt       : 1 − clamp(debt/need, 0, 1), debt = max(0, need−duration)
 *   20% sleep-quality    : mean(efficiency, regularity/100) where present
 * If a RELATIVE temp deviation is available, fold ±10% for large deviations.
 * Output score (0..100) + component breakdown + the mandatory "(est.) — not HRV" note.
 *
 * Confidence formula: ESTIMATE base 0.5 × input_completeness, where
 *   input_completeness = (#components computable among {rhr, sleep_debt, quality})/3.
 */
export function calcReadiness(
  inputs: ReadinessInputs,
  baseline: Baseline
): Metric<ReadinessValue> {
  const NOTE = '(est.) — not HRV-based';
  const used: string[] = [];

  // Component 1: RHR vs baseline.
  let rhrComp = 0;
  let haveRhr = false;
  if (inputs.resting_hr != null && baseline.resting_hr > 0) {
    const dev = (inputs.resting_hr - baseline.resting_hr) / baseline.resting_hr;
    rhrComp = 1 - clamp(dev / 0.2, 0, 1); // only elevated RHR penalizes
    haveRhr = true;
    used.push('resting_hr', 'baseline.resting_hr');
  }

  // Component 2: sleep debt.
  let debtComp = 0;
  let haveDebt = false;
  if (inputs.sleep_duration_min != null && baseline.sleep_need_min > 0) {
    const debt = Math.max(0, baseline.sleep_need_min - inputs.sleep_duration_min);
    debtComp = 1 - clamp(debt / baseline.sleep_need_min, 0, 1);
    haveDebt = true;
    used.push('sleep_duration_min', 'baseline.sleep_need_min');
  }

  // Component 3: sleep quality (efficiency + regularity).
  const qualityParts: number[] = [];
  if (inputs.sleep_efficiency != null) {
    qualityParts.push(clamp(inputs.sleep_efficiency, 0, 1));
    used.push('sleep_efficiency');
  }
  if (inputs.sleep_regularity != null) {
    qualityParts.push(clamp(inputs.sleep_regularity / 100, 0, 1));
    used.push('sleep_regularity');
  }
  const haveQuality = qualityParts.length > 0;
  const qualityComp = haveQuality
    ? qualityParts.reduce((a, b) => a + b, 0) / qualityParts.length
    : 0;

  // Reweight across present components so missing ones don't silently zero score.
  const weights = { rhr: 0.5, debt: 0.3, quality: 0.2 };
  let wSum = 0;
  let acc = 0;
  if (haveRhr) {
    acc += weights.rhr * rhrComp;
    wSum += weights.rhr;
  }
  if (haveDebt) {
    acc += weights.debt * debtComp;
    wSum += weights.debt;
  }
  if (haveQuality) {
    acc += weights.quality * qualityComp;
    wSum += weights.quality;
  }

  let score = wSum > 0 ? (acc / wSum) * 100 : 0;

  // Optional RELATIVE temp fold ±10% for large deviations.
  let tempAdjust = 1;
  if (inputs.skin_temp != null && baseline.skin_temp != null) {
    const tdev = inputs.skin_temp - baseline.skin_temp;
    if (Math.abs(tdev) > 0.5) {
      tempAdjust = tdev > 0 ? 0.9 : 1.1; // fever-like up → down-weight readiness
      score *= tempAdjust;
      used.push('skin_temp', 'baseline.skin_temp');
    }
  }
  score = clamp(score, 0, 100);

  const present = [haveRhr, haveDebt, haveQuality].filter(Boolean).length;
  const confidence = 0.5 * (present / 3);

  return {
    score: round(score, 1),
    components: {
      rhr: round(rhrComp, 4),
      sleep_debt: round(debtComp, 4),
      sleep_quality: round(qualityComp, 4),
      temp_adjust: tempAdjust,
    },
    note: NOTE,
    confidence: round(present === 0 ? 0 : confidence, 4),
    tier: 'ESTIMATE',
    inputs_used: used,
  };
}

export interface AnomalyInputs {
  /** recent RHR series, most-recent LAST, used for the ≥2 consecutive-day rule */
  recent_rhr: number[];
  skin_temp?: number | null; // today RELATIVE
  sleep_efficiency?: number | null; // today
  baseline_sleep_efficiency?: number | null; // prior typical efficiency
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
  baseline: Baseline
): Metric<AnomalyValue> {
  const NOTE = 'signal, not a diagnosis';
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

  const signal = ruleA || ruleB;

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
