// HUMAN — does one day of the week actually cost you? (MIND-12)
//
// The question is easy to ask and almost impossible to answer honestly. Take
// any 90 days of any daily metric, split by weekday, and one of the seven will
// look worse — that is what seven groups DO. Publishing that day is a machine
// for manufacturing weekday superstitions, and it will do it on pure noise for
// every user, forever.
//
// So the gate is the feature, and it has two stages:
//
//   1. KRUSKAL-WALLIS OMNIBUS across all seven groups. Rank-based, so a couple
//      of wrecked nights do not carry it, and it asks one question — "do these
//      seven groups differ at all?" — instead of seven.
//   2. Only if that clears: a PERMUTATION TEST ON THE MAX DEVIATION. The
//      statistic is the largest |group median − overall median| over the seven,
//      and its null distribution is built by reshuffling the weekday labels. A
//      max over seven groups has a null distribution nothing like a single
//      group's, and permuting is how the 7-way selection gets paid for rather
//      than pocketed.
//
// Both p-values are permutation p-values off the SAME shuffles, so there is one
// loop and no chi-square table.
//
// HONESTY CEILING: purely descriptive and totally confounded. Saturday is not a
// cause, it is a container for everything you do on Saturdays. No advice
// attaches to this, ever, and nothing here licenses telling anyone to change a
// weekend. Under 8 weeks it is absent, not weak.

import 'dart:math' as math;

import '../types.dart';
import '../util.dart';

/// One weekday's slice, and the two-stage verdict over all seven.
class WeekdayEffect {
  /// Observations per weekday, `DateTime.weekday` keys (1 = Mon … 7 = Sun).
  final Map<int, int> nByWeekday;

  /// Median of the outcome per weekday, same keys.
  final Map<int, double> medianByWeekday;

  /// Median over every day, the reference the deviations are measured from.
  final double overallMedian;

  /// Kruskal-Wallis H (tie-corrected). Reported for auditability; the verdict
  /// rides on [omnibusP], not on H.
  final double kruskalH;

  /// Permutation p for the omnibus — stage 1.
  final double omnibusP;

  /// The weekday with the largest |median − [overallMedian]|.
  final int peakWeekday;

  /// That deviation, SIGNED, in the outcome's own units.
  final double peakDelta;

  /// Permutation p for the max deviation — stage 2, the one that pays for
  /// having looked at seven days and picked the worst.
  final double peakP;

  /// Both stages cleared. The ONLY field a screen may gate on.
  final bool meaningful;

  const WeekdayEffect({
    required this.nByWeekday,
    required this.medianByWeekday,
    required this.overallMedian,
    required this.kruskalH,
    required this.omnibusP,
    required this.peakWeekday,
    required this.peakDelta,
    required this.peakP,
    required this.meaningful,
  });

  Map<String, dynamic> toJson() => {
        'n_by_weekday': {
          for (final e in nByWeekday.entries) '${e.key}': e.value
        },
        'median_by_weekday': {
          for (final e in medianByWeekday.entries) '${e.key}': round6(e.value)
        },
        'overall_median': round6(overallMedian),
        'kruskal_h': round6(kruskalH),
        'omnibus_p': round6(omnibusP),
        'peak_weekday': peakWeekday,
        'peak_delta': round6(peakDelta),
        'peak_p': round6(peakP),
        'meaningful': meaningful,
      };
}

/// Kruskal-Wallis H over pre-computed [ranks] split by [group] (0..6).
double _kruskalH(List<double> ranks, List<int> group, int k) {
  final n = ranks.length;
  final sums = List<double>.filled(k, 0);
  final counts = List<int>.filled(k, 0);
  for (var i = 0; i < n; i++) {
    sums[group[i]] += ranks[i];
    counts[group[i]]++;
  }
  var acc = 0.0;
  for (var g = 0; g < k; g++) {
    if (counts[g] == 0) continue;
    acc += sums[g] * sums[g] / counts[g];
  }
  return 12.0 / (n * (n + 1)) * acc - 3.0 * (n + 1);
}

/// Largest |group median − [overall]|, and which group it was.
({double delta, int group}) _maxDeviation(
  List<double> values,
  List<int> group,
  int k,
  double overall,
) {
  final buckets = List<List<double>>.generate(k, (_) => <double>[]);
  for (var i = 0; i < values.length; i++) {
    buckets[group[i]].add(values[i]);
  }
  var best = 0.0;
  var bestG = 0;
  for (var g = 0; g < k; g++) {
    if (buckets[g].isEmpty) continue;
    final d = median(buckets[g])! - overall;
    if (d.abs() > best.abs()) {
      best = d;
      bestG = g;
    }
  }
  return (delta: best, group: bestG);
}

