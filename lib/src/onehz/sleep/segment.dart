// SLEEP — SINGLE-SOURCE segmentation entry point.
//
// ARCHITECTURE_V2 invariant 2/4 + "Segmentation (FROZEN — single source)":
// exactly ONE sleep/wake/stage windowing. No component re-detects sleep; every
// downstream figure (TST, WASO, efficiency, stage minutes, hypnogram) derives
// from the SAME per-second stage labels produced here. There is no second
// estimator — this is THE source.
//
// Pipeline:
//   1. vanHeesSleepWindow(accel) with the published 30-min bridge gap → the
//      in-bed REST window [onsetIdx, offsetIdx) + the per-second immobility mask.
//   2. AdvancedSleepStager.detectSleep/stageWindow, staged via
//      StagingMethod.cardio (the default — delegates to cardioStager, the
//      transparent motion+HR+RMSSD rule stager; see advanced_stager.dart's
//      file header for the 2026-07 comparison behind this default) → 4-class
//      wake/light/deep/rem per epoch, over the WINDOW SLICE ONLY.
//   3. Expand the per-epoch stages to PER-SECOND labels over the window, mark
//      every second we did not actually observe as 'unobserved' (step 4), and
//      derive TST/WASO/efficiency/stage-seconds ALL from those labels
//      (asleep = stage != wake), so they are mutually consistent and consistent
//      with any hypnogram built from `stages`.
//   4. UNOBSERVED time. The window is wall-clock; the substrate is a POSITIONAL
//      array with holes, and HR is intermittent. A second with no sample, or
//      with no heart rate anywhere near it, is labelled 'unobserved' and counts
//      into NOTHING — not TST, not WASO, not wake, not the efficiency
//      denominator. It is published as [SleepSegmentation.unobservedSec] so the
//      UI can state the reason instead of implying a measurement.
//
// HONESTY: if no qualifying sleep (no window, in-bed < ~3 h, staging cannot
// run, or too little of the window was observed) we return
// SleepSegmentation.absent — everything null, confidence 0, with
// [SleepSegmentation.absenceReason] set where the cause is known. Never
// fabricated. Stages are tier ESTIMATE (3-class autonomic, not PSG).

import 'dart:math' as math;
import '../types.dart';
import '../util.dart';
import 'van_hees.dart';
import 'accounting.dart' show SleepStage;
import 'advanced_stager.dart';

/// Minimum in-bed duration to qualify as the main sleep (ARCHITECTURE_V2: ~3 h).
const int _minQualifyingSleepSec = 3 * 3600;

/// Fraction of the in-bed window that must be OBSERVED (a sample present, and a
/// heart rate within half an epoch of it) before any accounting figure is
/// published. Below it the night is [SleepSegmentation.absent] with a reason,
/// not a plausible number over a window nobody watched. Same 0.5 floor the edge
/// applies to the nocturnal accel path (`kMinAccelCoverageForVanHees`).
const double kMinObservedFractionForSleep = 0.5;

/// A second is credited with cardiac evidence when a valid HR sample lands
/// within ±[_hrEvidenceHalfWinSec] of it — half a staging epoch either side.
///
/// The stager decides a 30-s epoch on ANY valid HR inside it, so this is the
/// closest per-second equivalent available here (segmentation does not see the
/// stager's epoch grid, which starts at each usable run, not at a fixed
/// offset). Worst-case misalignment is under one epoch in either direction.
const int _hrEvidenceHalfWinSec = 15;

/// Ceiling on [SleepSegmentation.confidence]. Four-class staging from RR and
/// wrist motion sits at κ 0.21–0.53 across every consumer device measured, and
/// REM and light both show elevated HRV — so no amount of coverage makes this
/// night certain. The confidence this file publishes is a fraction of THIS
/// ceiling, never of 1.0.
const double kMaxSleepConfidence = 0.6;

/// SLP-13 — the narrowest half-width a stage interval may ever have (s).
///
/// A CHOICE, and the same five minutes [kSustainedAwakeningSec] already uses:
/// without it a night with `deep_sec == 0` would publish the interval 0–0,
/// which is the exact false precision the intervals exist to remove. A stage
/// the overlay did not fire on is "under five minutes", not "none".
const int kStageIntervalFloorSec = 300;

/// SLP-13 — relative half-widths at the two ends of the confidence range.
///
/// These are OUR numbers for OUR segmenter, scaled by each night's own
/// [SleepSegmentation.confidence]. They are deliberately NOT a published κ
/// converted into minutes: one literature figure applied uniformly to every
/// night is itself a fabricated precision, it hides the difference between a
/// fully-covered night and one scraping the observed floor, and it is the kind
/// of number that gets quoted back at us as if we had measured it.
///
/// Deep is wider than REM at both ends because it is not the same class of
/// estimate: REM comes out of the stager's own four-class decision, while the
/// Light/Deep boundary is the UNVALIDATED HR-depth overlay (see [stages4]).
const double _remRelHalfBest = 0.30;
const double _remRelHalfWorst = 0.55;
const double _deepRelHalfBest = 0.45;
const double _deepRelHalfWorst = 0.75;

