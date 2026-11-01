import 'dart:math' as math;
import 'dart:typed_data';

import '../../aggregate/aggregator.dart';
import '../../aggregate/json_support.dart';
import '../../aggregate/primitives.dart';
import '../incremental_core.dart';
import 'hrv_jitter_evidence.dart';
import 'hrv_time.dart';

const double _fiveMinutesMs = 300000.0;

/// NN intervals and their beat times. A missing time is represented by NaN.
class Beats extends Batch<Beats> {
  Beats(this.nnMs, this.timeMs) : assert(nnMs.length == timeMs.length);

  factory Beats.fromJson(Object? json) {
    final map = decodeMap(json);
    final nn = decodeDoubles(field(map, 'nnMs'));
    final times = decodeDoubles(field(map, 'timeMs'));
    if (nn.length != times.length) {
      throw const FormatException('Beats columns differ in length');
    }
    return Beats(nn, times);
  }

  final Float64List nnMs;
  final Float64List timeMs;

  @override
  Object? toJson() =>
      {'nnMs': encodeDoubles(nnMs), 'timeMs': encodeDoubles(timeMs)};

  @override
  int get length => nnMs.length;

  @override
  Beats copyRange(int start, int end) => Beats(
      Float64List(end - start)..setRange(0, end - start, nnMs, start),
      Float64List(end - start)..setRange(0, end - start, timeMs, start));

  @override
  Beats join(Beats other) {
    final nn = Float64List(length + other.length);
    final times = Float64List(length + other.length);
    nn
      ..setRange(0, length, nnMs)
      ..setRange(length, nn.length, other.nnMs);
    times
      ..setRange(0, length, timeMs)
      ..setRange(length, times.length, other.timeMs);
    return Beats(nn, times);
  }
}

/// Builds the composed time-domain HRV summary for a columnar beat batch.
///
/// With [gapAware] false, times and five-minute bins are deliberately ignored.
// The jitter rejection/exemption thresholds are an internal rule, ESTIMATE
// with low confidence; Welch 1967 and Hirsch & Bishop 1981 support spectral
// and respiratory components only. See rmssd_gate.dart.
// Task Force 1996 time-domain HRV, now also the hrvTime() one-slice path.
// Moments, two-beat differences, three-beat lag products and five-minute bins
// retain the same sufficient statistics. gapAware:false omits timestamp-
// dependent bins and gap tests. Floating-point order can change rounding and
// jitter-threshold decisions. Checked field tolerances are 1e-9 absolute plus
// 1e-9 relative; near-constant differences and jitter gates have the
// qualifications in test/aggregate/hrv_time_aggregator_test.dart.
Aggregator<dynamic, Beats, HrvTime> hrvTimeAggregator({
  double? originMs,
  bool gapAware = true,
}) {
  final core = _numericCore(originMs: originMs, gapAware: gapAware);
  // Streaming finish uses the evidence already collected and merged by fold.
  final evidence = JitterEvidenceAggregator(originMs: originMs, gapAware: gapAware);
  final combined = validateCheckpoint(both(core, evidence),
      (json) => _validateVersioned(json, gapAware));
  final checked = gapAware ? _FiniteTimes(combined) : combined;
  return checked.map((result) => _finish(
      result.$1.$1, result.$1.$2, result.$1.$3, result.$1.$4,
      () => result.$2, gapAware: gapAware));
}

/// Runs the same numeric core over one slice, building jitter evidence only
/// when the ACF floor requires it. This helper is not exported by the public libraries.
HrvTime hrvTimeOneSlice(Beats beats, {
  double? originMs,
  bool gapAware = true,
}) {
  final core = _numericCore(originMs: originMs, gapAware: gapAware);
  final result = (gapAware ? _FiniteTimes(core) : core).run(beats);
  JitterEvidence? cached;
  JitterEvidence evidence() => cached ??= JitterEvidenceAggregator(
      originMs: originMs, gapAware: gapAware).run(beats);
  return _finish(result.$1, result.$2, result.$3, result.$4, evidence,
      gapAware: gapAware);
}

typedef _CoreSummary = (
  _DiffSummary, _LagSummary, RunningMoments, Map<int, RunningMoments>
);

