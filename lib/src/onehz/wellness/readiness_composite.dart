// WELLNESS — honest glass-box readiness composite.
//
// ★ CANONICAL recovery/readiness (ARCHITECTURE_V2 `recovery.score`). ★
// Per the "one source per concept" invariant there is exactly ONE headline
// readiness, and this is it: disclosed weights (HRV>RHR>RR>temp) + ranked
// drivers + personal-baseline robust z-scores (median+MAD `robustZ`) + an
// SWC/TE gate that will say "no meaningful change". The other readiness
// function — `glassBoxReadiness` in human/readiness_glassbox.dart — is the
// DEPRECATED duplicate (ARCHITECTURE_V2 "DROP: the duplicate readiness
// composite"); it is kept exported for back-compat but is INTERNAL and must not
// be surfaced as the headline. Reason this one is canonical: it uses
// personal-baseline z-scores (not percentiles), the exact criterion in the
// frozen catalog.
//
// Catalog: "per-metric percentile/z to personal baseline → sign-orient →
// weighted sum (HRV>RHR>RR>temp) → SWC/TE gate. Reweight on missing inputs,
// don't zero." + "always show the per-input breakdown + 'why'."
//
// Design (disclosed, NOT a black box):
//   1. Each input is robustly z-scored vs its OWN trailing baseline (median+MAD).
//   2. Sign-oriented so positive z = "good for readiness" (HRV↑ good; RHR↑,
//      temp↑, resp↑ bad => negated).
//   3. Weighted sum with disclosed weights HRV > RHR > RR > temp; weights are
//      RENORMALIZED over the inputs actually present (missing inputs are
//      dropped, never zero-imputed).
//   4. The composite z is mapped to a 0..100 score via a logistic so typical
//      days land near 50.
//   5. SWC/TE gate: if |composite z| is below the smallest-worthwhile-change of
//      the dominant input, we report "no meaningful change" (flat) — the
//      credibility signal is the willingness to say nothing.
//   6. ALWAYS attach the per-input contribution breakdown |w_i·z_i| ranked.
//
// HONESTY: glass-box index (weights disclosed); "—" when no inputs present;
// every score carries its drivers; never names a driver below its MDC.

import 'dart:math' as math;
import '../types.dart';
import '../util.dart';

/// One readiness input: its current value + a trailing baseline window + the
/// sign of "good" (+1 if higher is better, -1 if higher is worse) + a weight.
class ReadinessInput {
  final String label;
  final double? value;
  final List<double> baseline; // trailing personal-baseline window
  final int goodSign; // +1 higher-is-better, -1 higher-is-worse
  final double weight; // relative importance (HRV>RHR>RR>temp)
  const ReadinessInput(
    this.label,
    this.value,
    this.baseline,
    this.goodSign,
    this.weight,
  );
}

/// Canonical default inputs (caller supplies values + baselines). Weights encode
/// the disclosed HRV > RHR > RR > temp ordering.
ReadinessInput hrvInput(double? v, List<double> base) =>
    ReadinessInput('HRV', v, base, 1, 0.40);
ReadinessInput rhrInput(double? v, List<double> base) =>
    ReadinessInput('RHR', v, base, -1, 0.30);
ReadinessInput respInput(double? v, List<double> base) =>
    ReadinessInput('RR', v, base, -1, 0.20);
ReadinessInput tempInput(double? v, List<double> base) =>
    ReadinessInput('temp', v, base, -1, 0.10);

class Readiness {
  final double score; // 0..100 glass-box readiness
  final double compositeZ; // weighted, sign-oriented composite z
  final bool meaningful; // passed the SWC gate (else "flat")
  const Readiness(this.score, this.compositeZ, this.meaningful);
  Map<String, dynamic> toJson() => {
        'score': round6(score),
        'composite_z': round6(compositeZ),
        'meaningful': meaningful,
      };
}

/// Compute the honest readiness composite.
///
/// Each present input with a usable robust baseline contributes a sign-oriented
/// robust z. Weights are renormalized over present inputs. [swcMultiplier] sets
/// the smallest-worthwhile-change gate (Hopkins 0.2 of the composite scale,
/// i.e. of unit SD here since z is standardized).
/// Required minimum baseline points (per input) before readiness can compute.
const int readinessCompositeMinBaseline = 3;

Metric<Readiness> readinessComposite(
  List<ReadinessInput> inputs, {
  double swcMultiplier = 0.2,
  int minBaseline = readinessCompositeMinBaseline,
}) {
  final used = <String>[];
  final drivers = <Driver>[];
  var weightSum = 0.0;
  var weightedZ = 0.0;
  // Track the best-covered input that has a value but a too-short baseline, so
  // we can emit a machine-readable need_baseline note when nothing computes.
  var anyValuePresent = false;
  var bestShortHave = -1;
  for (final inp in inputs) {
    final v = inp.value;
    if (v == null) continue;
    anyValuePresent = true;
    final base = inp.baseline;
    if (base.length < minBaseline) {
      if (base.length > bestShortHave) bestShortHave = base.length;
      continue;
    }
    final zr = robustZ(v, base); // null if MAD degenerate
    if (zr == null) continue;
    final oriented = inp.goodSign * zr; // + = good for readiness
    used.add(inp.label);
    weightSum += inp.weight;
    weightedZ += inp.weight * oriented;
    // Driver contribution is the signed weighted z (renormalized later).
    drivers.add(Driver(inp.label, inp.weight * oriented,
        detail: 'oriented robust-z=${round6(oriented)}'));
  }
  if (used.isEmpty || weightSum == 0) {
    // If inputs HAD values but their baselines were too short, say so in the
    // machine-readable need_baseline convention (don't fabricate a score).
    if (anyValuePresent && bestShortHave >= 0) {
      return Metric<Readiness>.absent(
        tier: Tier.estimate,
        inputs_used: const [],
        note: needBaselineNote(have: bestShortHave, need: minBaseline),
      );
    }
    return const Metric<Readiness>.absent(
      tier: Tier.estimate,
      inputs_used: [],
      note: 'no readiness inputs present — "—" (never imputed)',
    );
  }
  // Renormalize weights over present inputs.
  final composite = weightedZ / weightSum;
  // Renormalize driver contributions by the same factor so they sum to the
  // composite z (glass-box: contributions are definitional within the formula).
  final normDrivers = <Driver>[
    for (final d in drivers)
      Driver(d.label, round6(d.contribution / weightSum), detail: d.detail)
  ];
  // Rank by |contribution| (the deterministic-narrative driver ordering).
  normDrivers.sort((a, b) => b.contribution.abs().compareTo(a.contribution.abs()));

  // SWC gate: standardized composite z has unit SD by construction, so the SWC
  // is swcMultiplier (×1). Below it => not a meaningful change ("flat").
  final meaningful = composite.abs() > swcMultiplier;

  // Map composite z -> 0..100 via logistic; ~50 at z=0, scale so ±2 z ~ 12/88.
  final score = 100 / (1 + math.exp(-composite));

  // Confidence scales with how many inputs were available (more = better).
  final conf = clamp(0.3 + 0.15 * used.length, 0.3, 0.9);

  return Metric<Readiness>(
    value: Readiness(score, composite, meaningful),
    confidence: conf,
    tier: Tier.estimate,
    inputs_used: used,
    drivers: normDrivers,
    note: 'GLASS-BOX readiness: disclosed weights HRV>RHR>RR>temp, renormalized '
        'over present inputs; SWC-gated (meaningful=$meaningful). Drivers are '
        'definitional within the formula (correction, not inferred cause).',
  );
}