/// SLP-13 — a stage duration as the INTERVAL it actually is.
///
/// [pointSec] is the exact figure the stager counted. It is kept so Investigate
/// (density 3) can show what was counted, and so nothing downstream has to
/// re-derive it — but a normal screen renders [loSec]–[hiSec] and never
/// [pointSec] on its own.
class StageInterval {
  final int pointSec;
  final int loSec;
  final int hiSec;
  const StageInterval(this.pointSec, this.loSec, this.hiSec);
  Map<String, dynamic> toJson() =>
      {'point_sec': pointSec, 'lo_sec': loSec, 'hi_sec': hiSec};
}

/// SLP-13 — the intervals a screen may publish for tonight's stage minutes.
///
/// [confidence] is that night's own [SleepSegmentation.confidence] (0 ..
/// [kMaxSleepConfidence]); a better-observed night gets a narrower interval and
/// a night at the observed floor gets a wide one. Intervals clamp to [0,
/// tstSec] — no stage can exceed the sleep it is a part of.
({StageInterval light, StageInterval deep, StageInterval rem}) stageIntervals({
  required int lightSec,
  required int deepSec,
  required int remSec,
  required int tstSec,
  required double confidence,
}) {
  final t = clamp(confidence / kMaxSleepConfidence, 0.0, 1.0);
  double rel(double best, double worst) => worst + (best - worst) * t;
  final deepHalf = math.max(
    (rel(_deepRelHalfBest, _deepRelHalfWorst) * deepSec).round(),
    kStageIntervalFloorSec,
  );
  final remHalf = math.max(
    (rel(_remRelHalfBest, _remRelHalfWorst) * remSec).round(),
    kStageIntervalFloorSec,
  );
  // Light and Deep are the two sides of ONE binary decision inside NREM: a
  // second the overlay wrongly called deep is a second of light, and vice
  // versa. So light inherits deep's ABSOLUTE half-width — applying deep's
  // RELATIVE width to the (usually much larger) light figure would claim the
  // overlay's error grows with the stage it did not misclassify.
  return (
    light: _interval(lightSec, deepHalf, tstSec),
    deep: _interval(deepSec, deepHalf, tstSec),
    rem: _interval(remSec, remHalf, tstSec),
  );
}

StageInterval _interval(int sec, int halfSec, int tstSec) => StageInterval(
      sec,
      math.max(0, sec - halfSec),
      math.min(tstSec, sec + halfSec),
    );

/// How long a wake run must last to be counted as an awakening (SLP-03).
///
/// Five minutes is a CHOICE — it is the bar Webster's rescoring already uses
/// elsewhere in this package for a genuine sustained awakening, and it is not
/// a physiological boundary. Anything shorter is inside the noise of a 1 Hz
/// wrist. Published in the JSON so the number on screen can state its own bar.
const int kSustainedAwakeningSec = 300;

/// Single-source sleep segmentation result. Every accounting figure is derived
/// from the per-second [stages] labels (asleep = stage != wake), so the parts
/// are mutually consistent. When no sleep qualifies, see [SleepSegmentation.absent].
class SleepSegmentation {
  /// The in-bed window (van Hees REST window, optionally HR-refined). Null when absent.
  final SleepWindow? window;

  /// Per-second 3-class labels over the window [onsetIdx, offsetIdx).
  /// Empty when absent. `stages.length == inBedSec`. (Back-compat: wake/nrem/rem;
  /// NREM here is light+deep combined — the Light/Deep split lives in [stages4].)
  ///
  /// LEGACY VIEW, LOSSY: [SleepStage] has no 'unobserved' member, so a second we
  /// never observed reads here as `wake`. It is NOT counted as wake in any figure
  /// on this class — see [stages4] and [unobservedSec] — but a reader that
  /// tallies this list itself will over-count wake. Prefer [stages4].
  final List<SleepStage> stages;

  /// Per-second labels over the SAME window, aligned 1:1 with [stages]:
  /// 'wake' | 'light' | 'deep' | 'rem' | 'unobserved'. 'light' and 'deep' are the
  /// two halves of NREM — 'deep' marks the NREM seconds the LOW-CONFIDENCE
  /// HR-depth overlay flags as deep (see walch_stager STEP 2); 'light' is the
  /// remaining NREM. The Light/Deep split is an UNVALIDATED estimate; surface it
  /// badged low-confidence.
  ///
  /// 'unobserved' is not a stage and not a measurement: it marks a second the
  /// record does not contain, or one with no heart rate within half an epoch. A
  /// hypnogram must break at those seconds rather than draw across them.
  /// Empty when absent.
  final List<String> stages4;

