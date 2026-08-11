// workout_detect.dart — retroactive per-day workout detection from the 1 Hz store.
//
// Retroactive per-day workout detector (ported from WorkoutDetector.swift /
// exercise.py / activity.py / calories.py). A workout is a SUSTAINED window (≥ MIN_EXERCISE_MIN)
// of elevated HR (> resting + HR_MARGIN_BPM) AND sustained motion (gravity-derived
// intensity > MOTION_THRESHOLD); both gates must hold for a sample to count.
//
// Per detected bout: avg/peak HR, duration, Edwards zone time-%, mean %HRR,
// strain (the existing [StrainScorer], REUSED — not re-derived), HRmax + source
// (via [StrainScorer.estimateHRmax]), and calories (Keytel + Harris–Benedict via
// the ported [Calories]). Every bout is typed through the [SportClassifier] seam.
//
// Pure / headless: no I/O, no clock, dart:math only. ts/start/end are unix
// SECONDS. All intensity/energy outputs are APPROXIMATE, not medical advice.

import 'dart:math' as math;

import '../types.dart';
import '../util.dart' show round6;
import '../clinical/load_trimp.dart';
import 'auto_detect.dart' show SavedWorkoutSpan;
import 'calories.dart';
import 'sport.dart';

/// A detected workout window. All intensity fields are APPROXIMATE.
class ExerciseSession {
  final int start;
  final int end;
  final double avgHR;
  final int peakHR;
  final double? strain;
  final double durationS;

  /// Edwards zone (0–5) time breakdown as % of HR samples; sums to ~100.
  final Map<int, double> zoneTimePct;

  /// Mean Karvonen %HRR over the bout, clamped [0,100], or null.
  final double? avgHRRPct;

  /// Effective HRmax used for zone math (bpm), or null.
  final double? hrmax;

  /// "caller" | "observed" | "tanaka" | "unknown".
  final String hrmaxSource;
  final double? caloriesKcal;
  final double? caloriesKJ;

  /// True when [caloriesKcal]/[caloriesKJ] were computed against a FABRICATED
  /// anchor — [Calories.estimateBoutCalories] falls back to a flat
  /// `hrmax = 220` / `restingHr = 60` when either is null, and returns
  /// `usedDefaultAnchors` precisely so that number can be caveated instead of
  /// shown as if it were personal. The flag used to be computed and thrown
  /// away; it is now carried through to [toJson]. False when no calories were
  /// computed at all.
  final bool caloriesUsedDefaultAnchors;

  /// Which of Keytel's two published active models priced [caloriesKcal]: true
  /// for the fitness-adjusted one, false for age/mass/sex. Carried for the same
  /// reason as [caloriesUsedDefaultAnchors] — two bouts scored on different
  /// models are not comparable, and a VO2max that was supplied and then
  /// rejected as implausible is otherwise indistinguishable from one that was
  /// never supplied. False when no calories were computed at all.
  final bool caloriesUsedFitnessModel;

  /// Sport label from the classifier seam ("detected" by default).
  final String sport;

  const ExerciseSession({
    required this.start,
    required this.end,
    required this.avgHR,
    required this.peakHR,
    required this.strain,
    required this.durationS,
    required this.zoneTimePct,
    required this.avgHRRPct,
    required this.hrmax,
    required this.hrmaxSource,
    required this.caloriesKcal,
    required this.caloriesKJ,
    this.caloriesUsedDefaultAnchors = false,
    this.caloriesUsedFitnessModel = false,
    this.sport = defaultSportLabel,
  });

  Map<String, dynamic> toJson() => {
        'start': start,
        'end': end,
        'avg_hr': round6(avgHR),
        'peak_hr': peakHR,
        'strain': strain == null ? null : round6(strain!),
        'duration_s': round6(durationS),
        'zone_time_pct': {for (final e in zoneTimePct.entries) '${e.key}': e.value},
        'avg_hrr_pct': avgHRRPct,
        'hrmax': hrmax == null ? null : round6(hrmax!),
        'hrmax_source': hrmaxSource,
        'calories_kcal': caloriesKcal == null ? null : round6(caloriesKcal!),
        'calories_kj': caloriesKJ == null ? null : round6(caloriesKJ!),
        'calories_used_default_anchors': caloriesUsedDefaultAnchors,
        'calories_used_fitness_model': caloriesUsedFitnessModel,
        'sport': sport,
      };
}

/// Per-record motion-intensity point.
class ActivityPoint {
  final int ts;
  final double intensity;
  const ActivityPoint(this.ts, this.intensity);
}

