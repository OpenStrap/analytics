// banisterTrimpAggregator must agree with banisterTrimp for the same rows under
// any slicing or chunking, and obey the aggregator laws.
//
// Contract used here:
//  * banisterTrimpAggregator({restingHr, maxHr, sex}) is an
//    Aggregator<_, DoubleColumn, Metric<double>>; the column is the per-minute
//    HR (NaN = missing). Exported from package:openstrap_analytics/aggregate.dart.
//  * Anchors null / NaN / infinite, or maxHr <= restingHr: absent, for any rows
//    (the note, tier and inputs_used equal banisterTrimp's).
//  * Valid anchors and ZERO rows: absent (banisterTrimp's hrPerMin.isEmpty).
//  * Valid anchors and at least one row, all of them non-finite or <= 0:
//    PRESENT with value 0.0 and confidence 0.6. "Zero rows" means length 0 of
//    the whole batch, not "no finite row".
//  * value within relTol 1e-12; present, confidence, tier, inputs_used and
//    note equal.
//  * Constructing the aggregator never throws, whatever the anchors are.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:openstrap_analytics/aggregate.dart';
import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

import '../support/checkpoint_support.dart';
import '../support/aggregator_laws.dart';
import '../support/property.dart' show Rng;

const nan = double.nan;
const inf = double.infinity;

typedef _Agg = Aggregator<dynamic, DoubleColumn, Metric<double>>;

List<Object?> _fields(Metric<double> m) => [
      m.present,
      m.value,
      m.confidence,
      m.tier,
      m.inputs_used.join(','),
      m.note,
    ];

final _eq = fieldsEqual<Metric<double>>(_fields, relTol: 1e-12);

void _same(Metric<double> got, Metric<double> want, String tag) {
  expect(_eq(got, want), isTrue,
      reason: '$tag\n got ${_fields(got)}\nwant ${_fields(want)}');
}

_Agg _agg(double? rest, double? max, Sex sex) =>
    banisterTrimpAggregator(restingHr: rest, maxHr: max, sex: sex);

Metric<double> _want(DoubleColumn c, double? rest, double? max, Sex sex) =>
    banisterTrimp(c.values, restingHr: rest, maxHr: max, sex: sex);

double _hr(Rng r) {
  final k = r.nextDouble();
  if (k < .04) return 0;
  if (k < .08) return -r.nextDouble() * 50;
  if (k < .10) return inf;
  if (k < .12) return -inf;
  if (k < .30) return 30 + r.nextDouble() * 30; // around / below resting
  if (k < .35) return 190 + r.nextDouble() * 40; // above max
  return 50 + r.nextDouble() * 140;
}

DoubleColumn _hrColumn(Rng r, int n, {double nanP = .1}) =>
    DoubleColumn(Float64List.fromList(
        [for (var i = 0; i < n; i++) r.nextBool(nanP) ? nan : _hr(r)]));

