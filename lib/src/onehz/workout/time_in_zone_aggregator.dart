import 'dart:math' as math;
import 'dart:typed_data';

import '../../aggregate/aggregator.dart';
import '../../aggregate/json_support.dart';
import '../../aggregate/primitives.dart';
import '../util.dart';
import 'hr_zones.dart';

/// Time-ordered heart-rate samples held in timestamp and heart-rate columns.
class HrStream extends Batch<HrStream> {
  HrStream(this.tsMs, this.hr) : assert(tsMs.length == hr.length);

  factory HrStream.fromJson(Object? json) {
    final map = decodeMap(json);
    final timestamps = decodeDoubles(field(map, 'tsMs'));
    final heartRates = decodeDoubles(field(map, 'hr'));
    if (timestamps.length != heartRates.length) {
      throw const FormatException('HrStream columns differ in length');
    }
    return HrStream(timestamps, heartRates);
  }

  final Float64List tsMs;
  final Float64List hr;

  @override
  Object? toJson() =>
      {'tsMs': encodeDoubles(tsMs), 'hr': encodeDoubles(hr)};

  @override
  int get length => tsMs.length;

  @override
  HrStream copyRange(int start, int end) => HrStream(
        Float64List(end - start)..setRange(0, end - start, tsMs, start),
        Float64List(end - start)..setRange(0, end - start, hr, start),
      );

  @override
  HrStream join(HrStream other) {
    final timestamps = Float64List(length + other.length);
    final heartRates = Float64List(length + other.length);
    timestamps
      ..setRange(0, length, tsMs)
      ..setRange(length, timestamps.length, other.tsMs);
    heartRates
      ..setRange(0, length, hr)
      ..setRange(length, heartRates.length, other.hr);
    return HrStream(timestamps, heartRates);
  }
}

/// Builds a mergeable time-in-heart-rate-zone summary over [HrStream].
///
/// It has the same cadence validation and duration crediting as
/// [HeartRateZones.timeInZone]. The exact gap histograms let it defer the
/// global cadence median until [Aggregator.finish].
// Cadence validation, median-capped interval credit and tail credit are an
// internal rule, ESTIMATE with low confidence. Karvonen 1957 supports the
// HR-reserve zone option, not this duration-credit policy.
// Histogram reformulation of HeartRateZones.timeInZone(), now its one-slice
// path. Exact cadence-gap counts and zone-credit gaps retain the same global
// median, cadence validation and duration-credit rule. Grouped sums change
// rounding; checked tolerances are 1e-12 relative and 1e-9 absolute.
Aggregator<dynamic, HrStream, TimeInHeartRateZone?> timeInZoneAggregator(
  HeartRateZoneSet zoneSet,
) =>
    _TimeInZoneAggregator(zoneSet);

/// Number of distinct histogram values retained by a time-in-zone state.
///
/// This accepts [Object] so callers can inspect an empty state without knowing
/// the private state type used by the aggregator.
int timeInZoneStateEntries(Object? state) {
  if (state is! _TimeInZoneState) return 0;
  return state.histograms().entryCount;
}

