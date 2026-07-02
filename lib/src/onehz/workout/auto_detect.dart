// auto_detect.dart — opt-in "did you just work out?" SUGGESTION detector.
//
// Opt-in workout suggestion detector (ported from AutoWorkoutDetector.swift).
// DELIBERATELY conservative (low sensitivity): a sustained ≥12-min
// elevation of HR ≥ resting+30 bpm, brief (≤90 s) dips tolerated, near windows
// merged, optional motion confirmation, overlap-excluded against saved spans.
//
// This NEVER writes a row — it only ever SUGGESTS. It is separate from the
// persistent per-day [WorkoutDetector] (workout_detect.dart), which computes
// calories/zones/strain for the durable "detected" rows.
//
// HYBRID SEAM: every surviving bout is run through a [SportClassifier]; the
// default returns "detected" (no sport typing). OpenStrap's motion-based HAR typer
// can be injected to type each bout when high-rate accel features exist.
//
// Pure / headless: no I/O, no clock, dart:math only. All ts/start/end are unix
// SECONDS. NOT medical advice.

import 'dart:math' as math;

import '../types.dart';
import 'sport.dart';

/// A candidate workout window the user can accept (Save) or reject (dismiss).
/// All fields derived purely from the HR samples inside the window.
class DetectedWorkout {
  final int startSec;
  final int endSec;
  final int avgBpm;
  final int peakBpm;

  /// Whole minutes, floor of (endSec - startSec) / 60.
  final int durationMin;

  /// Sport label from the [SportClassifier] ("detected" by default).
  final String sport;

  const DetectedWorkout({
    required this.startSec,
    required this.endSec,
    required this.avgBpm,
    required this.peakBpm,
    required this.durationMin,
    this.sport = defaultSportLabel,
  });

  Map<String, dynamic> toJson() => {
        'start_sec': startSec,
        'end_sec': endSec,
        'avg_bpm': avgBpm,
        'peak_bpm': peakBpm,
        'duration_min': durationMin,
        'sport': sport,
      };
}

/// A [startSec, endSec] span of an already-saved workout, used to exclude windows
/// that overlap a session the user has already logged.
class SavedWorkoutSpan {
  final int startSec;
  final int endSec;
  const SavedWorkoutSpan(this.startSec, this.endSec);
}

/// One motion-intensity reading aligned to the HR timeline (optional confirmation
/// signal). [intensity] is L2 gravity-delta vs the previous record.
class MotionPoint {
  final int ts;
  final double intensity;
  const MotionPoint(this.ts, this.intensity);
}

/// Opt-in suggestion detector.
class AutoWorkoutDetector {
  // ── Constants ─────────────────────────────────────────────────────────────

  /// Minimum elevated-gate margin (bpm above resting). A safety floor for the
  /// %HRR gate below when HRmax is low/unknown — the real threshold is [hrrFloor].
  static const int elevatedMarginBPM = 40;

  /// PRIMARY gate: a bout must sit at ≥ this fraction of heart-rate RESERVE
  /// (HRmax − RHR), not just a few bpm above rest. Calibrated on a full week of a
  /// sedentary user's data (zero real workouts): a fixed RHR+30 margin (≈90 bpm)
  /// flagged 30 windows; 0.45·HRR (~117 bpm at RHR 57 / HRmax 190) rejects
  /// ordinary daytime and even a 3 h steady-state evening elevation, leaving only
  /// short genuinely-cardio bouts (avg ≥ ~120 bpm) — which is exactly what a "did
  /// you work out?" prompt should ask about.
  static const double hrrFloorFraction = 0.45;

  /// HRmax fallback when the caller passes none (age-predicted is preferred).
  static const int defaultMaxHR = 190;

  /// A suggested WORKOUT is time-bounded. A sustained elevation longer than this
  /// (observed: ~3 h of steady 131 bpm from an active evening) is lifestyle
  /// activity, not a workout — don't suggest it. Endurance sessions beyond this
  /// are better logged manually than auto-prompted.
  static const int maxWorkoutMin = 120;

  /// A candidate must hold the gate for a contiguous span ≥ this (12 min).
  static const double minSustainedMin = 12.0;

  /// A dip below the gate no longer than this does NOT break the span.
  static const int maxDipS = 90;

