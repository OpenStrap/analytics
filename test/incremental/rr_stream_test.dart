// Oracle test: streaming RrCorrector == correctRr over the series so far.
// BIT-identical (nn, nnTimes, per-beat classes, counts, cleanFraction), for
// random chunkings, restart-from-JSON between chunks, and awkward inputs.
import 'dart:math' as math;

import 'package:openstrap_analytics/onehz.dart'
    hide RrCorrector, RrSettled, RrSnapshot, IrregularScreenState;
import 'package:test/test.dart';

import '../../tool/incremental/oracle_util.dart';
import '../../tool/incremental/rr_stream.dart';
import '../../tool/incremental/synth.dart';

class _Run {
  RrCorrector c;
  final settledNn = <double>[], settledT = <double>[];
  final classes = <int, int>{};
  _Run(this.c) {
    _hook();
  }
  void _hook() => c.debugClassSink = (g, cls) => classes[g] = cls;
  void restart() {
    c = RrCorrector.fromJson(jsonRoundTrip(c.toJson()));
    _hook();
  }

  void fold(List<double> rr, List<double>? ts) {
    final s = c.fold(rr, tsMs: ts);
    settledNn.addAll(s.nn);
    settledT.addAll(s.nnTimes);
  }
}

void _expectSame(_Run run, List<double> rr, List<double>? ts, int n,
    {double alpha = 5.2, int win = 91, String? why}) {
  final oracle = correctRr(rr.sublist(0, n),
      rrTsMs: ts?.sublist(0, n), alpha: alpha, windowBeats: win);
  final snap = run.c.snapshot(withClasses: true);
  expect(snap.n, n, reason: why);
  final nn = [...run.settledNn, ...snap.tailNn];
  final tt = [...run.settledT, ...snap.tailNnTimes];
  expect(nn, orderedEquals(oracle.nn), reason: 'nn $why');
  expect(tt, orderedEquals(oracle.nnTimesMs), reason: 'nnTimes $why');
  expect(snap.cleanFraction, oracle.cleanFraction, reason: 'clean $why');
  expect(snap.droppedCount, oracle.droppedCount, reason: 'dropped $why');
  expect(snap.correctedCount, oracle.correctedCount, reason: 'corrected $why');
  // classes: sink (final) ++ tail (provisional)
  final cl = <BeatClass>[
    for (var g = 0; g < snap.classifiedBeats; g++)
      BeatClass.values[run.classes[g]!],
    ...snap.tailClasses ?? const <BeatClass>[],
  ];
  if (n >= 3) {
    expect(cl, orderedEquals(oracle.classes), reason: 'classes $why');
  }
}

