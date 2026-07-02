import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

// Build a 1 Hz HR series: [restBpm] for [restBeforeS], [workBpm] for [workS],
// then [restBpm] again for [restAfterS], starting at epoch [t0].
({List<int> ts, List<int> bpm}) _hrDay({
  int t0 = 0,
  int restBeforeS = 600,
  int restBpm = 60,
  int workS = 900,
  int workBpm = 140,
  int restAfterS = 600,
}) {
  final ts = <int>[];
  final bpm = <int>[];
  var t = t0;
  for (var i = 0; i < restBeforeS; i++, t++) {
    ts.add(t);
    bpm.add(restBpm);
  }
  for (var i = 0; i < workS; i++, t++) {
    ts.add(t);
    bpm.add(workBpm);
  }
  for (var i = 0; i < restAfterS; i++, t++) {
    ts.add(t);
    bpm.add(restBpm);
  }
  return (ts: ts, bpm: bpm);
}

void main() {
  group('AutoWorkoutDetector (suggestion)', () {
    test('detects a sustained elevated-HR bout in the right window', () {
      final d = _hrDay(); // 60 bpm rest, 140 bpm for 900 s (15 min)
      final out = AutoWorkoutDetector.detect(
        hrTs: d.ts,
        hrBpm: d.bpm,
        restingBpm: 60,
      );
      expect(out, hasLength(1));
      final w = out.first;
      // floor = max(60+40, 60+.45*(190-60)) = 119; work span 140 bpm. window = [600, 1499].
      expect(w.startSec, 600);
      expect(w.endSec, 1499);
      expect(w.avgBpm, 140);
      expect(w.peakBpm, 140);
      expect(w.durationMin, (1499 - 600) ~/ 60); // = 14
      expect(w.sport, 'detected'); // default seam
    });

    test('below-threshold day → no suggestion', () {
      // Elevated for only 5 min (< 12 min minSustained).
      final d = _hrDay(workS: 300);
      final out = AutoWorkoutDetector.detect(
        hrTs: d.ts,
        hrBpm: d.bpm,
        restingBpm: 60,
      );
      expect(out, isEmpty);
    });

    test('HR never above RHR+30 → none', () {
      final d = _hrDay(workBpm: 85); // floor 90 → never elevated
      final out =
          AutoWorkoutDetector.detect(hrTs: d.ts, hrBpm: d.bpm, restingBpm: 60);
      expect(out, isEmpty);
    });

    test('overlap-dedup drops a bout overlapping a saved span', () {
      final d = _hrDay();
      final saved = [const SavedWorkoutSpan(900, 1000)]; // inside the bout
      final out = AutoWorkoutDetector.detect(
        hrTs: d.ts,
        hrBpm: d.bpm,
        restingBpm: 60,
        savedSpans: saved,
      );
      expect(out, isEmpty);
    });

    test('motion confirmation gate: low motion drops it, high keeps it', () {
      final d = _hrDay();
      // Low motion over the bout → below motionConfirmMean (0.15).
      final lowMotion = [
        for (var t = 600; t <= 1499; t++) MotionPoint(t, 0.01),
      ];
      final dropped = AutoWorkoutDetector.detect(
        hrTs: d.ts,
        hrBpm: d.bpm,
        restingBpm: 60,
        motion: lowMotion,
      );
      expect(dropped, isEmpty);

      final highMotion = [
        for (var t = 600; t <= 1499; t++) MotionPoint(t, 0.5),
      ];
      final kept = AutoWorkoutDetector.detect(
        hrTs: d.ts,
        hrBpm: d.bpm,
        restingBpm: 60,
        motion: highMotion,
      );
      expect(kept, hasLength(1));
    });

    test('brief dip ≤ maxDipS does not break the span', () {
      // 13 min elevated, with a single 60-s dip in the middle.
      final ts = <int>[];
      final bpm = <int>[];
      for (var t = 0; t < 780; t++) {
        ts.add(t);
        // dip to 70 (below floor 100) for [400,460).
        bpm.add((t >= 400 && t < 460) ? 70 : 140);
      }
      final out = AutoWorkoutDetector.detect(hrTs: ts, hrBpm: bpm, restingBpm: 60);
      expect(out, hasLength(1));
      expect(out.first.startSec, 0);
      expect(out.first.endSec, 779);
    });

    test('injected classifier types the bout', () {
      final d = _hrDay();
      String classify(WorkoutBout b, MotionFeatures? f) =>
          b.avgBpm >= 130 ? 'run' : 'walk';
      final out = AutoWorkoutDetector.detect(
        hrTs: d.ts,
        hrBpm: d.bpm,
        restingBpm: 60,
        classify: classify,
      );
      expect(out.single.sport, 'run');
    });

    test('Metric wrapper is present with a list', () {
      final d = _hrDay();
      final m = autoDetectWorkouts(hrTs: d.ts, hrBpm: d.bpm, restingBpm: 60);
      expect(m.present, isTrue);
      expect(m.value, hasLength(1));
    });
  });

  group('WorkoutDetector (persistent per-day)', () {
    // Build aligned HR + gravity with sustained motion over the work window.
    ({
      List<int> hrTs,
      List<double> hrBpm,
      List<int> gTs,
      List<double> gx,
      List<double> gy,
      List<double> gz
    }) buildDay({int workS = 900, double workBpm = 150}) {
      final hrTs = <int>[];
      final hrBpm = <double>[];
      final gTs = <int>[];
      final gx = <double>[];
      final gy = <double>[];
      final gz = <double>[];
      var t = 0;
      // 10 min rest
      for (var i = 0; i < 600; i++, t++) {
        hrTs.add(t);
        hrBpm.add(60);
        gTs.add(t);
        gx.add(0);
        gy.add(0);
        gz.add(1.0); // static gravity → ~0 intensity
      }
      // work: high HR + alternating gravity (large L2 delta each second)
      for (var i = 0; i < workS; i++, t++) {
        hrTs.add(t);
        hrBpm.add(workBpm);
        gTs.add(t);
        gx.add(i.isEven ? 0.5 : -0.5); // |delta| = 1.0 each step >> 0.20 thresh
        gy.add(0);
        gz.add(0.8);
      }
      // 10 min rest
      for (var i = 0; i < 600; i++, t++) {
        hrTs.add(t);
        hrBpm.add(60);
        gTs.add(t);
        gx.add(0);
        gy.add(0);
        gz.add(1.0);
      }
      return (hrTs: hrTs, hrBpm: hrBpm, gTs: gTs, gx: gx, gy: gy, gz: gz);
    }

    test('detects a HR+motion gated bout with per-bout metrics', () {
      final d = buildDay();
      final out = WorkoutDetector.detect(
        hrTs: d.hrTs,
        hrBpm: d.hrBpm,
        gravTs: d.gTs,
        gx: d.gx,
        gy: d.gy,
        gz: d.gz,
        maxHR: 190,
        restingHR: 60,
        profile: const WorkoutUserProfile(
            weightKg: 75, heightCm: 178, age: 30, sex: 'male'),
      );
      expect(out, hasLength(1));
      final s = out.first;
      expect(s.avgHR, closeTo(150, 1));
      expect(s.peakHR, 150);
      expect(s.durationS, greaterThan(WorkoutDetector.minExerciseMin * 60 - 11));
      // strain present + bounded 0..100.
      expect(s.strain, isNotNull);
      expect(s.strain!, inInclusiveRange(0, 100));
      // zone time-% sums to ~100.
      final zsum = s.zoneTimePct.values.fold<double>(0, (a, b) => a + b);
      expect(zsum, closeTo(100, 1.0));
      // %HRR for 150 bpm w/ rhr60,max190 = (150-60)/130 = 69.2% → zone 3 (≥70?)
      expect(s.avgHRRPct, closeTo(69.2, 0.5));
      // calories present + positive.
      expect(s.caloriesKcal, isNotNull);
      expect(s.caloriesKcal!, greaterThan(0));
      expect(s.hrmaxSource, 'caller');
      expect(s.sport, 'detected');
    });

    test('below min duration / low intensity → none', () {
      final d = buildDay(workS: 120); // 2 min < 5 min
      final out = WorkoutDetector.detect(
        hrTs: d.hrTs,
        hrBpm: d.hrBpm,
        gravTs: d.gTs,
        gx: d.gx,
        gy: d.gy,
        gz: d.gz,
        maxHR: 190,
        restingHR: 60,
      );
      expect(out, isEmpty);
    });

    test('overlap-dedup drops a detected bout overlapping a saved span', () {
      final d = buildDay();
      final out = WorkoutDetector.detect(
        hrTs: d.hrTs,
        hrBpm: d.hrBpm,
        gravTs: d.gTs,
        gx: d.gx,
        gy: d.gy,
        gz: d.gz,
        maxHR: 190,
        restingHR: 60,
        savedSpans: const [SavedWorkoutSpan(700, 900)],
      );
      expect(out, isEmpty);
    });

    test('injected sport classifier types the detected bout', () {
      final d = buildDay();
      String classify(WorkoutBout b, MotionFeatures? f) {
        // feats should carry the 1 Hz amplitude index.
        expect(f, isNotNull);
        expect(f!.meanIntensity, greaterThan(0.2));
        return 'cardio';
      }

      final out = WorkoutDetector.detect(
        hrTs: d.hrTs,
        hrBpm: d.hrBpm,
        gravTs: d.gTs,
        gx: d.gx,
        gy: d.gy,
        gz: d.gz,
        maxHR: 190,
        restingHR: 60,
        classify: classify,
      );
      expect(out.single.sport, 'cardio');
    });

    test('Metric wrapper present + toJson round-trips', () {
      final d = buildDay();
      final m = detectWorkouts(
        hrTs: d.hrTs,
        hrBpm: d.hrBpm,
        gravTs: d.gTs,
        gx: d.gx,
        gy: d.gy,
        gz: d.gz,
        maxHR: 190,
        restingHR: 60,
        profile: const WorkoutUserProfile(sex: 'female'),
      );
      expect(m.present, isTrue);
      final j = m.value!.first.toJson();
      expect(j['sport'], 'detected');
      expect(j['calories_kcal'], isNotNull);
    });
  });

  group('Calories (Keytel + Harris–Benedict)', () {
    test('male/female coefficients differ; active > resting', () {
      // 10 min @ 150 bpm, 1 Hz.
      final ts = [for (var t = 0; t < 600; t++) t];
      final bpm = [for (var t = 0; t < 600; t++) 150.0];
      final (mKcal, mKj) = Calories.estimateBoutCalories(ts, bpm,
          profile: const WorkoutUserProfile(
              weightKg: 80, heightCm: 180, age: 30, sex: 'male'),
          hrmax: 190,
          restingHr: 60);
      final (fKcal, _) = Calories.estimateBoutCalories(ts, bpm,
          profile: const WorkoutUserProfile(
              weightKg: 80, heightCm: 180, age: 30, sex: 'female'),
          hrmax: 190,
          restingHr: 60);
      expect(mKcal, greaterThan(0));
      expect(fKcal, greaterThan(0));
      expect(mKcal, isNot(closeTo(fKcal, 0.01))); // sex coeffs differ
      expect(mKj, closeTo(mKcal * 4.184, 1e-6));
    });

    test('resting samples use the BMR floor, not active rate', () {
      // 5 min @ 65 bpm → below active threshold (60 + 0.30*(190-60)=99) → resting.
      final ts = [for (var t = 0; t < 300; t++) t];
      final bpm = [for (var t = 0; t < 300; t++) 65.0];
      final (kcal, _) = Calories.estimateBoutCalories(ts, bpm,
          profile: const WorkoutUserProfile(sex: 'male'),
          hrmax: 190,
          restingHr: 60);
      // ~5 min of resting BMR — small but positive.
      expect(kcal, greaterThan(0));
      expect(kcal, lessThan(10)); // resting-only over 5 min is tiny (~5–6 kcal)
    });
  });
}