  /// Total sleep time (s): seconds where stage != wake. Null when absent.
  final int? tstSec;

  /// Wake after sleep onset (s): wake seconds between first and last asleep
  /// second within the window. Null when absent.
  final int? wasoSec;

  /// In-bed time (s) = window length (offsetIdx − onsetIdx). Null when absent.
  /// This is WALL-CLOCK span and includes [unobservedSec].
  final int? inBedSec;

  /// Seconds inside the window we did not observe: no sample in the record, or
  /// no heart rate within half a staging epoch. They count into NOTHING else on
  /// this class. Observed in-bed time is `inBedSec - unobservedSec`. Null when
  /// absent.
  final int? unobservedSec;

  /// Sleep efficiency (%) = 100 · TST / OBSERVED in-bed seconds. Null when
  /// absent. The denominator excludes [unobservedSec] on purpose: dividing by
  /// wall-clock time published 62.7 % for a night where three of the eight hours
  /// were never recorded, which reads as measured wakefulness.
  final double? efficiencyPct;

  /// NREM seconds (stage == nrem) = [lightSec] + [deepSec]. Null when absent.
  /// Kept for back-compat with any reader that still wants combined Core.
  final int? nremSec;

  /// Light-NREM seconds (4-class 'light'). Null when absent.
  final int? lightSec;

  /// Deep-NREM seconds (4-class 'deep') — LOW CONFIDENCE HR-depth overlay
  /// (unvalidated; not PSG). Null when absent.
  final int? deepSec;

  /// REM seconds (stage == rem). Null when absent.
  final int? remSec;

  /// Wake seconds within the window (stage == wake). Null when absent.
  final int? wakeSec;

  /// Sustained awakenings AT LEAST this long: runs of wake between sleep onset
  /// and final offset lasting ≥ [kSustainedAwakeningSec]. Null when absent.
  ///
  /// AT LEAST is not hedging. A 1 Hz wrist cannot see the 3–15 s cortical
  /// arousals PSG counts at all, and our wake specificity is 29–52 %, so the
  /// true number of awakenings is HIGHER than this — never lower. This is not
  /// an arousal index and must never be rendered as one.
  ///
  /// A run TERMINATES at an unobserved second; it never merges across one. Two
  /// two-minute wakes with a charging gap between them are two short wakes we
  /// did not count, not one sustained awakening we invented.
  final int? sustainedAwakenings;

  /// Longest unbroken stretch of sleep (s) inside the window. Null when absent.
  ///
  /// Same rule, and this is where it matters most: the run ends at an
  /// unobserved second as surely as it ends at a wake one. A naive longest-run
  /// that draws through a three-hour hole prints a 5 h stretch nobody watched.
  final int? longestSleepRunSec;

  /// 0..1 confidence — the mean of a van Hees window term and a staging term.
  /// There is no HR-consensus term; no such step exists (see [segmentSleep]).
  /// 0 when absent.
  final double confidence;

  /// Machine-readable cause when [present] is false and the cause is known
  /// (currently: too little of the window was observed). Null when a caller
  /// should say nothing more than "no qualifying sleep". Never render a bare
  /// dash for an absence that carries one of these.
  final String? absenceReason;

  const SleepSegmentation({
    required this.window,
    required this.stages,
    required this.stages4,
    required this.tstSec,
    required this.wasoSec,
    required this.inBedSec,
    required this.unobservedSec,
    required this.efficiencyPct,
    required this.nremSec,
    required this.lightSec,
    required this.deepSec,
    required this.remSec,
    required this.wakeSec,
    required this.sustainedAwakenings,
    required this.longestSleepRunSec,
    required this.confidence,
    this.absenceReason,
  });

  /// Honest "no qualifying sleep" result — all figures null, confidence 0.
  static const SleepSegmentation absent = SleepSegmentation(
    window: null,
    stages: <SleepStage>[],
    stages4: <String>[],
    tstSec: null,
    wasoSec: null,
    inBedSec: null,
    unobservedSec: null,
    efficiencyPct: null,
    nremSec: null,
    lightSec: null,
    deepSec: null,
    remSec: null,
    wakeSec: null,
    sustainedAwakenings: null,
    longestSleepRunSec: null,
    confidence: 0,
  );

  /// Absent BECAUSE the window was too thinly observed to stand behind — the
  /// caller has a reason to show, not a hole.
  static SleepSegmentation unobservedWindow(String reason) => SleepSegmentation(
        window: null,
        stages: const <SleepStage>[],
        stages4: const <String>[],
        tstSec: null,
        wasoSec: null,
        inBedSec: null,
        unobservedSec: null,
        efficiencyPct: null,
        nremSec: null,
        lightSec: null,
        deepSec: null,
        remSec: null,
        wakeSec: null,
        sustainedAwakenings: null,
        longestSleepRunSec: null,
        confidence: 0,
        absenceReason: reason,
      );

  bool get present => window != null;

