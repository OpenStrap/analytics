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
}
