// FOUNDATION — robust personal baseline.
//
// median + MAD (Leys 2013; Iglewicz-Hoaglin modified-z, flag |M|>3.5), a
// MINIMUM-COUNT gate, and an MDC gate so we only surface a change beyond the
// metric's minimal detectable change (Hopkins 2000). MAD=0 is guarded for
// quantized data.
//
// NOT A COVERAGE GATE, and it used to cite Plews 2014 as if it were. Plews'
// compliance result is about ≥3 valid days PER WEEK — a fraction, with a
// denominator. [robustBaseline] is handed a list of values that are all valid
// by construction, so it has no denominator to divide by: `sufficient` can only
// ever mean "the caller passed at least minValid values". A caller that DOES
// know its window length can say so by building [RobustBaseline] itself with a
// larger [RobustBaseline.nWindow]; nothing in this file can infer it.
//
// HONESTY: insufficient coverage => baseline absent (null), never an
// optimistic guess.

import 'dart:math' as math;
import '../util.dart';

class RobustBaseline {
  final double? center; // median of the window (null if no data)
  final double? scale; // MAD (scaled to σ); null if undefined
  final int nValid;

  /// Days the window SPANNED, when the caller knows it. [robustBaseline] cannot
  /// — it receives only valid values — and sets it equal to [nValid]; a caller
  /// that constructs this directly may pass the real span.
  final int nWindow;

  /// [nValid] ≥ minValid. A minimum-COUNT gate, not a coverage fraction.
  final bool sufficient;
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
/// metric of interest). [minValid] is a MINIMUM-COUNT gate on those values —
/// see the file header for why it is not a coverage gate. Values are taken
/// as-is; pass only valid samples.
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

/// Whether [base]'s dispersion is too coarse for the instrument that produced
/// it. [quantum] is the input's own quantization step (1.0 for whole-bpm RHR,
/// 1.0 for an integer skin-temp ADC count); 0 means "not quantized, no guard".
/// TRUE = refuse; there is nothing to standardize against.
///
/// Extracted verbatim from `readiness_composite.dart`'s refusal (see that
/// file's comment for why it is NOT gated on `robustZ == null`: MAD can
/// collapse to zero on a quantized baseline whose SD is still nonzero-but-tiny
/// — a 14-night whole-bpm baseline alternating 58/59 has MAD 0.5 (robustZ
/// succeeds) but SD ~0.52, exactly the unresolvable-dispersion case this
/// exists to catch).
bool dispersionBelowQuantum(List<double> base, double quantum) {
  if (quantum <= 0) return false;
  final sd = stddev(base);
  return sd == null || sd < quantum;
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