  /// SLP-13 — tonight's stage minutes as INTERVALS, from this night's own
  /// [confidence]. Null when the night is absent. The exact seconds stay on
  /// [lightSec]/[deepSec]/[remSec] for Investigate; everything user-facing
  /// should be reading this instead.
  ({StageInterval light, StageInterval deep, StageInterval rem})?
      get stageRanges {
    final l = lightSec, d = deepSec, r = remSec, t = tstSec;
    if (l == null || d == null || r == null || t == null) return null;
    return stageIntervals(
      lightSec: l,
      deepSec: d,
      remSec: r,
      tstSec: t,
      confidence: confidence,
    );
  }

  Map<String, dynamic> toJson() => {
        'window': window?.toJson(),
        'tst_sec': tstSec,
        'waso_sec': wasoSec,
        'in_bed_sec': inBedSec,
        'unobserved_sec': unobservedSec,
        'efficiency_pct': efficiencyPct == null ? null : round6(efficiencyPct!),
        'nrem_sec': nremSec,
        'light_sec': lightSec,
        'deep_sec': deepSec,
        'rem_sec': remSec,
        'wake_sec': wakeSec,
        // SLP-03. The 5-minute bar is a CHOICE, not physiology — it ships with
        // the count so a screen can say what it counted.
        'sustained_awakenings': sustainedAwakenings,
        'awakening_min_sec': kSustainedAwakeningSec,
        'longest_sleep_run_sec': longestSleepRunSec,
        'epochs': stages.length,
        'confidence': round6(confidence),
        if (absenceReason != null) 'absence_reason': absenceReason,
        // Deep is a LOW-CONFIDENCE, unvalidated HR-depth overlay (see
        // walch_stager STEP 2). Carry the flag so the UI badges it honestly.
        'deep_low_confidence': true,
        // SLP-13 — the interval each stage figure should actually be shown as,
        // derived from THIS night's confidence. `*_sec` above stays the exact
        // count for Investigate; these are what a normal screen renders.
        'light_range_sec': _rangeJson(stageRanges?.light),
        'deep_range_sec': _rangeJson(stageRanges?.deep),
        'rem_range_sec': _rangeJson(stageRanges?.rem),
      };

  static List<int>? _rangeJson(StageInterval? r) =>
      r == null ? null : [r.loSec, r.hiSec];
}

