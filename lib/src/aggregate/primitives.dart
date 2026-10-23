// Mergeable sums, centered moments and affine EWMA composition reformulate
// the corresponding batch arithmetic. Composition is algebraically equal;
// floating-point evaluation order can differ. Count/min/max and structural
// wrappers are definitional operations, not additional physiological estimators.

import 'dart:typed_data';

import '../onehz/incremental_core.dart' show RunningMoments;

import 'aggregator.dart';
import 'json_support.dart';

/// Counts every row, including rows whose column value is NaN.
class Count<B extends Batch<B>> extends Aggregator<int, B, int> {
  const Count();
  @override
  int empty() => 0;
  @override
  int addSlice(int state, B batch, int start, int end) => state + end - start;
  @override
  int combine(int left, int right) => left + right;
  @override
  int finish(int state) => state;
  @override
  bool get persistable => true;
  @override
  Object? encodeState(int state) => state;
  @override
  int decodeState(Object? json) => decodeCount(json);
}

/// Counts non-missing values in a double column.
class CountFinite<B extends Batch<B>> extends Aggregator<int, B, int> {
  const CountFinite(this.column);
  final Float64List Function(B batch) column;
  @override
  int empty() => 0;
  @override
  int addSlice(int state, B batch, int start, int end) {
    final values = column(batch);
    var count = state;
    for (var i = start; i < end; i++) {
      if (!values[i].isNaN) count++;
    }
    return count;
  }
  @override
  int combine(int left, int right) => left + right;
  @override
  int finish(int state) => state;
  @override
  bool get persistable => true;
  @override
  Object? encodeState(int state) => state;
  @override
  int decodeState(Object? json) => decodeCount(json);
}

/// Counts non-missing values in a double column which pass [test].
class CountWhere<B extends Batch<B>> extends Aggregator<int, B, int> {
  const CountWhere(this.column, this.test);
  final Float64List Function(B batch) column;
  final bool Function(double value) test;
  @override
  int empty() => 0;
  @override
  int addSlice(int state, B batch, int start, int end) {
    final values = column(batch);
    var count = state;
    for (var i = start; i < end; i++) {
      final value = values[i];
      if (!value.isNaN && test(value)) count++;
    }
    return count;
  }
  @override
  int combine(int left, int right) => left + right;
  @override
  int finish(int state) => state;
  @override
  bool get persistable => true;
  @override
  Object? encodeState(int state) => state;
  @override
  int decodeState(Object? json) => decodeCount(json);
}

/// Neumaier-compensated sum of non-missing double column values.
///
/// Chunk-invariant results are supported while all partial sums are finite.
/// Once a partial sum overflows, IEEE-754 arithmetic can make the result
/// depend on chunking.
class Sum<B extends Batch<B>> extends Aggregator<_SumState, B, double> {
  const Sum(this.column);
  final Float64List Function(B batch) column;
  @override
  _SumState empty() => _SumState();
  @override
  _SumState addSlice(_SumState state, B batch, int start, int end) {
    final values = column(batch);
    for (var i = start; i < end; i++) {
      final value = values[i];
      if (!value.isNaN) state.add(value);
    }
    return state;
  }
  @override
  _SumState combine(_SumState left, _SumState right) {
    left.add(right.sum);
    left.add(right.correction);
    return left;
  }
  @override
  double finish(_SumState state) => state.sum + state.correction;
  @override
  bool get persistable => true;

  @override
  Object? encodeState(_SumState state) => state.toJson();

  @override
  _SumState decodeState(Object? json) => _SumState.fromJson(json);
}

/// Neumaier-compensated sum of a function of non-missing double column values.
///
/// A NaN source value is skipped without calling [transform]. A NaN result from
/// [transform] is also skipped.
/// Chunk-invariant results are supported while all partial sums are finite.
/// Once a partial sum overflows, IEEE-754 arithmetic can make the result
/// depend on chunking.
class SumOf<B extends Batch<B>> extends Aggregator<_SumState, B, double> {
  const SumOf(this.column, this.transform);

