import 'dart:io';
import 'dart:math' as math;

import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';
import '../support/incremental_compare.dart';

/// Exact equality, not a tolerance: the histogram must return the very double
/// `percentileSorted` returns for the expanded sorted list.
void _same(IntHistogram h, List<double> values, {String? reason}) {
  final sorted = [...values]..sort();
  expect(h.count, values.length, reason: reason);
  for (final p in [0, 1, 5, 25, 30, 33.3, 50, 66.6, 75, 90, 95, 99, 100]) {
    final expected = percentileSorted(sorted, p.toDouble());
    final actual = h.percentile(p.toDouble());
    expect(actual, expected, reason: '$reason p=$p');
  }
  expect(h.median, percentileSorted(sorted, 50), reason: reason);
  expect(h.median, median(values), reason: reason);
}

List<double> _realNightHr() => [
      for (final line in File('test/onehz/fixtures/real_night_2026_07_onehz.csv')
          .readAsLinesSync()
          .skip(1))
        if (line.trim().isNotEmpty) double.parse(line.split(',')[1])
    ];

void main() {
  test('real overnight HR: exact parity at every prefix and few distinct values',
      () {
    final hr = _realNightHr();
    expect(hr.length, greaterThan(20000));
    final h = IntHistogram();
    for (var i = 0; i < hr.length; i++) {
      h.add(hr[i].toInt());
      if (i % 997 == 0 || i == hr.length - 1) {
        _same(h, hr.sublist(0, i + 1), reason: 'prefix ${i + 1}');
      }
    }
    expect(h.distinct, lessThan(80), reason: 'compaction is the point');
  });

  test('real overnight HR: sliding window add/remove stays exact', () {
    final hr = _realNightHr();
    const window = 1800;
    final h = IntHistogram();
    for (var i = 0; i < 6000; i++) {
      h.add(hr[i].toInt());
      if (i >= window) h.remove(hr[i - window].toInt());
      if (i % 251 == 0) {
        _same(h, hr.sublist(math.max(0, i + 1 - window), i + 1),
            reason: 'window ending $i');
      }
    }
  });

  for (final seed in [1, 7, 42, 914]) {
    test('randomized integer data, add/remove sequence seed=$seed', () {
      final rnd = math.Random(seed);
      final h = IntHistogram();
      final values = <double>[];
      for (var step = 0; step < 1500; step++) {
        if (values.isNotEmpty && rnd.nextInt(10) < 4) {
          final v = values.removeAt(rnd.nextInt(values.length));
          h.remove(v.toInt());
        } else {
          // Includes negatives and a wide spread, not just heart rates.
          final v = rnd.nextInt(400) - 100;
          values.add(v.toDouble());
          h.add(v);
        }
        if (step % 7 == 0 || values.length < 6) {
          _same(h, values, reason: 'step $step n=${values.length}');
        }
      }
      while (values.isNotEmpty) {
        h.remove(values.removeLast().toInt());
      }
      _same(h, values);
    });
  }

  test('odd and even counts, single value, all-equal values', () {
    for (final values in [
      [5.0],
      [5.0, 5.0],
      [4.0, 9.0],
      [3.0, 1.0, 2.0],
      [3.0, 1.0, 2.0, 10.0],
      List.filled(7, 61.0),
      [60.0, 60.0, 61.0],
    ]) {
      final h = IntHistogram();
      for (final v in values) {
        h.add(v.toInt());
      }
      _same(h, values, reason: '$values');
    }
  });

  test('p=0 and p=1 hit the extremes; p=100 is not a special case', () {
    final h = IntHistogram();
    final values = [72.0, 55.0, 90.0, 61.0, 61.0];
    for (final v in values) {
      h.add(v.toInt());
    }
    expect(h.percentile(0), 55);
    expect(h.percentile(100), 90);
    expect(h.percentile(1), percentileSorted([...values]..sort(), 1));
    expect(h.percentile(0.5), percentileSorted([...values]..sort(), 0.5));
  });

  test('empty histogram abstains with null, as the batch functions do', () {
    final h = IntHistogram();
    expect(h.count, 0);
    expect(h.distinct, 0);
    expect(h.median, isNull);
    expect(h.median, median(const []));
    expect(h.percentile(0), isNull);
    expect(h.percentile(100), isNull);
    expect(h.percentile(50), percentile(const [], 50));
    h.add(70);
    h.remove(70);
    expect(h.median, isNull, reason: 'emptied again');
    expect(h.distinct, 0, reason: 'no zero-count bins are retained');
  });

  test('add with a repeat count, and removing one of several', () {
    final h = IntHistogram()
      ..add(60, 3)
      ..add(70, 2);
    _same(h, [60, 60, 60, 70, 70]);
    h.remove(60);
    _same(h, [60, 60, 70, 70]);
    expect(h.distinct, 2);
  });

  test('removing a value that is not present throws and changes nothing', () {
    final h = IntHistogram()..add(60);
    expect(() => h.remove(61), throwsStateError);
    expect(() => IntHistogram().remove(1), throwsStateError);
    _same(h, [60]);
  });

  test('rejects values that are not whole numbers and bad arguments', () {
    final h = IntHistogram();
    expect(() => h.add(double.nan), throwsArgumentError);
    expect(() => h.add(double.infinity), throwsArgumentError);
    expect(() => h.add(70.5), throwsArgumentError);
    expect(() => h.add(70, 0), throwsArgumentError);
    expect(() => h.add(70, -1), throwsArgumentError);
    h.add(70.0); // a whole-number double is a whole number
    expect(h.count, 1);
    expect(() => h.percentile(-1), throwsArgumentError);
    expect(() => h.percentile(100.5), throwsArgumentError);
    expect(() => h.percentile(double.nan), throwsArgumentError);
  });

  for (final seed in [3, 11]) {
    test('merge equals one histogram over the concatenation seed=$seed', () {
      final rnd = math.Random(seed);
      final a = [for (var i = 0; i < 300; i++) rnd.nextInt(60) + 40.0];
      final b = [for (var i = 0; i < 211; i++) rnd.nextInt(90) + 30.0];
      final ha = IntHistogram(), hb = IntHistogram();
      for (final v in a) {
        ha.add(v.toInt());
      }
      for (final v in b) {
        hb.add(v.toInt());
      }
      ha.merge(hb);
      _same(ha, [...a, ...b]);
      _same(hb, b, reason: 'the argument is left unchanged');
      ha.merge(IntHistogram());
      _same(ha, [...a, ...b], reason: 'merging empty is a no-op');
      final empty = IntHistogram()..merge(hb);
      _same(empty, b, reason: 'merging into empty');
      empty.merge(empty);
      _same(empty, [...b, ...b], reason: 'merging with itself doubles counts');
    });
  }

  test('checkpoint round-trips and continues; malformed input throws', () {
    final h = IntHistogram();
    final values = <double>[];
    for (final v in [70, 70, 64, 91, 64, 64, 120]) {
      h.add(v);
      values.add(v.toDouble());
    }
    final back = IntHistogram.fromJson(checkpoint(h.toJson()));
    _same(back, values);
    back.add(55);
    values.add(55);
    _same(back, values);
    for (final bad in <Map<String, dynamic>>[
      {},
      {'version': 2, 'type': 'IntHistogram', 'values': [], 'counts': []},
      {'version': 1, 'type': 'RunningMoments', 'values': [], 'counts': []},
      {'version': 1, 'type': 'IntHistogram', 'values': [1, 2], 'counts': [1]},
      {'version': 1, 'type': 'IntHistogram', 'values': [2, 1], 'counts': [1, 1]},
      {'version': 1, 'type': 'IntHistogram', 'values': [1, 1], 'counts': [1, 1]},
      {'version': 1, 'type': 'IntHistogram', 'values': [1], 'counts': [0]},
      {'version': 1, 'type': 'IntHistogram', 'values': [1.5], 'counts': [1]},
    ]) {
      expect(() => IntHistogram.fromJson(bad), throwsFormatException,
          reason: '$bad');
    }
  });
}