/// THE single-source sleep segmentation.
///
/// [accel] 1 Hz gravity vectors. [hr1hz] 1 Hz HR (bpm; 0 = off-skin), same time
/// base / length as [accel].
///
/// [hrBaseline] is CURRENTLY UNUSED. The file header describes a pipeline step
/// that confirms/refines onset and offset against a nocturnal-HR dip; no such
/// code exists, and the parameter is read nowhere in this file. It is kept in
/// the signature (all three edge call sites pass a real baseline) so wiring the
/// step up later is a one-file change — but until then, onset and offset are
/// NOT HR-refined, whatever the header says.
SleepSegmentation segmentSleep(
  List<AccelSample> accel,
  List<double> hr1hz, {
  List<double>? hrBaseline,
  List<double> rrMs = const [],
  List<double> rrTsMs = const [],
  int? habitualMidsleepSec,
  ({int onsetSec, int offsetSec})? forcedWindow,
  int? tzOffsetSec,
  int Function(int tsSec)? tzOffsetResolver,
}) {
  final n = math.min(accel.length, hr1hz.length);
  // A forced window (manual entry / user confirmation, Approach 1) is asserted
  // by the human, so it skips the 3 h sample-count gate the auto path enforces —
  // a user may log a 2 h nap, and partial data inside the window is fine (those
  // seconds just stay unstaged/wake). We still need SOME data to stage.
  if (forcedWindow == null && n < _minQualifyingSleepSec) {
    return SleepSegmentation.absent;
  }
  if (n == 0) return SleepSegmentation.absent;

  final trimmedAccel = accel.sublist(0, n);
  final trimmedHr = hr1hz.sublist(0, n);
  // van Hees only runs on the AUTO path; a forced window replaces it entirely.
  final wm = forcedWindow == null
      ? vanHeesSleepWindow(trimmedAccel)
      : const Metric<SleepWindow>.absent(
          tier: Tier.estimate, inputs_used: ['forced_window']);
  final fallbackWindow = wm.value;

  // Local-time-of-day math (daytime guard + midsleep alignment) must use the
  // offset IN EFFECT AT EACH timestamp — a single frozen offset derived from the
  // first sample mishandles a DST transition inside the sleep window (an hour of
  // the night lands in the wrong local hour). Resolve the offset per timestamp:
  //   * [tzOffsetResolver] (if given) wins — lets callers/tests inject a
  //     deterministic ts→offset map (e.g. a synthetic DST span).
  //   * else a fixed [tzOffsetSec] (if given) reproduces the legacy single-offset
  //     behavior for callers that want determinism.
  //   * else the machine's local offset at that instant (DST-correct) is used.
  final int Function(int tsSec) tzAt = tzOffsetResolver ??
      (tzOffsetSec != null
          ? (int _) => tzOffsetSec
          : (int tsSec) => DateTime.fromMillisecondsSinceEpoch(
                tsSec * 1000,
                isUtc: false,
              ).timeZoneOffset.inSeconds);
  final grav = <GravTs>[
    for (var i = 0; i < n; i++)
      GravTs(
        trimmedAccel[i].tsMs ~/ 1000,
        trimmedAccel[i].x,
        trimmedAccel[i].y,
        trimmedAccel[i].z,
      ),
  ];
  final hr = <HrTs>[
    for (var i = 0; i < n; i++)
      if (trimmedHr[i] > 0) HrTs(trimmedAccel[i].tsMs ~/ 1000, trimmedHr[i])
  ];
  final rr = <RrTs>[
    for (var i = 0; i < math.min(rrMs.length, rrTsMs.length); i++)
      if (rrMs[i].isFinite && rrMs[i] > 0)
        RrTs((rrTsMs[i] / 1000.0).round(), rrMs[i])
  ];

  final _SleepGroup? chosen;
  if (forcedWindow != null) {
    final onsetSec = forcedWindow.onsetSec;
    final offsetSec = forcedWindow.offsetSec;
    if (offsetSec <= onsetSec) return SleepSegmentation.absent;
    // Stage the user-asserted window directly — no detection, no gates.
    final session =
        AdvancedSleepStager.stageWindow(onsetSec, offsetSec, grav, hr, rr: rr);
    chosen = _SleepGroup(
      sessions: [session],
      start: onsetSec,
      end: offsetSec,
      asleepMin: AdvancedSleepStager.hypnogramMetrics(session).tstS / 60.0,
    );
  } else {
    final sessions = AdvancedSleepStager.detectSleep(
      grav,
      hr,
      rr: rr,
      tzOffsetResolver: tzAt,
    );
    if (sessions.isEmpty) return SleepSegmentation.absent;

    chosen = _pickMainSleepGroup(
      _bridgeAdjacentSessions(sessions),
      tzAt,
      habitualMidsleepSec: habitualMidsleepSec,
    );
  }
  if (chosen == null) return SleepSegmentation.absent;

  final tsSec = [for (final a in trimmedAccel) a.tsMs ~/ 1000];
  final onset = _lowerBoundInt(tsSec, chosen.start);
  final offset = _lowerBoundInt(tsSec, chosen.end);
  final inBed = chosen.end - chosen.start;
  if (inBed <= 0) return SleepSegmentation.absent;
  // The empty-index and 3 h in-bed floors are AUTO-path sanity gates; a forced
  // window is the user's word — honor any positive-length window.
  if (forcedWindow == null &&
      (offset <= onset || inBed < _minQualifyingSleepSec)) {
    return SleepSegmentation.absent;
  }

  // OBSERVED mask over the wall-clock window. `inBed` is wall-clock length but
  // `trimmedAccel` is a POSITIONAL array with holes (pruning, sync gaps), and HR
  // is intermittent — so a second is observed only when BOTH hold:
  //   * the record contains a sample for it, and
  //   * a valid HR landed within half a staging epoch of it.
  // Neither used to be checked. Every unwritten second defaulted to 'wake' and
  // was then counted as measured WASO, as wake_sec and into the efficiency
  // denominator: an 8 h confirmed window over a 5 h record published waso
  // 10740 s and 62.7 % efficiency for three hours nobody watched. And every
  // no-HR epoch could only ever fall through to NREM (see cardio_stager's
  // asymmetric gates), so it was credited to TST as Light on zero cardiac
  // evidence, one-way, inflating TST and efficiency and never deflating them.
  final sampled = List<bool>.filled(inBed, false);
  final hrNear = List<bool>.filled(inBed, false);
  for (var k = onset; k < tsSec.length && tsSec[k] < chosen.end; k++) {
    final off = tsSec[k] - chosen.start;
    if (off < 0 || off >= inBed) continue;
    sampled[off] = true;
    if (trimmedHr[k] <= 0) continue;
    final lo = math.max(0, off - _hrEvidenceHalfWinSec);
    final hi = math.min(inBed - 1, off + _hrEvidenceHalfWinSec);
    for (var m = lo; m <= hi; m++) {
      hrNear[m] = true;
    }
  }
  final observed = List<bool>.generate(inBed, (i) => sampled[i] && hrNear[i],
      growable: false);

  final stages4 = List<String>.filled(inBed, 'wake');
  for (final session in chosen.sessions) {
    for (final seg in session.stages) {
      final lo = math.max(0, seg.start - chosen.start);
      final hi = math.min(inBed, seg.end - chosen.start);
      for (var i = lo; i < hi; i++) {
        stages4[i] = seg.stage;
      }
    }
  }
  // Stamped LAST: an unobserved second has no stage, whatever a staging segment
  // spanning the hole happened to claim.
  var unobservedSec = 0;
  for (var i = 0; i < inBed; i++) {
    if (observed[i]) continue;
    stages4[i] = 'unobserved';
    unobservedSec++;
  }

  final observedSec = inBed - unobservedSec;
  if (observedSec < inBed * kMinObservedFractionForSleep) {
    return SleepSegmentation.unobservedWindow(
      'only ${observedSec}s of a ${inBed}s window were observed '
      '(sample + heart rate); below the '
      '${(kMinObservedFractionForSleep * 100).round()}% floor',
    );
  }

  final perSec = List<SleepStage>.generate(
    inBed,
    (i) => _sleepStageFor(stages4[i]),
    growable: false,
  );
  var tst = 0, waso = 0, nrem = 0, light = 0, deep = 0, rem = 0, wake = 0;
  var firstSleep = -1, lastSleep = -1;
  for (var i = 0; i < perSec.length; i++) {
    if (!observed[i]) continue;
    switch (perSec[i]) {
      case SleepStage.wake:
        wake++;
        break;
      case SleepStage.nrem:
        nrem++;
        tst++;
        if (stages4[i] == 'deep') {
          deep++;
        } else {
          light++;
        }
        break;
      case SleepStage.rem:
        rem++;
        tst++;
        break;
    }
    if (perSec[i] != SleepStage.wake) {
      if (firstSleep < 0) firstSleep = i;
      lastSleep = i;
    }
  }
  if (firstSleep >= 0) {
    for (var i = firstSleep; i <= lastSleep; i++) {
      if (observed[i] && perSec[i] == SleepStage.wake) waso++;
    }
  }

  // SLP-03 — the SHAPE of the night, off the same per-second labels everything
  // else here comes from, so there is one definition of where a run ends.
  //
  // Three states, not two: asleep / wake / UNOBSERVED. Both runs terminate at
  // an unobserved second. Merging across one is how a naive longest-run bridges
  // a three-hour charging hole and prints a 5 h unbroken stretch, and how two
  // short wakes either side of a gap become one "sustained awakening".
  var sustainedAwakenings = 0;
  var longestSleepRun = 0;
  var sleepRun = 0;
  var wakeRun = 0;
  for (var i = 0; i < perSec.length; i++) {
    final asleep = observed[i] && perSec[i] != SleepStage.wake;
    final awake = observed[i] && perSec[i] == SleepStage.wake;
    sleepRun = asleep ? sleepRun + 1 : 0;
    if (sleepRun > longestSleepRun) longestSleepRun = sleepRun;
    // Awakenings are WASO only — the settling before onset and the lie-in after
    // final offset are not awakenings.
    final inWaso = firstSleep >= 0 && i > firstSleep && i < lastSleep;
    if (awake && inWaso) {
      wakeRun++;
      if (wakeRun == kSustainedAwakeningSec) sustainedAwakenings++;
    } else {
      wakeRun = 0;
    }
  }
  if (tst == 0) {
    // Nothing in the window staged as sleep. A forced window deliberately skips
    // the 3 h and index gates, so this used to publish tst 0 / efficiency 0 % as
    // a PRESENT metric — "0 h 0 m slept, 0 % efficiency" for a night we simply
    // did not observe. That is a fabricated measurement, not an abstention.
    return SleepSegmentation.absent;
  }
  // Denominator is OBSERVED in-bed time, not wall clock — see [efficiencyPct].
  final efficiency = observedSec > 0 ? 100.0 * tst / observedSec : 0.0;

  // Confidence = window quality x STAGING quality. The staging term used to be
  // the literal 0.5, so every forced-window night (where `wm` is absent) came
  // out at exactly 0.475 no matter how much data was behind it. cardioStager
  // computes a real staging confidence (0.35 + 0.25*rrCov) and throws it away
  // on the way out, and threading it back through SleepSession is a wider
  // change than this — so recompute the same quantity from the HR and beats
  // that actually landed INSIDE the chosen window.
  var hrCovered = 0;
  final rrSeconds = <int>{};
  for (var i = 0; i < n; i++) {
    final ts = trimmedAccel[i].tsMs ~/ 1000;
    if (ts < chosen.start || ts >= chosen.end) continue;
    if (trimmedHr[i] > 0) hrCovered++;
  }
  for (final b in rr) {
    if (b.ts >= chosen.start && b.ts < chosen.end) rrSeconds.add(b.ts);
  }
  final hrCov = clamp(hrCovered / inBed, 0.0, 1.0);
  final rrCov = clamp(rrSeconds.length / inBed, 0.0, 1.0);
  final stagingConf = (0.35 + 0.25 * rrCov) * hrCov;
  final windowConf = wm.confidence > 0 ? wm.confidence : 0.45;
  final conf =
      clamp((windowConf + stagingConf) / 2.0, 0.0, kMaxSleepConfidence);

  return SleepSegmentation(
    window: SleepWindow(
      onsetIdx: onset,
      offsetIdx: offset,
      onsetMs: chosen.start * 1000.0,
      offsetMs: chosen.end * 1000.0,
      // EMPTY when van Hees never ran (every forced-window path), as
      // `immobileUnknown` already is. A full-length all-false immobility mask
      // and an all-0.0 deg arm-angle series are fabricated per-second
      // measurements, not "we did not look".
      immobile: fallbackWindow?.immobile ?? const [],
      // Forward the undecidable-second mask too. Dropping it here silently
      // downgraded "we could not tell" into "not immobile", which is the
      // conservative direction but costs the caller `undecidableSec` — the
      // one signal that says a night ran past the end of the record.
      immobileUnknown: fallbackWindow?.immobileUnknown ?? const [],
      zAngleDeg: fallbackWindow?.zAngleDeg ?? const [],
      sptSec: inBed,
    ),
    stages: perSec,
    stages4: stages4,
    tstSec: tst,
    wasoSec: waso,
    inBedSec: inBed,
    unobservedSec: unobservedSec,
    efficiencyPct: efficiency,
    nremSec: nrem,
    lightSec: light,
    deepSec: deep,
    remSec: rem,
    wakeSec: wake,
    sustainedAwakenings: sustainedAwakenings,
    longestSleepRunSec: longestSleepRun,
    confidence: conf,
  );
}

