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
}) {
  const inputs = ['rr_cleaned'];
  // The defensive [300, 2000] filter COMPACTS the series. Keep the mask too, so
  // successive differences below are taken only between beats that were both
  // kept AND adjacent in the input — otherwise every filtered beat manufactured
  // one spurious difference spanning the gap, which counted toward pNNx and
  // inflated sdsd/sd1, pushing both flag conditions toward a false "sustained
  // irregularity" screen positive.
  final keep = [for (final v in rrMs) v >= 300 && v <= 2000];
  final nn = [for (var i = 0; i < rrMs.length; i++) if (keep[i]) rrMs[i]];
  if (nn.length < minBeats) {
    return const Metric<IrregularRhythm>.absent(
      tier: Tier.estimate,
      inputs_used: inputs,
      note: 'too few clean beats for an irregular-rhythm screen',
    );
  }
  if (artifactFraction > maxArtifact) {
    return Metric<IrregularRhythm>.absent(
      tier: Tier.estimate,
      inputs_used: inputs,
      note: 'artifact fraction ${(artifactFraction * 100).round()}% > '
          '${(maxArtifact * 100).round()}% — screen suppressed on noisy RR',
    );
  }

  // Poincaré descriptors — successive beats only (see [keep]).
  final diffs = <double>[
    for (var i = 1; i < rrMs.length; i++)
      if (keep[i] && keep[i - 1]) rrMs[i] - rrMs[i - 1]
  ];
  final sdsd = stddev(diffs);
  final sdnn = stddev(nn);
  if (sdsd == null || sdnn == null) {
    return const Metric<IrregularRhythm>.absent(
      tier: Tier.estimate,
      inputs_used: inputs,
      note: 'no successive clean beats to build a Poincare plot from',
    );
  }
  final sd1 = sdsd / math.sqrt2;
  final v = 2 * sdnn * sdnn - sd1 * sd1;
  final sd2 = v > 0 ? math.sqrt(v) : 0.0;
  if (sd2 <= 0) {
    // SD1/SD2 is undefined without long-term variability to divide by; emitting
    // ratio 0.0 with sd1 = sd2 = 0 published "perfectly regular" as a
    // measurement of a degenerate series.
    return const Metric<IrregularRhythm>.absent(
      tier: Tier.estimate,
      inputs_used: inputs,
      note: 'no long-term variability (SD2 = 0) — the SD1/SD2 ratio is '
          'undefined, not "perfectly regular"',
    );
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
  // Windows are built from the SAME clean beats as the aggregate above (the
  // [keep] mask), not the raw input — an artifact beat the aggregate
  // correctly excludes must not be allowed back in here to inflate one
  // window's own ratio/pNN into a spurious per-window flag.
  final hasTimes = nnTimesMs != null && nnTimesMs.length == rrMs.length;
  final nnTimes = hasTimes
      ? [for (var i = 0; i < rrMs.length; i++) if (keep[i]) nnTimesMs[i]]
      : const <double>[];
  final flag = aggregateHigh &&
      (!hasTimes ||
          _sustainedAcrossWindows(
            nn,
            nnTimes,
            sd1sd2Flag: sd1sd2Flag,
            pnnThresholdMs: pnnThresholdMs,
            pnnFlagPct: pnnFlagPct,
            windowMinutes: windowMinutes,
            minWindowBeats: minWindowBeats,
            sustainedFraction: sustainedFraction,
          ));
  // Confidence scales with beat count (~5000 beats ≈ a full strong night) AND
  // with the artifact fraction we were handed — it used to ignore it entirely,
  // so a barely-passing 29 %-artifact night published at the same confidence as
  // a clean one.
  final conf = clamp(nn.length / 5000.0 * (1 - artifactFraction), 0.2, 0.9);
  return Metric<IrregularRhythm>(
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
  );
}

/// True when the SD1/SD2 + pNNx criteria independently hold in a real
/// fraction of short, roughly-stationary windows across [rrMs] — not just in
/// the one number the whole span blends into. [timesMs] must be the same
/// length as [rrMs] and index-aligned (elapsed ms per beat).
bool _sustainedAcrossWindows(
  List<double> rrMs,
  List<double> timesMs, {
  required double sd1sd2Flag,
  required double pnnThresholdMs,
  required double pnnFlagPct,
  required double windowMinutes,
  required int minWindowBeats,
  required double sustainedFraction,
}) {
  if (timesMs.length != rrMs.length || rrMs.length < 2) return false;
  // Fail CLOSED (never sustained) on a bad config — a misconfigured caller
  // must never manufacture a medical false positive.
  if (!windowMinutes.isFinite ||
      windowMinutes <= 0 ||
      minWindowBeats < 2 ||
      !sustainedFraction.isFinite ||
      sustainedFraction < 0 ||
      sustainedFraction > 1) {
    return false;
  }
  final windowMs = windowMinutes * 60000;
  var windowStart = timesMs.first;
  var validWindows = 0;
  var flaggedWindows = 0;
  var bucket = <double>[];
  void flush() {
    if (bucket.length >= minWindowBeats) {
      validWindows++;
      final diffs = <double>[
        for (var i = 1; i < bucket.length; i++) bucket[i] - bucket[i - 1]
      ];
      final sdsd = stddev(diffs);
      final sdnn = stddev(bucket);
      if (sdsd != null && sdnn != null) {
        final sd1 = sdsd / math.sqrt2;
        final v = 2 * sdnn * sdnn - sd1 * sd1;
        final sd2 = v > 0 ? math.sqrt(v) : 0.0;
        if (sd2 > 0) {
          final ratio = sd1 / sd2;
          final over = diffs.where((d) => d.abs() > pnnThresholdMs).length;
          final pnn = 100.0 * over / diffs.length;
          if (ratio >= sd1sd2Flag && pnn >= pnnFlagPct) flaggedWindows++;
        }
      }
    }
    bucket = [];
  }

  for (var i = 0; i < rrMs.length; i++) {
    if (timesMs[i] - windowStart >= windowMs) {
      flush();
      windowStart = timesMs[i];
    }
    bucket.add(rrMs[i]);
  }
  flush();
  if (validWindows == 0) return false;
  return flaggedWindows / validWindows >= sustainedFraction;
}
