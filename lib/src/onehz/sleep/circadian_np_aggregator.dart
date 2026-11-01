import 'dart:typed_data';

import '../../aggregate/aggregator.dart';
import '../../aggregate/json_support.dart';
import '../../aggregate/primitives.dart';
import '../types.dart';
import 'circadian_np.dart';
import 'circadian_window.dart';

/// Epoch-binned activity (or HR) values.
///
/// [firstIndex] is the absolute index of row zero, so the epoch of day of a
/// row survives slicing and joining.
class EpochSeries extends Batch<EpochSeries> {
  EpochSeries(this.x, {this.firstIndex = 0});

  factory EpochSeries.fromJson(Object? json) {
    final map = decodeMap(json);
    return EpochSeries(decodeDoubles(field(map, 'x')),
        firstIndex: decodeCount(field(map, 'firstIndex')));
  }

  final Float64List x;
  final int firstIndex;

  @override
  Object? toJson() => {'x': encodeDoubles(x), 'firstIndex': firstIndex};

  @override
  int get length => x.length;

  @override
  EpochSeries copyRange(int start, int end) => EpochSeries(
      Float64List(end - start)..setRange(0, end - start, x, start),
      firstIndex: firstIndex + start);

  @override
  EpochSeries join(EpochSeries other) {
    assert(other.firstIndex == firstIndex + length);
    return EpochSeries(
        Float64List(length + other.length)
          ..setRange(0, length, x)
          ..setRange(length, length + other.length, other.x),
        firstIndex: firstIndex);
  }
}

/// Sum of squared successive differences. Run under `Lookback(2)`, which
/// feeds the pair across each chunk seam.
class _SquaredDiffs extends Aggregator<double, EpochSeries, double> {
  const _SquaredDiffs();
  @override
  double empty() => 0.0;
  @override
  double addSlice(double state, EpochSeries batch, int start, int end) {
    for (var i = start + 1; i < end; i++) {
      final d = batch.x[i] - batch.x[i - 1];
      state += d * d;
    }
    return state;
  }

  @override
  double combine(double left, double right) => left + right;
  @override
  double finish(double state) => state;
  @override
  bool get persistable => true;
  @override
  Object? encodeState(double state) => encodeDouble(state);
  @override
  double decodeState(Object? json) => decodeDouble(json);
}

/// A direct, non-skipping sum. Circadian's reference calculation deliberately
/// lets NaN and infinities propagate through every sum they touch.
class _RawSum extends Aggregator<double, EpochSeries, double> {
  const _RawSum(this.column);

  final Float64List Function(EpochSeries batch) column;

  @override
  double empty() => 0.0;

  @override
  double addSlice(double state, EpochSeries batch, int start, int end) {
    final values = column(batch);
    for (var i = start; i < end; i++) {
      state += values[i];
    }
    return state;
  }

  @override
  double combine(double left, double right) => left + right;

  @override
  double finish(double state) => state;

  @override
  bool get persistable => true;

  // This retains the Sum checkpoint shape, so pre-existing finite checkpoints
  // remain readable.
  @override
  Object? encodeState(double state) =>
      {'sum': encodeDouble(state), 'correction': 0.0};

  @override
  double decodeState(Object? json) {
    final map = decodeMap(json);
    return decodeDouble(field(map, 'sum')) +
        decodeDouble(field(map, 'correction'));
  }
}

class _CircadianStats {
  int count = 0;
  double sum = 0.0;
  double mean = 0.0;
  double m2 = 0.0;
}

