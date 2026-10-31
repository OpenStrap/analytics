// auto_detect.dart — opt-in "did you just work out?" SUGGESTION detector.
//
// Opt-in workout suggestion detector (ported from AutoWorkoutDetector.swift).
// DELIBERATELY conservative (low sensitivity): a sustained ≥12-min elevation of
// HR ≥ max(RHR+[elevatedMarginBPM], RHR+[hrrFloorFraction]·HRR) — RHR+59 at
// RHR 60 / HRmax 190 — brief (≤90 s) dips tolerated, near windows merged,
// observed rests of up to 15 min bridged when their mean HR stays above
// resting (see [restBridgeMaxS]), optional motion confirmation, overlap-excluded against
// saved spans.
// (The header and the note used to quote "RHR+30", the margin this detector
// deliberately abandoned: see [hrrFloorFraction] for the 30 false windows on a
// sedentary week that motivated replacing it.)
//
// This NEVER writes a row — it only ever SUGGESTS.
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

  // There is deliberately no HRmax fallback. A population 190 put the %HRR
  // gate ~12 bpm too high for a 62-year-old at RHR 62 (120 vs 108 on their
  // age line) and too low for anyone whose real ceiling is above 190, and
  // nothing in the result said a default was used. No ceiling → no
  // suggestions; see [detect] and [autoDetectWorkouts].

  /// A suggested WORKOUT is time-bounded. A sustained elevation longer than this
  /// (observed: ~3 h of steady 131 bpm from an active evening) is lifestyle
  /// activity, not a workout — don't suggest it. Endurance sessions beyond this
  /// are better logged manually than auto-prompted.
  static const int maxWorkoutMin = 120;

  /// A candidate must hold the gate for a contiguous span ≥ this (12 min).
  static const double minSustainedMin = 12.0;

  /// A dip below the gate no longer than this does NOT break the span.
  static const int maxDipS = 90;

  /// A GAP IN THE DATA longer than this breaks the span.
  ///
  /// A dip is "HR present and low"; a gap is "no HR at all", and only the dip
  /// used to be time-bounded — so an off-wrist stretch produced no samples, the
  /// loop never saw it, and the span simply resumed at the next elevated
  /// sample. Two 12-minute efforts 40 minutes apart came out as one 64-minute
  /// workout whose mean HR (a mean over present samples only) still read
  /// normal. Absence of data is not evidence of continuity.
  static const int maxGapS = 90;

  /// Two windows whose gap is strictly < this are merged (5 min),
  /// unconditionally — a gap this short is a dip, not a pause.
  static const int mergeGapS = 5 * 60;

  /// A REST between two bouts up to this long (inclusive) is bridged into ONE
  /// workout — but only when [_restBridgeHolds] says the pause was observed and
  /// the heart never went back to rest. 15 min.
  ///
  /// [mergeGapS] alone split every sport with real breaks in it: tennis for an
  /// hour with a 5-10 min sit-down after 20 min, set breaks in padel, a
  /// half-time, a water stop on a long ride. During the sit-down HR falls
  /// below the gate, the span closes after [maxDipS], and the two halves sat
  /// 7-8 min apart — past the 5-min merge — so the user got two "did you work
  /// out?" prompts for one match. Fifteen minutes covers a sit-down,
  /// a changeover and a half-time; a morning and an evening run, or a session
  /// after lunch, are hours apart and never come near it.
  static const int restBridgeMaxS = 15 * 60;

  /// During a bridged rest the mean HR must stay at or above
  /// RHR + this fraction of heart-rate reserve (≈ RHR+20 at RHR 60 /
  /// HRmax 190). Recovery from a real effort holds HR well clear of resting
  /// for many minutes (post-exercise HR recovery has a fast vagal phase in
  /// the first minute and a slow phase lasting several more; Imai et al.
  /// 1994), so a sit-down between games clears this; HR that has fallen back
  /// to a seated baseline means the effort is over and the next bout is a new
  /// one. The %HRR form mirrors
  /// [hrrFloorFraction] so the bar scales with the user's range rather than
  /// a fixed bpm offset.
  static const double restBridgeHrrFraction = 0.15;

  /// When a motion series is supplied, the window's mean per-second motion
  /// intensity (L2 gravity-vector change/s, in g) must be ≥ this to qualify.
  /// 0.05 was far too low — desk fidgeting/typing/gesturing while seated averages
  /// above it, so an elevated resting HR alone got confirmed as a "workout". Real
  /// ambulatory exercise (walking/running/lifting) sustains well above 0.15.
  /// Ignored in HR-only mode.
  static const double motionConfirmMean = 0.15;

  /// Lookback immediately before a span's start, used to test for an
  /// exercise-like HR ONSET as a motion-gate bypass — see [onsetRiseBpm].
  static const int onsetLookbackS = 180;

  /// The onset check's "post" window: the first stretch of the span itself.
  static const int onsetWindowS = 180;

  /// Bypass the motion-confirmation gate when it fails BUT the HR shows a
  /// genuine exercise ONSET: mean bpm over [onsetWindowS] at the START of the
  /// span must rise by at least this many bpm versus mean bpm over
  /// [onsetLookbackS] immediately BEFORE it.
  ///
  /// Real aerobic effort produces a fast (~1-2 min time-constant) phase-II HR
  /// kinetic response right as exertion begins (Whipp & Wasserman 1972) —
  /// exactly what low-limb-swing cardio (cycling, rowing) shows even though
  /// the wrist stays still on a handlebar/oar and [motionConfirmMean] (tuned
  /// for arm-swing activities) never clears. A slow-drifting elevation —
  /// fever, heat, anxiety climbing over many minutes, or a plateau with no
  /// visible start because the data begins mid-elevation — shows no such rise
  /// and stays gated: this is what keeps the bypass from turning "every
  /// sustained heart-rate elevation" into a suggested activity. No usable
  /// pre-window (nothing in [onsetLookbackS], e.g. the day/recording starts
  /// mid-span) → the onset can't be evaluated → abstain, motion gate stays in
  /// force (never fabricate an onset that isn't there).
  static const double onsetRiseBpm = 25.0;

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
  /// [maxBpm] the user's HRmax (measured or age-predicted); null → [] (the
  /// %HRR gate cannot be placed without it).
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
    if (n == 0 || maxBpm == null) return const [];
    final order = List<int>.generate(n, (i) => i)
      ..sort((a, b) => hrTs[a].compareTo(hrTs[b]));
    final ts = [for (final i in order) hrTs[i]];
    final bpm = [for (final i in order) hrBpm[i]];

    // %HRR floor (primary), never below the RHR+margin safety floor.
    final rhr = restingBpm ?? defaultRestingHR;
    final hrrFloor = (rhr + hrrFloorFraction * (maxBpm - rhr)).round();
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
      // Break on a hole in the record before anything else — see [maxGapS].
      if (k > 0 && spanStart != null && ts[k] - ts[k - 1] > maxGapS) closeSpan();
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

    // --- 4: merge spans whose gap is strictly < mergeGapS, and bridge a
    // rest of up to restBridgeMaxS the heart never recovered from ---
    // The bridge floor sits between resting and the gate: "still recovering
    // from effort", not "working out". Never above the gate itself, so a low
    // HRmax can't make bridging stricter than the bout definition.
    final bridgeFloor = math.min(
        floor, (rhr + restBridgeHrrFraction * (maxBpm - rhr)).round());
    // Two passes. The unconditional < mergeGapS merge runs first, exactly as
    // it always has; bridging then works on its output. Done the other way
    // round, a short gap after a bridge would grow the window past
    // maxWorkoutMin with no cap check and the whole window, efforts that used
    // to stand on their own included, would be thrown away.
    final joined = <List<int>>[];
    var curStart = spans[0][0], curEnd = spans[0][1];
    for (var k = 1; k < spans.length; k++) {
      final next = spans[k];
      if (next[0] - curEnd < mergeGapS) {
        curEnd = math.max(curEnd, next[1]);
      } else {
        joined.add([curStart, curEnd]);
        curStart = next[0];
        curEnd = next[1];
      }
    }
    joined.add([curStart, curEnd]);

    final merged = <_Window>[];
    var cur = _Window(joined[0][0], joined[0][1]);
    for (var k = 1; k < joined.length; k++) {
      final next = joined[k];
      final gap = next[0] - cur.end;
      if (gap <= restBridgeMaxS &&
          // Never bridge into a window maxWorkoutMin would then throw away
          // whole: two honest suggestions beat none.
          next[1] - cur.start <= maxWorkoutMin * 60 &&
          // Nor across a saved workout: the overlap check below would drop
          // the bridged window whole, taking the effort the user never saved
          // with it. Kept apart, only the saved one is excluded.
          !savedSpans.any(
              (s) => _overlaps(cur.start, next[1], s.startSec, s.endSec)) &&
          _restBridgeHolds(ts, bpm, cur.end, next[0], bridgeFloor)) {
        cur.rests.add([cur.end, next[0]]);
        cur.end = math.max(cur.end, next[1]);
      } else {
        merged.add(cur);
        cur = _Window(next[0], next[1]);
      }
    }
    merged.add(cur);

    // --- 5+6+7 ---
    final motionSeries =
        (motion == null || motion.isEmpty) ? null : motion;
    final results = <DetectedWorkout>[];
    for (final span in merged) {
      final start = span.start, end = span.end;

      // A workout is time-bounded — a multi-hour sustained elevation is lifestyle
      // activity, not a workout to suggest.
      if ((end - start) > maxWorkoutMin * 60) continue;

      // 6: never re-suggest a window overlapping a saved workout.
      if (savedSpans.any((s) => _overlaps(start, end, s.startSec, s.endSec))) {
        continue;
      }

      // window HR samples — all of them (the reported avg/peak describe the
      // whole session, rests included, as a recorded workout would), and the
      // EFFORT subset outside the bridged rests, which the gates judge.
      final winBpm = <int>[];
      var effortSum = 0, effortCnt = 0;
      for (var k = 0; k < n; k++) {
        if (ts[k] >= start && ts[k] <= end) {
          winBpm.add(bpm[k]);
          if (!span.inRest(ts[k])) {
            effortSum += bpm[k];
            effortCnt++;
          }
        }
      }
      if (winBpm.isEmpty || effortCnt == 0) continue;

      // The WHOLE window must be genuinely elevated, not just brief floor
      // crossings that dip-bridging stitched together — require the mean HR to
      // clear the floor too. (A sedentary afternoon oscillating around the gate
      // averaged below it; a real bout averages well above.) Judged on the
      // effort minutes only: a bridged rest is by construction below the gate,
      // and folding it in would turn one bridged match into NO suggestion where
      // its two halves used to produce two. With no rests this is the whole
      // window, exactly as before.
      final winMean = effortSum / effortCnt;
      if (winMean < floor) continue;

      // 5: motion confirmation when a continuous motion series was supplied.
      double? meanMotion;
      if (motionSeries != null) {
        var sum = 0.0;
        var cnt = 0;
        for (final p in motionSeries) {
          // Same effort-only rule as the HR mean: a sit-down is still.
          if (p.ts >= start && p.ts <= end && !span.inRest(p.ts)) {
            sum += p.intensity;
            cnt++;
          }
        }
        // No motion sample inside the window is missing evidence, not a still
        // wrist: reading it as 0.0 g failed the gate and dropped the bout,
        // and handed the classifier an intensity nobody measured. Judge the
        // window on HR alone, as with no motion series at all.
        meanMotion = cnt == 0 ? null : sum / cnt;
        if (meanMotion != null && meanMotion < motionConfirmMean) {
          // Low-motion but a genuine exercise-like onset — see [onsetRiseBpm].
          final preMean =
              _meanBpmInRange(ts, bpm, start - onsetLookbackS, start);
          final earlyMean = _meanBpmInRange(
              ts, bpm, start, math.min(end + 1, start + onsetWindowS));
          if (preMean == null ||
              earlyMean == null ||
              (earlyMean - preMean) < onsetRiseBpm) {
            continue;
          }
        }
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

  /// Whether the pause between two bouts — from [gapStart] (last sample of
  /// the earlier span) to [gapEnd] (first sample of the later one) — may be
  /// bridged as a rest inside one workout. Both must hold:
  ///
  ///  * OBSERVED: no hole in the record longer than [maxGapS] anywhere in it.
  ///    The span builder's rule, for the same reason: absence of data is not
  ///    evidence of continuity — an off-wrist stretch between two efforts says
  ///    nothing about whether the user was still at it.
  ///  * NOT RECOVERED: the mean HR strictly inside the pause is at or above
  ///    [bridgeFloor] (see [restBridgeHrrFraction]).
  ///
  /// No samples strictly inside → can't tell → don't bridge.
  static bool _restBridgeHolds(
      List<int> ts, List<int> bpm, int gapStart, int gapEnd, int bridgeFloor) {
    var k = _lowerBound(ts, gapStart);
    var prev = gapStart;
    var sum = 0, cnt = 0;
    for (; k < ts.length && ts[k] <= gapEnd; k++) {
      if (ts[k] - prev > maxGapS) return false;
      prev = ts[k];
      if (ts[k] > gapStart && ts[k] < gapEnd) {
        sum += bpm[k];
        cnt++;
      }
    }
    if (gapEnd - prev > maxGapS) return false;
    return cnt > 0 && sum / cnt >= bridgeFloor;
  }

  /// First index with `ts[i] >= x` ([ts] sorted ascending).
  static int _lowerBound(List<int> ts, int x) {
    var lo = 0, hi = ts.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (ts[mid] < x) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  /// Closed-interval overlap (touching endpoints count).
  static bool _overlaps(int aStart, int aEnd, int bStart, int bEnd) =>
      aStart <= bEnd && bStart <= aEnd;

  /// Mean bpm for samples with `lo <= ts < hi`. Null when nothing falls in
  /// range (can't evaluate — caller must abstain, not substitute a default).
  static double? _meanBpmInRange(
      List<int> ts, List<int> bpm, int lo, int hi) {
    var sum = 0, cnt = 0;
    for (var k = 0; k < ts.length; k++) {
      if (ts[k] >= lo && ts[k] < hi) {
        sum += bpm[k];
        cnt++;
      }
    }
    return cnt == 0 ? null : sum / cnt;
  }
}

/// Wrap a list of [DetectedWorkout] in the honesty envelope. An empty list is a
/// valid, honest "no suggested workouts" answer; a null value means the gate
/// could not be placed because [maxBpm] was absent (`need_input:hr_max`).
Metric<List<DetectedWorkout>> autoDetectWorkouts({
  required List<int> hrTs,
  required List<int> hrBpm,
  int? restingBpm,
  int? maxBpm,
  List<MotionPoint>? motion,
  List<SavedWorkoutSpan> savedSpans = const [],
  SportClassifier classify = defaultSportClassifier,
}) {
  if (maxBpm == null) {
    return const Metric<List<DetectedWorkout>>.absent(
      tier: Tier.estimate,
      inputs_used: [],
      note: 'need_input:hr_max',
    );
  }
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
    note: 'opt-in workout suggestion (HR ≥ max(RHR+'
        '${AutoWorkoutDetector.elevatedMarginBPM}, RHR+'
        '${AutoWorkoutDetector.hrrFloorFraction}·HRR) sustained ≥12 min); '
        'wrist-HR ESTIMATE, not medical advice',
  );
}

/// One merged candidate: [start, end] plus the bridged rests inside it, each
/// an open interval (lastEffortSample, firstEffortSample) — see
/// [AutoWorkoutDetector.restBridgeMaxS].
class _Window {
  final int start;
  int end;
  final List<List<int>> rests = [];
  _Window(this.start, this.end);

  /// True when [t] falls strictly inside a bridged rest.
  bool inRest(int t) => rests.any((r) => t > r[0] && t < r[1]);
}
