// RED: RR artifact-run cap (combined bump, chunk A1).
//
// Contract:
//   * `kMaxArtifactRun == 32` is the default of `correctRr(maxArtifactRun:)` and
//     `RrCorrector(maxArtifactRun:)`; null means uncapped (today's behaviour).
//   * Every artifact run <= K  =>  output bit-identical to today's (the frozen
//     reference in support/correct_rr_reference.dart): nn, nnTimesMs, classes,
//     counts, cleanFraction.
//   * A run LONGER than K splits the series: the output is
//     correctRr(before) ++ correctRr(after), times kept absolute (the clock
//     keeps running through the run), and the run's beats are ABSENT (a gap,
//     not a correction). Each side is corrected as a series of its own, so its
//     windows do not see the run.
//   * The capped streaming `RrCorrector` equals the capped batch at every prefix
//     (settled ++ snapshot tail), for any chunking and with JSON save/restore.
//   * Its state is bounded: a checkpoint does not grow with an unbounded run.
//
// The long-run series are built so the split is unambiguous: clean integer RR,
// runs of 3000 ms beats (> 2000 is a hard artifact whatever the windows say),
// timestamps = exact cumulative sums, so every clock value is an integer and the
// comparison can be bit-exact.
import 'dart:convert';
import 'dart:math' as math;

import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

import '../support/property.dart';
import 'support/correct_rr_reference.dart';
import 'support/rr_chunking.dart';
import 'support/rr_compare.dart';
import 'support/rr_runs.dart';
import 'support/rr_synth.dart';

const _t0 = rrRunsT0;

int _longestRun(List<BeatClass> classes) {
  var best = 0, cur = 0;
  for (final c in classes) {
    cur = c == BeatClass.normal ? 0 : cur + 1;
    best = math.max(best, cur);
  }
  return best;
}

/// What the cap promises for [runs] (each longer than K): the pieces between
/// the runs corrected on their own, their times moved onto the one clock.
void _expectSplit(RrCorrectionResult got, RunSeries s, List<(int, int)> runs, String why) {
  final n = s.rr.length;
  final bounds = <(int, int)>[];
  var from = 0;
  for (final (a, b) in runs) {
    bounds.add((from, a));
    from = b;
  }
  bounds.add((from, n));
  final nn = <double>[], times = <double>[];
  for (final (a, b) in bounds) {
    final piece = correctRr(s.rr.sublist(a, b),
        rrTsMs: s.ts.sublist(a, b), maxArtifactRun: null);
    final shift = (s.ts[a] - s.rr[a]) - (s.ts[0] - s.rr[0]);
    nn.addAll(piece.nn);
    times.addAll([for (final t in piece.nnTimesMs) t + shift]);
    expectSameClasses(got.classes.sublist(a, b), piece.classes,
        '$why: classes of piece [$a, $b)');
  }
  for (final (a, b) in runs) {
    // the run's own beats sit between the pieces: artifacts, absent from nn
    expect(got.classes.sublist(a, b).every((c) => c != BeatClass.normal), isTrue,
        reason: '$why: run [$a, $b) is all artifact');
  }
  expect(got.classes.length, n, reason: '$why: one class per input beat');
  expectBitIdentical(got.nn, nn, '$why nn');
  expectBitIdentical(got.nnTimesMs, times, '$why nnTimesMs');
}