/// Raw total plus mergeable centred squares for circadian variance.
///
/// The raw total reproduces the reference grand mean. Centred squares retain
/// the finite-input stability of the former Moments block, while an individual
/// non-finite row immediately poisons them just as the reference's second
/// pass does.
class _CircadianStatsAggregator
    extends Aggregator<_CircadianStats, EpochSeries, _CircadianStats> {
  const _CircadianStatsAggregator(this.column);

  final Float64List Function(EpochSeries batch) column;

  @override
  _CircadianStats empty() => _CircadianStats();

  @override
  _CircadianStats addSlice(
      _CircadianStats state, EpochSeries batch, int start, int end) {
    final values = column(batch);
    for (var i = start; i < end; i++) {
      final value = values[i];
      state.sum += value;
      state.count++;
      if (!value.isFinite) {
        // The reference later evaluates (value - grand) squared for this row.
        // Whatever grand is, this makes ssTot non-finite (and usually NaN).
        state.m2 = double.nan;
        state.mean = state.sum / state.count;
        continue;
      }
      final delta = value - state.mean;
      state.mean += delta / state.count;
      state.m2 += delta * (value - state.mean);
    }
    return state;
  }

  @override
  _CircadianStats combine(_CircadianStats left, _CircadianStats right) {
    if (right.count == 0) return left;
    if (left.count == 0) {
      left
        ..count = right.count
        ..sum = right.sum
        ..mean = right.mean
        ..m2 = right.m2;
      return left;
    }
    final leftCount = left.count;
    final count = leftCount + right.count;
    final delta = right.mean - left.mean;
    left
      ..sum += right.sum
      ..mean += delta * right.count / count
      ..m2 += right.m2 + delta * delta * leftCount * right.count / count
      ..count = count;
    return left;
  }

  @override
  _CircadianStats finish(_CircadianStats state) => state;

  @override
  bool get persistable => true;

  @override
  Object? encodeState(_CircadianStats state) => {
        'version': 1,
        'type': 'CircadianStats',
        'count': state.count,
        'sum': encodeDouble(state.sum),
        'mean': encodeDouble(state.mean),
        'm2': encodeDouble(state.m2),
      };

  @override
  _CircadianStats decodeState(Object? json) {
    final map = decodeMap(json);
    final type = field(map, 'type');
    if (field(map, 'version') != 1 || type is! String) {
      throw const FormatException('Unsupported circadian statistics checkpoint');
    }
    final result = _CircadianStats()..count = decodeCount(field(map, 'count'));
    if (type == 'CircadianStats') {
      result
        ..sum = decodeDouble(field(map, 'sum'))
        ..mean = decodeDouble(field(map, 'mean'))
        ..m2 = decodeDouble(field(map, 'm2'));
      if ((result.m2.isFinite && result.m2 < 0) ||
          (result.count == 0 &&
              (result.sum != 0 || result.mean != 0 || result.m2 != 0))) {
        throw const FormatException('Invalid circadian statistics');
      }
      return result;
    }
    if (type != 'RunningMoments') {
      throw const FormatException('Unsupported circadian statistics checkpoint');
    }
    // Older checkpoints used RunningMoments. Their finite mean is sufficient
    // to resume, even though it did not preserve the reference's raw sum.
    final origin = decodeDouble(field(map, 'origin'));
    final meanOffset = decodeDouble(field(map, 'meanOffset'));
    result
      ..mean = origin + meanOffset
      ..sum = result.mean * result.count
      ..m2 = decodeDouble(field(map, 'm2'));
    if (!origin.isFinite ||
        !meanOffset.isFinite ||
        (result.m2.isFinite && result.m2 < 0) ||
        (result.count == 0 &&
            (origin != 0 || meanOffset != 0 || result.m2 != 0))) {
      throw const FormatException('Invalid circadian statistics');
    }
    return result;
  }
}

