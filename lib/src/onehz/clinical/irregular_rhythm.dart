// Internal rule for SD1/SD2, pNNx thresholds and sustained-window voting.
// Task Force 1996 supports successive-difference HRV components, not this
// classifier or its SD1/SD2 thresholds; see hrv_time.dart.
// Internal irregular-rhythm screen, ESTIMATE with low confidence. Batch and
// stream share irregularWindowVerdict(); centered moments reorder floating-point
// sums, while exact counters preserve window evidence. Shared adjacency excludes
// timestamp-gap pairs. Diagnostics account for evidence without adding a
// clinical estimator.
// CLINICAL — 24/7 irregular-rhythm SCREEN (NOT a diagnosis).
//
// A pulse-derived screen for sustained beat-to-beat irregularity over a long RR
// window (whole day / sleep). It does NOT diagnose atrial fibrillation or any
// arrhythmia — it flags when the RR scatter is large and disorganised enough to
// warrant "if you have symptoms, see a clinician". Two independent markers must
// BOTH fire to reduce motion/ectopy false positives:
//
//   1. Poincaré SD1/SD2 ratio high — the scatter is round, not cigar-shaped
//      (organised sinus rhythm sits on the identity line → low SD1/SD2).
//   2. pNNx high — a large fraction of successive intervals differ by > x ms,
//      the classic irregularly-irregular signature.
//
// HONESTY: PRV not ECG. Wrist pulse misses P-waves entirely; this is a screen.
// Gated hard on beat count and artifact fraction — a noisy night never flags.

import 'dart:math' as math;
import '../types.dart';
import '../util.dart';
import 'irregular_diagnostics.dart';
import 'irregular_window.dart';

class IrregularRhythm {
  final double sd1; // ms — short-term (beat-to-beat) scatter
  final double sd2; // ms — long-term scatter
  final double sd1sd2; // ratio (→1 = disorganised, →0 = organised sinus)
  final double pnnPct; // % of successive diffs > pnnThresholdMs
  final int nBeats;
  final bool flag; // sustained irregularity screen positive
  const IrregularRhythm({
    required this.sd1,
    required this.sd2,
    required this.sd1sd2,
    required this.pnnPct,
    required this.nBeats,
    required this.flag,
  });
  Map<String, dynamic> toJson() => {
        'sd1_ms': round6(sd1),
        'sd2_ms': round6(sd2),
        'sd1_sd2': round6(sd1sd2),
        'pnn_pct': round6(pnnPct),
        'n_beats': nBeats,
        'flag': flag,
      };
}

/// Minimum clean beats required to run the screen (≈ a solid run of monitoring).
const int irregularScreenMinBeats = 500;

/// 24/7 irregular-rhythm screen over a cleaned NN / RR series (ms).
///
/// [rrMs] beat-to-beat intervals (ideally already artifact-corrected). A light
/// physiologic range filter [300, 2000] ms is applied defensively. [artifactFraction]
/// is the fraction of beats the upstream corrector rejected (0..1); the screen is
/// suppressed above [maxArtifact] because scatter on a dirty signal is noise, not
/// rhythm. Both Poincaré SD1/SD2 ≥ [sd1sd2Flag] AND pNNx ≥ [pnnFlagPct] must hold
/// to flag. Returns an absent Metric when there are too few clean beats.
Metric<IrregularRhythm> irregularBeatScreen(
  List<double> rrMs, {
  // Elapsed beat time (ms), same length + index alignment as [rrMs] — e.g.
  // `RrCorrectionResult.nnTimesMs`. Used ONLY to require the irregularity be
  // SUSTAINED across independent short windows rather than true of one number
  // blended across the whole span. Optional for backward compatibility, but
  // pass it whenever [rrMs] spans more than a few minutes of heterogeneous
  // activity (a whole day) — see the sustained-window note below.
  List<double>? nnTimesMs,
  double artifactFraction = 0.0,
  int minBeats = irregularScreenMinBeats,
  double sd1sd2Flag = 0.70,
  double pnnThresholdMs = 70,
  double pnnFlagPct = 30,
  double maxArtifact = 0.30,
  // ponytail: fixed 5-min / 50%-of-windows heuristic, not backtested against
  // labeled arrhythmia data (none available) — upgrade path is to calibrate
  // windowMinutes/sustainedFraction once real AFib-vs-sinus recordings exist.
  double windowMinutes = 5,
  int minWindowBeats = 40,
  double sustainedFraction = 0.5,
}) =>
    irregularBeatScreenDetailed(
      rrMs,
      nnTimesMs: nnTimesMs,
      artifactFraction: artifactFraction,
      minBeats: minBeats,
      sd1sd2Flag: sd1sd2Flag,
      pnnThresholdMs: pnnThresholdMs,
      pnnFlagPct: pnnFlagPct,
      maxArtifact: maxArtifact,
      windowMinutes: windowMinutes,
      minWindowBeats: minWindowBeats,
      sustainedFraction: sustainedFraction,
    ).metric;