void main() {
  test('kMaxArtifactRun is 32 (2x the longest run on 18 days of real data)', () {
    expect(kMaxArtifactRun, 32);
  });

  group('runs <= K: bit-identical to today', () {
    forAll('synthetic series whose longest artifact run fits', G.intIn(1, 100000),
        (seed) {
      final s = synthRr(SynthConfig(
          seed: seed,
          hours: 0.12,
          ectopicPerMin: 1.5,
          missedPerMin: 0.8,
          extraPerMin: 0.8,
          noiseRunPerMin: 0.6,
          gapPerHour: 10));
      final want = correctRrReference(s.rr, rrTsMs: s.ts);
      final longest = _longestRun(want.classes);
      if (longest > kMaxArtifactRun) return; // another property's business
      expectSameCorrection(correctRr(s.rr, rrTsMs: s.ts), want, 'default cap');
      expectSameCorrection(
          correctRr(s.rr, rrTsMs: s.ts, maxArtifactRun: kMaxArtifactRun),
          want,
          'K = 32');
      expectSameCorrection(correctRr(s.rr, rrTsMs: s.ts, maxArtifactRun: null),
          want, 'uncapped');
      // The cap is a ceiling: K equal to the longest run changes nothing.
      expectSameCorrection(
          correctRr(s.rr, rrTsMs: s.ts, maxArtifactRun: math.max(1, longest)),
          want,
          'K = longest run ($longest)');
    }, cases: 30, budget: const Duration(seconds: 60));

    test('the checked-in real night and a real-shaped day', () {
      final night = realNightRr()!;
      final day = realShapedDay();
      for (final (name, d) in [('night', night), ('day', day)]) {
        final want = correctRrReference(d.rr, rrTsMs: d.ts);
        expect(_longestRun(want.classes), lessThanOrEqualTo(kMaxArtifactRun),
            reason: '$name: precondition, no run over the cap');
        expectSameCorrection(correctRr(d.rr, rrTsMs: d.ts), want, name);
      }
    });

    test('a run of exactly K is still corrected the old way (dropped, no split)', () {
      final (s, runs) = withRuns(5, [300, 300], [kMaxArtifactRun], nearRun: true);
      expect(runs.single.$2 - runs.single.$1, kMaxArtifactRun);
      expectSameCorrection(correctRr(s.rr, rrTsMs: s.ts),
          correctRrReference(s.rr, rrTsMs: s.ts), 'run == K');
    });
  });

  group('a run longer than K is a gap', () {
    test('K + 1 splits the series', () {
      final (s, runs) = withRuns(6, [300, 300], [kMaxArtifactRun + 1]);
      _expectSplit(correctRr(s.rr, rrTsMs: s.ts), s, runs, 'K+1');
    });

    test('one 40-beat run, clean sides', () {
      final (s, runs) = withRuns(7, [360, 360], [40]);
      _expectSplit(correctRr(s.rr, rrTsMs: s.ts), s, runs, '40-run');
    });

    test('isolated artifacts 20 beats either side of the run are judged without '
        'the run in their window', () {
      final (s, runs) = withRuns(8, [360, 360], [40], nearRun: true);
      _expectSplit(correctRr(s.rr, rrTsMs: s.ts), s, runs, 'near-run artifacts');
    });

    for (final seed in [11, 12, 13, 14, 15, 16]) {
      test('two long runs, random lengths and sides (seed $seed)', () {
        final r = Rng(seed);
        final (s, runs) = withRuns(
            seed,
            [r.intIn(150, 400), r.intIn(150, 400), r.intIn(150, 400)],
            [r.intIn(33, 90), r.intIn(33, 90)],
            nearRun: r.nextBool());
        _expectSplit(correctRr(s.rr, rrTsMs: s.ts), s, runs, 'seed $seed');
      });
    }

    test('an explicit smaller K splits at that K', () {
      final (s, runs) = withRuns(9, [300, 300], [6]);
      _expectSplit(correctRr(s.rr, rrTsMs: s.ts, maxArtifactRun: 5), s, runs, 'K=5');
      // ...and the same run is under the default cap: not a split.
      expectSameCorrection(correctRr(s.rr, rrTsMs: s.ts),
          correctRrReference(s.rr, rrTsMs: s.ts), 'K=32 keeps the 6-run');
    });

    test('uncapped (null) still drops the run and keeps one series', () {
      final (s, _) = withRuns(10, [300, 300], [40]);
      expectSameCorrection(correctRr(s.rr, rrTsMs: s.ts, maxArtifactRun: null),
          correctRrReference(s.rr, rrTsMs: s.ts), 'null');
    });
  });

  group('streaming RrCorrector with the cap', () {
    void expectPrefix(RrCorrector c, List<double> nn, List<double> times,
        List<BeatClass> classes, RunSeries s, int n, int k, String why) {
      final snap = c.snapshot();
      final want = correctRr(s.rr.sublist(0, n),
          rrTsMs: s.ts.sublist(0, n), maxArtifactRun: k);
      expectBitIdentical([...nn, ...snap.tailNn], want.nn, '$why nn');
      expectBitIdentical([...times, ...snap.tailNnTimes], want.nnTimesMs, '$why t');
      expectSameClasses([...classes, ...snap.tailClasses], want.classes, why);
      expect(snap.droppedCount, want.droppedCount, reason: '$why dropped');
      expect(snap.correctedCount, want.correctedCount, reason: '$why corrected');
      expect(sameBits(snap.cleanFraction, want.cleanFraction), isTrue,
          reason: '$why cleanFraction');
    }

    for (final k in [32, 5]) {
      test('one beat at a time, every prefix, K = $k, a 40-beat run in the middle', () {
        final (s, _) = withRuns(21, [110, 110], [40], nearRun: true);
        final c = RrCorrector(maxArtifactRun: k);
        final nn = <double>[], times = <double>[];
        final classes = <BeatClass>[];
        for (var i = 0; i < s.rr.length; i++) {
          final out = c.fold([s.rr[i]], tsMs: [s.ts[i]]);
          nn.addAll(out.nn);
          times.addAll(out.nnTimes);
          classes.addAll(out.classes);
          expectPrefix(c, nn, times, classes, s, i + 1, k, 'K=$k n=${i + 1}');
        }
      });
    }

    for (final seed in [31, 32, 33]) {
      test('random chunks with a JSON save/restore between them (seed $seed)', () {
        final r = Rng(seed);
        final (s, _) = withRuns(
            seed, [r.intIn(120, 250), r.intIn(120, 250)], [r.intIn(33, 70)],
            nearRun: true);
        var c = RrCorrector();
        final nn = <double>[], times = <double>[];
        final classes = <BeatClass>[];
        var at = 0;
        for (final cut in randomCuts(math.Random(seed), s.rr.length)) {
          final out = c.fold(s.rr.sublist(at, cut), tsMs: s.ts.sublist(at, cut));
          nn.addAll(out.nn);
          times.addAll(out.nnTimes);
          classes.addAll(out.classes);
          at = cut;
          c = RrCorrector.fromJson(jsonRoundTrip(c.toJson()));
          expect(c.maxArtifactRun, kMaxArtifactRun, reason: 'cap survives restore');
          expectPrefix(c, nn, times, classes, s, at, kMaxArtifactRun, 'seed $seed n=$at');
        }
      });
    }

    test('settling through a gap retains the new segment boundary', () {
      final (s, _) = withRuns(51, [300, 700], [100], nearRun: true);
      var c = RrCorrector();
      final nn = <double>[], times = <double>[];
      final classes = <BeatClass>[];
      for (var i = 0; i < s.rr.length; i++) {
        final out = c.fold([s.rr[i]], tsMs: [s.ts[i]]);
        nn.addAll(out.nn);
        times.addAll(out.nnTimes);
        classes.addAll(out.classes);
        if (i % 19 == 0 || i == s.rr.length - 1) {
          c = RrCorrector.fromJson(jsonRoundTrip(c.toJson()));
          expectPrefix(c, nn, times, classes, s, i + 1, kMaxArtifactRun,
              'across a settled gap at $i');
        }
      }
    });

    test('maxArtifactRun survives the checkpoint (a value, the default, null)', () {
      for (final k in <int?>[5, kMaxArtifactRun, null]) {
        final c = RrCorrector(maxArtifactRun: k)
          ..fold([for (var i = 0; i < 50; i++) 800.0 + i % 7],
              tsMs: [for (var i = 0; i < 50; i++) _t0 + 800.0 * i]);
        final back = RrCorrector.fromJson(jsonRoundTrip(c.toJson()));
        expect(back.maxArtifactRun, k, reason: 'K = $k');
      }
      expect(RrCorrector().maxArtifactRun, kMaxArtifactRun);
    });

    test('the checkpoint is bounded: 10,000 artifact beats do not grow it', () {
      final r = Rng(41);
      final clean = cleanRr(r, 300);
      final c = RrCorrector();
      var t = _t0;
      c.fold(clean, tsMs: [for (final v in clean) t += v]);
      final before = jsonEncode(c.toJson()).length;
      var worst = before;
      for (var fed = 0; fed < 10000; fed += 100) {
        final chunk = List.filled(100, 3000.0);
        c.fold(chunk, tsMs: [for (final v in chunk) t += v]);
        worst = math.max(worst, jsonEncode(c.toJson()).length);
      }
      expect(worst, lessThan(60000), reason: 'checkpoint chars during the run');
      expect(worst, lessThan(before * 3 + 2000),
          reason: 'does not scale with the run (started at $before)');
      // and it resumes: after the run the series is a new segment, and the
      // stream still equals the capped batch over everything it was fed.
      final tail = cleanRr(r, 300);
      final out = c.fold(tail, tsMs: [for (final v in tail) t += v]);
      final rrAll = [...clean, ...List.filled(10000, 3000.0), ...tail];
      var u = _t0;
      final all = RunSeries(rrAll, [for (final v in rrAll) u += v]);
      final want = correctRr(rrAll, rrTsMs: all.ts);
      final snap = c.snapshot();
      expect(snap.n, rrAll.length);
      expect(out.nn.length, greaterThan(0), reason: 'the tail settles');
      expect(snap.droppedCount, want.droppedCount);
      expect(snap.correctedCount, want.correctedCount);
      expect(sameBits(snap.cleanFraction, want.cleanFraction), isTrue);
    });
  });
  group('nnSourceIndex: which input beat each NN came from', () {
    void expectSources(List<double> rr, List<double> ts, String why,
        {int? cap = kMaxArtifactRun}) {
      final got = correctRr(rr, rrTsMs: ts, maxArtifactRun: cap);
      final src = got.nnSourceIndex;
      expect(src.length, got.nn.length, reason: '$why length');
      for (var k = 0; k < src.length; k++) {
        expect(src[k], inInclusiveRange(0, rr.length - 1), reason: '$why range');
        if (k > 0) expect(src[k], greaterThan(src[k - 1]), reason: '$why order');
        if (got.classes[src[k]] == BeatClass.normal) {
          expect(sameBits(got.nn[k], rr[src[k]]), isTrue, reason: '$why value');
        }
      }
      // every beat that is not a source was dropped
      expect(rr.length - src.length, got.droppedCount, reason: '$why dropped');
    }

    test('synthetic nights (corrected, dropped, gap beats)', () {
      for (final seed in [3, 23, 77]) {
        final d = synthRr(SynthConfig(
            seed: seed, hours: 0.2, ectopicPerMin: 2, missedPerMin: 1,
            extraPerMin: 1, noiseRunPerMin: 0.5, gapPerHour: 12));
        expectSources(d.rr, d.ts, 'seed $seed');
        expectSources(d.rr, d.ts, 'seed $seed uncapped', cap: null);
      }
    });

    test('over the cap, tiny inputs, and empty', () {
      final (s, runs) = withRuns(8, [120, 120, 120], [33, 45]);
      expectSources(s.rr, s.ts, 'runs');
      final src = correctRr(s.rr, rrTsMs: s.ts).nnSourceIndex;
      for (final (a, b) in runs) {
        expect(src.where((i) => i >= a && i < b), isEmpty);
      }
      for (final n in [0, 1, 2, 3, 5]) {
        expectSources(s.rr.sublist(0, n), s.ts.sublist(0, n), 'n=$n');
      }
    });

    test('a spline-corrected beat is its own source', () {
      final rr = cleanRr(Rng(5), 200);
      rr[100] = rr[100] * 0.5;
      final ts = rrSeries(rr).ts;
      final got = correctRr(rr, rrTsMs: ts);
      expect(got.correctedCount, 1);
      expect(got.nnSourceIndex, contains(100));
    });
  });
}