class _SleepGroup {
  final List<SleepSession> sessions;
  final int start;
  final int end;
  final double asleepMin;

  /// The group's circadian centre: the midpoint of its ACTUAL SPAN. This is
  /// what a midsleep anchor is defined against (the middle of the sleep period,
  /// gaps included — Roenneberg's MSF/mid-sleep convention), and it is what
  /// [_pickMainSleepGroup] must compare with a habitual-midsleep anchor.
  int get midsleepSec => start + (end - start) ~/ 2;

  const _SleepGroup({
    required this.sessions,
    required this.start,
    required this.end,
    required this.asleepMin,
  });
}

List<_SleepGroup> _bridgeAdjacentSessions(List<SleepSession> sessions) {
  if (sessions.isEmpty) return const [];
  final sorted = [...sessions]..sort((a, b) => a.start.compareTo(b.start));
  const bridgeGapSec = 60 * 60;
  final out = <_SleepGroup>[];
  for (final session in sorted) {
    final asleepMin = AdvancedSleepStager.hypnogramMetrics(session).tstS / 60.0;
    if (out.isEmpty) {
      out.add(
        _SleepGroup(
          sessions: [session],
          start: session.start,
          end: session.end,
          asleepMin: asleepMin,
        ),
      );
      continue;
    }
    final last = out.removeLast();
    final gap = session.start - last.end;
    if (gap >= 0 && gap < bridgeGapSec) {
      out.add(
        _SleepGroup(
          sessions: [...last.sessions, session],
          start: last.start,
          end: math.max(last.end, session.end),
          asleepMin: last.asleepMin + asleepMin,
        ),
      );
    } else {
      out.add(last);
      out.add(
        _SleepGroup(
          sessions: [session],
          start: session.start,
          end: session.end,
          asleepMin: asleepMin,
        ),
      );
    }
  }
  return out;
}

