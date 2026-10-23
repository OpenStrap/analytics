// Guard for the `correctRr` speed rewrite: the production function must stay
// BIT-IDENTICAL to a frozen copy of the implementation it replaces
// (support/correct_rr_reference.dart) — nn, nnTimesMs, per-beat classes, counts
// and cleanFraction — on synthetic, real-shaped and hostile inputs.
//
// This passes against today's implementation by construction (it IS the frozen
// copy). It is the net under the rewrite, not a failing test.
import 'dart:math' as math;

import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

import 'support/correct_rr_reference.dart';
import 'support/rr_compare.dart';
import 'support/rr_synth.dart';

void _check(List<double> rr, List<double>? ts, String why,
    {double alpha = 5.2,
    int win = 91,
    double floor = 100,
    double reanchor = 1000}) {
  final want = correctRrReference(rr,
      rrTsMs: ts,
      alpha: alpha,
      windowBeats: win,
      minThresholdMs: floor,
      reanchorGapMs: reanchor);
  final got = correctRr(rr,
      rrTsMs: ts,
      alpha: alpha,
      windowBeats: win,
      minThresholdMs: floor,
      reanchorGapMs: reanchor);
  expectSameCorrection(got, want, why);
  // The input must not be modified.
  expect(got.classes.length, rr.length, reason: '$why classes per input beat');
}

/// Timestamps for [rr] in one of several shapes. `null` = none supplied.
List<double>? _timestamps(math.Random r, List<double> rr, int mode) {
  final n = rr.length;
  var t = 1.7e12;
  switch (mode) {
    case 0:
      return null;
    case 1: // contiguous, whole-second like rec_ts*1000
      return [
        for (final v in rr) ((t += v) / 1000).floorToDouble() * 1000.0
      ];
    case 2: // dropouts of 3..600 s
      return [
        for (final v in rr)
          ((t += v + (r.nextDouble() < 0.01 ? 3000 + r.nextInt(600000) : 0)) /
                      1000)
                  .floorToDouble() *
              1000.0
      ];
    case 3: // sub-second stamps
      return [for (final v in rr) (t += v) + r.nextDouble() * 40];
    case 4: // counter-reset style: some stamps step backwards
      return [
        for (final v in rr)
          (t += v) - (r.nextDouble() < 0.02 ? 1000.0 * (1 + r.nextInt(3)) : 0)
      ];
    case 5: // length mismatch: the oracle ignores the stamps entirely
      return List<double>.filled(math.max(0, n - 1), 1.7e12);
    default: // every beat on the same stamp
      return List<double>.filled(n, 1.7e12);
  }
}

/// A hostile-ish RR series: drifting base, then bursts of every artefact shape.
List<double> _randomRr(math.Random r, int n) {
  final base = 500 + r.nextInt(700).toDouble();
  final rate = r.nextDouble() * 0.12;
  final rr = <double>[];
  var drift = 0.0;
  while (rr.length < n) {
    drift += (r.nextDouble() - .5) * 8;
    drift = drift.clamp(-200.0, 200.0);
    final v = base + drift + (r.nextDouble() - .5) * 60;
    if (r.nextDouble() < rate) {
      switch (r.nextInt(7)) {
        case 0: // ectopic + compensatory pause
          rr..add((v * .6).roundToDouble())..add((v * 1.4).roundToDouble());
        case 1: // missed beat
          rr.add((v * 2).roundToDouble());
        case 2: // extra beat
          rr..add((v * .45).roundToDouble())..add((v * .55).roundToDouble());
        case 3: // multi-beat garbage run
          for (var k = 3 + r.nextInt(12); k > 0; k--) {
            rr.add(200 + r.nextInt(2500).toDouble());
          }
        case 4: // saturated / zero / negative / absurd values
          rr.add([0.0, -50.0, 2400.0, 5000.0, 1e6][r.nextInt(5)]);
        case 5: // non-integer ms
          rr.add(v + r.nextDouble());
        default:
          rr.add(v.roundToDouble());
      }
    } else {
      rr.add(v.roundToDouble());
    }
  }
  return rr.sublist(0, n);
}

