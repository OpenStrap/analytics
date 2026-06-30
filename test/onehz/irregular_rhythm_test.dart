// Irregular-rhythm SCREEN — synthetic known-answer tests.
import 'dart:math' as math;
import 'package:test/test.dart';
import 'package:openstrap_analytics/src/onehz/types.dart';
import 'package:openstrap_analytics/src/onehz/clinical/irregular_rhythm.dart';

void main() {
  group('irregularBeatScreen', () {
    test('organised sinus rhythm does NOT flag', () {
      // Regular ~60 bpm (1000 ms) with tiny RSA-like wobble → low SD1/SD2, low pNN.
      final rr = <double>[
        for (var i = 0; i < 1200; i++) 1000 + 15 * math.sin(i / 8)
      ];
      final m = irregularBeatScreen(rr);
      expect(m.present, isTrue);
      expect(m.tier, Tier.estimate);
      expect(m.value!.flag, isFalse);
      expect(m.value!.sd1sd2, lessThan(0.70));
    });

    test('irregularly-irregular rhythm flags', () {
      // Large beat-to-beat jumps (alternating ±200 ms) → round Poincaré + high pNN70.
      final rnd = math.Random(7);
      final rr = <double>[
        for (var i = 0; i < 1200; i++)
          800.0 + (rnd.nextBool() ? 250 : -50) + rnd.nextInt(120)
      ];
      final m = irregularBeatScreen(rr);
      expect(m.present, isTrue);
      expect(m.value!.flag, isTrue);
      expect(m.value!.pnnPct, greaterThanOrEqualTo(30));
    });

    test('too few beats → absent', () {
      final m = irregularBeatScreen([for (var i = 0; i < 100; i++) 1000]);
      expect(m.present, isFalse);
    });

    test('high artifact fraction suppresses the screen', () {
      final rr = [for (var i = 0; i < 1200; i++) 1000.0];
      final m = irregularBeatScreen(rr, artifactFraction: 0.5);
      expect(m.present, isFalse);
      expect(m.note, contains('artifact'));
    });
  });
}
