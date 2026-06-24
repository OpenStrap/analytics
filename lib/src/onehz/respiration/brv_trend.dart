// RESPIRATION TIER-MED — Breathing-Rate Variability (BRV) trend.
//
// Given a sequence of per-window respiratory-rate estimates across a night (or
// across nights), BRV is the dispersion of breathing rate. Elevated breathing-
// rate variability is associated with disturbed/periodic breathing; a falling
// nightly mean breathing rate is a known restful-recovery signal. We expose
// both a within-night BRV (CV of the rate) and a Theil-Sen trend slope across
// the supplied window — robust, n-of-1, surfaced only beyond MDC by the caller.
//
// HONESTY: BRV is a TREND descriptor (MED tier). It is not a diagnosis; it is
// only meaningful within-user against the wearer's own history.

import '../types.dart';
import '../util.dart';

class BrvResult {
  final double meanBrpm; // mean breathing rate (br/min)
  final double sdBrpm; // SD of breathing rate (br/min) — the BRV
  final double cv; // coefficient of variation (sd/mean), unitless
  final double? trendSlope; // Theil-Sen slope (br/min per sample), null if <2
  final int nWindows; // estimates contributing
  const BrvResult({
    required this.meanBrpm,
    required this.sdBrpm,
    required this.cv,
    required this.trendSlope,
    required this.nWindows,
  });
  Map<String, dynamic> toJson() => {
        'mean_brpm': round6(meanBrpm),
        'sd_brpm': round6(sdBrpm),
        'cv': round6(cv),
        if (trendSlope != null) 'trend_slope': round6(trendSlope!),
        'n_windows': nWindows,
      };
}

/// Breathing-rate variability over a sequence of respiratory-rate estimates.
///
/// [brpm] per-window breathing rates (br/min), time-ordered. Pass only valid
/// (resolved) estimates — absent windows contribute nothing.
Metric<BrvResult> breathingRateVariability(List<double> brpm) {
  const inputs = ['resp_rate_series'];
  if (brpm.length < 3) {
    return const Metric<BrvResult>.absent(
      tier: Tier.estimate,
      inputs_used: inputs,
      note: 'need ≥3 respiratory-rate windows for a BRV estimate',
    );
  }
  final m = mean(brpm)!;
  final sd = stddev(brpm)!;
  final cv = m == 0 ? 0.0 : sd / m;
  final slope = theilSen(brpm); // robust trend across the window
  // Confidence grows with window count, capped (MED tier).
  final conf = clamp(0.3 + 0.05 * brpm.length, 0.3, 0.8);
  return Metric<BrvResult>(
    value: BrvResult(
      meanBrpm: m,
      sdBrpm: sd,
      cv: cv,
      trendSlope: slope,
      nWindows: brpm.length,
    ),
    confidence: conf,
    tier: Tier.estimate,
    inputs_used: inputs,
    note: 'Breathing-rate variability TREND (within-user only); '
        'surface a change only beyond the metric MDC',
  );
}
