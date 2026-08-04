import 'dart:math' as math;

import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

List<int> sinePpg({
  required double bpm,
  required int n,
  double sampleHz = 24.0,
  double amplitude = 1000,
  double offset = 500,
}) {
  final f = bpm / 60.0;
  return List<int>.generate(n, (i) {
    final t = i / sampleHz;
    return (offset + amplitude * math.sin(2 * math.pi * f * t)).round();
  });
}

void main() {
  group('deriveHrFromGen5PpgWaveform', () {
    test('synthetic 72 bpm sine (≥48 samples) recovers ~72', () {
      final samples = sinePpg(bpm: 72, n: 48);
      final hr = deriveHrFromGen5PpgWaveform(samples);
      expect(hr, isNotNull);
      expect(hr!, closeTo(72, 3));
    });

    test('synthetic 120 bpm sine (≥48 samples) recovers ~120', () {
      final samples = sinePpg(bpm: 120, n: 48);
      final hr = deriveHrFromGen5PpgWaveform(samples);
      expect(hr, isNotNull);
      expect(hr!, closeTo(120, 3));
    });

    test('flatline abstains', () {
      expect(deriveHrFromGen5PpgWaveform(List.filled(48, 42)), isNull);
    });

    test('too-short abstains', () {
      expect(deriveHrFromGen5PpgWaveform(sinePpg(bpm: 72, n: 23)), isNull);
    });
  });
}
