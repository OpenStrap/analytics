import 'package:test/test.dart';
import 'package:openstrap_analytics/onehz.dart';

void main() {
  group('hrLedSleepWindow (Approach 2 fallback)', () {
    // Build a day: active morning (~72 bpm), a sustained night dip (~50 bpm),
    // active tail. tsSec is contiguous 1 Hz from an arbitrary epoch.
    ({List<double> hr, List<int> ts}) day(int dayH, int nightH, int tailH,
        {double nightBpm = 50, List<int> arouseAt = const []}) {
      final hr = <double>[];
      final ts = <int>[];
      const t0 = 1700000000;
      var t = t0;
      void seg(int secs, double bpm, {bool noise = false}) {
        for (var i = 0; i < secs; i++) {
          hr.add(bpm + (noise ? 6 * ((i % 7) - 3) : 0.0));
          ts.add(t++);
        }
      }
      seg(dayH * 3600, 72, noise: true);
      final nightStart = hr.length;
      seg(nightH * 3600, nightBpm);
      for (final a in arouseAt) {
        final idx = nightStart + a;
        if (idx < hr.length) hr[idx] = 80; // brief arousal spike
      }
      seg(tailH * 3600, 72, noise: true);
      return (hr: hr, ts: ts);
    }

    test('sustained night dip → finds a window of ~the dip length', () {
      final d = day(2, 7, 1);
      final w = hrLedSleepWindow(d.hr, d.ts,
          hrBaseline: List<double>.filled(120, 72));
      expect(w, isNotNull);
      // ~7h dip (bridge tolerates the edges); well over the 2h floor.
      expect(w!.durationSec, greaterThan(6 * 3600));
      expect(w.durationSec, lessThan(8 * 3600));
      expect(w.thresholdBpm, lessThan(72));
    });

    test('brief arousals do not fragment the dip', () {
      final d = day(2, 7, 1, arouseAt: [2 * 3600, 4 * 3600, 5 * 3600 + 1800]);
      final w = hrLedSleepWindow(d.hr, d.ts,
          hrBaseline: List<double>.filled(120, 72));
      expect(w, isNotNull);
      expect(w!.durationSec, greaterThan(6 * 3600));
    });

    test('no dip (flat elevated HR all day) → null', () {
      final hr = <double>[];
      final ts = <int>[];
      const t0 = 1700000000;
      for (var i = 0; i < 6 * 3600; i++) {
        hr.add(74 + (i % 5).toDouble());
        ts.add(t0 + i);
      }
      final w = hrLedSleepWindow(hr, ts, hrBaseline: List<double>.filled(60, 75));
      expect(w, isNull);
    });

    test('dip too short (<2h) → null', () {
      final d = day(2, 1, 1); // only a 1h dip
      final w = hrLedSleepWindow(d.hr, d.ts,
          hrBaseline: List<double>.filled(120, 72));
      expect(w, isNull);
    });
  });
}
