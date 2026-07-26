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

  group('Tier B — personalDynFloor', () {
    test('insufficient pooled history → null (never a constant)', () {
      expect(personalDynFloor(List<double>.filled(1999, 0.5)), isNull);
      expect(personalDynFloor(List<double>.filled(2000, 0.5)), isNotNull);
      expect(personalDynFloor(const []), isNull);
    });

    test('a degenerate (all-zero) pool → null, not a floor of 0', () {
      // A floor of 0 would pass every minute — abstaining is the honest answer.
      expect(personalDynFloor(List<double>.filled(3000, 0.0)), isNull);
    });

    test('returns the requested quantile of the pooled distribution', () {
      final pool = [for (var i = 0; i < 3000; i++) i / 3000.0];
      expect(personalDynFloor(pool), closeTo(0.9, 0.01));
      expect(personalDynFloor(pool, quantile: 0.5), closeTo(0.5, 0.01));
    });

    test('the minimum-history requirement is a named, overridable constant', () {
      expect(personalDynFloorMinMinutes, 2000);
      expect(
          personalDynFloor(List<double>.filled(50, 0.4), minMinutes: 10),
          closeTo(0.4, 1e-9));
    });
  });

  // The storage-bound variant. A caller that prunes its raw substrate within
  // days cannot re-read trailing minutes, so it persists ONE value per day.
  group('Tier B — personalDynFloorFromDailySummaries', () {
    test('too few trailing days → null (never a constant)', () {
      expect(
          personalDynFloorFromDailySummaries(
              List<double>.filled(personalDynFloorMinDays - 1, 0.44)),
          isNull);
      expect(
          personalDynFloorFromDailySummaries(
              List<double>.filled(personalDynFloorMinDays, 0.44)),
          isNotNull);
      expect(personalDynFloorFromDailySummaries(const []), isNull);
    });

    test('a single anomalous day cannot move the floor (median, not mean)', () {
      // The whole point of a multi-day anchor: one day spent travelling, or
      // with the wrist in an odd posture, must not drag the threshold.
      final normal = <double>[0.44, 0.43, 0.45, 0.44, 0.46, 0.43, 0.45];
      final withOutlier = [...normal, 9.0];
      final a = personalDynFloorFromDailySummaries(normal)!;
      final b = personalDynFloorFromDailySummaries(withOutlier)!;
      expect((a - b).abs(), lessThan(0.02),
          reason: 'a 20x outlier day must barely move a median-based floor');
    });

    test('degenerate/non-positive day summaries are dropped, not averaged in',
        () {
      expect(personalDynFloorFromDailySummaries(List<double>.filled(8, 0.0)),
          isNull);
      final mixed = <double>[0.44, 0.0, 0.45, -1.0, 0.43, 0.44, 0.46, 0.45];
      // Only the 6 positive days survive, which still clears the minimum.
      expect(personalDynFloorFromDailySummaries(mixed), closeTo(0.445, 0.01));
    });
  });

  group('Tier B — dailyDynSummary (what the caller persists)', () {
    List<MotionMinute> mins(List<double> dyn, {int n = 60}) => [
          for (var i = 0; i < dyn.length; i++)
            MotionMinute(i * 60000.0, n, 0.055, 0.02, 1.055, dyn[i]),
        ];

    test('a day too thin to summarise yields null, not a fabricated level', () {
      expect(dailyDynSummary(mins(List<double>.filled(59, 0.4))), isNull);
      expect(dailyDynSummary(mins(List<double>.filled(60, 0.4))), isNotNull);
      expect(dailyDynSummary(const []), isNull);
    });

    test('uncovered minutes do not count toward the summary', () {
      // 200 rows but all sparse → below the covered-minute floor → null.
      expect(dailyDynSummary(mins(List<double>.filled(200, 0.4), n: 5)),
          isNull);
    });

    test('summarises this day at the same quantile the floor is defined on',
        () {
      final day = [for (var i = 0; i < 1000; i++) i / 1000.0];
      expect(dailyDynSummary(mins(day)), closeTo(0.9, 0.01));
    });

    test('round-trips: per-day summaries feed the multi-day floor', () {
      // End-to-end of the persistence path: summarise each day, pool the
      // summaries, get a floor — the exact sequence the caller performs.
      final summaries = <double>[
        for (var d = 0; d < 7; d++)
          dailyDynSummary(mins([for (var i = 0; i < 500; i++) i / 1000.0]))!
      ];
      final floor = personalDynFloorFromDailySummaries(summaries);
      expect(floor, isNotNull);
      expect(floor!, greaterThan(0));
    });
  });

  group('Tier B — 1 Hz active-minutes estimate', () {
    // Per-minute motion rows built directly (bypassing enmoSeries). ENMO/MAD/
    // meanMag are filled with DELIBERATELY MISLEADING values: every sedentary
    // minute carries an ENMO of 0.055 g, just above the absolute 0.05 g walking
    // floor the old estimator used. If anything ever re-introduces an ENMO-based
    // decision path, these tests break loudly instead of shipping 39k steps.
    List<MotionMinute> rows(List<double> dyn) => [
          for (var i = 0; i < dyn.length; i++)
            MotionMinute(i * 60000.0, 60, 0.055, 0.02, 1.055, dyn[i]),
        ];
    const sedDyn = 0.02; // a sedentary minute's dynamic amplitude (g)
    const walkDyn = 0.60; // an ambulatory minute's (g)
    const floorG = 0.375; // the kind of value personalDynFloor yields in practice
    // A day = `sed` sedentary minutes then `walk` ambulatory minutes.
    List<MotionMinute> day(int sed, int walk) => rows([
          ...List<double>.filled(sed, sedDyn),
          ...List<double>.filled(walk, walkDyn),
        ]);
    // A measured personal cadence from Tier A (100 Hz, real counts).
    const cal = StepCalibration(cadenceSpm: 110, refEnmo: 0.06, n: 10);

    test('COLD START: no personal floor → ABSTAIN with a need_baseline note', () {
      final m = dailyStepEstimate(day(120, 30),
          personalDynFloorG: null, pooledMinutesAvailable: 640);
      expect(m.present, isFalse, reason: 'no constant fallback is permitted');
      expect(m.confidence, 0);
      expect(m.tier, Tier.estimate);
      expect(m.note, 'need_baseline:have=640,need=$personalDynFloorMinMinutes');
    });

    test('a non-positive floor is treated as absent, not as "pass everything"',
        () {
      final m = dailyStepEstimate(day(120, 30), personalDynFloorG: 0.0);
      expect(m.present, isFalse);
      expect(m.note, startsWith('need_baseline:'));
    });

    test('REGRESSION: a day whose sedentary minutes sit just above an ABSOLUTE '
        '0.05 g floor produces no active minutes', () {
      // The measured failure shape: a calibration excursion lifted every
      // sedentary minute of one day above the old absolute 0.05 g gate, and the
      // day reported 39,384 steps against a true ~2,000. The personal floor is
      // a multi-day reference, so a whole quiet day sitting at 0.055 g simply
      // sits far below it — there is nothing for a drift to push it over.
      final drifted = rows(List<double>.filled(1400, 0.055));
      final m = dailyStepEstimate(drifted, personalDynFloorG: floorG);
      expect(m.value!.activeMinutes, 0);
      expect(m.value!.steps, 0);
      expect(m.value!.stepsHigh, 0);
    });

    test('REGRESSION: a quiet day cannot collapse its own threshold', () {
      // The mirror-image failure of a SAME-DAY relative baseline (day p20 +
      // 4·MAD): on a quiet day the baseline collapses and everything passes.
      // The floor here comes from history, so a quiet day stays quiet.
      final quiet = rows(List<double>.filled(1400, sedDyn));
      final m = dailyStepEstimate(quiet, personalDynFloorG: floorG);
      expect(m.value!.activeMinutes, 0);
    });

    test('an ambulatory block over a sedentary day → active minutes × the '
        'cadence band', () {
      final m = dailyStepEstimate(day(120, 30), personalDynFloorG: floorG);
      expect(m.present, isTrue);
      expect(m.value!.activeMinutes, 30);
      expect(m.value!.calibrated, isFalse);
      // population band 100–130 spm (Tudor-Locke 2011)
      expect(m.value!.stepsLow, 3000);
      expect(m.value!.stepsHigh, 3900);
      expect(m.value!.steps, 3450); // midpoint, the back-compat scalar
      expect(m.value!.steps,
          inInclusiveRange(m.value!.stepsLow, m.value!.stepsHigh));
      expect(m.value!.dynFloorG, closeTo(floorG, 1e-12));
      expect(m.tier, Tier.estimate);
    });

    test('more ambulatory minutes → more steps, and the range scales with them',
        () {
      final few = dailyStepEstimate(day(120, 10), personalDynFloorG: floorG);
      final many = dailyStepEstimate(day(120, 40), personalDynFloorG: floorG);
      expect(many.value!.activeMinutes,
          greaterThan(few.value!.activeMinutes));
      expect(many.value!.steps, greaterThan(few.value!.steps));
      expect(many.value!.stepsHigh - many.value!.stepsLow,
          greaterThan(few.value!.stepsHigh - few.value!.stepsLow));
    });

    test('VIGOROUS CEILING: motion far above the floor is not walking', () {
      // 30 minutes of violent arm motion (shaking / a lifting set): well over
      // floor × vigorousCeilingRatio, so it is activity but not ambulation.
      final m = dailyStepEstimate(
          rows([
            ...List<double>.filled(120, sedDyn),
            ...List<double>.filled(30, floorG * 5),
          ]),
          personalDynFloorG: floorG);
      expect(m.value!.activeMinutes, 0);
      // …and raising the ceiling lets the same minutes through, proving the
      // ceiling (not some other gate) was what rejected them.
      final loose = dailyStepEstimate(
          rows([
            ...List<double>.filled(120, sedDyn),
            ...List<double>.filled(30, floorG * 5),
          ]),
          personalDynFloorG: floorG,
          vigorousCeilingRatio: 10.0);
      expect(loose.value!.activeMinutes, 30);
    });

    test('HR GATE: ambulatory-amplitude minutes at resting HR do not count', () {
      final m = dailyStepEstimate(day(120, 30),
          personalDynFloorG: floorG,
          hrPerMin: [
            ...List<double>.filled(120, 58.0),
            ...List<double>.filled(30, 58.0)
          ],
          restingHr: 58);
      expect(m.value!.activeMinutes, 0, reason: 'HR at rest → not walking');
    });

    test('HR GATE: HR elevated over the block → it counts', () {
      final m = dailyStepEstimate(day(120, 30),
          personalDynFloorG: floorG,
          hrPerMin: [
            ...List<double>.filled(120, 58.0),
            ...List<double>.filled(30, 95.0)
          ],
          restingHr: 58);
      expect(m.value!.activeMinutes, 30);
    });

    test('HR GATE: resting HR falls back to the day p10 when none is supplied',
        () {
      final m = dailyStepEstimate(day(120, 30),
          personalDynFloorG: floorG,
          hrPerMin: [
            ...List<double>.filled(120, 55.0),
            ...List<double>.filled(30, 57.0), // < p10 + 8 bpm
          ]);
      expect(m.value!.activeMinutes, 0);
    });

    test('BOUT GATE: an isolated elevated minute does not count on its own', () {
      final d = List<double>.filled(60, sedDyn);
      d[30] = walkDyn;
      final m = dailyStepEstimate(rows(d), personalDynFloorG: floorG);
      expect(m.value!.activeMinutes, 0);
      expect(m.value!.steps, 0);
    });

    test('BOUT GATE: exactly at the boundary — 3 in a row counts, 2 does not',
        () {
      final d2 = List<double>.filled(60, sedDyn);
      d2[30] = walkDyn;
      d2[31] = walkDyn;
      expect(dailyStepEstimate(rows(d2), personalDynFloorG: floorG)
          .value!
          .activeMinutes,
          0);

      final d3 = List<double>.filled(60, sedDyn);
      d3[30] = walkDyn;
      d3[31] = walkDyn;
      d3[32] = walkDyn;
      expect(dailyStepEstimate(rows(d3), personalDynFloorG: floorG)
          .value!
          .activeMinutes,
          3);
    });

    test('BOUT GATE: a coverage gap breaks the run rather than stitching two '
        'short bouts together', () {
      // 4 elevated minutes total but never 3 adjacent, so none of it counts.
      final d = List<double>.filled(60, sedDyn);
      d[10] = walkDyn;
      d[11] = walkDyn;
      d[20] = walkDyn;
      d[21] = walkDyn;
      final m = dailyStepEstimate(rows(d), personalDynFloorG: floorG);
      expect(m.value!.activeMinutes, 0);
    });

    test('a MEASURED personal cadence narrows the reported range', () {
      final pop = dailyStepEstimate(day(120, 30), personalDynFloorG: floorG);
      final personal = dailyStepEstimate(day(120, 30),
          personalDynFloorG: floorG, calib: cal);
      expect(personal.value!.calibrated, isTrue);
      expect(personal.value!.activeMinutes, pop.value!.activeMinutes);
      expect(personal.value!.stepsHigh - personal.value!.stepsLow,
          lessThan(pop.value!.stepsHigh - pop.value!.stepsLow),
          reason: 'a measured cadence is a narrower band than the population');
      // ±10% around a measured 110 spm
      expect(personal.value!.cadenceLowSpm, closeTo(99.0, 1e-9));
      expect(personal.value!.cadenceHighSpm, closeTo(121.0, 1e-9));
      expect(personal.confidence, greaterThan(pop.confidence));
    });

    test('a faster measured cadence lifts the count', () {
      final slow =
          dailyStepEstimate(day(120, 30), personalDynFloorG: floorG, calib: cal);
      final fast = dailyStepEstimate(day(120, 30),
          personalDynFloorG: floorG,
          calib: const StepCalibration(cadenceSpm: 135, refEnmo: 0.06, n: 10));
      expect(fast.value!.steps, greaterThan(slow.value!.steps));
    });

    test('a thin calibration (n < 3) does not claim a personal cadence', () {
      final m = dailyStepEstimate(day(120, 30),
          personalDynFloorG: floorG,
          calib: const StepCalibration(cadenceSpm: 110, refEnmo: 0.06, n: 1));
      expect(m.value!.calibrated, isFalse);
      expect(m.value!.cadenceLowSpm, freeLivingCadenceLowSpm);
    });

    test('empty motion → absent ESTIMATE', () {
      final m = dailyStepEstimate(const [], personalDynFloorG: floorG);
      expect(m.present, isFalse);
      expect(m.tier, Tier.estimate);
      expect(m.note, 'no motion minutes');
    });

    test('too few covered minutes → absent, not a fabricated zero', () {
      final sparse = [
        for (var i = 0; i < 3; i++)
          MotionMinute(i * 60000.0, 60, 0.055, 0.02, 1.055, walkDyn),
      ];
      final m = dailyStepEstimate(sparse, personalDynFloorG: floorG);
      expect(m.present, isFalse);
      // uncovered minutes are excluded before the count, too
      final uncovered = [
        for (var i = 0; i < 100; i++)
          MotionMinute(i * 60000.0, 5, 0.055, 0.02, 1.055, walkDyn),
      ];
      expect(dailyStepEstimate(uncovered, personalDynFloorG: floorG).present,
          isFalse);
    });

    test('toJson leads with active minutes and carries the range', () {
      final j = dailyStepEstimate(day(120, 30), personalDynFloorG: floorG)
          .value!
          .toJson();
      expect(j['active_min'], 30);
      expect(j['steps_low'], 3000);
      expect(j['steps_high'], 3900);
      expect(j['steps'], 3450);
      expect(j['cadence_source'], 'population_band');
    });
  });

  group('Tier B — PROPERTY: calibration invariance end to end', () {
    // Build a synthetic 1 Hz day, run the whole pipeline (enmoSeries →
    // personalDynFloor → dailyStepEstimate), then run it again through a
    // corrupted sensor — a constant per-axis OFFSET plus a per-axis GAIN — and
    // require the same number of active minutes. This is the exact fault that
    // produced 39,384 steps on a real day, so it is the regression that matters
    // most: the answer must not depend on the sensor's calibration state.
    List<AccelSample> synth(
      int minutes, {
      required double Function(int) amp,
      double gx = 1.0,
      double gy = 1.0,
      double gz = 1.0,
      double bx = 0.0,
      double by = 0.0,
      double bz = 0.0,
    }) {
      final out = <AccelSample>[];
      for (var m = 0; m < minutes; m++) {
        final a = amp(m);
        // Motion DIRECTION rotates between axes so per-axis gains cannot cancel
        // by a trivial common factor — the invariance being tested is real.
        final axis = m % 3;
        for (var s = 0; s < 60; s++) {
          final i = m * 60 + s;
          final p = i.isEven ? a : -a;
          final x = (axis == 0 ? p : 0.0);
          final y = (axis == 1 ? p : 0.0) - 0.05;
          final z = (axis == 2 ? p : 0.0) + 1.03;
          out.add(AccelSample(
              i * 1000.0, gx * x + bx, gy * y + by, gz * z + bz));
        }
      }
      return out;
    }

    // History pool: a CONTINUOUS, low-skewed spread of minute intensities, the
    // shape a real 24/7 wrist stream has — most minutes near-still, a long
    // right tail. Its p90 is what personalDynFloor will pick up.
    double poolAmp(int m) {
      final u = (m % 200) / 200.0;
      return 0.01 + 0.5 * u * u;
    }

    // The day under test: near-still, except one 30-minute walk.
    double dayAmp(int m) =>
        (m >= 600 && m < 630) ? 0.60 : 0.01 + 0.0004 * (m % 40);

    ({int active, double floor}) run({
      double gx = 1.0,
      double gy = 1.0,
      double gz = 1.0,
      double bx = 0.0,
      double by = 0.0,
      double bz = 0.0,
    }) {
      final pool = enmoSeries(synth(2400,
          amp: poolAmp, gx: gx, gy: gy, gz: gz, bx: bx, by: by, bz: bz));
      final today = enmoSeries(synth(720,
          amp: dayAmp, gx: gx, gy: gy, gz: gz, bx: bx, by: by, bz: bz));
      final floor =
          personalDynFloor([for (final m in pool.minutes) m.dynAmp]);
      expect(floor, isNotNull, reason: '2400 pooled minutes is enough history');
      final est =
          dailyStepEstimate(today.minutes, personalDynFloorG: floor);
      expect(est.present, isTrue);
      return (active: est.value!.activeMinutes, floor: floor!);
    }

    test('the clean sensor finds the walk', () {
      final r = run();
      expect(r.active, 30, reason: 'the one 30-minute walk, and only it');
    });

    test('a constant per-axis OFFSET changes nothing', () {
      expect(run(bx: 0.05, by: -0.04, bz: 0.06).active, run().active);
    });

    test('a per-axis GAIN error changes nothing', () {
      expect(run(gx: 1.05, gy: 0.96, gz: 1.03).active, run().active);
    });

    test('OFFSET + GAIN together change nothing', () {
      final clean = run();
      final corrupt =
          run(gx: 1.05, gy: 0.96, gz: 1.03, bx: 0.05, by: -0.04, bz: 0.06);
      expect(corrupt.active, clean.active);
      // The floor itself DOES move — it rides the same gain the feature does,
      // which is precisely why the decision does not move.
      expect(corrupt.floor, isNot(closeTo(clean.floor, 1e-12)));
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
      // no hrmax passed, so this ran on the fallback anchor - flagged.
      expect(e.usedDefaultHrmax, isTrue);
    });

    test('usedDefaultHrmax is false once a real profile + hrmax are both given', () {
      final profile = const WorkoutUserProfile(
          weightKg: 80, heightCm: 180, age: 30, sex: 'male');
      final hr = List<double>.filled(1440, 70.0);
      final e = Calories.dailyEnergy(hr, profile: profile, hrmax: 190);
      expect(e.usedDefaultHrmax, isFalse);
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
