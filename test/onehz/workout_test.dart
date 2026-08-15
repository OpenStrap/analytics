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

    test('motion confirmation gate: high motion keeps it', () {
      final d = _hrDay();
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

    test('motion gate + onset bypass: sharp HR onset from rest keeps a '
        'low-motion bout (cycling/rowing — wrist stays still)', () {
      // Same shape as _hrDay(): 60 bpm rest for 600 s, then a sharp step to
      // 140 bpm — a genuine exercise onset even though the wrist motion stays
      // near-zero throughout (handlebar/oar grip).
      final d = _hrDay();
      final lowMotion = [
        for (var t = 600; t <= 1499; t++) MotionPoint(t, 0.01),
      ];
      final out = AutoWorkoutDetector.detect(
        hrTs: d.ts,
        hrBpm: d.bpm,
        restingBpm: 60,
        motion: lowMotion,
      );
      expect(out, hasLength(1));
      expect(out.first.startSec, 600);
    });

    test('motion gate + onset bypass: a slow-drifting elevation with no '
        'discernible start (fever/heat/anxiety) stays dropped even at low '
        'motion', () {
      // Ramp gradually from 60 to 140 over 10 min (well under onsetRiseBpm's
      // 25 bpm/3 min bar at any point), then hold — no sharp onset anywhere,
      // so the low-motion gate must still reject it.
      final ts = <int>[];
      final bpm = <int>[];
      var t = 0;
      for (; t < 600; t++) {
        ts.add(t);
        bpm.add(60);
      }
      // 600 s ramp: +8 bpm/min over 10 min => 60 -> 140.
      for (var i = 0; i < 600; i++, t++) {
        ts.add(t);
        bpm.add(60 + (i * 80 / 600).round());
      }
      for (var i = 0; i < 900; i++, t++) {
        ts.add(t);
        bpm.add(140);
      }
      final lowMotion = [
        for (var tt = 0; tt < t; tt++) MotionPoint(tt, 0.01),
      ];
      final out = AutoWorkoutDetector.detect(
        hrTs: ts,
        hrBpm: bpm,
        restingBpm: 60,
        motion: lowMotion,
      );
      expect(out, isEmpty);
    });

    test('motion gate + onset bypass: no pre-window (span starts at the '
        'first sample) cannot evaluate onset — stays dropped', () {
      // Elevated from t=0 with no preceding rest data at all.
      final ts = <int>[for (var t = 0; t < 900; t++) t];
      final bpm = <int>[for (var t = 0; t < 900; t++) 140];
      final lowMotion = [for (final t in ts) MotionPoint(t, 0.01)];
      final out = AutoWorkoutDetector.detect(
        hrTs: ts,
        hrBpm: bpm,
        restingBpm: 60,
        motion: lowMotion,
      );
      expect(out, isEmpty);
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

  test('a bridged dropout is billed at the published cap, through detect()', () {
    // The reason detect() reads Calories.defaultMergeGapCapS rather than its own
    // mergeGapS: bridgeGapS is TWICE mergeGapS, so _bridgeRuns stitches an
    // HR-free dropout of up to 300 s into a single bout, and the cap really does
    // bind inside one. Everything else about the cap is tested against
    // estimateBoutCalories directly, which cannot observe that the detector
    // passes the right constant.
    const gapS = 252; // > the 150 s cap, < the 300 s bridge window
    final hrTs = <int>[];
    final hrBpm = <double>[];
    for (var t = 0; t < 600; t++) {
      hrTs.add(t);
      hrBpm.add(150);
    }
    for (var t = 600 + gapS; t < 1200 + gapS; t++) {
      hrTs.add(t);
      hrBpm.add(150);
    }
    // Motion has to stay above the gate across the gap or the runs never merge.
    final gTs = <int>[];
    final gx = <double>[], gy = <double>[], gz = <double>[];
    for (var t = 0; t < 1200 + gapS; t++) {
      gTs.add(t);
      gx.add(t.isEven ? 0.0 : 0.6);
      gy.add(0);
      gz.add(1);
    }

    const profile =
        WorkoutUserProfile(weightKg: 75, heightCm: 178, age: 30, sex: 'male');
    final out = WorkoutDetector.detect(
      hrTs: hrTs,
      hrBpm: hrBpm,
      gravTs: gTs,
      gx: gx,
      gy: gy,
      gz: gz,
      maxHR: 190,
      restingHR: 60,
      profile: profile,
    );

    expect(out, hasLength(1), reason: 'the dropout must be bridged, not split');
    final session = out.first;

    // Score the same samples both ways. The detector must match the capped one.
    double score(double cap) => Calories.estimateBoutCalories(
          hrTs,
          hrBpm,
          profile: profile,
          hrmax: 190,
          restingHr: 60,
          mergeGapCapS: cap,
        ).kcal;

    final capped = score(Calories.defaultMergeGapCapS);
    final uncapped = score(gapS.toDouble() + 1);

    // Not exact: detect() prices its own bout window, which the run boundaries
    // trim by a sample or two against the raw stream scored here — worth a few
    // tenths of a kcal. The capped and uncapped figures are ~24 kcal apart, so
    // a 2 kcal tolerance still tells them apart by an order of magnitude.
    expect(uncapped - capped, greaterThan(20.0),
        reason: 'if these converge the assertions below prove nothing');
    expect((session.caloriesKcal! - capped).abs(), lessThan(2.0));
    expect((session.caloriesKcal! - uncapped).abs(), greaterThan(20.0));
  });

  group('Calories (Keytel + Harris–Benedict)', () {
    test('male/female coefficients differ; active > resting', () {
      // 10 min @ 150 bpm, 1 Hz.
      final ts = [for (var t = 0; t < 600; t++) t];
      final bpm = [for (var t = 0; t < 600; t++) 150.0];
      final m = Calories.estimateBoutCalories(ts, bpm,
          profile: const WorkoutUserProfile(
              weightKg: 80, heightCm: 180, age: 30, sex: 'male'),
          hrmax: 190,
          restingHr: 60);
      final f = Calories.estimateBoutCalories(ts, bpm,
          profile: const WorkoutUserProfile(
              weightKg: 80, heightCm: 180, age: 30, sex: 'female'),
          hrmax: 190,
          restingHr: 60);
      expect(m.kcal, greaterThan(0));
      expect(f.kcal, greaterThan(0));
      expect(m.kcal, isNot(closeTo(f.kcal, 0.01))); // sex coeffs differ
      expect(m.kj, closeTo(m.kcal * 4.184, 1e-6));
      expect(m.usedDefaultAnchors, isFalse); // real profile + real anchors given
    });

    test('resting samples use the BMR floor, not active rate', () {
      // 5 min @ 65 bpm → below active threshold (60 + 0.30*(190-60)=99) → resting.
      final ts = [for (var t = 0; t < 300; t++) t];
      final bpm = [for (var t = 0; t < 300; t++) 65.0];
      final r = Calories.estimateBoutCalories(ts, bpm,
          profile: const WorkoutUserProfile(sex: 'male'),
          hrmax: 190,
          restingHr: 60);
      final kcal = r.kcal;
      // ~5 min of resting BMR — small but positive.
      expect(kcal, greaterThan(0));
      expect(kcal, lessThan(10)); // resting-only over 5 min is tiny (~5–6 kcal)
    });
  });

  // ---------------------------------------------------------------------------
  // REGRESSION: unevaluable gates must BLOCK, hidden anchors must not exist,
  // off-skin samples must not become the resting-HR baseline, and the
  // fabricated-anchor calorie flag must reach the output.
  // ---------------------------------------------------------------------------
  group('WorkoutDetector — abstain-over-fabricate (regression)', () {
    /// Build a day of [restS] still/low-HR seconds, then [workS] seconds of
    /// sustained motion at [workBpm], then [restS] still seconds again.
    /// [offSkinS] leading seconds report hr == 0 (the off-skin sentinel) with
    /// static gravity.
    ({
      List<int> hrTs,
      List<double> hrBpm,
      List<int> gTs,
      List<double> gx,
      List<double> gy,
      List<double> gz
    }) day({
      required int workS,
      required double workBpm,
      required double restBpm,
      int restS = 60,
      int offSkinS = 0,
    }) {
      final hrTs = <int>[];
      final hrBpm = <double>[];
      final gTs = <int>[];
      final gx = <double>[];
      final gy = <double>[];
      final gz = <double>[];
      var t = 0;
      void still(int n, double bpm) {
        for (var i = 0; i < n; i++, t++) {
          hrTs.add(t);
          hrBpm.add(bpm);
          gTs.add(t);
          gx.add(0);
          gy.add(0);
          gz.add(1.0); // static gravity -> ~0 motion intensity
        }
      }

      still(offSkinS, 0); // OFF-SKIN: hr == 0 (types.dart HrSample convention)
      still(restS, restBpm);
      for (var i = 0; i < workS; i++, t++) {
        hrTs.add(t);
        hrBpm.add(workBpm);
        gTs.add(t);
        gx.add(i.isEven ? 0.5 : -0.5); // |delta| = 1.0 >> motionThreshold
        gy.add(0);
        gz.add(0.8);
      }
      still(restS, restBpm);
      return (hrTs: hrTs, hrBpm: hrBpm, gTs: gTs, gx: gx, gy: gy, gz: gz);
    }

    test('no HRmax anchor => the zone-2 gate is unevaluable => NO workout', () {
      // age null + maxHR null + <600 HR samples => estimateHRmax returns
      // (0.0, "unknown") => effMaxHR null => zonePct empty. PRE-FIX the whole
      // ">=50% time in zone 2+" gate was SKIPPED, so this 6.7-minute walk at
      // RHR+16 bpm was emitted as a durable workout.
      final d = day(workS: 400, workBpm: 76, restBpm: 60, restS: 60);
      expect(d.hrTs.length, lessThan(600),
          reason: 'must stay below estimateHRmax observed-sample minimum');

      final out = WorkoutDetector.detect(
        hrTs: d.hrTs,
        hrBpm: d.hrBpm,
        gravTs: d.gTs,
        gx: d.gx,
        gy: d.gy,
        gz: d.gz,
        restingHR: 60,
        maxHR: null,
        age: null,
      );
      expect(out, isEmpty);
    });

    test('detectWorkouts SAYS the gate could not be evaluated', () {
      final d = day(workS: 400, workBpm: 76, restBpm: 60, restS: 60);
      final m = detectWorkouts(
        hrTs: d.hrTs,
        hrBpm: d.hrBpm,
        gravTs: d.gTs,
        gx: d.gx,
        gy: d.gy,
        gz: d.gz,
        restingHR: 60,
      );
      expect(m.value, isEmpty);
      expect(m.note, contains('no HRmax anchor'));
      // inputs_used must reflect what was actually supplied.
      expect(m.inputs_used, contains('resting_hr'));
      expect(m.inputs_used, isNot(contains('max_hr')));
      expect(m.inputs_used, isNot(contains('age')));
      expect(m.inputs_used, isNot(contains('profile')));
    });

    test('an emitted session NEVER reports strain without an HRmax anchor', () {
      // PRE-FIX StrainScorer.strain(maxHR: null) silently used
      // defaultMaxHR() = 220 - 30 = 190, so a session shipped a concrete strain
      // alongside `hrmax: null, hrmax_source: "unknown"`.
      final scenarios = <List<ExerciseSession>>[
        for (final anchor in <double?>[null, 190])
          WorkoutDetector.detect(
            hrTs: day(workS: 400, workBpm: 160, restBpm: 60).hrTs,
            hrBpm: day(workS: 400, workBpm: 160, restBpm: 60).hrBpm,
            gravTs: day(workS: 400, workBpm: 160, restBpm: 60).gTs,
            gx: day(workS: 400, workBpm: 160, restBpm: 60).gx,
            gy: day(workS: 400, workBpm: 160, restBpm: 60).gy,
            gz: day(workS: 400, workBpm: 160, restBpm: 60).gz,
            restingHR: 60,
            maxHR: anchor,
          ),
      ];
      // With an anchor a real bout is emitted; without one, nothing is.
      expect(scenarios[1], isNotEmpty);
      expect(scenarios[0], isEmpty);
      for (final list in scenarios) {
        for (final s in list) {
          if (s.hrmax == null) {
            expect(s.strain, isNull,
                reason: 'strain must abstain without a real HRmax');
          }
        }
      }
    });

    test('off-skin (hr==0) samples are excluded from the resting-HR percentile',
        () {
      // 200 s off-skin (hr == 0) then a 400 s walk at 120 bpm on a 55 bpm day.
      // PRE-FIX the 10th percentile of the RAW stream was 0, so restHR = 0,
      // hrFloor = 15 and %HRR for the walk was (120-0)/190 = 63% => zone 2, so
      // ordinary walking cleared the >=50%-in-zone-2+ gate. On-skin only, the
      // 10th percentile is 55 and %HRR is (120-55)/135 = 48% => zone 0.
      final d = day(
          workS: 400, workBpm: 120, restBpm: 55, restS: 400, offSkinS: 200);
      final out = WorkoutDetector.detect(
        hrTs: d.hrTs,
        hrBpm: d.hrBpm,
        gravTs: d.gTs,
        gx: d.gx,
        gy: d.gy,
        gz: d.gz,
        maxHR: 190, // isolate the resting-HR derivation
      );
      expect(out, isEmpty,
          reason: 'a 120 bpm walk is zone 0 against a real 55 bpm resting HR');
    });

    test('an all-off-skin day derives no resting HR and abstains', () {
      final d = day(workS: 400, workBpm: 0, restBpm: 0, restS: 60);
      final out = WorkoutDetector.detect(
        hrTs: d.hrTs,
        hrBpm: d.hrBpm,
        gravTs: d.gTs,
        gx: d.gx,
        gy: d.gy,
        gz: d.gz,
        maxHR: 190,
      );
      expect(out, isEmpty);
    });

    test('the fabricated-anchor calorie flag reaches the session JSON', () {
      // Calories.estimateBoutCalories returns usedDefaultAnchors precisely so a
      // number built on the flat hrmax 220 / restingHr 60 fallback can be
      // caveated. PRE-FIX it was computed and dropped, and ExerciseSession had
      // no field or JSON key for it at all.
      final flagged = Calories.estimateBoutCalories(
        [0, 60, 120],
        [140, 145, 150],
        profile: const WorkoutUserProfile(),
        hrmax: null,
        restingHr: null,
      );
      expect(flagged.usedDefaultAnchors, isTrue);

      final d = day(workS: 400, workBpm: 160, restBpm: 60);
      final out = WorkoutDetector.detect(
        hrTs: d.hrTs,
        hrBpm: d.hrBpm,
        gravTs: d.gTs,
        gx: d.gx,
        gy: d.gy,
        gz: d.gz,
        restingHR: 60,
        maxHR: 190,
        profile: const WorkoutUserProfile(
            weightKg: 75, heightCm: 178, age: 30, sex: 'male'),
      );
      expect(out, isNotEmpty);
      final j = out.first.toJson();
      expect(j.containsKey('calories_used_default_anchors'), isTrue);
      expect(j['calories_used_default_anchors'], isFalse,
          reason: 'both anchors were real here');

      // And the flag is genuinely carried, not hardcoded false.
      const caveated = ExerciseSession(
        start: 0,
        end: 400,
        avgHR: 150,
        peakHR: 160,
        strain: null,
        durationS: 400,
        zoneTimePct: {},
        avgHRRPct: null,
        hrmax: null,
        hrmaxSource: 'unknown',
        caloriesKcal: 123.0,
        caloriesKJ: 514.6,
        caloriesUsedDefaultAnchors: true,
      );
      expect(caveated.toJson()['calories_used_default_anchors'], isTrue);
    });
  });

  group('autoDetectWorkouts — a data GAP is not continuity', () {
    test('two efforts either side of an off-wrist hole stay two workouts', () {
      // T-13. Only a low-HR DIP used to close a span. Edge filters `hr > 0`
      // before calling, so an off-skin stretch produces no samples at all — the
      // loop never saw the hole and the span simply resumed. Two 13-minute
      // efforts 40 minutes apart came out as ONE 64.98-minute workout whose
      // mean HR (a mean over present samples) still read normal.
      final ts = <int>[];
      final bpm = <int>[];
      void effort(int t0) {
        for (var s = 0; s < 13 * 60; s++) {
          ts.add(t0 + s);
          bpm.add(140);
        }
      }

      effort(0);
      effort(52 * 60); // 40-minute hole: NO samples
      final out =
          autoDetectWorkouts(hrTs: ts, hrBpm: bpm, restingBpm: 55, maxBpm: 190)
                  .value ??
              const <DetectedWorkout>[];
      expect(out.length, 2, reason: 'pre-fix: 1 workout of 64.98 min');
      for (final w in out) {
        expect((w.endSec - w.startSec) / 60.0, closeTo(12.98, 0.1));
      }
    });
  });
}
