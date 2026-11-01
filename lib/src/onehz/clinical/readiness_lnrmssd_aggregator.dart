import '../../aggregate/aggregator.dart';
import '../../aggregate/json_support.dart';
import '../../aggregate/primitives.dart';
import '../types.dart';
import 'readiness_lnrmssd.dart';

// Plews et al. 2013, as implemented by readinessLnRmssd(). Retains the history
// count and relevant prior-night suffix, then calls identical scoring
// arithmetic. The aggregator uses positional history; calendar-date filtering
// remains in the batch wrapper.
/// Builds a mergeable lnRMSSD readiness summary over a nightly history column
/// (oldest first, tonight last), matching [readinessLnRmssd] exactly.
///
/// Only the history length and the last [windowDays] + 1 nights matter, so the
/// state is a count and a bounded suffix. [windowDays] must be at least 0.
Aggregator<dynamic, DoubleColumn, Metric<ReadinessLnRmssd>>
    readinessLnRmssdAggregator({
  double? meanNnTodayMs,
  int windowDays = 7,
  int minNights = readinessLnRmssdMinNights,
}) {
  assert(windowDays >= 0);
  const maxLastRows = 1 << 62;
  final keptRows = windowDays >= maxLastRows ? maxLastRows : windowDays + 1;
  final core = both(
    const Count<DoubleColumn>(),
    LastRows<DoubleColumn>(keptRows,
        batchFromJson: DoubleColumn.fromJson),
  );
  return validateCheckpoint(core, (json) {
    final state = decodeList(json);
    if (state.length != 2) throw const FormatException('Expected two states');
    final count = decodeCount(state[0]);
    final rows = field(decodeMap(state[1]), 'rows');
    if (count == 0) {
      if (rows != null) throw const FormatException('Rows without history');
      return;
    }
    if (rows == null || decodeList(rows).length != (count < keptRows ? count : keptRows)) {
      throw const FormatException('History rows disagree with count');
    }
  }).map((result) {
    final n = result.$1;
    if (n < minNights) {
      return Metric<ReadinessLnRmssd>.absent(
        tier: Tier.high,
        inputs_used: const ['ln_rmssd_history'],
        note: needBaselineNote(have: n, need: minNights),
      );
    }
    return readinessLnRmssdFromSuffix(
      n,
      result.$2!.values.toList(),
      meanNnTodayMs: meanNnTodayMs,
      windowDays: windowDays,
      minNights: minNights,
    );
  });
}
