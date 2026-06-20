// §SpO₂ — RELATIVE blood-oxygen index from the red/IR reflectance ratio.
//
// Pulse oximetry is grounded in the ratio R = red/IR: dividing the two LED
// channels cancels common-mode (perfusion, skin tone, contact, motion) that a
// single channel conflates. We do NOT have factory LED/photodiode calibration,
// and the 1 Hz historical record can't resolve the cardiac AC for a true
// ratio-of-ratios — so this is a RELATIVE index (tonight's median R vs the
// user's own baseline R), never an absolute %. Validated on 4 user datasets:
// the ratio is more stable than red-alone on clean signal (CV 0.79–4.81% vs
// 0.99–5.53%); on a noisy band it isn't, which is why the confidence below
// is gated on intra-night ratio stability + sample count — a noisy night
// yields low confidence (or null), never a misleading number.
import type { Metric, Driver, MetricRef } from './types';
import { median, mean, stddev, round, clamp } from './util';

export interface Spo2Value {
  /** Relative deviation vs personal baseline, in % of baseline ratio.
   *  Signed so that POSITIVE = better-oxygenated than your baseline (lower R). */
  index: number | null;
  /** Tonight's median red/IR ratio (raw) — kept so the caller can roll the baseline. */
  night_ratio: number | null;
}

const MIN_MINUTES = 30;       // need ≥30 one-minute ratios for a defensible night
const PLAUSIBLE = (r: number) => r > 0.4 && r < 1.5; // reflectance-ratio sanity band
const CV_FLOOR = 0.08;        // intra-night CV at/above which confidence → 0

/**
 * calcSpo2Index(ratios, baselineRatio)
 *
 * ratios: per-minute red/IR ratios over the sleep window (one per usable minute).
 * baselineRatio: the user's rolling baseline ratio, or null if not yet established.
 *
 * Returns a RELATIVE index + a computed confidence. With no baseline yet it reports
 * night_ratio only (to seed the baseline) and a null index — honest, not guessed.
 */
export function calcSpo2Index(ratios: number[], baselineRatio: number | null): Metric<Spo2Value> {
  const r = ratios.filter(PLAUSIBLE);
  const none = (conf = 0): Metric<Spo2Value> => ({
    index: null, night_ratio: null, confidence: conf, tier: 'RELATIVE', inputs_used: [],
  });
  if (r.length < MIN_MINUTES) return none();

  const med = median(r);
  if (med == null) return none();
  const nightR = round(med, 4);
  const m = mean(r);
  const cv = m > 0 ? stddev(r) / m : 1;
  // confidence: more minutes (cap at 3 h) AND a stable within-night ratio.
  const conf = round(clamp(Math.min(r.length / 180, 1) * Math.max(0, 1 - cv / CV_FLOOR), 0, 1), 3);
  const inputs_used = ['spo2_red_raw', 'spo2_ir_raw'];
  const ref: MetricRef = { metric: 'spo2', scale: 'day' };

  // No personal baseline yet → seed value only, no fabricated index.
  if (baselineRatio == null || !(baselineRatio > 0)) {
    return { index: null, night_ratio: nightR, confidence: round(conf * 0.5, 3), tier: 'RELATIVE', inputs_used };
  }

  // + = lower ratio than baseline = more oxygenated than your norm.
  const index = round(((baselineRatio - nightR) / baselineRatio) * 100, 2);
  const drivers: Driver[] = [
    { label: 'Blood-oxygen vs baseline', contribution: index, detail: `R ${nightR} vs baseline ${round(baselineRatio, 4)}`, ref },
  ];
  return { index, night_ratio: nightR, confidence: conf, tier: 'RELATIVE', inputs_used, drivers };
}
