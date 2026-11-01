// prsaAggregator must reproduce decelerationCapacity / accelerationCapacity
// (the references, unchanged) under every slicing / chunking, and obey the laws.
//
// Contract: prsaAggregator({required deceleration, l = 2, anchorRatioCap = 0.05})
// folds a DoubleColumn of NN intervals (ms); l < 2 is the reference's absent
// Metric for every input and never throws. Persistable.
//
// Equality: anchors, kind, note, tier, inputs exact; capacity and every profile
// entry within 1e-9 (rel and abs); confidence within 1e-12.

import 'dart:typed_data';

import 'package:openstrap_analytics/aggregate.dart';
import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

import '../support/aggregator_laws.dart';
import '../support/checkpoint_support.dart';
import '../support/property.dart' show Rng;

List<Object?> _exact(Metric<PrsaResult> m) => [
      m.present, m.tier, m.inputs_used.join(','), m.note,
      m.value?.anchors, m.value?.kind, m.value?.profile.length,
    ];
List<Object?> _near(Metric<PrsaResult> m) =>
    [m.value?.capacity, ...?m.value?.profile];

final _same = (Metric<PrsaResult> a, Metric<PrsaResult> b) =>
    fieldsEqual<Metric<PrsaResult>>(_exact)(a, b) &&
    fieldsEqual<Metric<PrsaResult>>(_near, relTol: 1e-9, absTol: 1e-9)(a, b) &&
    (a.confidence - b.confidence).abs() <= 1e-12;

DoubleColumn _c(Iterable<num> x) =>
    DoubleColumn(Float64List.fromList([for (final v in x) v.toDouble()]));

/// Seeded NN series of [n] beats, 700-1100 ms, small steps; [draw] overrides.
List<double> _walk(Rng r, int n) {
  var v = 900.0;
  return [
    for (var i = 0; i < n; i++)
      v = (v + (r.nextDouble() - .5) * 90).clamp(700.0, 1100.0)
  ];
}

List<DoubleColumn> _cases(int seed) {
  final r = Rng(seed);
  return [
    _c([]),
    _c([800]),
    _c(_walk(r, 7)), // short for every l
    _c(_walk(r, 14)),
    for (var i = 0; i < 4; i++) _c(_walk(r, r.intIn(15, 120))),
    _c(_walk(r, 400)),
    _c([for (var i = 0; i < 40; i++) 700 + i * 2.0]), // monotone up
    _c([for (var i = 0; i < 40; i++) 1100 - i * 2.0]), // monotone down
    _c([
      for (final v in _walk(r, 60)) r.nextBool(.15) ? (r.nextBool() ? 0.0 : -v) : v
    ]), // zero / negative values
  ];
}

void main() {
  group('parity with the reference', () {
    for (final dec in [true, false]) {
      for (final l in [2, 3, 5]) {
        for (final cap in [0.05, 0.2]) {
          test('${dec ? 'DC' : 'AC'}, l=$l, cap=$cap', () {
            expectConversion<dynamic, DoubleColumn, Metric<PrsaResult>>(
              (_) => prsaAggregator(
                  deceleration: dec, l: l, anchorRatioCap: cap),
              _cases(l * 100 + (dec ? 1 : 0)),
              (b) {
                final x = b.values.toList();
                return dec
                    ? decelerationCapacity(x, l: l, anchorRatioCap: cap)
                    : accelerationCapacity(x, l: l, anchorRatioCap: cap);
              },
              equals: _same,
              seed: l,
            );
          });
        }
      }
    }
  });

  group('absent cases', () {
    for (final l in [1, 0, -3]) {
      test('l=$l is absent for every input and never throws', () {
        final a = prsaAggregator(deceleration: true, l: l);
        final b = _c(_walk(Rng(l + 9), 50));
        final want = decelerationCapacity(b.values.toList(), l: l);
        expect(want.present, isFalse);
        expect(_same(a.run(b), want), isTrue);
        expect(_same(a.finish(a.empty()), want), isTrue);
        expect(_same(runChunked(a, b, [0, 20, 50]), want), isTrue);
        expect(_same(runSliced(a, b, [0, 0, 30, 50]), want), isTrue);
      });
    }
  });

  test('persistable: a mid-stream checkpoint resumes to the one-pass result', () {
    final agg = prsaAggregator(deceleration: false, l: 3);
    expect(agg.persistable, isTrue);
    expectCheckpointResumes(agg, _c(_walk(Rng(0xBA0E), 300)), equals: _same);
  });

  group('checkpoint relationships (beat count, window length, anchors)', () {
    final agg = prsaAggregator(deceleration: true, l: 2);
    final b = _c(_walk(Rng(0xBA0F), 40));
    // State: [n, lookback]; lookback inner is {profile, anchors}.
    Map lookback(Object? s) => (s as List)[1] as Map;
    Map inner(Object? s) => lookback(s)['inner'] as Map;

    test('the beat count must equal the lookback row count', () {
      for (final n in [10, 39, 41]) {
        expectDamagedCheckpointRefused(agg, b, (s) {
          (s as List)[0] = n;
          return s;
        }, reason: 'n=$n');
      }
    });
    test('more anchors than windows is refused', () {
      // 40 beats hold 40 - 2l = 36 windows with l = 2.
      expectDamagedCheckpointRefused(agg, b, (s) {
        inner(s)['anchors'] = 37;
        return s;
      });
    });
    test('anchors with fewer beats than one window are refused', () {
      final short = _c(_walk(Rng(1), 3));
      expectDamagedCheckpointRefused(agg, short, (s) {
        inner(s)['anchors'] = 1;
        return s;
      });
    });
    test('a consistent checkpoint restores', () {
      expect(
          decodeCheckpoint<dynamic>(agg, checkpointOf(agg, b),
              kind: 'test', version: 1),
          isNotNull);
    });
  });
}
