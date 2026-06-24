// CLINICAL TIER-1 — Phase-Rectified Signal Averaging (Bauer 2006).
//
// Deceleration Capacity (DC) and Acceleration Capacity (AC) of heart rate.
// Mortality-grade, noise-robust by averaging over thousands of anchors — our
// long all-night beat-to-beat RR is exactly its substrate.
//
// Algorithm:
//   1. Anchor selection: for DC, anchor i where RR(i) > RR(i-1) (a
//      deceleration); for AC, RR(i) < RR(i-1). (Optionally bounded by a ratio
//      threshold T to suppress artifacts — default unbounded as in the
//      canonical DC.)
//   2. For each anchor, take a window of length 2L centered at the anchor.
//      Drop anchors too close to the series ends.
//   3. Phase-aligned averaging: X(k) = mean over anchors of RR(anchor+k),
//      k in [-L, L-1].
//   4. Quantify with the Haar-wavelet-like contrast (s=2):
//      DC = [X(0) + X(1) − X(−1) − X(−2)] / 4.   (ms; positive = healthier)
//
// Risk tiers (Bauer 2006, post-MI): DC ≤2.5 high | 2.6–4.5 intermediate |
// >4.5 low risk.

import '../types.dart';
import '../util.dart';

class PrsaResult {
  final double capacity; // DC (deceleration) or AC (acceleration), ms
  final List<double> profile; // averaged X(k), k=-L..L-1
  final int anchors; // number of anchors averaged
  final String kind; // 'DC' or 'AC'
  final String? riskTier; // only meaningful for DC
  const PrsaResult({
    required this.capacity,
    required this.profile,
    required this.anchors,
    required this.kind,
    this.riskTier,
  });
  Map<String, dynamic> toJson() => {
        'capacity_ms': round6(capacity),
        'anchors': anchors,
        'kind': kind,
        if (riskTier != null) 'risk_tier': riskTier,
      };
}

String _dcRisk(double dc) {
  if (dc <= 2.5) return 'high';
  if (dc <= 4.5) return 'intermediate';
  return 'low';
}

/// PRSA deceleration capacity.
Metric<PrsaResult> decelerationCapacity(List<double> nnMs,
        {int l = 2, double anchorRatioCap = 0.05}) =>
    _prsa(nnMs, l: l, deceleration: true, anchorRatioCap: anchorRatioCap);

/// PRSA acceleration capacity.
Metric<PrsaResult> accelerationCapacity(List<double> nnMs,
        {int l = 2, double anchorRatioCap = 0.05}) =>
    _prsa(nnMs, l: l, deceleration: false, anchorRatioCap: anchorRatioCap);

Metric<PrsaResult> _prsa(
  List<double> nnMs, {
  required int l,
  required bool deceleration,
  required double anchorRatioCap,
}) {
  final kind = deceleration ? 'DC' : 'AC';
  final inputs = const ['rr_cleaned'];
  final n = nnMs.length;
  if (n < 2 * l + 4) {
    return Metric<PrsaResult>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'too few beats for PRSA ($kind)',
    );
  }

  // Anchor selection with an artifact-suppression ratio cap: |RR(i)/RR(i-1)-1|
  // must be ≤ anchorRatioCap so gross jumps (residual artifacts) don't anchor.
  final anchors = <int>[];
  for (var i = l; i < n - l; i++) {
    final prev = nnMs[i - 1];
    if (prev <= 0) continue;
    final delta = nnMs[i] - prev;
    final isDecel = delta > 0;
    if (isDecel != deceleration) continue;
    final ratio = (nnMs[i] / prev - 1).abs();
    if (ratio > anchorRatioCap) continue;
    anchors.add(i);
  }
  if (anchors.isEmpty) {
    return Metric<PrsaResult>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'no valid PRSA anchors ($kind)',
    );
  }

  // Phase-aligned averaging over k in [-l, l-1]  (indices 0..2l-1).
  final profile = List<double>.filled(2 * l, 0);
  for (final a in anchors) {
    for (var k = -l; k < l; k++) {
      profile[k + l] += nnMs[a + k];
    }
  }
  for (var k = 0; k < profile.length; k++) {
    profile[k] /= anchors.length;
  }

  // Quantify with the Haar contrast at the anchor: X(0)+X(1)-X(-1)-X(-2).
  // For l=2: indices are X(-2)=0, X(-1)=1, X(0)=2, X(1)=3.
  final x0 = profile[l]; // k=0
  final x1 = profile[l + 1]; // k=1
  final xm1 = profile[l - 1]; // k=-1
  final xm2 = profile[l - 2]; // k=-2
  final capacity = (x0 + x1 - xm1 - xm2) / 4;

  final conf = clamp(anchors.length / 1000.0, 0.3, 0.95);
  return Metric<PrsaResult>(
    value: PrsaResult(
      capacity: capacity,
      profile: profile,
      anchors: anchors.length,
      kind: kind,
      riskTier: deceleration ? _dcRisk(capacity) : null,
    ),
    confidence: conf,
    tier: Tier.high,
    inputs_used: inputs,
    note: 'Bauer 2006 PRSA $kind; needs a long overnight RR record for '
        'mortality-grade stability',
  );
}
