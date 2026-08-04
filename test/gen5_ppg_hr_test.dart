import 'dart:math' as math;

import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

List<int> sinePpg({
  required double bpm,
  required int n,
  double sampleHz = 24.0,
  double amplitude = 1000,
  double offset = 500,
  double noiseStd = 0,
  int? seed,
}) {
  final rng = seed != null ? math.Random(seed) : null;
  final f = bpm / 60.0;
  return List<int>.generate(n, (i) {
    final t = i / sampleHz;
    var v = offset + amplitude * math.sin(2 * math.pi * f * t);
    if (noiseStd > 0 && rng != null) {
      // Box–Muller-ish: uniform noise is enough for a regression guard.
      v += (rng.nextDouble() * 2 - 1) * noiseStd;
    }
    return v.round();
  });
}

void main() {
  group('deriveHrFromGen5PpgWaveform', () {
    test('synthetic 72 bpm sine (10 s window) recovers ~72', () {
      final samples = sinePpg(bpm: 72, n: kGen5PpgHrMinSamples);
      final hr = deriveHrFromGen5PpgWaveform(samples);
      expect(hr, isNotNull);
      expect(hr!, closeTo(72, 3));
    });

    test('synthetic 120 bpm sine (10 s window) recovers ~120', () {
      final samples = sinePpg(bpm: 120, n: kGen5PpgHrMinSamples);
      final hr = deriveHrFromGen5PpgWaveform(samples);
      expect(hr, isNotNull);
      expect(hr!, closeTo(120, 3));
    });

    test('low HR 45 bpm needs a longer window (12 s)', () {
      final samples = sinePpg(bpm: 45, n: 288);
      final hr = deriveHrFromGen5PpgWaveform(samples);
      expect(hr, isNotNull);
      expect(hr!, closeTo(45, 3));
    });

    test('noisy 72 bpm sine still recovers within tolerance', () {
      final samples = sinePpg(
        bpm: 72,
        n: kGen5PpgHrMinSamples,
        noiseStd: 80,
        seed: 42,
      );
      final hr = deriveHrFromGen5PpgWaveform(samples);
      expect(hr, isNotNull);
      expect(hr!, closeTo(72, 5));
    });

    test('flatline abstains', () {
      expect(
        deriveHrFromGen5PpgWaveform(List.filled(kGen5PpgHrMinSamples, 42)),
        isNull,
      );
    });

    test('too-short abstains (under 10 s)', () {
      expect(deriveHrFromGen5PpgWaveform(sinePpg(bpm: 72, n: 239)), isNull);
      expect(deriveHrFromGen5PpgWaveform(sinePpg(bpm: 72, n: 23)), isNull);
    });
  });
}
