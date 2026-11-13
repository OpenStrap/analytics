// Aggregator core: the Batch implementations, fold (with ranges) / run /
// runList, map and both.

import 'dart:typed_data';

import 'package:openstrap_analytics/aggregate.dart';
import 'package:test/test.dart';

import '../support/aggregator_laws.dart';
import '../support/property.dart' show Rng;

/// Sum of the int rows. State is a one-slot list so combine/addSlice can mutate.
class _SumRows extends Aggregator<List<int>, ListBatch<int>, int> {
  const _SumRows();
  @override
  List<int> empty() => [0];
  @override
  List<int> addSlice(List<int> s, ListBatch<int> b, int start, int end) {
    for (var i = start; i < end; i++) {
      s[0] += b.rows[i];
    }
    return s;
  }

  @override
  List<int> combine(List<int> left, List<int> right) {
    left[0] += right[0];
    return left;
  }

  @override
  int finish(List<int> s) => s[0];
}

/// Rows seen, in order, as a list (state mutated in place).
class _Rows extends Aggregator<List<int>, ListBatch<int>, List<int>> {
  const _Rows();
  @override
  List<int> empty() => <int>[];
  @override
  List<int> addSlice(List<int> s, ListBatch<int> b, int start, int end) =>
      s..addAll(b.rows.sublist(start, end));
  @override
  List<int> combine(List<int> left, List<int> right) => left..addAll(right);
  @override
  List<int> finish(List<int> s) => List<int>.of(s);
}

bool _same<T>(T a, T b) => a.toString() == b.toString();

