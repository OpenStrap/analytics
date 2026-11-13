import 'dart:typed_data';

import 'json_support.dart';

/// A run of rows stored column-wise.
abstract class Batch<B extends Batch<B>> {
  int get length;
  B copyRange(int start, int end);
  B join(B other);

  /// A JSON-encodable copy of the rows. Throws [UnsupportedError] unless the
  /// batch type implements it.
  Object? toJson() =>
      throw UnsupportedError('$runtimeType does not support toJson');
}

/// How a [ListBatch] writes and reads one row. [decode] must throw
/// [FormatException] on a malformed row.
class RowCodec<A> {
  const RowCodec(this.encode, this.decode);

  final Object? Function(A row) encode;
  final A Function(Object? json) decode;

  /// Reads a coded batch from the JSON list written by [ListBatch.toJson].
  ListBatch<A> batchFromJson(Object? json) =>
      ListBatch<A>.coded([for (final row in decodeList(json)) decode(row)], this);
}

/// A batch backed by a normal Dart list.
class ListBatch<A> extends Batch<ListBatch<A>> {
  ListBatch(this.rows) : _codec = null;

  /// A batch whose rows can be written with [codec] (see [toJson]).
  ListBatch.coded(this.rows, RowCodec<A> codec) : _codec = codec;

  final List<A> rows;
  final RowCodec<A>? _codec;

  @override
  int get length => rows.length;

  @override
  ListBatch<A> copyRange(int start, int end) =>
      ListBatch<A>._(rows.sublist(start, end), _codec);

  @override
  ListBatch<A> join(ListBatch<A> other) =>
      ListBatch<A>._([...rows, ...other.rows], _codec ?? other._codec);

  ListBatch._(this.rows, this._codec);

  /// The encoded rows. Throws [UnsupportedError] for a batch without a codec.
  @override
  Object? toJson() {
    final codec = _codec;
    if (codec == null) {
      throw UnsupportedError('ListBatch has no row codec; use ListBatch.coded');
    }
    return [for (final row in rows) codec.encode(row)];
  }
}

/// A batch containing one double column. NaN represents a missing row.
class DoubleColumn extends Batch<DoubleColumn> {
  DoubleColumn(this.values);

  final Float64List values;

  @override
  int get length => values.length;

  @override
  DoubleColumn copyRange(int start, int end) {
    final copied = Float64List(end - start)
      ..setRange(0, end - start, values, start);
    return DoubleColumn(copied);
  }

  @override
  DoubleColumn join(DoubleColumn other) {
    final joined = Float64List(length + other.length);
    joined.setRange(0, length, values);
    joined.setRange(length, joined.length, other.values);
    return DoubleColumn(joined);
  }

  /// The values as a JSON list; NaN and infinities become strings.
  @override
  Object? toJson() => encodeDoubles(values);

  factory DoubleColumn.fromJson(Object? json) => DoubleColumn(decodeDoubles(json));
}

/// A mergeable summary over slices of a [Batch].
abstract class Aggregator<S, B extends Batch<B>, R> {
  const Aggregator();

  S empty();
  S addSlice(S state, B batch, int start, int end);
  S combine(S left, S right);
  R finish(S state);

  /// Whether [encodeState] and [decodeState] are implemented. A composite is
  /// persistable only when every child is.
  bool get persistable => false;

  /// A JSON-encodable form of [state] (null, bool, num, String, List, or a
  /// Map with String keys). Throws [UnsupportedError] unless [persistable].
  Object? encodeState(S state) =>
      throw UnsupportedError('$runtimeType is not persistable');

  /// Inverse of [encodeState]. Throws [FormatException] on malformed input,
  /// and [UnsupportedError] unless [persistable].
  S decodeState(Object? json) =>
      throw UnsupportedError('$runtimeType is not persistable');
}

/// Convenience operations and result adapters for [Aggregator].
extension AggregatorOps<S, B extends Batch<B>, R> on Aggregator<S, B, R> {
  S fold(B batch, [int start = 0, int? end]) {
    final actualEnd = end ?? batch.length;
    return addSlice(empty(), batch, start, actualEnd);
  }

  R run(B batch) => finish(fold(batch));

  Aggregator<S, B, R2> map<R2>(R2 Function(R result) transform) =>
      _MappedAggregator<S, B, R, R2>(this, transform);
}

