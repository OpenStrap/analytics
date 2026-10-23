import 'dart:convert';
import 'dart:math' as math;

import 'aggregator.dart';

typedef ResultEquals<R> = bool Function(R left, R right);

class LawViolation {
  const LawViolation(this.law, this.detail);
  final String law;
  final String detail;
}

/// Checks aggregator merge and slicing laws on each batch in [cases].
List<LawViolation> checkLaws<S, B extends Batch<B>, R>(
  Aggregator<S, B, R> aggregator,
  List<B> cases, {
  ResultEquals<R>? equals,
  int maxSplits = 64,
  int seed = 0,
}) {
  final equal = equals ?? (R left, R right) => left == right;
  final violations = <LawViolation>[];

  R whole(B batch) => aggregator.finish(aggregator.fold(batch));
  R joined(B batch, int split) => aggregator.finish(aggregator.combine(
      aggregator.fold(batch, 0, split),
      aggregator.fold(batch, split, batch.length)));

  for (var caseIndex = 0; caseIndex < cases.length; caseIndex++) {
    final batch = cases[caseIndex];
    final detail = 'case $caseIndex: $batch';
    final expected = whole(batch);
    final leftIdentity = aggregator.finish(
        aggregator.combine(aggregator.empty(), aggregator.fold(batch)));
    if (!equal(leftIdentity, expected)) {
      violations.add(LawViolation('leftIdentity', detail));
    }
    final rightIdentity = aggregator.finish(
        aggregator.combine(aggregator.fold(batch), aggregator.empty()));
    if (!equal(rightIdentity, expected)) {
      violations.add(LawViolation('rightIdentity', detail));
    }

    final splits = _splitPoints(batch.length, maxSplits, seed + caseIndex);
    for (final split in splits) {
      if (!equal(joined(batch, split), expected)) {
        violations.add(LawViolation('split', '$detail; split $split'));
      }
    }
    for (var i = 0; i < splits.length; i++) {
      for (var j = i; j < splits.length; j++) {
        final first = splits[i];
        final second = splits[j];
        final left = aggregator.finish(aggregator.combine(
            aggregator.combine(aggregator.fold(batch, 0, first),
                aggregator.fold(batch, first, second)),
            aggregator.fold(batch, second, batch.length)));
        final right = aggregator.finish(aggregator.combine(
            aggregator.fold(batch, 0, first),
            aggregator.combine(aggregator.fold(batch, first, second),
                aggregator.fold(batch, second, batch.length))));
        if (!equal(left, right)) {
          violations.add(
              LawViolation('associativity', '$detail; splits $first, $second'));
        }
      }
    }

    var singletonState = aggregator.empty();
    for (var i = 0; i < batch.length; i++) {
      singletonState = aggregator.combine(
          singletonState, aggregator.fold(batch, i, i + 1));
    }
    if (!equal(aggregator.finish(singletonState), expected)) {
      violations.add(LawViolation('singletons', detail));
    }

    var sliced = aggregator.empty();
    final slicePoints = _splitPoints(batch.length, maxSplits, seed ^ caseIndex);
    for (var i = 0; i + 1 < slicePoints.length; i++) {
      sliced = aggregator.addSlice(sliced, batch, slicePoints[i], slicePoints[i + 1]);
    }
    if (!equal(aggregator.finish(sliced), expected)) {
      violations.add(LawViolation('slicing', detail));
    }

    // finish must not consume or otherwise close a state. Keep separate
    // states for the add and combine continuations: combine is allowed to
    // consume either input.
    final continuationStart = batch.length ~/ 2;
    var afterFinish = aggregator.fold(batch, 0, continuationStart);
    final firstFinish = aggregator.finish(afterFinish);
    final secondFinish = aggregator.finish(afterFinish);
    var finishIsPure = equal(firstFinish, secondFinish);

    afterFinish = aggregator.addSlice(
        afterFinish, batch, continuationStart, batch.length);
    var addReference = aggregator.fold(batch, 0, continuationStart);
    addReference = aggregator.addSlice(
        addReference, batch, continuationStart, batch.length);
    if (!equal(aggregator.finish(afterFinish), aggregator.finish(addReference))) {
      finishIsPure = false;
    }

    var combinedAfterFinish = aggregator.fold(batch, 0, continuationStart);
    aggregator.finish(combinedAfterFinish);
    aggregator.finish(combinedAfterFinish);
    combinedAfterFinish = aggregator.combine(
        combinedAfterFinish,
        aggregator.fold(batch, continuationStart, batch.length));
    var combineReference = aggregator.fold(batch, 0, continuationStart);
    combineReference = aggregator.combine(
        combineReference,
        aggregator.fold(batch, continuationStart, batch.length));
    if (!equal(aggregator.finish(combinedAfterFinish),
        aggregator.finish(combineReference))) {
      finishIsPure = false;
    }
    if (!finishIsPure) {
      violations.add(LawViolation('finishPure', detail));
    }

    if (aggregator.persistable) {
      // A state written to JSON text and read back must behave like the
      // original: alone, on either side of a merge, and when extended.
      S roundTrip(S state) => aggregator.decodeState(
          jsonDecode(jsonEncode(aggregator.encodeState(state))));
      void check(String what, R Function() actual) {
        try {
          if (!equal(actual(), expected)) {
            violations.add(LawViolation('roundTrip', '$detail; $what'));
          }
        } catch (error) {
          violations.add(LawViolation('roundTrip', '$detail; $what: $error'));
        }
      }

      check('whole state', () => aggregator.finish(roundTrip(aggregator.fold(batch))));
      for (final split in splits) {
        check(
            'combine after split $split (restored left)',
            () => aggregator.finish(aggregator.combine(
                roundTrip(aggregator.fold(batch, 0, split)),
                aggregator.fold(batch, split, batch.length))));
        check(
            'combine after split $split (restored right)',
            () => aggregator.finish(aggregator.combine(
                aggregator.fold(batch, 0, split),
                roundTrip(aggregator.fold(batch, split, batch.length)))));
        check(
            'combine after split $split (restored both)',
            () => aggregator.finish(aggregator.combine(
                roundTrip(aggregator.fold(batch, 0, split)),
                roundTrip(aggregator.fold(batch, split, batch.length)))));
        check(
            'addSlice after split $split',
            () => aggregator.finish(aggregator.addSlice(
                roundTrip(aggregator.fold(batch, 0, split)),
                batch,
                split,
                batch.length)));
      }
    }
  }
  return violations;
}

