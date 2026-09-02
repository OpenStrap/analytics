// WELLNESS — honest glass-box readiness composite.
//
// ★ CANONICAL recovery/readiness (ARCHITECTURE_V2 `recovery.score`). ★
// Per the "one source per concept" invariant there is exactly ONE headline
// readiness, and this is it: disclosed weights (HRV>RHR>RR>temp) + ranked
// drivers + personal-baseline robust z-scores (median+MAD `robustZ`). The
// SWC/TE "no meaningful change" flag is GONE — it was computed and serialized
// for months with no reader, so a flat night rendered exactly like a real one
// while the code claimed otherwise. If a surface wants to say "flat", add the
// gate back WITH the surface. The other readiness
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
//   5. ALWAYS attach the per-input contribution breakdown |w_i·z_i| ranked.
//
// HONESTY: glass-box index (weights disclosed); "—" when no inputs present;
// every score carries its drivers; never names a driver below its MDC.

import 'dart:math' as math;
import '../foundations/baseline.dart' show dispersionBelowQuantum;
import '../types.dart';
import '../util.dart';
import 'temp_circadian.dart' show kMinSettledFraction;

/// One readiness input: its current value + a trailing baseline window + the
/// sign of "good" (+1 if higher is better, -1 if higher is worse) + a weight.
class ReadinessInput {
  final String label;
  final double? value;
  final List<double> baseline; // trailing personal-baseline window
  final int goodSign; // +1 higher-is-better, -1 higher-is-worse
  final double weight; // relative importance (HRV>RHR>RR>temp)

  /// Set when a value WAS measured but this input refuses to let readiness use
  /// it tonight (see [tempInput]). [value] is null in that case, so the input
  /// drops out and the weights renormalise — but the reason is named in the
  /// composite's note instead of vanishing.
  final String? refusal;

  /// The input's own QUANTIZATION STEP, in the units of [value]/[baseline]
  /// (whole-bpm RHR → 1, integer skin-temp ADC → 1). 0 = continuous, no step.
  ///
  /// Read only on the MAD-collapse fallback path: a baseline whose dispersion
  /// is below one step has no resolvable dispersion at all, so an SD computed
  /// from it is quantization noise, not physiology. See the guard in
  /// [readinessComposite].
  final double quantum;
  const ReadinessInput(
    this.label,
    this.value,
    this.baseline,
    this.goodSign,
    this.weight, {
    this.refusal,
    this.quantum = 0,
  });
}

/// Canonical default inputs (caller supplies values + baselines). Weights encode
/// the disclosed HRV > RHR > RR > temp ordering.
ReadinessInput hrvInput(double? v, List<double> base) =>
    ReadinessInput('HRV', v, base, 1, 0.40);
ReadinessInput rhrInput(double? v, List<double> base) =>
    ReadinessInput('RHR', v, base, -1, 0.30, quantum: 1); // whole bpm
ReadinessInput respInput(double? v, List<double> base) =>
    ReadinessInput('RR', v, base, -1, 0.20);

/// The skin-temp driver — GATED ON SETTLEDNESS, and the gate has no safe
/// default.
///
/// The channel stays; what is gated is readiness's USE of it. A nightly mean
/// taken over a window the strap spent partly warming up (or off the body) is
/// displaced downwards, and `goodSign = -1` reads downwards as GOOD: on the one
/// real gen4 night carrying a two-hour cold segment the ungated input pushed
/// readiness UP by 7.6 points on the shipped baseline (and by ~26 against the
/// clean-night baseline the audit measured against). A cold strap must not read
/// as a recovered person.
///
/// [settledFraction] is `nightlySkinTemp`'s scalar for this night. NULL means
/// "nobody measured it", which is not the same as "it was fine" — the input is
/// refused, exactly as it is when the fraction is below [minSettledFraction],
/// and the composite renormalises over the drivers that are present. Pass the
/// fraction to get the driver back.
///
/// The ORIENTATION is inherited, not endorsed: Kräuchi's distal-proximal
/// gradient work says nocturnal distal skin temperature BELOW baseline is
/// vasoconstriction, not recovery, and `glassBoxReadiness` already disagrees
/// with this file by using |z|. Deciding the sign is a separate, deliberate
/// change (RD-05); this one only stops a sensor artifact from paying out.
ReadinessInput tempInput(
  double? v,
  List<double> base, {
  double? settledFraction,
  double minSettledFraction = kMinSettledFraction,
}) {
  if (v == null) return ReadinessInput('temp', null, base, -1, 0.10);
  if (settledFraction == null) {
    return ReadinessInput('temp', null, base, -1, 0.10,
        refusal: 'temp: no settled fraction measured for this night — an '
            'ungated nightly mean cannot tell skin from a warming strap');
  }
  if (settledFraction < minSettledFraction) {
    return ReadinessInput('temp', null, base, -1, 0.10,
        refusal: 'temp: unsettled_skin_temp:settled='
            '${round6(settledFraction)},need=${round6(minSettledFraction)}');
  }
  return ReadinessInput('temp', v, base, -1, 0.10, quantum: 1); // 1 ADC count
}

