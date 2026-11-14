import '../util.dart';

/// Mean and start epoch of a circular profile window.
class CircularWindow {
  final double value;
  final int start;
  const CircularWindow(this.value, this.start);
}

/// Best (max or min) mean over a contiguous circular window of length [w].
// Unchanged extraction of circadianNonparametric() circular L5/M10 search,
// Witting 1990 / van Someren 1999. Traversal, arithmetic and first-winner tie
// handling are unchanged.
CircularWindow bestCircularWindow(List<double> profile, int w,
    {required bool maximize}) {
  final p = profile.length;
  if (w >= p) {
    return CircularWindow(mean(profile) ?? 0, 0);
  }
  double? best;
  var bestStart = 0;
  for (var s = 0; s < p; s++) {
    var sum = 0.0;
    for (var k = 0; k < w; k++) {
      sum += profile[(s + k) % p];
    }
    final m = sum / w;
    if (best == null || (maximize ? m > best : m < best)) {
      best = m;
      bestStart = s;
    }
  }
  return CircularWindow(best ?? 0, bestStart);
}