class ConversionFailure {
  const ConversionFailure(this.path, this.caseIndex, this.detail);
  final String path;
  final int caseIndex;
  final String detail;
}

/// Checks that an aggregator reproduces [reference] on every evaluation path.
///
/// Paths: 'whole', 'chunked' (left-to-right combine of ranges of the original
/// batch), 'chunkedRight' (same bounds, right-nested combine), 'copies' (each
/// chunk cut with copyRange first), 'sliced' (one state, consecutive slices)
/// and 'singletons'. With [laws], checkLaws violations appear as 'law:<name>'.
/// Deterministic per [seed].
List<ConversionFailure> checkConversion<S, B extends Batch<B>, R>(
  Aggregator<S, B, R> Function(B input) build,
  List<B> cases,
  R Function(B input) reference, {
  ResultEquals<R>? equals,
  int chunkings = 8,
  int seed = 0,
  bool laws = true,
}) {
  final equal = equals ?? (R left, R right) => left == right;
  final failures = <ConversionFailure>[];

  for (var caseIndex = 0; caseIndex < cases.length; caseIndex++) {
    final batch = cases[caseIndex];
    final aggregator = build(batch);
    final expected = reference(batch);
    final seen = <String>{};

    void check(String path, R Function() actual, [String where = '']) {
      if (seen.contains(path)) return;
      final got = actual();
      if (equal(got, expected)) return;
      seen.add(path);
      failures.add(ConversionFailure(path, caseIndex,
          'case $caseIndex: $batch$where; got $got, expected $expected'));
    }

    check('whole', () => aggregator.finish(aggregator.fold(batch)));

    final rng = _Lcg(seed * 7919 + caseIndex);
    for (var c = 0; c < chunkings; c++) {
      final bounds = _chunkBounds(batch.length, rng);
      final where = '; bounds $bounds';
      List<S> states({bool copy = false}) => [
            for (var i = 0; i + 1 < bounds.length; i++)
              copy
                  ? aggregator.fold(batch.copyRange(bounds[i], bounds[i + 1]))
                  : aggregator.fold(batch, bounds[i], bounds[i + 1]),
          ];
      S leftToRight(List<S> parts) {
        var acc = parts.first;
        for (var i = 1; i < parts.length; i++) {
          acc = aggregator.combine(acc, parts[i]);
        }
        return acc;
      }

      check('chunked', () => aggregator.finish(leftToRight(states())), where);
      check('chunkedRight', () {
        final parts = states();
        var acc = parts.last;
        for (var i = parts.length - 2; i >= 0; i--) {
          acc = aggregator.combine(parts[i], acc);
        }
        return aggregator.finish(acc);
      }, where);
      check('copies',
          () => aggregator.finish(leftToRight(states(copy: true))), where);
      check('sliced', () {
        var state = aggregator.empty();
        for (var i = 0; i + 1 < bounds.length; i++) {
          state = aggregator.addSlice(state, batch, bounds[i], bounds[i + 1]);
        }
        return aggregator.finish(state);
      }, where);
    }

    check('singletons', () {
      var state = aggregator.empty();
      for (var i = 0; i < batch.length; i++) {
        state = aggregator.combine(state, aggregator.fold(batch, i, i + 1));
      }
      return aggregator.finish(state);
    });

    if (laws) {
      for (final v in checkLaws(aggregator, [batch],
          equals: equals, seed: seed + caseIndex)) {
        failures.add(ConversionFailure(
            'law:${v.law}', caseIndex, v.detail.replaceFirst('case 0', 'case $caseIndex')));
      }
    }
  }
  return failures;
}

