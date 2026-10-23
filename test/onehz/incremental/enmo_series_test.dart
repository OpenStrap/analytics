import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';
import '../support/incremental_compare.dart';
import '../support/incremental_fixtures.dart';

void main() {
  for (final seed in [1, 42, 914]) {
    for (final hz in [.5, 1.0, 2.0]) {
      for (final chunk in [1, 31, 97]) {
        test('ENMO explicit reference seed=$seed hz=$hz chunk=$chunk', () {
          final f = incrementalFixture(
              seed: seed, cadenceHz: hz, originMs: 1700000010000);
          var state = IncrementalEnmoSeries();
          for (final n in prefixSizes(f.accel.length, chunk)) {
            final a = f.accel.sublist(0, n);
            enmoClose(state.sync(a, gRef: 1.013456789, expectedMinutes: 12),
                enmoSeries(a, gRef: 1.013456789, expectedMinutes: 12));
            final work = state.processedPoints;
            state.sync(a, gRef: 1.013456789, expectedMinutes: 12);
            expect(state.processedPoints, work);
            if (n == 31 || n == f.accel.length) {
              state =
                  IncrementalEnmoSeries.fromJson(checkpoint(state.toJson()));
            }
          }
          expect(state.processedPoints, lessThanOrEqualTo(f.accel.length));
        });
      }
    }
  }
  for (final window in [0.0, 1.0, 15.0, 61.5]) {
    for (final minimum in [1, 30, 60]) {
      test('ENMO window=$window coverage minimum=$minimum', () {
        final samples = <AccelSample>[
          for (final t in <double>[
            0.0,
            999,
            1000,
            14999,
            15000,
            59999,
            60000,
            60001,
            119999,
            120000,
            199999
          ])
            AccelSample(t, t % 17 / 30, .1, 1),
        ];
        final state = IncrementalEnmoSeries();
        for (var n = 0; n <= samples.length; n++) {
          final a = samples.sublist(0, n);
          enmoClose(
              state.sync(a,
                  gRef: 1,
                  gravityWindowS: window,
                  minSamplesPerMinute: minimum),
              enmoSeries(a,
                  gRef: 1,
                  gravityWindowS: window,
                  minSamplesPerMinute: minimum));
        }
      });
    }
  }
  test('ENMO auto-calibration recomputes each changing prefix', () {
    final f = incrementalFixture();
    var state = IncrementalEnmoSeries();
    for (final n in prefixSizes(f.accel.length, 29)) {
      final a = f.accel.sublist(0, n);
      enmoClose(state.sync(a), enmoSeries(a));
      state = IncrementalEnmoSeries.fromJson(checkpoint(state.toJson()));
    }
  });
  test('ENMO parameter changes, replace, remove, reorder and force', () {
    final f = incrementalFixture();
    var a = [...f.accel];
    final state = IncrementalEnmoSeries();
    state.sync(a, gRef: 1);
    enmoClose(
        state.sync(a,
            gRef: 1.05,
            gravityWindowS: 31,
            minSamplesPerMinute: 60,
            expectedMinutes: 100),
        enmoSeries(a,
            gRef: 1.05,
            gravityWindowS: 31,
            minSamplesPerMinute: 60,
            expectedMinutes: 100));
    final old = a[7];
    a[7] = AccelSample(old.tsMs, old.x + .07, old.y, old.z);
    enmoClose(state.sync(a, gRef: 1), enmoSeries(a, gRef: 1));
    a = a.sublist(9, 140).reversed.toList();
    enmoClose(state.sync(a, gRef: 1), enmoSeries(a, gRef: 1));
    final work = state.processedPoints;
    enmoClose(state.sync(a, gRef: 1, force: true), enmoSeries(a, gRef: 1));
    expect(state.processedPoints, greaterThan(work));
    enmoClose(state.sync([], gRef: 1), enmoSeries([], gRef: 1));
  });
  test('ENMO duplicate timestamps, invalid samples and constant vector', () {
    final a = <AccelSample>[
      for (var i = 0; i < 80; i++)
        AccelSample((i ~/ 2) * 1000.0, .3, -.4, 1, valid: i % 3 != 0),
      const AccelSample(500, 100, 100, 100, valid: false),
    ];
    final state = IncrementalEnmoSeries();
    enmoClose(state.sync(a, gRef: 1), enmoSeries(a, gRef: 1));
    final invalid =
        a.map((s) => AccelSample(s.tsMs, s.x, s.y, s.z, valid: false)).toList();
    enmoClose(state.sync(invalid), enmoSeries(invalid));
  });
  test('ENMO real capture streamed with batch-calibrated reference', () {
    final f = realIncrementalFixture();
    expect(f.accel.length, 900);
    final g = enmoSeries(f.accel).gRef;
    final state = IncrementalEnmoSeries();
    for (final n in prefixSizes(f.accel.length, 113)) {
      final a = f.accel.sublist(0, n);
      enmoClose(state.sync(a, gRef: g), enmoSeries(a, gRef: g));
    }
  });
}
