// slidingMedians (round 15, phase 0) - RED until the implementation lands.
//
// Contract (r15-phase0.md section 1): for every j,
//   out[j] == median(xs.sublist(max(0, j - halfWin), min(n - 1, j + halfWin) + 1))
// bit for bit, where `median` is util.dart's (copy + List.sort default order,
// NaN last, linear-interpolated percentile at 50).
//
// Assumed signature: List<double> slidingMedians(List<double> xs, int halfWin)
// exported from package:openstrap_analytics/onehz.dart (via util.dart).

import 'dart:math' as math;

import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

/// The definition, written independently of the implementation.
List<double> naiveSlidingMedians(List<double> xs, int halfWin) {
  final n = xs.length;
  return [
    for (var j = 0; j < n; j++)
      median(xs.sublist(
          math.max(0, j - halfWin), math.min(n - 1, j + halfWin) + 1))!
  ];
}

bool sameD(double a, double b) {
  if (a.isNaN || b.isNaN) return a.isNaN && b.isNaN;
  return a == b && a.isNegative == b.isNegative;
}

void expectBitIdentical(List<double> xs, int halfWin) {
  final got = slidingMedians(xs, halfWin);
  final want = naiveSlidingMedians(xs, halfWin);
  expect(got.length, want.length, reason: 'length xs=$xs h=$halfWin');
  for (var j = 0; j < want.length; j++) {
    if (!sameD(got[j], want[j])) {
      fail('j=$j h=$halfWin xs=$xs: got ${got[j]}, want ${want[j]}');
    }
  }
}

void main() {
  const specials = <double>[
    double.nan,
    double.infinity,
    double.negativeInfinity,
    0.0,
    -0.0,
  ];

  test('empty input and zero window', () {
    expect(slidingMedians(const [], 0), isEmpty);
    expect(slidingMedians(const [], 5), isEmpty);
    expectBitIdentical([3.5], 0);
    expectBitIdentical([3.5], 7);
    final xs = [4.0, 1.0, 9.0, 2.0];
    expect(slidingMedians(xs, 0), xs); // halfWin 0: each window is one value
  });

  test('does not mutate or alias its input', () {
    final xs = [5.0, 1.0, 4.0, 2.0, 3.0];
    final copy = List<double>.of(xs);
    final out = slidingMedians(xs, 2);
    expect(xs, copy);
    expect(identical(out, xs), isFalse);
  });

  test('exhaustive small: n 0..20, halfWin 0..12, distinct values', () {
    final r = math.Random(1);
    for (var n = 0; n <= 20; n++) {
      for (var h = 0; h <= 12; h++) {
        expectBitIdentical([for (var i = 0; i < n; i++) r.nextDouble() * 100 - 50], h);
      }
    }
  });

  test('exhaustive small: heavy ties', () {
    final r = math.Random(2);
    for (var n = 0; n <= 20; n++) {
      for (var h = 0; h <= 12; h++) {
        for (var rep = 0; rep < 3; rep++) {
          expectBitIdentical([for (var i = 0; i < n; i++) r.nextInt(3).toDouble()], h);
        }
      }
    }
  });

  test('exhaustive small: NaN, +-inf, +-0.0 mixed with ties', () {
    final r = math.Random(3);
    for (var n = 0; n <= 20; n++) {
      for (var h = 0; h <= 12; h++) {
        for (var rep = 0; rep < 4; rep++) {
          final xs = <double>[
            for (var i = 0; i < n; i++)
              r.nextInt(3) == 0
                  ? specials[r.nextInt(specials.length)]
                  : r.nextInt(4).toDouble() - 1,
          ];
          expectBitIdentical(xs, h);
        }
      }
    }
  });

  test('all-special and all-equal series', () {
    for (final v in specials) {
      for (var n = 1; n <= 9; n++) {
        for (var h = 0; h <= 5; h++) {
          expectBitIdentical(List.filled(n, v), h);
        }
      }
    }
    for (final pair in [
      [double.nan, double.infinity],
      [double.negativeInfinity, double.infinity],
      [double.negativeInfinity, double.nan],
      [-0.0, 0.0],
    ]) {
      for (var n = 2; n <= 12; n++) {
        for (var h = 0; h <= 6; h++) {
          expectBitIdentical([for (var i = 0; i < n; i++) pair[i % 2]], h);
        }
      }
    }
  });

  test('infinities make even-window interpolation NaN exactly as the definition',
      () {
    // inf - inf and (-inf) + inf in the interpolation: the result must match
    // the naive percentile arithmetic, not a "smarter" average.
    expectBitIdentical([double.infinity, double.infinity], 1);
    expectBitIdentical([double.negativeInfinity, double.infinity], 1);
    expectBitIdentical([double.negativeInfinity, double.negativeInfinity, 1.0], 1);
    expectBitIdentical([1.0, double.nan, 2.0, double.nan], 1);
  });

  test('halfWin >= n and very large halfWin', () {
    final r = math.Random(4);
    for (final n in [1, 2, 5, 17, 40]) {
      final xs = [for (var i = 0; i < n; i++) r.nextDouble()];
      for (final h in [n - 1, n, n + 1, 3 * n, 1 << 30]) {
        expectBitIdentical(xs, h);
      }
    }
  });

  test('monotone and reversed runs (window slides over sorted data)', () {
    for (final n in [10, 33]) {
      for (final h in [1, 3, 8]) {
        expectBitIdentical([for (var i = 0; i < n; i++) i.toDouble()], h);
        expectBitIdentical([for (var i = 0; i < n; i++) (n - i).toDouble()], h);
      }
    }
  });

  test('production-sized: CVHR window (halfWin 65) over 3000 s', () {
    final r = math.Random(5);
    final xs = [
      for (var i = 0; i < 3000; i++)
        900 + 60 * math.sin(i / 9.0) + (r.nextDouble() - 0.5) * 30
    ];
    expectBitIdentical(xs, 65);
    // quantised values => many ties
    expectBitIdentical([for (final x in xs) x.roundToDouble()], 65);
  });

  test('production-sized with sprinkled NaN and inf', () {
    final r = math.Random(6);
    final xs = [
      for (var i = 0; i < 1500; i++)
        r.nextInt(40) == 0
            ? specials[r.nextInt(specials.length)]
            : (r.nextDouble() * 20).roundToDouble()
    ];
    expectBitIdentical(xs, 65);
    expectBitIdentical(xs, 165);
  });
}