void main() {
  group('absent cases', () {
    final rows = col([60, 100, 150, 120]);
    final badAnchors = <String, (double?, double?)>{
      'null resting': (null, 190),
      'null max': (55, null),
      'both null': (null, null),
      'NaN resting': (nan, 190),
      'NaN max': (55, nan),
      'infinite resting': (-inf, 190),
      'infinite max': (55, inf),
      'max == resting': (60, 60),
      'max < resting': (80, 70),
    };
    badAnchors.forEach((name, a) {
      for (final sex in Sex.values) {
        test('$name (${sex.name}): absent, same note as banisterTrimp', () {
          final want = _want(rows, a.$1, a.$2, sex);
          expect(want.present, isFalse);
          final agg = _agg(a.$1, a.$2, sex);
          // Empty and non-finite-only input are absent too, anchors rule.
          expectConversion<dynamic, DoubleColumn, Metric<double>>(
              (_) => agg,
              [rows, col([]), col([nan, 0, -5])],
              (c) => _want(c, a.$1, a.$2, sex),
              equals: _eq);
        });
      }
    });

    test('valid anchors, zero rows: absent', () {
      for (final sex in Sex.values) {
        final agg = _agg(55, 190, sex);
        final want = _want(col([]), 55, 190, sex);
        expect(want.present, isFalse);
        _same(agg.run(col([])), want, 'empty');
        _same(agg.finish(agg.empty()), want, 'empty state');
        _same(
            agg.finish(agg.combine(
                agg.fold(col([]), 0, 0), agg.fold(col([]), 0, 0))),
            want,
            'empty combined');
      }
    });

    test('rows that all vanish in a chunk still count as rows', () {
      // 3 rows, none usable: PRESENT 0.0 (not absent) however it is cut.
      final c = col([nan, 0, -3]);
      for (final sex in Sex.values) {
        final agg = _agg(55, 190, sex);
        final want = _want(c, 55, 190, sex);
        expect(want.present, isTrue);
        expect(want.value, 0.0);
        expectConversion<dynamic, DoubleColumn, Metric<double>>(
            (_) => agg, [c], (c) => _want(c, 55, 190, sex),
            equals: _eq, chunkings: 24);
      }
    });
  });

  group('present with 0.0 when no row counts', () {
    final cases = <String, DoubleColumn>{
      'one NaN': col([nan]),
      'one zero': col([0]),
      'one negative': col([-40]),
      'infinities': col([inf, -inf]),
      'mixed junk': col([nan, 0, -1, inf, -inf, nan]),
    };
    cases.forEach((name, c) {
      for (final sex in Sex.values) {
        test('$name (${sex.name})', () {
          final want = _want(c, 55, 190, sex);
          expect(want.present, isTrue);
          expect(want.value, 0.0);
          expect(want.confidence, 0.6);
          final got = _agg(55, 190, sex).run(c);
          _same(got, want, name);
          expect(got.value, 0.0);
          expect(got.confidence, 0.6);
        });
      }
    });
  });

  group('values', () {
    test('hand-worked: resting is 0, max is 0.64 e^1.92 (male)', () {
      final a = _agg(50, 190, Sex.male);
      expect(a.run(col([50])).value, 0.0);
      expect(a.run(col([190])).value, closeTo(0.64 * math.exp(1.92), 1e-12));
      // Clamped: below resting counts 0 (but is still a present row), above
      // max counts as max.
      expect(a.run(col([40, 250])).value,
          closeTo(0.64 * math.exp(1.92), 1e-12));
    });
    test('hand-worked: female coefficients 0.86 and 1.67', () {
      final a = _agg(50, 190, Sex.female);
      expect(a.run(col([190])).value, closeTo(0.86 * math.exp(1.67), 1e-12));
      final x = (120 - 50) / 140;
      expect(a.run(col([120])).value,
          closeTo(x * 0.86 * math.exp(1.67 * x), 1e-12));
    });
    test('metadata equals the reference on a plain day', () {
      final c = col([60, 70, 90, 120, 150, 100]);
      for (final sex in Sex.values) {
        final got = _agg(55, 190, sex).run(c);
        final want = _want(c, 55, 190, sex);
        expect(got.confidence, 0.6);
        expect(got.tier, want.tier);
        expect(got.inputs_used, want.inputs_used);
        expect(got.note, want.note);
        _same(got, want, 'plain');
      }
    });
    test('sexes differ', () {
      final c = col([150, 160]);
      expect(_agg(55, 190, Sex.male).run(c).value,
          isNot(_agg(55, 190, Sex.female).run(c).value));
    });
  });

  group('random parity (seeded)', () {
    test('random anchors, sex, rows; every evaluation path', () {
      final r = Rng(0x7217);
      final params = Map<DoubleColumn, (double?, double?, Sex)>.identity();
      for (var t = 0; t < 120; t++) {
        final n = r.nextBool(.15) ? r.intIn(0, 3) : r.intIn(0, 300);
        final c = _hrColumn(r, n, nanP: r.nextBool() ? .05 : .4);
        // Mostly valid anchors; sometimes degenerate.
        double? rest = 40 + r.nextDouble() * 40;
        double? max = rest + (r.nextBool(.1) ? -5 : 60) + r.nextDouble() * 80;
        if (r.nextBool(.05)) rest = null;
        if (r.nextBool(.05)) max = nan;
        params[c] = (rest, max, r.nextBool() ? Sex.male : Sex.female);
      }
      expectConversion<dynamic, DoubleColumn, Metric<double>>(
          (c) => _agg(params[c]!.$1, params[c]!.$2, params[c]!.$3),
          params.keys.toList(),
          (c) => _want(c, params[c]!.$1, params[c]!.$2, params[c]!.$3),
          equals: _eq);
    });
  });

  test('persistable: a mid-stream checkpoint resumes to the one-pass result', () {
    final a = _agg(55, 190, Sex.male);
    expectCheckpointResumes(a, _hrColumn(Rng(0xC0DE), 120), equals: _eq);
  });

  group('lawful', () {
    final cols = [
      ...randomColumns(31, value: _hr, nanP: .1),
      col([nan, 0, -2]),
      col([inf, 120]),
    ];
    for (final sex in Sex.values) {
      test('valid anchors (${sex.name})',
          () => expectLawful(_agg(55, 190, sex), cols, equals: _eq));
    }
    test('invalid anchors',
        () => expectLawful(_agg(null, 190, Sex.male), cols, equals: _eq));
  });
}
