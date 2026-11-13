// Contract for the irregular-rhythm screen's DIAGNOSTICS (batch side).
//
// Today `irregularBeatScreen` returns SD1/SD2/ratio/pNN/n_beats/flag and throws
// away the evidence: how many beats went in, how many survived the [300, 2000]
// filter, how the corrector treated them, how many 5-minute windows existed,
// how many voted, how many flagged, what the final OPEN window was, and what
// fraction of windows flagged against what the rule needs. An abstention also
// carried only a note string. The contract:
//
//   a. `irregularBeatScreenDetailed` returns the SAME Metric as
//      `irregularBeatScreen` plus an `IrregularDiagnostics`, present when the
//      screen ran AND when it abstained (the abstention names its cause + counts);
//   c. absent input stays absent: no beats => absent metric, zero counts, no
//      fabricated windows; an unknown count is null, never 0; NaN is not a beat;
//   d. toJson round-trips, existing JSON keys and verdicts are unchanged.
//
// (b, batch == resumed, is test/onehz/incremental/irregular_diagnostics_stream_test.dart.)
//
// RED until implemented: the stub throws UnimplementedError.
import 'dart:convert';
import 'dart:math' as math;

import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

// ---- fixtures -------------------------------------------------------------

/// Calm, slowly drifting sinus: valid windows, none flagged.
List<double> _calm(int n) =>
    [for (var i = 0; i < n; i++) (1000 + 15 * math.sin(i / 8)).roundToDouble()];

/// Irregularly irregular: every window of it flags.
List<double> _af(int n, int seed) {
  final r = math.Random(seed);
  return [
    for (var i = 0; i < n; i++)
      (800.0 + (r.nextBool() ? 250 : -50) + r.nextInt(120)).roundToDouble()
  ];
}

List<double> _cumsum(List<double> rr) {
  var t = 0.0;
  return [for (final v in rr) t += v];
}

/// Three-window day crafted so every window edge is hand-known (the same trick
/// as the screen-state test): window 1 opens at the first beat (t = 1000) and
/// is AF-like; the beat that lands EXACTLY 300 s after a window's first beat
/// opens the next one. Window 2 is calm. The final window holds [lastBeats]
/// beats in total (the edge beat that opens it included) of [lastMode]
/// ('calm' | 'af') and is OPEN when the data ends.
({List<double> nn, List<double> t}) _threeWindowDay(
    int lastBeats, String lastMode) {
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

  double afLike() => 400.0 + 100 * r.nextInt(13);
  double calm() => 800.0 + 10 * (r.nextInt(5) - 2);
  add(1000);
  landOn(301000, afLike);
  landOn(601000, calm);
  for (var i = 1; i < lastBeats; i++) {
    add(lastMode == 'af' ? afLike() : calm());
  }
  expect(t.where((x) => x == 301000 || x == 601000).length, 2,
      reason: 'fixture: both window edges landed exactly');
  return (nn: nn, t: t);
}

/// Independent window oracle: the same bucketing rule written out, each window
/// judged by calling the PUBLIC screen on its beats (whole-span verdict, no
/// times), so it shares no code with the window helpers it checks. Only for
/// series with no out-of-range beats (no gaps inside a bucket).
({int total, int valid, int flagged, int openBeats, IrregularOpenWindow open})
    _refWindows(List<double> nn, List<double> t,
        {double windowMin = 5, int minWindowBeats = 40}) {
  var total = 0, valid = 0, flagged = 0;
  var bucket = <double>[];
  IrregularOpenWindow last = IrregularOpenWindow.none;
  void close() {
    if (bucket.isEmpty) return;
    total++;
    if (bucket.length < minWindowBeats) {
      last = IrregularOpenWindow.thin;
    } else {
      valid++;
      final m = irregularBeatScreen(bucket, minBeats: 2);
      final f = m.present && m.value!.flag;
      if (f) flagged++;
      last = f ? IrregularOpenWindow.flagged : IrregularOpenWindow.unflagged;
    }
  }

  var start = t.isEmpty ? 0.0 : t.first;
  var openBeats = 0;
  for (var i = 0; i < nn.length; i++) {
    if (t[i] - start >= windowMin * 60000) {
      close();
      bucket = [];
      start = t[i];
    }
    bucket.add(nn[i]);
  }
  openBeats = bucket.length;
  close();
  return (
    total: total,
    valid: valid,
    flagged: flagged,
    openBeats: openBeats,
    open: last,
  );
}

