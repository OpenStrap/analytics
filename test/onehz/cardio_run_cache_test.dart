import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

void main() {
  test('cached gravity references stop at run boundaries', () {
    final hr = List<double>.filled(180, 55);
    final accel = [for (var i = 0; i < 180; i++)
      AccelSample((i + (i >= 90 ? 1000 : 0)) * 1000.0,
          0, 0, i < 90 ? 1.0 : 1.1)];
    final cache = CardioRowCache();
    CardioEpochFeatures extract(List<int> starts) => cardioEpochFeatures(
        hr, accel, runStarts: starts, rowCache: cache);
    // Two perfectly still postures, one on each side of a recording gap.
    // Each run's own reference makes ENMO exactly zero in all six epochs.
    expect(extract([90]).motion, List<double>.filled(6, 0));
    expect(extract([90]).motion, List<double>.filled(6, 0));
    expect(cache.hits, 6);
    // Removing the boundary changes the dependencies even with identical raw
    // arrays, so cached gap-clipped medians must not be reused.
    final joined = extract([]);
    expect(joined.motion.sublist(3), everyElement(closeTo(0.05, 1e-12)));
    final fresh = cardioEpochFeatures(hr, accel);
    expect(joined.motion, fresh.motion);
    expect(extract([90]).motion, List<double>.filled(6, 0));
  });
}
