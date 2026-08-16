// HRR (heart-rate recovery) — synthetic known-answer tests.
import 'dart:math' as math;

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

    test('with tsSec the PEAK window is clock time, not array positions', () {
      // an-motion-4. Supplying tsSec used to convert only the +60 s recovery
      // point; the peak window and the ±3 s median window stayed positional.
      // On this 20 s-spaced tail a 30-POSITION peak window spanned 580 s of
      // clock, so "peak at exercise end" came from nine minutes earlier:
      // pre-fix peak 180, drop 69, confidence 0.90 (bonus included). The bout
      // actually ended at 151 bpm, and a real 30 s window holds 151-152.
      final hr = <int>[];
      final ts = <int>[];
      var t = 0;
      for (var i = 0; i < 30; i++) {
        hr.add(180 - i); // 180 -> 151 over 580 s
        ts.add(t);
        t += 20;
      }
      for (var i = 0; i < 200; i++) {
        hr.add(151 - i < 100 ? 100 : 151 - i);
        ts.add(t);
        t += 1;
      }
      final m = hrRecovery(hr, endIndex: 29, tsSec: ts, peakWindowSec: 30);
      expect(m.present, isTrue, reason: m.note);
      expect(m.value!.peakHr, 152, reason: 'the two samples inside 30 s');
      expect(m.value!.dropBpm, 41);
      // The +0.2 timestamped bonus is withheld: 20 s of tail is not the 30 s
      // asked for, so the timestamps proved the window short, not sound.
      expect(m.confidence, closeTo(0.7, 1e-9));
    });

    test('a dense timestamped tail still earns the +0.2 bonus', () {
      final hr = <int>[];
      final ts = <int>[];
      for (var i = 0; i < 30; i++) {
        hr.add(170);
        ts.add(i);
      }
      for (var s = 1; s <= 70; s++) {
        hr.add((170 - (40 * s / 60)).round());
        ts.add(29 + s);
      }
      final m = hrRecovery(hr, endIndex: 29, tsSec: ts, peakWindowSec: 30);
      expect(m.present, isTrue, reason: m.note);
      expect(m.confidence, closeTo(0.9, 1e-9));
    });

    test('tail too short to reach +60s → absent', () {
      final hr = [for (var i = 0; i < 40; i++) 160 - i];
      final m = hrRecovery(hr, endIndex: 10, recoverySec: 60);
      expect(m.present, isFalse);
    });
  });

  // -------------------------------------------------------------------------
  // CV-08 — the exponential recovery time constant, alongside HRR-60.
  // -------------------------------------------------------------------------
  group('hrRecovery — tau', () {
    /// A 1 Hz tail: 30 s of steady exercise at [start] bpm, then
    /// `asymptote + amp·exp(-t/tau)` for [postSec] seconds.
    ({List<int> hr, List<int> ts, int end}) tail({
      required double asymptote,
      required double amp,
      required double tau,
      int postSec = 200,
      double noise = 0,
    }) {
      final hr = <int>[];
      final ts = <int>[];
      var t = 0;
      for (var i = 0; i < 30; i++) {
        hr.add((asymptote + amp).round());
        ts.add(t++);
      }
      final end = hr.length - 1;
      for (var s = 1; s <= postSec; s++) {
        final v = asymptote +
            amp * math.exp(-s / tau) +
            (noise == 0 ? 0.0 : noise * math.sin(s / 3.0));
        hr.add(v.round());
        ts.add(t++);
      }
      return (hr: hr, ts: ts, end: end);
    }

    test('recovers a known time constant from a clean tail', () {
      final d = tail(asymptote: 70, amp: 100, tau: 55);
      final m = hrRecovery(d.hr, endIndex: d.end, tsSec: d.ts);
      expect(m.present, isTrue);
      final v = m.value!;
      expect(v.tauSec, isNotNull);
      expect(v.tauSec!, closeTo(55, 3));
      expect(v.tauAmpBpm!, closeTo(100, 4));
      expect(v.tauAsymptoteBpm!, closeTo(70, 3));
      // The intensity it started from ships WITH it — tau is not comparable
      // across intensities and the number that conditions it is not optional.
      expect(v.tauStartHr!, closeTo(170, 4));
      expect(v.tauResidualRatio!, lessThan(0.05));
      expect(v.tauAbsenceReason, isNull);
      // And it did NOT replace HRR-60.
      expect(v.dropBpm, greaterThan(0));
    });

    test('a short tail abstains with a reason, it does not extrapolate', () {
      // The +75 s tail the caller slices today. Half a window is not a curve.
      final d = tail(asymptote: 70, amp: 100, tau: 55, postSec: 75);
      final v = hrRecovery(d.hr, endIndex: d.end, tsSec: d.ts).value!;
      expect(v.tauSec, isNull);
      expect(v.tauAbsenceReason, startsWith('tau_tail_short'));
      expect(v.dropBpm, greaterThan(0), reason: 'HRR-60 still publishes');
    });

    test('without timestamps there is no clock, so there is no tau', () {
      final d = tail(asymptote: 70, amp: 100, tau: 55);
      final v = hrRecovery(d.hr, endIndex: d.end).value!;
      expect(v.tauSec, isNull);
      expect(v.tauAbsenceReason, 'tau_needs_timestamps');
    });

    test('a tail that is not one clean exponential is rejected', () {
      // Noise the size of the swing itself: the residual gate is the feature.
      final d = tail(asymptote: 70, amp: 20, tau: 55, noise: 12);
      final v = hrRecovery(d.hr, endIndex: d.end, tsSec: d.ts).value!;
      expect(v.tauSec, isNull);
      expect(v.tauAbsenceReason, 'tau_fit_rejected');
    });

    test('the residual gate is a FRACTION of the swing, not bpm', () {
      // Same shape, same relative noise, ten times the amplitude. A bpm
      // threshold would pass one and fail the other; the same recovery on a
      // strap with a different noise floor is still the same recovery.
      final small = tail(asymptote: 70, amp: 20, tau: 50, noise: 0.4);
      final big = tail(asymptote: 70, amp: 200, tau: 50, noise: 4.0);
      final a =
          hrRecovery(small.hr, endIndex: small.end, tsSec: small.ts).value!;
      final b = hrRecovery(big.hr, endIndex: big.end, tsSec: big.ts).value!;
      expect(a.tauSec, isNotNull);
      expect(b.tauSec, isNotNull);
      expect(a.tauResidualRatio!, closeTo(b.tauResidualRatio!, 0.03));
    });
  });
}
