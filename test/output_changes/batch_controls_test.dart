import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

void main() {
  test('RR cap boundary preserves uncapped NN for short classified runs', () {
    for (final n in [30, 31, 33]) {
      final rr = [...List<double>.filled(100, 900),
        ...List<double>.filled(n, 250), ...List<double>.filled(100, 900)];
      final capped = correctRr(rr);
      if (n <= 31) {
        final old = correctRr(rr, maxArtifactRun: null);
        expect(capped.nn, old.nn);
        expect(capped.nnTimesMs, old.nnTimesMs);
        expect(capped.classes, old.classes);
      } else {
        expect(capped.nn, List<double>.filled(200, 900));
        expect(capped.droppedCount, 33);
      }
    }
  });
  test('batch circular near-ties retain strict first-winner selection', () {
    // Equal 10-epoch windows on an alternating profile tie at every start.
    // A 5-epoch trough starts at zero, which includes three low epochs.
    final profile = [for (var i = 0; i < 24; i++) i.isEven ? 1.0 : 2.0];
    final equal = circadianNonparametric(profile, 24).value!;
    expect(equal.m10StartEpoch, 0);
    expect(equal.l5StartEpoch, 0);
    final near = [...profile]..[0] += 1e-12;
    final result = circadianNonparametric(near, 24).value!;
    expect(result.m10StartEpoch, 0);
    expect(result.l5StartEpoch, 2);
  });
  test('batch irregular screen excludes the gap pair already excluded by main', () {
    final result = irregularBeatScreen([800, 900, 1000, 1100, 700, 850, 900, 1000],
      nnTimesMs: [800, 1700, 2700, 3800, 14500, 15350, 16250, 17250],
      minBeats: 4).value!;
    // Six successive differences remain: 100,100,100,150,50,100.
    // Five exceed 70 ms. The -400 ms difference across the gap is absent.
    expect(result.pnnPct, 100 * 5 / 6);
    expect(result.nBeats, 8);
  });
}
