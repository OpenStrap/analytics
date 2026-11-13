// SumOf<B>(col, f): Neumaier-compensated sum of f(x) over the rows where x is
// not NaN and f(x) is not NaN.
//
// Decisions the implementation follows:
//  * f is never called with NaN (a NaN input row is skipped before f). An
//    infinite input IS passed to f.
//  * f returning NaN skips that row (it does not poison the sum).
//  * The result is a double; nothing counted (or an empty batch) is exactly 0.0.
//  * Compensation is the same as Sum: combine adds the other state's sum and
//    correction, so the compensation survives chunking and addSlice.
//  * Exported from package:openstrap_analytics/aggregate.dart.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:openstrap_analytics/aggregate.dart';
import 'package:test/test.dart';

import '../support/aggregator_laws.dart';
import '../support/property.dart' show Rng;

Float64List _v(DoubleColumn c) => c.values;

const nan = double.nan;

final _tol = fieldsEqual<double>((x) => [x], relTol: 1e-12, absTol: 1e-6);

SumOf<DoubleColumn> _sumOf(double Function(double) f) =>
    SumOf<DoubleColumn>(_v, f);

void main() {
  final id = _sumOf((x) => x);
  final square = _sumOf((x) => x * x);
  // Square root of positives; NaN (skip) for everything else.
  final rootPos = _sumOf((x) => x > 0 ? math.sqrt(x) : nan);

  group('values', () {
    test('plain sums of f(x)', () {
      expect(id.run(col([1.5, 2.5, -1.0])), 3.0);
      expect(square.run(col([1, 2, 3])), 14.0);
      expect(_sumOf((x) => 2 * x + 1).run(col([1, 2, 3])), 15.0);
    });
    test('empty is exactly 0.0, as a double', () {
      final e = square.run(col([]));
      expect(e, 0.0);
      expect(e, isA<double>());
      expect(square.finish(square.empty()), 0.0);
    });
    test('NaN inputs are skipped, all-NaN is 0.0', () {
      expect(square.run(col([1, nan, 2, nan])), 5.0);
      expect(square.run(col([nan, nan])), 0.0);
    });
    test('f is never called with NaN', () {
      final seen = <double>[];
      final spy = _sumOf((x) {
        seen.add(x);
        return x;
      });
      expect(spy.run(col([1, nan, 2, nan, nan, 3])), 6.0);
      expect(seen, [1.0, 2.0, 3.0]);
    });
    test('f returning NaN skips the row', () {
      expect(rootPos.run(col([4, -1, 9, 0, nan, 16])), 9.0);
      expect(rootPos.run(col([-1, -2, 0])), 0.0);
      expect(_sumOf((_) => nan).run(col([1, 2, 3])), 0.0);
    });
    test('an infinite input reaches f', () {
      final finiteOnly = _sumOf((x) => x.isFinite ? x : nan);
      expect(finiteOnly.run(col([1, double.infinity, 2, -double.infinity])),
          3.0);
      expect(id.run(col([1, double.infinity])), double.infinity);
    });
    test('honours the range', () {
      final c = col([1, 2, 3, 4, 5]);
      expect(square.finish(square.fold(c, 1, 4)), 4.0 + 9 + 16);
      expect(square.finish(square.fold(c, 2, 2)), 0.0);
    });
    test('reads the column through the getter, on any batch', () {
      final second = SumOf<ListBatch<(double, double)>>(
          (b) => Float64List.fromList([for (final r in b.rows) r.$2]),
          (x) => x * 10);
      expect(second.runList([(1, nan), (2, 3), (3, 4)]), 70.0);
    });
  });

  group('compensation', () {
    test('ten times 0.1 is exactly 1.0', () {
      expect(id.run(col(List.filled(10, 0.1))), 1.0);
    });
    test('Neumaier: big, small, minus big', () {
      expect(id.run(col([1e16, 1.0, -1e16])), 1.0);
      expect(id.run(col([1.0, 1e16, -1e16])), 1.0);
    });
    test('compensation applies to f(x), not x', () {
      // f(1e8) = 1e16, f(-1e8) = -1e16; the 1.0 would vanish in a naive sum.
      final signedSquare = _sumOf((x) => x >= 0 ? x * x : -(x * x));
      expect(signedSquare.run(col([1e8, 1, -1e8])), 1.0);
    });
    test('survives every split and repeated addSlice', () {
      final c = col([1e16, 1.0, -1e16, 1.0]);
      for (var k = 0; k <= 4; k++) {
        final s = id.combine(id.fold(c, 0, k), id.fold(c, k, 4));
        expect(id.finish(s), 2.0, reason: 'split at $k');
        var one = id.addSlice(id.empty(), c, 0, k);
        one = id.addSlice(one, c, k, 4);
        expect(id.finish(one), 2.0, reason: 'sliced at $k');
      }
    });
    test('finish does not mutate: finish twice, keep adding', () {
      final c = col([1, 2, 3, 4]);
      var s = id.fold(c, 0, 3);
      expect(id.finish(s), 6.0);
      expect(id.finish(s), 6.0);
      s = id.addSlice(s, c, 3, 4);
      expect(id.finish(s), 10.0);
    });
  });

  group('random parity (seeded)', () {
    test('matches Sum of the mapped column under random chunkings', () {
      final r = Rng(0x50F);
      final sum = Sum<DoubleColumn>(_v);
      for (final c in randomColumns(21, count: 25)) {
        final mapped = DoubleColumn(Float64List.fromList([
          for (final x in c.values) x.isNaN || x <= 0 ? nan : math.sqrt(x)
        ]));
        final want = sum.run(mapped);
        for (var t = 0; t < 3; t++) {
          final b = randomBounds(r, c.length);
          for (final got in [
            runChunked(rootPos, c, b),
            runChunked(rootPos, c, b, copy: true),
            runChunkedRight(rootPos, c, b),
            runSliced(rootPos, c, b),
          ]) {
            expect(_tol(got, want), isTrue, reason: '$got vs $want, $b');
          }
        }
      }
    });
  });

  group('lawful', () {
    final cols = randomColumns(22);
    test('identity f', () => expectLawful(id, cols, equals: _tol));
    test('square', () => expectLawful(square, cols, equals: _tol));
    test('f that skips rows', () => expectLawful(rootPos, cols, equals: _tol));
  });
}