class Readiness {
  final double score; // 0..100 glass-box readiness
  final double compositeZ; // weighted, sign-oriented composite z
  const Readiness(this.score, this.compositeZ);
  Map<String, dynamic> toJson() => {
        'score': round6(score),
        'composite_z': round6(compositeZ),
      };
}

/// Compute the honest readiness composite.
///
/// Each present input with a usable robust baseline contributes a sign-oriented
/// robust z. Weights are renormalized over present inputs.
/// Required minimum baseline points (per input) before readiness can compute.
///
/// 14, not 3. Three nights are not a personal baseline, they are three numbers:
/// on the real corpus `[58, 58, 59]` bpm of RHR plus a 52 bpm night produced
/// z = −10.97 and a published score of **99.949** at confidence 0.60 — maximal
/// recovery manufactured out of a 6 bpm change. Two weeks is the shortest
/// window in which a median+MAD has anything to be robust ABOUT (it is also the
/// floor `overreaching_conjunction` and `session_cost` already use).
///
/// Deliberately NOT paired with an abs(z) clamp: a bounded-but-wrong score
/// published at confidence 0.60 is harder to catch than an absurd one.
const int readinessCompositeMinBaseline = 14;

/// Minimum number of inputs, and minimum surviving weight, before a composite
/// is a composite at all.
///
/// Renormalising over present inputs is the frozen catalog's own rule
/// ("Reweight on missing inputs, don't zero") and stays. What it must not do is
/// hand the WHOLE 0..100 score to one input: with only `temp` present, its
/// disclosed 0.10 becomes an effective 1.0 and a single sensor artifact IS the
/// headline. Reachable — each input needs its own ≥3-night baseline and the four
/// series fill at different rates. On the real gen4 corpus two of seventeen days
/// scored off exactly one input (readiness 44.7 and 0.8); both now read "—".
const int readinessCompositeMinInputs = 2;
const double readinessCompositeMinWeight = 0.5;