void main() {
  group('ListBatch', () {
    test('length, rows and copyRange', () {
      final b = ListBatch<String>(['a', 'b', 'c', 'd']);
      expect(b.length, 4);
      expect(b.rows, ['a', 'b', 'c', 'd']);
      expect(b.copyRange(1, 3).rows, ['b', 'c']);
      expect(b.copyRange(0, 4).rows, ['a', 'b', 'c', 'd']);
      expect(b.copyRange(2, 2).length, 0);
      expect(b.copyRange(4, 4).length, 0);
      expect(b.copyRange(1, 3).length, 2);
    });

    test('copyRange is a copy: later changes to the source do not show', () {
      final rows = [1, 2, 3, 4];
      final b = ListBatch<int>(rows);
      final c = b.copyRange(1, 4);
      rows[1] = 99;
      rows[3] = 77;
      expect(c.rows, [2, 3, 4]);
    });

    test('join puts this before other and leaves both unchanged', () {
      final a = ListBatch<int>([1, 2]), b = ListBatch<int>([3, 4, 5]);
      final j = a.join(b);
      expect(j.rows, [1, 2, 3, 4, 5]);
      expect(j.length, 5);
      expect(a.rows, [1, 2]);
      expect(b.rows, [3, 4, 5]);
      expect(a.join(ListBatch<int>([])).rows, [1, 2]);
      expect(ListBatch<int>([]).join(b).rows, [3, 4, 5]);
      expect(ListBatch<int>([]).join(ListBatch<int>([])).length, 0);
    });
  });

  group('DoubleColumn', () {
    test('length, values and copyRange', () {
      final c = col([1, 2, 3, 4]);
      expect(c.length, 4);
      expect(c.copyRange(1, 3).values, [2.0, 3.0]);
      expect(c.copyRange(0, 4).values, [1.0, 2.0, 3.0, 4.0]);
      expect(c.copyRange(3, 3).length, 0);
    });

    test('copyRange is a copy: later changes to the source do not show', () {
      final v = Float64List.fromList([1, 2, 3, 4]);
      final c = DoubleColumn(v).copyRange(1, 3);
      v[1] = 99;
      v[2] = 77;
      expect(c.values, [2.0, 3.0]);
    });

    test('join, with NaN kept as a missing value', () {
      final a = col([1, double.nan]), b = col([3]);
      final j = a.join(b);
      expect(j.length, 3);
      expect(j.values[0], 1.0);
      expect(j.values[1].isNaN, isTrue);
      expect(j.values[2], 3.0);
      expect(a.length, 2);
      expect(b.values, [3.0]);
      expect(a.join(col([])).length, 2);
      expect(col([]).join(b).values, [3.0]);
    });
  });

  group('fold, run, runList', () {
    const sum = _SumRows();
    final batch = ListBatch<int>([for (var i = 1; i <= 5; i++) i]);

    test('run of nothing is the identity result', () {
      expect(sum.run(ListBatch<int>([])), 0);
      expect(sum.runList(<int>[]), 0);
    });

    test('run equals finish(fold) and folds in order', () {
      expect(sum.run(batch), 15);
      expect(sum.finish(sum.fold(batch)), 15);
      expect(const _Rows().run(batch), [1, 2, 3, 4, 5]);
    });

    test('runList is run over a ListBatch', () {
      expect(sum.runList([4, 5, 6]), 15);
      expect(const _Rows().runList([9, 8, 7]), [9, 8, 7]);
    });

    test('fold takes a half-open range; end defaults to the length', () {
      expect(sum.finish(sum.fold(batch, 1, 4)), 2 + 3 + 4);
      expect(sum.finish(sum.fold(batch, 0, 5)), 15);
      expect(sum.finish(sum.fold(batch, 2)), 3 + 4 + 5);
      expect(sum.finish(sum.fold(batch, 5)), 0);
      expect(sum.finish(sum.fold(batch, 2, 2)), 0);
      expect(sum.finish(sum.fold(batch, 5, 5)), 0);
      expect(const _Rows().finish(const _Rows().fold(batch, 1, 3)), [2, 3]);
    });

    test('fold ranges combine back to the whole at every split', () {
      final xs = ListBatch<int>([for (var i = 1; i <= 20; i++) i]);
      for (var k = 0; k <= 20; k++) {
        final s = sum.combine(sum.fold(xs, 0, k), sum.fold(xs, k, 20));
        expect(sum.finish(s), 210, reason: 'split at $k');
      }
    });

    test('addSlice continues a state: several slices equal one', () {
      var s = sum.empty();
      s = sum.addSlice(s, batch, 0, 2);
      s = sum.addSlice(s, batch, 2, 2);
      s = sum.addSlice(s, batch, 2, 5);
      expect(sum.finish(s), 15);
    });

    test('empty() returns independent states', () {
      final a = sum.empty(), b = sum.empty();
      sum.addSlice(a, batch, 0, 5);
      expect(sum.finish(b), 0);
    });

    test('chunked and sliced runs agree with the whole run', () {
      const agg = _Rows();
      final r = Rng(99);
      for (final b in randomIntBatches(1)) {
        for (var t = 0; t < 6; t++) {
          final bounds = randomBounds(r, b.length);
          expect(runChunked(agg, b, bounds), b.rows, reason: '$bounds');
          expect(runChunked(agg, b, bounds, copy: true), b.rows,
              reason: 'copy $bounds');
          expect(runChunkedRight(agg, b, bounds), b.rows, reason: '$bounds');
          expect(runSliced(agg, b, bounds), b.rows, reason: '$bounds');
        }
      }
    });
  });

  group('map', () {
    test('transforms the result only', () {
      final a = const _SumRows().map((n) => 'n=$n');
      expect(a.runList([1, 2, 3]), 'n=6');
      expect(a.runList(<int>[]), 'n=0');
      expectLawful(a, randomIntBatches(2));
    });

    test('composes', () {
      final a = Count<ListBatch<int>>().map((n) => n * 2).map((n) => n + 1);
      expect(a.runList([7, 7, 7]), 7);
    });

    test('keeps ranges and seams working', () {
      final a = const _SumRows().map((n) => n * 10);
      final b = ListBatch<int>([1, 2, 3, 4]);
      expect(a.finish(a.combine(a.fold(b, 0, 2), a.fold(b, 2, 4))), 100);
      expect(a.finish(a.fold(b, 1, 3)), 50);
    });
  });

  group('both', () {
    final a = both(const _SumRows(), Count<ListBatch<int>>());

    test('runs two aggregators over the same rows', () {
      expect(a.runList([3, 4, 5]), (12, 3));
      expect(a.runList(<int>[]), (0, 0));
    });

    test('nests and stays lawful', () {
      final n = both(a, const _Rows());
      final r = n.runList([3, 9, 5]); // records holding lists compare by identity
      expect(r.$1, (17, 3));
      expect(r.$2, [3, 9, 5]);
      expectLawful(n, randomIntBatches(3), equals: _same);
    });

    test('each side has its own fresh state', () {
      final p = a.addSlice(a.empty(), ListBatch<int>([5]), 0, 1);
      final q = a.empty();
      expect(a.finish(q), (0, 0));
      expect(a.finish(p), (5, 1));
    });

    test('combines across a seam and honours fold ranges', () {
      final b = ListBatch<int>([1, 2, 3, 4]);
      expect(a.finish(a.combine(a.fold(b, 0, 2), a.fold(b, 2, 4))), (10, 4));
      expect(a.finish(a.fold(b, 1, 3)), (5, 2));
    });

    test('Pair is a mutable holder', () {
      final p = Pair<int, String>(1, 'a');
      p.first = 2;
      p.second = 'b';
      expect((p.first, p.second), (2, 'b'));
    });
  });
}
