// GroupBy: consecutive rows with equal key go to the inner aggregator as one
// slice; a key seen again later is combined into its existing state; finish
// maps every key through inner.finish.

import 'dart:typed_data';

import 'package:openstrap_analytics/aggregate.dart';
import 'package:openstrap_analytics/onehz.dart' show RunningMoments;
import 'package:test/test.dart';

import '../support/aggregator_laws.dart';
import '../support/property.dart' show Rng;

Float64List _v(DoubleColumn c) => c.values;
int _mod3(DoubleColumn c, int i) => c.values[i].toInt() % 3;
int _mod2(DoubleColumn c, int i) => c.values[i].toInt() % 2;
int _tens(DoubleColumn c, int i) => c.values[i] ~/ 10;

/// Exact deep equality for (nested) maps; Map == is identity in Dart.
bool _mapsEqual(Object? a, Object? b) {
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final k in a.keys) {
      if (!b.containsKey(k) || !_mapsEqual(a[k], b[k])) return false;
    }
    return true;
  }
  return a == b;
}

List<Object?> _momentFields(Map<int, RunningMoments> m) {
  final keys = m.keys.toList()..sort();
  return [
    keys.length,
    for (final k in keys) ...[k, m[k]!.count, m[k]!.mean, m[k]!.sampleSd],
  ];
}

/// Records every slice the inner is handed, as a list of its rows.
class _Slices extends Aggregator<List<List<double>>, DoubleColumn, List<List<double>>> {
  const _Slices();
  @override
  List<List<double>> empty() => <List<double>>[];
  @override
  List<List<double>> addSlice(
      List<List<double>> s, DoubleColumn b, int start, int end) {
    if (end > start) s.add(b.values.sublist(start, end));
    return s;
  }

  @override
  List<List<double>> combine(List<List<double>> l, List<List<double>> r) =>
      l..addAll(r);
  @override
  List<List<double>> finish(List<List<double>> s) => s;
}

DoubleColumn _ints(List<int> xs) => col([for (final x in xs) x * 1.0]);