/// Retroactive per-day workout detector.
class WorkoutDetector {
  // ── Constants (exercise.py) ────────────────────────────────────────────────
  static const double minExerciseMin = 5.0;
  static const double hrMarginBPM = 15.0;
  static const double motionThreshold = 0.20;
  static const double motionSmoothS = 10.0;
  static const double mergeGapS = 150.0;
  static const double minIntensityZ2Plus = 0.50;
  static const double alignToleranceS = 5.0;
  static const double restingPercentile = 10.0;

  /// Second-pass bridge window (#303): two adjacent active runs separated by a
  /// below-motion gap ≤ this are stitched IFF HR stays elevated across the gap.
  static const double bridgeGapS = 300.0;

  /// Per-record motion-intensity series: L2 magnitude of the gravity change vs
  /// the previous record. First row → 0. Empty → []. [gravTs]/[gx]/[gy]/[gz]
  /// parallel arrays.
  static List<ActivityPoint> activitySeries(
      List<int> gravTs, List<double> gx, List<double> gy, List<double> gz) {
    final n = gravTs.length;
    if (n == 0) return const [];
    final idx = List<int>.generate(n, (i) => i)
      ..sort((a, b) => gravTs[a].compareTo(gravTs[b]));
    final out = <ActivityPoint>[];
    double? px, py, pz;
    for (var k = 0; k < n; k++) {
      final i = idx[k];
      final double intensity;
      if (k == 0 || px == null) {
        intensity = 0.0;
      } else {
        final dx = gx[i] - px;
        final dy = gy[i] - py!;
        final dz = gz[i] - pz!;
        intensity = math.sqrt(dx * dx + dy * dy + dz * dz);
      }
      out.add(ActivityPoint(gravTs[i], intensity));
      px = gx[i];
      py = gy[i];
      pz = gz[i];
    }
    return out;
  }

  /// Day resting-HR baseline = nearest-rank RESTING_PERCENTILE of the ON-SKIN
  /// bpm values.
  ///
  /// OFF-SKIN FILTER: the package convention (types.dart, `HrSample`) is that
  /// `hr == 0` means the sensor was off the wrist, NEVER bradycardia. Taking the
  /// 10th percentile of the RAW stream on a day with ≥10 % dropout returned
  /// restHR = 0, which dragged hrFloor down to 15 bpm and inflated every
  /// downstream %HRR — an ordinary 120 bpm walk read as 63 % HRR (zone 2)
  /// instead of 48 % (zone 0), so it cleared the zone-2 workout gate. Zeros are
  /// dropped before the percentile; null when nothing on-skin remains (we
  /// abstain rather than invent a resting HR).
  static double? _deriveRestingHR(List<double> bpm) {
    final onSkin = [for (final b in bpm) if (b > 0 && b.isFinite) b]..sort();
    if (onSkin.isEmpty) return null;
    final rank = math.max(1, (restingPercentile / 100.0 * onSkin.length).ceil());
    return onSkin[rank - 1];
  }

  /// Value whose ts is nearest [target] within [tol] s, else null. Ties → later
  /// timestamp (matches Python <=).
  static double? _nearest(
      List<int> sortedTs, List<double> values, int target, double tol) {
    if (sortedTs.isEmpty) return null;
    // bisect_left
    var lo = 0, hi = sortedTs.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (sortedTs[mid] < target) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    final i = lo;
    double? bestV;
    var bestD = tol;
    for (final j in [i - 1, i]) {
      if (j >= 0 && j < sortedTs.length) {
        final d = (sortedTs[j] - target).abs().toDouble();
        if (d <= bestD) {
          bestD = d;
          bestV = values[j];
        }
      }
    }
    return bestV;
  }

  /// Trailing rolling mean (over [windowS]) of intensities.
  static List<double> _smoothedIntensity(
      List<ActivityPoint> motion, double windowS) {
    final ts = [for (final p in motion) p.ts];
    final raw = [for (final p in motion) p.intensity.isFinite ? p.intensity : 0.0];
    final out = <double>[];
    var lo = 0;
    var running = 0.0;
    for (var i = 0; i < motion.length; i++) {
      running += raw[i];
      while ((ts[i] - ts[lo]).toDouble() > windowS) {
        running -= raw[lo];
        lo++;
      }
      out.add(running / (i - lo + 1));
    }
    return out;
  }