Metric<Readiness> readinessComposite(
  List<ReadinessInput> inputs, {
  int minBaseline = readinessCompositeMinBaseline,
  int minInputs = readinessCompositeMinInputs,
  double minWeightSum = readinessCompositeMinWeight,
}) {
  final used = <String>[];
  final drivers = <Driver>[];
  final refusals = <String>[
    for (final inp in inputs)
      if (inp.refusal != null) inp.refusal!
  ];
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
    // Robust z (median + MAD) first. But a QUANTIZED input (whole-bpm RHR,
    // integer skin-temp ADC) can cluster tight enough on some nights that MAD
    // collapses to 0 — robustZ then returns null and, if that was the only
    // present input, the WHOLE score intermittently blanked to "—" (present some
    // nights, absent others, even with sleep detected). Fall back to an ordinary
    // mean/SD z so a usable input still contributes; only skip when SD is ALSO
    // zero (a truly constant baseline with no dispersion to normalize against).
    final rz = robustZ(v, base);
    // Checked for EVERY quantized input, not only when robustZ came back null.
    // `robustZ` can still return a score on a baseline whose SD sits below the
    // quantum — a 14-night whole-bpm baseline alternating 58/59 has MAD 0.5
    // (nonzero, so robustZ succeeds) but SD ~0.52, which is exactly the
    // unresolvable-dispersion case this guard exists to catch. Gating it on
    // `rz == null` let that baseline's z through unrefused.
    if (inp.quantum > 0) {
      // MAD collapsed, so more than half this baseline sits exactly on its own
      // median. For a QUANTIZED input that is the signature of a baseline with
      // no resolvable dispersion — and the mean/SD fallback below then divides
      // by what is left, which is quantization noise: `[58,58,59]` has SD 0.577
      // bpm, so a 6 bpm night scores z = −10.97 and readiness 99.949. Refuse
      // the input by name (weights renormalise over the rest, and if too few
      // survive the composite comes back absent) rather than scale against a
      // dispersion the instrument cannot resolve.
      //
      // NOT a synthetic floor and NOT a clamp: nothing is substituted for the
      // missing dispersion. Scoped to the fallback on purpose — MAD > 0 on a
      // quantized series already means ≥ 1 step of spread.
      if (dispersionBelowQuantum(base, inp.quantum)) {
        final sd = stddev(base);
        refusals.add('${inp.label}: baseline_dispersion_below_quantum:'
            'sd=${sd == null ? 'null' : round6(sd)},'
            'quantum=${round6(inp.quantum)},n=${base.length}');
        continue;
      }
    }
    final zr = rz ?? z(v, base);
    if (zr == null) continue;
    final oriented = inp.goodSign * zr; // + = good for readiness
    used.add(inp.label);
    weightSum += inp.weight;
    weightedZ += inp.weight * oriented;
    // Driver contribution is the signed weighted z (renormalized later).
    // GLASS-BOX: the disclosed method must be the method ACTUALLY used — on a
    // quantized baseline the MAD collapses and the mean/SD fallback above
    // produced this z, so saying "robust-z" there would misstate how the
    // contribution was computed.
    final method = rz != null
        ? 'robust-z (median+MAD)'
        : 'z (mean+SD fallback — MAD=0 on a quantized baseline)';
    drivers.add(Driver(inp.label, inp.weight * oriented,
        detail: 'oriented $method=${round6(oriented)}'));
  }
  final suffix = refusals.isEmpty ? '' : ' Refused: ${refusals.join('; ')}.';
  if (used.length < minInputs || weightSum < minWeightSum) {
    // If inputs HAD values but their baselines were too short, say so in the
    // machine-readable need_baseline convention (don't fabricate a score).
    if (used.isEmpty && anyValuePresent && bestShortHave >= 0) {
      return Metric<Readiness>.absent(
        tier: Tier.estimate,
        inputs_used: const [],
        note: needBaselineNote(have: bestShortHave, need: minBaseline) + suffix,
      );
    }
    if (used.isEmpty) {
      return Metric<Readiness>.absent(
        tier: Tier.estimate,
        inputs_used: const [],
        note: 'no readiness inputs present — "—" (never imputed).$suffix',
      );
    }
    // Present but too thin to be a COMPOSITE. Renormalising here would promote
    // one disclosed weight to 1.0; see [readinessCompositeMinInputs].
    return Metric<Readiness>.absent(
      tier: Tier.estimate,
      inputs_used: used,
      note: 'need_inputs:have=${used.length},need=$minInputs,'
          'weight=${round6(weightSum)},need_weight=${round6(minWeightSum)} — '
          'renormalising this few would hand the whole score to one input.'
          '$suffix',
    );
  }
  // Renormalize weights over present inputs.
  final composite = weightedZ / weightSum;
  // Renormalize driver contributions by the same factor so they sum to the
  // composite z (glass-box: contributions are definitional within the formula).
  final normDrivers = <Driver>[
    for (final d in drivers)
      Driver(d.label, roundTo(d.contribution / weightSum, 6), detail: d.detail)
  ];
  // Rank by |contribution| (the deterministic-narrative driver ordering).
  normDrivers
      .sort((a, b) => b.contribution.abs().compareTo(a.contribution.abs()));

  // Map composite z -> 0..100 via logistic; ~50 at z=0, scale so ±2 z ~ 12/88.
  final score = 100 / (1 + math.exp(-composite));

  // Confidence scales with how many inputs were available (more = better).
  final conf = (0.3 + 0.15 * used.length).clamp(0.3, 0.9);

  return Metric<Readiness>(
    value: Readiness(score, composite),
    confidence: conf,
    tier: Tier.estimate,
    inputs_used: used,
    drivers: normDrivers,
    note:
        'GLASS-BOX readiness: disclosed weights HRV>RHR>RR>temp, renormalized '
        'over present inputs. Drivers are definitional within the formula '
        '(correction, not inferred cause).$suffix',
  );
}
