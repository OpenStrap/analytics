// Run with: nix develop -c dart run tool/incremental_benchmark.dart
// Same deterministic growing inputs on both paths. Timings describe this
// process and machine; processed counts measure the incremental math work.
import 'dart:math' as math;

import 'package:openstrap_analytics/onehz.dart';

void main() {
  final nn = <double>[], times = <double>[];
  var time = 0.0;
  for (var i = 0; i < 7200; i++) {
    final value = 800 + 60 * math.sin(i * .13) + 20 * math.sin(i * .031);
    time += value;
    if (i % 731 == 730) time += 17000;
    nn.add(value);
    times.add(time);
  }
  final frequencies = List.generate(32, (i) => .01 + i * .012);
  final seconds = [for (final t in times) t / 1000];
  final accel = List.generate(
      7200,
      (i) => AccelSample(i * 1000.0, .1 * math.sin(i * .19),
          .05 * math.cos(i * .07), 1 + .04 * math.sin(i * .31)));
  final hr = List.generate(600, (i) => 75.0 + 65 * (1 + math.sin(i * .07)) / 2);
  final keys = List.generate(hr.length, (i) => 28000000 + i);
  final cadence =
      List<double?>.generate(hr.length, (i) => i % 5 == 0 ? 110 : null);
  const profile =
      WorkoutUserProfile(weightKg: 80, heightCm: 180, age: 35, sex: 'male');

  final spectrum = IncrementalLombScargle(frequencies);
  compare(
      'Lomb, 32 frequencies',
      nn.length,
      60,
      (n) => lombScargle(seconds.sublist(0, n), nn.sublist(0, n), frequencies),
      (n) => spectrum.sync(seconds.sublist(0, n), nn.sublist(0, n)),
      () => spectrum.processedPoints);
  final hrv = IncrementalHrvTime();
  compare(
      'Time HRV',
      nn.length,
      60,
      (n) => hrvTime(nn.sublist(0, n), nnTimesMs: times.sublist(0, n)),
      (n) => hrv.sync(nn.sublist(0, n), nnTimesMs: times.sublist(0, n)),
      () => hrv.processedPoints);
  final motion = IncrementalEnmoSeries();
  compare(
      'Motion, explicit gravity reference',
      accel.length,
      60,
      (n) => enmoSeries(accel.sublist(0, n), gRef: 1),
      (n) => motion.sync(accel.sublist(0, n), gRef: 1),
      () => motion.processedPoints);
  final minutes = IncrementalMinuteMetrics();
  compare('Minute load and energy', hr.length, 1, (n) {
    final input = hr.sublist(0, n), walking = cadence.sublist(0, n);
    final load = banisterTrimp(input, restingHr: 55, maxHr: 185, sex: Sex.male);
    final strain = strainScoreMetric(load.value,
        wakeMinutes: n.toDouble(), quietHrr: .12, quietSettled: false, female: false);
    final energy = Calories.dailyEnergy(input,
        profile: profile, hrmax: 185, restingHr: 55, cadenceSpmPerMin: walking);
    final series = Calories.minuteEnergy(input,
        profile: profile,
        hrmax: 185,
        restingHr: 55,
        cadenceSpmPerMin: walking,
        epochMinutes: keys.sublist(0, n));
    return MinuteMetrics(
        trimp: load, strain: strain, energy: energy, minutes: series);
  },
      (n) => minutes.sync(keys.sublist(0, n), hr.sublist(0, n),
          cadenceSpm: cadence.sublist(0, n),
          restingHr: 55,
          maxHr: 185,
          profile: profile,
          quietHrr: .12),
      () => minutes.processedMinutes);
  final summary = IncrementalMinuteMetrics();
  compare('Minute summaries (no minute series)', hr.length, 1, (n) {
    final input = hr.sublist(0, n), walking = cadence.sublist(0, n);
    final load = banisterTrimp(input, restingHr: 55, maxHr: 185, sex: Sex.male);
    final strain = strainScoreMetric(load.value,
        wakeMinutes: n.toDouble(), quietHrr: .12, quietSettled: false, female: false);
    final energy = Calories.dailyEnergy(input,
        profile: profile, hrmax: 185, restingHr: 55, cadenceSpmPerMin: walking);
    return MinuteMetrics(trimp: load, strain: strain, energy: energy);
  },
      (n) => summary.sync(keys.sublist(0, n), hr.sublist(0, n),
          cadenceSpm: cadence.sublist(0, n),
          restingHr: 55,
          maxHr: 185,
          profile: profile,
          quietHrr: .12,
          includeMinuteSeries: false),
      () => summary.processedMinutes);
}

Object? _sink;

void compare(String name, int length, int chunk, Object? Function(int) batch,
    Object? Function(int) incremental, int Function() work) {
  // Warm the same growing-prefix workloads that will be measured, including
  // the append checks and artifact rendering on the incremental path.
  for (var warm = 0; warm < 3; warm++) {
    for (var n = chunk; n <= length; n += chunk) {
      _sink = batch(n);
    }
    incremental(0);
    for (var n = chunk; n <= length; n += chunk) {
      _sink = incremental(n);
    }
  }
  final fullTimes = <int>[], deltaTimes = <int>[];
  var batchPoints = 0, processed = 0;
  for (var repeat = 0; repeat < 5; repeat++) {
    batchPoints = 0;
    final full = Stopwatch()..start();
    for (var n = chunk; n <= length; n += chunk) {
      _sink = batch(n);
      batchPoints += n;
    }
    full.stop();
    fullTimes.add(full.elapsedMicroseconds);
    incremental(0);
    final workBefore = work();
    final delta = Stopwatch()..start();
    for (var n = chunk; n <= length; n += chunk) {
      _sink = incremental(n);
    }
    delta.stop();
    deltaTimes.add(delta.elapsedMicroseconds);
    processed = work() - workBefore;
  }
  fullTimes.sort();
  deltaTimes.sort();
  print('$name: batch ${fullTimes[2] / 1000} ms, '
      'incremental ${deltaTimes[2] / 1000} ms (median of 5 warmed runs); '
      '$batchPoints batch input visits, $processed incremental points');
  // Keep results observable so the benchmark represents published output.
  if (_sink == null) throw StateError('Benchmark produced no output');
}