// Mapping only the finished summaries leaves both the accumulation order and
// checkpoint state shape unchanged, including the gap-unaware branch.
Aggregator<dynamic, Beats, _CoreSummary> _numericCore({
  double? originMs,
  required bool gapAware,
}) {
  final diffs = both(
    Lookback<Beats, _DiffState, _DiffSummary>(
        2, _DiffStats(gapAware: gapAware),
        batchFromJson: Beats.fromJson),
    Lookback<Beats, _LagState, _LagSummary>(
        3, _LagStats(gapAware: gapAware),
        batchFromJson: Beats.fromJson),
  );
  final levels = Moments<Beats>((batch) => batch.nnMs);
  if (!gapAware) {
    return both(diffs, levels).map((result) => (
        result.$1.$1, result.$1.$2, result.$2,
        const <int, RunningMoments>{}));
  }

  final bins = GroupBy<Beats, RunningMoments, RunningMoments>(
    (batch, row) {
      final origin = originMs;
      if (origin == null) throw StateError('gap-aware HRV needs originMs');
      return ((_timeAt(batch, row) - origin) / _fiveMinutesMs).floor();
    },
    Moments<Beats>((batch) => batch.nnMs),
  );
  return both(diffs, both(levels, bins)).map((result) => (
      result.$1.$1, result.$1.$2, result.$2.$1, result.$2.$2));
}

/// Refuses a slice holding a non-finite beat time before any state changes
/// (a fold cannot be undone), as the other night streams do. Gap-aware only:
/// without gap awareness times are never read.
class _FiniteTimes<S, R> extends Aggregator<S, Beats, R> {
  const _FiniteTimes(this.inner);
  final Aggregator<S, Beats, R> inner;

  @override
  S empty() => inner.empty();

  @override
  S addSlice(S state, Beats batch, int start, int end) {
    for (var i = start; i < end; i++) {
      if (!batch.timeMs[i].isFinite) {
        throw ArgumentError('beat times must be finite');
      }
    }
    return inner.addSlice(state, batch, start, end);
  }

  @override
  S combine(S left, S right) => inner.combine(left, right);

  @override
  R finish(S state) => inner.finish(state);

  @override
  bool get persistable => inner.persistable;

  @override
  Object? encodeState(S state) => inner.encodeState(state);

  @override
  S decodeState(Object? json) => inner.decodeState(json);
}

/// Version 2: `[core, evidence]`, the evidence counting what the core counts.
void _validateVersioned(Object? json, bool gapAware) {
  final state = decodeList(json);
  if (state.length != 2) throw const FormatException('Expected core and evidence');
  _validateCheckpoint(state[0], gapAware);
  final core = decodeList(state[0]);
  final evidence = decodeMap(state[1]);
  final diffs = decodeMap(field(decodeMap(decodeList(core[0])[0]), 'inner'));
  final rawLevels = gapAware ? decodeList(core[1])[0] : core[1];
  if (decodeCount(field(evidence, 'n')) !=
          decodeCount(field(decodeMap(rawLevels), 'count')) ||
      decodeCount(field(evidence, 'nd')) != decodeCount(field(diffs, 'pairs'))) {
    throw const FormatException('Evidence disagrees with the core');
  }
}

void _validateCheckpoint(Object? json, bool gapAware) {
  final state = decodeList(json);
  if (state.length != 2) throw const FormatException('Expected two states');
  final lookbacks = decodeList(state[0]);
  if (lookbacks.length != 2) throw const FormatException('Expected two lookbacks');
  final diffs = decodeMap(lookbacks[0]);
  final lags = decodeMap(lookbacks[1]);
  final beats = decodeCount(field(diffs, 'length'));
  if (decodeCount(field(lags, 'length')) != beats) {
    throw const FormatException('Lookback lengths disagree');
  }
  final diffPairs = decodeCount(field(decodeMap(field(diffs, 'inner')), 'pairs'));
  final lagPairs = decodeCount(field(decodeMap(field(lags, 'inner')), 'pairs'));
  final diffLimit = beats > 0 ? beats - 1 : 0;
  final lagLimit = beats > 1 ? beats - 2 : 0;
  if (diffPairs > diffLimit || lagPairs > lagLimit) {
    throw const FormatException('Pair count exceeds beat windows');
  }

  final Object? rawLevels;
  Map<String, Object?>? bins;
  if (gapAware) {
    final levelAndBins = decodeList(state[1]);
    if (levelAndBins.length != 2) {
      throw const FormatException('Expected levels and bins');
    }
    rawLevels = levelAndBins[0];
    bins = decodeMap(levelAndBins[1]);
  } else {
    rawLevels = state[1];
  }
  final levels = decodeCount(field(decodeMap(rawLevels), 'count'));
  if (levels > beats) {
    throw const FormatException('Level count exceeds beat count');
  }
  if (bins == null) return;
  var binned = 0;
  for (final bin in bins.values) {
    final count = decodeCount(field(decodeMap(bin), 'count'));
    if (binned > levels - count) {
      throw const FormatException('Bin counts exceed level count');
    }
    binned += count;
  }
  if (binned != levels) {
    throw const FormatException('Bin counts disagree with level count');
  }
}

