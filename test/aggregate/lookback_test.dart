// Lookback(k, inner): the inner aggregator sees every length-k window of the
// whole batch exactly once, in order, however the batch is sliced or chunked.
//
// The probe inner records each window it is shown. Per the contract, inner
// .addSlice(s, b, start, end) must itself handle the windows ending at rows
// start+k-1 .. end-1 (reading rows i-k+1..i of b), so the recorder does that
// and nothing else. Row values are their own index, so a window identifies
// itself.

import 'package:openstrap_analytics/aggregate.dart';
import 'package:test/test.dart';

import '../support/aggregator_laws.dart';
import '../support/fold_law_support.dart' show foldBounds;
import '../support/property.dart' show Rng;

typedef _Windows = List<List<double>>;

class _Record extends Aggregator<_Windows, DoubleColumn, _Windows> {
  const _Record(this.k);
  final int k;
  @override
  _Windows empty() => <List<double>>[];
  @override
  _Windows addSlice(_Windows s, DoubleColumn b, int start, int end) {
    for (var i = start + k - 1; i < end; i++) {
      s.add([for (var j = i - k + 1; j <= i; j++) b.values[j]]);
    }
    return s;
  }

  @override
  _Windows combine(_Windows left, _Windows right) => left..addAll(right);
  @override
  _Windows finish(_Windows s) => [for (final w in s) List<double>.of(w)];
}

Lookback<DoubleColumn, _Windows, _Windows> _lookback(int k) =>
    Lookback<DoubleColumn, _Windows, _Windows>(k, _Record(k));

/// n rows whose values are 0, 1, 2, ... (distinct, so windows identify).
DoubleColumn _iota(int n) => col([for (var i = 0; i < n; i++) i * 1.0]);

_Windows _expected(int n, int k) => [
      for (var i = k - 1; i < n; i++)
        [for (var j = i - k + 1; j <= i; j++) j * 1.0]
    ];

bool _same(Object? a, Object? b) => a.toString() == b.toString();