/// Which day of the week costs you — omnibus first, then the max deviation.
///
/// [dates] are `yyyy-MM-dd` LOCAL day labels and [values] is positionally
/// aligned to them; a null value is a day with no measurement and is dropped.
/// The weekday comes off the local label, never off an epoch — mixing the two
/// is how a Sunday night becomes a Monday.
///
/// [minPerWeekday] and [minSpanDays] together are the "≥ 8 weeks" floor. Both
/// are needed: eight weeks of data with three Sundays in it cannot say anything
/// about Sundays, and 56 Mondays in a row is not eight weeks of anything else.
///
/// [permutations] trades runtime for p resolution; the smallest p this can
/// report is 1/(permutations+1), which is the honest floor for a permutation
/// test and not a rounding artefact. [seed] fixes the shuffles so the same
/// history always gives the same answer.
Metric<WeekdayEffect> weekdayEffect(
  List<String> dates,
  List<double?> values, {
  int minPerWeekday = 5,
  int minSpanDays = 56,
  double alpha = 0.05,
  int permutations = 999,
  int seed = 20260817,
}) {
  const inputs = ['metric_series'];
  if (dates.length != values.length) {
    return const Metric<WeekdayEffect>.absent(
      tier: Tier.estimate,
      inputs_used: inputs,
      note: 'misaligned_series',
    );
  }

  final xs = <double>[];
  final group = <int>[]; // 0 = Monday … 6 = Sunday
  final days = <int>[];
  final cal = calendarDays(dates);
  for (var i = 0; i < dates.length; i++) {
    final v = values[i];
    if (v == null || !v.isFinite) continue;
    final d = DateTime.tryParse(dates[i]);
    if (d == null) continue;
    xs.add(v);
    group.add(d.weekday - 1);
    days.add(cal[i]);
  }

  final counts = List<int>.filled(7, 0);
  for (final g in group) {
    counts[g]++;
  }
  final span =
      days.isEmpty ? 0 : days.reduce(math.max) - days.reduce(math.min) + 1;
  final thin = counts.indexWhere((c) => c < minPerWeekday);
  if (span < minSpanDays || thin >= 0) {
    return Metric<WeekdayEffect>.absent(
      tier: Tier.estimate,
      inputs_used: inputs,
      note: 'need_history:span=${span}d/${minSpanDays}d,'
          'min_per_weekday=${counts.reduce(math.min)}/$minPerWeekday',
    );
  }

  final overall = median(xs)!;
  // Ranks are invariant to a label shuffle, so they are computed ONCE and every
  // permutation just re-partitions them.
  final ranks = averageRanks(xs);
  final n = xs.length;

  // Tie correction: a constant divisor, so it cannot move the permutation p —
  // it only makes the reported H comparable to a published one.
  final tieCounts = <double, int>{};
  for (final x in xs) {
    tieCounts[x] = (tieCounts[x] ?? 0) + 1;
  }
  var tieSum = 0.0;
  for (final t in tieCounts.values) {
    tieSum += t * t * t - t;
  }
  final tieDiv = 1.0 - tieSum / (n * n * n - n);
  final hObs = _kruskalH(ranks, group, 7);
  final devObs = _maxDeviation(xs, group, 7, overall);

  final rng = math.Random(seed);
  final shuffled = [...group];
  var hGe = 0, dGe = 0;
  for (var b = 0; b < permutations; b++) {
    shuffled.shuffle(rng);
    if (_kruskalH(ranks, shuffled, 7) >= hObs - 1e-12) hGe++;
    if (_maxDeviation(xs, shuffled, 7, overall).delta.abs() >=
        devObs.delta.abs() - 1e-12) {
      dGe++;
    }
  }
  final omnibusP = (hGe + 1) / (permutations + 1);
  final peakP = (dGe + 1) / (permutations + 1);

  return Metric<WeekdayEffect>(
    value: WeekdayEffect(
      nByWeekday: {for (var g = 0; g < 7; g++) g + 1: counts[g]},
      medianByWeekday: {
        for (var g = 0; g < 7; g++)
          g + 1: median([
            for (var i = 0; i < n; i++)
              if (group[i] == g) xs[i]
          ])!
      },
      overallMedian: overall,
      kruskalH: tieDiv > 0 ? hObs / tieDiv : hObs,
      omnibusP: omnibusP,
      peakWeekday: devObs.group + 1,
      peakDelta: devObs.delta,
      peakP: peakP,
      // BOTH stages. Either alone is a weekday superstition with a p-value
      // stapled to it.
      meaningful: omnibusP <= alpha && peakP <= alpha,
    ),
    confidence: clamp(0.25 + 0.25 * (span / 365.0), 0.25, 0.5),
    tier: Tier.estimate,
    inputs_used: inputs,
    note: 'descriptive weekday split, Kruskal-Wallis omnibus then a '
        'permutation test on the max deviation. a weekday is a container for '
        'what you do on it, never a cause — no advice attaches to this.',
  );
}
