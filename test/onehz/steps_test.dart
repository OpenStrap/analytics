// STEPS — hybrid pedometry tests.
//
// (1) TIER A live pedometer: synthetic walking at a KNOWN cadence on a 100 Hz
//     accel must recover the right step count (±1) and cadence; still/noise
//     must yield ~0; a faster cadence must read more steps than a slower one.
// (2) CALIBRATION: a credible live bout updates the cadence model; fidgeting
//     (low confidence / out-of-band cadence) does not.
// (3) TIER B 1 Hz estimate: sedentary day → ~0; an ambulatory block → a
//     plausible count that scales with the block length; HR gate suppresses
//     stationary arm motion; calibration shifts the cadence used.
//
// Imports the motion barrel by package path (onehz.dart re-exports it too).

import 'dart:math' as math;
import 'package:test/test.dart';
import 'package:openstrap_analytics/src/onehz/types.dart';
import 'package:openstrap_analytics/src/onehz/motion/motion.dart';
import 'package:openstrap_analytics/src/onehz/workout/calories.dart';

/// Synthetic 100 Hz walking: arm-swing fundamental at [stepHz] with a little
/// impact harmonic, plus z-gravity. Amplitude [ampG]. Returns (x,y,z).
(List<double>, List<double>, List<double>) _walk(
  double durationS,
  double stepHz, {
  double fs = 100.0,
  double ampG = 0.25,
  double noiseG = 0.01,
}) {
  final n = (durationS * fs).round();
  final x = <double>[], y = <double>[], z = <double>[];
  // deterministic pseudo-noise (no Math.random — keep test stable)
  var seed = 12345;
  double rnd() {
    seed = (seed * 1103515245 + 12345) & 0x7fffffff;
    return (seed / 0x7fffffff - 0.5) * 2.0;
  }

  for (var i = 0; i < n; i++) {
    final t = i / fs;
    // Real gait's dominant accel is the VERTICAL bob (one impact per step) plus
    // arm swing; put the fundamental on z (gravity axis) so ‖a‖ actually moves.
    final s = ampG * math.sin(2 * math.pi * stepHz * t) +
        0.25 * ampG * math.sin(2 * math.pi * 2 * stepHz * t);
    x.add(0.3 * ampG * math.sin(2 * math.pi * stepHz * t) + noiseG * rnd());
    y.add(noiseG * rnd());
    z.add(1.0 + s + noiseG * rnd());
  }
  return (x, y, z);
}