void main() {
  final count3 = GroupBy<DoubleColumn, dynamic, int>(_mod3, Count<DoubleColumn>());
  final sum3 = GroupBy<DoubleColumn, dynamic, double>(_mod3, Sum<DoubleColumn>(_v));

  group('values', () {
    test('counts per key', () {
      expect(count3.run(_ints([1, 2, 3, 4, 5, 6, 7])), {0: 2, 1: 3, 2: 2});
    });

    test('sums per key', () {
      final a = GroupBy<DoubleColumn, dynamic, double>(_mod2, Sum<DoubleColumn>(_v));
      expect(a.run(_ints([1, 2, 3, 4, 5])), {1: 9.0, 0: 6.0});
    });

    test('empty input gives an empty map', () {
      expect(count3.run(col([])), isEmpty);
      expect(count3.finish(count3.empty()), <int, int>{});
    });

    test('a key that never occurs is absent', () {
      expect(count3.run(_ints([3, 6])).keys, [0]);
    });

    test('the key function sees the batch and a row index', () {
      final rows = <int>[];
      final a = GroupBy<DoubleColumn, dynamic, int>(
          (b, i) {
            rows.add(i);
            return 0;
          },
          Count<DoubleColumn>());
      a.run(_ints([5, 6, 7]));
      expect(rows.toSet(), {0, 1, 2});
    });

    test('works over a ListBatch', () {
      final a = GroupBy<ListBatch<String>, dynamic, int>(
          (b, i) => b.rows[i].length, Count<ListBatch<String>>());
      expect(a.runList(['a', 'bb', 'c', 'dd', 'e']), {1: 3, 2: 2});
    });
  });

  group('runs of equal keys', () {
    const slices = _Slices();
    final g = GroupBy<DoubleColumn, dynamic, List<List<double>>>(_tens, slices);

    test('consecutive equal keys reach the inner as one slice', () {
      final r = g.run(col([10, 11, 12, 20, 21]));
      expect(r, {
        1: [
          [10.0, 11.0, 12.0]
        ],
        2: [
          [20.0, 21.0]
        ],
      });
    });

    test('a key that reappears later is combined into its existing state, '
        'in row order', () {
      final r = g.run(col([10, 11, 20, 21, 22, 12, 30, 13, 14]));
      expect(r.keys.toSet(), {1, 2, 3});
      expect(r[1]!.expand((s) => s).toList(), [10.0, 11.0, 12.0, 13.0, 14.0]);
      expect(r[2], [
        [20.0, 21.0, 22.0]
      ]);
      expect(r[3], [
        [30.0]
      ]);
      // each run stayed together; the two runs of key 1 stay separate slices
      expect(r[1], [
        [10.0, 11.0],
        [12.0],
        [13.0, 14.0]
      ]);
    });

    test('alternating keys give one-row slices', () {
      final r = g.run(col([10, 20, 11, 21, 12]));
      expect(r[1], [
        [10.0],
        [11.0],
        [12.0]
      ]);
      expect(r[2], [
        [20.0],
        [21.0]
      ]);
    });

    test('a fold range groups only the rows inside it', () {
      final c = col([10, 11, 20, 21, 12, 13]);
      final r = g.finish(g.fold(c, 1, 5));
      expect(r[1], [
        [11.0],
        [12.0]
      ]);
      expect(r[2], [
        [20.0, 21.0]
      ]);
    });

    test('a run cut by a slice boundary arrives as two slices', () {
      final c = col([10, 11, 12, 13]);
      var s = g.empty();
      s = g.addSlice(s, c, 0, 2);
      s = g.addSlice(s, c, 2, 4);
      final r = g.finish(s);
      expect(r[1]!.expand((x) => x).toList(), [10.0, 11.0, 12.0, 13.0]);
    });
  });

  group('combine', () {
    test('disjoint keys are adopted', () {
      final s = sum3.combine(sum3.fold(_ints([3, 6])), sum3.fold(_ints([1, 4])));
      expect(sum3.finish(s), {0: 9.0, 1: 5.0});
    });

    test('overlapping keys merge with the inner combine', () {
      final s = sum3.combine(
          sum3.fold(_ints([1, 2, 3])), sum3.fold(_ints([4, 5, 6])));
      expect(sum3.finish(s), {0: 9.0, 1: 5.0, 2: 7.0});
    });

    test('mixed shared and one-sided keys', () {
      final s = sum3.combine(sum3.fold(_ints([1, 3])), sum3.fold(_ints([4, 5])));
      expect(sum3.finish(s), {0: 3.0, 1: 5.0, 2: 5.0});
    });

    test('combining with empty on either side changes nothing', () {
      final xs = _ints([1, 2, 3, 4]);
      expect(sum3.finish(sum3.combine(sum3.empty(), sum3.fold(xs))),
          sum3.run(xs));
      expect(sum3.finish(sum3.combine(sum3.fold(xs), sum3.empty())),
          sum3.run(xs));
    });

    test('order within a key is preserved across a seam', () {
      final g = GroupBy<DoubleColumn, dynamic, List<List<double>>>(
          _tens, const _Slices());
      final c = col([10, 20, 11, 12, 21, 13]);
      final r = g.finish(g.combine(g.fold(c, 0, 3), g.fold(c, 3, 6)));
      expect(r[1]!.expand((s) => s).toList(), [10.0, 11.0, 12.0, 13.0]);
      expect(r[2]!.expand((s) => s).toList(), [20.0, 21.0]);
    });
  });

  group('laws', () {
    final cols = randomColumns(0x6B01, nanP: 0, value: (r) => r.intIn(-20, 20) * 1.0);

    test('GroupBy(key, Count) is lawful with exact equality', () {
      expectLawful(count3, cols, equals: _mapsEqual);
    });

    test('GroupBy(key, Sum) is lawful (integer-valued sums are exact)', () {
      expectLawful(sum3, cols, equals: _mapsEqual);
    });

    test('nested GroupBy', () {
      final nested = GroupBy<DoubleColumn, dynamic, Map<int, double>>(
          _mod2, GroupBy<DoubleColumn, dynamic, double>(_mod3, Sum<DoubleColumn>(_v)));
      expect(nested.run(_ints([1, 2, 3, 4, 5, 6])), {
        1: {1: 1.0, 0: 3.0, 2: 5.0},
        0: {2: 2.0, 1: 4.0, 0: 6.0},
      });
      expect(nested.run(col([])), isEmpty);
      expectLawful(nested, cols, equals: _mapsEqual);
    });

    test('tolerance-compared inner (Moments per key)', () {
      final g = GroupBy<DoubleColumn, dynamic, RunningMoments>(
          _mod3, Moments<DoubleColumn>(_v));
      final r = g.run(_ints([1, 2, 3, 4, 5, 10]));
      expect(r.keys.toSet(), {0, 1, 2});
      expect(r[1]!.count, 3);
      expect(r[1]!.mean, closeTo(5.0, 1e-12)); // (1+4+10)/3
      expect(r[1]!.sampleSd, closeTo(4.58257569495584, 1e-9));
      expectLawful(g, cols,
          equals: fieldsEqual<Map<int, RunningMoments>>(_momentFields,
              relTol: 1e-9, absTol: 1e-9));
    });

    test('random chunkings and slicings agree with the whole fold', () {
      final r = Rng(0x6B02);
      for (var t = 0; t < 40; t++) {
        final c = _ints([for (var i = r.intIn(0, 60); i > 0; i--) r.intIn(0, 9)]);
        final b = randomBounds(r, c.length);
        final want = sum3.run(c);
        expect(_mapsEqual(runChunked(sum3, c, b), want), isTrue,
            reason: 'chunked $b');
        expect(_mapsEqual(runChunked(sum3, c, b, copy: true), want), isTrue,
            reason: 'copies $b');
        expect(_mapsEqual(runChunkedRight(sum3, c, b), want), isTrue,
            reason: 'right $b');
        expect(_mapsEqual(runSliced(sum3, c, b), want), isTrue,
            reason: 'sliced $b');
      }
    });
  });
}