  /// Per-bout Edwards zone breakdown (%) + mean %HRR. Reuses [StrainScorer].
  static (Map<int, double>, double?) _boutIntensity(
      List<double> bpm, double restingHR, double maxHR) {
    if (bpm.isEmpty || maxHR <= restingHR) return (<int, double>{}, null);
    final hrReserve = maxHR - restingHR;
    final zoneCounts = {for (var z = 0; z <= 5; z++) z: 0};
    final hrrVals = <double>[];
    for (final b in bpm) {
      final z = StrainScorer.zoneWeight(b, restingHR, hrReserve);
      zoneCounts[z] = (zoneCounts[z] ?? 0) + 1;
      hrrVals.add(StrainScorer.pctHRR(b, restingHR, hrReserve));
    }
    final n = bpm.length.toDouble();
    final zonePct = <int, double>{};
    zoneCounts.forEach((z, c) {
      zonePct[z] = ((c / n * 100.0) * 10).roundToDouble() / 10;
    });
    final avgHRR =
        ((hrrVals.reduce((a, b) => a + b) / n) * 10).roundToDouble() / 10;
    return (zonePct, avgHRR);
  }

  /// Second-pass bridge over raw active runs (#303).
  static List<List<int>> _bridgeRuns(
      List<List<int>> runs, List<int> hrTs, List<double> hrBpm, double hrFloor) {
    if (runs.length <= 1) return runs;
    final merged = <List<int>>[];
    var curStart = runs[0][0];
    var curEnd = runs[0][1];
    for (var r = 1; r < runs.length; r++) {
      final next = runs[r];
      final gap = (next[0] - curEnd).toDouble();
      var bridge = false;
      if (gap <= bridgeGapS) {
        final gapHR = <double>[];
        for (var k = 0; k < hrTs.length; k++) {
          if (hrTs[k] > curEnd && hrTs[k] < next[0]) gapHR.add(hrBpm[k]);
        }
        if (gapHR.isEmpty) {
          bridge = true; // sensor dropout mid-effort → same workout
        } else {
          final meanGapHR = gapHR.reduce((a, b) => a + b) / gapHR.length;
          bridge = meanGapHR > hrFloor; // still working → same workout
        }
      }
      if (bridge) {
        curEnd = math.max(curEnd, next[1]);
      } else {
        merged.add([curStart, curEnd]);
        curStart = next[0];
        curEnd = next[1];
      }
    }
    merged.add([curStart, curEnd]);
    return merged;
  }

  /// Closed-interval overlap (touching endpoints count).
  static bool _overlaps(int aStart, int aEnd, int bStart, int bEnd) =>
      aStart <= bEnd && bStart <= aEnd;

