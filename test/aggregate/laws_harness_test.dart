// The law harness itself: lawful aggregators pass, deliberately broken ones are
// caught under the right law name (including 'slicing'), and fieldsEqual
// compares as documented.

import 'dart:typed_data';

import 'package:openstrap_analytics/aggregate.dart';
import 'package:test/test.dart';

import '../support/aggregator_laws.dart';

typedef _B = ListBatch<int>;

int _sliceSum(_B b, int start, int end) {
  var t = 0;
  for (var i = start; i < end; i++) {
    t += b.rows[i];
  }
  return t;
}

/// A correct sum over int rows.
class _Sum extends Aggregator<int, _B, int> {
  const _Sum();
  @override
  int empty() => 0;
  @override
  int addSlice(int s, _B b, int start, int end) => s + _sliceSum(b, start, end);
  @override
  int combine(int left, int right) => left + right;
  @override
  int finish(int s) => s;
}

/// Sum whose identity is 1: breaks the identity laws.
class _SumFromOne extends _Sum {
  const _SumFromOne();
  @override
  int empty() => 1;
}

/// Combine drops the right side.
class _DropRight extends _Sum {
  const _DropRight();
  @override
  int combine(int left, int right) => left;
}

/// addSlice ignores the state it is given (restarts from the slice), so a
/// second addSlice onto a state that already holds data loses it. fold (one
/// addSlice onto empty) and combine are both correct, so only 'slicing' sees it.
class _IgnoresState extends _Sum {
  const _IgnoresState();
  @override
  int addSlice(int s, _B b, int start, int end) => _sliceSum(b, start, end);
}

/// addSlice always sums the whole batch, whatever range it is asked for.
class _IgnoresRange extends _Sum {
  const _IgnoresRange();
  @override
  int addSlice(int s, _B b, int start, int end) =>
      s + _sliceSum(b, 0, b.length);
}

/// Mean kept as (mean, count); combine averages the two means unweighted.
class _UnweightedMean extends Aggregator<List<double>, _B, double> {
  const _UnweightedMean();
  @override
  List<double> empty() => [0, 0];
  @override
  List<double> addSlice(List<double> s, _B b, int start, int end) {
    for (var i = start; i < end; i++) {
      final n = s[1] + 1;
      s = [s[0] + (b.rows[i] - s[0]) / n, n];
    }
    return s;
  }

  @override
  List<double> combine(List<double> l, List<double> r) {
    if (r[1] == 0) return l;
    if (l[1] == 0) return r;
    return [(l[0] + r[0]) / 2, l[1] + r[1]];
  }

  @override
  double finish(List<double> s) => s[0];
}

/// addSlice counts 1 per row, but joining two NON-empty chunks adds a bonus, so
/// the add path and the combine path disagree. Identities still hold.
class _JoinBonus extends Aggregator<int, _B, int> {
  const _JoinBonus();
  @override
  int empty() => 0;
  @override
  int addSlice(int s, _B b, int start, int end) => s + (end - start);
  @override
  int combine(int left, int right) =>
      left > 0 && right > 0 ? left + right + 1 : left + right;
  @override
  int finish(int s) => s;
}

/// Wrong only when exactly 3 rows meet exactly 2 (a split of a 5-row batch).
class _WrongAtThreeTwo extends Aggregator<List<int>, _B, int> {
  const _WrongAtThreeTwo();
  @override
  List<int> empty() => [0, 0]; // sum, count
  @override
  List<int> addSlice(List<int> s, _B b, int start, int end) =>
      [s[0] + _sliceSum(b, start, end), s[1] + (end - start)];
  @override
  List<int> combine(List<int> l, List<int> r) =>
      [l[0] + r[0] + (l[1] == 3 && r[1] == 2 ? 1000 : 0), l[1] + r[1]];
  @override
  int finish(List<int> s) => s[0];
}

