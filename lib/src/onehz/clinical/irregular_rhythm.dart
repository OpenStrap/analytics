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
  double artifactFraction = 0.0,
  int minBeats = irregularScreenMinBeats,
  double sd1sd2Flag = 0.70,
  double pnnThresholdMs = 70,
  double pnnFlagPct = 30,
  double maxArtifact = 0.30,
}) {
  const inputs = ['rr_cleaned'];
  final nn = [for (final v in rrMs) if (v >= 300 && v <= 2000) v];
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

  // Poincaré descriptors.
  final diffs = [for (var i = 1; i < nn.length; i++) nn[i] - nn[i - 1]];
  final sdsd = stddev(diffs) ?? 0.0;
  final sdnn = stddev(nn) ?? 0.0;
  final sd1 = sdsd / math.sqrt2;
  final v = 2 * sdnn * sdnn - sd1 * sd1;
  final sd2 = v > 0 ? math.sqrt(v) : 0.0;
  final ratio = sd2 > 0 ? sd1 / sd2 : 0.0;

  // pNNx — irregularly-irregular fraction.
  var over = 0;
  for (final d in diffs) {
    if (d.abs() > pnnThresholdMs) over++;
  }
  final pnnPct = diffs.isEmpty ? 0.0 : 100.0 * over / diffs.length;

  final flag = ratio >= sd1sd2Flag && pnnPct >= pnnFlagPct;
  // Confidence scales with beat count; ~5000 beats ≈ a full strong night.
  final conf = clamp(nn.length / 5000.0, 0.3, 0.9);
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
