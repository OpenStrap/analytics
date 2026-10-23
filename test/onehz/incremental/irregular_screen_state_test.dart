// Contract for `IrregularScreenState` (clinical/irregular_rhythm_state).
//
// Oracle = `irregularBeatScreen` on the same NN series. The state folds the NN
// that `RrCorrector` settles and is evaluated with the corrector's provisional
// tail; the Metric must match the batch call on settled ++ tail at every prefix
// and under any chunking / save-restore:
//   * present, note, tier, inputs, flag, nBeats, pNN%: identical;
//   * SD1 / SD2 / ratio / confidence: equal to 1e-9 relative (the state uses a
//     running variance, the batch a two-pass one);
//   * ABSENT exactly where the batch is absent, with the same note — a thin,
//     noisy, flat or gappy series never gets a made-up verdict.
//
// RED until the state is implemented: every test fails with UnimplementedError
// from the stub.
import 'dart:convert';
import 'dart:math' as math;

import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

import '../support/correct_rr_reference.dart';
import '../support/rr_chunking.dart';
import '../support/rr_synth.dart';

void _close(double got, double want, String why, {double rel = 1e-9}) {
  final tol = rel * math.max(1.0, want.abs());
  expect((got - want).abs(), lessThanOrEqualTo(tol),
      reason: '$why got=$got want=$want');
}

void _expectSameScreen(Metric<IrregularRhythm> got,
    Metric<IrregularRhythm> want, String why) {
  expect(got.present, want.present, reason: 'present $why');
  expect(got.note, want.note, reason: 'note $why');
  expect(got.tier, want.tier, reason: 'tier $why');
  expect(got.inputs_used, want.inputs_used, reason: 'inputs $why');
  if (!want.present) {
    expect(got.value, isNull, reason: 'absent => no value $why');
    expect(got.confidence, 0, reason: 'absent => confidence 0 $why');
    return;
  }
  final g = got.value!, w = want.value!;
  expect(g.flag, w.flag, reason: 'flag $why');
  expect(g.nBeats, w.nBeats, reason: 'nBeats $why');
  expect(g.pnnPct, w.pnnPct, reason: 'pnn $why');
  _close(g.sd1, w.sd1, 'sd1 $why');
  _close(g.sd2, w.sd2, 'sd2 $why');
  _close(g.sd1sd2, w.sd1sd2, 'sd1sd2 $why');
  _close(got.confidence, want.confidence, 'confidence $why', rel: 1e-12);
}

/// AF-like bursts (irregularly irregular RR) in [afShare] of 5..30 min blocks,
/// otherwise sinus with slow drift. Optionally salted with out-of-range beats.
({List<double> nn, List<double> t}) _fixture(int seed, double afShare,
    {double hours = 8, double outOfRange = 0}) {
  final r = math.Random(seed);
  final nn = <double>[], t = <double>[];
  var clock = 0.0;
  var af = false;
  var left = 0;
  while (clock < hours * 3600 * 1000.0) {
    if (--left <= 0) {
      af = r.nextDouble() < afShare;
      left = 300 + r.nextInt(2000);
    }
    var v = af
        ? (420 + r.nextInt(700)).toDouble()
        : (850 + 40 * math.sin(clock / 9000) + 25 * (r.nextDouble() - .5))
            .roundToDouble();
    if (r.nextDouble() < outOfRange) v = r.nextBool() ? 2500 : 250;
    clock += v;
    nn.add(v);
    t.add(clock);
  }
  return (nn: nn, t: t);
}

Metric<IrregularRhythm> _batch(List<double> nn, List<double> t, int n,
        {double af = 0.0,
        int minBeats = irregularScreenMinBeats,
        double maxArtifact = 0.30,
        double sd1sd2Flag = 0.70,
        double pnnThresholdMs = 70,
        double pnnFlagPct = 30,
        double windowMinutes = 5,
        int minWindowBeats = 40,
        double sustainedFraction = 0.5}) =>
    irregularBeatScreen(nn.sublist(0, n),
        nnTimesMs: t.sublist(0, n),
        artifactFraction: af,
        minBeats: minBeats,
        maxArtifact: maxArtifact,
        sd1sd2Flag: sd1sd2Flag,
        pnnThresholdMs: pnnThresholdMs,
        pnnFlagPct: pnnFlagPct,
        windowMinutes: windowMinutes,
        minWindowBeats: minWindowBeats,
        sustainedFraction: sustainedFraction);