  final Float64List Function(B batch) column;
  final double Function(double value) transform;

  @override
  _SumState empty() => _SumState();

  @override
  _SumState addSlice(_SumState state, B batch, int start, int end) {
    final values = column(batch);
    for (var i = start; i < end; i++) {
      final value = values[i];
      if (value.isNaN) continue;
      final transformed = transform(value);
      if (!transformed.isNaN) state.add(transformed);
    }
    return state;
  }

  @override
  _SumState combine(_SumState left, _SumState right) {
    left.add(right.sum);
    left.add(right.correction);
    return left;
  }

  @override
  double finish(_SumState state) => state.sum + state.correction;
  @override
  bool get persistable => true;

  @override
  Object? encodeState(_SumState state) => state.toJson();

  @override
  _SumState decodeState(Object? json) => _SumState.fromJson(json);
}

class _SumState {
  _SumState();

  factory _SumState.fromJson(Object? json) {
    final map = decodeMap(json);
    return _SumState()
      ..sum = decodeDouble(field(map, 'sum'))
      ..correction = decodeDouble(field(map, 'correction'));
  }

  double sum = 0.0;
  double correction = 0.0;

  Map<String, Object?> toJson() =>
      {'sum': encodeDouble(sum), 'correction': encodeDouble(correction)};

  void add(double value) {
    final next = sum + value;
    if (!next.isFinite) {
      sum = next;
      return;
    }
    if (sum.abs() >= value.abs()) {
      correction += (sum - next) + value;
    } else {
      correction += (value - next) + sum;
    }
    sum = next;
  }
}

