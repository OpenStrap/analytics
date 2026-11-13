import 'dart:convert';
import 'dart:math' as math;

import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

import 'welch_stream_test.dart' show expectSameHrv, expectSameResp;

void main() {
  // why: compaction must retain powers of completed segments, including ULF.
  // # catches: a retained span shorter than segSec hides previously accumulated power.
  test('ULF stays present after ten-hour compaction', () {
    final nn = List.generate(18001, (i) => 1900 + 20 * math.sin(i / 1000));
    final ts = List.generate(nn.length, (i) => i * 2000.0);
    final s = HrvFreqStream()..fold(nn, ts);
    final want = hrvFreq(nn, ts, artifactFraction: 0);
    expect(want.value!.ulf, isNotNull);
    expectSameHrv(s.snapshot(artifactFraction: 0), want, 'ten hours');
  });
  // why: capped-reset clocks may regress slightly; batch drops at most 5%.
  // # catches: throwing at the first regression or forgetting omissions at checkpoint.
  test('spectral stream follows batch regression policy at prefixes and tails',
      () {
    final nn = List.generate(801, (i) => 800 + 20 * math.sin(i / 4));
    final ts = List.generate(nn.length, (i) => i * 800.0);
    ts[410] = ts[409] - 500;
    var s = HrvFreqStream();
    s.fold(nn.sublist(0, 410), ts.sublist(0, 410));
    expectSameHrv(
        s.snapshot(
            tailNnMs: nn.sublist(410),
            tailNnTimesMs: ts.sublist(410),
            artifactFraction: 0),
        hrvFreq(nn, ts, artifactFraction: 0),
        'tail');
    s.fold(nn.sublist(410), ts.sublist(410));
    s = HrvFreqStream.fromJson(
        jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>);
    expectSameHrv(s.snapshot(artifactFraction: 0),
        hrvFreq(nn, ts, artifactFraction: 0), 'fold');
    final bad = HrvFreqStream()
      ..fold(List.filled(40, 800.0),
          [for (var i = 0; i < 40; i++) i < 20 ? i * 800.0 : 1000.0]);
    expect(bad.snapshot(artifactFraction: 0).note, 'regressing beat time');
  });
  // why: non-finite provisional clocks must abstain, just like batch, before order checks.
  // # catches: -Infinity is treated as a finite backward timestamp and throws.
  test('RSA and CVHR abstain on a non-finite tail', () {
    final nn = List.filled(70, 800.0);
    final ts = List.generate(70, (i) => i * 800.0);
    final rsa = RsaRespStream()..fold(nn, ts);
    final cvhr = CvhrStream()..fold(nn, ts);
    for (final bad in [double.negativeInfinity, double.infinity, double.nan]) {
      final r = rsa
          .snapshot(tailNnMs: [800], tailNnTimesMs: [bad], artifactFraction: 0);
      expectSameResp(
          r,
          rsaRespRate([...nn, 800], [...ts, bad], artifactFraction: 0),
          'RSA $bad');
      final c = cvhr
          .snapshot(tailNnMs: [800], tailNnTimesMs: [bad], artifactFraction: 0);
      expect(c.present, isFalse);
      expect(c.note, 'non-finite beat time');
    }
  });
}
