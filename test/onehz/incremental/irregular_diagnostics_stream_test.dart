// Contract: the screen's DIAGNOSTICS are the same whether the beats arrive in
// one batch call or in chunks through `RrCorrector` + `IrregularScreenState`,
// across save/restore (design 04 "PRV diagnostics", item b).
//
// Oracle = `irregularBeatScreenDetailed` over `correctRr(prefix)`, with the
// corrector's own counts. At every cut, the streaming side is
//   corrector.snapshot() -> state.evaluateDetailed(tail, cleaning: counts)
// and its diagnostics must equal the batch's JSON text, byte for byte: beat
// counts, corrected / dropped, artifact fraction, window counts, the final OPEN
// window, thresholds. Cuts are placed to split a 5-minute window, an isolated
// artifact (a spline correction that cannot settle until two normals follow it)
// and a multi-beat noise run (a drop).
//
// RED until implemented: `evaluateDetailed` / `irregularBeatScreenDetailed`
// are stubs that throw UnimplementedError.
import 'dart:convert';
import 'dart:math' as math;

import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

import '../support/rr_chunking.dart';

String _json(Object? o) => jsonEncode(o);

/// A day of beats with known artifacts: calm sinus with AF bursts, isolated
/// early beats (+ compensatory pause) at [isolated], a 6-beat noise run at each
/// of [runs], and one 40 s dropout. Stamps are end-of-beat epoch ms.
({List<double> rr, List<double> ts, List<int> isolated, List<int> runs}) _day(
    int seed,
    {int beats = 9000}) {
  final r = math.Random(seed);
  final rr = <double>[], ts = <double>[];
  final isolated = <int>[], runs = <int>[];
  var clock = 1.76e12; // epoch ms
  var af = false;
  var left = 0;
  var droppedOut = false;
  void emit(double v) {
    clock += v;
    rr.add(v);
    ts.add(clock.floorToDouble());
  }

  while (rr.length < beats) {
    if (--left <= 0) {
      af = r.nextDouble() < 0.4;
      left = 300 + r.nextInt(900);
    }
    final i = rr.length;
    if (!droppedOut && i >= 4000) {
      droppedOut = true;
      clock += 40000; // a sensor dropout
    }
    if (i > 100 && i % 523 == 7) {
      isolated.add(i);
      emit(380); // early beat
      emit(1450); // compensatory pause
      continue;
    }
    if (i > 100 && i % 811 == 400) {
      runs.add(i);
      for (var k = 0; k < 6; k++) {
        emit(250 + r.nextInt(1800).toDouble());
      }
      continue;
    }
    emit(af
        ? (420 + r.nextInt(700)).toDouble()
        : (850 + 40 * math.sin(i / 70) + 12 * (r.nextDouble() - .5))
            .roundToDouble());
  }
  return (rr: rr, ts: ts, isolated: isolated, runs: runs);
}

IrregularScreenResult _batch(List<double> rr, List<double> ts, int n) {
  final c = correctRr(rr.sublist(0, n), rrTsMs: ts.sublist(0, n));
  return irregularBeatScreenDetailed(
    c.nn,
    nnTimesMs: c.nnTimesMs,
    artifactFraction: (1.0 - c.cleanFraction).clamp(0.0, 1.0),
    cleaning: RrCleaningCounts(
        raw: n, corrected: c.correctedCount, dropped: c.droppedCount),
  );
}

IrregularScreenResult _stream(RrCorrector c, IrregularScreenState st) {
  final s = c.snapshot();
  return st.evaluateDetailed(
    s.tailNn,
    s.tailNnTimes,
    artifactFraction: (1.0 - s.cleanFraction).clamp(0.0, 1.0),
    cleaning: RrCleaningCounts(
        raw: s.n, corrected: s.correctedCount, dropped: s.droppedCount),
  );
}

void _same(IrregularScreenResult got, IrregularScreenResult want, String why) {
  expect(_json(got.diagnostics.toJson()), _json(want.diagnostics.toJson()),
      reason: 'diagnostics $why');
  expect(got.metric.present, want.metric.present, reason: 'present $why');
  expect(got.metric.note, want.metric.note, reason: 'note $why');
  if (want.metric.present) {
    expect(got.metric.value!.flag, want.metric.value!.flag, reason: 'flag $why');
    expect(got.metric.value!.nBeats, want.metric.value!.nBeats,
        reason: 'nBeats $why');
  }
}

