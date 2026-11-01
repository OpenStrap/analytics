import 'dart:io';
import 'dart:math' as math;

import 'package:openstrap_analytics/onehz.dart';

/// Reproducible inputs; no wall clock, device, network, or unseeded randomness.
class IncrementalFixture {
  final List<double> times, nn;
  final List<AccelSample> accel;
  final List<int> minuteKeys;
  final List<double> hr;
  final List<double?> cadence;
  const IncrementalFixture(
      this.times, this.nn, this.accel, this.minuteKeys, this.hr, this.cadence);
}

IncrementalFixture incrementalFixture(
    {int seed = 42,
    int beats = 850,
    int seconds = 241,
    int minutes = 121,
    double originMs = 0,
    double cadenceHz = 1,
    bool gaps = true,
    bool jitter = false}) {
  final random = math.Random(seed);
  final nn = <double>[], times = <double>[];
  var time = originMs;
  for (var i = 0; i < beats; i++) {
    final interval = jitter
        ? 800 + 160 * (random.nextDouble() - .5)
        : 800 +
            75 * math.sin(i * .13 + seed * .003) +
            21 * math.sin(i * .031 + seed * .007);
    time += interval;
    if (gaps && i % 113 == 112) time += 21000;
    nn.add(interval);
    times.add(time);
  }
  final accel = <AccelSample>[];
  for (var i = 0; i < seconds; i++) {
    if (gaps && i >= 70 && i < 139) continue;
    accel.add(AccelSample(
        originMs + i * 1000 / cadenceHz,
        .22 * math.sin(i * .29) + random.nextDouble() * .007,
        .11 * math.cos(i * .07),
        1.02 + .065 * math.sin(i * .23),
        valid: i % 47 != 46));
  }
  const hrBranches = [54.0, 95.0, 106.799999, 106.8, 130.0, 190.0, 0.0];
  const cadBranches = <double?>[null, 99.999, 100, 110, 120, 130, 160, 0];
  return IncrementalFixture(
      times,
      nn,
      accel,
      List.generate(minutes, (i) => 28000000 + i + i ~/ 17),
      List.generate(minutes, (i) => hrBranches[(i + seed) % hrBranches.length]),
      List.generate(
          minutes, (i) => cadBranches[(i + seed) % cadBranches.length]));
}

List<int> prefixSizes(int length, int chunk) => <int>{
      0,
      1,
      2,
      3,
      4,
      29,
      30,
      31,
      for (var i = chunk; i < length; i += chunk) i,
      length,
    }.where((n) => n <= length).toList()
      ..sort();

/// Checked-in anonymised WHOOP-4 overnight capture, July 2026. Provenance and
/// documentation: test/onehz/real_night_cardio_stager_test.dart. Timestamps were
/// rebased to zero and only HR, axes, and RR retained. This subset is
/// read directly from the repository; missing fixtures fail, never skip.
IncrementalFixture realIncrementalFixture({int seconds = 900}) {
  final accel = <AccelSample>[], hrSeconds = <double>[];
  for (final line in File('test/onehz/fixtures/real_night_2026_07_onehz.csv')
      .readAsLinesSync()
      .skip(1)) {
    if (line.trim().isEmpty) continue;
    final p = line.split(',').map(double.parse).toList();
    if (p[0] >= seconds) break;
    hrSeconds.add(p[1]);
    accel.add(AccelSample(p[0] * 1000, p[2], p[3], p[4]));
  }
  final raw = <double>[], times = <double>[];
  for (final line in File('test/onehz/fixtures/real_night_2026_07_rr.csv')
      .readAsLinesSync()
      .skip(1)) {
    if (line.trim().isEmpty) continue;
    final p = line.split(',').map(double.parse).toList();
    if (p[0] >= seconds * 1000) break;
    times.add(p[0]);
    raw.add(p[1]);
  }
  final clean = correctRr(raw, rrTsMs: times);
  final hr = <double>[];
  for (var i = 0; i < hrSeconds.length; i += 60) {
    hr.add(mean(hrSeconds.sublist(i, math.min(i + 60, hrSeconds.length)))!);
  }
  return IncrementalFixture(
      clean.nnTimesMs,
      clean.nn,
      accel,
      List.generate(hr.length, (i) => i),
      hr,
      List<double?>.filled(hr.length, null));
}