/// A correct sum that mutates and consumes both arguments in combine.
class _MutatingSum extends Aggregator<List<int>, _B, int> {
  const _MutatingSum();
  @override
  List<int> empty() => [0];
  @override
  List<int> addSlice(List<int> s, _B b, int start, int end) {
    s[0] += _sliceSum(b, start, end);
    return s;
  }

  @override
  List<int> combine(List<int> left, List<int> right) {
    left[0] += right[0];
    right[0] = -999999; // consumed
    return left;
  }

  @override
  int finish(List<int> s) => s[0];
}

/// Same, but wipes `left` too and returns a brand new state.
class _ConsumingSum extends _MutatingSum {
  const _ConsumingSum();
  @override
  List<int> combine(List<int> left, List<int> right) {
    final out = [left[0] + right[0]];
    left[0] = -1;
    right[0] = -1;
    return out;
  }
}

/// A sum whose finish reads the state and then clears it. A single finish per
/// fresh state looks right, so only a law that finishes the SAME state twice
/// (or keeps using it afterwards) can see the damage.
class _DestructiveSum extends Aggregator<List<int>, _B, int> {
  const _DestructiveSum();
  @override
  List<int> empty() => [0];
  @override
  List<int> addSlice(List<int> s, _B b, int start, int end) {
    s[0] += _sliceSum(b, start, end);
    return s;
  }

  @override
  List<int> combine(List<int> left, List<int> right) {
    left[0] += right[0];
    return left;
  }

  @override
  int finish(List<int> s) {
    final out = s[0];
    s[0] = 0; // destructive
    return out;
  }
}

/// finish returns the right number the first time, but marks the state as
/// closed so later rows are ignored. Two finishes in a row agree; continuing to
/// add afterwards does not.
class _FinishFreezes extends Aggregator<List<int>, _B, int> {
  const _FinishFreezes();
  @override
  List<int> empty() => [0, 0]; // sum, frozen
  @override
  List<int> addSlice(List<int> s, _B b, int start, int end) {
    if (s[1] == 0) s[0] += _sliceSum(b, start, end);
    return s;
  }

  @override
  List<int> combine(List<int> left, List<int> right) {
    if (left[1] == 0) left[0] += right[0];
    return left;
  }

  @override
  int finish(List<int> s) {
    s[1] = 1;
    return s[0];
  }
}

/// A correct sum whose codec only breaks when the restored state is the RIGHT
/// operand of combine: a state read back from JSON carries a flag, and combine
/// drops the right side's total when that flag is set. Restoring only the left
/// operand (the old roundTrip law) never sees it.
class _RightRestoreDrops extends Aggregator<List<int>, _B, int> {
  const _RightRestoreDrops({this.faithful = false});

  /// When true the same codec is lawful: combine keeps a restored right side.
  final bool faithful;
  @override
  List<int> empty() => [0, 0]; // total, restored flag
  @override
  List<int> addSlice(List<int> s, _B b, int start, int end) {
    s[0] += _sliceSum(b, start, end);
    return s;
  }

  @override
  List<int> combine(List<int> left, List<int> right) =>
      [left[0] + (right[1] == 1 && !faithful ? 0 : right[0]), left[1]];
  @override
  int finish(List<int> s) => s[0];
  @override
  bool get persistable => true;
  @override
  Object? encodeState(List<int> s) => s[0];
  @override
  List<int> decodeState(Object? json) => [json as int, 1];
}

Set<String> _laws(List<LawViolation> v) => {for (final x in v) x.law};

