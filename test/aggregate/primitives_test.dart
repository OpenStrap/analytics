// Primitives: known values (NaN skipping, empty gives the identity result),
// then the laws on seeded random columns.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:openstrap_analytics/aggregate.dart';
import 'package:openstrap_analytics/onehz.dart' show RunningMoments;
import 'package:test/test.dart';

import '../support/aggregator_laws.dart';
import '../support/property.dart' show Rng;

Float64List _v(DoubleColumn c) => c.values;

const nan = double.nan;

List<Object?> _momentFields(RunningMoments m) =>
    [m.count, m.mean, m.sampleSd, m.populationSd];

// Aggregators over DoubleColumn.
final _count = Count<DoubleColumn>();
final _finite = CountFinite<DoubleColumn>(_v);
final _positive = CountWhere<DoubleColumn>(_v, (x) => x > 0);
final _sum = Sum<DoubleColumn>(_v);
final _sumSq = SumSq<DoubleColumn>(_v);
final _min = Min<DoubleColumn>(_v);
final _max = Max<DoubleColumn>(_v);
final _moments = Moments<DoubleColumn>(_v);

/// Every split point of [c] recombines to [want] (compared by [eq]).
void _splitsAgree<S, R>(Aggregator<S, DoubleColumn, R> a, DoubleColumn c,
    bool Function(R, R) eq) {
  final want = a.run(c);
  for (var k = 0; k <= c.length; k++) {
    final got = a.finish(a.combine(a.fold(c, 0, k), a.fold(c, k, c.length)));
    expect(eq(got, want), isTrue, reason: 'split at $k: $got vs $want');
  }
}