void main() {
  group('folding a corrected NN series directly', () {
    for (final share in [0.0, 0.35, 0.75, 1.0]) {
      for (final restart in [false, true]) {
        test('af share=$share, save/restore between chunks: $restart', () {
          final x = _fixture((share * 100).round() + 3, share);
          var st = IrregularScreenState();
          var at = 0;
          var flags = 0, checks = 0;
          final cuts = randomCuts(math.Random(5), x.nn.length,
              sizes: [90, 500, 4000]);
          for (final cut in cuts) {
            st.fold(x.nn.sublist(at, cut), x.t.sublist(at, cut));
            at = cut;
            if (restart) {
              st = IrregularScreenState.fromJson(jsonRoundTrip(st.toJson()));
            }
            // 0.31 is over the 0.30 suppression line: must be absent.
            for (final af in [0.0, 0.31]) {
              final want = _batch(x.nn, x.t, cut, af: af);
              final got =
                  st.evaluate(const [], const [], artifactFraction: af);
              _expectSameScreen(got, want, 'cut=$cut af=$af');
              if (want.present) {
                checks++;
                if (want.value!.flag) flags++;
              }
            }
          }
          expect(checks, greaterThan(5), reason: 'screen was really evaluated');
          // ignore: avoid_print
          print('irregular share=$share: checks=$checks flagged=$flags');
          if (share >= 0.75) {
            expect(flags, greaterThan(0), reason: 'a flagged day is flagged');
          }
          if (share == 0.0) expect(flags, 0);
        });
      }
    }

    test('out-of-range beats are skipped without bridging the gap', () {
      // 2% of beats are 250 / 2500 ms. The batch never takes a difference
      // ACROSS a skipped beat; the state must not either.
      final x = _fixture(77, 0.5, hours: 4, outOfRange: 0.02);
      var st = IrregularScreenState();
      var at = 0;
      for (final cut in randomCuts(math.Random(6), x.nn.length,
          sizes: [1, 7, 90, 700])) {
        st.fold(x.nn.sublist(at, cut), x.t.sublist(at, cut));
        at = cut;
        if (cut % 3 == 0) {
          st = IrregularScreenState.fromJson(jsonRoundTrip(st.toJson()));
        }
        _expectSameScreen(st.evaluate(const [], const []),
            _batch(x.nn, x.t, cut), 'cut=$cut');
      }
    });

    test('a window edge hit EXACTLY decides the verdict (>= closes the window)',
        () {
      // Window 1: 300 s of AF-like beats whose last interval lands the next
      // beat on windowStart + 300000 EXACTLY. Window 2: calm, same trick.
      // Window 3: calm, exactly minWindowBeats (40) beats, so it only counts
      // as a window when the edge beat OPENS it. Closing on > instead of >=
      // moves that beat into window 2, window 3 falls to 39 beats and stops
      // counting, and the sustained fraction jumps from 1/3 to 1/2 (flag).
      final r = math.Random(3);
      final nn = <double>[], t = <double>[];
      var clock = 0.0;
      void add(double v) {
        clock += v;
        nn.add(v);
        t.add(clock);
      }

      void landOn(double target, double Function() next) {
        while (target - clock > 2200) {
          add(next());
        }
        var rest = target - clock;
        if (rest < 300) {
          clock -= nn.removeLast();
          t.removeLast();
          rest = target - clock;
        }
        if (rest > 2000) {
          add(rest / 2);
          add(rest / 2);
        } else {
          add(rest);
        }
      }

      add(1000); // the first beat opens window 1 at t = 1000
      landOn(301000, () => 400.0 + 100 * r.nextInt(13)); // AF-like
      double calm() => 800.0 + 10 * (r.nextInt(5) - 2);
      landOn(601000, calm);
      for (var i = 0; i < 39; i++) {
        add(calm());
      }
      expect(t.where((x) => x == 301000 || x == 601000).length, 2);
      final want = _batch(nn, t, nn.length, minBeats: 500);
      expect(want.present, isTrue, reason: 'sanity: crafted day is evaluable');
      expect(want.value!.flag, isFalse, reason: 'sanity: 1 of 3 windows flags');
      final st = IrregularScreenState();
      st.fold(nn, t);
      _expectSameScreen(st.evaluate(const [], const []), want, 'edge day');
      // and split anywhere, with a restore, including right at the edge beats
      for (final cut in [
        nn.length ~/ 2,
        t.indexOf(301000),
        t.indexOf(601000),
        t.indexOf(601000) + 1
      ]) {
        var a = IrregularScreenState()
          ..fold(nn.sublist(0, cut), t.sublist(0, cut));
        a = IrregularScreenState.fromJson(jsonRoundTrip(a.toJson()));
        a.fold(nn.sublist(cut), t.sublist(cut));
        _expectSameScreen(a.evaluate(const [], const []), want, 'cut=$cut');
      }
    });

    test('provisional tail: evaluate(tail) == batch(settled ++ tail), and '
        'leaves the state untouched', () {
      final x = _fixture(31, 0.75, hours: 3);
      final st = IrregularScreenState();
      final settled = x.nn.length - 400;
      st.fold(x.nn.sublist(0, settled), x.t.sublist(0, settled));
      final before = jsonEncode(st.toJson());
      for (final tailLen in [0, 1, 50, 399, 400]) {
        final to = settled + tailLen;
        final got = st.evaluate(x.nn.sublist(settled, to), x.t.sublist(settled, to));
        _expectSameScreen(got, _batch(x.nn, x.t, to), 'tail=$tailLen');
        expect(jsonEncode(st.toJson()), before,
            reason: 'evaluate must not fold the tail into the state');
      }
      // Fold the tail for real afterwards: still the batch answer.
      st.fold(x.nn.sublist(settled), x.t.sublist(settled));
      _expectSameScreen(st.evaluate(const [], const []),
          _batch(x.nn, x.t, x.nn.length), 'tail folded');
    });
  });

  group('absent where the batch is absent (never fabricated)', () {
    test('every prefix 0..700, one beat at a time: thin, then present', () {
      final x = _fixture(12, 0.6, hours: 1);
      final st = IrregularScreenState();
      var present = 0, absent = 0;
      for (var i = 0; i < 700; i++) {
        st.fold([x.nn[i]], [x.t[i]]);
        final want = _batch(x.nn, x.t, i + 1);
        final got = st.evaluate(const [], const []);
        _expectSameScreen(got, want, 'n=${i + 1}');
        want.present ? present++ : absent++;
      }
      expect(absent, greaterThan(400), reason: 'thin prefixes were exercised');
      expect(present, greaterThan(100), reason: 'and then it speaks');
    });

    test('a smaller beat floor and every prefix 0..120', () {
      final x = _fixture(13, 1.0, hours: 1);
      final st = IrregularScreenState();
      for (var i = 0; i < 120; i++) {
        st.fold([x.nn[i]], [x.t[i]]);
        _expectSameScreen(
            st.evaluate(const [], const [], minBeats: 20),
            _batch(x.nn, x.t, i + 1, minBeats: 20),
            'minBeats=20 n=${i + 1}');
      }
    });

    test('artifact fraction at / over the line, absent with the same note', () {
      final x = _fixture(14, 0.5, hours: 2);
      final st = IrregularScreenState()..fold(x.nn, x.t);
      for (final af in [0.0, 0.29, 0.30, 0.3000001, 0.31, 0.5, 1.0]) {
        _expectSameScreen(st.evaluate(const [], const [], artifactFraction: af),
            _batch(x.nn, x.t, x.nn.length, af: af), 'af=$af');
      }
      for (final cap in [0.1, 0.5]) {
        _expectSameScreen(
            st.evaluate(const [], const [],
                artifactFraction: 0.2, maxArtifact: cap),
            _batch(x.nn, x.t, x.nn.length, af: 0.2, maxArtifact: cap),
            'maxArtifact=$cap');
      }
    });

    test('flat series: SD2 = 0 is "undefined", not "perfectly regular"', () {
      final nn = List<double>.filled(900, 800);
      final t = [for (var i = 1; i <= 900; i++) i * 800.0];
      final got = (IrregularScreenState()..fold(nn, t))
          .evaluate(const [], const []);
      final want = _batch(nn, t, 900);
      expect(want.present, isFalse, reason: 'the oracle abstains');
      _expectSameScreen(got, want, 'flat');
    });

    test('no two adjacent clean beats: nothing to build a Poincare plot from',
        () {
      // every other beat out of range: 300 clean beats, zero adjacent pairs.
      final nn = [for (var i = 0; i < 600; i++) i.isEven ? 800.0 : 250.0];
      final t = [for (var i = 1; i <= 600; i++) i * 800.0];
      final got = (IrregularScreenState()..fold(nn, t))
          .evaluate(const [], const [], minBeats: 5);
      final want = _batch(nn, t, 600, minBeats: 5);
      expect(want.present, isFalse);
      _expectSameScreen(got, want, 'no adjacent pairs');
    });

    test('empty state', () {
      _expectSameScreen(IrregularScreenState().evaluate(const [], const []),
          _batch(const [], const [], 0), 'empty');
    });
  });

  group('parameters', () {
    test('non-default thresholds and windows, with restore', () {
      final x = _fixture(21, 0.4, hours: 3);
      final params = (
        sd1sd2Flag: 0.5,
        pnnThresholdMs: 50.0,
        pnnFlagPct: 20.0,
        windowMinutes: 2.0,
        minWindowBeats: 20,
        sustainedFraction: 0.3
      );
      var st = IrregularScreenState(
          sd1sd2Flag: params.sd1sd2Flag,
          pnnThresholdMs: params.pnnThresholdMs,
          pnnFlagPct: params.pnnFlagPct,
          windowMinutes: params.windowMinutes,
          minWindowBeats: params.minWindowBeats,
          sustainedFraction: params.sustainedFraction);
      var at = 0;
      for (final cut in randomCuts(math.Random(8), x.nn.length,
          sizes: [100, 900, 3000])) {
        st.fold(x.nn.sublist(at, cut), x.t.sublist(at, cut));
        at = cut;
        st = IrregularScreenState.fromJson(jsonRoundTrip(st.toJson()));
        _expectSameScreen(
            st.evaluate(const [], const []),
            _batch(x.nn, x.t, cut,
                sd1sd2Flag: params.sd1sd2Flag,
                pnnThresholdMs: params.pnnThresholdMs,
                pnnFlagPct: params.pnnFlagPct,
                windowMinutes: params.windowMinutes,
                minWindowBeats: params.minWindowBeats,
                sustainedFraction: params.sustainedFraction),
            'cut=$cut');
      }
      // The parameters travel in the checkpoint.
      expect(st.sd1sd2Flag, params.sd1sd2Flag);
      expect(st.pnnThresholdMs, params.pnnThresholdMs);
      expect(st.pnnFlagPct, params.pnnFlagPct);
      expect(st.windowMinutes, params.windowMinutes);
      expect(st.minWindowBeats, params.minWindowBeats);
      expect(st.sustainedFraction, params.sustainedFraction);
    });

    test('a bad window config fails CLOSED: never a flag', () {
      // AF all day, so the aggregate verdict is high; only the sustained-window
      // check can hold the flag back, and a broken config must hold it back.
      final x = _fixture(22, 1.0, hours: 2);
      final base = _batch(x.nn, x.t, x.nn.length);
      expect(base.present && base.value!.flag, isTrue,
          reason: 'sanity: the default config flags this day');
      for (final bad in <IrregularScreenState>[
        IrregularScreenState(windowMinutes: 0),
        IrregularScreenState(windowMinutes: -5),
        IrregularScreenState(windowMinutes: double.nan),
        IrregularScreenState(minWindowBeats: 1),
        IrregularScreenState(sustainedFraction: 1.5),
        IrregularScreenState(sustainedFraction: -0.1),
        IrregularScreenState(sustainedFraction: double.nan),
      ]) {
        bad.fold(x.nn, x.t);
        final want = _batch(x.nn, x.t, x.nn.length,
            windowMinutes: bad.windowMinutes,
            minWindowBeats: bad.minWindowBeats,
            sustainedFraction: bad.sustainedFraction);
        final got = bad.evaluate(const [], const []);
        expect(want.present && !want.value!.flag, isTrue,
            reason: 'oracle fails closed');
        _expectSameScreen(got, want,
            'window=${bad.windowMinutes} minBeats=${bad.minWindowBeats} '
            'sustained=${bad.sustainedFraction}');
      }
    });
  });

  group('behind RrCorrector (the way the pipeline will use it)', () {
    test('6 h dirty day, 15-minute passes, both states restored every pass',
        () {
      final s = synthRr(const SynthConfig(
          seed: 5,
          hours: 6,
          ectopicPerMin: 0.8,
          missedPerMin: 0.3,
          extraPerMin: 0.3,
          noiseRunPerMin: 0.1,
          gapPerHour: 4));
      final cuts = timeCuts(s.ts, 900);
      var corrector = RrCorrector();
      var st = IrregularScreenState();
      var from = 0, present = 0, maxBytes = 0;
      for (var k = 0; k < cuts.length; k++) {
        final settled = corrector.fold(s.rr.sublist(from, cuts[k]),
            tsMs: s.ts.sublist(from, cuts[k]));
        from = cuts[k];
        st.fold(settled.nn, settled.nnTimes);
        corrector = RrCorrector.fromJson(jsonRoundTrip(corrector.toJson()));
        st = IrregularScreenState.fromJson(jsonRoundTrip(st.toJson()));
        maxBytes = math.max(maxBytes, jsonEncode(st.toJson()).length);
        if (k % 4 != 0 && k != cuts.length - 1) continue;
        final snap = corrector.snapshot();
        final ref = correctRrReference(s.rr.sublist(0, cuts[k]),
            rrTsMs: s.ts.sublist(0, cuts[k]));
        final af = (1.0 - ref.cleanFraction).clamp(0.0, 1.0).toDouble();
        final want = irregularBeatScreen(ref.nn,
            nnTimesMs: ref.nnTimesMs, artifactFraction: af);
        final got = st.evaluate(snap.tailNn, snap.tailNnTimes,
            artifactFraction: 1.0 - snap.cleanFraction);
        _expectSameScreen(got, want, 'pass $k n=${cuts[k]}');
        if (want.present) present++;
      }
      expect(present, greaterThan(3), reason: 'the screen was really run');
      expect(maxBytes, lessThan(16 * 1024), reason: 'checkpoint chars');
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('23 h day: final screen equals the batch screen on the whole day', () {
      final s = realShapedDay();
      final cuts = timeCuts(s.ts, 900);
      final corrector = RrCorrector();
      final st = IrregularScreenState();
      var from = 0;
      for (final to in cuts) {
        final settled =
            corrector.fold(s.rr.sublist(from, to), tsMs: s.ts.sublist(from, to));
        from = to;
        st.fold(settled.nn, settled.nnTimes);
      }
      final snap = corrector.snapshot();
      final ref = correctRrReference(s.rr, rrTsMs: s.ts);
      final af = (1.0 - ref.cleanFraction).clamp(0.0, 1.0).toDouble();
      final want = irregularBeatScreen(ref.nn,
          nnTimesMs: ref.nnTimesMs, artifactFraction: af);
      expect(want.present, isTrue, reason: 'sanity: a day is enough data');
      _expectSameScreen(
          st.evaluate(snap.tailNn, snap.tailNnTimes,
              artifactFraction: 1.0 - snap.cleanFraction),
          want,
          'day');
    }, timeout: const Timeout(Duration(minutes: 10)));
  });

  group('contract', () {
    test('checkpoint is versioned and typed like the other states', () {
      final json = IrregularScreenState().toJson();
      expect(json['version'], 3);
      expect(json['type'], 'IrregularScreenState');
      expect(() => IrregularScreenState.fromJson({...json, 'version': 2}),
          throwsFormatException);
      expect(() => IrregularScreenState.fromJson({...json, 'type': 'Other'}),
          throwsFormatException);
      expect(() => IrregularScreenState.fromJson({}), throwsFormatException);
    });

    test('checkpoint is bounded: running sums plus one open window', () {
      final x = _fixture(41, 0.5, hours: 8);
      expect(x.nn.length, greaterThan(20000));
      final st = IrregularScreenState();
      var at = 0, maxBytes = 0;
      for (final cut in randomCuts(math.Random(2), x.nn.length,
          sizes: [50, 500, 2000])) {
        st.fold(x.nn.sublist(at, cut), x.t.sublist(at, cut));
        at = cut;
        maxBytes = math.max(maxBytes, jsonEncode(st.toJson()).length);
      }
      // ~1.4 KB measured in the prototype; the series would be ~250 KB.
      expect(maxBytes, lessThan(16 * 1024), reason: 'max checkpoint chars');
    });

    test('save/restore is invisible: restored state folds on identically', () {
      final x = _fixture(42, 0.5, hours: 3);
      final cut = x.nn.length ~/ 2;
      final a = IrregularScreenState()..fold(x.nn.sublist(0, cut), x.t.sublist(0, cut));
      final b = IrregularScreenState.fromJson(jsonRoundTrip(a.toJson()));
      expect(jsonEncode(b.toJson()), jsonEncode(a.toJson()));
      a.fold(x.nn.sublist(cut), x.t.sublist(cut));
      b.fold(x.nn.sublist(cut), x.t.sublist(cut));
      expect(jsonEncode(b.toJson()), jsonEncode(a.toJson()));
      _expectSameScreen(b.evaluate(const [], const []),
          a.evaluate(const [], const []), 'restored vs original');
    });
  });
}
