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

  /// Day resting-HR baseline = nearest-rank RESTING_PERCENTILE of bpm values.
  /// Derive resting HR from a sorted series. [bpmSorted] must already be sorted ascending.
  static double _deriveRestingHR(List<double> bpmSorted) {
    final rank =
        math.max(1, (restingPercentile / 100.0 * bpmSorted.length).ceil());
    return bpmSorted[rank - 1];
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

    final restHR = restingHR ?? _deriveRestingHR([...sBpm]..sort());
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
      if (zonePct.isNotEmpty) {
        var z2plus = 0.0;
        for (var z = 2; z <= 5; z++) {
          z2plus += zonePct[z] ?? 0.0;
        }
        z2plus /= 100.0;
        if (z2plus < minIntensityZ2Plus) continue;
      }

      // OVERLAP-DEDUP: drop a detected bout overlapping a saved/manual span.
      if (savedSpans.any((s) => _overlaps(start, end, s.startSec, s.endSec))) {
        continue;
      }

      double? kcal, kj;
      if (profile != null) {
        final winBpmInt = [for (final b in winBpm) b];
        (kcal, kj) = Calories.estimateBoutCalories(
          winTs,
          winBpmInt,
          profile: profile,
          hrmax: effMaxHR,
          restingHr: restHR,
          mergeGapCapS: mergeGapS,
        );
      }

      final avg = winBpm.reduce((a, b) => a + b) / winBpm.length;
      final peak = winBpm.reduce(math.max).round();
      // Strain via the existing StrainScorer (reused, NOT re-derived).
      final strain = StrainScorer.strain(
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
  return Metric<List<ExerciseSession>>(
    value: list,
    confidence: list.isEmpty ? 0.0 : 0.6,
    tier: Tier.estimate,
    inputs_used: const ['hr_1hz', 'gravity_1hz', 'profile'],
    note: 'detected workouts (HR + motion gated, ≥5 min, ≥50% time in zone 2+); '
        'wrist-HR ESTIMATE, not medical advice',
  );
}