void main() {
  final cases = randomIntBatches(11, lo: 1, hi: 50);

  group('lawful aggregators', () {
    test('a correct sum has no violations', () {
      expect(checkLaws(const _Sum(), cases), isEmpty);
    });
    test('a mutating combine is judged lawful when otherwise lawful', () {
      expect(checkLaws(const _MutatingSum(), cases), isEmpty);
      expect(checkLaws(const _ConsumingSum(), cases), isEmpty);
    });
    test('no cases is vacuously lawful', () {
      expect(checkLaws(const _Sum(), <_B>[]), isEmpty);
    });
    test('empty and one-row cases alone are fine', () {
      expect(checkLaws(const _Sum(), [_B([]), _B([5])]), isEmpty);
    });
    test('long cases are bounded by maxSplits and still pass', () {
      final long = _B([for (var i = 0; i < 300; i++) i]);
      expect(checkLaws(const _Sum(), [long], maxSplits: 8), isEmpty);
    });
    test('the harness leaves the case batches unchanged', () {
      final b = _B([5, 6, 7, 8]);
      checkLaws(const _Sum(), [b]);
      expect(b.rows, [5, 6, 7, 8]);
    });
    test('expectLawful passes for a lawful aggregator and fails for a broken '
        'one', () {
      expectLawful(const _Sum(), cases);
      expect(() => expectLawful(const _DropRight(), cases),
          throwsA(isA<TestFailure>()));
    });
  });

  group('broken aggregators are caught', () {
    test('(a) non-identity empty fires the identity laws', () {
      final laws = _laws(checkLaws(const _SumFromOne(), cases));
      expect(laws, containsAll(['leftIdentity', 'rightIdentity']));
    });

    test('(b) combine that drops the right side fires split', () {
      final v = checkLaws(const _DropRight(), cases);
      expect(_laws(v), contains('split'));
      expect(v.every((x) => x.detail.isNotEmpty), isTrue);
    });

    test('(c) unweighted mean combine fires split or associativity', () {
      bool close(double a, double b) => (a - b).abs() < 1e-9;
      final laws =
          _laws(checkLaws(const _UnweightedMean(), cases, equals: close));
      expect(laws.intersection({'split', 'associativity'}), isNotEmpty);
    });

    test('(d) addSlice inconsistent with combine fires singletons (identities '
        'hold)', () {
      final laws = _laws(checkLaws(const _JoinBonus(), cases));
      expect(laws, contains('singletons'));
      expect(laws, contains('split'));
      expect(laws, isNot(contains('leftIdentity')));
      expect(laws, isNot(contains('rightIdentity')));
    });

    test('(e) addSlice that ignores the state on a second call fires only '
        '"slicing"', () {
      final laws = _laws(checkLaws(const _IgnoresState(), cases));
      expect(laws, {'slicing'});
    });

    test('(f) addSlice that ignores its range fires split and slicing', () {
      final laws = _laws(checkLaws(const _IgnoresRange(), cases));
      expect(laws, containsAll(['split', 'slicing']));
    });

    test('every split point of a short case is tried', () {
      // Only the 3|2 split of a five-row batch is wrong.
      final laws = _laws(checkLaws(const _WrongAtThreeTwo(), [
        _B([1, 2, 3, 4, 5])
      ]));
      expect(laws, contains('split'));
    });

    test('a lawful case alongside a broken one still reports the broken one',
        () {
      final v = checkLaws(const _DropRight(), [
        _B([]),
        _B([5]),
        _B([1, 2, 3])
      ]);
      expect(_laws(v), contains('split'));
    });

    test('results are deterministic for a given seed', () {
      String render(List<LawViolation> v) =>
          v.map((x) => '${x.law}|${x.detail}').join('\n');
      final a = checkLaws(const _IgnoresState(), cases, seed: 5);
      final b = checkLaws(const _IgnoresState(), cases, seed: 5);
      expect(render(a), render(b));
      expect(a, isNotEmpty);
    });

    test('a custom equals is honoured', () {
      // Everything is "equal", so even a broken aggregator passes.
      expect(checkLaws(const _DropRight(), cases, equals: (a, b) => true),
          isEmpty);
      expect(checkLaws(const _IgnoresState(), cases, equals: (a, b) => true),
          isEmpty);
    });
  });

  group('roundTrip restores the right operand too', () {
    final small = [
      _B([]),
      _B([1, 2, 3]),
      _B([4, 5]),
    ];

    test('a codec that breaks only as the right operand is caught as exactly '
        '{roundTrip}', () {
      final v = checkLaws(const _RightRestoreDrops(), small);
      expect(_laws(v), {'roundTrip'});
      expect(v.every((x) => x.detail.isNotEmpty), isTrue);
    });

    test('the review case [1,2,3] is caught', () {
      expect(
          _laws(checkLaws(const _RightRestoreDrops(), [
            _B([1, 2, 3])
          ])),
          {'roundTrip'});
    });

    test('checkConversion reports it as law:roundTrip', () {
      final f = checkConversion<List<int>, _B, int>(
          (_) => const _RightRestoreDrops(),
          small,
          (b) => b.rows.fold(0, (s, x) => s + x));
      expect({for (final x in f) x.path}, {'law:roundTrip'});
    });

    test('expectLawful fails for it', () {
      expect(() => expectLawful(const _RightRestoreDrops(), small),
          throwsA(isA<TestFailure>()));
    });

    test('the same codec with a combine that keeps a restored right side is '
        'clean', () {
      expect(checkLaws(const _RightRestoreDrops(faithful: true), small),
          isEmpty);
    });
  });

  group('finishPure', () {
    test('a sum whose finish clears the state is caught with exactly '
        '{finishPure}', () {
      expect(_laws(checkLaws(const _DestructiveSum(), cases)), {'finishPure'});
    });

    test('a finish that closes the state to later rows is caught with exactly '
        '{finishPure}', () {
      expect(_laws(checkLaws(const _FinishFreezes(), cases)), {'finishPure'});
    });

    test('the violation names the case', () {
      final v = checkLaws(const _DestructiveSum(), [
        _B([1, 2, 3])
      ]);
      expect(v, isNotEmpty);
      expect(v.every((x) => x.law == 'finishPure' && x.detail.isNotEmpty),
          isTrue);
    });

    test('lawful aggregators report no finishPure violation', () {
      for (final agg in <Aggregator<dynamic, _B, int>>[
        const _Sum(),
        const _MutatingSum(),
        const _ConsumingSum(),
      ]) {
        expect(checkLaws(agg, cases), isEmpty, reason: '$agg');
      }
    });

    test('expectLawful fails for a destructive finish', () {
      expect(() => expectLawful(const _DestructiveSum(), cases),
          throwsA(isA<TestFailure>()));
    });
  });

  group('fieldsEqual', () {
    List<Object?> same(List<Object?> x) => x;

    test('two ints compare exactly, with no double conversion', () {
      final eq = fieldsEqual<List<Object?>>(same, relTol: 1e-9, absTol: 1e-9);
      expect(eq([9007199254740992], [9007199254740993]), isFalse);
      expect(eq([9007199254740993], [9007199254740993]), isTrue);
      final loose = fieldsEqual<List<Object?>>(same, relTol: 0.5, absTol: 10);
      expect(loose([100], [101]), isFalse);
    });

    test('tolerance is absTol + relTol * max(|a|, |b|)', () {
      final eq = fieldsEqual<List<Object?>>(same, absTol: 0.1, relTol: 0.05);
      // 0.15 <= 0.1 + 0.05 * 1.15; the max(absTol, rel) rule would say no.
      expect(eq([1.0], [1.15]), isTrue);
      expect(eq([1.15], [1.0]), isTrue);
      expect(eq([1.0], [1.2]), isFalse);
    });

    test('a finite value never equals a non-finite one', () {
      final eq = fieldsEqual<List<Object?>>(same, absTol: 1e300, relTol: 1);
      expect(eq([1.0], [double.infinity]), isFalse);
      expect(eq([double.negativeInfinity], [1.0]), isFalse);
      expect(eq([double.maxFinite], [double.infinity]), isFalse);
      expect(eq([1.0], [double.nan]), isFalse);
      expect(eq([double.nan], [double.infinity]), isFalse);
    });

    test('NaN equals NaN and each infinity only itself, tolerances or not', () {
      final eq = fieldsEqual<List<Object?>>(same, absTol: 1, relTol: 1);
      expect(eq([double.nan], [double.nan]), isTrue);
      expect(eq([double.infinity], [double.infinity]), isTrue);
      expect(eq([double.negativeInfinity], [double.negativeInfinity]), isTrue);
      expect(eq([double.infinity], [double.negativeInfinity]), isFalse);
    });

    test('an int and a double compare with tolerance', () {
      final eq = fieldsEqual<List<Object?>>(same, absTol: 0.1);
      expect(eq([1], [1.05]), isTrue);
      expect(eq([1], [1.5]), isFalse);
    });

    test('identical lists are equal; length mismatch is not', () {
      final eq = fieldsEqual<List<Object?>>(same);
      expect(eq([1, 'a', null], [1, 'a', null]), isTrue);
      expect(eq([1, 2], [1, 2, 3]), isFalse);
    });

    test('NaN equals NaN, but not a number', () {
      final eq = fieldsEqual<List<Object?>>(same);
      expect(eq([double.nan], [double.nan]), isTrue);
      expect(eq([double.nan], [1.0]), isFalse);
      expect(eq([1.0], [double.nan]), isFalse);
    });

    test('null equals only null', () {
      final eq = fieldsEqual<List<Object?>>(same, relTol: 1, absTol: 1);
      expect(eq([null], [null]), isTrue);
      expect(eq([null], [0.0]), isFalse);
      expect(eq([0.0], [null]), isFalse);
    });

    test('zero tolerance is exact', () {
      final eq = fieldsEqual<List<Object?>>(same);
      expect(eq([1.0], [1.0]), isTrue);
      expect(eq([1.0], [1.0000000000000002]), isFalse);
      expect(eq([1], [1.0]), isTrue);
    });

    test('relTol scales with magnitude', () {
      final eq = fieldsEqual<List<Object?>>(same, relTol: 1e-9);
      expect(eq([1000.0], [1000.0000001]), isTrue); // 1e-7 abs, 1e-10 rel
      expect(eq([1000.0], [1000.00001]), isFalse); // 1e-5 abs, 1e-8 rel
      expect(eq([0.0], [1e-12]), isFalse); // relTol alone gives nothing at 0
    });

    test('absTol covers values near zero', () {
      final eq = fieldsEqual<List<Object?>>(same, absTol: 1e-6);
      expect(eq([0.0], [1e-7]), isTrue);
      expect(eq([0.0], [1e-5]), isFalse);
    });

    test('infinities match only themselves', () {
      final eq = fieldsEqual<List<Object?>>(same, relTol: 1e-9, absTol: 1e-9);
      expect(eq([double.infinity], [double.infinity]), isTrue);
      expect(eq([double.infinity], [double.negativeInfinity]), isFalse);
    });

    test('non-numeric fields compare with ==', () {
      final eq = fieldsEqual<List<Object?>>(same, relTol: 1, absTol: 1);
      expect(eq(['a'], ['a']), isTrue);
      expect(eq(['a'], ['b']), isFalse);
      expect(eq([true], [true]), isTrue);
      expect(eq([1], ['1']), isFalse);
    });

    test('the projection is applied to both sides', () {
      final eq =
          fieldsEqual<({int a, double b})>((r) => [r.a, r.b], absTol: 1e-6);
      expect(eq((a: 1, b: 2.0), (a: 1, b: 2.0000001)), isTrue);
      expect(eq((a: 1, b: 2.0), (a: 2, b: 2.0)), isFalse);
    });

    group('list fields', () {
      test('equal-valued distinct List<double> fields are equal', () {
        final eq = fieldsEqual<List<Object?>>(same);
        expect(
            eq([
              <double>[1.0, 2.5]
            ], [
              <double>[1.0, 2.5]
            ]),
            isTrue);
      });

      test('Float64List equals a List<double> with the same values', () {
        final eq = fieldsEqual<List<Object?>>(same);
        final typed = Float64List.fromList([1.0, 2.5]);
        expect(
            eq([typed], [
              <double>[1.0, 2.5]
            ]),
            isTrue);
        expect(
            eq([
              <double>[1.0, 2.5]
            ], [typed]),
            isTrue);
      });

      test('elements use the numeric tolerance', () {
        final eq = fieldsEqual<List<Object?>>(same, relTol: 1e-3);
        expect(
            eq([
              <double>[1000.0, 1.0]
            ], [
              <double>[1000.5, 1.0]
            ]),
            isTrue);
        expect(
            eq([
              <double>[1000.0, 1.0]
            ], [
              <double>[1002.0, 1.0]
            ]),
            isFalse);
      });

      test('different lengths are unequal (guard)', () {
        final eq = fieldsEqual<List<Object?>>(same, absTol: 1);
        expect(
            eq([
              <double>[1.0, 2.0]
            ], [
              <double>[1.0]
            ]),
            isFalse);
      });

      test('NaN elements equal each other', () {
        final eq = fieldsEqual<List<Object?>>(same);
        expect(
            eq([
              <double>[double.nan, 1.0]
            ], [
              <double>[double.nan, 1.0]
            ]),
            isTrue);
        expect(
            eq([
              <double>[double.nan]
            ], [
              <double>[1.0]
            ]),
            isFalse);
      });

      test('finite never equals non-finite inside a list (guard)', () {
        final eq = fieldsEqual<List<Object?>>(same, absTol: 1e300, relTol: 1);
        expect(
            eq([
              <double>[1.0]
            ], [
              <double>[double.infinity]
            ]),
            isFalse);
      });

      test('int elements compare exactly', () {
        final eq = fieldsEqual<List<Object?>>(same, relTol: 1e-9, absTol: 1e-9);
        expect(
            eq([
              <int>[9007199254740992]
            ], [
              <int>[9007199254740993]
            ]),
            isFalse);
        expect(
            eq([
              <int>[9007199254740993]
            ], [
              <int>[9007199254740993]
            ]),
            isTrue);
      });

      test('null elements equal only null', () {
        final eq = fieldsEqual<List<Object?>>(same, absTol: 1);
        expect(
            eq([
              [null, 1.0]
            ], [
              [null, 1.0]
            ]),
            isTrue);
        expect(
            eq([
              [null]
            ], [
              [0.0]
            ]),
            isFalse);
      });

      test('nested lists recurse', () {
        final eq = fieldsEqual<List<Object?>>(same, absTol: 0.01);
        expect(
            eq([
              [
                [1.0, 2.0],
                [3.0]
              ]
            ], [
              [
                [1.001, 2.0],
                [3.0]
              ]
            ]),
            isTrue);
        expect(
            eq([
              [
                [1.0, 2.0],
                [3.0]
              ]
            ], [
              [
                [1.0, 2.0],
                [3.5]
              ]
            ]),
            isFalse);
      });

      test('a list never equals a non-list (guard)', () {
        final eq = fieldsEqual<List<Object?>>(same, absTol: 10, relTol: 1);
        expect(
            eq([
              <double>[1.0]
            ], [1.0]),
            isFalse);
        expect(
            eq([1.0], [
              <double>[1.0]
            ]),
            isFalse);
        expect(
            eq([
              <double>[]
            ], [null]),
            isFalse);
      });

      test('empty lists are equal', () {
        final eq = fieldsEqual<List<Object?>>(same);
        expect(eq([<double>[]], [<double>[]]), isTrue);
        expect(eq([Float64List(0)], [<double>[]]), isTrue);
      });
    });
  });
}