void main() {
  group('Tier A — live pedometer (100 Hz)', () {
    test('120 spm (2 Hz) for 10 s → ~20 steps, cadence ≈ 120', () {
      final (x, y, z) = _walk(10.0, 2.0);
      final r = livePedometer(x, y, z, sampleRateHz: 100.0);
      expect(r.steps, inInclusiveRange(18, 22), reason: 'want ~20 steps');
      expect(r.cadenceSpm, closeTo(120.0, 15.0));
      expect(r.confidence, greaterThan(0.5));
    });

    test('slower cadence reads fewer steps than faster over equal time', () {
      final slow = _walk(20.0, 1.6); // 96 spm
      final fast = _walk(20.0, 2.2); // 132 spm
      final rs = livePedometer(slow.$1, slow.$2, slow.$3);
      final rf = livePedometer(fast.$1, fast.$2, fast.$3);
      expect(rf.steps, greaterThan(rs.steps));
    });

    test('still wrist → ~0 steps', () {
      final n = 1000;
      final x = List<double>.filled(n, 0.0);
      final y = List<double>.filled(n, 0.0);
      final z = List<double>.filled(n, 1.0);
      final r = livePedometer(x, y, z);
      expect(r.steps, lessThanOrEqualTo(1));
    });

    test('empty / tiny buffer → none', () {
      expect(livePedometer(const [], const [], const []).steps, 0);
      expect(livePedometer([1, 2], [0, 0], [1, 1]).steps, 0);
    });

    test('fidgeting (a few irregular bumps while seated) → ~0 steps', () {
      // 10 s mostly still, with 3 isolated, irregularly-spaced arm bumps.
      const fs = 100.0;
      final n = 1000;
      final x = List<double>.filled(n, 0.0);
      final y = List<double>.filled(n, 0.0);
      final z = List<double>.filled(n, 1.0);
      for (final c in [120, 470, 800]) {
        for (var k = -10; k <= 10; k++) {
          z[c + k] += 0.3 * math.cos(math.pi * k / 20); // a single lobe
        }
      }
      final r = livePedometer(x, y, z, sampleRateHz: fs);
      expect(r.steps, lessThanOrEqualTo(1),
          reason: 'isolated bumps must not form a gait run');
    });

    test('intermittent gestures never reach the min run', () {
      // alternating big/small bumps ~1.5 s apart — irregular, not gait.
      const fs = 100.0;
      final n = 1500;
      final x = List<double>.filled(n, 0.0);
      final y = List<double>.filled(n, 0.0);
      final z = List<double>.filled(n, 1.0);
      var c = 100;
      var big = true;
      while (c < n - 20) {
        final amp = big ? 0.35 : 0.12;
        for (var k = -10; k <= 10; k++) {
          z[c + k] += amp * math.cos(math.pi * k / 20);
        }
        c += big ? 90 : 220; // wildly varying spacing
        big = !big;
      }
      final r = livePedometer(x, y, z, sampleRateHz: fs);
      expect(r.steps, lessThanOrEqualTo(2));
    });
  });

  group('Calibration', () {
    test('credible walking bout seeds + refines the model', () {
      const live = PedometerResult(220, 120, 110.0, 0.25, 0.8);
      final c1 = calibrateCadence(null, live, 0.06);
      expect(c1, isNotNull);
      expect(c1!.cadenceSpm, closeTo(110.0, 0.01));
      expect(c1.n, 1);
      const live2 = PedometerResult(200, 120, 100.0, 0.8, 0.7);
      final c2 = calibrateCadence(c1, live2, 0.05);
      expect(c2!.cadenceSpm, closeTo(105.0, 0.01)); // running mean of 110,100
      expect(c2.n, 2);
    });

    test('fidgeting (low confidence / out-of-band cadence) is ignored', () {
      final prior = const StepCalibration(cadenceSpm: 110, refEnmo: 0.06, n: 5);
      // low confidence
      expect(
          calibrateCadence(prior, const PedometerResult(10, 30, 110, 0.2, 0.2),
                  0.06),
          same(prior));
      // implausible cadence (200 spm)
      expect(
          calibrateCadence(prior, const PedometerResult(100, 30, 200, 0.2, 0.9),
                  0.06),
          same(prior));
      // too short
      expect(
          calibrateCadence(prior, const PedometerResult(20, 10, 110, 0.2, 0.9),
                  0.06),
          same(prior));
    });

    test('round-trips through JSON', () {
      const c = StepCalibration(cadenceSpm: 112.5, refEnmo: 0.071, n: 9);
      final back = StepCalibration.fromJson(c.toJson());
      expect(back!.cadenceSpm, closeTo(112.5, 1e-6));
      expect(back.refEnmo, closeTo(0.071, 1e-6));
      expect(back.n, 9);
    });
  });

  group('Tier B — 1 Hz step estimate', () {
    // Build per-minute motion rows directly (bypass enmoSeries).
    List<MotionMinute> rows(List<double> enmos) => [
          for (var i = 0; i < enmos.length; i++)
            MotionMinute(i * 60000.0, 60, enmos[i], enmos[i], 1.0 + enmos[i]),
        ];
    // A day = `sed` sedentary minutes (low ENMO) + `walk` walking minutes.
    List<MotionMinute> day(int sed, int walk,
            {double sedE = 0.006, double walkE = 0.06}) =>
        rows([...List<double>.filled(sed, sedE), ...List<double>.filled(walk, walkE)]);
    // A learned personal walking signature — the estimate is calibration-gated.
    const cal = StepCalibration(cadenceSpm: 110, refEnmo: 0.06, n: 10);

    test('uncalibrated → a bounded ballpark (no whipsaw)', () {
      // A walking block: even uncalibrated it gives a believable number (fixed
      // gate, continuous cadence), not 0 and not absurd.
      final m = dailyStepEstimate(day(120, 30)); // no calib
      expect(m.present, isTrue);
      expect(m.value!.calibrated, isFalse);
      expect(m.value!.steps, inInclusiveRange(1500, 5000)); // ~30 walking min
    });

    test('calibrated sedentary day → 0 steps', () {
      final m = dailyStepEstimate(rows(List<double>.filled(600, 0.006)), calib: cal);
      expect(m.value!.steps, 0);
    });

    test('a quiet day with HR at rest → 0 steps', () {
      // Below-floor movement OR resting HR → nothing counts (no whipsaw to huge).
      final m = dailyStepEstimate(rows(List<double>.filled(300, 0.02)),
          calib: cal,
          hrPerMin: List<double>.filled(300, 58.0),
          restingHr: 58);
      expect(m.value!.steps, 0);
    });

    test('a walking block over a sedentary baseline → minutes × cadence', () {
      final m = dailyStepEstimate(day(120, 30), calib: cal);
      expect(m.value!.ambulatoryMinutes, inInclusiveRange(28, 30));
      expect(m.value!.steps, inInclusiveRange(2800, 3600)); // ~30 × ~110
    });

    test('more walking → more steps', () {
      final few = dailyStepEstimate(day(120, 10), calib: cal);
      final many = dailyStepEstimate(day(120, 40), calib: cal);
      expect(many.value!.steps, greaterThan(few.value!.steps));
    });

    test('HR (soft veto) suppresses walking-amplitude minutes at rest HR', () {
      final m = dailyStepEstimate(day(120, 30),
          calib: cal,
          hrPerMin: [
            ...List<double>.filled(120, 58.0),
            ...List<double>.filled(30, 58.0)
          ],
          restingHr: 58);
      expect(m.value!.ambulatoryMinutes, 0, reason: 'HR at rest → not walking');
    });

    test('HR elevated over the walking block → it counts', () {
      final m = dailyStepEstimate(day(120, 30),
          calib: cal,
          hrPerMin: [
            ...List<double>.filled(120, 58.0),
            ...List<double>.filled(30, 95.0)
          ],
          restingHr: 58);
      expect(m.value!.ambulatoryMinutes, greaterThan(20));
    });

    test('a brief movement minute contributes only a little', () {
      final e = List<double>.filled(60, 0.006);
      e[30] = 0.20; // one elevated minute
      final m = dailyStepEstimate(rows(e), calib: cal);
      // It counts (a brief walk is real), but a single minute can't be large.
      expect(m.value!.ambulatoryMinutes, 1);
      expect(m.value!.steps, lessThan(200));
    });

    test('a higher personal cadence lifts the count', () {
      final slow = dailyStepEstimate(day(120, 30), calib: cal);
      final fast = dailyStepEstimate(day(120, 30),
          calib: const StepCalibration(cadenceSpm: 135, refEnmo: 0.06, n: 10));
      expect(fast.value!.cadenceUsed, greaterThan(slow.value!.cadenceUsed));
      expect(fast.value!.steps, greaterThan(slow.value!.steps));
    });

    test('empty motion → absent ESTIMATE', () {
      final m = dailyStepEstimate(const []);
      expect(m.present, isFalse);
      expect(m.tier, Tier.estimate);
    });
  });

  group('Calories — BMR + daily TDEE', () {
    test('Mifflin–St Jeor matches the textbook (M, 80kg, 180cm, 30y)', () {
      // 10*80 + 6.25*180 - 5*30 + 5 = 800 + 1125 - 150 + 5 = 1780
      expect(Calories.mifflinBmrKcalDay(80, 180, 30, 'male'),
          closeTo(1780.0, 1e-6));
      // women: ... - 161 = 1614
      expect(Calories.mifflinBmrKcalDay(80, 180, 30, 'female'),
          closeTo(1614.0, 1e-6));
    });

    test('all-resting day → total ≈ basal, active ≈ 0', () {
      final profile = const WorkoutUserProfile(
          weightKg: 80, heightCm: 180, age: 30, sex: 'male');
      // 1440 minutes at a low HR (40% HRmax → below active surplus)
      final hr = List<double>.filled(1440, 70.0);
      final e = Calories.dailyEnergy(hr, profile: profile);
      expect(e.basal, closeTo(1780.0, 1.0));
      expect(e.active, closeTo(0.0, 60.0)); // tiny if any
      expect(e.total, greaterThanOrEqualTo(e.basal));
    });

    test('an exercise block adds active calories on top of basal', () {
      final profile = const WorkoutUserProfile(
          weightKg: 80, heightCm: 180, age: 30, sex: 'male');
      final hr = [
        ...List<double>.filled(1380, 65.0),
        ...List<double>.filled(60, 150.0), // 1 h hard
      ];
      final e = Calories.dailyEnergy(hr, profile: profile, hrmax: 190);
      expect(e.active, greaterThan(300.0));
      expect(e.total, closeTo(e.basal + e.active, 1e-6));
    });
  });

}