/// Mergeable nonparametric circadian metrics, matching
/// [circadianNonparametric].
// Witting 1990 / van Someren 1999 nonparametric circadian indices, now also the
// circadianNonparametric() one-slice path. Phase sums/counts, centered variance
// and successive squared differences reproduce the formulas. Checked relative
// tolerances are 1e-12 for integer fixtures and 1e-9 for real fixtures; real-
// valued near-ties can select different L5/M10 start epochs.
Aggregator<dynamic, EpochSeries, Metric<CircadianNp>> circadianNpAggregator(
  int epochsPerDay, {
  int? m10Epochs,
  int? l5Epochs,
}) {
  const inputs = ['activity_or_hr_epochs'];
  const tooShort = Metric<CircadianNp>.absent(
    tier: Tier.high,
    inputs_used: inputs,
    note: 'need ≥1 full day of epochs for circadian metrics',
  );
  if (epochsPerDay <= 0) {
    return Count<EpochSeries>().map((_) => tooShort);
  }
  final p = epochsPerDay;
  final mEp = m10Epochs ?? (p * 10 ~/ 24);
  final lEp = l5Epochs ?? (p * 5 ~/ 24);
  Float64List column(EpochSeries b) => b.x;
  final core = both(
    both(Count<EpochSeries>(), _CircadianStatsAggregator(column)),
    both(
      GroupBy(
        (EpochSeries batch, int row) => (batch.firstIndex + row) % p,
        both(Count<EpochSeries>(), _RawSum(column)),
      ),
      Lookback<EpochSeries, double, double>(2, const _SquaredDiffs(),
          batchFromJson: EpochSeries.fromJson),
    ),
  );
  return validateCheckpoint(core, (json) {
    final state = decodeList(json);
    if (state.length != 2) throw const FormatException('Expected two states');
    final totals = decodeList(state[0]);
    final grouped = decodeList(state[1]);
    if (totals.length != 2 || grouped.length != 2) {
      throw const FormatException('Unexpected circadian checkpoint state');
    }
    final count = decodeCount(totals[0]);
    final statistics = decodeMap(totals[1]);
    if (decodeCount(field(statistics, 'count')) != count) {
      throw const FormatException('Circadian statistics disagree with total');
    }
    final groups = decodeMap(grouped[0]);
    final lookback = decodeMap(grouped[1]);
    if (decodeCount(field(lookback, 'length')) != count) {
      throw const FormatException('Lookback length disagrees with epoch count');
    }
    final first = field(lookback, 'first');
    if (count == 0) {
      if (first != null || groups.isNotEmpty) {
        throw const FormatException('Circadian groups without epochs');
      }
      return;
    }
    if (first == null) throw const FormatException('Missing first circadian epoch');
    final firstEpoch = EpochSeries.fromJson(first);
    if (firstEpoch.length != 1) {
      throw const FormatException('Expected one first circadian epoch');
    }
    final start = firstEpoch.firstIndex % p;
    final expectedGroups = count < p ? count : p;
    if (groups.length != expectedGroups) {
      throw const FormatException('Unexpected epoch-of-day groups');
    }
    final fullDays = count ~/ p;
    final remainder = count % p;
    var groupTotal = 0;
    for (final entry in groups.entries) {
      final bin = int.tryParse(entry.key);
      if (bin == null || bin < 0 || bin >= p) {
        throw const FormatException('Epoch-of-day group is outside the record');
      }
      final offset = (bin - start + p) % p;
      final expected = fullDays + (offset < remainder ? 1 : 0);
      final groupState = decodeList(entry.value);
      if (groupState.length != 2 ||
          decodeCount(groupState[0]) != expected ||
          expected == 0 ||
          groupTotal > count - expected) {
        throw const FormatException('Epoch-of-day group count disagrees');
      }
      groupTotal += expected;
    }
    if (groupTotal != count) {
      throw const FormatException('Epoch-of-day groups disagree with total');
    }
  }).map((result) {
    final ((n, stats), (byEpoch, ssDiff)) = result;
    if (n < p) return tooShort;
    final grand = stats.sum / n;
    final ssTot = stats.m2;
    if (ssTot == 0) {
      return const Metric<CircadianNp>.absent(
        tier: Tier.high,
        inputs_used: inputs,
        note: 'no variance in activity series',
      );
    }
    final profile = List<double>.filled(p, 0);
    var ssHour = 0.0;
    for (var h = 0; h < p; h++) {
      final (count, sum) = byEpoch[h]!;
      profile[h] = sum / count;
      final d = profile[h] - grand;
      ssHour += d * d;
    }
    final is_ = (n * ssHour) / (p * ssTot);
    final iv = (n * ssDiff) / ((n - 1) * ssTot);
    final m10 = bestCircularWindow(profile, mEp, maximize: true);
    final l5 = bestCircularWindow(profile, lEp, maximize: false);
    final ra = (m10.value + l5.value) > 0
        ? (m10.value - l5.value) / (m10.value + l5.value)
        : 0.0;
    return Metric<CircadianNp>(
      value: CircadianNp(
        interdailyStability: is_.clamp(0, 1),
        intradailyVariability: iv < 0 ? 0 : iv,
        m10: m10.value,
        l5: l5.value,
        relativeAmplitude: ra.clamp(0, 1),
        m10StartEpoch: m10.start,
        l5StartEpoch: l5.start,
      ),
      confidence: (n / p / 7.0).clamp(0.3, 0.95),
      tier: Tier.high,
      inputs_used: inputs,
      note: 'IS/IV/RA/L5/M10 (van Someren 1999); circadian phase anchored on '
          'the L5 nocturnal trough, not the daytime peak',
    );
  });
}
