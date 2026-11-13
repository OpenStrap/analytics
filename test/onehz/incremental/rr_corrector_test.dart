// Contract for the streaming `RrCorrector` (foundations/rr_correction_stream).
//
// Oracle = the frozen copy of today's `correctRr` (support/correct_rr_reference
// .dart). At every prefix of the input, for any chunking and with the corrector
// saved to JSON and restored between chunks:
//
//     settled output so far ++ snapshot().tail  ==  correctRr(prefix)
//
// bit for bit (nn, nnTimes, per-beat classes, counts, cleanFraction). Settled
// output is final (a prefix of what the oracle says about the whole series),
// the settle horizon is bounded, and the checkpoint stays small.
//
// RED until RrCorrector is implemented: every test below fails with
// UnimplementedError from the stub.
import 'dart:convert';
import 'dart:math' as math;

import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

import '../support/correct_rr_reference.dart';
import '../support/rr_compare.dart';
import '../support/rr_stream_driver.dart';
import '../support/rr_synth.dart';

/// Series used by several groups. Cached: generating is cheap, the oracle runs
/// are not.
final _dirty = SynthConfig(
    seed: 23,
    hours: 0.4,
    ectopicPerMin: 2,
    missedPerMin: 1,
    extraPerMin: 1,
    noiseRunPerMin: 0.5,
    gapPerHour: 12);

