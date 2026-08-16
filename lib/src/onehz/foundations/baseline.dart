// FOUNDATION — robust personal baseline.
//
// median + MAD (Leys 2013; Iglewicz-Hoaglin modified-z, flag |M|>3.5),
// coverage-gate (Plews 2014: require ≥minValid of window), and an MDC gate so
// we only surface a change beyond the metric's minimal detectable change
// (Hopkins 2000). MAD=0 is guarded for quantized data.
//
// HONESTY: insufficient coverage => baseline absent (null), never an
// optimistic guess.

import 'dart:math' as math;
import '../util.dart';

class RobustBaseline {
  final double? center; // median of the window (null if no data)
  final double? scale; // MAD (scaled to σ); null if undefined
  final int nValid;
  final int nWindow;
  final bool sufficient; // passed the coverage gate
  const RobustBaseline({
    required this.center,
    required this.scale,
    required this.nValid,
    required this.nWindow,
    required this.sufficient,
  });

  /// Iglewicz-Hoaglin modified z of [x] vs this baseline. Null if scale absent.
  double? modZ(double x) {
    if (center == null || scale == null || scale == 0) return null;
    return (x - center!) / scale!;
  }

  /// |modZ| > 3.5 outlier flag (Iglewicz-Hoaglin). Null when undecidable.
  bool? isOutlier(double x) {
    final m = modZ(x);
    return m == null ? null : m.abs() > 3.5;
  }
}

/// Build a robust baseline from a window of values (already filtered to the
/// metric of interest). [minValid] coverage gate (e.g. 3 for a 7-day window per
/// Plews 2014). Values are taken as-is; pass only valid samples.
RobustBaseline robustBaseline(List<double> window, {int minValid = 3}) {
  final n = window.length;
  if (n == 0) {
    return RobustBaseline(
        center: null, scale: null, nValid: 0, nWindow: 0, sufficient: false);
  }
  final c = median(window);
  final s = mad(window); // may be null/0 on tiny or quantized data
  return RobustBaseline(
    center: c,
    scale: s,
    nValid: n,
    nWindow: n,
    sufficient: n >= minValid,
  );
}

/// Minimal Detectable Change: MDC = 1.96 × √2 × typical-error.
/// We approximate the typical error by the baseline scale unless a measured
/// [typicalError] is supplied. Returns null if no dispersion is known.
double? mdc(RobustBaseline baseline, {double? typicalError}) {
  final te = typicalError ?? baseline.scale;
  // A zero scale (e.g. fully quantized/constant baseline) means we have no
  // honest estimate of the metric's noise => no MDC => never claim a change.
  if (te == null || te <= 0) return null;
  return 1.96 * math.sqrt2 * te;
}