void main() {
  test('every prefix, 1 beat at a time (n = 0..260), with artefacts', () {
    for (final seed in [3, 4]) {
      final s = synthRr(SynthConfig(
          seed: seed,
          hours: 0.12,
          ectopicPerMin: 2,
          missedPerMin: 1,
          extraPerMin: 1,
          noiseRunPerMin: 0.8,
          gapPerHour: 20));
      final n = math.min(260, s.length);
      final run = _Run(RrCorrector());
      for (var i = 0; i < n; i++) {
        run.fold([s.rr[i]], [s.ts[i]]);
        _expectSame(run, s.rr, s.ts, i + 1, why: 'seed=$seed i=$i');
      }
    }
  });

  test('every prefix with a JSON restart between EVERY beat', () {
    final s = synthRr(SynthConfig(
        seed: 11,
        hours: 0.1,
        ectopicPerMin: 2,
        noiseRunPerMin: 0.6,
        gapPerHour: 10));
    final n = math.min(230, s.length);
    final run = _Run(RrCorrector());
    for (var i = 0; i < n; i++) {
      run.fold([s.rr[i]], [s.ts[i]]);
      run.restart();
      _expectSame(run, s.rr, s.ts, i + 1, why: 'i=$i');
    }
  });

  test('1-beat folds over 4000 dirty beats: settled output == oracle', () {
    // Hits every alignment between a fold boundary and an isolated artefact's
    // right-anchor search (the case a coarse chunking rarely lands on).
    final s = synthRr(const SynthConfig(
        seed: 51,
        hours: 1.2,
        ectopicPerMin: 3,
        missedPerMin: 2,
        extraPerMin: 2,
        noiseRunPerMin: 1,
        gapPerHour: 8));
    final n = math.min(4000, s.length);
    final run = _Run(RrCorrector());
    for (var i = 0; i < n; i++) {
      run.fold([s.rr[i]], [s.ts[i]]);
      if (i % 997 == 0) run.restart();
    }
    _expectSame(run, s.rr, s.ts, n, why: 'final');
  });

  group('random chunking', () {
    final cfgs = <String, SynthConfig>{
      'clean': const SynthConfig(
          seed: 21,
          hours: 1.5,
          ectopicPerMin: 0,
          missedPerMin: 0,
          extraPerMin: 0,
          noiseRunPerMin: 0,
          gapPerHour: 0),
      'default': const SynthConfig(seed: 22, hours: 2),
      'dirty': const SynthConfig(
          seed: 23,
          hours: 1.5,
          ectopicPerMin: 2,
          missedPerMin: 1,
          extraPerMin: 1,
          noiseRunPerMin: 0.5,
          gapPerHour: 12),
      'backwards-ts': const SynthConfig(
          seed: 24, hours: 1.5, backwardsPerHour: 30, gapPerHour: 6),
    };
    for (final e in cfgs.entries) {
      for (final restart in [false, true]) {
        test('${e.key} restart=$restart', () {
          final s = synthRr(e.value);
          final r = math.Random(e.value.seed * 7 + (restart ? 1 : 0));
          final cuts = randomCuts(r, s.length);
          final run = _Run(RrCorrector());
          var from = 0;
          var maxLag = 0;
          for (var k = 0; k < cuts.length; k++) {
            final to = cuts[k];
            run.fold(s.rr.sublist(from, to), s.ts.sublist(from, to));
            from = to;
            maxLag = math.max(maxLag, to - run.c.settledBeats);
            if (restart && r.nextBool()) run.restart();
            if (k % 11 == 0 || k == cuts.length - 1) {
              _expectSame(run, s.rr, s.ts, to, why: '${e.key} cut=$to');
            }
          }
          // buffer is bounded: not the whole series
          expect(run.c.bufferedBeats, lessThan(2000));
          // ignore: avoid_print
          print('${e.key}: beats=${s.length} folds=${cuts.length} '
              'max unsettled lag=$maxLag beats');
        });
      }
    }
  });

  test('sub-second beat timestamps (non-integer ms) stream identically', () {
    final s = synthRr(const SynthConfig(seed: 33, hours: 1, gapPerHour: 6));
    final r = math.Random(12);
    final ts = [for (final t in s.ts) t + r.nextInt(1000) + r.nextDouble()];
    final run = _Run(RrCorrector());
    var from = 0;
    for (final to in randomCuts(r, s.length)) {
      run.fold(s.rr.sublist(from, to), ts.sublist(from, to));
      from = to;
      if (to % 4 == 0 || to == s.length) _expectSame(run, s.rr, ts, to, why: 'to=$to');
    }
    _expectSame(run, s.rr, ts, s.length);
  });

  test('no timestamps (null ts) streams identically', () {
    final s = synthRr(const SynthConfig(seed: 31, hours: 1));
    final run = _Run(RrCorrector());
    final r = math.Random(5);
    var from = 0;
    for (final to in randomCuts(r, s.length)) {
      run.fold(s.rr.sublist(from, to), null);
      from = to;
      if (to % 3 == 0 || to == s.length) {
        _expectSame(run, s.rr, null, to, why: 'to=$to');
      }
    }
    _expectSame(run, s.rr, null, s.length);
  });

  for (final p in [
    (alpha: 5.2, win: 31),
    (alpha: 4.0, win: 61),
    (alpha: 5.2, win: 121),
    (alpha: 6.5, win: 91),
  ]) {
    test('params alpha=${p.alpha} win=${p.win}', () {
      final s = synthRr(const SynthConfig(seed: 41, hours: 1, ectopicPerMin: 1));
      final run =
          _Run(RrCorrector(alpha: p.alpha, windowBeats: p.win));
      final r = math.Random(9);
      var from = 0;
      for (final to in randomCuts(r, s.length)) {
        run.fold(s.rr.sublist(from, to), s.ts.sublist(from, to));
        from = to;
        if (to % 5 == 0 || to == s.length) {
          _expectSame(run, s.rr, s.ts, to,
              alpha: p.alpha, win: p.win, why: 'to=$to');
        }
      }
      _expectSame(run, s.rr, s.ts, s.length, alpha: p.alpha, win: p.win);
    });
  }

  group('degenerate inputs', () {
    void drive(List<double> rr, List<double> ts, String why) {
      final run = _Run(RrCorrector());
      final r = math.Random(3);
      var from = 0;
      for (final to in randomCuts(r, rr.length, sizes: [1, 2, 3, 50, 200])) {
        run.fold(rr.sublist(from, to), ts.sublist(from, to));
        from = to;
        _expectSame(run, rr, ts, to, why: '$why to=$to');
      }
    }

    test('constant RR (QD = 0, floor governs, massive ties)', () {
      final rr = List<double>.filled(500, 800);
      drive(rr, [for (var i = 0; i < 500; i++) 1.7e12 + i * 800.0], 'const');
    });
    test('constant with one outlier at start / middle / end', () {
      for (final at in [0, 1, 250, 498, 499]) {
        final rr = List<double>.filled(500, 800)..[at] = 1700;
        drive(rr, [for (var i = 0; i < 500; i++) i * 800.0], 'outlier@$at');
      }
    });
    test('long artefact runs (>90 beats) and alternating artefacts', () {
      final r = math.Random(5);
      final rr = <double>[
        for (var i = 0; i < 700; i++)
          (i >= 150 && i < 290)
              ? 250 + r.nextInt(2000).toDouble()
              : (i >= 400 && i < 500 && i.isEven)
                  ? 2200
                  : 800 + r.nextInt(40).toDouble()
      ];
      var t = 0.0;
      final ts = [
        for (final v in rr) (t += v)
      ];
      drive(rr, ts, 'longrun');
    });
    test('artefact beat 0 and 1 (no left anchors), tail artefact (no right)', () {
      final rr = <double>[2500, 800, 810, 790, 805, for (var i = 0; i < 300; i++) 800 + (i % 7) * 3.0, 2500];
      drive(rr, [for (var i = 0; i < rr.length; i++) i * 800.0], 'edges');
    });
    test('n = 1, 2, 3 transitions', () {
      final rr = <double>[800, 810, 790, 805, 3000, 800];
      drive(rr, [for (var i = 0; i < rr.length; i++) i * 800.0], 'tiny');
    });
  });

  test('REAL 8.9 h night: 15-min folds, restart each, 6 checkpoints', () {
    final s = realNightRr()!;
    final cuts = timeCuts(s.ts, 900);
    final run = _Run(RrCorrector());
    var from = 0;
    final checks = <int>{0, cuts.length ~/ 5, cuts.length ~/ 2, cuts.length - 2,
        cuts.length - 1};
    for (var k = 0; k < cuts.length; k++) {
      run.fold(s.rr.sublist(from, cuts[k]), s.ts.sublist(from, cuts[k]));
      from = cuts[k];
      run.restart();
      if (checks.contains(k)) {
        _expectSame(run, s.rr, s.ts, cuts[k], why: 'real k=$k');
      }
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