  /// Detect workouts from the 1 Hz HR + gravity store.
  ///
  /// [hrTs]/[hrBpm] heart-rate stream (parallel arrays; empty → []).
  /// [gravTs]/[gx]/[gy]/[gz] gravity stream (parallel; empty → []).
  /// [restingHR] day RHR baseline; null → 10th-pct of the day's HR.
  /// [maxHR] HRmax; null → [StrainScorer.estimateHRmax] (observed/Tanaka).
  /// [age] for the Tanaka fallback. [profile] when provided → per-bout calories.
  /// [savedSpans] saved/manual spans — a detected bout overlapping any is DROPPED
  /// (overlap-dedup; caller passes saved spans). [classify] the sport seam.
  static List<ExerciseSession> detect({
    required List<int> hrTs,
    required List<double> hrBpm,
    required List<int> gravTs,
    required List<double> gx,
    required List<double> gy,
    required List<double> gz,
    double? restingHR,
    double? maxHR,
    double? age,
    WorkoutUserProfile? profile,
    // Keytel's fitness-adjusted active model reads this. It has to reach here
    // as well as the manual-logging path: a detected bout and a hand-logged one
    // over the SAME heart-rate trace are the same workout, and pricing one on
    // each of the two published models puts them ~30% apart in the same app on
    // the same day. Null ⇒ the age/mass/sex model, as before.
    double? vo2max,
    List<SavedWorkoutSpan> savedSpans = const [],
    SportClassifier classify = defaultSportClassifier,
  }) {
    // Clean + sort HR.
    final hn = hrTs.length;
    if (hn == 0) return const [];
    final ho = List<int>.generate(hn, (i) => i)
      ..sort((a, b) => hrTs[a].compareTo(hrTs[b]));
    final sTs = [for (final i in ho) hrTs[i]];
    final sBpm = [for (final i in ho) hrBpm[i]];

    final motion = activitySeries(gravTs, gx, gy, gz);
    if (motion.isEmpty) return const [];

    final restHR = restingHR ?? _deriveRestingHR(sBpm);
    // No caller RHR and no on-skin sample to derive one from → no baseline, so
    // no honest HR gate. Abstain rather than gate against a fabricated floor.
    if (restHR == null) return const [];
    final hrFloor = restHR + hrMarginBPM;

    final double? effMaxHR;
    final String hrmaxSource;
    if (maxHR != null) {
      effMaxHR = maxHR;
      hrmaxSource = 'caller';
    } else {
      final (est, src) = StrainScorer.estimateHRmax(sBpm, age);
      effMaxHR = est == 0.0 ? null : est;
      hrmaxSource = src;
    }

    final smooth = _smoothedIntensity(motion, motionSmoothS);

    // Walk the gravity timeline; flag samples where BOTH gates hold.
    final activeTs = <int>[];
    for (var k = 0; k < motion.length; k++) {
      if (smooth[k] <= motionThreshold) continue;
      final bpm = _nearest(sTs, sBpm, motion[k].ts, alignToleranceS);
      if (bpm == null || bpm <= hrFloor) continue;
      activeTs.add(motion[k].ts);
    }
    if (activeTs.isEmpty) return const [];

    // Group contiguous active samples into runs, merging gaps < MERGE_GAP_S.
    var runs = <List<int>>[];
    var runStart = activeTs[0];
    var prev = activeTs[0];
    for (var k = 1; k < activeTs.length; k++) {
      final t = activeTs[k];
      if ((t - prev).toDouble() > mergeGapS) {
        runs.add([runStart, prev]);
        runStart = t;
      }
      prev = t;
    }
    runs.add([runStart, prev]);

    // Second pass (#303): bridge across brief, still-elevated-HR lulls.
    runs = _bridgeRuns(runs, sTs, sBpm, hrFloor);

    final minDurS = minExerciseMin * 60.0;
    final sessions = <ExerciseSession>[];
    for (final run in runs) {
      final start = run[0], end = run[1];

      // Onset latency tolerance equal to the smoothing window.
      if ((end - start).toDouble() < minDurS - motionSmoothS) continue;

      // window HR samples
      final winTs = <int>[];
      final winBpm = <double>[];
      for (var k = 0; k < sTs.length; k++) {
        if (sTs[k] >= start && sTs[k] <= end) {
          winTs.add(sTs[k]);
          winBpm.add(sBpm[k]);
        }
      }
      if (winBpm.isEmpty) continue;

      var zonePct = <int, double>{};
      double? avgHRR;
      if (effMaxHR != null && effMaxHR > restHR) {
        (zonePct, avgHRR) = _boutIntensity(winBpm, restHR, effMaxHR);
      }

      // Intensity qualification: require ≥ MIN_INTENSITY_Z2PLUS in zone 2+.
      //
      // AN UNEVALUABLE GATE BLOCKS, IT DOES NOT PASS. `zonePct` is empty exactly
      // when there is no usable HRmax anchor (no caller HRmax, no age for
      // Tanaka, <600 samples for an observed estimate → estimateHRmax returns
      // ("unknown", 0)), or when the anchor is at/below resting HR. The old code
      // skipped the whole gate in that case, so a 6-minute walk at RHR+16 bpm
      // was emitted as a durable workout. With no zone breakdown we cannot know
      // whether the bout qualified, so we drop it.
      if (zonePct.isEmpty) continue;
      var z2plus = 0.0;
      for (var z = 2; z <= 5; z++) {
        z2plus += zonePct[z] ?? 0.0;
      }
      z2plus /= 100.0;
      if (z2plus < minIntensityZ2Plus) continue;

      // OVERLAP-DEDUP: drop a detected bout overlapping a saved/manual span.
      if (savedSpans.any((s) => _overlaps(start, end, s.startSec, s.endSec))) {
        continue;
      }

      double? kcal, kj;
      // Carry [Calories.estimateBoutCalories]'s usedDefaultAnchors through to
      // the session — it exists so a calorie number built on the flat
      // `hrmax ?? 220` / `restingHr ?? 60` fallback can be caveated, and it used
      // to be computed and dropped on the floor here.
      var calUsedDefaultAnchors = false;
      var calUsedFitnessModel = false;
      if (profile != null) {
        final winBpmInt = [for (final b in winBpm) b];
        final cal = Calories.estimateBoutCalories(
          winTs,
          winBpmInt,
          profile: profile,
          hrmax: effMaxHR,
          restingHr: restHR,
          mergeGapCapS: mergeGapS,
          vo2max: vo2max,
        );
        kcal = cal.kcal;
        kj = cal.kj;
        calUsedDefaultAnchors = cal.usedDefaultAnchors;
        calUsedFitnessModel = cal.usedFitnessModel;
      }

      final avg = winBpm.reduce((a, b) => a + b) / winBpm.length;
      final peak = winBpm.reduce(math.max).round();
      // Strain via the existing StrainScorer (reused, NOT re-derived).
      //
      // NO HIDDEN ANCHOR: StrainScorer.strain silently substitutes
      // `defaultMaxHR() = 220 − 30 = 190` when maxHR is null, so a session used
      // to report `hrmax: null, hrmax_source: 'unknown'` next to a concrete
      // strain scored against an invented 190. We ABSTAIN instead — no anchor,
      // no strain. (The zone gate above already drops such bouts; this keeps the
      // guarantee local so it survives any future change to that gate. The
      // fallback itself lives in clinical/load_trimp.dart and is not ours to
      // change.)
      final strain = effMaxHR == null
          ? null
          : StrainScorer.strain(
              winBpm,
              [for (final t in winTs) t.toDouble()],
              maxHR: effMaxHR,
              restingHR: restHR,
            );

      // HYBRID SEAM: type the bout.
      final bout = WorkoutBout(
        startSec: start,
        endSec: end,
        avgBpm: avg,
        peakBpm: peak.toDouble(),
        durationS: (end - start).toDouble(),
      );
      // Mean motion intensity over the bout window → a 1 Hz amplitude feature.
      var msum = 0.0;
      var mcnt = 0;
      for (final p in motion) {
        if (p.ts >= start && p.ts <= end) {
          msum += p.intensity;
          mcnt++;
        }
      }
      final feats =
          mcnt == 0 ? null : MotionFeatures(meanIntensity: msum / mcnt);
      final sport = classify(bout, feats);

      sessions.add(ExerciseSession(
        start: start,
        end: end,
        avgHR: avg,
        peakHR: peak,
        strain: strain,
        durationS: (end - start).toDouble(),
        zoneTimePct: zonePct,
        avgHRRPct: avgHRR,
        hrmax: effMaxHR,
        hrmaxSource: hrmaxSource,
        caloriesKcal: kcal,
        caloriesKJ: kj,
        caloriesUsedDefaultAnchors: calUsedDefaultAnchors,
        caloriesUsedFitnessModel: calUsedFitnessModel,
        sport: sport,
      ));
    }
    return sessions;
  }
}

