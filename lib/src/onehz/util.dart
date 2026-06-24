// 1 Hz-native analytics family — pure math utilities.
// dart:math only. No I/O, no clock, no randomness.
//
// All functions are pure. Where a statistic is undefined (empty input,
// degenerate variance), they return null rather than a fabricated value.

import 'dart:math' as math;

/// Mean, or null if empty.
double? mean(List<double> xs) {
  if (xs.isEmpty) return null;
  var s = 0.0;
  for (final x in xs) {
    s += x;
  }
  return s / xs.length;
}

/// Sample standard deviation (N-1), or null if <2 points.
double? stddev(List<double> xs) {
  if (xs.length < 2) return null;
  final m = mean(xs)!;
  var s = 0.0;
  for (final x in xs) {
    final d = x - m;
    s += d * d;
  }
  return math.sqrt(s / (xs.length - 1));
}

/// Population standard deviation (N), or null if empty.
double? stddevPop(List<double> xs) {
  if (xs.isEmpty) return null;
  final m = mean(xs)!;
  var s = 0.0;
  for (final x in xs) {
    final d = x - m;
    s += d * d;
  }
  return math.sqrt(s / xs.length);
}

/// Linear-interpolated percentile (p in [0,100]); null if empty.
double? percentile(List<double> values, double p) {
  if (values.isEmpty) return null;
  final sorted = [...values]..sort();
  if (sorted.length == 1) return sorted[0];
  final rank = (p / 100) * (sorted.length - 1);
  final lo = rank.floor();
  final hi = rank.ceil();
  if (lo == hi) return sorted[lo];
  final frac = rank - lo;
  return sorted[lo] + (sorted[hi] - sorted[lo]) * frac;
}

/// Median (linear-interpolated), or null if empty.
double? median(List<double> xs) => percentile(xs, 50);

/// Median absolute deviation, scaled to be a consistent estimator of σ for
/// normal data (× 1.4826). Returns null if empty. NOTE: on quantized data the
/// raw MAD can be 0 — callers must guard division (see [robustZ]).
double? mad(List<double> xs, {bool scaled = true}) {
  if (xs.isEmpty) return null;
  final m = median(xs)!;
  final dev = xs.map((x) => (x - m).abs()).toList();
  final raw = median(dev)!;
  return scaled ? raw * 1.4826 : raw;
}

/// Iglewicz–Hoaglin modified z-score of [x] against a sample, using
/// median + MAD. Returns null if MAD is 0 (degenerate / fully-quantized) so
/// the caller can fall back to a coarser test rather than divide by zero.
double? robustZ(double x, List<double> sample) {
  if (sample.length < 2) return null;
  final m = median(sample)!;
  final s = mad(sample);
  if (s == null || s == 0) return null;
  return (x - m) / s;
}

/// Ordinary z-score against a sample (mean+SD). Null if SD undefined or 0.
double? z(double x, List<double> sample) {
  final m = mean(sample);
  final sd = stddev(sample);
  if (m == null || sd == null || sd == 0) return null;
  return (x - m) / sd;
}

double clamp(double x, double lo, double hi) => math.max(lo, math.min(hi, x));

/// Ordinary-least-squares slope of y vs x (x defaults to 0..n-1). Null if <2.
double? olsSlope(List<double> y, [List<double>? x]) {
  final n = y.length;
  if (n < 2) return null;
  final xs = x ?? List<double>.generate(n, (i) => i.toDouble());
  final mx = mean(xs)!;
  final my = mean(y)!;
  var num = 0.0, den = 0.0;
  for (var i = 0; i < n; i++) {
    num += (xs[i] - mx) * (y[i] - my);
    den += (xs[i] - mx) * (xs[i] - mx);
  }
  return den == 0 ? null : num / den;
}

class LineFit {
  final double slope;
  final double intercept;
  const LineFit(this.slope, this.intercept);
}

/// OLS line fit (slope + intercept). Null if degenerate.
LineFit? olsFit(List<double> y, [List<double>? x]) {
  final n = y.length;
  if (n < 2) return null;
  final xs = x ?? List<double>.generate(n, (i) => i.toDouble());
  final s = olsSlope(y, xs);
  if (s == null) return null;
  final b = mean(y)! - s * mean(xs)!;
  return LineFit(s, b);
}

