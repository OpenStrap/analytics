// HUMAN LAYER — Percentile-of-you.
// Catalog §D "Percentile-of-you + records" [PUB order-statistics]. Neither the
// streak nor the records half of that catalog line is implemented: there are no
// streaks in this product and no personal-record surface reads one, so an
// unused detector would only be one more thing a baseline change has to keep
// green.
//
// n-of-1 only: a value's rank is computed against the SAME USER's recent
// history (a robust empirical CDF), never a population leaderboard.
//
// HONESTY: within-user percentiles (catalog honesty rule), no validity
// exposure, "—" when history is too short.

import '../types.dart';
import '../util.dart';

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
  final conf = (history.length / 60.0).clamp(0.3, 0.95);
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
