// cardioEpochFeatures (round 15, phase 0) - RED until the implementation lands.
//
// ASSUMED API (derived from reading cardioStager; the implementer may change
// the CALL SHAPE below, never the assertions):
//
//   CardioEpochFeatures cardioEpochFeatures(
//     List<double> hr1hz,
//     List<AccelSample> accel, {
//     List<double> rrMs = const [],
//     List<double> rrTsMs = const [],
//     int epochSec = 30,
//     int startEpoch = 0,   // first epoch row to compute (inclusive)
//     int? endEpoch,        // one past the last row; null = through nEpoch
//   });
//
// Same inputs as `cardioStager` (so the stager is literally
// `classifyCardioEpochs(cardioEpochFeatures(...), ...)`). The whole-night inputs
// stay whole: the epoch grid (cadence, perEpoch, nEpoch = n ~/ perEpoch) is
// derived from them exactly as today, and [startEpoch, endEpoch) only selects
// which rows are computed, clamped to [0, nEpoch]. Row k of a sub-range call is
// epoch startEpoch + k of the full call. When the whole input cannot be staged
// (cadence abstain, nEpoch < 3) the result has zero-length lists for any range.
//
// Pinned by this file:
//  1. cardioStager(...) == classifyCardioEpochs(cardioEpochFeatures(...))
//     on every result field, bit for bit.
//  2. rows for random sub-ranges [a, b) == rows a..b-1 of the full computation,
//     all seven feature lists, bit for bit (NaN-ness included).

import 'dart:math' as math;

import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

bool sameD(double a, double b) {
  if (a.isNaN || b.isNaN) return a.isNaN && b.isNaN;
  return a == b && a.isNegative == b.isNegative;
}

Map<String, List<double>> cols(CardioEpochFeatures f) => {
      'motion': f.motion,
      'hr': f.hr,
      'hrSd': f.hrSd,
      'rmssd': f.rmssd,
      'lfhf': f.lfhf,
      'rk': f.rk,
      'sdnn': f.sdnn,
    };

void expectRowsEqual(
    CardioEpochFeatures sub, CardioEpochFeatures full, int a, int b, String ctx) {
  final s = cols(sub), f = cols(full);
  for (final k in s.keys) {
    expect(s[k]!.length, b - a, reason: '$ctx $k length for [$a,$b)');
    for (var i = 0; i < b - a; i++) {
      if (!sameD(s[k]![i], f[k]![a + i])) {
        fail('$ctx $k row ${a + i} of [$a,$b): ${s[k]![i]} vs ${f[k]![a + i]}');
      }
    }
  }
}

void expectSameStager(CardioStagerResult a, CardioStagerResult b) {
  expect(a.base.stages, b.base.stages);
  expect(a.base.epochSec, b.base.epochSec);
  expect(sameD(a.base.wakePct, b.base.wakePct), isTrue);
  expect(sameD(a.base.nremPct, b.base.nremPct), isTrue);
  expect(sameD(a.base.remPct, b.base.remPct), isTrue);
  expect(a.deepFlag, b.deepFlag);
  expect(sameD(a.confidence, b.confidence), isTrue);
}

({List<double> hr, List<AccelSample> accel, List<double> rr, List<double> rrTs})
    genNight(
  int seed,
  int seconds, {
  int cadenceSec = 1,
  bool nanAccel = false,
  bool hrDropouts = false,
  bool rrOutliers = false,
  bool withRr = true,
}) {
  final r = math.Random(seed);
  final n = seconds ~/ cadenceSec;
  final hr = <double>[];
  final accel = <AccelSample>[];
  final rr = <double>[];
  final rrTs = <double>[];
  var posture = 1.0;
  var moveLeft = 0;
  var hrBase = 62.0;
  for (var i = 0; i < n; i++) {
    final ts = i * cadenceSec * 1000.0;
    if (r.nextInt(900) == 0) posture = 0.95 + r.nextDouble() * 0.1;
    if (moveLeft == 0 && r.nextInt(500) == 0) moveLeft = 5 + r.nextInt(40);
    var m = posture + (r.nextDouble() - 0.5) * 0.002;
    if (moveLeft > 0) {
      m += r.nextDouble() * 0.3;
      moveLeft--;
    }
    if (r.nextInt(2000) == 0) hrBase = 52 + r.nextDouble() * 25;
    final cyc = 4 * math.sin(2 * math.pi * i * cadenceSec / 5400.0);
    var h = hrBase + cyc + (r.nextDouble() - 0.5) * 4;
    if (moveLeft > 0) h += 12;
    if (hrDropouts && (i ~/ 200) % 7 == 3) h = 0;
    if (hrDropouts && r.nextInt(300) == 0) h = double.nan;
    hr.add(h);
    var gx = m * 0.6;
    final gy = m * 0.64, gz = m * 0.48;
    if (nanAccel && r.nextInt(400) == 0) gx = double.nan;
    accel.add(AccelSample(ts, gx, gy, gz));
    if (withRr) {
      final nb = h.isNaN || h <= 0 ? 0 : (h * cadenceSec / 60).round();
      for (var b = 0; b < nb; b++) {
        var v = 60000.0 / h +
            (r.nextDouble() - 0.5) * 60 +
            40 * math.sin(2 * math.pi * i * cadenceSec / 25.0);
        if (rrOutliers && r.nextInt(60) == 0) {
          v = r.nextBool() ? 150 : 2600;
        } else if (rrOutliers && r.nextInt(80) == 0) {
          v += 350;
        }
        rr.add(v);
        rrTs.add(ts);
      }
    }
  }
  return (hr: hr, accel: accel, rr: rr, rrTs: rrTs);
}