/// [irregularBeatScreen] and the evidence behind its verdict: the beat counts,
/// the per-window counts (the final OPEN window included), the thresholds, and,
/// when the screen abstained, which gate stopped it. The Metric is exactly the
/// one [irregularBeatScreen] returns. [cleaning] is what the RR corrector did
/// upstream, when the caller knows (otherwise those counts are null, not 0).
/// Windows are counted whenever beat times are given, whether or not the
/// aggregate looked irregular and whether or not the screen abstained.
IrregularScreenResult irregularBeatScreenDetailed(
  List<double> rrMs, {
  List<double>? nnTimesMs,
  double artifactFraction = 0.0,
  int minBeats = irregularScreenMinBeats,
  double sd1sd2Flag = 0.70,
  double pnnThresholdMs = 70,
  double pnnFlagPct = 30,
  double maxArtifact = 0.30,
  double windowMinutes = 5,
  int minWindowBeats = 40,
  double sustainedFraction = 0.5,
  RrCleaningCounts? cleaning,
}) {
  const inputs = ['rr_cleaned'];
  final thresholds = IrregularThresholds(
    minBeats: minBeats,
    maxArtifact: maxArtifact,
    sd1sd2Flag: sd1sd2Flag,
    pnnThresholdMs: pnnThresholdMs,
    pnnFlagPct: pnnFlagPct,
    windowMinutes: windowMinutes,
    minWindowBeats: minWindowBeats,
    sustainedFraction: sustainedFraction,
  );
  // The defensive [300, 2000] filter COMPACTS the series. Keep the mask too, so
  // successive differences below are taken only between beats that were both
  // kept AND adjacent in the input — otherwise every filtered beat manufactured
  // one spurious difference spanning the gap, which counted toward pNNx and
  // inflated sdsd/sd1, pushing both flag conditions toward a false "sustained
  // irregularity" screen positive. (NaN fails both comparisons: not a beat.)
  final keep = [for (final v in rrMs) v >= 300 && v <= 2000];
  final nn = [
    for (var i = 0; i < rrMs.length; i++)
      if (keep[i]) rrMs[i]
  ];
  // Per-element flag, aligned to [nn]: was this beat immediately preceded (no
  // dropped beat in between) by the previous kept beat in the ORIGINAL rrMs?
  // Carried into the window pass below so it can skip diffs across a removed
  // artifact beat the same way the aggregate diffs already do (see [keep]
  // note above) instead of just diffing consecutive elements of the
  // compacted array.
  //
  // Successive also means successive in TIME: callers pass `correctRr(...).nn`,
  // which already dropped multi-beat artifact runs and re-anchored its clock
  // across sensor dropouts, so two beats adjacent in the input can still sit
  // either side of a hole. Same seam test as hrv_time.dart: a pair is
  // contiguous iff the elapsed time between the two beat times is the interval.
  final hasTimes = nnTimesMs != null && nnTimesMs.length == rrMs.length;
  final successive = <bool>[
    for (var i = 0; i < rrMs.length; i++)
      i > 0 &&
          keep[i] &&
          keep[i - 1] &&
          (!hasTimes || nnTimesMs[i] - nnTimesMs[i - 1] <= rrMs[i] + 0.5)
  ];
  final nnAdjacent = <bool>[
    for (var i = 0; i < rrMs.length; i++)
      if (keep[i]) successive[i]
  ];
  // Poincaré descriptors — successive beats only (see [keep]).
  final diffs = <double>[
    for (var i = 1; i < rrMs.length; i++)
      if (successive[i]) rrMs[i] - rrMs[i - 1]
  ];
  // Windows are built from the SAME clean beats as the aggregate (the [keep]
  // mask), not the raw input — an artifact beat the aggregate correctly
  // excludes must not be allowed back in to inflate one window's own ratio/pNN
  // into a spurious per-window flag. Counted up front so an abstention can
  // still report them; the verdict reads them only where it did before.
  final windowsOk = irregularWindowConfigOk(
      windowMinutes: windowMinutes,
      minWindowBeats: minWindowBeats,
      sustainedFraction: sustainedFraction);
  IrregularWindowCounts? windows;
  if (hasTimes && windowsOk) {
    final nnTimes = [
      for (var i = 0; i < rrMs.length; i++)
        if (keep[i]) nnTimesMs[i]
    ];
    windows = _countWindows(
      nn,
      nnTimes,
      nnAdjacent,
      sd1sd2Flag: sd1sd2Flag,
      pnnThresholdMs: pnnThresholdMs,
      pnnFlagPct: pnnFlagPct,
      windowMinutes: windowMinutes,
      minWindowBeats: minWindowBeats,
    );
  }

  IrregularScreenResult abstain(IrregularAbstain why, String note) =>
      IrregularScreenResult(
        Metric<IrregularRhythm>.absent(
            tier: Tier.estimate, inputs_used: inputs, note: note),
        IrregularDiagnostics(
          abstain: why,
          rrRaw: cleaning?.raw,
          corrected: cleaning?.corrected,
          dropped: cleaning?.dropped,
          nnIn: rrMs.length,
          nnKept: nn.length,
          artifactFraction: diagnosticArtifactFraction(artifactFraction, cleaning),
          windows: windows,
          thresholds: thresholds,
        ),
      );

  // Gate on the contiguous pairs actually averaged, not the beat count: a
  // series fragmented by holes can hold minBeats beats yet only a handful of
  // successive pairs, and SD1/pNNx would then come from those few diffs.
  if (diffs.length < minBeats - 1) {
    return abstain(IrregularAbstain.tooFewBeats,
        'too few clean beats for an irregular-rhythm screen');
  }
  if (artifactFraction > maxArtifact) {
    return abstain(
        IrregularAbstain.artifact,
        'artifact fraction ${(artifactFraction * 100).round()}% > '
        '${(maxArtifact * 100).round()}% — screen suppressed on noisy RR');
  }

  final sdsd = stddev(diffs);
  final sdnn = stddev(nn);
  if (sdsd == null || sdnn == null) {
    return abstain(IrregularAbstain.noSuccessivePairs,
        'no successive clean beats to build a Poincare plot from');
  }
  final sd1 = sdsd / math.sqrt2;
  final v = 2 * sdnn * sdnn - sd1 * sd1;
  final sd2 = v > 0 ? math.sqrt(v) : 0.0;
  if (sd2 <= 0) {
    // SD1/SD2 is undefined without long-term variability to divide by; emitting
    // ratio 0.0 with sd1 = sd2 = 0 published "perfectly regular" as a
    // measurement of a degenerate series.
    return abstain(
        IrregularAbstain.noLongTermVariability,
        'no long-term variability (SD2 = 0) — the SD1/SD2 ratio is '
        'undefined, not "perfectly regular"');
  }
  final ratio = sd1 / sd2;

  // pNNx — irregularly-irregular fraction.
  var over = 0;
  for (final d in diffs) {
    if (d.abs() > pnnThresholdMs) over++;
  }
  final pnnPct = diffs.isEmpty ? 0.0 : 100.0 * over / diffs.length;

  final aggregateHigh = ratio >= sd1sd2Flag && pnnPct >= pnnFlagPct;
  // A single ratio blended across an entire day always clears both cutoffs —
  // sleep, rest, exercise and posture changes are each legitimately
  // "scattered" in a different way, and stacking them together manufactures
  // the appearance of sustained irregularity out of ordinary daily
  // variability (validated on real user data: 9/9 sampled days sat at or
  // over BOTH thresholds, flagged or not — see analytics#irregular-rhythm
  // false-positive fix). Require the same two conditions to independently
  // hold in a real fraction of short, mostly-stationary windows instead —
  // that is what "sustained" is supposed to mean. Falls back to the old
  // whole-span verdict only when times weren't supplied (short/sleep-only
  // callers where the whole span already IS roughly one physiological state).
  // A bad window config fails CLOSED (never sustained): a misconfigured caller
  // must never manufacture a medical false positive.
  final flag = aggregateHigh &&
      (!hasTimes ||
          (windows != null &&
              windows.valid > 0 &&
              windows.flagged / windows.valid >= sustainedFraction));
  // Confidence scales with beat count (~5000 beats ≈ a full strong night) AND
  // with the artifact fraction we were handed — it used to ignore it entirely,
  // so a barely-passing 29 %-artifact night published at the same confidence as
  // a clean one.
  final conf = (nn.length / 5000.0 * (1 - artifactFraction)).clamp(0.2, 0.9);
  return IrregularScreenResult(
    Metric<IrregularRhythm>(
      value: IrregularRhythm(
        sd1: sd1,
        sd2: sd2,
        sd1sd2: ratio,
        pnnPct: pnnPct,
        nBeats: nn.length,
        flag: flag,
      ),
      confidence: conf,
      tier: Tier.estimate,
      inputs_used: inputs,
      note: 'irregular-rhythm SCREEN (not a diagnosis): Poincaré SD1/SD2 + pNN'
          '${pnnThresholdMs.round()}. PRV not ECG — wrist pulse misses P-waves. '
          'Discuss with a clinician only if you have symptoms.',
    ),
    IrregularDiagnostics(
      abstain: null,
      rrRaw: cleaning?.raw,
      corrected: cleaning?.corrected,
      dropped: cleaning?.dropped,
      nnIn: rrMs.length,
      nnKept: nn.length,
      artifactFraction: diagnosticArtifactFraction(artifactFraction, cleaning),
      windows: windows,
      thresholds: thresholds,
    ),
  );
}

