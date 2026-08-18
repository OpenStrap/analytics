// HUMAN LAYER — Percentile-of-you and records.
// Catalog §D "Percentile-of-you + records" [PUB order-statistics]. The streak
// half of that catalog line is deliberately NOT implemented: no streaks in this
// product, so there is nothing here to wire one up from.
//
// n-of-1 only: a value's rank is computed against the SAME USER's recent
// history (a robust empirical CDF), never a population leaderboard. Records are
// MDC-gated: a new high/low is only a "record" when it beats the prior extreme
// by more than the metric's minimal detectable change — otherwise it is noise.
//
// HONESTY: within-user percentiles (catalog honesty rule), no validity
// exposure, MDC-gated records, "—" when history is too short.

import '../types.dart';
import '../util.dart';
import '../foundations/baseline.dart';

/// Which direction is "better" for a metric. Required by every function here
/// that puts a WORD on a number: a rank is direction-free, a label is not.
enum Better { higher, lower, neither }

class PercentileOfYou {
  final double value;
  final double percentile; // 0..100, rank of `value` within personal history
  final int n; // history size used (excludes the value itself unless asked)
  final String label; // coarse, within-user band (never population)
  const PercentileOfYou(this.value, this.percentile, this.n, this.label);
  Map<String, dynamic> toJson() => {
        'value': round6(value),
        'percentile_of_you': round6(percentile),
        'n': n,
        'label': label,
      };
}

/// Empirical-CDF percentile of [value] within personal [history] (the user's
/// own prior observations of this metric). Uses the midrank ("mean rank")
/// definition so ties map to a stable centre rank.
///
/// [history] should NOT include [value]. Needs ≥[minN] prior points, else absent.
///
/// [better] says which end of the scale is the good end, and the [label] is
/// derived from it — there is no default. Without it the ladder hard-coded
/// "high percentile = good", so resting HR (where high is bad) printed the
/// user's WORST-ever night as "among your best" and their best-ever night as
/// "among your lowest". [Better.neither] gets direction-only wording ("among
/// your highest") rather than a verdict.
Metric<PercentileOfYou> percentileOfYou(
  double value,
  List<double> history, {
  required Better better,
  int minN = 14,
}) {
  const inputs = ['metric_history'];
  if (history.length < minN) {
    return const Metric<PercentileOfYou>.absent(
      tier: Tier.relative,
      inputs_used: inputs,
      note: 'need more of your own history for a percentile-of-you',
    );
  }
  var below = 0, equal = 0;
  for (final h in history) {
    if (h < value) {
      below++;
    } else if (h == value) {
      equal++;
    }
  }
  // Midrank empirical CDF: below + half the ties, over n.
  final pct = 100.0 * (below + 0.5 * equal) / history.length;
  final label = _bandLabel(pct, better);
  // Confidence grows with history depth (more of your own data => sturdier CDF).
  final conf = clamp(history.length / 60.0, 0.3, 0.95);
  return Metric<PercentileOfYou>(
    value: PercentileOfYou(value, pct, history.length, label),
    confidence: conf,
    tier: Tier.relative,
    inputs_used: inputs,
    note: 'within-user percentile (your own history), not a population rank',
  );
}

String _bandLabel(double pct, Better better) {
  if (better == Better.neither) {
    // No good end of the scale: describe the position, don't judge it.
    if (pct >= 90) return 'among your highest';
    if (pct >= 70) return 'higher than usual';
    if (pct > 30) return 'typical for you';
    if (pct > 10) return 'lower than usual';
    return 'among your lowest';
  }
  // Rank on the GOODNESS axis: for a lower-is-better metric the 100th
  // percentile is the worst night the user has had, not the best.
  final good = better == Better.higher ? pct : 100.0 - pct;
  if (good >= 90) return 'among your best';
  if (good >= 70) return 'better than usual';
  if (good > 30) return 'typical for you';
  if (good > 10) return 'worse than usual';
  return 'among your worst';
}

class RecordCheck {
  final bool isRecord; // beat the prior extreme by > MDC
  final String kind; // 'high' | 'low' | 'none'
  final double value;
  final double? priorExtreme;
  final double? margin; // |value - priorExtreme|
  final double? mdc; // gate threshold used
  const RecordCheck({
    required this.isRecord,
    required this.kind,
    required this.value,
    required this.priorExtreme,
    required this.margin,
    required this.mdc,
  });
  Map<String, dynamic> toJson() => {
        'is_record': isRecord,
        'kind': kind,
        'value': round6(value),
        if (priorExtreme != null) 'prior_extreme': round6(priorExtreme!),
        if (margin != null) 'margin': round6(margin!),
        if (mdc != null) 'mdc': round6(mdc!),
      };
}

/// Is [value] a personal record vs [history], gated by MDC?
///
/// A record requires the value to beat the prior extreme (max for [Better.higher],
/// min for [Better.lower]) by MORE than the metric's minimal detectable change,
/// so regression-to-mean noise never gets celebrated. When no MDC can be
/// established (degenerate/quantized scale) we refuse to call a record.
Metric<RecordCheck> personalRecord(
  double value,
  List<double> history, {
  required Better better,
  double? typicalError,
  int minN = 14,
}) {
  const inputs = ['metric_history'];
  if (history.length < minN || better == Better.neither) {
    return const Metric<RecordCheck>.absent(
      tier: Tier.relative,
      inputs_used: inputs,
      note: 'records need history and a defined "better" direction',
    );
  }
  final baseline = robustBaseline(history, minValid: minN);
  final gate = mdc(baseline, typicalError: typicalError);
  if (gate == null) {
    return const Metric<RecordCheck>.absent(
      tier: Tier.relative,
      inputs_used: inputs,
      note: 'no MDC (degenerate scale) — refusing to claim a record',
    );
  }
  final prior = better == Better.higher
      ? history.reduce((a, b) => a > b ? a : b)
      : history.reduce((a, b) => a < b ? a : b);
  final beats = better == Better.higher ? value - prior : prior - value;
  final isRecord = beats > gate;
  final kind = isRecord ? (better == Better.higher ? 'high' : 'low') : 'none';
  return Metric<RecordCheck>(
    value: RecordCheck(
      isRecord: isRecord,
      kind: kind,
      value: value,
      priorExtreme: prior,
      margin: beats,
      mdc: gate,
    ),
    confidence: clamp(history.length / 60.0, 0.3, 0.9),
    tier: Tier.relative,
    inputs_used: inputs,
    note: 'record only if it beats your prior extreme by > MDC',
  );
}