_SleepGroup? _pickMainSleepGroup(
  List<_SleepGroup> groups,
  int Function(int tsSec) tzAt, {
  int? habitualMidsleepSec,
}) {
  if (groups.isEmpty) return null;
  const alignmentBonusMin = 90.0;
  const fullWindowSec = 2 * 3600;
  const zeroWindowSec = 5 * 3600;
  const overnightStartHour = 20;
  const overnightEndHour = 11;
  const secondsPerDay = 86400;
  final overnightSpanSec =
      (((overnightEndHour - overnightStartHour) * 3600) + secondsPerDay) %
          secondsPerDay;
  final coldStartAnchorSec =
      ((overnightStartHour * 3600) + overnightSpanSec ~/ 2) % secondsPerDay;
  final targetMidsleepSec = habitualMidsleepSec ?? coldStartAnchorSec;

  int localSecOfDay(int ts) {
    // Per-timestamp offset (DST-correct); [tzAt] is constant when the caller
    // passed a fixed offset, otherwise the offset in effect at [ts].
    final local = ts + tzAt(ts);
    return ((local % secondsPerDay) + secondsPerDay) % secondsPerDay;
  }

  int circularDistanceSec(int a, int b) {
    final raw = (a - b).abs() % secondsPerDay;
    return math.min(raw, secondsPerDay - raw);
  }

  double alignmentBonusFor(_SleepGroup g) {
    // Midsleep = the middle of the SPAN — see [_SleepGroup.midsleepSec].
    final dist =
        circularDistanceSec(localSecOfDay(g.midsleepSec), targetMidsleepSec);
    if (dist <= fullWindowSec) return alignmentBonusMin;
    if (dist >= zeroWindowSec) return 0.0;
    final frac = (zeroWindowSec - dist) / (zeroWindowSec - fullWindowSec);
    return alignmentBonusMin * frac;
  }

  _SleepGroup winner = groups.first;
  var bestScore = winner.asleepMin + alignmentBonusFor(winner);
  for (final g in groups.skip(1)) {
    final score = g.asleepMin + alignmentBonusFor(g);
    if (score > bestScore || (score == bestScore && g.start < winner.start)) {
      winner = g;
      bestScore = score;
    }
  }
  return winner;
}