/// Cut points: random chunking plus neighbourhoods of every artifact and of
/// every 5-minute beat-clock edge.
List<int> _cuts(
    ({List<double> rr, List<double> ts, List<int> isolated, List<int> runs}) d,
    int seed) {
  final n = d.rr.length;
  final cuts = <int>{...randomCuts(math.Random(seed), n, sizes: [90, 500, 1500])};
  for (final k in d.isolated) {
    for (var o = -1; o <= 4; o++) {
      cuts.add(k + o);
    }
  }
  for (final m in d.runs) {
    for (var o = 0; o <= 9; o++) {
      cuts.add(m + o);
    }
  }
  var next = d.ts.first + 300000;
  for (var i = 0; i < n; i++) {
    if (d.ts[i] >= next) {
      cuts..add(i - 1)..add(i)..add(i + 1);
      next += 300000;
    }
  }
  return [
    for (final c in cuts)
      if (c > 0 && c <= n) c
  ]..sort();
}

void main() {
  group('corrector + screen state == batch, at every cut', () {
    for (final restart in [false, true]) {
      test('save/restore between chunks: $restart', () {
        final d = _day(restart ? 2 : 1);
        final c0 = correctRr(d.rr, rrTsMs: d.ts);
        expect(c0.correctedCount, greaterThan(5), reason: 'fixture corrects');
        expect(c0.droppedCount, greaterThan(10), reason: 'fixture drops');

        var corr = RrCorrector();
        var st = IrregularScreenState();
        var at = 0;
        final opens = <IrregularOpenWindow>{};
        var flaggedSeen = 0, presentSeen = 0, abstainedSeen = 0;
        for (final cut in _cuts(d, 4)) {
          final settled =
              corr.fold(d.rr.sublist(at, cut), tsMs: d.ts.sublist(at, cut));
          st.fold(settled.nn, settled.nnTimes);
          at = cut;
          if (restart) {
            corr = RrCorrector.fromJson(jsonDecode(jsonEncode(corr.toJson()))
                as Map<String, dynamic>);
            st = IrregularScreenState.fromJson(
                jsonDecode(jsonEncode(st.toJson())) as Map<String, dynamic>);
          }
          final got = _stream(corr, st);
          _same(got, _batch(d.rr, d.ts, cut), 'cut=$cut restart=$restart');
          final w = got.diagnostics.windows;
          if (w != null) opens.add(w.open);
          got.metric.present ? presentSeen++ : abstainedSeen++;
          if (got.diagnostics.windows != null &&
              got.diagnostics.windows!.flagged > 0) {
            flaggedSeen++;
          }
        }
        expect(presentSeen, greaterThan(20), reason: 'the screen really ran');
        expect(abstainedSeen, greaterThan(0), reason: 'and abstained early on');
        expect(flaggedSeen, greaterThan(5), reason: 'windows really flagged');
        expect(opens, containsAll([IrregularOpenWindow.thin]),
            reason: 'cuts landed in a window that had not yet filled');
        expect(
            opens.contains(IrregularOpenWindow.unflagged) ||
                opens.contains(IrregularOpenWindow.flagged),
            isTrue,
            reason: 'and in valid open windows');
        final last = _stream(corr, st);
        expect(last.diagnostics.rrRaw, d.rr.length);
        expect(last.diagnostics.corrected, c0.correctedCount);
        expect(last.diagnostics.dropped, c0.droppedCount);
      });
    }

    test('evaluateDetailed does not change the state', () {
      final d = _day(3, beats: 3000);
      final corr = RrCorrector();
      final st = IrregularScreenState();
      final settled = corr.fold(d.rr, tsMs: d.ts);
      st.fold(settled.nn, settled.nnTimes);
      final before = jsonEncode(st.toJson());
      final a = _stream(corr, st);
      final b = _stream(corr, st);
      expect(jsonEncode(st.toJson()), before);
      expect(_json(a.diagnostics.toJson()), _json(b.diagnostics.toJson()));
    });

    test('one fold of the whole day == a hundred small ones', () {
      final d = _day(5, beats: 4000);
      final one = RrCorrector(), many = RrCorrector();
      final s1 = IrregularScreenState(), s2 = IrregularScreenState();
      final r1 = one.fold(d.rr, tsMs: d.ts);
      s1.fold(r1.nn, r1.nnTimes);
      for (var i = 0; i < d.rr.length; i += 40) {
        final to = math.min(d.rr.length, i + 40);
        final r = many.fold(d.rr.sublist(i, to), tsMs: d.ts.sublist(i, to));
        s2.fold(r.nn, r.nnTimes);
      }
      _same(_stream(many, s2), _stream(one, s1), 'chunking');
      _same(_stream(one, s1), _batch(d.rr, d.ts, d.rr.length), 'vs batch');
    });
  });

  group('folding a corrected NN series directly (no corrector)', () {
    ({List<double> nn, List<double> t}) fixture(int seed, {double salt = 0.03}) {
      final r = math.Random(seed);
      final nn = <double>[], t = <double>[];
      var clock = 0.0;
      var af = false;
      var left = 0;
      while (clock < 4 * 3600 * 1000.0) {
        if (--left <= 0) {
          af = r.nextDouble() < 0.5;
          left = 200 + r.nextInt(1500);
        }
        var v = af
            ? (420 + r.nextInt(700)).toDouble()
            : (850 + 40 * math.sin(clock / 9000)).roundToDouble();
        final u = r.nextDouble();
        if (u < salt / 3) {
          v = 250;
        } else if (u < 2 * salt / 3) {
          v = 2500;
        } else if (u < salt) {
          v = double.nan;
        }
        clock += v.isFinite ? v : 800;
        nn.add(v);
        t.add(clock);
      }
      return (nn: nn, t: t);
    }

    IrregularScreenResult batch(List<double> nn, List<double> t, int n,
            {double af = 0,
            int minBeats = irregularScreenMinBeats,
            double maxArtifact = 0.30}) =>
        irregularBeatScreenDetailed(nn.sublist(0, n),
            nnTimesMs: t.sublist(0, n),
            artifactFraction: af,
            minBeats: minBeats,
            maxArtifact: maxArtifact);

    for (final restart in [false, true]) {
      test('out-of-range and NaN beats are counted in nnIn, not nnKept; '
          'restore: $restart', () {
        final x = fixture(8);
        var st = IrregularScreenState();
        var at = 0;
        var sawGap = false;
        for (final cut
            in randomCuts(math.Random(9), x.nn.length, sizes: [7, 90, 700, 3000])) {
          st.fold(x.nn.sublist(at, cut), x.t.sublist(at, cut));
          at = cut;
          if (restart) {
            st = IrregularScreenState.fromJson(
                jsonDecode(jsonEncode(st.toJson())) as Map<String, dynamic>);
          }
          for (final af in [0.0, 0.31]) {
            final got = st.evaluateDetailed(const [], const [], artifactFraction: af);
            _same(got, batch(x.nn, x.t, cut, af: af), 'cut=$cut af=$af');
            if (got.diagnostics.nnIn > got.diagnostics.nnKept) sawGap = true;
          }
        }
        expect(sawGap, isTrue, reason: 'fixture has beats the filter removes');
      });
    }

    test('every prefix 0..700, one beat at a time: abstention reasons and '
        'counts match the batch the whole way', () {
      final x = fixture(12, salt: 0.0);
      final st = IrregularScreenState();
      final reasons = <IrregularAbstain?>{};
      for (var i = 0; i < 700; i++) {
        st.fold([x.nn[i]], [x.t[i]]);
        final got = st.evaluateDetailed(const [], const []);
        _same(got, batch(x.nn, x.t, i + 1), 'n=${i + 1}');
        reasons.add(got.diagnostics.abstain);
      }
      expect(reasons, containsAll([IrregularAbstain.tooFewBeats, null]),
          reason: 'thin first, then the screen runs');
    });

    test('a smaller beat floor is a threshold the diagnostics report', () {
      final x = fixture(13, salt: 0.0);
      final st = IrregularScreenState()
        ..fold(x.nn.sublist(0, 300), x.t.sublist(0, 300));
      final got =
          st.evaluateDetailed(const [], const [], minBeats: 100, maxArtifact: 0.2);
      expect(got.diagnostics.thresholds.minBeats, 100);
      expect(got.diagnostics.thresholds.maxArtifact, 0.2);
      _same(got, batch(x.nn, x.t, 300, minBeats: 100, maxArtifact: 0.2),
          'minBeats 100');
    });

    test('tail: evaluateDetailed(tail) == batch(settled ++ tail), state '
        'untouched', () {
      final x = fixture(31);
      final st = IrregularScreenState();
      const settled = 2500;
      st.fold(x.nn.sublist(0, settled), x.t.sublist(0, settled));
      final before = jsonEncode(st.toJson());
      for (final tail in [0, 1, 50, 399]) {
        final to = settled + tail;
        _same(
            st.evaluateDetailed(x.nn.sublist(settled, to), x.t.sublist(settled, to)),
            batch(x.nn, x.t, to),
            'tail=$tail');
        expect(jsonEncode(st.toJson()), before);
      }
    });
  });

  group('old checkpoints', () {
    test('a version 1 checkpoint (no input-beat or window-total counters) is '
        'REFUSED, never restored with counts it did not keep', () {
      final st = IrregularScreenState()
        ..fold([for (var i = 0; i < 80; i++) 800.0 + i % 9], [
          for (var i = 0; i < 80; i++) 800.0 * (i + 1)
        ]);
      final v1 = jsonDecode(jsonEncode(st.toJson())) as Map<String, dynamic>
        ..['version'] = 1
        ..remove('nIn')
        ..remove('total');
      expect(() => IrregularScreenState.fromJson(v1), throwsFormatException);
      // The current format still restores.
      final now = IrregularScreenState.fromJson(
          jsonDecode(jsonEncode(st.toJson())) as Map<String, dynamic>);
      expect(now.evaluateDetailed(const [], const []).diagnostics.nnIn, 80);
      expect(st.toJson()['version'], 3);
    });

    test('a version 2 checkpoint missing a counter is refused too', () {
      final j = jsonDecode(jsonEncode(IrregularScreenState().toJson()))
          as Map<String, dynamic>
        ..remove('nIn');
      expect(() => IrregularScreenState.fromJson(j), throwsFormatException);
    });
  });

  group('absent input stays absent', () {
    test('a fresh state: absent, zero counts, nothing invented', () {
      final got = IrregularScreenState().evaluateDetailed(const [], const []);
      _same(got, irregularBeatScreenDetailed(const [], nnTimesMs: const []),
          'empty');
      expect(got.metric.present, isFalse);
      expect(got.diagnostics.nnIn, 0);
      expect(got.diagnostics.windows!.total, 0);
      expect(got.diagnostics.windows!.sustainedObserved, isNull);
      expect(got.diagnostics.rrRaw, isNull,
          reason: 'no cleaning counts handed in: unknown, not 0');
    });

    test('only unusable beats folded: counted as input, none kept, no window',
        () {
      final st = IrregularScreenState()
        ..fold([double.nan, 100, 5000, double.nan], [1, 2, 3, 4]);
      final got = st.evaluateDetailed(const [], const []);
      expect(got.diagnostics.nnIn, 4);
      expect(got.diagnostics.nnKept, 0);
      expect(got.diagnostics.windows!.total, 0);
      expect(got.diagnostics.windows!.open, IrregularOpenWindow.none);
      expect(got.metric.present, isFalse);
    });

    test('a window config that fails closed: windows null, same as the batch',
        () {
      final r = math.Random(4);
      final nn = [for (var i = 0; i < 1200; i++) 400.0 + 100 * r.nextInt(13)];
      var clock = 0.0;
      final t = [for (final v in nn) clock += v];
      final st = IrregularScreenState(windowMinutes: 0)..fold(nn, t);
      final got = st.evaluateDetailed(const [], const []);
      expect(got.diagnostics.windows, isNull);
      _same(
          got,
          irregularBeatScreenDetailed(nn, nnTimesMs: t, windowMinutes: 0),
          'windowMinutes 0');
    });
  });
}
