// Shared helpers for the column-slice aggregator tests: the law assertion,
// seeded batch generation, and the three ways to evaluate an aggregator over a
// batch (whole, chunked + combined, one state sliced).

import 'dart:typed_data';

import 'package:openstrap_analytics/aggregate.dart';
import 'package:test/test.dart';

import 'fold_law_support.dart' show foldBounds;
import 'property.dart' show Rng;

/// Asserts that [agg] satisfies every aggregator law on [cases]. The failure
/// message lists each violated law with its detail.
void expectLawful<S, B extends Batch<B>, R>(
  Aggregator<S, B, R> agg,
  List<B> cases, {
  ResultEquals<R>? equals,
}) {
  final violations = checkLaws<S, B, R>(agg, cases, equals: equals);
  expect(violations, isEmpty,
      reason: violations.isEmpty
          ? null
          : 'aggregator laws violated:\n'
              '${violations.map((v) => '  ${v.law}: ${v.detail}').join('\n')}');
}

/// Seeded random double columns. Always starts with the empty column, a
/// singleton and a pair, then [count] columns of length `0..maxLen`. A value
/// is NaN with probability [nanP]; [value] draws the finite ones.
List<DoubleColumn> randomColumns(int seed,
    {int count = 30,
    int maxLen = 40,
    double nanP = .15,
    double Function(Rng)? value}) {
  final r = Rng(seed);
  final draw = value ?? (Rng r) => (r.nextDouble() - .5) * 2000;
  DoubleColumn col(int n) => DoubleColumn(Float64List.fromList(
      [for (var i = 0; i < n; i++) r.nextBool(nanP) ? double.nan : draw(r)]));
  return [
    col(0),
    col(1),
    col(2),
    for (var i = 0; i < count; i++) col(r.intIn(0, maxLen)),
  ];
}

/// Seeded random int batches, same shape as [randomColumns].
List<ListBatch<int>> randomIntBatches(int seed,
    {int count = 30, int maxLen = 40, int lo = -1000, int hi = 1000}) {
  final r = Rng(seed);
  ListBatch<int> b(int n) =>
      ListBatch<int>([for (var i = 0; i < n; i++) r.intIn(lo, hi)]);
  return [b(0), b(1), b(2), for (var i = 0; i < count; i++) b(r.intIn(0, maxLen))];
}

/// A column of the given values.
DoubleColumn col(List<double> xs) => DoubleColumn(Float64List.fromList(xs));

/// Chunk bounds `[0, ...cuts, n]` for a batch of [n] rows. Cuts may repeat or
/// sit on 0 / 1 / 2 / 3 / n-1 / n, so there are empty, singleton and very short
/// chunks.
List<int> randomBounds(Rng r, int n) =>
    foldBounds(n, r.intIn(0, 6), r.nextInt(1 << 30), special: [0, 1, 2, 3]);

/// Folds each chunk `[bounds[k], bounds[k+1])` from a fresh state and combines
/// the chunk states left to right, then finishes. With [copy] each chunk is
/// first cut out with `copyRange` and folded as a batch of its own (so the
/// inner aggregator cannot peek at rows before the chunk); otherwise chunks are
/// ranges of the one batch.
R runChunked<S, B extends Batch<B>, R>(
    Aggregator<S, B, R> agg, B batch, List<int> bounds,
    {bool copy = false}) {
  S chunk(int a, int b) => copy
      ? agg.fold(batch.copyRange(a, b))
      : agg.fold(batch, a, b);
  var acc = chunk(bounds[0], bounds[1]);
  for (var k = 1; k + 1 < bounds.length; k++) {
    acc = agg.combine(acc, chunk(bounds[k], bounds[k + 1]));
  }
  return agg.finish(acc);
}

/// Same chunks, combined right to left: `c0 + (c1 + (c2 + ...))`.
R runChunkedRight<S, B extends Batch<B>, R>(
    Aggregator<S, B, R> agg, B batch, List<int> bounds) {
  var acc = agg.fold(batch, bounds[bounds.length - 2], bounds.last);
  for (var k = bounds.length - 3; k >= 0; k--) {
    acc = agg.combine(agg.fold(batch, bounds[k], bounds[k + 1]), acc);
  }
  return agg.finish(acc);
}

/// The 'slicing' path: ONE state, repeated `addSlice` over the consecutive
/// slices `[bounds[k], bounds[k+1])` (empty slices included), then finish.
R runSliced<S, B extends Batch<B>, R>(
    Aggregator<S, B, R> agg, B batch, List<int> bounds) {
  var state = agg.empty();
  for (var k = 0; k + 1 < bounds.length; k++) {
    state = agg.addSlice(state, batch, bounds[k], bounds[k + 1]);
  }
  return agg.finish(state);
}

/// Plain bounds for the chunk-size-one case: `[0, 1, 2, ..., n]` (`[0, 0]` for
/// an empty batch).
List<int> singletonBounds(int n) => n == 0 ? [0, 0] : [for (var i = 0; i <= n; i++) i];

/// Asserts that [build] over every case in [cases] reproduces [reference] on
/// every evaluation path of [checkConversion] (and, with [laws], the aggregator
/// laws). The failure reason lists the first few failures, one per line.
void expectConversion<S, B extends Batch<B>, R>(
  Aggregator<S, B, R> Function(B input) build,
  List<B> cases,
  R Function(B input) reference, {
  ResultEquals<R>? equals,
  int chunkings = 8,
  int seed = 0,
  bool laws = true,
}) {
  final failures = checkConversion<S, B, R>(build, cases, reference,
      equals: equals, chunkings: chunkings, seed: seed, laws: laws);
  expect(failures, isEmpty,
      reason: failures.isEmpty
          ? null
          : 'conversion check failed (${failures.length}):\n'
              '${failures.take(5).map((f) => '  ${f.path} (case ${f.caseIndex}): ${f.detail}').join('\n')}');
}
