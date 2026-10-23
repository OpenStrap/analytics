import 'dart:math' as math;

import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';
import '../support/incremental_compare.dart';
import '../support/incremental_fixtures.dart';

void main() {
  test('HRV jitter gate refuses only successive-difference outputs', () {
    final jitter = incrementalFixture(seed: 42, jitter: true, gaps: false);
    final oracle = hrvTime(jitter.nn, nnTimesMs: jitter.times);
    expect(oracle.value!.diffAcf1, lessThan(kNnDiffAcf1Floor));
    expect(oracle.value!.rmssd, isNull);
    expect(oracle.value!.pnn50, isNull);
    expect(oracle.value!.sdnn, isNotNull);
    expect(oracle.value!.sdann, isNotNull);
    hrvClose(
        IncrementalHrvTime().sync(jitter.nn, nnTimesMs: jitter.times), oracle);
  });
  for (final seed in [1, 42, 914]) {
    for (final jitter in [false, true]) {
      for (final chunk in [1, 37, 251]) {
        test(
            'HRV seams and evolving bins seed=$seed jitter=$jitter chunk=$chunk',
            () {
          final f = incrementalFixture(seed: seed, jitter: jitter);
          var state = IncrementalHrvTime();
          for (final n in prefixSizes(f.nn.length, chunk)) {
            final nn = f.nn.sublist(0, n), t = f.times.sublist(0, n);
            hrvClose(state.sync(nn, nnTimesMs: t, artifactFraction: .17),
                hrvTime(nn, nnTimesMs: t, artifactFraction: .17));
            final work = state.processedPoints;
            state.sync(nn, nnTimesMs: t, artifactFraction: .17);
            expect(state.processedPoints, work);
            if (n % 37 == 0 || n == f.nn.length) {
              state = IncrementalHrvTime.fromJson(checkpoint(state.toJson()));
            }
          }
          expect(state.processedPoints, lessThanOrEqualTo(f.nn.length + 2));
        });
      }
    }
  }
  for (final origin in [0.0, 299999.5, 1700000010123.125]) {
    test('HRV five-minute exact boundaries and shifted origin=$origin', () {
      final nn = List<double>.generate(610, (i) => 900 + (i % 11) * 7.0);
      final t = List<double>.generate(610, (i) => origin + i * 1000);
      final state = IncrementalHrvTime();
      for (final n in [2, 299, 300, 301, 302, 599, 600, 601, 602, 610]) {
        final y = nn.sublist(0, n), ts = t.sublist(0, n);
        hrvClose(state.sync(y, nnTimesMs: ts), hrvTime(y, nnTimesMs: ts));
      }
    });
  }
  for (final artifacts in [0.0, .15, .8, 1.0]) {
    test('HRV artifact confidence reprice=$artifacts', () {
      final f = incrementalFixture();
      final state = IncrementalHrvTime();
      state.sync(f.nn, nnTimesMs: f.times);
      hrvClose(
          state.sync(f.nn, nnTimesMs: f.times, artifactFraction: artifacts),
          hrvTime(f.nn, nnTimesMs: f.times, artifactFraction: artifacts));
    });
  }
  test('HRV replacements, dropped prefix and force rebuild', () {
    final f = incrementalFixture();
    var nn = [...f.nn], times = [...f.times];
    final state = IncrementalHrvTime();
    state.sync(nn, nnTimesMs: times);
    nn[119] += 60;
    hrvClose(state.sync(nn, nnTimesMs: times), hrvTime(nn, nnTimesMs: times));
    times[113] += 18000;
    hrvClose(state.sync(nn, nnTimesMs: times), hrvTime(nn, nnTimesMs: times));
    nn = nn.sublist(27, 700);
    times = times.sublist(27, 700);
    hrvClose(state.sync(nn, nnTimesMs: times), hrvTime(nn, nnTimesMs: times));
    final work = state.processedPoints;
    hrvClose(state.sync(nn, nnTimesMs: times, force: true),
        hrvTime(nn, nnTimesMs: times));
    expect(state.processedPoints - work, nn.length);
    hrvClose(state.sync(nn), hrvTime(nn));
    hrvClose(state.sync(nn, nnTimesMs: [1]), hrvTime(nn, nnTimesMs: [1]));
  });
  test('HRV constant series, singleton, empty and all separated seams', () {
    final state = IncrementalHrvTime();
    for (final n in [0, 1, 2, 29, 30, 31, 32, 80]) {
      final nn = List<double>.filled(n, 800);
      final times = List<double>.generate(n, (i) => i * 5000.0);
      hrvClose(state.sync(nn), hrvTime(nn));
      hrvClose(state.sync(nn, nnTimesMs: times), hrvTime(nn, nnTimesMs: times));
    }
  });
  // Below the ACF floor upstream's hrvTime reads the difference runs: a
  // respiratory line on a low floor exempts the night, and a refused night may
  // publish from the windows on a breathing line steady in Hz. Both are batch
  // decisions the stream must reproduce at every prefix.
  ({List<double> nn, List<double> t}) breathing(
      {required double hours,
      required double baseMs,
      required double driftMs,
      required double breathMs,
      required double breathHz,
      required double jitterMs}) {
    final r = math.Random(7);
    final nn = <double>[], t = <double>[];
    var clock = 0.0;
    while (clock < hours * 3.6e6) {
      final v = baseMs +
          driftMs * clock / (hours * 3.6e6) +
          breathMs * math.sin(2 * math.pi * breathHz * clock / 1000) +
          jitterMs * (r.nextDouble() - .5);
      clock += v;
      nn.add(v);
      t.add(clock);
    }
    return (nn: nn, t: t);
  }

  for (final (name, x, note) in [
    (
      'a respiratory line exempts the night',
      breathing(
          hours: 1, baseMs: 1350, driftMs: 80, breathMs: 40, breathHz: .3,
          jitterMs: 3),
      'PRV not ECG-HRV; RMSSD/pNN50',
    ),
    (
      'a refused night publishes from a breathing line steady in Hz',
      breathing(
          hours: 2.5, baseMs: 900, driftMs: 400, breathMs: 10, breathHz: .25,
          jitterMs: 40),
      'breathing line steady in Hz',
    ),
  ]) {
    test('HRV below the ACF floor: $name', () {
      final whole = hrvTime(x.nn, nnTimesMs: x.t);
      expect(whole.value!.diffAcf1, lessThan(kNnDiffAcf1Floor),
          reason: 'the fixture is under the floor');
      expect(whole.value!.rmssd, isNotNull, reason: 'and the batch publishes');
      expect(whole.note, contains(note), reason: 'by the path named');
      var state = IncrementalHrvTime();
      for (final n in prefixSizes(x.nn.length, 701)) {
        final nn = x.nn.sublist(0, n), t = x.t.sublist(0, n);
        hrvClose(state.sync(nn, nnTimesMs: t), hrvTime(nn, nnTimesMs: t));
        state = IncrementalHrvTime.fromJson(checkpoint(state.toJson()));
      }
    });
  }
  test('HRV real capture chunk parity includes cleaned beat times', () {
    final f = realIncrementalFixture();
    expect(f.nn.length, greaterThan(300));
    final state = IncrementalHrvTime();
    for (final n in prefixSizes(f.nn.length, 149)) {
      final nn = f.nn.sublist(0, n), t = f.times.sublist(0, n);
      hrvClose(state.sync(nn, nnTimesMs: t), hrvTime(nn, nnTimesMs: t));
    }
  });
}