void main() {
  group('edge cases', () {
    test('empty', () {
      _check(const [], null, 'empty no ts');
      _check(const [], const [], 'empty with ts');
    });

    test('fewer than the 3 beats the dispersion estimate needs', () {
      final cases = <List<double>>[
        [800],
        [250],
        [2500],
        [300],
        [2000],
        [2001],
        [800, 810],
        [800, 250],
        [2500, 2500],
        [299, 300],
      ];
      for (final rr in cases) {
        _check(rr, null, 'short $rr no ts');
        _check(rr, [for (var i = 0; i < rr.length; i++) 1.7e12 + i * 800.0],
            'short $rr ts');
      }
    });

    test('every length around the window sizes, clean and dirty', () {
      final r = math.Random(5);
      final lengths = <int>{
        for (var n = 3; n <= 16; n++) n,
        for (final c in [31, 45, 46, 47, 90, 91, 92, 93, 135, 136, 181, 182, 183])
          for (var d = -1; d <= 1; d++) c + d,
      };
      for (final n in lengths) {
        final rr = _randomRr(r, n);
        _check(rr, null, 'n=$n no ts');
        _check(rr, _timestamps(r, rr, 2), 'n=$n ts');
      }
    });

    test('all artefacts', () {
      final r = math.Random(6);
      for (final n in [3, 4, 10, 100, 400]) {
        _check(List.filled(n, 2500.0), null, 'all long n=$n');
        _check(List.filled(n, 250.0), null, 'all short n=$n');
        final rr = [for (var i = 0; i < n; i++) 250 + r.nextInt(2250).toDouble()];
        _check(rr, null, 'random garbage n=$n');
        _check(rr, _timestamps(r, rr, 1), 'random garbage ts n=$n');
        // alternating normal / artefact: no run is ever longer than 1
        final alt = [for (var i = 0; i < n; i++) i.isEven ? 800.0 : 2500.0];
        _check(alt, null, 'alternating n=$n');
      }
    });

    test('constant RR (QD = 0: the floor governs, massive ties)', () {
      final rr = List<double>.filled(500, 800);
      _check(rr, null, 'constant');
      for (final at in [0, 1, 2, 250, 497, 498, 499]) {
        final o = List<double>.of(rr)..[at] = 1700;
        _check(o, null, 'constant + outlier@$at');
        _check(o, [for (var i = 0; i < 500; i++) 1.7e12 + i * 800.0],
            'constant + outlier@$at ts');
      }
      // two-valued series: dRR is mostly 0 with exact ties everywhere
      final two = [for (var i = 0; i < 400; i++) i % 3 == 0 ? 810.0 : 800.0];
      _check(two, null, 'two-valued');
    });

    test('artefact runs longer than the window, and at the edges', () {
      final r = math.Random(7);
      final rr = <double>[
        for (var i = 0; i < 700; i++)
          (i >= 150 && i < 290)
              ? 250 + r.nextInt(2000).toDouble()
              : (i >= 400 && i < 500 && i.isEven)
                  ? 2200
                  : 800 + r.nextInt(40).toDouble()
      ];
      _check(rr, null, 'long runs');
      _check(rr, _timestamps(r, rr, 1), 'long runs ts');
      final edges = <double>[
        2500,
        800,
        810,
        790,
        805,
        for (var i = 0; i < 300; i++) 800 + (i % 7) * 3.0,
        2500
      ];
      _check(edges, null, 'artefacts at both ends');
    });

    test('gaps, re-anchoring and timestamp shapes', () {
      final r = math.Random(8);
      final rr = _randomRr(r, 900);
      for (var mode = 0; mode <= 6; mode++) {
        _check(rr, _timestamps(r, rr, mode), 'ts mode $mode');
      }
      // a dropout exactly at, just under and just over the re-anchor slack
      for (final extra in [999.0, 1000.0, 1001.0]) {
        var t = 1.7e12;
        final ts = <double>[
          for (var i = 0; i < 300; i++)
            t += 800 + (i == 150 ? extra : 0)
        ];
        _check(List.filled(300, 800.0), ts, 'slack extra=$extra');
      }
    });

    test('rrTsMs present vs absent changes only the clock', () {
      final r = math.Random(9);
      final rr = _randomRr(r, 600);
      final ts = _timestamps(r, rr, 2)!;
      final a = correctRr(rr, rrTsMs: ts);
      final b = correctRr(rr);
      expectSameClasses(a.classes, b.classes, 'classes ignore the clock');
      expectBitIdentical(a.nn, b.nn, 'nn ignores the clock');
    });

    test('parameter grid', () {
      final r = math.Random(10);
      final rr = _randomRr(r, 450);
      final ts = _timestamps(r, rr, 2);
      for (final alpha in [5.2, 2.0, 8.0]) {
        for (final win in [1, 2, 3, 4, 31, 61, 90, 91, 92, 121, 1000]) {
          for (final floor in [100.0, 0.0, 250.0]) {
            _check(rr, ts, 'a=$alpha w=$win f=$floor',
                alpha: alpha, win: win, floor: floor);
          }
        }
      }
      for (final reanchor in [0.0, 400.0, 5000.0]) {
        _check(rr, ts, 'reanchor=$reanchor', reanchor: reanchor);
      }
    });
  });

  group('randomized', () {
    // 90 independent series: random length, artefact mix, timestamp shape and
    // parameters. Seeds are fixed so a failure names a reproducible case.
    for (var seed = 0; seed < 90; seed++) {
      test('seed $seed', () {
        final r = math.Random(1000 + seed);
        final n = [
          r.nextInt(12),
          r.nextInt(200),
          r.nextInt(900),
          r.nextInt(2500)
        ][r.nextInt(4)];
        final rr = _randomRr(r, n);
        final ts = _timestamps(r, rr, r.nextInt(7));
        final custom = r.nextInt(4) == 0;
        _check(rr, ts, 'seed=$seed n=$n',
            alpha: custom ? [3.0, 4.5, 6.5][r.nextInt(3)] : 5.2,
            win: custom ? [5, 31, 61, 121][r.nextInt(4)] : 91,
            floor: custom ? [0.0, 50.0, 150.0][r.nextInt(3)] : 100,
            reanchor: custom ? [0.0, 500.0, 3000.0][r.nextInt(3)] : 1000);
      });
    }
  });

  group('real-shaped', () {
    test('generator configs (clean, default, dirty, backwards-ts, noisy)', () {
      final cfgs = <SynthConfig>[
        const SynthConfig(
            seed: 21,
            hours: 0.5,
            ectopicPerMin: 0,
            missedPerMin: 0,
            extraPerMin: 0,
            noiseRunPerMin: 0,
            gapPerHour: 0),
        const SynthConfig(seed: 22, hours: 0.6),
        const SynthConfig(
            seed: 23,
            hours: 0.5,
            ectopicPerMin: 2,
            missedPerMin: 1,
            extraPerMin: 1,
            noiseRunPerMin: 0.5,
            gapPerHour: 12),
        const SynthConfig(
            seed: 24, hours: 0.5, backwardsPerHour: 30, gapPerHour: 6),
        const SynthConfig(
            seed: 25, hours: 0.4, noiseRunPerMin: 2, gapPerHour: 30),
      ];
      for (final c in cfgs) {
        final s = synthRr(c);
        _check(s.rr, s.ts, 'synth seed=${c.seed} ts');
        _check(s.rr, null, 'synth seed=${c.seed} no ts');
      }
    });

    test('real 8.9 h WHOOP 4 night: full, with and without timestamps', () {
      final s = realNightRr();
      expect(s, isNotNull, reason: 'real night fixture missing');
      _check(s!.rr, s.ts, 'real night ts');
      _check(s.rr, null, 'real night no ts');
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('real night prefixes (every window alignment)', () {
      final s = realNightRr()!;
      for (final n in [1, 2, 3, 4, 45, 46, 90, 91, 92, 181, 1000, 4999]) {
        _check(s.rr.sublist(0, n), s.ts.sublist(0, n), 'real prefix n=$n');
      }
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('a whole 23 h day (~96k beats)', () {
      final s = realShapedDay();
      expect(s.length, inInclusiveRange(90000, 100000));
      _check(s.rr, s.ts, 'day');
    }, timeout: const Timeout(Duration(minutes: 10)));
  });
}