void main() {
  group('stager entry point == classify(features)', () {
    void check(String name, int seed, int seconds,
        {int cadenceSec = 1,
        bool nanAccel = false,
        bool hrDropouts = false,
        bool rrOutliers = false,
        bool withRr = true,
        int epochSec = 30}) {
      test(name, () {
        final g = genNight(seed, seconds,
            cadenceSec: cadenceSec,
            nanAccel: nanAccel,
            hrDropouts: hrDropouts,
            rrOutliers: rrOutliers,
            withRr: withRr);
        final viaStager = cardioStager(g.hr, g.accel,
            rrMs: g.rr, rrTsMs: g.rrTs, epochSec: epochSec);
        final feats = cardioEpochFeatures(g.hr, g.accel,
            rrMs: g.rr, rrTsMs: g.rrTs, epochSec: epochSec);
        final viaParts = classifyCardioEpochs(feats, epochSec: epochSec);
        expectSameStager(viaStager, viaParts);
      });
    }

    check('40 min with RR', 61, 2400);
    check('50 min, outliers + dropouts', 62, 3000,
        rrOutliers: true, hrDropouts: true);
    check('40 min, NaN accel', 63, 2400, nanAccel: true);
    check('40 min without RR', 64, 2400, withRr: false);
    check('10 s cadence', 65, 5400, cadenceSec: 10);
    check('epochSec 60', 66, 2400, epochSec: 60);
    check('5 s cadence abstains', 67, 3600, cadenceSec: 5);
    check('2 epochs abstains', 68, 70);
  });

  group('feature rows', () {
    test('full call has one row per epoch in all seven lists', () {
      final g = genNight(71, 2400);
      final f = cardioEpochFeatures(g.hr, g.accel, rrMs: g.rr, rrTsMs: g.rrTs);
      expect(f.motion.length, 2400 ~/ 30);
      for (final c in cols(f).values) {
        expect(c.length, 80);
      }
    });

    test('abstaining inputs give zero-length rows for any range', () {
      final g = genNight(72, 70);
      final f = cardioEpochFeatures(g.hr, g.accel, rrMs: g.rr, rrTsMs: g.rrTs);
      expect(f.length, 0);
      final f2 = cardioEpochFeatures(g.hr, g.accel,
          rrMs: g.rr, rrTsMs: g.rrTs, startEpoch: 0, endEpoch: 2);
      expect(f2.length, 0);
    });

    void subRanges(String name, int seed, int seconds,
        {int cadenceSec = 1,
        bool nanAccel = false,
        bool hrDropouts = false,
        bool rrOutliers = false}) {
      test(name, () {
        final g = genNight(seed, seconds,
            cadenceSec: cadenceSec,
            nanAccel: nanAccel,
            hrDropouts: hrDropouts,
            rrOutliers: rrOutliers);
        final full =
            cardioEpochFeatures(g.hr, g.accel, rrMs: g.rr, rrTsMs: g.rrTs);
        final n = full.length;
        expect(n, greaterThan(10));
        final r = math.Random(seed);
        final ranges = <List<int>>[
          [0, n],
          [0, 1],
          [n - 1, n],
          [n, n],
          [3, 3],
          [0, 0],
          [0, math.min(8, n)],
          [math.max(0, n - 8), n],
          for (var i = 0; i < 12; i++)
            () {
              final a = r.nextInt(n);
              return [a, a + r.nextInt(n - a + 1)];
            }(),
        ];
        for (final ab in ranges) {
          final sub = cardioEpochFeatures(g.hr, g.accel,
              rrMs: g.rr,
              rrTsMs: g.rrTs,
              startEpoch: ab[0],
              endEpoch: ab[1]);
          expectRowsEqual(sub, full, ab[0], ab[1], name);
        }
      });
    }

    subRanges('plain night', 81, 2700);
    subRanges('RR outliers + HR dropouts', 82, 2700,
        rrOutliers: true, hrDropouts: true);
    subRanges('NaN accel magnitudes', 83, 2700, nanAccel: true);
    subRanges('10 s cadence', 84, 5400, cadenceSec: 10);

    test('open-ended range and out-of-range bounds clamp', () {
      final g = genNight(85, 2400);
      final full =
          cardioEpochFeatures(g.hr, g.accel, rrMs: g.rr, rrTsMs: g.rrTs);
      final n = full.length;
      final tail = cardioEpochFeatures(g.hr, g.accel,
          rrMs: g.rr, rrTsMs: g.rrTs, startEpoch: 10);
      expectRowsEqual(tail, full, 10, n, 'open-ended');
      final over = cardioEpochFeatures(g.hr, g.accel,
          rrMs: g.rr, rrTsMs: g.rrTs, startEpoch: n - 5, endEpoch: n + 100);
      expectRowsEqual(over, full, n - 5, n, 'clamped end');
      final past = cardioEpochFeatures(g.hr, g.accel,
          rrMs: g.rr, rrTsMs: g.rrTs, startEpoch: n + 3, endEpoch: n + 9);
      expect(past.length, 0);
    });

    test('no RR at all: rows are NaN for rmssd/sdnn/lfhf/rk, in any range', () {
      final g = genNight(86, 2400, withRr: false);
      final sub = cardioEpochFeatures(g.hr, g.accel,
          startEpoch: 20, endEpoch: 30);
      expect(sub.length, 10);
      for (final c in [sub.rmssd, sub.sdnn, sub.lfhf, sub.rk]) {
        expect(c.every((v) => v.isNaN), isTrue);
      }
    });
  });
}
