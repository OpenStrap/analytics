// LastRows(k): a verbatim copy of the last min(k, n) rows of the whole input,
// null for an empty input. Persistable when batchFromJson is given.

import 'package:openstrap_analytics/aggregate.dart';
import 'package:test/test.dart';

import '../support/aggregator_laws.dart';
import '../support/checkpoint_support.dart';

const nan = double.nan;

List<Object?> _vals(DoubleColumn? c) => [c == null, ...?c?.values];
final _same = fieldsEqual<DoubleColumn?>(_vals); // NaN-aware, exact

LastRows<DoubleColumn> _last(int k) =>
    LastRows<DoubleColumn>(k, batchFromJson: DoubleColumn.fromJson);

void main() {
  group('values', () {
    final x = col([1, 2, 3, 4, 5]);
    test('k = 1, 3, 8 on a longer and a shorter input', () {
      expect(_last(1).run(x)!.values.toList(), [5]);
      expect(_last(3).run(x)!.values.toList(), [3, 4, 5]);
      expect(_last(8).run(x)!.values.toList(), [1, 2, 3, 4, 5]); // n < k
      expect(_last(3).run(col([7, nan]))!.values.toList(), [7, nan]);
    });
    test('empty input is null, also through finish(empty())', () {
      for (final k in [1, 3, 8]) {
        expect(_last(k).run(col([])), isNull);
        expect(_last(k).finish(_last(k).empty()), isNull);
      }
    });
    test('honours the range and returns a copy', () {
      final a = _last(3);
      expect(a.finish(a.fold(x, 0, 4))!.values.toList(), [2, 3, 4]);
      expect(a.finish(a.fold(x, 2, 2)), isNull);
      final got = a.run(x)!;
      got.values[0] = 99;
      expect(x.values.toList(), [1, 2, 3, 4, 5]);
    });
    test('combine keeps the last k of left ++ right', () {
      final a = _last(3);
      List<double> at(int i, int j) => a
          .finish(a.combine(a.fold(x, 0, i), a.fold(x, i, j)))!
          .values
          .toList();
      expect(at(4, 5), [3, 4, 5]); // right has 1 row: 2 from left
      expect(at(2, 5), [3, 4, 5]); // right alone has k rows
      expect(at(3, 4), [2, 3, 4]);
    });
  });

  group('laws', () {
    for (final k in [1, 3, 8]) {
      test('k=$k is lawful (slicing, finishPure, round trip)', () {
        expectLawful(_last(k), randomColumns(40 + k), equals: _same);
      });
    }
  });

  group('persistence', () {
    test('persistable only with batchFromJson', () {
      expect(LastRows<DoubleColumn>(3).persistable, isFalse);
      expect(_last(3).persistable, isTrue);
    });
    test('a mid-stream checkpoint resumes to the one-pass result', () {
      final c = randomColumns(77, count: 1, maxLen: 30).last;
      for (final k in [1, 3, 8]) {
        expectCheckpointResumes(_last(k), col([for (var i = 0; i < 20; i++) i * 1.5]),
            equals: _same);
        expectCheckpointResumes(_last(k), c, equals: _same);
      }
    });
  });
}