double _timeAt(Beats batch, int row) {
  final time = batch.timeMs[row];
  return time.isNaN ? 0.0 : time;
}

bool _contiguous(Beats batch, int previous, int current, bool gapAware) =>
    !gapAware ||
    _timeAt(batch, current) - _timeAt(batch, previous) <=
        batch.nnMs[current] + 0.5;

class _DiffSummary {
  const _DiffSummary(
      this.pairs, this.over50, this.mean, this.m2, this.squares);
  final int pairs;
  final int over50;
  final double mean;
  final double m2;
  final double squares;
}

class _DiffState {
  int pairs = 0;
  int over50 = 0;
  double mean = 0.0;
  double m2 = 0.0;
  double squares = 0.0;

  @pragma('vm:prefer-inline')
  void add(double value) {
    final nextPairs = pairs + 1;
    final delta = value - mean;
    mean += delta / nextPairs;
    m2 += delta * (value - mean);
    pairs = nextPairs;
  }

  @pragma('vm:prefer-inline')
  void merge(_DiffState other) {
    if (other.pairs == 0) return;
    if (pairs == 0) {
      pairs = other.pairs;
      over50 = other.over50;
      mean = other.mean;
      m2 = other.m2;
      squares = other.squares;
      return;
    }
    final leftPairs = pairs;
    final combinedPairs = leftPairs + other.pairs;
    final delta = other.mean - mean;
    m2 += other.m2 + delta * delta * leftPairs * other.pairs / combinedPairs;
    mean += delta * other.pairs / combinedPairs;
    pairs = combinedPairs;
    over50 += other.over50;
    squares += other.squares;
  }
}

/// Processes every two-row window supplied by [Lookback].
class _DiffStats extends Aggregator<_DiffState, Beats, _DiffSummary> {
  const _DiffStats({required this.gapAware});
  final bool gapAware;

  @override
  _DiffState empty() => _DiffState();

  @override
  _DiffState addSlice(_DiffState state, Beats batch, int start, int end) {
    for (var i = start + 1; i < end; i++) {
      if (!_contiguous(batch, i - 1, i, gapAware)) continue;
      final diff = batch.nnMs[i] - batch.nnMs[i - 1];
      state.add(diff);
      state.squares += diff * diff;
      if (diff.abs() > 50) state.over50++;
    }
    return state;
  }

  @override
  _DiffState combine(_DiffState left, _DiffState right) {
    left.merge(right);
    return left;
  }

  @override
  bool get persistable => true;

  @override
  Object? encodeState(_DiffState state) => {
        'pairs': state.pairs,
        'over50': state.over50,
        'mean': encodeDouble(state.mean),
        'm2': encodeDouble(state.m2),
        'squares': encodeDouble(state.squares),
      };

  @override
  _DiffState decodeState(Object? json) {
    final map = decodeMap(json);
    final pairs = decodeCount(field(map, 'pairs'));
    final over50 = decodeCount(field(map, 'over50'));
    if (over50 > pairs) throw const FormatException('over50 exceeds pairs');
    return _DiffState()
      ..pairs = pairs
      ..over50 = over50
      ..mean = decodeDouble(field(map, 'mean'))
      ..m2 = decodeDouble(field(map, 'm2'))
      ..squares = decodeDouble(field(map, 'squares'));
  }

  @override
  _DiffSummary finish(_DiffState state) =>
      _DiffSummary(
          state.pairs, state.over50, state.mean, state.m2, state.squares);
}

class _LagSummary {
  const _LagSummary(this.pairs, this.meanA, this.meanB, this.coMoment);
  final int pairs;
  final double meanA;
  final double meanB;
  final double coMoment;
}

class _LagState {
  int pairs = 0;
  double meanA = 0.0;
  double meanB = 0.0;
  double coMoment = 0.0;

  @pragma('vm:prefer-inline')
  void add(double a, double b) {
    final nextPairs = pairs + 1;
    final deltaA = a - meanA;
    final deltaB = b - meanB;
    meanA += deltaA / nextPairs;
    meanB += deltaB / nextPairs;
    coMoment += deltaA * (b - meanB);
    pairs = nextPairs;
  }

