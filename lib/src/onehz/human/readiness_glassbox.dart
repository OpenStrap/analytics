// HUMAN LAYER — Glass-box GlassBoxReadiness 0–100 + deterministic narrative.
//
// ⚠ DEPRECATED / INTERNAL — NOT the headline readiness. ⚠
// ARCHITECTURE_V2 mandates ONE readiness ("one source per concept";
// "DROP: the duplicate readiness composite"). The CANONICAL readiness/recovery
// is `readinessComposite` in wellness/readiness_composite.dart (personal-baseline
// robust z-scores + disclosed weights + drivers + SWC gate — the catalog's
// stated criterion). This percentile-of-you variant is retained only for
// back-compat and its deterministic-narrative helper; do NOT present it as the
// headline `recovery`. Kept exported so existing callers/tests don't break.
//
// Catalog §D: Glass-box GlassBoxReadiness [PUB HRV centrality; HEUR weighting] and
// deterministic narrative driver-attribution [HEUR, standard decomposition].
//
// EVERY input is a within-user percentile-of-you (0..100), sign-oriented so
// "higher = better-for-you", then combined as a WEIGHTED MEAN with the catalog
// priority HRV > RHR > RR > temp. The per-input breakdown is ALWAYS present —
// the score is glass-box by construction.
//
// The narrative is NOT an LLM and NOT an inferred cause. Each driver's
// contribution is the STANDARDIZED deviation w_i·z_i, where z_i is the input's
// deviation from its own 50th percentile (in percentile points) — definitional
// within the formula we control. Drivers are ranked by |w_i·z_i|; a driver is
// only NAMED when its underlying change clears its MDC. "Why" is therefore
// exactly "this input moved the score by this much", never a claim about the
// world.

import '../types.dart';
import '../util.dart';
import '../foundations/baseline.dart';

/// One readiness input the caller supplies.
class GlassBoxInput {
  final String label; // 'hrv' | 'rhr' | 'resp' | 'temp' | custom
  final double value; // tonight's value (raw unit)
  final List<double> history; // personal history of this input (excl. tonight)
  final double weight; // relative weight (HRV>RHR>RR>temp)
  /// If true, a LOWER value is better-for-you (e.g. RHR, resp, temp deviation).
  final bool lowerIsBetter;
  const GlassBoxInput({
    required this.label,
    required this.value,
    required this.history,
    required this.weight,
    this.lowerIsBetter = false,
  });
}

class ReadinessBreakdownItem {
  final String label;

  /// 0..100, sign-ORIENTED (higher=better-for-you). NULL when the input had too
  /// little of the user's own history to rank against — absence, never a
  /// fabricated rank and never NaN (see [note] for the machine-readable reason).
  final double? percentileOfYou;
  final double weight;
  final double weightedContribution; // w·(pct-50), signed — narrative driver
  final bool pastMdc; // did the underlying change clear its MDC?
  final bool used; // was the input present + usable
  /// Machine-readable reason this input was not used, e.g.
  /// `need_baseline:have=2,need=7`. Null when the input WAS used.
  final String? note;
  const ReadinessBreakdownItem({
    required this.label,
    required this.percentileOfYou,
    required this.weight,
    required this.weightedContribution,
    required this.pastMdc,
    required this.used,
    this.note,
  });
  Map<String, dynamic> toJson() => {
        'label': label,
        'percentile_of_you':
            percentileOfYou == null ? null : round6(percentileOfYou!),
        'weight': round6(weight),
        'weighted_contribution': round6(weightedContribution),
        'past_mdc': pastMdc,
        'used': used,
        if (note != null) 'note': note,
      };
}

class GlassBoxReadiness {
  final double score; // 0..100
  final List<ReadinessBreakdownItem> breakdown; // ALWAYS present
  final List<Driver> drivers; // ranked by |w·z|, only NAMED past MDC
  final String narrative; // deterministic, definitional "why"
  final int inputsUsed;
  const GlassBoxReadiness(this.score, this.breakdown, this.drivers, this.narrative,
      this.inputsUsed);
  Map<String, dynamic> toJson() => {
        'score': round6(score),
        'breakdown': [for (final b in breakdown) b.toJson()],
        'drivers': [for (final d in drivers) d.toJson()],
        'narrative': narrative,
        'inputs_used': inputsUsed,
      };
}

