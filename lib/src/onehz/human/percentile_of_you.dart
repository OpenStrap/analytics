// HUMAN LAYER — Percentile-of-you, records, and forgiving streaks.
// Catalog §D "Percentile-of-you + records + streaks" [PUB order-statistics].
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

/// Which direction is "better" for a metric (used for record labelling only).
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
Metric<PercentileOfYou> percentileOfYou(
  double value,
  List<double> history, {
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
  final label = _bandLabel(pct);
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

String _bandLabel(double pct) {
  if (pct >= 90) return 'among your best';
  if (pct >= 70) return 'better than usual';
  if (pct > 30) return 'typical for you';
  if (pct > 10) return 'below your usual';
  return 'among your lowest';
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
  final prior =
      better == Better.higher ? history.reduce((a, b) => a > b ? a : b)
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

class Streak {
  final int current; // current run length (days meeting the goal)
  final int best; // longest run in the supplied series
  final int graceUsed; // grace days consumed inside the current run
  final bool alive; // is the current streak still alive at the last day
  const Streak(this.current, this.best, this.graceUsed, this.alive);
  Map<String, dynamic> toJson() => {
        'current': current,
        'best': best,
        'grace_used': graceUsed,
        'alive': alive,
      };
}

/// Forgiving streak over a chronological [met] boolean series (oldest→newest):
/// `met[i]` = did the day meet the goal. A run survives up to [grace] missed
/// days *within* it (Phillips/Windred-style "don't break on one bad night"),
/// but a miss still does not extend the count. Grace resets per run.
///
/// Definition: scanning forward, a run continues across a miss as long as the
/// cumulative misses in the run ≤ [grace]; the (grace+1)-th miss ends the run.
/// `current` counts MET days in the live run; `alive` is whether the run that
/// includes the last day has not yet exceeded its grace.
Streak forgivingStreak(List<bool> met, {int grace = 1}) {
  if (met.isEmpty) return const Streak(0, 0, 0, false);
  var best = 0;
  var runMet = 0; // met days in the current run
  var runMiss = 0; // misses spent in the current run
  var runGrace = 0;
  // Track the run that reaches the end for `current`/`alive`.
  for (var i = 0; i < met.length; i++) {
    if (met[i]) {
      runMet++;
    } else {
      if (runMiss < grace) {
        runMiss++;
        runGrace = runMiss;
      } else {
        // Run breaks; start fresh AFTER this miss.
        best = runMet > best ? runMet : best;
        runMet = 0;
        runMiss = 0;
        runGrace = 0;
      }
    }
  }
  best = runMet > best ? runMet : best;
  // The trailing run defines current/alive: it is alive iff it never exceeded
  // its grace budget (which is always true here — exceeding it starts a new run).
  final alive = runMet > 0;
  return Streak(runMet, best, runGrace, alive);
}