String _json(Object? o) => jsonEncode(o);

void main() {
  group('present screen: the evidence behind a verdict', () {
    test('beat counts: raw in, kept after the [300,2000] filter, NaN is not a '
        'beat', () {
      final rr = _af(1200, 1);
      rr[10] = 250; // short
      rr[11] = 2500; // long
      rr[12] = double.nan;
      rr[500] = 299.999;
      final res = irregularBeatScreenDetailed(rr,
          nnTimesMs: _cumsum(rr.map((v) => v.isFinite ? v : 800.0).toList()));
      final d = res.diagnostics;
      expect(d.nnIn, 1200);
      expect(d.nnKept, 1200 - 4, reason: '250, 2500, NaN and 299.999 are out');
      expect(res.metric.present, isTrue);
      expect(d.nnKept, res.metric.value!.nBeats,
          reason: 'diagnostics and value agree on the beats analysed');
      expect(d.abstain, isNull);
      expect(d.artifactFraction, 0.0);
    });

    test('the verdict is exactly irregularBeatScreen\'s, to the last digit', () {
      for (final rr in [_calm(1200), _af(1200, 7), _af(900, 8)]) {
        final t = _cumsum(rr);
        final plain = irregularBeatScreen(rr, nnTimesMs: t);
        final res = irregularBeatScreenDetailed(rr, nnTimesMs: t);
        expect(_json(res.metric.toJson((v) => v.toJson())),
            _json(plain.toJson((v) => v.toJson())));
      }
    });

    test('hand-known windows: AF-like, calm, then an OPEN window of exactly '
        'minWindowBeats (40) calm beats is VALID and not flagged', () {
      final x = _threeWindowDay(40, 'calm');
      final res = irregularBeatScreenDetailed(x.nn, nnTimesMs: x.t);
      expect(res.metric.present, isTrue, reason: 'sanity: evaluable day');
      final w = res.diagnostics.windows!;
      expect(w.total, 3);
      expect(w.valid, 3);
      expect(w.flagged, 1);
      expect(w.openBeats, 40);
      expect(w.open, IrregularOpenWindow.unflagged);
      expect(w.sustainedObserved, closeTo(1 / 3, 1e-12));
      expect(res.diagnostics.thresholds.sustainedFraction, 0.5,
          reason: 'required vs observed: 0.5 needed, 1/3 seen');
      expect(res.metric.value!.flag, isFalse);
    });

    test('hand-known windows: an open window of 39 beats is EXCLUDED (thin) but '
        'still counted in total', () {
      final x = _threeWindowDay(39, 'calm');
      final w =
          irregularBeatScreenDetailed(x.nn, nnTimesMs: x.t).diagnostics.windows!;
      expect(w.total, 3);
      expect(w.valid, 2, reason: 'the 39-beat tail does not vote');
      expect(w.flagged, 1);
      expect(w.openBeats, 39);
      expect(w.open, IrregularOpenWindow.thin);
      expect(w.sustainedObserved, 0.5);
    });

    test('hand-known windows: an open window of AF-like beats is VALID and '
        'FLAGGED', () {
      final x = _threeWindowDay(60, 'af');
      final res = irregularBeatScreenDetailed(x.nn, nnTimesMs: x.t);
      final w = res.diagnostics.windows!;
      expect(w.total, 3);
      expect(w.valid, 3);
      expect(w.flagged, 2);
      expect(w.openBeats, 60);
      expect(w.open, IrregularOpenWindow.flagged);
      expect(w.sustainedObserved, closeTo(2 / 3, 1e-12));
    });

    test('window counts equal an independent oracle across seeds', () {
      for (final seed in [1, 2, 3, 4, 5, 6]) {
        final r = math.Random(seed);
        // Blocks of calm and AF of random length, so windows straddle modes.
        final rr = <double>[];
        while (rr.length < 3000) {
          rr.addAll(r.nextBool() ? _calm(100 + r.nextInt(500)) : _af(100 + r.nextInt(500), seed));
        }
        final t = _cumsum(rr);
        final ref = _refWindows(rr, t);
        final res = irregularBeatScreenDetailed(rr, nnTimesMs: t);
        final w = res.diagnostics.windows!;
        expect(w.total, ref.total, reason: 'seed $seed');
        expect(w.valid, ref.valid, reason: 'seed $seed');
        expect(w.flagged, ref.flagged, reason: 'seed $seed');
        expect(w.openBeats, ref.openBeats, reason: 'seed $seed');
        expect(w.open, ref.open, reason: 'seed $seed');
        expect(w.valid, lessThanOrEqualTo(w.total));
        expect(w.flagged, lessThanOrEqualTo(w.valid));
        if (res.metric.present && res.metric.value!.flag) {
          expect(w.sustainedObserved, greaterThanOrEqualTo(0.5),
              reason: 'a flag implies the sustained rule was met');
        }
      }
    });

    test('windows are counted even when the aggregate is not high (they explain '
        'a NOT flagged too)', () {
      final rr = _calm(1500);
      final res = irregularBeatScreenDetailed(rr, nnTimesMs: _cumsum(rr));
      final w = res.diagnostics.windows!;
      expect(res.metric.value!.flag, isFalse);
      expect(w.total, greaterThan(1));
      expect(w.valid, greaterThan(1));
      expect(w.flagged, 0);
      expect(w.sustainedObserved, 0.0, reason: 'valid windows, none flagged: 0, a fact');
    });

    test('cleaning counts pass through; without them they are null, not 0', () {
      final rr = _af(1200, 3);
      final t = _cumsum(rr);
      final withCounts = irregularBeatScreenDetailed(rr,
          nnTimesMs: t,
          artifactFraction: 0.07,
          cleaning: const RrCleaningCounts(raw: 1290, corrected: 41, dropped: 49));
      expect(withCounts.diagnostics.rrRaw, 1290);
      expect(withCounts.diagnostics.corrected, 41);
      expect(withCounts.diagnostics.dropped, 49);
      expect(withCounts.diagnostics.artifactFraction, 0.07);
      final without = irregularBeatScreenDetailed(rr, nnTimesMs: t);
      expect(without.diagnostics.rrRaw, isNull);
      expect(without.diagnostics.corrected, isNull);
      expect(without.diagnostics.dropped, isNull);
    });

    test('real corrector output: counts equal correctRr\'s own', () {
      final r = math.Random(11);
      final raw = <double>[
        for (var i = 0; i < 2500; i++)
          (i % 97 == 50
                  ? 420 // isolated early beat
                  : (i % 211 >= 100 && i % 211 < 106)
                      ? 250 + r.nextInt(1800) // a noise run
                      : 900 + 30 * math.sin(i / 7) + r.nextInt(20))
              .toDouble()
      ];
      final c = correctRr(raw);
      expect(c.correctedCount, greaterThan(0), reason: 'fixture corrects');
      expect(c.droppedCount, greaterThan(0), reason: 'fixture drops');
      final res = irregularBeatScreenDetailed(c.nn,
          nnTimesMs: c.nnTimesMs,
          artifactFraction: (1 - c.cleanFraction).clamp(0.0, 1.0),
          cleaning: RrCleaningCounts(
              raw: raw.length,
              corrected: c.correctedCount,
              dropped: c.droppedCount));
      expect(res.diagnostics.rrRaw, raw.length);
      expect(res.diagnostics.corrected, c.correctedCount);
      expect(res.diagnostics.dropped, c.droppedCount);
      expect(res.diagnostics.nnIn, c.nn.length);
    });
  });

  group('abstention carries the counts that caused it', () {
    test('too few beats', () {
      final rr = _calm(212);
      final res = irregularBeatScreenDetailed(rr, nnTimesMs: _cumsum(rr));
      expect(res.metric.present, isFalse);
      final d = res.diagnostics;
      expect(d.abstain, IrregularAbstain.tooFewBeats);
      expect(d.nnIn, 212);
      expect(d.nnKept, 212);
      expect(d.thresholds.minBeats, irregularScreenMinBeats);
      expect(res.metric.note, contains('too few clean beats'),
          reason: 'the existing note is unchanged');
    });

    test('too few beats because the filter removed them (kept < minBeats <= in)',
        () {
      final rr = <double>[
        for (var i = 0; i < 700; i++) i % 2 == 0 ? 1000.0 + i % 40 : 250.0
      ]; // 350 kept
      final d = irregularBeatScreenDetailed(rr).diagnostics;
      expect(d.abstain, IrregularAbstain.tooFewBeats);
      expect(d.nnIn, 700);
      expect(d.nnKept, 350);
    });

    test('artifact fraction over the line', () {
      final rr = _calm(1200);
      final res = irregularBeatScreenDetailed(rr,
          nnTimesMs: _cumsum(rr),
          artifactFraction: 0.45,
          cleaning: const RrCleaningCounts(raw: 2200, corrected: 100, dropped: 900));
      expect(res.metric.present, isFalse);
      final d = res.diagnostics;
      expect(d.abstain, IrregularAbstain.artifact);
      expect(d.artifactFraction, 0.45);
      expect(d.thresholds.maxArtifact, 0.30);
      expect(d.nnKept, 1200);
      expect(d.dropped, 900);
      expect(d.corrected, 100);
    });

    // The gate counts successive pairs (upstream, merged 2026-10-18), so with
    // any minBeats >= 2 an all-isolated series is "too few"; minBeats 1 is the
    // one setting that still reaches the no-pairs abstention.
    test('no successive clean pairs (every kept beat is isolated)', () {
      final rr = <double>[
        for (var i = 0; i < 1000; i++) i % 2 == 0 ? 900.0 + i % 50 : 250.0
      ];
      expect(irregularBeatScreenDetailed(rr, minBeats: 100).diagnostics.abstain,
          IrregularAbstain.tooFewBeats);
      final res = irregularBeatScreenDetailed(rr, minBeats: 1);
      expect(res.metric.present, isFalse);
      expect(res.diagnostics.abstain, IrregularAbstain.noSuccessivePairs);
      expect(res.diagnostics.nnIn, 1000);
      expect(res.diagnostics.nnKept, 500);
    });

    test('no long-term variability (SD2 = 0), not "perfectly regular"', () {
      final rr = [for (var i = 0; i < 1200; i++) 1000.0];
      final res = irregularBeatScreenDetailed(rr, nnTimesMs: _cumsum(rr));
      expect(res.metric.present, isFalse);
      expect(res.diagnostics.abstain, IrregularAbstain.noLongTermVariability);
      expect(res.diagnostics.nnKept, 1200);
    });

    test('an abstained screen still reports its windows (they were there)', () {
      final x = _threeWindowDay(60, 'af');
      final res = irregularBeatScreenDetailed(x.nn,
          nnTimesMs: x.t, artifactFraction: 0.5);
      expect(res.metric.present, isFalse);
      expect(res.diagnostics.abstain, IrregularAbstain.artifact);
      expect(res.diagnostics.windows!.total, 3);
      expect(res.diagnostics.windows!.flagged, 2);
    });
  });

  group('absent input stays absent', () {
    test('no beats: absent metric, zero counts, no fabricated windows', () {
      final res = irregularBeatScreenDetailed(const [], nnTimesMs: const []);
      expect(res.metric.present, isFalse);
      expect(res.metric.confidence, 0);
      final d = res.diagnostics;
      expect(d.abstain, IrregularAbstain.tooFewBeats);
      expect(d.nnIn, 0);
      expect(d.nnKept, 0);
      expect(d.rrRaw, isNull, reason: 'no cleaning info given: unknown, not 0');
      final w = d.windows!;
      expect((w.total, w.valid, w.flagged, w.openBeats), (0, 0, 0, 0));
      expect(w.open, IrregularOpenWindow.none);
      expect(w.sustainedObserved, isNull, reason: 'no valid window: null, not 0 or NaN');
    });

    test('no beat times: windows are NOT evaluated (null), not zero windows', () {
      final res = irregularBeatScreenDetailed(_af(1200, 2));
      expect(res.diagnostics.windows, isNull);
      expect(res.metric.present, isTrue);
    });

    test('times of the wrong length: windows null, whole-span verdict as before',
        () {
      final rr = _af(1200, 2);
      final res = irregularBeatScreenDetailed(rr, nnTimesMs: _cumsum(rr).sublist(1));
      expect(res.diagnostics.windows, isNull);
      expect(_json(res.metric.toJson((v) => v.toJson())),
          _json(irregularBeatScreen(rr, nnTimesMs: _cumsum(rr).sublist(1)).toJson((v) => v.toJson())));
    });

    test('a window config that fails closed: windows null, never flagged', () {
      final rr = _af(1200, 2);
      final res = irregularBeatScreenDetailed(rr,
          nnTimesMs: _cumsum(rr), windowMinutes: 0);
      expect(res.diagnostics.windows, isNull);
      expect(res.metric.value!.flag, isFalse);
    });
  });

  group('JSON', () {
    List<IrregularScreenResult> variety() {
      final x = _threeWindowDay(40, 'calm');
      final af = _af(1200, 5);
      return [
        irregularBeatScreenDetailed(x.nn,
            nnTimesMs: x.t,
            cleaning: const RrCleaningCounts(raw: 900, corrected: 3, dropped: 4)),
        irregularBeatScreenDetailed(af, nnTimesMs: _cumsum(af)),
        irregularBeatScreenDetailed(af), // windows null, cleaning null
        irregularBeatScreenDetailed(_calm(100)), // tooFewBeats
        irregularBeatScreenDetailed(_calm(1200), artifactFraction: 0.5),
        irregularBeatScreenDetailed([for (var i = 0; i < 1200; i++) 1000.0]),
        irregularBeatScreenDetailed(const []),
      ];
    }

    test('every shape survives real JSON text and comes back identical', () {
      for (final r in variety()) {
        final text = jsonEncode(r.diagnostics.toJson());
        final back =
            IrregularDiagnostics.fromJson(jsonDecode(text) as Map<String, dynamic>);
        expect(jsonEncode(back.toJson()), text);
        expect(back.abstain, r.diagnostics.abstain);
        expect(back.nnIn, r.diagnostics.nnIn);
        expect(back.nnKept, r.diagnostics.nnKept);
        expect(back.rrRaw, r.diagnostics.rrRaw);
        expect(back.windows?.total, r.diagnostics.windows?.total);
        expect(back.windows?.open, r.diagnostics.windows?.open);
      }
    });

    test('the wire shape (what edge persists and Nerd stats reads)', () {
      final x = _threeWindowDay(40, 'calm');
      final j = irregularBeatScreenDetailed(x.nn,
              nnTimesMs: x.t,
              artifactFraction: 0.1,
              cleaning: const RrCleaningCounts(raw: 900, corrected: 3, dropped: 4))
          .diagnostics
          .toJson();
      expect(j['version'], 1);
      expect(j['abstain'], isNull);
      final b = j['beats'] as Map;
      expect(b.keys.toSet(), {
        'rr_raw', 'nn_in', 'nn_kept', 'corrected', 'dropped', 'artifact_fraction'
      });
      expect(b['rr_raw'], 900);
      expect(b['corrected'], 3);
      expect(b['dropped'], 4);
      expect(b['nn_in'], x.nn.length);
      expect(b['artifact_fraction'], 0.1);
      final w = j['windows'] as Map;
      expect(w.keys.toSet(), {
        'total', 'valid', 'flagged', 'sustained_observed', 'open_beats', 'open'
      });
      expect(w['total'], 3);
      expect(w['open'], 'unflagged');
      expect(w['open_beats'], 40);
      final th = j['thresholds'] as Map;
      expect(th.keys.toSet(), {
        'min_beats', 'max_artifact', 'sd1sd2_flag', 'pnn_threshold_ms',
        'pnn_flag_pct', 'window_minutes', 'min_window_beats', 'sustained_fraction'
      });
      expect(th['min_beats'], 500);
      expect(th['sustained_fraction'], 0.5);
    });

    test('abstain wire names; unknown counts and windows are JSON null', () {
      expect(
          irregularBeatScreenDetailed(_calm(100)).diagnostics.toJson()['abstain'],
          'too_few_beats');
      expect(
          irregularBeatScreenDetailed(_calm(1200), artifactFraction: 0.5)
              .diagnostics.toJson()['abstain'],
          'artifact');
      final j = irregularBeatScreenDetailed(_calm(100)).diagnostics.toJson();
      expect(j['windows'], isNull);
      expect((j['beats'] as Map)['rr_raw'], isNull);
      expect((j['beats'] as Map)['corrected'], isNull);
      expect((j['beats'] as Map)['dropped'], isNull);
      expect(
          irregularBeatScreenDetailed([for (var i = 0; i < 1200; i++) 1000.0])
              .diagnostics.toJson()['abstain'],
          'no_long_term_variability');
      expect(
          irregularBeatScreenDetailed([
            for (var i = 0; i < 1000; i++) i % 2 == 0 ? 900.0 + i % 50 : 250.0
          ], minBeats: 1).diagnostics.toJson()['abstain'],
          'no_successive_pairs');
    });

    test('fromJson refuses another version and malformed maps', () {
      final j = irregularBeatScreenDetailed(_calm(1200)).diagnostics.toJson();
      expect(() => IrregularDiagnostics.fromJson({...j, 'version': 2}),
          throwsFormatException);
      expect(() => IrregularDiagnostics.fromJson({...j, 'beats': 'x'}),
          throwsFormatException);
      expect(() => IrregularDiagnostics.fromJson({...j, 'abstain': 'because'}),
          throwsFormatException);
      expect(() => IrregularDiagnostics.fromJson(const {}), throwsFormatException);
    });

    test('IrregularScreenResult.toJson = the old envelope + a diagnostics key',
        () {
      final rr = _af(1200, 9);
      final t = _cumsum(rr);
      final res = irregularBeatScreenDetailed(rr, nnTimesMs: t);
      final env = res.toJson();
      final old = irregularBeatScreen(rr, nnTimesMs: t).toJson((v) => v.toJson());
      expect(env.keys.toSet(), {...old.keys, 'diagnostics'});
      expect(_json({...env}..remove('diagnostics')), _json(old),
          reason: 'every pre-existing key and value is untouched');
      expect(_json(env['diagnostics']), _json(res.diagnostics.toJson()));
      // Absent envelope too.
      final ab = irregularBeatScreenDetailed(_calm(50)).toJson();
      expect(ab['value'], '—');
      expect(ab['confidence'], 0);
      expect(ab['diagnostics'], isA<Map>());
    });
  });

  group('regression: nothing the screen already says changes', () {
    test('IrregularRhythm.toJson keeps exactly its six keys (green today)', () {
      final j = irregularBeatScreen(_af(1200, 1)).value!.toJson();
      expect(j.keys.toSet(),
          {'sd1_ms', 'sd2_ms', 'sd1_sd2', 'pnn_pct', 'n_beats', 'flag'});
    });

    test('same flag / sd1 / sd2 / pnn / nBeats / confidence / note on the '
        'existing test inputs, and on salted ones', () {
      final r = math.Random(7);
      final salted = _af(2000, 4);
      salted[5] = 250;
      salted[900] = 2200;
      final cases = <({List<double> rr, List<double>? t, double af})>[
        (rr: [for (var i = 0; i < 1200; i++) 1000 + 15 * math.sin(i / 8)], t: null, af: 0.0),
        (rr: [for (var i = 0; i < 1200; i++) 800.0 + (r.nextBool() ? 250 : -50) + r.nextInt(120)], t: null, af: 0.0),
        (rr: [for (var i = 0; i < 100; i++) 1000.0], t: null, af: 0.0),
        (rr: [for (var i = 0; i < 1200; i++) 1000.0], t: null, af: 0.4),
        (rr: salted, t: null, af: 0.1),
      ];
      for (final c in cases) {
        final t = c.t ?? _cumsum(c.rr);
        for (final times in [null, t]) {
          final plain = irregularBeatScreen(c.rr, nnTimesMs: times, artifactFraction: c.af);
          final det = irregularBeatScreenDetailed(c.rr, nnTimesMs: times, artifactFraction: c.af);
          expect(det.metric.present, plain.present);
          expect(det.metric.note, plain.note);
          expect(det.metric.confidence, plain.confidence);
          expect(det.metric.tier, plain.tier);
          expect(det.metric.inputs_used, plain.inputs_used);
          if (plain.present) {
            final a = det.metric.value!, b = plain.value!;
            expect((a.flag, a.nBeats, a.pnnPct, a.sd1, a.sd2, a.sd1sd2),
                (b.flag, b.nBeats, b.pnnPct, b.sd1, b.sd2, b.sd1sd2));
          }
        }
      }
    });
  });
}