/// Compute glass-box readiness.
///
/// Each input is mapped to its within-user percentile (empirical CDF on its own
/// history), oriented so higher=better-for-you. Score = weighted mean of those
/// percentiles over the inputs that have enough history (weights RENORMALIZED
/// over present inputs — we reweight on missing inputs, never zero-fill).
///
/// Drivers: contribution_i = weight_i · (orientedPct_i − 50). Ranked by
/// magnitude; a driver is NAMED in the narrative only if its raw change cleared
/// its MDC (robust baseline gate). The breakdown lists ALL inputs regardless.
@Deprecated(
  'DUPLICATE readiness — use readinessComposite (wellness/readiness_composite.dart) '
  'as the canonical/headline recovery. glassBoxReadiness is retained ONLY for its '
  'percentile-of-you breakdown + deterministic narrative and for back-compat with '
  'existing edge callers (crossday_pipeline "readiness_glassbox"); do NOT surface '
  'it as the headline score.',
)
Metric<GlassBoxReadiness> glassBoxReadiness(
  List<GlassBoxInput> inputs, {
  int minHistory = 7,
}) {
  const used = ['readiness_inputs'];
  final items = <ReadinessBreakdownItem>[];
  var wsum = 0.0;
  var wpsum = 0.0; // Σ w·orientedPct over usable inputs
  var nUsable = 0;

  // First pass: percentile + MDC gate per input.
  final raw = <_RawItem>[];
  for (final inp in inputs) {
    if (inp.history.length < minHistory) {
      items.add(ReadinessBreakdownItem(
        label: inp.label,
        percentileOfYou: null, // no rank yet — absent, not NaN, not 50
        weight: inp.weight,
        weightedContribution: 0,
        pastMdc: false,
        used: false,
        note: 'need_baseline:have=${inp.history.length},need=$minHistory',
      ));
      continue;
    }
    // Empirical-CDF percentile (midrank) of tonight within personal history.
    var below = 0, equal = 0;
    for (final h in inp.history) {
      if (h < inp.value) {
        below++;
      } else if (h == inp.value) {
        equal++;
      }
    }
    var pct = 100.0 * (below + 0.5 * equal) / inp.history.length;
    // Orient: higher should mean better-for-you.
    final oriented = inp.lowerIsBetter ? 100.0 - pct : pct;
    // MDC gate on the RAW change vs robust baseline.
    final base = robustBaseline(inp.history, minValid: minHistory);
    final m = mdc(base);
    final delta = (base.center == null) ? 0.0 : (inp.value - base.center!);
    final pastMdc = m != null && delta.abs() > m;

    final contribution = inp.weight * (oriented - 50.0);
    items.add(ReadinessBreakdownItem(
      label: inp.label,
      percentileOfYou: oriented,
      weight: inp.weight,
      weightedContribution: contribution,
      pastMdc: pastMdc,
      used: true,
    ));
    raw.add(_RawItem(inp.label, contribution, pastMdc));
    wsum += inp.weight;
    wpsum += inp.weight * oriented;
    nUsable++;
  }

  if (nUsable == 0 || wsum == 0) {
    var have = 0;
    for (final inp in inputs) {
      if (inp.history.length > have) have = inp.history.length;
    }
    return Metric<GlassBoxReadiness>.absent(
      tier: Tier.estimate,
      inputs_used: used,
      note: 'need_baseline:have=$have,need=$minHistory',
    );
  }

  final score = clamp(wpsum / wsum, 0, 100);

  // Drivers ranked by |contribution|; only NAME a driver past its MDC.
  final ranked = [...raw]..sort((a, b) => b.c.abs().compareTo(a.c.abs()));
  final drivers = <Driver>[];
  for (final r in ranked) {
    if (!r.pastMdc) continue; // never name a sub-MDC mover
    drivers.add(Driver(
      r.label,
      r.c,
      detail: r.c >= 0 ? 'lifting your score' : 'dragging your score down',
    ));
  }

  final narrative = _buildNarrative(score, drivers);

  // Confidence reflects how many of the priority inputs were usable.
  final conf = clamp(nUsable / inputs.length.toDouble(), 0.3, 0.9);
  return Metric<GlassBoxReadiness>(
    value: GlassBoxReadiness(score, items, drivers, narrative, nUsable),
    confidence: conf,
    tier: Tier.estimate,
    inputs_used: used,
    drivers: drivers,
    note: 'glass-box: weighted personal-percentile inputs (HRV>RHR>RR>temp); '
        'drivers are definitional within the formula, not inferred causes',
  );
}

class _RawItem {
  final String label;
  final double c; // weighted contribution
  final bool pastMdc;
  const _RawItem(this.label, this.c, this.pastMdc);
}

String _buildNarrative(double score, List<Driver> drivers) {
  final band = score >= 70
      ? 'You\'re ready'
      : score >= 40
          ? 'A moderate day'
          : 'Take it easier today';
  if (drivers.isEmpty) {
    return '$band — nothing moved beyond your normal day-to-day noise.';
  }
  final top = drivers.first;
  final dir = top.contribution >= 0 ? 'up' : 'down';
  final word = _humanLabel(top.label);
  return '$band — mainly because your $word is $dir vs your usual.';
}

String _humanLabel(String l) {
  switch (l) {
    case 'hrv':
      return 'HRV';
    case 'rhr':
      return 'resting heart rate';
    case 'resp':
      return 'breathing rate';
    case 'temp':
      return 'skin temperature';
    default:
      return l;
  }
}

/// Catalog-priority default weights (HRV > RHR > RR > temp). Helper for callers.
const double wHrv = 0.40;
const double wRhr = 0.30;
const double wResp = 0.18;
const double wTemp = 0.12;
