// WELLNESS — logged cycle lengths, and the two published criterion numbers
// (WH-08).
//
// Arithmetic on LOGGED ONSET DATES ONLY. No PPG, no temperature, no HRV,
// nothing that can be wrong for sensor reasons. Consecutive-onset differencing
// and one absolute value.
//
// WHAT IT PRODUCES: her own cycle lengths, the difference between each
// consecutive pair, and the two numbers the published criteria use (Harlow
// 2012 / STRAW+10): a persistent 7-day-or-more difference between consecutive
// cycles, and a 60-day-or-longer interval. The screen renders the lengths as a
// bar series with those two lines on it and NO VERDICT TEXT AT ALL.
//
// NAMING. There is no stage vocabulary in this file and there must not be one
// added — not in a string, not in a field, not in a local variable. An
// identifier leaks into logs, into exports and eventually into a sentence on a
// screen, which is precisely how a description of arithmetic turns into a
// diagnosis nobody wrote. Everything here is named after what it computes.
//
// REFUSING ON HOLES IS THE FEATURE. This is entirely hostage to logging
// discipline: one missed start manufactures a single 60-day "cycle" that meets
// a criterion on its own. So an interval longer than [implausibleGapDays] is
// classed UNUSABLE — we cannot tell a long interval from a forgotten log — and
// its presence blocks the whole series rather than being quietly charted.
//
// This never says anyone is anything, never predicts an age, and never
// headlines a label. The card carries a non-dismissible line that cycle change
// has many causes — thyroid, stress, weight change, contraception, PCOS — and
// that this is a prompt to ask a clinician, not an answer.

import '../types.dart';
import '../util.dart';

/// Consecutive-cycle difference used by the published criteria, in days.
const int cycleLengthDifferenceCriterionDays = 7;

/// Long-interval criterion, in days.
const int cycleLongIntervalCriterionDays = 60;

/// Logged onsets required before anything is computed. Roughly a year: the
/// criteria are about PERSISTENT change, and a handful of cycles cannot show
/// persistence.
const int cycleLengthMinCycles = 12;

/// Above this, an interval is more likely a missed log than a cycle.
const int cycleLengthImplausibleGapDays = 90;

class CycleLengthSeries {
  /// Days between consecutive logged onsets, oldest first.
  final List<int> lengthsDays;

  /// |lengths[i+1] − lengths[i]|, one shorter than [lengthsDays].
  final List<int> consecutiveDifferencesDays;

  /// Largest value in [consecutiveDifferencesDays].
  final int maxConsecutiveDifferenceDays;

  /// Largest value in [lengthsDays].
  final int longestIntervalDays;

  const CycleLengthSeries({
    required this.lengthsDays,
    required this.consecutiveDifferencesDays,
    required this.maxConsecutiveDifferenceDays,
    required this.longestIntervalDays,
  });

  Map<String, dynamic> toJson() => {
        'lengths_days': lengthsDays,
        'consecutive_differences_days': consecutiveDifferencesDays,
        'max_consecutive_difference_days': maxConsecutiveDifferenceDays,
        'longest_interval_days': longestIntervalDays,
        'difference_criterion_days': cycleLengthDifferenceCriterionDays,
        'long_interval_criterion_days': cycleLongIntervalCriterionDays,
      };
}

/// Cycle lengths from logged onset day labels (`YYYY-MM-DD`, any order).
///
/// Day labels, differenced as UTC calendar dates so a DST boundary cannot turn
/// a 28-day cycle into 27. Nothing here touches an epoch timestamp.
Metric<CycleLengthSeries> cycleLengthSeries(
  List<String> onsetDates, {
  int minCycles = cycleLengthMinCycles,
  int implausibleGapDays = cycleLengthImplausibleGapDays,
}) {
  const inputs = ['cycle_log_onsets'];
  const caveat = 'Logged dates only — no sensor input. Cycle change has many '
      'causes (thyroid, stress, weight change, contraception, PCOS); this is a '
      'prompt to ask a clinician, not an answer. No verdict, no label, no '
      'prediction.';

  final days = <int>[];
  for (final d in onsetDates) {
    final parsed = DateTime.tryParse('${d}T00:00:00Z');
    if (parsed != null) days.add(parsed.millisecondsSinceEpoch ~/ 86400000);
  }
  days.sort();
  // Same day logged twice is one onset.
  final unique = <int>[];
  for (final d in days) {
    if (unique.isEmpty || unique.last != d) unique.add(d);
  }

  if (unique.length < minCycles + 1) {
    return Metric<CycleLengthSeries>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: '${needBaselineNote(have: unique.length, need: minCycles + 1)} '
          '$caveat',
    );
  }

  final lengths = [
    for (var i = 1; i < unique.length; i++) unique[i] - unique[i - 1]
  ];
  final unusable = lengths.where((l) => l > implausibleGapDays).length;
  if (unusable > 0) {
    // A hole is indistinguishable from a long interval, and a long interval is
    // exactly what one of the criteria is about. Refuse the series rather than
    // chart a manufactured one.
    return Metric<CycleLengthSeries>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'log_has_holes:intervals_over_${implausibleGapDays}d=$unusable — '
          'a missed start and a long interval look identical here. $caveat',
    );
  }

  final diffs = [
    for (var i = 1; i < lengths.length; i++) (lengths[i] - lengths[i - 1]).abs()
  ];
  return Metric<CycleLengthSeries>(
    value: CycleLengthSeries(
      lengthsDays: lengths,
      consecutiveDifferencesDays: diffs,
      maxConsecutiveDifferenceDays: diffs.reduce((a, b) => a > b ? a : b),
      longestIntervalDays: lengths.reduce((a, b) => a > b ? a : b),
    ),
    confidence: clamp(lengths.length / 24.0, 0.3, 0.8),
    tier: Tier.high,
    inputs_used: inputs,
    note: caveat,
  );
}
