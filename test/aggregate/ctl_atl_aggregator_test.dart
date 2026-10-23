// ctlAtlTsbAggregator must agree with ctlAtlTsb for the same daily series under
// any slicing or chunking, and obey the aggregator laws.
//
// Contract used here:
//  * ctlAtlTsbAggregator({ctlDays = 42, atlDays = 7, minDays = ctlAtlMinDays,
//    primeDays = 7}) is an Aggregator<_, DoubleColumn, Metric<LoadState>>;
//    the column is daily TRIMP, oldest first. Exported from
//    package:openstrap_analytics/aggregate.dart.
//  * Fewer rows than minDays: absent, with the reference's note (the
//    needBaselineNote), tier and inputs_used.
//  * Otherwise ctl / atl / tsb within relTol 1e-9 (absTol 1e-9); confidence,
//    tier, inputs_used and note (which interpolates the prime count
//    min(max(primeDays, 1), rows)) are exactly equal.
//  * Rows are all real days (a rest day is 0, not NaN); NaN input is out of
//    scope. minDays < 1 is out of scope too (the reference throws on an empty
//    series with minDays 0).
//  * primeDays 0 behaves as 1 (reference clamps), primeDays > rows as rows.
//  * Constructing the aggregator never throws for the parameters below.

import 'dart:typed_data';

import 'package:openstrap_analytics/aggregate.dart';
import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

import '../support/checkpoint_support.dart';
import '../support/aggregator_laws.dart';
import '../support/property.dart' show Rng;

typedef _Agg = Aggregator<dynamic, DoubleColumn, Metric<LoadState>>;

List<Object?> _fields(Metric<LoadState> m) => [
      m.present,
      m.value?.ctl,
      m.value?.atl,
      m.value?.tsb,
      m.tier,
      m.inputs_used.join(','),
      m.note,
    ];

final _eq = fieldsEqual<Metric<LoadState>>(_fields, relTol: 1e-9, absTol: 1e-9);

/// _same, as a predicate: the fields within tolerance, confidence exact.
bool _eqExact(Metric<LoadState> got, Metric<LoadState> want) =>
    _eq(got, want) && got.confidence == want.confidence;

void _same(Metric<LoadState> got, Metric<LoadState> want, String tag) {
  expect(_eq(got, want), isTrue,
      reason: '$tag\n got ${_fields(got)}\nwant ${_fields(want)}');
  expect(got.confidence, want.confidence, reason: '$tag confidence');
  expect(got.note, want.note, reason: '$tag note');
}

class _P {
  const _P(this.name, {this.ctl = 42, this.atl = 7, this.min = ctlAtlMinDays, this.prime = 7});
  final String name;
  final double ctl, atl;
  final int min, prime;
  _Agg get agg => ctlAtlTsbAggregator(
      ctlDays: ctl, atlDays: atl, minDays: min, primeDays: prime);
  Metric<LoadState> want(DoubleColumn c) => ctlAtlTsb(c.values.toList(),
      ctlDays: ctl, atlDays: atl, minDays: min, primeDays: prime);
}

const _params = [
  _P('default'),
  _P('custom time constants', ctl: 30, atl: 5, min: 10, prime: 5),
  _P('minDays < primeDays', min: 3, prime: 10),
  _P('minDays 1, primeDays 7', min: 1),
  _P('primeDays 1', prime: 1),
  _P('primeDays 0 acts as 1', prime: 0),
  _P('primeDays 14 = minDays', prime: 14),
  _P('primeDays > minDays', min: 5, prime: 30),
];

void _allPaths(_Agg a, DoubleColumn c, List<int> b, Metric<LoadState> want,
    String tag) {
  _same(runChunked(a, c, b), want, '$tag chunks $b');
  _same(runChunked(a, c, b, copy: true), want, '$tag copies $b');
  _same(runChunkedRight(a, c, b), want, '$tag right $b');
  _same(runSliced(a, c, b), want, '$tag sliced $b');
}

/// A daily-TRIMP-like series: rest days (0), spikes, ordinary workouts.
DoubleColumn _series(Rng r, int n) => DoubleColumn(Float64List.fromList([
      for (var i = 0; i < n; i++)
        r.nextBool(.25)
            ? 0.0
            : r.nextBool(.05)
                ? 300 + r.nextDouble() * 9000
                : r.nextDouble() * 250
    ]));

