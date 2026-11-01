import 'dart:convert';
import 'dart:math' as math;

import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

void main() {
  // Same slow-breathing model as upstream respiration_test.dart. Its true
  // peak is below 9 br/min; the in-band skirt must never become a measurement.
  test('RSA floor outcomes survive chunks, JSON restart and provisional tails', () {
    final random = math.Random(1);
    final nn = <double>[], times = <double>[];
    var clock = 0.0;
    while (clock < 1800e3) {
      final sec = clock / 1000;
      final interval = 1000 +
          30 * math.sin(2 * math.pi * 8 / 60 * sec) +
          10 * math.sin(2 * math.pi * 0.1 * sec) +
          (random.nextDouble() * 20 - 10);
      clock += interval;
      nn.add(interval);
      times.add(clock);
    }
    final batch = rsaRespRate(nn, times, artifactFraction: 0);
    expect(batch.present, isFalse);
    expect(batch.note, contains('floor'));
    var stream = RsaRespStream();
    const split = 1000;
    stream.fold(nn.sublist(0, split), times.sublist(0, split));
    final saved = stream.toJson();
    expect((saved['closed'] as List).where((r) => r['kind'] == 5), isNotEmpty);
    stream = RsaRespStream.fromJson(jsonDecode(jsonEncode(saved)) as Map<String, dynamic>);
    final withTail = stream.snapshot(artifactFraction: 0,
        tailNnMs: nn.sublist(split), tailNnTimesMs: times.sublist(split));
    expect(withTail.toJson(), batch.toJson());
    stream.fold(nn.sublist(split), times.sublist(split));
    expect(stream.snapshot(artifactFraction: 0).toJson(), batch.toJson());
    for (final old in [1, 2]) {
      expect(() => RsaRespStream.fromJson({...saved, 'version': old}),
          throwsFormatException);
    }
  });
}