class _TimeInZoneAggregator
    extends Aggregator<_TimeInZoneState, HrStream, TimeInHeartRateZone?> {
  _TimeInZoneAggregator(this.zoneSet)
      : _windows = Lookback<HrStream, _ZoneHistograms, _ZoneHistograms>(
            2, _PairHistograms(zoneSet),
            batchFromJson: HrStream.fromJson);

  final HeartRateZoneSet zoneSet;
  final Lookback<HrStream, _ZoneHistograms, _ZoneHistograms> _windows;

  @override
  _TimeInZoneState empty() =>
      _TimeInZoneState(_windows.empty(), (windows) => _windows.finish(windows));

  @override
  _TimeInZoneState addSlice(
      _TimeInZoneState state, HrStream batch, int start, int end) {
    state.windows = _windows.addSlice(state.windows, batch, start, end);
    if (start < end) {
      state.hasTail = true;
      state.tailTimestampMs = batch.tsMs[end - 1];
      state.tailHr = batch.hr[end - 1];
    }
    return state;
  }

  @override
  _TimeInZoneState combine(
      _TimeInZoneState left, _TimeInZoneState right) {
    left.windows = _windows.combine(left.windows, right.windows);
    if (right.hasTail) {
      left.hasTail = true;
      left.tailTimestampMs = right.tailTimestampMs;
      left.tailHr = right.tailHr;
    }
    return left;
  }

  @override
  bool get persistable => _windows.persistable;

  @override
  Object? encodeState(_TimeInZoneState state) => {
        'windows': _windows.encodeState(state.windows),
        'hasTail': state.hasTail,
        'tailTimestampMs': encodeDouble(state.tailTimestampMs),
        'tailHr': encodeDouble(state.tailHr),
      };

  @override
  _TimeInZoneState decodeState(Object? json) {
    final map = decodeMap(json);
    final windows = decodeMap(field(map, 'windows'));
    final length = decodeCount(field(windows, 'length'));
    final hasTail = field(map, 'hasTail');
    if (hasTail is! bool) throw const FormatException('Expected a bool');
    final result = empty()
      ..windows = _windows.decodeState(windows)
      ..hasTail = hasTail
      ..tailTimestampMs = decodeDouble(field(map, 'tailTimestampMs'))
      ..tailHr = decodeDouble(field(map, 'tailHr'));
    if (hasTail != (length > 0)) {
      throw const FormatException('Invalid tail');
    }
    _validateHistogramCounts(result.histograms(), length);
    return result;
  }

  @override
  TimeInHeartRateZone? finish(_TimeInZoneState state) {
    final histograms = state.histograms();
    final cadence = _cadence(histograms.cadence);
    if (cadence == null) return null;

    final seconds = List<double>.filled(5, 0.0);
    var belowZone1 = 0.0;
    for (var zone = 0; zone < histograms.credits.length; zone++) {
      var total = 0.0;
      for (final entry in histograms.credits[zone].entries) {
        final gap = entry.key;
        final credited = gap > 0 ? math.min(gap, cadence) : cadence;
        total += entry.value * credited;
      }
      if (zone == 0) {
        belowZone1 += total;
      } else {
        seconds[zone - 1] += total;
      }
    }
    if (state.hasTail && state.tailHr > 0) {
      final zone = zoneSet.zoneNumber(state.tailHr);
      if (zone == 0) {
        belowZone1 += cadence;
      } else {
        seconds[zone - 1] += cadence;
      }
    }
    return TimeInHeartRateZone(seconds: seconds, belowZone1: belowZone1);
  }
}

class _TimeInZoneState {
  _TimeInZoneState(this.windows, this._finishWindows);

  dynamic windows;
  final _ZoneHistograms Function(dynamic) _finishWindows;
  bool hasTail = false;
  double tailTimestampMs = 0.0;
  double tailHr = 0.0;

  _ZoneHistograms histograms() => _finishWindows(windows);
}

/// Processes every complete two-row window supplied by [Lookback].
class _PairHistograms
    extends Aggregator<_ZoneHistograms, HrStream, _ZoneHistograms> {
  const _PairHistograms(this.zoneSet);

  final HeartRateZoneSet zoneSet;

  @override
  _ZoneHistograms empty() => _ZoneHistograms();

  @override
  _ZoneHistograms addSlice(
      _ZoneHistograms state, HrStream batch, int start, int end) {
    for (var i = start + 1; i < end; i++) {
      final previous = i - 1;
      final cadenceGap = batch.tsMs[i] / 1000.0 -
          batch.tsMs[previous] / 1000.0;
      if (cadenceGap > 0) state.addCadence(cadenceGap);

      final previousHr = batch.hr[previous];
      if (previousHr > 0) {
        final creditGap =
            (batch.tsMs[i] - batch.tsMs[previous]) / 1000.0;
        state.addCredit(zoneSet.zoneNumber(previousHr), creditGap);
      }
    }
    return state;
  }

  @override
  _ZoneHistograms combine(_ZoneHistograms left, _ZoneHistograms right) {
    left.merge(right);
    return left;
  }

  @override
  _ZoneHistograms finish(_ZoneHistograms state) => state;

  @override
  bool get persistable => true;

  @override
  Object? encodeState(_ZoneHistograms state) => {
        'cadence': _encodeHistogram(state.cadence),
        'credits': [
          for (final histogram in state.credits) _encodeHistogram(histogram)
        ],
      };

  @override
  _ZoneHistograms decodeState(Object? json) {
    final map = decodeMap(json);
    final state = _ZoneHistograms();
    _decodeHistogram(field(map, 'cadence'), state.cadence,
        requirePositive: true);
    final credits = decodeList(field(map, 'credits'));
    if (credits.length != state.credits.length) {
      throw const FormatException('Expected six credit histograms');
    }
    for (var zone = 0; zone < credits.length; zone++) {
      _decodeHistogram(credits[zone], state.credits[zone]);
    }
    return state;
  }
}

