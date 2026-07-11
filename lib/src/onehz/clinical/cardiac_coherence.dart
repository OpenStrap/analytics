// CLINICAL — real-time "cardiac coherence" from live RR during a guided
// paced-breathing session.
//
// McCraty & Zayas 2014 ("Emotional Stress, Positive Emotions, and
// Psychophysiological Coherence", Frontiers in Psychology), building on
// McCraty, Atkinson, Tomasino & Bradley 2009 ("The Coherent Heart"). The
// method: take the Lomb-Scargle PSD of the beat-to-beat tachogram, find the
// single dominant peak within 0.04-0.26 Hz (the range paced/resonance
// breathing entrains RSA into), integrate power in a narrow window around
// that peak (+/- 0.015 Hz), and divide by the REMAINING spectral power. A
// clean, single, regular oscillation (breathing-entrained RSA) produces a
// high ratio; a noisy/irregular tachogram produces a low one.
//
// HONESTY:
//   * This is PRV (wrist-PPG beat timing), not ECG-HRV — ESTIMATE tier.
//   * A live guided session is short (~1-2 min) vs. HeartMath's classic 3-5
//     min protocol, so the peak-frequency estimate is correspondingly
//     noisier — confidence scales with span length.
//   * The raw [ratio] is the cited measure. The 0-100 [score] is OUR OWN
//     saturating display map (score = 100*ratio/(ratio+1)) — NOT a published
//     scale (HeartMath's own commercial coherence score uses a different,
//     proprietary mapping we don't have access to). Documented as an
//     engineering choice, same convention as e.g. steps.dart's minBoutMin.
//   * Absent/insufficient input => null Metric, never a fabricated number.

import '../types.dart';
import '../util.dart';

class CardiacCoherence {
  /// Raw McCraty coherence ratio: peak-band power / remaining spectral power.
  /// Unbounded, >= 0. This is the cited measure.
  final double ratio;

  /// 0-100 saturating display map of [ratio] (our own choice, not published).
  final double score;

  /// Dominant frequency found within the 0.04-0.26 Hz search band (Hz).
  final double peakHz;

  const CardiacCoherence({
    required this.ratio,
    required this.score,
    required this.peakHz,
  });

  Map<String, dynamic> toJson() => {
        'ratio': round6(ratio),
        'score': round6(score),
        'peak_hz': round6(peakHz),
      };
}

/// [nnMs] cleaned NN intervals (ms), [nnTimesMs] their cumulative beat times
/// (ms) — pass `correctRr(...)`'s `.nn` / `.nnTimesMs` directly.
///
/// [pacedHz] the guided pacing frequency if known (e.g. 5.5 breaths/min ==
/// 0.0917 Hz). Purely informational for the confidence/note — the search
/// band stays McCraty's full 0.04-0.26 Hz regardless, since a user won't
/// always be perfectly on-pace.
Metric<CardiacCoherence> cardiacCoherence(
  List<double> nnMs,
  List<double> nnTimesMs, {
  double? pacedHz,
  int gridPoints = 400,
}) {
  const inputs = ['rr_cleaned', 'beat_times'];
  if (nnMs.length < 20 || nnTimesMs.length != nnMs.length) {
    return const Metric<CardiacCoherence>.absent(
      tier: Tier.estimate,
      inputs_used: inputs,
      note: 'too few beats for a coherence estimate',
    );
  }

  final tSec = [for (final t in nnTimesMs) t / 1000.0];
  final spanSec = tSec.last - tSec.first;
  if (spanSec < 30) {
    return const Metric<CardiacCoherence>.absent(
      tier: Tier.estimate,
      inputs_used: inputs,
      note: 'session too short (< 30s) for a spectral estimate',
    );
  }

  const searchLoHz = 0.04, searchHiHz = 0.26;
  const totalHiHz = 0.4;
  // Total-power floor can't resolve below ~1/span — mirrors hrvFreq's same
  // honesty guard rather than pretending a short session sees down to 0.0033 Hz.
  final totalLoHz = (1.0 / spanSec).clamp(0.0033, searchLoHz);

  final ls = lombScargle(tSec, nnMs, freqGrid(totalLoHz, totalHiHz, gridPoints));
  if (ls == null) {
    return const Metric<CardiacCoherence>.absent(
      tier: Tier.estimate,
      inputs_used: inputs,
      note: 'spectrum undefined',
    );
  }

  final peakHz = ls.peakFreq(searchLoHz, searchHiHz);
  if (peakHz == null) {
    return const Metric<CardiacCoherence>.absent(
      tier: Tier.estimate,
      inputs_used: inputs,
      note: 'no resolvable peak in the 0.04-0.26 Hz coherence band',
    );
  }

  final peakPower = ls.bandPower(
    (peakHz - 0.015).clamp(totalLoHz, totalHiHz),
    (peakHz + 0.015).clamp(totalLoHz, totalHiHz),
  );
  final totalPower = ls.bandPower(totalLoHz, totalHiHz);
  final remainder = totalPower - peakPower;
  if (remainder <= 0) {
    return const Metric<CardiacCoherence>.absent(
      tier: Tier.estimate,
      inputs_used: inputs,
      note: 'degenerate spectrum (all power in the peak window)',
    );
  }

  final ratio = peakPower / remainder;
  final score = 100.0 * ratio / (ratio + 1.0);

  final onPace = pacedHz != null && (peakHz - pacedHz).abs() < 0.02;
  // Confidence scales with how much of HeartMath's classic 3-5 min protocol
  // this span actually covers (floored/ceilinged), lightly penalized when the
  // found peak isn't near the guided pace (could still be real RSA, just less
  // clearly the paced-breathing entrainment this feature is meant to reward).
  final conf = clamp(
    (spanSec / 180.0).clamp(0.3, 1.0) * (onPace ? 1.0 : 0.85),
    0.2,
    0.9,
  );

  return Metric<CardiacCoherence>(
    value: CardiacCoherence(ratio: ratio, score: score, peakHz: peakHz),
    confidence: conf,
    tier: Tier.estimate,
    inputs_used: inputs,
    note: onPace
        ? 'peak matches guided pace — breathing-entrained RSA'
        : 'peak off guided pace by > 0.02 Hz — may be natural RSA, not entrainment',
  );
}