void main() {
  group('every prefix', () {
    for (final seed in [3, 4]) {
      test('1 beat at a time, n = 0..260, seed $seed', () {
        final s = synthRr(SynthConfig(
            seed: seed,
            hours: 0.12,
            ectopicPerMin: 2,
            missedPerMin: 1,
            extraPerMin: 1,
            noiseRunPerMin: 0.8,
            gapPerHour: 20));
        final n = math.min(260, s.length);
        final run = RrStreamRun();
        run.expectMatchesOracle(s.rr, s.ts, 0, why: 'n=0');
        for (var i = 0; i < n; i++) {
          run.fold([s.rr[i]], [s.ts[i]]);
          run.expectMatchesOracle(s.rr, s.ts, i + 1, why: 'seed=$seed n=${i + 1}');
        }
      });
    }

    test('with a JSON save/restore between EVERY beat (n = 0..230)', () {
      final s = synthRr(const SynthConfig(
          seed: 11,
          hours: 0.1,
          ectopicPerMin: 2,
          noiseRunPerMin: 0.6,
          gapPerHour: 10));
      final n = math.min(230, s.length);
      final run = RrStreamRun();
      run.restart(); // a corrector restored from an EMPTY checkpoint
      run.expectMatchesOracle(s.rr, s.ts, 0, why: 'empty restore');
      for (var i = 0; i < n; i++) {
        run.fold([s.rr[i]], [s.ts[i]]);
        run.restart();
        run.expectMatchesOracle(s.rr, s.ts, i + 1, why: 'n=${i + 1}');
      }
    });

    test('1-beat folds over 4000 dirty beats: every alignment of a fold edge '
        'and an artefact\'s right-anchor search', () {
      final s = synthRr(const SynthConfig(
          seed: 51,
          hours: 1.2,
          ectopicPerMin: 3,
          missedPerMin: 2,
          extraPerMin: 2,
          noiseRunPerMin: 1,
          gapPerHour: 8));
      final n = math.min(4000, s.length);
      final full = correctRrReference(s.rr.sublist(0, n),
          rrTsMs: s.ts.sublist(0, n));
      final run = RrStreamRun();
      for (var i = 0; i < n; i++) {
        run.fold([s.rr[i]], [s.ts[i]]);
        if (i % 997 == 0) run.restart();
        if (i % 50 == 0) run.expectSettledIsPrefixOf(full, 'i=$i');
      }
      run.expectMatchesOracle(s.rr, s.ts, n, why: 'final');
    });
  });

  group('random chunking', () {
    final cfgs = <String, SynthConfig>{
      'clean': const SynthConfig(
          seed: 21,
          hours: 0.4,
          ectopicPerMin: 0,
          missedPerMin: 0,
          extraPerMin: 0,
          noiseRunPerMin: 0,
          gapPerHour: 0),
      'default': const SynthConfig(seed: 22, hours: 0.5),
      'dirty': _dirty,
      'backwards-ts': const SynthConfig(
          seed: 24, hours: 0.4, backwardsPerHour: 30, gapPerHour: 6),
    };
    for (final e in cfgs.entries) {
      for (final restart in [false, true]) {
        test('${e.key}, save/restore between chunks: $restart', () {
          final s = synthRr(e.value);
          final full = correctRrReference(s.rr, rrTsMs: s.ts);
          final r = math.Random(e.value.seed * 7 + (restart ? 1 : 0));
          final cuts = randomCuts(r, s.length);
          final run = RrStreamRun();
          var from = 0;
          for (var k = 0; k < cuts.length; k++) {
            final to = cuts[k];
            run.fold(s.rr.sublist(from, to), s.ts.sublist(from, to));
            from = to;
            if (restart && r.nextBool()) run.restart();
            run.expectSettledIsPrefixOf(full, '${e.key} cut=$to');
            if (k % 13 == 0 || k == cuts.length - 1) {
              run.expectMatchesOracle(s.rr, s.ts, to,
                  why: '${e.key} cut=$to');
            }
          }
        });
      }
    }

    test('chunking does not matter: 1 chunk, 7 chunks and 1-beat chunks end '
        'identical', () {
      final s = synthRr(const SynthConfig(seed: 61, hours: 0.3));
      final out = <String>[];
      for (final size in [s.length, 400, 1]) {
        final run = RrStreamRun();
        for (var at = 0; at < s.length; at += size) {
          final to = math.min(s.length, at + size);
          run.fold(s.rr.sublist(at, to), s.ts.sublist(at, to));
        }
        final snap = run.c.snapshot();
        out.add(jsonEncode([
          [...run.nn, ...snap.tailNn],
          [...run.nnTimes, ...snap.tailNnTimes],
          snap.normalCount,
          snap.droppedCount,
          snap.correctedCount,
        ]));
      }
      expect(out[1], out[0]);
      expect(out[2], out[0]);
    });
  });

  group('timestamps', () {
    test('sub-second timestamps', () {
      final s = synthRr(const SynthConfig(seed: 33, hours: 0.4, gapPerHour: 6));
      final r = math.Random(12);
      final ts = [for (final t in s.ts) t + r.nextInt(1000) + r.nextDouble()];
      final run = RrStreamRun();
      var from = 0;
      final cuts = randomCuts(r, s.length);
      for (var k = 0; k < cuts.length; k++) {
        run.fold(s.rr.sublist(from, cuts[k]), ts.sublist(from, cuts[k]));
        from = cuts[k];
        if (k % 9 == 0) run.restart();
        if (k % 9 == 0 || k == cuts.length - 1) {
          run.expectMatchesOracle(s.rr, ts, cuts[k], why: 'cut=${cuts[k]}');
        }
      }
    });

    test('no timestamps at all (the clock is the RR cumsum)', () {
      final s = synthRr(const SynthConfig(seed: 31, hours: 0.4));
      final run = RrStreamRun();
      final r = math.Random(5);
      var from = 0;
      final cuts = randomCuts(r, s.length);
      for (var k = 0; k < cuts.length; k++) {
        run.fold(s.rr.sublist(from, cuts[k]), null);
        from = cuts[k];
        if (k % 4 == 0) run.restart();
        if (k % 7 == 0 || k == cuts.length - 1) {
          run.expectMatchesOracle(s.rr, null, cuts[k], why: 'cut=${cuts[k]}');
        }
      }
    });

    test('dropouts: the clock re-anchors across a hole, also across a fold '
        'boundary and a restore', () {
      // 300 beats, a 40 s hole before beat 150, a fold edge exactly there.
      final rr = <double>[for (var i = 0; i < 300; i++) 800.0 + (i % 5) * 3];
      var t = 1.7e12;
      final ts = <double>[
        for (var i = 0; i < 300; i++) (t += rr[i] + (i == 150 ? 40000 : 0))
      ];
      for (final edge in [149, 150, 151]) {
        final run = RrStreamRun();
        run.fold(rr.sublist(0, edge), ts.sublist(0, edge));
        run.restart();
        run.fold(rr.sublist(edge), ts.sublist(edge));
        run.expectMatchesOracle(rr, ts, 300, why: 'edge=$edge');
      }
    });
  });

  group('parameters', () {
    for (final p in [
      (alpha: 5.2, win: 31, floor: 100.0, reanchor: 1000.0),
      (alpha: 4.0, win: 61, floor: 100.0, reanchor: 1000.0),
      (alpha: 5.2, win: 121, floor: 100.0, reanchor: 1000.0),
      (alpha: 6.5, win: 91, floor: 30.0, reanchor: 400.0),
      (alpha: 5.2, win: 4, floor: 0.0, reanchor: 1000.0),
      (alpha: 5.2, win: 90, floor: 100.0, reanchor: 5000.0),
    ]) {
      test('alpha=${p.alpha} win=${p.win} floor=${p.floor} '
          'reanchor=${p.reanchor}, with restore', () {
        final s = synthRr(const SynthConfig(
            seed: 41, hours: 0.4, ectopicPerMin: 1, gapPerHour: 20));
        final run = RrStreamRun.params(
            alpha: p.alpha,
            win: p.win,
            floor: p.floor,
            reanchor: p.reanchor);
        final r = math.Random(9);
        var from = 0;
        final cuts = randomCuts(r, s.length);
        for (var k = 0; k < cuts.length; k++) {
          run.fold(s.rr.sublist(from, cuts[k]), s.ts.sublist(from, cuts[k]));
          from = cuts[k];
          if (r.nextBool()) run.restart();
          if (k % 9 == 0 || k == cuts.length - 1) {
            run.expectMatchesOracle(s.rr, s.ts, cuts[k],
                alpha: p.alpha,
                win: p.win,
                floor: p.floor,
                reanchor: p.reanchor,
                why: 'cut=${cuts[k]}');
          }
        }
        // The parameters travel in the checkpoint.
        expect(run.c.alpha, p.alpha);
        expect(run.c.windowBeats, p.win);
        expect(run.c.minThresholdMs, p.floor);
        expect(run.c.reanchorGapMs, p.reanchor);
      });
    }
  });

  group('degenerate inputs', () {
    void drive(List<double> rr, List<double> ts, String why) {
      final run = RrStreamRun();
      final r = math.Random(3);
      var from = 0;
      for (final to in randomCuts(r, rr.length, sizes: [1, 2, 3, 50, 200])) {
        run.fold(rr.sublist(from, to), ts.sublist(from, to));
        from = to;
        if (r.nextInt(3) == 0) run.restart();
        run.expectMatchesOracle(rr, ts, to, why: '$why to=$to');
      }
    }

    test('constant RR (QD = 0, the floor governs, massive ties)', () {
      drive(List<double>.filled(500, 800),
          [for (var i = 0; i < 500; i++) 1.7e12 + i * 800.0], 'const');
    });

    test('constant with one outlier at start / middle / end', () {
      for (final at in [0, 1, 250, 498, 499]) {
        final rr = List<double>.filled(500, 800)..[at] = 1700;
        drive(rr, [for (var i = 0; i < 500; i++) i * 800.0], 'outlier@$at');
      }
    });

    test('artefact runs longer than the window, and alternating artefacts', () {
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
      drive(rr, [for (final v in rr) (t += v)], 'longrun');
    });

    test('artefact at beat 0 (no left anchors) and at the tail (no right)', () {
      final rr = <double>[
        2500,
        800,
        810,
        790,
        805,
        for (var i = 0; i < 300; i++) 800 + (i % 7) * 3.0,
        2500
      ];
      drive(rr, [for (var i = 0; i < rr.length; i++) i * 800.0], 'edges');
    });

    test('all artefacts: nothing is ever invented', () {
      final rr = List<double>.filled(400, 2500);
      drive(rr, [for (var i = 0; i < 400; i++) 1.7e12 + i * 2500.0], 'all');
    });

    test('n = 1, 2, 3 and just past (the < 3 beat branch hands over)', () {
      final rr = <double>[800, 810, 790, 805, 3000, 800];
      final ts = [for (var i = 0; i < 6; i++) 1.7e12 + i * 800.0];
      final run = RrStreamRun();
      for (var i = 0; i < 6; i++) {
        run.fold([rr[i]], [ts[i]]);
        run.expectMatchesOracle(rr, ts, i + 1, why: 'n=${i + 1}');
      }
      final out = RrStreamRun()
        ..fold([250, 2500], [1.7e12, 1.7e12 + 2500]);
      out.expectMatchesOracle([250, 2500], [1.7e12, 1.7e12 + 2500], 2,
          why: 'two implausible beats');
    });
  });

  group('settle horizon and state size', () {
    test('capped settled edge includes the cap decision and its left influence',
        () {
      // Dirty series: only check the bound where the oracle's FINAL classes of
      // the 5 beats just before the 90-beat look-ahead are all normal. Then no
      // artefact run is in flight at the classified edge and no lone artefact
      // is still waiting for its two right-hand anchors.
      final s = synthRr(const SynthConfig(
          seed: 23,
          hours: 1.0,
          ectopicPerMin: 0.5,
          missedPerMin: 0.2,
          extraPerMin: 0.2,
          noiseRunPerMin: 0.1,
          gapPerHour: 6));
      final full = correctRrReference(s.rr, rrTsMs: s.ts);
      expect(full.classes.where((c) => c != BeatClass.normal).length,
          greaterThan(20),
          reason: 'sanity: the series really has artefacts');
      final run = RrStreamRun();
      final r = math.Random(17);
      var checked = 0, maxLag = 0, from = 0;
      final cuts = randomCuts(r, s.length, sizes: [1, 3, 25, 90, 400]);
      var lastSettled = 0;
      for (final to in cuts) {
        run.fold(s.rr.sublist(from, to), s.ts.sublist(from, to));
        from = to;
        final settled = run.c.settledBeats;
        expect(settled, greaterThanOrEqualTo(lastSettled),
            reason: 'settledBeats never goes backwards');
        expect(settled, lessThanOrEqualTo(to));
        lastSettled = settled;
        if (to < 130) continue;
        final quiet = [
          for (var k = to - 95; k < to - 90; k++) full.classes[k]
        ].every((c) => c == BeatClass.normal);
        if (quiet) {
          checked++;
          maxLag = math.max(maxLag, to - settled);
          expect(to - settled, lessThanOrEqualTo(280),
              reason: 'to=$to settled=$settled');
        }
      }
      expect(checked, greaterThan(20), reason: 'the bound was really checked');
      // ignore: avoid_print
      print('settle lag: checked=$checked max=$maxLag beats');
    });

    test('a clean series settles right up to the look-ahead', () {
      final r = math.Random(71);
      var t = 1.7e12;
      final rr = [
        for (var i = 0; i < 1500; i++)
          (800 + 40 * math.sin(i / 9) + r.nextInt(21) - 10).roundToDouble()
      ];
      final ts = [for (final v in rr) (t += v)];
      final full = correctRrReference(rr, rrTsMs: ts);
      // The comparison below only holds if the series really is all normal.
      expect(full.classes.every((c) => c == BeatClass.normal), isTrue);
      final run = RrStreamRun();
      for (var at = 0; at < rr.length; at += 37) {
        final to = math.min(rr.length, at + 37);
        run.fold(rr.sublist(at, to), ts.sublist(at, to));
        if (to >= 91) {
          expect(to - run.c.settledBeats, lessThanOrEqualTo(248),
              reason: 'to=$to');
        }
      }
    });

    test('checkpoint is bounded: it holds the window, not the series', () {
      final s = synthRr(const SynthConfig(seed: 81, hours: 6));
      expect(s.length, greaterThan(20000));
      final run = RrStreamRun();
      var maxBytes = 0;
      var from = 0;
      for (final to in timeCuts(s.ts, 900)) {
        run.fold(s.rr.sublist(from, to), s.ts.sublist(from, to));
        from = to;
        maxBytes = math.max(maxBytes, jsonEncode(run.c.toJson()).length);
      }
      // ~4.6 KB measured in the prototype; the series would be ~300 KB.
      expect(maxBytes, lessThan(32 * 1024), reason: 'max checkpoint chars');
      // ignore: avoid_print
      print('checkpoint max: $maxBytes chars over ${s.length} beats');
    });
  });

  group('contract', () {
    test('snapshot() changes nothing: twice is equal, folding on is unaffected',
        () {
      final s = synthRr(const SynthConfig(seed: 91, hours: 0.2));
      final a = RrStreamRun(), b = RrStreamRun();
      final cut = s.length ~/ 2;
      a.fold(s.rr.sublist(0, cut), s.ts.sublist(0, cut));
      b.fold(s.rr.sublist(0, cut), s.ts.sublist(0, cut));
      final before = jsonEncode(a.c.toJson());
      final one = a.c.snapshot(), two = a.c.snapshot();
      expect(jsonEncode(a.c.toJson()), before, reason: 'checkpoint unchanged');
      expectBitIdentical(one.tailNn, two.tailNn, 'tail twice');
      // b never snapshots; both then fold the rest and must agree.
      a.fold(s.rr.sublist(cut), s.ts.sublist(cut));
      b.fold(s.rr.sublist(cut), s.ts.sublist(cut));
      expectBitIdentical(a.nn, b.nn, 'settled nn with/without snapshot');
      expect(jsonEncode(a.c.toJson()), jsonEncode(b.c.toJson()));
    });

    test('toJson survives jsonEncode/jsonDecode: restored == original', () {
      final s = synthRr(_dirty);
      final cut = s.length ~/ 2;
      final a = RrStreamRun();
      a.fold(s.rr.sublist(0, cut), s.ts.sublist(0, cut));
      final restored = RrCorrector.fromJson(jsonRoundTrip(a.c.toJson()));
      expect(jsonEncode(restored.toJson()), jsonEncode(a.c.toJson()));
      expect(restored.settledBeats, a.c.settledBeats);
      final x = a.c.fold(s.rr.sublist(cut), tsMs: s.ts.sublist(cut));
      final y = restored.fold(s.rr.sublist(cut), tsMs: s.ts.sublist(cut));
      expectBitIdentical(y.nn, x.nn, 'nn after restore');
      expectBitIdentical(y.nnTimes, x.nnTimes, 'times after restore');
      expectSameClasses(y.classes, x.classes, 'classes after restore');
    });

    test('checkpoint is versioned and typed like the other states', () {
      final json = RrCorrector().toJson();
      expect(json['version'], 2);
      expect(json['type'], 'RrCorrector');
      expect(() => RrCorrector.fromJson({...json, 'version': 1}),
          throwsFormatException);
      expect(() => RrCorrector.fromJson({...json, 'type': 'Other'}),
          throwsFormatException);
      expect(() => RrCorrector.fromJson({}), throwsFormatException);
      expect(() => RrCorrector.fromJson({'version': 1, 'type': 'RrCorrector'}),
          throwsFormatException);
    });

    test('an empty chunk is a no-op', () {
      final s = synthRr(const SynthConfig(seed: 92, hours: 0.1));
      final run = RrStreamRun();
      run.fold(s.rr.sublist(0, 300), s.ts.sublist(0, 300));
      final before = jsonEncode(run.c.toJson());
      final out = run.c.fold(const [], tsMs: const []);
      expect(out.nn, isEmpty);
      expect(out.nnTimes, isEmpty);
      expect(out.classes, isEmpty);
      expect(jsonEncode(run.c.toJson()), before);
    });

    test('a fresh corrector reports an empty series, never NaN', () {
      final snap = RrCorrector().snapshot();
      expect(snap.n, 0);
      expect(snap.tailNn, isEmpty);
      expect(snap.tailNnTimes, isEmpty);
      expect(snap.tailClasses, isEmpty);
      expect(snap.cleanFraction, 0);
      expect(snap.droppedCount, 0);
      expect(snap.correctedCount, 0);
      expect(RrCorrector().settledBeats, 0);
    });

    test('a non-finite RR is refused and leaves the corrector unchanged', () {
      for (final bad in [double.nan, double.infinity, double.negativeInfinity]) {
        final run = RrStreamRun();
        run.fold([800, 810, 790], [1.7e12, 1.7e12 + 810, 1.7e12 + 1600]);
        final before = jsonEncode(run.c.toJson());
        // Good beats BEFORE the bad one in the same chunk must not stick.
        expect(
            () => run.c.fold([805, 800, bad, 810],
                tsMs: [1.7e12 + 2400, 1.7e12 + 3200, 1.7e12 + 4000, 1.7e12 + 4800]),
            throwsArgumentError,
            reason: '$bad');
        expect(jsonEncode(run.c.toJson()), before, reason: 'unchanged $bad');
      }
    });

    test('timestamps are given on every fold or on none', () {
      final a = RrCorrector()..fold([800, 810], tsMs: [1.7e12, 1.7e12 + 810]);
      final before = jsonEncode(a.toJson());
      expect(() => a.fold([790, 805]), throwsStateError);
      expect(jsonEncode(a.toJson()), before, reason: 'unchanged by the throw');
      final b = RrCorrector()..fold([800, 810]);
      expect(() => b.fold([790, 805], tsMs: [1.0, 2.0]), throwsStateError);
    });
  });

  group('whole nights and days', () {
    test('real 8.9 h WHOOP 4 night, 15-minute passes, restore every pass', () {
      final s = realNightRr()!;
      final full = correctRrReference(s.rr, rrTsMs: s.ts);
      final cuts = timeCuts(s.ts, 900);
      final run = RrStreamRun();
      var from = 0, maxLag = 0;
      for (var k = 0; k < cuts.length; k++) {
        run.fold(s.rr.sublist(from, cuts[k]), s.ts.sublist(from, cuts[k]));
        from = cuts[k];
        run.restart();
        run.expectSettledIsPrefixOf(full, 'pass $k');
        maxLag = math.max(maxLag, cuts[k] - run.c.settledBeats);
        if (k == 7 || k == 20) {
          run.expectMatchesOracle(s.rr, s.ts, cuts[k], why: 'pass $k');
        }
      }
      run.expectMatchesOracle(s.rr, s.ts, s.length, why: 'final');
      // Final cross-check against the whole-series oracle, field by field.
      final snap = run.c.snapshot();
      expectBitIdentical([...run.nn, ...snap.tailNn], full.nn, 'night nn');
      expect(sameBits(snap.cleanFraction, full.cleanFraction), isTrue);
      expect(run.restarts, cuts.length);
      // Real nights have artefact runs; the horizon stays within a few hundred.
      expect(maxLag, lessThan(400), reason: 'max unsettled beats');
      // ignore: avoid_print
      print('real night: ${s.length} beats, ${cuts.length} passes, '
          'max unsettled=$maxLag');
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('23 h day (~96k beats), 15-minute passes, restore every pass', () {
      final s = realShapedDay();
      final full = correctRrReference(s.rr, rrTsMs: s.ts);
      final cuts = timeCuts(s.ts, 900);
      final run = RrStreamRun();
      var from = 0, maxBytes = 0, maxLag = 0;
      for (var k = 0; k < cuts.length; k++) {
        run.fold(s.rr.sublist(from, cuts[k]), s.ts.sublist(from, cuts[k]));
        from = cuts[k];
        run.restart();
        run.expectSettledIsPrefixOf(full, 'pass $k');
        maxBytes = math.max(maxBytes, jsonEncode(run.c.toJson()).length);
        maxLag = math.max(maxLag, cuts[k] - run.c.settledBeats);
        if (k == 3 || k == 20) {
          run.expectMatchesOracle(s.rr, s.ts, cuts[k], why: 'pass $k');
        }
      }
      run.expectMatchesOracle(s.rr, s.ts, s.length, why: 'final');
      expect(maxBytes, lessThan(32 * 1024), reason: 'checkpoint chars');
      expect(maxLag, lessThan(400), reason: 'max unsettled beats');
      // ignore: avoid_print
      print('day: ${s.length} beats, ${cuts.length} passes, '
          'max checkpoint=$maxBytes chars, max unsettled=$maxLag');
    }, timeout: const Timeout(Duration(minutes: 10)));
  });
}