/// Theil–Sen robust slope estimator: median of all pairwise slopes. Robust to
/// outliers (breakdown ~29%). Null if <2 points or all x identical.
double? theilSen(List<double> y, [List<double>? x]) {
  final n = y.length;
  if (n < 2) return null;
  final xs = x ?? List<double>.generate(n, (i) => i.toDouble());
  final slopes = <double>[];
  for (var i = 0; i < n; i++) {
    for (var j = i + 1; j < n; j++) {
      final dx = xs[j] - xs[i];
      if (dx == 0) continue;
      slopes.add((y[j] - y[i]) / dx);
    }
  }
  return slopes.isEmpty ? null : median(slopes);
}

/// 6-dp rounding used for stable JSON output.
double round6(double x) {
  if (x.isNaN || x.isInfinite) return x;
  return (x * 1e6).roundToDouble() / 1e6;
}

double roundTo(double x, int decimals) {
  final f = math.pow(10, decimals).toDouble();
  return (x * f).roundToDouble() / f;
}

/// One spectral estimate (power at an angular/ordinary frequency).
class LsPoint {
  final double freqHz;
  final double power;
  const LsPoint(this.freqHz, this.power);
}

class LombScargle {
  final List<LsPoint> spectrum;
  const LombScargle(this.spectrum);

  /// Total power = Σ P(f)·Δf (trapezoid-free rectangular sum over the grid).
  double bandPower(double loHz, double hiHz) {
    var p = 0.0;
    for (var i = 1; i < spectrum.length; i++) {
      final f = spectrum[i].freqHz;
      if (f < loHz || f >= hiHz) continue;
      final df = spectrum[i].freqHz - spectrum[i - 1].freqHz;
      p += spectrum[i].power * df;
    }
    return p;
  }

  /// Peak frequency within [loHz,hiHz], or null if no grid points there.
  double? peakFreq(double loHz, double hiHz) {
    double? best;
    var bestP = double.negativeInfinity;
    for (final pt in spectrum) {
      if (pt.freqHz < loHz || pt.freqHz > hiHz) continue;
      if (pt.power > bestP) {
        bestP = pt.power;
        best = pt.freqHz;
      }
    }
    return best;
  }
}

/// Lomb–Scargle periodogram for UNEVENLY-sampled data (Press & Rybicki 1989,
/// classic form with Horne–Baliunas normalization by data variance).
///
/// [t] sample times (any consistent unit — pass SECONDS for Hz output),
/// [y] sample values. Computed on the supplied [freqsHz] grid. The series is
/// mean-subtracted; the τ phase-offset makes the estimate time-shift
/// invariant. Returns null if <4 points or zero variance.
///
/// This operates on NATIVE sample times — no resampling — which is exactly why
/// it's the correct PSD for unevenly-sampled beat-time RR.
LombScargle? lombScargle(List<double> t, List<double> y, List<double> freqsHz) {
  final n = t.length;
  if (n < 4 || y.length != n || freqsHz.isEmpty) return null;
  final my = mean(y)!;
  final yc = [for (final v in y) v - my];
  var variance = 0.0;
  for (final v in yc) {
    variance += v * v;
  }
  variance /= (n - 1);
  if (variance <= 0) return null;

  final out = <LsPoint>[];
  for (final fHz in freqsHz) {
    final w = 2 * math.pi * fHz; // angular frequency (rad / time-unit)
    if (w == 0) {
      out.add(const LsPoint(0, 0));
      continue;
    }
    // τ: phase reference for time-shift invariance.
    var sin2 = 0.0, cos2 = 0.0;
    for (final ti in t) {
      sin2 += math.sin(2 * w * ti);
      cos2 += math.cos(2 * w * ti);
    }
    final tau = math.atan2(sin2, cos2) / (2 * w);

    var cNum = 0.0, cDen = 0.0, sNum = 0.0, sDen = 0.0;
    for (var i = 0; i < n; i++) {
      final arg = w * (t[i] - tau);
      final c = math.cos(arg);
      final s = math.sin(arg);
      cNum += yc[i] * c;
      cDen += c * c;
      sNum += yc[i] * s;
      sDen += s * s;
    }
    final term1 = cDen == 0 ? 0.0 : (cNum * cNum) / cDen;
    final term2 = sDen == 0 ? 0.0 : (sNum * sNum) / sDen;
    final power = 0.5 * (term1 + term2) / variance;
    out.add(LsPoint(fHz, power));
  }
  return LombScargle(out);
}

/// Build a linear frequency grid [loHz, hiHz] with [n] points (inclusive).
List<double> freqGrid(double loHz, double hiHz, int n) {
  if (n < 1) return const [];
  if (n == 1) return [loHz];
  final step = (hiHz - loHz) / (n - 1);
  return List<double>.generate(n, (i) => loHz + step * i);
}

/// Natural log guard: ln of a positive value, else null.
double? safeLn(double x) => x > 0 ? math.log(x) : null;