  /// Two windows whose gap is strictly < this are merged (5 min).
  static const int mergeGapS = 5 * 60;

  /// When a motion series is supplied, the window's mean per-second motion
  /// intensity (L2 gravity-vector change/s, in g) must be ≥ this to qualify.
  /// 0.05 was far too low — desk fidgeting/typing/gesturing while seated averages
  /// above it, so an elevated resting HR alone got confirmed as a "workout". Real
  /// ambulatory exercise (walking/running/lifting) sustains well above 0.15.
  /// Ignored in HR-only mode.
  static const double motionConfirmMean = 0.15;

  /// Resting-HR fallback when the caller has no nightly RHR.
  static const int defaultRestingHR = 60;

  /// Per-second motion intensity = L2 magnitude of the gravity change vs the
  /// previous record. First row → 0. Empty input → [].
  /// [gravTs]/[gx]/[gy]/[gz] are parallel arrays for building the optional [motion] argument.
  /// [gravTs]/[gx]/[gy]/[gz] are parallel arrays (any order; sorted internally).
  static List<MotionPoint> motionPoints(
      List<int> gravTs, List<double> gx, List<double> gy, List<double> gz) {
    final n = gravTs.length;
    if (n == 0) return const [];
    final idx = List<int>.generate(n, (i) => i)
      ..sort((a, b) => gravTs[a].compareTo(gravTs[b]));
    final out = <MotionPoint>[];
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
      out.add(MotionPoint(gravTs[i], intensity));
      px = gx[i];
      py = gy[i];
      pz = gz[i];
    }
    return out;
  }

  /// Detect candidate sustained-elevated-HR workout windows.
  ///
  /// [hrTs]/[hrBpm] the day's HR samples (parallel, any order; empty → []).
  /// [restingBpm] nightly resting HR for the day; null → [defaultRestingHR] (60).
  /// [motion] OPTIONAL continuous motion series for confirmation; null/empty →
  /// HR-only. [savedSpans] already-saved windows to exclude by overlap.
  /// [classify] the sport seam — runs on each surviving bout; default
  /// [defaultSportClassifier] returns "detected" (no sport typing).
  static List<DetectedWorkout> detect({
    required List<int> hrTs,
    required List<int> hrBpm,
    int? restingBpm,
    int? maxBpm,
    List<MotionPoint>? motion,
    List<SavedWorkoutSpan> savedSpans = const [],
    SportClassifier classify = defaultSportClassifier,
  }) {
    final n = hrTs.length;
    if (n == 0) return const [];
    final order = List<int>.generate(n, (i) => i)
      ..sort((a, b) => hrTs[a].compareTo(hrTs[b]));
    final ts = [for (final i in order) hrTs[i]];
    final bpm = [for (final i in order) hrBpm[i]];

    // %HRR floor (primary), never below the RHR+margin safety floor.
    final rhr = restingBpm ?? defaultRestingHR;
    final hrMax = maxBpm ?? defaultMaxHR;
    final hrrFloor = (rhr + hrrFloorFraction * (hrMax - rhr)).round();
    final floor = math.max(rhr + elevatedMarginBPM, hrrFloor);

    // --- 1+2+3: grow sustained spans tolerating brief dips ---
    final spans = <List<int>>[]; // [start, end]
    int? spanStart;
    var spanEnd = 0;
    int? dipStart;

    void closeSpan() {
      if (spanStart != null &&
          (spanEnd - spanStart!).toDouble() >= minSustainedMin * 60.0) {
        spans.add([spanStart!, spanEnd]);
      }
      spanStart = null;
      dipStart = null;
    }

    for (var k = 0; k < n; k++) {
      if (bpm[k] >= floor) {
        spanStart ??= ts[k];
        spanEnd = ts[k];
        dipStart = null; // the dip (if any) is bridged
      } else if (spanStart != null) {
        dipStart ??= ts[k];
        if (ts[k] - dipStart! > maxDipS) closeSpan();
      }
    }
    closeSpan();

    if (spans.isEmpty) return const [];

    // --- 4: merge spans whose gap is strictly < mergeGapS ---
    final merged = <List<int>>[];
    var curStart = spans[0][0];
    var curEnd = spans[0][1];
    for (var k = 1; k < spans.length; k++) {
      final next = spans[k];
      if (next[0] - curEnd < mergeGapS) {
        curEnd = math.max(curEnd, next[1]);
      } else {
        merged.add([curStart, curEnd]);
        curStart = next[0];
        curEnd = next[1];
      }
    }
    merged.add([curStart, curEnd]);

    // --- 5+6+7 ---
    final motionSeries =
        (motion == null || motion.isEmpty) ? null : motion;
    final results = <DetectedWorkout>[];
    for (final span in merged) {
      final start = span[0], end = span[1];

      // A workout is time-bounded — a multi-hour sustained elevation is lifestyle
      // activity, not a workout to suggest.
      if ((end - start) > maxWorkoutMin * 60) continue;

      // 6: never re-suggest a window overlapping a saved workout.
      if (savedSpans.any((s) => _overlaps(start, end, s.startSec, s.endSec))) {
        continue;
      }

      // window HR samples
      final winBpm = <int>[];
      for (var k = 0; k < n; k++) {
        if (ts[k] >= start && ts[k] <= end) winBpm.add(bpm[k]);
      }
      if (winBpm.isEmpty) continue;

      // The WHOLE window must be genuinely elevated, not just brief floor
      // crossings that dip-bridging stitched together — require the mean HR to
      // clear the floor too. (A sedentary afternoon oscillating around the gate
      // averaged below it; a real bout averages well above.)
      final winMean = winBpm.reduce((a, b) => a + b) / winBpm.length;
      if (winMean < floor) continue;

      // 5: motion confirmation when a continuous motion series was supplied.
      double? meanMotion;
      if (motionSeries != null) {
        var sum = 0.0;
        var cnt = 0;
        for (final p in motionSeries) {
          if (p.ts >= start && p.ts <= end) {
            sum += p.intensity;
            cnt++;
          }
        }
        meanMotion = cnt == 0 ? 0.0 : sum / cnt;
        if (meanMotion < motionConfirmMean) continue;
      }

      var sum = 0;
      var peak = winBpm.first;
      for (final v in winBpm) {
        sum += v;
        if (v > peak) peak = v;
      }
      final avg = (sum / winBpm.length).round();
      final durMin = (end - start) ~/ 60;

      // HYBRID SEAM: type the bout. Default classifier returns "detected".
      final bout = WorkoutBout(
        startSec: start,
        endSec: end,
        avgBpm: avg.toDouble(),
        peakBpm: peak.toDouble(),
        durationS: (end - start).toDouble(),
      );
      final feats = meanMotion == null
          ? null
          : MotionFeatures(meanIntensity: meanMotion);
      final sport = classify(bout, feats);

      results.add(DetectedWorkout(
        startSec: start,
        endSec: end,
        avgBpm: avg,
        peakBpm: peak,
        durationMin: durMin,
        sport: sport,
      ));
    }
    return results;
  }

  /// Closed-interval overlap (touching endpoints count).
  static bool _overlaps(int aStart, int aEnd, int bStart, int bEnd) =>
      aStart <= bEnd && bStart <= aEnd;
}

/// Wrap a list of [DetectedWorkout] in the honesty envelope. Always present
/// (an empty list is a valid, honest "no suggested workouts" answer).
Metric<List<DetectedWorkout>> autoDetectWorkouts({
  required List<int> hrTs,
  required List<int> hrBpm,
  int? restingBpm,
  int? maxBpm,
  List<MotionPoint>? motion,
  List<SavedWorkoutSpan> savedSpans = const [],
  SportClassifier classify = defaultSportClassifier,
}) {
  final list = AutoWorkoutDetector.detect(
    hrTs: hrTs,
    hrBpm: hrBpm,
    restingBpm: restingBpm,
    maxBpm: maxBpm,
    motion: motion,
    savedSpans: savedSpans,
    classify: classify,
  );
  return Metric<List<DetectedWorkout>>(
    value: list,
    confidence: list.isEmpty ? 0.0 : 0.6,
    tier: Tier.estimate,
    inputs_used: const ['hr_1hz', 'resting_hr', 'motion_1hz'],
    note: 'opt-in workout suggestion (HR ≥ RHR+30 sustained ≥12 min); '
        'wrist-HR ESTIMATE, not medical advice',
  );
}
