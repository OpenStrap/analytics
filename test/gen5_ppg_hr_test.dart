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

  // FABRICATION REGRESSION — "never a fabricated BPM" has to hold for signals
  // with no cardiac content, not only for short or flat ones.
  //
  // The peak search used to consider the BOUNDARIES of its own lag range. At
  // `lag == minLag` the left neighbour was `-infinity`, so the `c <= left`
  // rejection could never fire, and the prominence fallback substituted
  // `c - 1`, making prominence 1.0 — maximal. Any smoothly DECAYING
  // autocorrelation was therefore accepted at the shortest lag and reported as
  // a confident 206 bpm, the top of the 25–230 search range.
  //
  // A monotonically decaying ACF is exactly what baseline wander, a DC drift
  // or a motion artifact produce, so the failure mode was not exotic: the
  // quieter and smoother the input, the more certain the fabricated
  // tachycardia. The fix requires an INTERIOR local maximum — a real turning
  // point with computed neighbours on both sides.
  group('never fabricates a BPM from non-cardiac input', () {
    List<int> wander() => [
          for (var i = 0; i < 480; i++)
            (500 * math.sin(2 * math.pi * i / 400)).round()
        ];
    List<int> ramp() => [for (var i = 0; i < 480; i++) i * 3];
    List<int> step() => [for (var i = 0; i < 480; i++) i < 240 ? 0 : 1000];
    List<int> decay() =>
        [for (var i = 0; i < 480; i++) (1000 * math.exp(-i / 150.0)).round()];

    test('pure baseline wander (slow sine drift, no heartbeat) abstains', () {
      expect(
        deriveHrFromGen5PpgWaveform(wander()),
        isNull,
        reason: 'used to return a confident 206 bpm',
      );
    });

    test('a pure DC ramp abstains', () {
      expect(deriveHrFromGen5PpgWaveform(ramp()), isNull);
    });

    test('a single step edge abstains', () {
      expect(deriveHrFromGen5PpgWaveform(step()), isNull);
    });

    test('no non-cardiac input may report the range boundary (206 bpm)', () {
      final inputs = <String, List<int>>{
        'wander': wander(),
        'ramp': ramp(),
        'step': step(),
        'decay': decay(),
      };
      inputs.forEach((name, wave) {
        expect(
          deriveHrFromGen5PpgWaveform(wave),
          anyOf(isNull, isNot(206)),
          reason: '$name pinned to the top of the search range',
        );
      });
    });

    test('white noise almost never resolves, and never at the boundary', () {
      final rng = math.Random(42);
      var hits = 0;
      for (var t = 0; t < 400; t++) {
        final noise = <int>[
          for (var i = 0; i < 480; i++) rng.nextInt(2001) - 1000
        ];
        final hr = deriveHrFromGen5PpgWaveform(noise);
        if (hr != null) {
          hits++;
          expect(hr, isNot(206));
        }
      }
      expect(hits / 400, lessThan(0.05));
    });
  });

  group('real cardiac signals still resolve after the boundary fix', () {
    test('clean sines across the physiological range stay accurate', () {
      // Integer lags at 24 Hz quantize the answer, and one lag step is worth
      // more at high BPM — hence a proportional tolerance rather than a fixed one.
      for (final bpm in [45, 60, 75, 100, 140]) {
        final hr = deriveHrFromGen5PpgWaveform(sinePpg(bpm: bpm * 1.0, n: 480));
        expect(hr, isNotNull, reason: '$bpm bpm must resolve');
        expect(
          (hr! - bpm).abs(),
          lessThanOrEqualTo((bpm * 0.04).ceil()),
          reason: '$bpm bpm resolved as $hr',
        );
      }
    });
  });
}
