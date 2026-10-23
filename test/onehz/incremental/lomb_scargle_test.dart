import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';
import '../support/incremental_compare.dart';
import '../support/incremental_fixtures.dart';

void main() {
  final frequencies = [0.0, .0033, .01, .04, .07, .1, .15, .25, .4];
  for (final seed in [1, 42, 914]) {
    for (final chunk in [1, 17, 128]) {
      test('Lomb prefixes and checkpoint seed=$seed chunk=$chunk', () {
        final f = incrementalFixture(seed: seed, beats: 160);
        final t = f.times.map((x) => x / 1000).toList();
        var state = IncrementalLombScargle(frequencies);
        for (final n in prefixSizes(t.length, chunk)) {
          final ts = t.sublist(0, n), y = f.nn.sublist(0, n);
          spectrumClose(state.sync(ts, y), lombScargle(ts, y, frequencies));
          final work = state.processedPoints;
          spectrumClose(state.sync(ts, y), lombScargle(ts, y, frequencies));
          expect(state.processedPoints, work,
              reason: 'identical prefix does no math');
          state = IncrementalLombScargle.fromJson(checkpoint(state.toJson()));
        }
        expect(state.processedPoints, lessThanOrEqualTo(t.length + 4),
            reason: 'append work is linear in newly accepted samples');
      });
    }
    test('Lomb replacement, shrink, shifted origin and force seed=$seed', () {
      final f = incrementalFixture(seed: seed, beats: 160);
      final state = IncrementalLombScargle(frequencies);
      var t = f.times.map((x) => x / 1000).toList(), y = [...f.nn];
      spectrumClose(state.sync(t, y), lombScargle(t, y, frequencies));
      y[31] += 79;
      spectrumClose(state.sync(t, y), lombScargle(t, y, frequencies));
      t[44] += .02;
      spectrumClose(state.sync(t, y), lombScargle(t, y, frequencies));
      t = t.sublist(13, 141);
      y = y.sublist(13, 141);
      spectrumClose(state.sync(t, y), lombScargle(t, y, frequencies));
      t = t.map((x) => x + 12345.125).toList();
      spectrumClose(state.sync(t, y), lombScargle(t, y, frequencies));
      final work = state.processedPoints;
      spectrumClose(
          state.sync(t, y, force: true), lombScargle(t, y, frequencies));
      expect(state.processedPoints - work, t.length);
      spectrumClose(state.sync([], []), lombScargle([], [], frequencies));
    });
  }
  for (final grid in [
    <double>[],
    [0.0],
    [.04, .04, .13],
    [.1, .07, .4]
  ]) {
    test('Lomb preserves frequency grid $grid', () {
      final f = incrementalFixture(beats: 31);
      spectrumClose(IncrementalLombScargle(grid).sync(f.times, f.nn),
          lombScargle(f.times, f.nn, grid));
    });
  }
  test('Lomb constant values, collapsed time, and malformed lengths abstain',
      () {
    final state = IncrementalLombScargle(frequencies);
    for (final input in <(List<double>, List<double>)>[
      ([0.0, 1, 2, 3], [7.0, 7, 7, 7]),
      ([1.0, 1, 1, 1], [7.0, 8, 9, 10]),
      ([1.0, 2, 3, 4], [7.0])
    ]) {
      spectrumClose(state.sync(input.$1, input.$2),
          lombScargle(input.$1, input.$2, frequencies));
    }
  });
  for (final bad in [double.nan, double.infinity, double.negativeInfinity]) {
    test('Lomb nonfinite fallback $bad', () {
      final f = incrementalFixture(beats: 31);
      final t = f.times.map((x) => x / 1000).toList(), y = [...f.nn];
      final state = IncrementalLombScargle(frequencies);
      state.sync(t, y);
      y[13] = bad;
      spectrumClose(state.sync(t, y), lombScargle(t, y, frequencies));
      y[13] = f.nn[13];
      t[9] = bad;
      spectrumClose(state.sync(t, y), lombScargle(t, y, frequencies));
    });
  }
  test('Lomb malformed checkpoint throws an explicit input error', () {
    expect(() => IncrementalLombScargle.fromJson({'frequencies': 'bad'}),
        throwsA(anyOf(isA<FormatException>(), isA<ArgumentError>())));
  });
  test('Lomb real capture irregular cleaned beat times match batch', () {
    final f = realIncrementalFixture();
    expect(f.nn.length, greaterThan(300));
    final t = f.times.map((x) => x / 1000).toList();
    final state = IncrementalLombScargle(frequencies);
    for (final n in prefixSizes(f.nn.length, 173)) {
      final ts = t.sublist(0, n), nn = f.nn.sublist(0, n);
      spectrumClose(state.sync(ts, nn), lombScargle(ts, nn, frequencies));
    }
  });
}
