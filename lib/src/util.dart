// Shared pure helpers. No I/O. 1:1 port of util.ts.
import 'dart:math' as math;
import 'types.dart';

/// A worn minute usable for HR math: wrist on AND a real HR reading (>0).
bool isHrUsable(Minute m) => m.wrist_on && m.hr_avg > 0;

/// Linear-interpolated percentile (p in [0,100]) of a numeric array.
double? percentile(List<double> values, double p) {
  if (values.isEmpty) return null;
  final sorted = [...values]..sort((a, b) => a.compareTo(b));
  if (sorted.length == 1) return sorted[0];
  final rank = (p / 100) * (sorted.length - 1);
  final lo = rank.floor();
  final hi = rank.ceil();
  if (lo == hi) return sorted[lo];
  final frac = rank - lo;
  return sorted[lo] + (sorted[hi] - sorted[lo]) * frac;
}

double? median(List<double> values) => percentile(values, 50);

double clamp(double x, double lo, double hi) => math.max(lo, math.min(hi, x));

double mean(List<double> values) {
  if (values.isEmpty) return 0;
  return values.fold<double>(0, (a, b) => a + b) / values.length;
}

double stddev(List<double> values) {
  if (values.length < 2) return 0;
  final m = mean(values);
  final v =
      values.fold<double>(0, (a, b) => a + (b - m) * (b - m)) / values.length;
  return math.sqrt(v);
}

/// Least-squares slope of y vs x (x = 0..n-1 if omitted). Returns 0 if <2 points.
double linregSlope(List<double> y, [List<double>? x]) {
  final n = y.length;
  if (n < 2) return 0;
  final xs = x ?? List<double>.generate(n, (i) => i.toDouble());
  final mx = mean(xs);
  final my = mean(y);
  double num = 0;
  double den = 0;
  for (var i = 0; i < n; i++) {
    num += (xs[i] - mx) * (y[i] - my);
    den += (xs[i] - mx) * (xs[i] - mx);
  }
  return den == 0 ? 0 : num / den;
}

/// Mirror of JS Math.round: round half up toward +Infinity.
double jsRound(double x) => (x + 0.5).floorToDouble();

double round(double x, int decimals) {
  final f = math.pow(10, decimals).toDouble();
  return jsRound(x * f) / f;
}

class MaxHrResult {
  final double maxHr;
  final String source; // 'measured' | 'age'
  const MaxHrResult(this.maxHr, this.source);
}

MaxHrResult resolveMaxHr(
  List<Minute> minutes,
  Baseline baseline, [
  Profile? profile,
]) {
  if (baseline.max_hr != null && baseline.max_hr! > 0) {
    return MaxHrResult(baseline.max_hr!, 'measured');
  }

  final observed = minutes
      .where(isHrUsable)
      .fold<double>(0, (mx, m) => math.max(mx, math.max(m.hr_max, m.hr_avg)));

  if (profile?.age != null && profile!.age! > 0) {
    final ageMax = jsRound(208 - 0.7 * profile.age!);
    if (observed > ageMax) return MaxHrResult(observed, 'measured');
    return MaxHrResult(ageMax, 'age');
  }

  if (observed > 0) {
    return MaxHrResult(observed, 'age');
  }

  return const MaxHrResult(190, 'age');
}