void main() {
  final cols = randomColumns(11);
  final pos = randomColumns(12, nanP: .1, value: (r) => 1 + r.nextDouble() * 100);
  final ints = randomIntBatches(13);

  group('Count', () {
    test('counts rows, NaN included', () {
      expect(_count.run(col([1, nan, 3])), 3);
      expect(_count.run(col([])), 0);
      expect(Count<ListBatch<String>>().runList(['a', 'b']), 2);
    });
    test('honours the range', () {
      final c = col([1, 2, 3, 4, 5]);
      expect(_count.finish(_count.fold(c, 1, 4)), 3);
      expect(_count.finish(_count.fold(c, 2, 2)), 0);
    });
  });

  group('CountFinite and CountWhere', () {
    test('CountFinite skips NaN', () {
      expect(_finite.run(col([1, nan, 3, nan])), 2);
      expect(_finite.run(col([nan, nan])), 0);
      expect(_finite.run(col([])), 0);
    });
    test('CountWhere counts non-NaN rows passing the test', () {
      expect(_positive.run(col([-1, 2, nan, 3, 0])), 2);
      expect(_positive.run(col([])), 0);
      // NaN is skipped before the test, even for a test NaN would pass.
      final notPos = CountWhere<DoubleColumn>(_v, (x) => !(x > 0));
      expect(notPos.run(col([-1, nan, 5, 0])), 2);
    });
    test('both use the column getter', () {
      final second = CountFinite<ListBatch<(double, double)>>(
          (b) => Float64List.fromList([for (final r in b.rows) r.$2]));
      expect(second.runList([(1, nan), (2, 3), (3, 4)]), 2);
    });
  });

  group('Sum', () {
    test('plain sums, empty is exactly 0.0', () {
      expect(_sum.run(col([1.5, 2.5, -1.0])), 3.0);
      final e = _sum.run(col([]));
      expect(e, 0.0);
      expect(e, isA<double>());
    });
    test('skips NaN; all-NaN is 0.0', () {
      expect(_sum.run(col([1, nan, 2, nan])), 3.0);
      expect(_sum.run(col([nan, nan])), 0.0);
    });
    test('is compensated: ten times 0.1 is exactly 1.0', () {
      expect(_sum.run(col(List.filled(10, 0.1))), 1.0);
    });
    test('is Neumaier compensated (big, small, minus big)', () {
      expect(_sum.run(col([1e16, 1.0, -1e16])), 1.0);
      expect(_sum.run(col([1.0, 1e16, -1e16])), 1.0);
    });
    test('compensation survives chunking and repeated addSlice', () {
      final c = col([1e16, 1.0, -1e16, 1.0]);
      for (var k = 0; k <= 4; k++) {
        final s = _sum.combine(_sum.fold(c, 0, k), _sum.fold(c, k, 4));
        expect(_sum.finish(s), 2.0, reason: 'split at $k');
        var one = _sum.addSlice(_sum.empty(), c, 0, k);
        one = _sum.addSlice(one, c, k, 4);
        expect(_sum.finish(one), 2.0, reason: 'sliced at $k');
      }
    });
    test('finish does not mutate: finish twice, keep adding', () {
      final c = col([1, 2, 3, 4]);
      var s = _sum.fold(c, 0, 3);
      expect(_sum.finish(s), 6.0);
      expect(_sum.finish(s), 6.0);
      s = _sum.addSlice(s, c, 3, 4);
      expect(_sum.finish(s), 10.0);
    });
  });

  group('SumSq', () {
    test('sums squares, skips NaN, empty is 0.0', () {
      expect(_sumSq.run(col([1, -2, 3])), 14.0);
      expect(_sumSq.run(col([2, nan, 3])), 13.0);
      expect(_sumSq.run(col([])), 0.0);
      expect(_sumSq.run(col([nan])), 0.0);
    });
  });

  group('Min and Max', () {
    test('values', () {
      final c = col([3, -1, 2]);
      expect(_min.run(c), -1.0);
      expect(_max.run(c), 3.0);
      expect(_min.run(col([7])), 7.0);
      expect(_max.run(col([-4, -9])), -4.0);
    });
    test('null when no finite row', () {
      expect(_min.run(col([])), isNull);
      expect(_max.run(col([])), isNull);
      expect(_min.run(col([nan, nan])), isNull);
      expect(_max.run(col([nan])), isNull);
    });
    test('NaN rows are skipped', () {
      final c = col([nan, 5, nan, 2, 9, nan]);
      expect(_min.run(c), 2.0);
      expect(_max.run(c), 9.0);
    });
    test('empty and all-NaN sides of a seam change nothing', () {
      final full = col([4, 2]);
      final nans = col([nan, nan]);
      expect(_max.finish(_max.combine(_max.empty(), _max.fold(full))), 4.0);
      expect(_max.finish(_max.combine(_max.fold(full), _max.empty())), 4.0);
      expect(_max.finish(_max.combine(_max.fold(nans), _max.fold(full))), 4.0);
      expect(_min.finish(_min.combine(_min.fold(full), _min.fold(nans))), 2.0);
      expect(_max.finish(_max.combine(_max.empty(), _max.empty())), isNull);
      expect(_min.finish(_min.combine(_min.fold(nans), _min.fold(nans))), isNull);
    });
  });

  group('Moments', () {
    test('textbook sample', () {
      final m = _moments.run(col([2, 4, 4, 4, 5, 5, 7, 9]));
      expect(m.count, 8);
      expect(m.mean, closeTo(5.0, 1e-12));
      expect(m.populationSd, closeTo(2.0, 1e-12));
      expect(m.sampleSd, closeTo(math.sqrt(32 / 7), 1e-12));
    });
    test('empty, one value, all NaN', () {
      final e = _moments.run(col([]));
      expect((e.count, e.mean, e.sampleSd), (0, null, null));
      final one = _moments.run(col([4]));
      expect((one.count, one.mean, one.sampleSd), (1, 4.0, null));
      final n = _moments.run(col([nan, nan]));
      expect((n.count, n.mean), (0, null));
    });
    test('skips NaN rows', () {
      final m = _moments.run(col([nan, 2, 4, nan, 6]));
      expect(m.count, 3);
      expect(m.mean, closeTo(4.0, 1e-12));
      expect(m.sampleSd, closeTo(2.0, 1e-12));
    });
    test('merged across a seam matches the whole', () {
      final c = col([for (var i = 0; i < 30; i++) math.sin(i) * 100 + 500]);
      final whole = _moments.run(c);
      for (final k in [0, 1, 15, 29, 30]) {
        final r = _moments
            .finish(_moments.combine(_moments.fold(c, 0, k), _moments.fold(c, k, 30)));
        expect(r.count, whole.count);
        expect(r.mean, closeTo(whole.mean!, 1e-9));
        expect(r.sampleSd, closeTo(whole.sampleSd!, 1e-9));
      }
    });
  });

  group('First and Last', () {
    final first = First<ListBatch<String>>(), last = Last<ListBatch<String>>();

    test('a one-row copy, null when empty', () {
      final f = first.runList(['x', 'y', 'z'])!;
      final l = last.runList(['x', 'y', 'z'])!;
      expect(f.rows, ['x']);
      expect(l.rows, ['z']);
      expect(first.runList([]), isNull);
      expect(last.runList([]), isNull);
    });
    test('work on a column and on a range', () {
      final c = col([10, 20, 30, 40]);
      expect(First<DoubleColumn>().run(c)!.values, [10.0]);
      expect(Last<DoubleColumn>().run(c)!.values, [40.0]);
      final f = First<DoubleColumn>(), l = Last<DoubleColumn>();
      expect(f.finish(f.fold(c, 1, 3))!.values, [20.0]);
      expect(l.finish(l.fold(c, 1, 3))!.values, [30.0]);
      expect(f.finish(f.fold(c, 2, 2)), isNull);
    });
    test('the copy does not alias the source', () {
      final v = Float64List.fromList([1, 2, 3]);
      final l = Last<DoubleColumn>().run(DoubleColumn(v))!;
      v[2] = 99;
      expect(l.values, [3.0]);
    });
    test('keep a seam in order, skipping empty chunks', () {
      final f = First<DoubleColumn>(), l = Last<DoubleColumn>();
      final c = col([10, 20, 30]);
      final fs = f.combine(f.combine(f.fold(c, 0, 0), f.fold(c, 0, 2)), f.fold(c, 2, 3));
      expect(f.finish(fs)!.values, [10.0]);
      final ls = l.combine(l.combine(l.fold(c, 0, 2), l.fold(c, 2, 3)), l.fold(c, 3, 3));
      expect(l.finish(ls)!.values, [30.0]);
    });
  });

  group('every primitive is lawful on seeded random cases', () {
    final tol = fieldsEqual<double>((x) => [x], relTol: 1e-12, absTol: 1e-6);
    List<Object?> batchFields(DoubleColumn? b) =>
        b == null ? [null] : [b.length, ...b.values];

    test('Count', () => expectLawful(_count, cols));
    test('CountFinite', () => expectLawful(_finite, cols));
    test('CountWhere', () => expectLawful(_positive, cols));
    test('Sum', () => expectLawful(_sum, cols, equals: tol));
    test('SumSq', () => expectLawful(_sumSq, cols, equals: tol));
    test('Min', () => expectLawful(_min, cols));
    test('Max', () => expectLawful(_max, cols));
    test('Moments (tolerance)', () {
      expectLawful(_moments, pos,
          equals: fieldsEqual<RunningMoments>(_momentFields,
              relTol: 1e-9, absTol: 1e-9));
    });
    test('First', () {
      expectLawful(First<DoubleColumn>(), cols,
          equals: fieldsEqual<DoubleColumn?>(batchFields));
      expectLawful(First<ListBatch<int>>(), ints,
          equals: (a, b) => a?.rows.toString() == b?.rows.toString());
    });
    test('Last', () {
      expectLawful(Last<DoubleColumn>(), cols,
          equals: fieldsEqual<DoubleColumn?>(batchFields));
      expectLawful(Last<ListBatch<int>>(), ints,
          equals: (a, b) => a?.rows.toString() == b?.rows.toString());
    });
    test('both of primitives with mixed result types', () {
      expectLawful(
          both(_min, _count).map((r) => [r.$1, r.$2]), cols,
          equals: (a, b) => a.toString() == b.toString());
    });
    test('splits agree on a column with NaN gaps', () {
      final r = Rng(5);
      final c = col([
        for (var i = 0; i < 25; i++) r.nextBool(.3) ? nan : r.intIn(-9, 9) * 1.0
      ]);
      _splitsAgree<dynamic, int>(_finite, c, (a, b) => a == b);
      _splitsAgree<dynamic, double?>(_max, c, (a, b) => a == b);
    });
  });
}