/// Element-world convenience for aggregators over [ListBatch].
extension ListAggregatorOps<S, A, R> on Aggregator<S, ListBatch<A>, R> {
  R runList(List<A> rows) => run(ListBatch<A>(rows));
}

class _MappedAggregator<S, B extends Batch<B>, R, R2>
    extends Aggregator<S, B, R2> {
  const _MappedAggregator(this.inner, this.transform);

  final Aggregator<S, B, R> inner;
  final R2 Function(R result) transform;

  @override
  S empty() => inner.empty();

  @override
  S addSlice(S state, B batch, int start, int end) =>
      inner.addSlice(state, batch, start, end);

  @override
  S combine(S left, S right) => inner.combine(left, right);

  @override
  R2 finish(S state) => transform(inner.finish(state));

  @override
  bool get persistable => inner.persistable;

  @override
  Object? encodeState(S state) => inner.encodeState(state);

  @override
  S decodeState(Object? json) => inner.decodeState(json);
}

/// Mutable state for [both].
class Pair<A, B> {
  Pair(this.first, this.second);

  A first;
  B second;
}

/// Runs two aggregators over each same slice.
Aggregator<Pair<S1, S2>, B, (R1, R2)>
    both<S1, S2, B extends Batch<B>, R1, R2>(
  Aggregator<S1, B, R1> first,
  Aggregator<S2, B, R2> second,
) =>
        _BothAggregator<S1, S2, B, R1, R2>(first, second);

/// Adds module-specific consistency checks to a persistable checkpoint.
///
/// [validate] runs after [inner] has decoded each child state. It receives the
/// encoded state so a composed module can compare child values whose concrete
/// state types are private to their aggregators. Encoding and hot paths are
/// otherwise unchanged.
Aggregator<S, B, R> validateCheckpoint<S, B extends Batch<B>, R>(
  Aggregator<S, B, R> inner,
  void Function(Object? json) validate,
) =>
    _CheckpointValidatedAggregator<S, B, R>(inner, validate);

class _CheckpointValidatedAggregator<S, B extends Batch<B>, R>
    extends Aggregator<S, B, R> {
  const _CheckpointValidatedAggregator(this.inner, this.validate);

  final Aggregator<S, B, R> inner;
  final void Function(Object? json) validate;

  @override
  S empty() => inner.empty();

  @override
  S addSlice(S state, B batch, int start, int end) =>
      inner.addSlice(state, batch, start, end);

  @override
  S combine(S left, S right) => inner.combine(left, right);

  @override
  R finish(S state) => inner.finish(state);

  @override
  bool get persistable => inner.persistable;

  @override
  Object? encodeState(S state) => inner.encodeState(state);

  @override
  S decodeState(Object? json) {
    final state = inner.decodeState(json);
    validate(json);
    return state;
  }
}

class _BothAggregator<S1, S2, B extends Batch<B>, R1, R2>
    extends Aggregator<Pair<S1, S2>, B, (R1, R2)> {
  const _BothAggregator(this.first, this.second);

  final Aggregator<S1, B, R1> first;
  final Aggregator<S2, B, R2> second;

  @override
  Pair<S1, S2> empty() => Pair<S1, S2>(first.empty(), second.empty());

  @override
  Pair<S1, S2> addSlice(Pair<S1, S2> state, B batch, int start, int end) {
    state.first = first.addSlice(state.first, batch, start, end);
    state.second = second.addSlice(state.second, batch, start, end);
    return state;
  }

  @override
  Pair<S1, S2> combine(Pair<S1, S2> left, Pair<S1, S2> right) {
    left.first = first.combine(left.first, right.first);
    left.second = second.combine(left.second, right.second);
    return left;
  }

  @override
  (R1, R2) finish(Pair<S1, S2> state) =>
      (first.finish(state.first), second.finish(state.second));

  @override
  bool get persistable => first.persistable && second.persistable;

  @override
  Object? encodeState(Pair<S1, S2> state) =>
      [first.encodeState(state.first), second.encodeState(state.second)];

  @override
  Pair<S1, S2> decodeState(Object? json) {
    final list = decodeList(json);
    if (list.length != 2) throw const FormatException('Expected two states');
    return Pair<S1, S2>(
        first.decodeState(list[0]), second.decodeState(list[1]));
  }
}