void main() {
  for (final k in [1, 2, 3, 4]) {
    group('k = $k', () {
      final lb = _lookback(k);

      test('a single slice sees every window of the batch', () {
        for (final n in [0, 1, k - 1, k, k + 1, 2 * k, 17]) {
          if (n < 0) continue;
          expect(lb.run(_iota(n)), _expected(n, k), reason: 'n=$n');
        }
      });

      test('a fold range sees only windows inside the range', () {
        final c = _iota(12);
        final got = lb.finish(lb.fold(c, 3, 9));
        expect(got, [
          for (var i = 3 + k - 1; i < 9; i++)
            [for (var j = i - k + 1; j <= i; j++) j * 1.0]
        ]);
      });

      test('every single split point (combine)', () {
        final c = _iota(14);
        for (var s = 0; s <= 14; s++) {
          final r = lb.finish(lb.combine(lb.fold(c, 0, s), lb.fold(c, s, 14)));
          expect(r, _expected(14, k), reason: 'split at $s');
        }
      });

      test('every two-slice cut on the slicing path (addSlice after data)', () {
        final c = _iota(14);
        for (var s = 0; s <= 14; s++) {
          var st = lb.empty();
          st = lb.addSlice(st, c, 0, s);
          st = lb.addSlice(st, c, s, 14);
          expect(lb.finish(st), _expected(14, k), reason: 'cut at $s');
        }
      });

      test('every three-slice cut on both paths', () {
        final c = _iota(10);
        for (var a = 0; a <= 10; a++) {
          for (var b = a; b <= 10; b++) {
            final bounds = [0, a, b, 10];
            expect(runChunked(lb, c, bounds), _expected(10, k),
                reason: 'chunked $bounds');
            expect(runChunkedRight(lb, c, bounds), _expected(10, k),
                reason: 'right $bounds');
            expect(runSliced(lb, c, bounds), _expected(10, k),
                reason: 'sliced $bounds');
            expect(runChunked(lb, c, bounds, copy: true), _expected(10, k),
                reason: 'copies $bounds');
          }
        }
      });

      test('random slicings and chunkings, empty chunks included', () {
        final r = Rng(0x10B0 + k);
        for (var t = 0; t < 80; t++) {
          final n = r.intIn(0, 40);
          final c = _iota(n);
          final b = foldBounds(n, r.intIn(0, 9), r.nextInt(1 << 20),
              special: [0, 1, 2, 3, 4]);
          final want = _expected(n, k);
          expect(runChunked(lb, c, b), want, reason: 'chunked $b n=$n');
          expect(runChunked(lb, c, b, copy: true), want, reason: 'copy $b n=$n');
          expect(runChunkedRight(lb, c, b), want, reason: 'right $b n=$n');
          expect(runSliced(lb, c, b), want, reason: 'sliced $b n=$n');
        }
      });

      test('one row per chunk and per slice', () {
        for (final n in [0, 1, 2, 3, 9]) {
          final c = _iota(n);
          final b = singletonBounds(n);
          expect(runChunked(lb, c, b), _expected(n, k), reason: 'chunks n=$n');
          expect(runChunked(lb, c, b, copy: true), _expected(n, k),
              reason: 'copies n=$n');
          expect(runChunkedRight(lb, c, b), _expected(n, k),
              reason: 'right n=$n');
          expect(runSliced(lb, c, b), _expected(n, k), reason: 'slices n=$n');
        }
      });

      test('empty chunks around and between data change nothing', () {
        final c = _iota(8);
        final want = _expected(8, k);
        expect(runChunked(lb, c, [0, 0, 0, 3, 3, 3, 8, 8]), want);
        expect(runSliced(lb, c, [0, 0, 3, 3, 8, 8]), want);
        expect(
            lb.finish(lb.combine(lb.combine(lb.empty(), lb.fold(c)), lb.empty())),
            want);
        expect(
            lb.finish(lb.combine(lb.fold(c, 0, 4),
                lb.combine(lb.empty(), lb.fold(c, 4, 8)))),
            want);
      });

      test('is lawful', () {
        expectLawful(lb, [for (var n = 0; n <= 12; n++) _iota(n), _iota(40)],
            equals: _same);
      });
    });
  }

  group('chunks shorter than k-1 rows', () {
    test('k = 4: all chunks of 1 or 2 rows, mixed with empties', () {
      final lb = _lookback(4);
      final c = _iota(11);
      final want = _expected(11, 4);
      for (final b in [
        [0, 1, 2, 4, 5, 6, 8, 9, 11],
        [0, 2, 3, 3, 4, 6, 7, 9, 10, 11],
        [0, 1, 1, 2, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11],
      ]) {
        expect(runChunked(lb, c, b), want, reason: '$b');
        expect(runChunked(lb, c, b, copy: true), want, reason: 'copy $b');
        expect(runChunkedRight(lb, c, b), want, reason: 'right $b');
        expect(runSliced(lb, c, b), want, reason: 'sliced $b');
      }
    });

    test('k = 3: a seam of two one-row chunks yields no window by itself', () {
      final lb = _lookback(3);
      final c = _iota(3);
      expect(lb.finish(lb.combine(lb.fold(c, 0, 1), lb.fold(c, 1, 2))), isEmpty);
      final s = lb.combine(
          lb.combine(lb.fold(c, 0, 1), lb.fold(c, 1, 2)), lb.fold(c, 2, 3));
      expect(lb.finish(s), [
        [0.0, 1.0, 2.0]
      ]);
    });

    test('k = 4: no window when the whole batch is shorter than k', () {
      final lb = _lookback(4);
      expect(lb.run(_iota(3)), isEmpty);
      expect(runChunked(lb, _iota(3), [0, 1, 2, 3]), isEmpty);
      expect(runSliced(lb, _iota(3), [0, 1, 2, 3]), isEmpty);
    });
  });

  group('seam batches are tiny', () {
    test('combining two 50-row chunks feeds the inner one seam of 2*(k-1) rows',
        () {
      // The inner records the length of every slice it is handed. The two
      // folds hand it 50 rows each; the combine hands it exactly one more
      // slice: the whole seam batch, last(k-1) + first(k-1) = 4 rows.
      final seen = <int>[];
      final probe = _Spy(3, seen);
      final lb = Lookback<DoubleColumn, _Windows, _Windows>(3, probe);
      final c = _iota(100);
      lb.combine(lb.fold(c, 0, 50), lb.fold(c, 50, 100));
      expect(seen, [50, 50, 4]);
    });
  });

  group('results of the inner pass through', () {
    test('Lookback(2, absolute successive differences)', () {
      final lb = Lookback<DoubleColumn, List<double>, double>(
          2, _AbsDiffSum());
      final c = col([1, 5, 2, 2, 10]);
      expect(lb.run(c), 4 + 3 + 0 + 8);
      expect(lb.run(col([])), 0.0);
      expect(lb.run(col([7])), 0.0);
      expectLawful(lb, randomColumns(0x10B9, nanP: 0),
          equals: fieldsEqual<double>((x) => [x], relTol: 1e-12, absTol: 1e-9));
    });

    test('composes with both and map', () {
      final a = both(
          Lookback<DoubleColumn, _Windows, _Windows>(2, _Record(2)),
          Count<DoubleColumn>()).map((r) => (r.$1.length, r.$2));
      expect(a.run(_iota(5)), (4, 5));
      expect(a.finish(a.combine(a.fold(_iota(5), 0, 2), a.fold(_iota(5), 2, 5))),
          (4, 5));
    });
  });
}

class _Spy extends _Record {
  _Spy(super.k, this.sizes);
  final List<int> sizes;
  @override
  _Windows addSlice(_Windows s, DoubleColumn b, int start, int end) {
    sizes.add(end - start);
    return super.addSlice(s, b, start, end);
  }
}

class _AbsDiffSum extends Aggregator<List<double>, DoubleColumn, double> {
  @override
  List<double> empty() => [0.0];
  @override
  List<double> addSlice(List<double> s, DoubleColumn b, int start, int end) {
    for (var i = start + 1; i < end; i++) {
      s[0] += (b.values[i] - b.values[i - 1]).abs();
    }
    return s;
  }

  @override
  List<double> combine(List<double> l, List<double> r) => l..[0] += r[0];
  @override
  double finish(List<double> s) => s[0];
}