void main() {
  group('absent below minDays', () {
    test('identical to the reference for every short length', () {
      for (final p in _params) {
        final cols = [
          for (var n = 0; n < p.min && n < 16; n++)
            col([for (var i = 0; i < n; i++) 10.0 + i])
        ];
        for (final c in cols) {
          expect(p.want(c).present, isFalse, reason: '${p.name} n=${c.length}');
        }
        expectConversion<dynamic, DoubleColumn, Metric<LoadState>>(
            (_) => p.agg, cols, p.want,
            equals: _eqExact);
      }
    });

    test('empty state is absent for minDays >= 1', () {
      final a = ctlAtlTsbAggregator();
      _same(a.finish(a.empty()), ctlAtlTsb(<double>[]), 'empty state');
      _same(a.run(col([])), ctlAtlTsb(<double>[]), 'empty column');
    });

    test('length minDays - 1 absent, minDays present (default)', () {
      final a = ctlAtlTsbAggregator();
      expect(a.run(_iotaCol(13)).present, isFalse);
      expect(a.run(_iotaCol(14)).present, isTrue);
      expect(a.run(_iotaCol(14)).note,
          contains('primed from the first 7 observed days'));
    });
  });

  group('values', () {
    test('constant series: ctl = atl = the constant, tsb 0', () {
      final c = col(List.filled(60, 120.0));
      final got = ctlAtlTsbAggregator().run(c);
      expect(got.value!.ctl, closeTo(120, 1e-9));
      expect(got.value!.atl, closeTo(120, 1e-9));
      expect(got.value!.tsb, closeTo(0, 1e-9));
      _same(got, ctlAtlTsb(c.values.toList()), 'constant');
    });

    test('exactly primeDays == rows: the value is the mean', () {
      final p = const _P('p', min: 3, prime: 4);
      final c = col([10, 20, 30, 40]);
      final got = p.agg.run(c);
      expect(got.value!.ctl, closeTo(25, 1e-12));
      expect(got.value!.atl, closeTo(25, 1e-12));
      _same(got, p.want(c), 'mean');
    });

    test('fewer rows than primeDays: prime is the row count', () {
      final p = const _P('p', min: 3, prime: 10);
      final c = col([4, 8, 12, 16, 20]);
      final got = p.agg.run(c);
      expect(got.note, contains('first 5 observed days'));
      _same(got, p.want(c), 'short prime');
    });

    test('primeDays 0 and 1 seed from the first day', () {
      for (final prime in [0, 1]) {
        final p = _P('p', min: 2, prime: prime);
        final c = col([100, 0, 0, 0, 50, 0, 0, 0, 0, 0]);
        _same(p.agg.run(c), p.want(c), 'prime $prime');
        expect(p.agg.run(c).note, contains('first 1 observed days'));
      }
    });

    test('rest days decay the load: all-zero tail', () {
      final c = col([200, 200, 200, 200, 200, 200, 200, ...List.filled(40, 0.0)]);
      final got = ctlAtlTsbAggregator().run(c);
      _same(got, ctlAtlTsb(c.values.toList()), 'decay');
      expect(got.value!.atl, lessThan(got.value!.ctl));
      expect(got.value!.tsb, greaterThan(0));
    });

    test('a single spike on the last day', () {
      final xs = [...List.filled(30, 50.0), 5000.0];
      final c = col(xs);
      _same(ctlAtlTsbAggregator().run(c), ctlAtlTsb(xs), 'spike');
    });

    test('confidence is exact: rows/42 clamped to 0.3..0.85', () {
      final a = ctlAtlTsbAggregator();
      expect(a.run(_iotaCol(14)).confidence, ctlAtlTsb(_iotaCol(14).values.toList()).confidence);
      expect(a.run(_iotaCol(30)).confidence, 30 / 42.0);
      expect(a.run(_iotaCol(300)).confidence, 0.85);
    });
  });

  group('random parity (seeded)', () {
    for (final p in _params) {
      test(p.name, () {
        final r = Rng(0xC71 + p.name.length * 31 + p.min * 7 + p.prime);
        final cols = <DoubleColumn>[];
        for (var t = 0; t < 30; t++) {
          final n = r.nextBool(.2) ? r.intIn(0, 20) : r.intIn(0, 200);
          cols.add(_series(r, n));
        }
        expectConversion<dynamic, DoubleColumn, Metric<LoadState>>(
            (_) => p.agg, cols, p.want,
            equals: _eqExact);
      });
    }

    test('constant series of random lengths and values', () {
      final r = Rng(0xC72);
      final cols = <DoubleColumn>[];
      for (var t = 0; t < 30; t++) {
        final n = r.intIn(0, 120);
        final v = r.nextBool(.3) ? 0.0 : r.nextDouble() * 400;
        cols.add(col(List.filled(n, v)));
      }
      expectConversion<dynamic, DoubleColumn, Metric<LoadState>>(
          (_) => ctlAtlTsbAggregator(), cols, (c) => ctlAtlTsb(c.values.toList()),
          equals: _eqExact);
    });

    test('chunks straddle the prime boundary (primeDays 7)', () {
      final r = Rng(0xC73);
      final a = ctlAtlTsbAggregator();
      final c = _series(r, 40);
      final want = ctlAtlTsb(c.values.toList());
      for (final cut in [1, 2, 6, 7, 8, 13, 14, 15]) {
        _allPaths(a, c, [0, cut, 40], want, 'cut $cut');
        _allPaths(a, c, [0, 3, cut > 3 ? cut : 3, 40], want, 'cuts 3,$cut');
      }
    });
  });

  test('persistable: a mid-stream checkpoint resumes to the one-pass result', () {
    final c = _series(Rng(0xC0DE), 60);
    for (final p in [_params[0], _params[2]]) {
      expectCheckpointResumes(p.agg, c, equals: _eq);
    }
  });

  group('lawful', () {
    final cols = [
      ...randomColumns(0xC74, nanP: 0, maxLen: 60, value: (r) => r.nextDouble() * 300),
      for (final n in [13, 14, 15, 21, 22]) _iotaCol(n),
    ];
    for (final p in [_params[0], _params[2], _params[5]]) {
      test(p.name, () => expectLawful(p.agg, cols, equals: _eq));
    }
  });

  group('composition', () {
    test('both(...) and map still work around it', () {
      final a = both(ctlAtlTsbAggregator(), Count<DoubleColumn>())
          .map((r) => (r.$1.present, r.$2));
      expect(a.run(_iotaCol(20)), (true, 20));
      expect(a.run(_iotaCol(5)), (false, 5));
    });
  });

  group('checkpoint relationships (day count against the primed prefix)', () {
    final agg = ctlAtlTsbAggregator(); // primeDays 7
    // State: [days, {rows: <prefix rows>, tail: [..]}]; rows hold min(days, 7).
    Object? set(Object? s, int days) {
      (s as List)[0] = days;
      return s;
    }

    test('a day count below the prefix rows held is refused', () {
      expectDamagedCheckpointRefused(agg, _iotaCol(10), (s) => set(s, 5));
      expectDamagedCheckpointRefused(agg, _iotaCol(10), (s) => set(s, 0));
    });
    test('a day count above what the prefix rows allow is refused', () {
      expectDamagedCheckpointRefused(agg, _iotaCol(3), (s) => set(s, 9));
      expectDamagedCheckpointRefused(agg, _iotaCol(3), (s) => set(s, 4));
    });
    test('days with no prefix rows are refused', () {
      expectDamagedCheckpointRefused(agg, _iotaCol(10), (s) {
        (((s as List)[1]) as Map)['rows'] = null;
        return s;
      });
    });
    test('prefix rows with no days are refused', () {
      expectDamagedCheckpointRefused(agg, _iotaCol(3), (s) => set(s, 0));
    });
    test('consistent checkpoints still restore', () {
      for (final n in [0, 1, 6, 7, 8, 20]) {
        final b = _iotaCol(n);
        expect(
            decodeCheckpoint<dynamic>(agg, checkpointOf(agg, b),
                kind: 'test', version: 1),
            isNotNull,
            reason: 'n=$n');
      }
    });
  });
}

DoubleColumn _iotaCol(int n) => col([for (var i = 0; i < n; i++) 5.0 + i * 3]);