  @pragma('vm:prefer-inline')
  void merge(_LagState other) {
    if (other.pairs == 0) return;
    if (pairs == 0) {
      pairs = other.pairs;
      meanA = other.meanA;
      meanB = other.meanB;
      coMoment = other.coMoment;
      return;
    }
    final leftPairs = pairs;
    final combinedPairs = leftPairs + other.pairs;
    final deltaA = other.meanA - meanA;
    final deltaB = other.meanB - meanB;
    coMoment += other.coMoment +
        deltaA * deltaB * leftPairs * other.pairs / combinedPairs;
    meanA += deltaA * other.pairs / combinedPairs;
    meanB += deltaB * other.pairs / combinedPairs;
    pairs = combinedPairs;
  }
}

/// Processes every three-row window supplied by [Lookback].
class _LagStats extends Aggregator<_LagState, Beats, _LagSummary> {
  const _LagStats({required this.gapAware});
  final bool gapAware;

  @override
  _LagState empty() => _LagState();

  @override
  _LagState addSlice(_LagState state, Beats batch, int start, int end) {
    for (var i = start + 2; i < end; i++) {
      if (!_contiguous(batch, i - 2, i - 1, gapAware) ||
          !_contiguous(batch, i - 1, i, gapAware)) {
        continue;
      }
      final first = batch.nnMs[i - 1] - batch.nnMs[i - 2];
      final second = batch.nnMs[i] - batch.nnMs[i - 1];
      state.add(first, second);
    }
    return state;
  }

  @override
  _LagState combine(_LagState left, _LagState right) {
    left.merge(right);
    return left;
  }

  @override
  bool get persistable => true;

  @override
  Object? encodeState(_LagState state) => {
        'pairs': state.pairs,
        'meanA': encodeDouble(state.meanA),
        'meanB': encodeDouble(state.meanB),
        'coMoment': encodeDouble(state.coMoment),
      };

  @override
  _LagState decodeState(Object? json) {
    final map = decodeMap(json);
    return _LagState()
      ..pairs = decodeCount(field(map, 'pairs'))
      ..meanA = decodeDouble(field(map, 'meanA'))
      ..meanB = decodeDouble(field(map, 'meanB'))
      ..coMoment = decodeDouble(field(map, 'coMoment'));
  }

  @override
  _LagSummary finish(_LagState state) =>
      _LagSummary(state.pairs, state.meanA, state.meanB, state.coMoment);
}

HrvTime _finish(_DiffSummary diffs, _LagSummary lags, RunningMoments levels,
    Map<int, RunningMoments> bins, JitterEvidence Function() evidence,
    {required bool gapAware}) {
  if (levels.count < 2) return HrvTime(nBeats: levels.count);

  double? acf1;
  if (diffs.pairs >= 30) {
    if (diffs.m2 > 0) {
      acf1 = (lags.coMoment +
              lags.pairs *
                  (lags.meanA - diffs.mean) *
                  (lags.meanB - diffs.mean)) /
          diffs.m2;
    }
  }
  // Under the floor hrvTime refuses only when the runs show no respiratory
  // line on a low floor, and then a timed night may still publish RMSSD from
  // the windows on a breathing line steady in Hz: both read from [evidence].
  final jittery =
      acf1 != null && acf1 < kNnDiffAcf1Floor && evidence().refused();
  final breathing = jittery && gapAware ? evidence().breathingRmssd() : null;

  double? sdann;
  double? sdnnIndex;
  if (gapAware) {
    final binMeans = RunningMoments();
    var binSdSum = 0.0;
    var binCount = 0;
    for (final bin in bins.values) {
      if (bin.count < 2) continue;
      binMeans.add(bin.mean!);
      binSdSum += bin.sampleSd!;
      binCount++;
    }
    if (binCount >= 2) {
      sdann = binMeans.sampleSd;
      sdnnIndex = binSdSum / binCount;
    }
  }

  return HrvTime(
    nBeats: levels.count,
    rmssd: diffs.pairs > 0 && !jittery
        ? math.sqrt(diffs.squares / diffs.pairs)
        : breathing,
    pnn50: diffs.pairs > 0 && !jittery
        ? 100.0 * diffs.over50 / diffs.pairs
        : null,
    sdnn: levels.sampleSd,
    sdann: sdann,
    sdnnIndex: sdnnIndex,
    diffAcf1: acf1,
  );
}
