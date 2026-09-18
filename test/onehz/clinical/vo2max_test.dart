// Submax VO2max estimate — known-answer + gating tests.
import 'package:test/test.dart';
import 'package:openstrap_analytics/src/onehz/types.dart';
import 'package:openstrap_analytics/src/onehz/clinical/vo2max.dart';

void main() {
  group('vo2maxSubmaxEstimate', () {
    test('plausible steady run yields a plausible VO2max', () {
      // 10 km/h (2.78 m/s) run, HR 150, rest 55, hrmax 185 -> %HRR ~ 73%.
      final m = vo2maxSubmaxEstimate(
        speedMps: 2.78,
        avgHrBpm: 150,
        boutDurationSec: 600,
        restingHrBpm: 55,
        hrMaxBpm: 185,
      );
      expect(m.present, isTrue);
      expect(m.tier, Tier.estimate);
      expect(m.value, greaterThan(30));
      expect(m.value, lessThan(70));
      expect(m.confidence, greaterThan(0));
      expect(m.confidence, lessThanOrEqualTo(0.6));
    });

    test('walking bout uses the walking equation and still resolves', () {
      final m = vo2maxSubmaxEstimate(
        speedMps: 1.4, // ~5 km/h, below the run threshold
        avgHrBpm: 120,
        boutDurationSec: 600,
        restingHrBpm: 58,
        hrMaxBpm: 180,
      );
      expect(m.present, isTrue);
    });

    test('bout shorter than the steady-state floor abstains', () {
      final m = vo2maxSubmaxEstimate(
        speedMps: 2.78,
        avgHrBpm: 150,
        boutDurationSec: 120,
        restingHrBpm: 55,
        hrMaxBpm: 185,
      );
      expect(m.present, isFalse);
      expect(m.note, contains('too short'));
    });

    test('near-maximal effort (too high %HRR) abstains', () {
      final m = vo2maxSubmaxEstimate(
        speedMps: 4.0,
        avgHrBpm: 179,
        boutDurationSec: 600,
        restingHrBpm: 55,
        hrMaxBpm: 185,
      );
      expect(m.present, isFalse);
      expect(m.note, contains('%HRR band'));
    });

    test('too-easy effort (low %HRR) abstains', () {
      final m = vo2maxSubmaxEstimate(
        speedMps: 1.2,
        avgHrBpm: 70,
        boutDurationSec: 600,
        restingHrBpm: 55,
        hrMaxBpm: 185,
      );
      expect(m.present, isFalse);
      expect(m.note, contains('%HRR band'));
    });

    test('hr_max too close to resting_hr abstains rather than divide-by-noise', () {
      final m = vo2maxSubmaxEstimate(
        speedMps: 2.78,
        avgHrBpm: 90,
        boutDurationSec: 600,
        restingHrBpm: 75,
        hrMaxBpm: 90,
      );
      expect(m.present, isFalse);
      expect(m.note, contains('unreliable'));
    });

    test('zero/negative speed abstains', () {
      final m = vo2maxSubmaxEstimate(
        speedMps: 0,
        avgHrBpm: 150,
        boutDurationSec: 600,
        restingHrBpm: 55,
        hrMaxBpm: 185,
      );
      expect(m.present, isFalse);
    });
  });
}
