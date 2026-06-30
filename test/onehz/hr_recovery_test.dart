// HRR (heart-rate recovery) — synthetic known-answer tests.
import 'package:test/test.dart';
import 'package:openstrap_analytics/src/onehz/types.dart';
import 'package:openstrap_analytics/src/onehz/workout/hr_recovery.dart';

void main() {
  group('hrRecovery', () {
    test('descending tail yields the expected drop', () {
      // 30 s ramp to peak 170, then linear recovery to 130 over 60 s.
      final tail = <int>[
        for (var i = 0; i < 30; i++) 150 + i, // ... ends at 179? cap below
      ];
      // Rebuild cleanly: 0..30 at ~170 peak, then 60 s dropping 170 -> 130.
      final hr = <int>[];
      for (var i = 0; i < 30; i++) hr.add(170); // pre-end window
      final endIdx = hr.length - 1; // exercise ends here at 170
      for (var s = 1; s <= 70; s++) {
        hr.add((170 - (40 * s / 60)).round().clamp(40, 200));
      }
      final m = hrRecovery(hr, endIndex: endIdx, recoverySec: 60);
      expect(m.present, isTrue);
      expect(m.tier, Tier.estimate);
      expect(m.value!.peakHr, 170);
      // 170 - 130 = 40 bpm drop (±2 for the median window).
      expect(m.value!.dropBpm, closeTo(40, 3));
      expect(tail, isNotEmpty);
    });

    test('HR that stays elevated → absent (still active)', () {
      final hr = [for (var i = 0; i < 100; i++) 165];
      final m = hrRecovery(hr, endIndex: 30, recoverySec: 60);
      expect(m.present, isFalse);
    });

    test('tail too short to reach +60s → absent', () {
      final hr = [for (var i = 0; i < 40; i++) 160 - i];
      final m = hrRecovery(hr, endIndex: 10, recoverySec: 60);
      expect(m.present, isFalse);
    });
  });
}
