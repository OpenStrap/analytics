// SLEEP/CIRCADIAN TIER-1 — nonparametric circadian rhythm metrics.
//
// Witting 1990 / van Someren 1999 (the standard actigraphy circadian battery),
// computed over an activity (ENMO surrogate) or HR series binned to a fixed
// epoch (default 60 min). Companion to the parametric cosinor engine.
//
//   IS (Interdaily Stability)  — strength of coupling to the 24-h zeitgeber:
//       IS = (n · Σ_h (x̄_h − x̄)²) / (p · Σ_i (x_i − x̄)²),  0..1, →1 = stable.
//   IV (Intradaily Variability) — fragmentation (transitions hour-to-hour):
//       IV = (n · Σ_i (x_i − x_{i−1})²) / ((n−1) · Σ_i (x_i − x̄)²), →0 = smooth.
//   M10 — mean of the most-active 10 contiguous hours (and its start hour).
//   L5  — mean of the least-active 5 contiguous hours (and its start hour).
//   RA (Relative Amplitude) = (M10 − L5) / (M10 + L5),  0..1, →1 = robust rhythm.
//
// where n = total epochs, p = epochs per day, x̄_h = mean of epoch-of-day h.
//
// HONESTY: anchor circadian phase on the nocturnal trough (L5), never the
// daytime peak — L5 is the trough-anchored marker the catalog requires.

import 'dart:typed_data';
import '../../aggregate/aggregator.dart';
import '../types.dart';
import '../util.dart';
import 'circadian_np_aggregator.dart';

class CircadianNp {
  final double interdailyStability; // IS
  final double intradailyVariability; // IV
  final double m10; // most-active 10 h mean
  final double l5; // least-active 5 h mean
  final double relativeAmplitude; // RA
  final int m10StartEpoch; // start epoch index (within a day)
  final int l5StartEpoch;
  const CircadianNp({
    required this.interdailyStability,
    required this.intradailyVariability,
    required this.m10,
    required this.l5,
    required this.relativeAmplitude,
    required this.m10StartEpoch,
    required this.l5StartEpoch,
  });
  Map<String, dynamic> toJson() => {
        'IS': round6(interdailyStability),
        'IV': round6(intradailyVariability),
        'M10': round6(m10),
        'L5': round6(l5),
        'RA': round6(relativeAmplitude),
        'm10_start_epoch': m10StartEpoch,
        'l5_start_epoch': l5StartEpoch,
      };
}

/// Nonparametric circadian metrics over an epoch-binned activity/HR series.
///
/// [x] activity (or HR) per epoch, laid out as consecutive days of exactly
/// [epochsPerDay] epochs. Needs ≥1 full day for IS/IV; M10/L5 need ≥`m10Epochs`
/// epochs. [epochMin] is informational only (epochs are pre-binned).
Metric<CircadianNp> circadianNonparametric(
  List<double> x,
  int epochsPerDay, {
  int? m10Epochs,
  int? l5Epochs,
}) {
  // Runs [circadianNpAggregator] over the whole series in one slice. IS is the
  // between-epoch-of-day variance over the total variance, IV the mean-squared
  // successive difference over the variance, and M10 / L5 the best circular
  // window over the average day profile (so a window may straddle midnight).
  return circadianNpAggregator(epochsPerDay,
          m10Epochs: m10Epochs, l5Epochs: l5Epochs)
      .run(EpochSeries(Float64List.fromList(x)));
}