/// Wrap detected workouts in the honesty envelope. Always present — an empty list
/// is a valid honest "no detected workouts" answer.
Metric<List<ExerciseSession>> detectWorkouts({
  required List<int> hrTs,
  required List<double> hrBpm,
  required List<int> gravTs,
  required List<double> gx,
  required List<double> gy,
  required List<double> gz,
  double? restingHR,
  double? maxHR,
  double? age,
  WorkoutUserProfile? profile,
  List<SavedWorkoutSpan> savedSpans = const [],
  SportClassifier classify = defaultSportClassifier,
}) {
  final list = WorkoutDetector.detect(
    hrTs: hrTs,
    hrBpm: hrBpm,
    gravTs: gravTs,
    gx: gx,
    gy: gy,
    gz: gz,
    restingHR: restingHR,
    maxHR: maxHR,
    age: age,
    profile: profile,
    savedSpans: savedSpans,
    classify: classify,
  );
  // Distinguish "no workouts today" from "the zone-2 qualification gate could
  // not be evaluated because there is no HRmax anchor" — with no anchor the
  // detector correctly emits nothing, and the caller deserves to know why.
  final noAnchor =
      maxHR == null && StrainScorer.estimateHRmax(hrBpm, age).$1 == 0.0;
  return Metric<List<ExerciseSession>>(
    value: list,
    confidence: list.isEmpty ? 0.0 : 0.6,
    tier: Tier.estimate,
    inputs_used: [
      'hr_1hz',
      'gravity_1hz',
      if (profile != null) 'profile',
      if (maxHR != null) 'max_hr',
      if (age != null) 'age',
      if (restingHR != null) 'resting_hr',
    ],
    note: noAnchor
        ? 'no HRmax anchor (no caller HRmax, no age, too few HR samples for an '
            'observed estimate) — the ≥50% time-in-zone-2+ qualification gate '
            'cannot be evaluated, so NO workout is emitted (never guessed)'
        : 'detected workouts (HR + motion gated, ≥5 min, ≥50% time in zone 2+); '
            'wrist-HR ESTIMATE, not medical advice',
  );
}
