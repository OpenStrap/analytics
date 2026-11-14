import 'dart:convert';
import 'dart:math' as math;

import 'package:openstrap_analytics/onehz.dart' hide IrregularScreenState;
import 'package:test/test.dart';

import '../../tool/incremental/hrv_incr.dart';
import '../../tool/incremental/resp_incr.dart';
import '../onehz/welch_stream_test.dart' show expectSameHrv, expectSameResp;
import 'support.dart';

void main() {
  // why: an error recorder must fail on non-finite values instead of reporting zero error.
  // # catches: comparisons against NaN leave maxAbs and maxRel at zero.
  test('Err rejects non-finite operands', () {
    for (final bad in [double.nan, double.infinity, double.negativeInfinity]) {
      expect(() => Err().add(bad, 1), throwsA(isA<TestFailure>()));
      expect(() => Err().add(1, bad), throwsA(isA<TestFailure>()));
    }
    final e = Err()..add(3, 2);
    expect(e.maxAbs, 1);
    expect(e.maxRel, .5);
  });
  // why: the stage mask is indexed in beat-clock seconds, including the origin.
  // # catches: window 0 at t0=120s reads mask[150] instead of mask[270].
  test('nocturnal stage lookup includes clock origin', () {
    final nn = List.filled(20, 800.0);
    final ts = List.generate(20, (i) => 120000 + i * 800.0);
    final mask = List.filled(500, false)..[270] = true;
    final s = NocturnalRmssdState()..fold(nn, ts);
    final want = nocturnalRmssd(nn, ts, stageMaskPerSec: mask);
    final got = s.evaluate([], [], stageMaskPerSec: mask);
    expect(want.present, isTrue);
    expect(got.toJson(), want.toJson());
  });
  // why: session refusal covers all raw times, including regressions between folds.
  // # catches: negative deltas contribute successive differences and produce RMSSD 0.
  test('session refuses regressing raw timestamps across folds', () {
    final rr = List.filled(40, 800.0);
    final ts = List.generate(40, (i) => 1000000 + i * 800.0)..[39] = 1000100;
    final s = SessionRmssdState(1000, 1300)
      ..fold(rr.sublist(0, 39), ts.sublist(0, 39));
    s.fold(rr.sublist(39), ts.sublist(39));
    final want =
        sleepSessionWindowedRmssd(rr, ts, startSec: 1000, endSec: 1300);
    expect(want.note, 'regressing beat time');
    expect(s.evaluate().toJson(), want.toJson());
  });
  // why: retained pNN counts and future counts must use the same screening policy.
  // # catches: fromJson silently installs default constructor settings.
  test('prototype irregular checkpoint restores custom settings', () {
    final s = IrregularScreenState(
        sd1sd2Flag: .6,
        pnnThresholdMs: 20,
        pnnFlagPct: 25,
        windowMinutes: 2,
        minWindowBeats: 15,
        sustainedFraction: .7);
    final nn = List.generate(200, (i) => 800.0 + (i.isOdd ? 40 : 0));
    final ts = List.generate(200, (i) => i * 800.0);
    s.fold(nn.sublist(0, 100), ts.sublist(0, 100));
    final restored = IrregularScreenState.fromJson(
        jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>);
    expect(restored.pnnThresholdMs, 20);
    expect(restored.sd1sd2Flag, .6);
    expect(restored.pnnFlagPct, 25);
    expect(restored.windowMs, 120000);
    expect(restored.minWindowBeats, 15);
    expect(restored.sustainedFraction, .7);
    restored.fold(nn.sublist(100), ts.sublist(100));
    s.fold(nn.sublist(100), ts.sublist(100));
    expect(restored.evaluate([], [], minBeats: 40).toJson((v) => v.toJson()),
        s.evaluate([], [], minBeats: 40).toJson((v) => v.toJson()));
  });
  // why: a fresh state with a provisional night must honor evaluation overrides.
  // # catches: the short-record batch fallback forwards only artifactFraction.
  test('RSA fallback forwards evaluation options', () {
    final nn = List.generate(1000, (i) => 800 + 30 * math.sin(i / 4));
    final ts = List.generate(1000, (i) => i * 800.0);
    expectSameResp(
        RsaWelchState().evaluate(nn, ts,
            artifactFraction: .2,
            maxArtifact: .1,
            tolBrpm: .4,
            minConsensus: .9),
        rsaRespRate(nn, ts,
            artifactFraction: .2,
            maxArtifact: .1,
            tolBrpm: .4,
            minConsensus: .9),
        'custom options');
  });
  // why: the supported abstaining state must survive persistence.
  // # catches: raw infinities/NaNs in tMs, nn, or sorted break jsonEncode.
  for (final pair in [(800.0, double.infinity), (double.nan, 0.0)]) {
    test('RSA checkpoint encodes non-finite input $pair', () {
      final s = RsaWelchState()..fold([pair.$1], [pair.$2]);
      final encoded = jsonEncode(s.toJson());
      final restored =
          RsaWelchState.fromJson(jsonDecode(encoded) as Map<String, dynamic>);
      expect(jsonEncode(restored.toJson()), encoded);
    });
  }
  // why: research parity reports must apply the batch omission policy across boundaries.
  // # catches: unsorted retained times enter binary search or omitted counts are lost.
  test('prototype spectrum preserves regression omission policy', () {
    final nn = List.generate(801, (i) => 800 + 20 * math.sin(i / 4));
    final ts = List.generate(801, (i) => i * 800.0)..[410] = 325000;
    var s = HrvFreqState()..fold(nn.sublist(0, 410), ts.sublist(0, 410));
    expectSameHrv(
        s.evaluate(nn.sublist(410), ts.sublist(410), artifactFraction: 0),
        hrvFreq(nn, ts, artifactFraction: 0),
        'tail regression');
    s.fold(nn.sublist(410), ts.sublist(410));
    s = HrvFreqState.fromJson(
        jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>);
    expectSameHrv(s.evaluate([], [], artifactFraction: 0),
        hrvFreq(nn, ts, artifactFraction: 0), 'fold regression');
  });
  // why: infinity cannot be used as the segment-loop clock.
  // # catches: Infinity + segment <= Infinity loops forever; validation must be atomic.
  test('prototype spectrum refuses non-finite time before mutation', () {
    final s = HrvFreqState()..fold([800], [0]);
    final before = jsonEncode(s.toJson());
    // The initial red run used NaN to expose the missing guard without hanging.
    for (final bad in [double.nan, double.infinity, double.negativeInfinity]) {
      expect(() => s.fold([800], [bad]), throwsArgumentError);
      expect(jsonEncode(s.toJson()), before);
    }
  });

  // why: the batch refuses a non-finite RR before cleaning; cleaning that drops
  // the value would publish RMSSD 0 from the beats around it.
  // # catches: 40 in-session 800 ms beats with a NaN in the middle give RMSSD 0.
  test('session RMSSD refuses a non-finite RR like the batch', () {
    final rr = List.filled(40, 800.0)..[20] = double.nan;
    final ts = List.generate(40, (i) => 1000000 + i * 800.0);
    final want =
        sleepSessionWindowedRmssd(rr, ts, startSec: 1000, endSec: 1300);
    expect(want.note, 'non-finite NN interval');
    final s = SessionRmssdState(1000, 1300)
      ..fold(rr.sublist(0, 25), ts.sublist(0, 25));
    s.fold(rr.sublist(25), ts.sublist(25));
    expect(s.evaluate().toJson(), want.toJson());
  });
  // why: the batch abstains when SDNN is below the rounding floor.
  // # catches: SDNN ~1e-7 ms with a positive SD2 publishes a screen here.
  test('prototype irregular screen applies the batch SDNN floor', () {
    final nn = List.generate(600, (i) => 800.0 + i * 1e-9);
    final ts = List.generate(600, (i) => i * 800.0);
    final want = irregularBeatScreen(nn, nnTimesMs: ts);
    final got = (IrregularScreenState()..fold(nn, ts)).evaluate([], []);
    expect(want.present, isFalse, reason: 'the batch abstains');
    expect(got.present, isFalse);
    expect(got.note, want.note);
  });
  // why: a bad window config must fail closed; it may never manufacture a flag.
  // # catches: windowMinutes infinity keeps one window and votes it flagged.
  test('prototype irregular screen rejects invalid window settings', () {
    final nn = [for (var i = 0; i < 600; i++) [500.0, 700.0, 1000.0, 800.0][i % 4]];
    var acc = 0.0;
    final ts = [for (final v in nn) acc += v];
    for (final cfg in [
      (windowMinutes: double.infinity, minWindowBeats: 40, sustained: 0.5),
      (windowMinutes: 5.0, minWindowBeats: 1, sustained: 0.5),
      (windowMinutes: 5.0, minWindowBeats: 40, sustained: 2.0),
    ]) {
      final want = irregularBeatScreen(nn,
          nnTimesMs: ts,
          windowMinutes: cfg.windowMinutes,
          minWindowBeats: cfg.minWindowBeats,
          sustainedFraction: cfg.sustained);
      final st = IrregularScreenState(
          windowMinutes: cfg.windowMinutes,
          minWindowBeats: cfg.minWindowBeats,
          sustainedFraction: cfg.sustained)
        ..fold(nn, ts);
      final got = st.evaluate([], []);
      expect(want.value?.flag, isFalse, reason: '$cfg batch');
      expect(got.value?.flag, isFalse, reason: '$cfg state');
    }
  });

  // why: a rejected call must leave the columns the same length, and a
  // mismatched tail must be the batch's refusal, not an exception.
  // # catches: fold([800, 800], [0]) pushes into _sorted and _nn before
  // throwing; evaluate with 20 NN and no times throws at allTs.first.
  test('RSA state validates column lengths at both entry points', () {
    final s = RsaWelchState();
    expect(() => s.fold([800.0, 800.0], [0.0]), throwsArgumentError);
    expect(s.bufferedBeats, 0);
    final nn = List.filled(20, 800.0);
    expectSameResp(
        RsaWelchState().evaluate(nn, const [], artifactFraction: 0),
        rsaRespRate(nn, const [], artifactFraction: 0),
        'tail without times');
    final folded = RsaWelchState()..fold(nn, [for (var i = 0; i < 20; i++) i * 800.0]);
    expectSameResp(folded.evaluate([800.0], const [], artifactFraction: 0),
        rsaRespRate([...nn, 800.0], [for (var i = 0; i < 20; i++) i * 800.0], artifactFraction: 0),
        'mismatched tail');
  });
  // why: once folding has begun the buffer is cut, so a backward time in a later
  // fold, at the seam or in the tail can only be refused from a kept flag.
  // # catches: the cached segments publish an estimate the batch refuses.
  group('RSA state keeps the batch regressing-time refusal', () {
    List<double> nnOf(int a, int b) =>
        [for (var i = a; i < b; i++) 800 + 30 * math.sin(i / 4)];
    List<double> tsOf(int a, int b, {double shift = 0}) =>
        [for (var i = a; i < b; i++) i * 800.0 + shift];
    RsaWelchState start() =>
        RsaWelchState()..fold(nnOf(0, 1000), tsOf(0, 1000));

    void expectRefused(RsaWelchState s, List<double> tailNn,
        List<double> tailT, List<double> allNn, List<double> allT, String why) {
      final want = rsaRespRate(allNn, allT, artifactFraction: 0);
      expect(want.note, 'regressing beat time', reason: '$why batch');
      expectSameResp(s.evaluate(tailNn, tailT, artifactFraction: 0), want, why);
    }

    test('a later fold goes backward', () {
      final s = start();
      final nn2 = nnOf(1000, 1100), t2 = tsOf(1000, 1100, shift: -300000);
      s.fold(nn2, t2);
      expectRefused(s, const [], const [], [...nnOf(0, 1000), ...nn2],
          [...tsOf(0, 1000), ...t2], 'later fold');
      final back = RsaWelchState.fromJson(
          jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>);
      expectRefused(back, const [], const [], [...nnOf(0, 1000), ...nn2],
          [...tsOf(0, 1000), ...t2], 'after a checkpoint');
    });
    test('the tail starts before the last folded beat', () {
      final s = start();
      final tn = nnOf(1000, 1050), tt = tsOf(1000, 1050, shift: -300000);
      expectRefused(s, tn, tt, [...nnOf(0, 1000), ...tn],
          [...tsOf(0, 1000), ...tt], 'seam');
    });
    test('the tail goes backward inside itself', () {
      final s = start();
      final tn = nnOf(1000, 1050);
      final tt = tsOf(1000, 1050)..[30] = tsOf(1000, 1050)[10];
      expectRefused(s, tn, tt, [...nnOf(0, 1000), ...tn],
          [...tsOf(0, 1000), ...tt], 'inside the tail');
    });
    test('ordered input is still estimated', () {
      final s = start();
      final tn = nnOf(1000, 1050), tt = tsOf(1000, 1050);
      expectSameResp(s.evaluate(tn, tt, artifactFraction: 0),
          rsaRespRate([...nnOf(0, 1000), ...tn], [...tsOf(0, 1000), ...tt],
              artifactFraction: 0),
          'ordered');
    });
  });

  // why: a bin of no width never reaches the next edge.
  // # catches: NightShapeState(binMin: 0)..fold([800], [0]) never returns. The
  // check is on construction so a regression fails instead of hanging.
  test('night shape rejects a non-positive or non-finite bin width', () {
    for (final bad in [0.0, -30.0, double.nan, double.infinity]) {
      expect(() => NightShapeState(binMin: bad), throwsArgumentError,
          reason: '$bad');
    }
    final ok = NightShapeState(binMin: 30)..fold([800.0], [0.0]);
    expect(ok.closed, isEmpty);
  });
  // why: one non-finite beat time must refuse like the batch, not throw halfway
  // through a fold with state already changed.
  // # catches: .round() on NaN throws UnsupportedError after _seen and the
  // previous time were updated.
  test('session RMSSD refuses a non-finite beat time without mutating', () {
    final s = SessionRmssdState(1000, 1300);
    expect(() => s.fold([800.0], [double.nan]), returnsNormally);
    final want = sleepSessionWindowedRmssd([800.0], [double.nan],
        startSec: 1000, endSec: 1300);
    expect(want.note, 'non-finite beat time');
    expect(s.evaluate().toJson(), want.toJson());
    // A later finite fold neither throws nor lifts the refusal.
    final rr = List.filled(40, 800.0);
    final ts = List.generate(40, (i) => 1000000 + i * 800.0);
    s.fold(rr, ts);
    expect(s.evaluate().note, 'non-finite beat time');
    // A short time column is rejected before anything is read.
    final fresh = SessionRmssdState(1000, 1300);
    expect(() => fresh.fold([800.0, 800.0], [1000000.0]), throwsArgumentError);
    expect(fresh.evaluate().note, 'invalid or empty RR session window');
  });
  // why: the batch bins by index in a map, so beats that come back to bin 0
  // join the old bin 0. A closed state cannot merge them, so that bin must have
  // no estimate, never the old one and never a second one beside it.
  // # catches: bin 0 -> bin 1 -> bin 0 keeps the old bin-0 estimate and opens a
  // separate state that adds another.
  test('a bin the clock returns to has no estimate', () {
    List<double> nnAt(double fromMs, double toMs) => [
          for (var t = fromMs; t < toMs; t += 800)
            800 + 40 * math.sin(2 * math.pi * 0.25 * t / 1000)
        ];
    List<double> tAt(double fromMs, double toMs) =>
        [for (var t = fromMs; t < toMs; t += 800) t];
    RespWindowsState fresh() => RespWindowsState(windowMs: 180000, minBeats: 20);
    final forward = fresh()
      ..fold(nnAt(0, 180000), tAt(0, 180000))
      ..fold(nnAt(180000, 360000), tAt(180000, 360000))
      ..fold(nnAt(360000, 540000), tAt(360000, 540000));
    final all = forward.evaluate(const [], const []);
    expect(all.length, 3, reason: 'the setup resolves every bin');
    // 0 -> 1 -> 0 (settled): only bin 1 has an estimate.
    final back = fresh()
      ..fold(nnAt(0, 180000), tAt(0, 180000))
      ..fold(nnAt(180000, 360000), tAt(180000, 360000))
      ..fold(nnAt(60000, 100000), tAt(60000, 100000));
    expect(back.evaluate(const [], const []), [all[1]]);
    // ...and going on to a later bin still leaves bin 0 without one.
    back.fold(nnAt(360000, 540000), tAt(360000, 540000));
    expect(back.evaluate(const [], const []), [all[1], all[2]]);
    // The same return seen only in the tail.
    final tail = fresh()
      ..fold(nnAt(0, 180000), tAt(0, 180000))
      ..fold(nnAt(180000, 360000), tAt(180000, 360000));
    expect(
        tail.evaluate(nnAt(60000, 100000), tAt(60000, 100000)), [all[1]]);
    // A forward-only stream is unchanged.
    expect(forward.evaluate(const [], const []), all);
  });

  // why: hrvTime and nocturnalRmssd refuse a backward beat time; the summaries
  // kept by their states cannot show it later, so the fact is kept.
  // # catches: 40 constant 800 ms beats with the last time set to 100 publish
  // RMSSD 0 from both states.
  group('time-domain states keep the batch regressing-time refusal', () {
    final nn = List<double>.filled(40, 800);
    final ts = List<double>.generate(40, (i) => i * 800.0)..[39] = 100;

    test('HrvTimeAcc: one fold, two folds, a tail, a checkpoint', () {
      final want = hrvTime(nn, nnTimesMs: ts);
      expect(want.note, 'regressing beat time');
      Map<String, Object?> j(Metric<HrvTime> m) => m.toJson((v) => v.toJson());
      expect(j((HrvTimeAcc()..fold(nn, ts)).evaluate([], [])), j(want),
          reason: 'one fold');
      final two = HrvTimeAcc()
        ..fold(nn.sublist(0, 39), ts.sublist(0, 39))
        ..fold(nn.sublist(39), ts.sublist(39));
      expect(j(two.evaluate([], [])), j(want), reason: 'across folds');
      final tail = HrvTimeAcc()..fold(nn.sublist(0, 39), ts.sublist(0, 39));
      expect(j(tail.evaluate(nn.sublist(39), ts.sublist(39))), j(want),
          reason: 'in the tail');
      final back = HrvTimeAcc.fromJson(
          jsonDecode(jsonEncode(two.toJson())) as Map<String, dynamic>);
      expect(j(back.evaluate([], [])), j(want), reason: 'after a checkpoint');
      // Ordered input is still estimated.
      final okTs = List<double>.generate(40, (i) => i * 800.0);
      expect(
          j((HrvTimeAcc()..fold(nn, okTs)).evaluate([], [])),
          j(hrvTime(nn, nnTimesMs: okTs)));
    });

    test('NocturnalRmssdState: one fold, across folds, a tail, the seam', () {
      final want = nocturnalRmssd(nn, ts);
      expect(want.note, 'regressing beat time');
      expect((NocturnalRmssdState()..fold(nn, ts)).evaluate([], []).toJson(),
          want.toJson(),
          reason: 'one fold');
      final two = NocturnalRmssdState()
        ..fold(nn.sublist(0, 39), ts.sublist(0, 39))
        ..fold(nn.sublist(39), ts.sublist(39));
      expect(two.evaluate([], []).toJson(), want.toJson(),
          reason: 'across folds');
      final tail = NocturnalRmssdState()
        ..fold(nn.sublist(0, 39), ts.sublist(0, 39));
      expect(tail.evaluate(nn.sublist(39), ts.sublist(39)).toJson(),
          want.toJson(),
          reason: 'seam to the tail');
      final okTs = List<double>.generate(40, (i) => i * 800.0);
      expect(
          (NocturnalRmssdState()..fold(nn, okTs)).evaluate([], []).toJson(),
          nocturnalRmssd(nn, okTs).toJson());
    });
  });
}