/// Habitual midsleep anchor (local second-of-day) from ≥[minDays] of history.
///
/// Timezone conversion is PER TIMESTAMP, with exactly the same precedence
/// [segmentSleep] uses for its own local-time-of-day math — because the anchor
/// this returns is compared against `_pickMainSleepGroup`'s per-timestamp
/// conversion, and the two must agree:
///   * [tzOffsetResolver] (if given) wins — inject a deterministic ts→offset map.
///   * else a fixed [tzOffsetSeconds] (if given) — LEGACY/deterministic only.
///   * else the machine's offset in effect AT EACH timestamp (DST-correct).
///
/// A single frozen offset applied to every history block is a DST bypass: the
/// ≥14 days this function requires will regularly straddle a transition, so
/// roughly half the days convert with the wrong offset and the circular-mean
/// anchor is biased by up to ~30 min against the DST-correct comparison it
/// feeds. Prefer passing NOTHING (machine-local, DST-correct) or a resolver;
/// pass [tzOffsetSeconds] only when a caller genuinely wants one frozen offset.
int? habitualMidsleepSecFromHistory(
  List<({int startSec, int endSec, String dayKey})> history, {
  int? tzOffsetSeconds,
  int Function(int tsSec)? tzOffsetResolver,
  int minDays = 14,
}) {
  if (history.isEmpty) return null;
  final int Function(int tsSec) tzAt = tzOffsetResolver ??
      (tzOffsetSeconds != null
          ? (int _) => tzOffsetSeconds
          : (int tsSec) => DateTime.fromMillisecondsSinceEpoch(
                tsSec * 1000,
                isUtc: false,
              ).timeZoneOffset.inSeconds);
  final longestByDay = <String, ({int startSec, int endSec, String dayKey})>{};
  for (final block in history) {
    final cur = longestByDay[block.dayKey];
    final dur = block.endSec - block.startSec;
    final curDur = cur == null ? -1 : cur.endSec - cur.startSec;
    if (cur == null ||
        dur > curDur ||
        (dur == curDur && block.startSec < cur.startSec)) {
      longestByDay[block.dayKey] = block;
    }
  }
  if (longestByDay.length < minDays) return null;
  final mids = [
    for (final block in longestByDay.values)
      // Convert with the offset in effect AT THAT BLOCK'S midsleep instant, not
      // one offset frozen for the whole history — see the doc comment above.
      () {
        final mid = block.startSec + ((block.endSec - block.startSec) ~/ 2);
        return _localSecOfDay(mid, tzAt(mid));
      }(),
  ];
  return _circularMeanSec(mids);
}

int _localSecOfDay(int ts, int offsetSec) {
  const secondsPerDay = 86400;
  final local = ts + offsetSec;
  return ((local % secondsPerDay) + secondsPerDay) % secondsPerDay;
}

int? _circularMeanSec(List<int> secs) {
  if (secs.isEmpty) return null;
  const secondsPerDay = 86400;
  const minResultant = 1e-9;
  var sumSin = 0.0;
  var sumCos = 0.0;
  final k = 2.0 * math.pi / secondsPerDay;
  for (final s in secs) {
    final a = s * k;
    sumSin += math.sin(a);
    sumCos += math.cos(a);
  }
  final resultant = math.sqrt(sumSin * sumSin + sumCos * sumCos) / secs.length;
  if (resultant < minResultant) return null;
  var ang = math.atan2(sumSin, sumCos);
  if (ang < 0) ang += 2.0 * math.pi;
  final sec = (ang / k).round() % secondsPerDay;
  return ((sec % secondsPerDay) + secondsPerDay) % secondsPerDay;
}

/// 4-class label → the legacy 3-class enum. 'unobserved' has no member and maps
/// to `wake` — see [SleepSegmentation.stages] for why that view is lossy and why
/// no figure on this class is derived from it.
SleepStage _sleepStageFor(String label) {
  switch (label) {
    case 'rem':
      return SleepStage.rem;
    case 'light':
    case 'deep':
      return SleepStage.nrem;
    default:
      return SleepStage.wake;
  }
}

int _lowerBoundInt(List<int> xs, int target) {
  var lo = 0, hi = xs.length;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (xs[mid] < target) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  return lo;
}