class _Lcg {
  _Lcg(int seed) : _state = seed & 0x7fffffff;
  int _state;
  int next(int bound) {
    _state = (_state * 1103515245 + 12345) & 0x7fffffff;
    return (_state >> 8) % bound;
  }
}

/// Sorted chunk bounds from 0 to [length]: always cuts at 1 and length - 1 and
/// a duplicated cut (an empty chunk), plus a few random cuts.
List<int> _chunkBounds(int length, _Lcg rng) {
  final cuts = <int>[
    0,
    length,
    math.min(1, length),
    math.max(0, length - 1),
    for (var i = rng.next(4); i > 0; i--) rng.next(length + 1),
  ];
  cuts.add(cuts[2 + rng.next(cuts.length - 2)]);
  return cuts..sort();
}

List<int> _splitPoints(int length, int maxSplits, int seed) {
  if (length == 0) return [0];
  final wanted = math.max(2, maxSplits);
  if (length + 1 <= wanted) return [for (var i = 0; i <= length; i++) i];
  final points = <int>{0, length};
  var state = seed & 0x7fffffff;
  while (points.length < wanted) {
    state = (state * 1103515245 + 12345) & 0x7fffffff;
    points.add(1 + state % (length - 1));
  }
  return points.toList()..sort();
}

/// Compares the listed fields pairwise; numbers use the tolerances and lists
/// compare element by element with the same rules.
ResultEquals<R> fieldsEqual<R>(
  List<Object?> Function(R value) fields, {
  double relTol = 0,
  double absTol = 0,
}) =>
    (left, right) {
      final a = fields(left);
      final b = fields(right);
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (!_fieldEqual(a[i], b[i], relTol, absTol)) return false;
      }
      return true;
    };

bool _fieldEqual(Object? left, Object? right, double relTol, double absTol) {
  // Converting two ints to double loses distinctions above 2^53.
  if (left is int && right is int) return left == right;
  if (left is List || right is List) {
    if (left is! List || right is! List || left.length != right.length) {
      return false;
    }
    for (var i = 0; i < left.length; i++) {
      if (!_fieldEqual(left[i], right[i], relTol, absTol)) return false;
    }
    return true;
  }
  if (left == right) return true;
  if (left == null || right == null) return false;
  if (left is! num || right is! num) return false;
  if (left.isNaN || right.isNaN) return left.isNaN && right.isNaN;
  if (!left.isFinite || !right.isFinite) return false;
  final a = left.toDouble();
  final b = right.toDouble();
  final tolerance = absTol + relTol * math.max(a.abs(), b.abs());
  return (a - b).abs() <= tolerance;
}