class _ZoneHistograms {
  final Map<double, int> cadence = <double, int>{};
  final List<Map<double, int>> credits =
      List<Map<double, int>>.generate(6, (_) => <double, int>{});

  int get entryCount => cadence.length +
      credits.fold<int>(0, (count, histogram) => count + histogram.length);

  void addCadence(double gap) => _increment(cadence, gap);

  void addCredit(int zone, double gap) => _increment(credits[zone], gap);

  void merge(_ZoneHistograms other) {
    _merge(cadence, other.cadence);
    for (var zone = 0; zone < credits.length; zone++) {
      _merge(credits[zone], other.credits[zone]);
    }
  }
}

/// A double-keyed histogram as `[[gap, count], ...]`; keys stay lossless.
List<Object> _encodeHistogram(Map<double, int> histogram) => [
      for (final entry in histogram.entries)
        [encodeDouble(entry.key), entry.value]
    ];

void _decodeHistogram(Object? json, Map<double, int> into,
    {bool requirePositive = false}) {
  for (final item in decodeList(json)) {
    final pair = decodeList(item);
    if (pair.length != 2) throw const FormatException('Expected [gap, count]');
    final gap = decodeDouble(pair[0]);
    if (!gap.isFinite || (requirePositive && gap <= 0)) {
      throw const FormatException('Invalid histogram gap');
    }
    final count = decodeCount(pair[1]);
    if (count == 0 || into.containsKey(gap)) {
      throw const FormatException('Invalid histogram entry');
    }
    into[gap] = count;
  }
}

void _validateHistogramCounts(_ZoneHistograms histograms, int length) {
  final pairCount = length == 0 ? 0 : length - 1;
  _validateHistogramCount(histograms.cadence.values, pairCount);
  var credits = 0;
  for (final histogram in histograms.credits) {
    for (final count in histogram.values) {
      if (count > pairCount - credits) {
        throw const FormatException('Too many credit histogram entries');
      }
      credits += count;
    }
  }
}

void _validateHistogramCount(Iterable<int> counts, int maximum) {
  var total = 0;
  for (final count in counts) {
    if (count > maximum - total) {
      throw const FormatException('Too many cadence histogram entries');
    }
    total += count;
  }
}

void _increment(Map<double, int> histogram, double value) {
  histogram[value] = (histogram[value] ?? 0) + 1;
}

void _merge(Map<double, int> left, Map<double, int> right) {
  for (final entry in right.entries) {
    left[entry.key] = (left[entry.key] ?? 0) + entry.value;
  }
}

double? _cadence(Map<double, int> histogram) {
  var gapCount = 0;
  for (final count in histogram.values) {
    gapCount += count;
  }
  final median = _median(histogram, gapCount);
  if (median == null || median > maxSupportedCadenceSec) return null;

  var inMode = 0;
  for (final entry in histogram.entries) {
    final gap = entry.key;
    if (gap <= median * 2.0 && gap * 2.0 >= median) {
      inMode += entry.value;
    }
  }
  return inMode < gapCount * 0.5 ? null : median;
}

/// Equivalent to `percentileSorted(expandedHistogram, 50)` without expansion.
double? _median(Map<double, int> histogram, int count) {
  if (count == 0) return null;
  final sorted = histogram.keys.toList()..sort();
  if (count == 1) return sorted.single;
  final rank = (50 / 100) * (count - 1);
  final lo = rank.floor();
  final hi = rank.ceil();
  final loValue = _valueAt(sorted, histogram, lo);
  if (lo == hi) return loValue;
  final hiValue = _valueAt(sorted, histogram, hi);
  final fraction = rank - lo;
  return loValue + (hiValue - loValue) * fraction;
}

double _valueAt(List<double> sorted, Map<double, int> histogram, int index) {
  var remaining = index;
  for (final value in sorted) {
    final count = histogram[value]!;
    if (remaining < count) return value;
    remaining -= count;
  }
  throw StateError('histogram index out of range');
}
