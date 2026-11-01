import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';
import '../support/incremental_compare.dart';
import '../support/incremental_fixtures.dart';

void _check(RunningMoments state, List<double> values) {
  expect(state.count, values.length);
  numberClose(state.mean, mean(values));
  numberClose(state.sampleSd, stddev(values));
  numberClose(state.populationSd, stddevPop(values));
}

void main() {
  for (final seed in [1, 42, 914]) {
    test('moments add/remove and JSON continuation seed=$seed', () {
      var state = RunningMoments();
      final values = <double>[];
      _check(state, values);
      final nn = incrementalFixture(seed: seed, beats: 100).nn;
      for (final x in nn) {
        values.add(x);
        state.add(x);
        _check(state, values);
        if (values.length == 53) {
          state = RunningMoments.fromJson(checkpoint(state.toJson()));
          _check(state, values);
        }
      }
      while (values.isNotEmpty) {
        state.remove(values.removeAt(values.length ~/ 2));
        _check(state, values);
      }
      state.add(17);
      _check(state, [17]);
    });
    test('moments merge disjoint partitions seed=$seed', () {
      final values = incrementalFixture(seed: seed, beats: 101).nn;
      final left = RunningMoments(), right = RunningMoments();
      for (final x in values.take(37)) {
        left.add(x);
      }
      for (final x in values.skip(37)) {
        right.add(x);
      }
      left.merge(right);
      _check(left, values);
      _check(right, values.sublist(37));
      left.merge(RunningMoments());
      _check(left, values);
      final copy = RunningMoments()..merge(left);
      _check(copy, values);
    });
  }
  for (final values in [
    <double>[],
    [42.0],
    List<double>.filled(80, 42),
    List.generate(80, (i) => 1e9 + (i % 7) * .25)
  ]) {
    test(
        'moments degenerate/stable data n=${values.length} first=${values.firstOrNull}',
        () {
      final state = RunningMoments();
      for (final x in values) {
        state.add(x);
      }
      _check(state, values);
      _check(RunningMoments.fromJson(checkpoint(state.toJson())), values);
    });
  }
}