/// Sum of squares of non-missing double column values.
class SumSq<B extends Batch<B>> extends Aggregator<double, B, double> {
  const SumSq(this.column);
  final Float64List Function(B batch) column;
  @override
  double empty() => 0.0;
  @override
  double addSlice(double state, B batch, int start, int end) {
    final values = column(batch);
    var sum = state;
    for (var i = start; i < end; i++) {
      final value = values[i];
      if (!value.isNaN) sum += value * value;
    }
    return sum;
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

/// Smallest non-missing value in a double column.
class Min<B extends Batch<B>> extends Aggregator<double?, B, double?> {
  const Min(this.column);
  final Float64List Function(B batch) column;
  @override
  double? empty() => null;
  @override
  double? addSlice(double? state, B batch, int start, int end) {
    final values = column(batch);
    var result = state;
    for (var i = start; i < end; i++) {
      final value = values[i];
      if (!value.isNaN && (result == null || value < result)) result = value;
    }
    return result;
  }
  @override
  double? combine(double? left, double? right) {
    if (left == null || right == null) return left ?? right;
    return right < left ? right : left;
  }
  @override
  double? finish(double? state) => state;
  @override
  bool get persistable => true;
  @override
  Object? encodeState(double? state) =>
      state == null ? null : encodeDouble(state);
  @override
  double? decodeState(Object? json) => decodeDoubleOrNull(json);
}

/// Largest non-missing value in a double column.
class Max<B extends Batch<B>> extends Aggregator<double?, B, double?> {
  const Max(this.column);
  final Float64List Function(B batch) column;
  @override
  double? empty() => null;
  @override
  double? addSlice(double? state, B batch, int start, int end) {
    final values = column(batch);
    var result = state;
    for (var i = start; i < end; i++) {
      final value = values[i];
      if (!value.isNaN && (result == null || value > result)) result = value;
    }
    return result;
  }
  @override
  double? combine(double? left, double? right) {
    if (left == null || right == null) return left ?? right;
    return right > left ? right : left;
  }
  @override
  double? finish(double? state) => state;
  @override
  bool get persistable => true;
  @override
  Object? encodeState(double? state) =>
      state == null ? null : encodeDouble(state);
  @override
  double? decodeState(Object? json) => decodeDoubleOrNull(json);
}

// Delegates updates/removal to Welford 1962 and partition merging to Chan,
// Golub & LeVeque 1983; full references and clamp details: RunningMoments.
/// Centered moments of non-missing double column values.
class Moments<B extends Batch<B>>
    extends Aggregator<RunningMoments, B, RunningMoments> {
  const Moments(this.column);
  final Float64List Function(B batch) column;
  @override
  RunningMoments empty() => RunningMoments();
  @override
  RunningMoments addSlice(RunningMoments state, B batch, int start, int end) {
    final values = column(batch);
    for (var i = start; i < end; i++) {
      final value = values[i];
      if (!value.isNaN) state.add(value);
    }
    return state;
  }
  @override
  RunningMoments combine(RunningMoments left, RunningMoments right) {
    left.merge(right);
    return left;
  }
  @override
  RunningMoments finish(RunningMoments state) => state;
  @override
  bool get persistable => true;
  @override
  Object? encodeState(RunningMoments state) => state.toJson();
  @override
  RunningMoments decodeState(Object? json) =>
      RunningMoments.fromJson(decodeMap(json));
}

class _EdgeState<B extends Batch<B>> {
  B? value;
}

Object? _encodeEdge<B extends Batch<B>>(
    _EdgeState<B> state, B Function(Object?)? batchFromJson) {
  if (batchFromJson == null) {
    throw UnsupportedError('Pass batchFromJson to persist this block');
  }
  return {'value': state.value?.toJson()};
}

_EdgeState<B> _decodeEdge<B extends Batch<B>>(
    Object? json, B Function(Object?)? batchFromJson) {
  if (batchFromJson == null) {
    throw UnsupportedError('Pass batchFromJson to persist this block');
  }
  final raw = field(decodeMap(json), 'value');
  final state = _EdgeState<B>();
  if (raw != null) {
    final row = batchFromJson(raw);
    if (row.length != 1) throw const FormatException('Expected one row');
    state.value = row;
  }
  return state;
}

/// The first row as a one-row copy, or null for no rows.
class First<B extends Batch<B>> extends Aggregator<_EdgeState<B>, B, B?> {
  /// Persistable only when [batchFromJson] is given (the inverse of
  /// [Batch.toJson] for [B]).
  const First({this.batchFromJson});
  final B Function(Object? json)? batchFromJson;
  @override
  _EdgeState<B> empty() => _EdgeState<B>();
  @override
  _EdgeState<B> addSlice(_EdgeState<B> state, B batch, int start, int end) {
    if (state.value == null && start < end) {
      state.value = batch.copyRange(start, start + 1);
    }
    return state;
  }
  @override
  _EdgeState<B> combine(_EdgeState<B> left, _EdgeState<B> right) {
    if (left.value == null) left.value = right.value;
    return left;
  }
  @override
  B? finish(_EdgeState<B> state) => state.value;
  @override
  bool get persistable => batchFromJson != null;
  @override
  Object? encodeState(_EdgeState<B> state) => _encodeEdge(state, batchFromJson);
  @override
  _EdgeState<B> decodeState(Object? json) => _decodeEdge(json, batchFromJson);
}

/// The last row as a one-row copy, or null for no rows.
class Last<B extends Batch<B>> extends Aggregator<_EdgeState<B>, B, B?> {
  /// Persistable only when [batchFromJson] is given (the inverse of
  /// [Batch.toJson] for [B]).
  const Last({this.batchFromJson});
  final B Function(Object? json)? batchFromJson;
  @override
  _EdgeState<B> empty() => _EdgeState<B>();
  @override
  _EdgeState<B> addSlice(_EdgeState<B> state, B batch, int start, int end) {
    if (start < end) state.value = batch.copyRange(end - 1, end);
    return state;
  }
  @override
  _EdgeState<B> combine(_EdgeState<B> left, _EdgeState<B> right) {
    if (right.value != null) left.value = right.value;
    return left;
  }
  @override
  B? finish(_EdgeState<B> state) => state.value;
  @override
  bool get persistable => batchFromJson != null;
  @override
  Object? encodeState(_EdgeState<B> state) => _encodeEdge(state, batchFromJson);
  @override
  _EdgeState<B> decodeState(Object? json) => _decodeEdge(json, batchFromJson);
}

class _RowsState<B extends Batch<B>> {
  B? rows;
}

/// The last [k] rows of the whole input as a copy (fewer when the input is
/// shorter), or null for no rows.
class LastRows<B extends Batch<B>> extends Aggregator<_RowsState<B>, B, B?> {
  /// Persistable only when [batchFromJson] is given (the inverse of
  /// [Batch.toJson] for [B]).
  const LastRows(this.k, {this.batchFromJson}) : assert(k >= 1);
  final int k;
  final B Function(Object? json)? batchFromJson;

  B _tail(B rows) =>
      rows.length <= k ? rows : rows.copyRange(rows.length - k, rows.length);

  @override
  _RowsState<B> empty() => _RowsState<B>();
  @override
  _RowsState<B> addSlice(_RowsState<B> state, B batch, int start, int end) {
    if (start >= end) return state;
    final from = end - start > k ? end - k : start;
    final piece = batch.copyRange(from, end);
    final rows = state.rows;
    state.rows = rows == null ? piece : _tail(rows.join(piece));
    return state;
  }
  @override
  _RowsState<B> combine(_RowsState<B> left, _RowsState<B> right) {
    final l = left.rows;
    final r = right.rows;
    if (r == null) return left;
    left.rows = l == null ? r : _tail(l.join(r));
    return left;
  }
  @override
  B? finish(_RowsState<B> state) => state.rows;
  @override
  bool get persistable => batchFromJson != null;
  @override
  Object? encodeState(_RowsState<B> state) {
    if (batchFromJson == null) {
      throw UnsupportedError('Pass batchFromJson to persist this block');
    }
    return {'rows': state.rows?.toJson()};
  }
  @override
  _RowsState<B> decodeState(Object? json) {
    final fromJson = batchFromJson;
    if (fromJson == null) {
      throw UnsupportedError('Pass batchFromJson to persist this block');
    }
    final raw = field(decodeMap(json), 'rows');
    final state = _RowsState<B>();
    if (raw != null) {
      final rows = fromJson(raw);
      if (rows.length < 1 || rows.length > k) {
        throw const FormatException('Row count out of range');
      }
      state.rows = rows;
    }
    return state;
  }
}

/// Routes consecutive equal keys to [inner] as one slice per run.
class GroupBy<B extends Batch<B>, S, R>
    extends Aggregator<Map<int, S>, B, Map<int, R>> {
  const GroupBy(this.key, this.inner);
  final int Function(B batch, int row) key;
  final Aggregator<S, B, R> inner;
  @override
  Map<int, S> empty() => <int, S>{};
  @override
  Map<int, S> addSlice(Map<int, S> state, B batch, int start, int end) {
    if (start == end) return state;
    var runStart = start;
    var runKey = key(batch, start);
    for (var i = start + 1; i < end; i++) {
      final nextKey = key(batch, i);
      if (nextKey != runKey) {
        _addRun(state, runKey, batch, runStart, i);
        runStart = i;
        runKey = nextKey;
      }
    }
    _addRun(state, runKey, batch, runStart, end);
    return state;
  }
  void _addRun(Map<int, S> state, int runKey, B batch, int start, int end) {
    final previous = state.containsKey(runKey) ? state[runKey] as S : inner.empty();
    state[runKey] = inner.addSlice(previous, batch, start, end);
  }
  @override
  Map<int, S> combine(Map<int, S> left, Map<int, S> right) {
    for (final entry in right.entries) {
      if (left.containsKey(entry.key)) {
        left[entry.key] = inner.combine(left[entry.key] as S, entry.value);
      } else {
        left[entry.key] = entry.value;
      }
    }
    return left;
  }
  @override
  Map<int, R> finish(Map<int, S> state) => <int, R>{
        for (final entry in state.entries) entry.key: inner.finish(entry.value),
      };
  @override
  bool get persistable => inner.persistable;

  @override
  Object? encodeState(Map<int, S> state) => <String, Object?>{
        for (final entry in state.entries)
          entry.key.toString(): inner.encodeState(entry.value),
      };

  @override
  Map<int, S> decodeState(Object? json) {
    final map = decodeMap(json);
    final result = <int, S>{};
    for (final entry in map.entries) {
      final key = int.tryParse(entry.key);
      if (key == null || key.toString() != entry.key) {
        throw FormatException('Invalid group key ${entry.key}');
      }
      result[key] = inner.decodeState(entry.value);
    }
    return result;
  }
}

/// Makes an inner length-[k] window aggregator invariant to chunk boundaries.
class Lookback<B extends Batch<B>, S, R>
    extends Aggregator<_LookbackState<B, S>, B, R> {
  /// Persistable only when [batchFromJson] is given (the inverse of
  /// [Batch.toJson] for [B]) and [inner] is persistable.
  Lookback(this.k, this.inner, {this.batchFromJson}) : assert(k >= 1);
  final int k;
  final Aggregator<S, B, R> inner;
  final B Function(Object? json)? batchFromJson;
  int get _edge => k - 1;
  @override
  _LookbackState<B, S> empty() => _LookbackState<B, S>(inner.empty());
  @override
  _LookbackState<B, S> addSlice(
      _LookbackState<B, S> state, B batch, int start, int end) {
    if (start == end) return state;
    if (state.length > 0 && _edge > 0) {
      final seam = state.last!.join(batch.copyRange(start, _prefixEnd(start, end)));
      state.innerState = inner.addSlice(state.innerState, seam, 0, seam.length);
    }
    state.innerState = inner.addSlice(state.innerState, batch, start, end);
    _appendEdges(state, batch, start, end);
    return state;
  }
  int _prefixEnd(int start, int end) =>
      start + (end - start < _edge ? end - start : _edge);
  void _appendEdges(_LookbackState<B, S> state, B batch, int start, int end) {
    final sliceLength = end - start;
    if (_edge == 0) {
      state.length += sliceLength;
      return;
    }
    if (state.length == 0) {
      state.first = batch.copyRange(start, _prefixEnd(start, end));
      state.last = batch.copyRange(
          end - (sliceLength < _edge ? sliceLength : _edge), end);
    } else {
      if (state.length < _edge) {
        final needed = _edge - state.length;
        final take = sliceLength < needed ? sliceLength : needed;
        if (take > 0) state.first = state.first!.join(batch.copyRange(start, start + take));
      }
      if (sliceLength >= _edge) {
        state.last = batch.copyRange(end - _edge, end);
      } else {
        final joined = state.last!.join(batch.copyRange(start, end));
        final keepStart = joined.length > _edge ? joined.length - _edge : 0;
        state.last = joined.copyRange(keepStart, joined.length);
      }
    }
    state.length += sliceLength;
  }
  @override
  _LookbackState<B, S> combine(
      _LookbackState<B, S> left, _LookbackState<B, S> right) {
    if (left.length > 0 && right.length > 0 && _edge > 0) {
      final seam = left.last!.join(right.first!);
      left.innerState = inner.addSlice(left.innerState, seam, 0, seam.length);
    }
    left.innerState = inner.combine(left.innerState, right.innerState);
    _combineEdges(left, right);
    return left;
  }
  void _combineEdges(_LookbackState<B, S> left, _LookbackState<B, S> right) {
    if (right.length == 0) return;
    if (left.length == 0) {
      left.length = right.length;
      left.first = right.first;
      left.last = right.last;
      return;
    }
    if (_edge > 0) {
      if (left.length < _edge) {
        final needed = _edge - left.length;
        final take = right.length < needed ? right.length : needed;
        if (take > 0) left.first = left.first!.join(right.first!.copyRange(0, take));
      }
      if (right.length >= _edge) {
        left.last = right.last;
      } else {
        final joined = left.last!.join(right.last!);
        final keepStart = joined.length > _edge ? joined.length - _edge : 0;
        left.last = joined.copyRange(keepStart, joined.length);
      }
    }
    left.length += right.length;
  }
  @override
  R finish(_LookbackState<B, S> state) => inner.finish(state.innerState);

  @override
  bool get persistable => batchFromJson != null && inner.persistable;

  @override
  Object? encodeState(_LookbackState<B, S> state) {
    _requireBatchCodec();
    return {
      'length': state.length,
      'first': state.first?.toJson(),
      'last': state.last?.toJson(),
      'inner': inner.encodeState(state.innerState),
    };
  }

  @override
  _LookbackState<B, S> decodeState(Object? json) {
    final fromJson = _requireBatchCodec();
    final map = decodeMap(json);
    final length = decodeCount(field(map, 'length'));
    // Edges hold the first/last min(length, k - 1) rows.
    final held = length < _edge ? length : _edge;
    B? edge(String name) {
      final raw = field(map, name);
      if (raw == null) {
        if (held != 0) throw FormatException('Missing $name rows');
        return null;
      }
      if (held == 0) throw FormatException('Unexpected $name rows');
      final rows = fromJson(raw);
      if (rows.length != held) {
        throw FormatException('Expected $held $name rows');
      }
      return rows;
    }

    return _LookbackState<B, S>(inner.decodeState(field(map, 'inner')))
      ..length = length
      ..first = edge('first')
      ..last = edge('last');
  }

  B Function(Object?) _requireBatchCodec() =>
      batchFromJson ??
      (throw UnsupportedError('Pass batchFromJson to persist Lookback'));
}

class _LookbackState<B extends Batch<B>, S> {
  _LookbackState(this.innerState);
  S innerState;
  int length = 0;
  B? first;
  B? last;
}

/// An affine map x -> scale * x + offset. Composition is associative, so a
/// run of affine steps can be summarised by one map and merged in any grouping.
class Affine {
  const Affine(this.scale, this.offset);

  final double scale;
  final double offset;

  double apply(double x) => scale * x + offset;

  /// The map that applies this one first, then [next].
  Affine then(Affine next) => Affine(
      next.scale * scale, next.scale * offset + next.offset);
}

class _AffineState {
  double scale = 1;
  double offset = 0;
}

// Algebraically equal to the EWMA recurrence: f_x(c)=a*c+lambda*x, a=1-lambda;
// f_y(f_x(c))=a*a*c+a*lambda*x+lambda*y. Floating-point order may differ.
/// An exponentially weighted moving average, as the composed affine map of the
/// running value: each row x applies c -> (1 - lambda) * c + lambda * x.
///
/// NaN rows are skipped (they act as the identity map), and no rows finish as
/// the identity. ±Infinity input is unsupported because scale can underflow to
/// zero across a seam and yield `0*Infinity`. Apply the result to the seed
/// value to get the final average.
class Ewma<B extends Batch<B>> extends Aggregator<_AffineState, B, Affine> {
  const Ewma(this.column, this.lambda);

  final Float64List Function(B batch) column;
  final double lambda;

  @override
  _AffineState empty() => _AffineState();

  @override
  _AffineState addSlice(_AffineState state, B batch, int start, int end) {
    final values = column(batch);
    final keep = 1 - lambda;
    var scale = state.scale;
    var offset = state.offset;
    for (var i = start; i < end; i++) {
      final x = values[i];
      if (x.isNaN) continue;
      scale *= keep;
      offset = keep * offset + lambda * x;
    }
    state.scale = scale;
    state.offset = offset;
    return state;
  }

  @override
  _AffineState combine(_AffineState left, _AffineState right) {
    // Right's map runs after left's.
    left.offset = right.scale * left.offset + right.offset;
    left.scale = right.scale * left.scale;
    return left;
  }

  @override
  Affine finish(_AffineState state) => Affine(state.scale, state.offset);
  @override
  bool get persistable => true;

  @override
  Object? encodeState(_AffineState state) => {
        'scale': encodeDouble(state.scale),
        'offset': encodeDouble(state.offset),
      };

  @override
  _AffineState decodeState(Object? json) {
    final map = decodeMap(json);
    return _AffineState()
      ..scale = decodeDouble(field(map, 'scale'))
      ..offset = decodeDouble(field(map, 'offset'));
  }
}

class _PrefixState<B extends Batch<B>, S2> {
  _PrefixState(this.tail);

  /// The first rows of the input seen so far (at most k), null before any.
  B? rows;
  int held = 0;
  S2 tail;
}

/// Sends the first [k] rows of the whole input to [head] and every later row
/// to [tail], in order, however the input is chunked.
///
/// The state keeps the prefix rows (a copy, at most k) and the tail state.
/// The head result is computed at finish by running [head] over the stored
/// rows, so [head] never needs a working combine. With fewer than k rows in
/// total, head sees all of them and the tail sees none.
class Prefix<B extends Batch<B>, S1, R1, S2, R2>
    extends Aggregator<_PrefixState<B, S2>, B, (R1, R2)> {
  /// Persistable only when [batchFromJson] is given (the inverse of
  /// [Batch.toJson] for [B]) and [tail] is persistable. [head] keeps no state,
  /// so it does not matter.
  const Prefix(this.k, this.head, this.tail, {this.batchFromJson});

  final int k;
  final Aggregator<S1, B, R1> head;
  final Aggregator<S2, B, R2> tail;
  final B Function(Object? json)? batchFromJson;

  @override
  _PrefixState<B, S2> empty() => _PrefixState<B, S2>(tail.empty());

  /// Appends [piece] to the stored prefix rows.
  void _hold(_PrefixState<B, S2> state, B piece) {
    final rows = state.rows;
    state.rows = rows == null ? piece : rows.join(piece);
    state.held += piece.length;
  }

  @override
  _PrefixState<B, S2> addSlice(
      _PrefixState<B, S2> state, B batch, int start, int end) {
    final room = k - state.held;
    final take = room < end - start ? room : end - start;
    if (take > 0) _hold(state, batch.copyRange(start, start + take));
    if (start + take < end) {
      state.tail = tail.addSlice(state.tail, batch, start + take, end);
    }
    return state;
  }

  @override
  _PrefixState<B, S2> combine(
      _PrefixState<B, S2> left, _PrefixState<B, S2> right) {
    final rightRows = right.rows;
    var rest = right.tail;
    if (rightRows != null) {
      // Right's leading rows fill whatever room left's prefix still has; the
      // remainder are tail rows that come before right's own tail.
      final room = k - left.held;
      final take = room < right.held ? room : right.held;
      if (take > 0) _hold(left, rightRows.copyRange(0, take));
      if (take < right.held) {
        final extra =
            tail.addSlice(tail.empty(), rightRows, take, right.held);
        rest = tail.combine(extra, rest);
      }
    }
    left.tail = tail.combine(left.tail, rest);
    return left;
  }

  @override
  (R1, R2) finish(_PrefixState<B, S2> state) {
    final rows = state.rows;
    final headState = rows == null
        ? head.empty()
        : head.addSlice(head.empty(), rows, 0, rows.length);
    return (head.finish(headState), tail.finish(state.tail));
  }

  @override
  bool get persistable => batchFromJson != null && tail.persistable;

  @override
  Object? encodeState(_PrefixState<B, S2> state) {
    _requireBatchCodec();
    return {
      'rows': state.rows?.toJson(),
      'tail': tail.encodeState(state.tail),
    };
  }

  @override
  _PrefixState<B, S2> decodeState(Object? json) {
    final fromJson = _requireBatchCodec();
    final map = decodeMap(json);
    final raw = field(map, 'rows');
    final result = _PrefixState<B, S2>(tail.decodeState(field(map, 'tail')));
    if (raw != null) {
      final rows = fromJson(raw);
      if (rows.length < 1 || rows.length > k) {
        throw const FormatException('Invalid prefix row count');
      }
      result.rows = rows;
      result.held = rows.length;
    }
    return result;
  }

  B Function(Object?) _requireBatchCodec() =>
      batchFromJson ??
      (throw UnsupportedError('Pass batchFromJson to persist Prefix'));
}
