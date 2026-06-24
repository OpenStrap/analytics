// FOUNDATION — robust personal baseline.
//
// median + MAD (Leys 2013; Iglewicz-Hoaglin modified-z, flag |M|>3.5),
// clamped gap-aware EWMA (Roberts 1959; λ ↔ half-life), coverage-gate
// (Plews 2014: require ≥minValid of window), and a SWC/MDC gate so we only
// surface a change beyond the metric's minimal detectable change (Hopkins
// 2000). MAD=0 is guarded for quantized data.
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

/// Convert an EWMA half-life (in samples) to the smoothing factor λ.
/// λ = 1 - 2^(-1/halfLife).
double lambdaFromHalfLife(double halfLifeSamples) {
  if (halfLifeSamples <= 0) return 1;
  return 1 - math.pow(2, -1 / halfLifeSamples).toDouble();
}

class EwmaPoint {
  final double value; // smoothed estimate at this step
  final bool gap; // true if this step was a (clamped) gap fill
  const EwmaPoint(this.value, this.gap);
}

/// Gap-aware, clamped EWMA over a possibly-irregular series.
///
/// [series] (time-ordered) values with their times (ms). On a gap larger than
/// [maxGapMs], the update is CLAMPED: λ is not allowed to fully reset the
/// estimate (we cap the effective weight) and the point is flagged as a gap —
/// we never invent intervening data. λ derived from [halfLifeMs].
List<EwmaPoint> gapAwareEwma(
  List<double> timesMs,
  List<double> values, {
  required double halfLifeMs,
  double maxGapMs = 0,
}) {
  final n = values.length;
  if (n == 0 || timesMs.length != n) return const [];
  final out = <EwmaPoint>[];
  double? est;
  double? lastT;
  for (var i = 0; i < n; i++) {
    if (est == null) {
      est = values[i];
      out.add(EwmaPoint(est, false));
      lastT = timesMs[i];
      continue;
    }
    final dt = timesMs[i] - lastT!;
    // Time-aware λ: half-life expressed in ms => decay over the elapsed dt.
    var lambda = 1 - math.pow(2, -dt / halfLifeMs).toDouble();
    final isGap = maxGapMs > 0 && dt > maxGapMs;
    if (isGap) {
      // Clamp: a long gap should not let one new sample dominate. Cap λ at 0.5.
      lambda = math.min(lambda, 0.5);
    }
    est = lambda * values[i] + (1 - lambda) * est;
    out.add(EwmaPoint(est, isGap));
    lastT = timesMs[i];
  }
  return out;
}

/// Smallest Worthwhile Change (Hopkins 2000): 0.2 × between-subject SD. For an
/// n-of-1 context we use the personal baseline scale (SD-equivalent) as the
/// dispersion, so SWC = swcMultiplier × scale.
double? swc(RobustBaseline baseline, {double swcMultiplier = 0.2}) {
  if (baseline.scale == null) return null;
  return swcMultiplier * baseline.scale!;
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

/// Gate a candidate change: surface it only if |Δ| exceeds the MDC (or, when
/// no MDC is known, never claim a change). Returns true => report the change.
bool changeExceedsMdc(double delta, RobustBaseline baseline,
    {double? typicalError}) {
  final m = mdc(baseline, typicalError: typicalError);
  if (m == null) return false; // can't justify a claim => stay silent
  return delta.abs() > m;
}