/// Counts the short windows across [rrMs] (clean beats only, with their
/// [timesMs] and [adjacent] flags, all the same length): how many exist, how
/// many are thick enough to vote, how many of those flag, and what the final
/// OPEN window was. The window rule and per-window verdict are the ones
/// `IrregularScreenState` uses (irregular_window.dart).
IrregularWindowCounts _countWindows(
  List<double> rrMs,
  List<double> timesMs,
  // Aligned to [rrMs]: whether each beat was truly adjacent (no dropped
  // artifact beat in between, no time hole) to the previous one in the
  // ORIGINAL series.
  List<bool> adjacent, {
  required double sd1sd2Flag,
  required double pnnThresholdMs,
  required double pnnFlagPct,
  required double windowMinutes,
  required int minWindowBeats,
}) {
  final windowMs = windowMinutes * 60000;
  var total = 0, valid = 0, flagged = 0;
  var openBeats = 0;
  var open = IrregularOpenWindow.none;
  var bucket = <double>[];
  var bucketAdjacent = <bool>[];
  var windowStart = timesMs.isEmpty ? 0.0 : timesMs.first;
  void flush() {
    if (bucket.isEmpty) return;
    final verdict = irregularWindowVerdict(bucket, bucketAdjacent,
        sd1sd2Flag: sd1sd2Flag,
        pnnThresholdMs: pnnThresholdMs,
        pnnFlagPct: pnnFlagPct,
        minWindowBeats: minWindowBeats);
    total++;
    openBeats = bucket.length;
    if (verdict == null) {
      open = IrregularOpenWindow.thin;
    } else {
      valid++;
      if (verdict) flagged++;
      open = verdict ? IrregularOpenWindow.flagged : IrregularOpenWindow.unflagged;
    }
    bucket = [];
    bucketAdjacent = [];
  }

  for (var i = 0; i < rrMs.length; i++) {
    if (timesMs[i] - windowStart >= windowMs) {
      flush();
      windowStart = timesMs[i];
    }
    bucket.add(rrMs[i]);
    bucketAdjacent.add(adjacent[i]);
  }
  flush();
  return IrregularWindowCounts(
    total: total,
    valid: valid,
    flagged: flagged,
    openBeats: openBeats,
    open: open,
  );
}
