// Run with: dart compile exe tool/bench_aggregate.dart -o /tmp/bench_aggregate
//          /tmp/bench_aggregate
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:openstrap_analytics/aggregate.dart';
import 'package:openstrap_analytics/onehz.dart';

Object? _sink;

void main() {
  final values = DoubleColumn(Float64List.fromList(
      [for (var i = 0; i < 86400; i++) ((i * 7919) % 2003 - 1001).toDouble()]));
  final summary = both(
    both(Sum<DoubleColumn>((batch) => batch.values), const Count<DoubleColumn>()),
    both(Min<DoubleColumn>((batch) => batch.values),
        Max<DoubleColumn>((batch) => batch.values)),
  );
  final beats = _beats(30000);
  final origin = beats.timeMs.first;
  final composed = hrvTimeAggregator(originMs: origin);

  final rows = <(String, String, int)>[
    ('86,400 doubles', 'hand sum/count/min/max',
        _medianMicros(() => _doubleHandLoop(values))),
    ('86,400 doubles', 'both blocks, one slice',
        _medianMicros(() => summary.run(values))),
    ('86,400 doubles', 'both blocks, 60-row slices',
        _medianMicros(() => _sliced(summary, values, 60))),
    ('30,000 beats', 'hrvTime() batch', _medianMicros(
        () => hrvTime(beats.nnMs.toList(), nnTimesMs: beats.timeMs.toList()))),
    ('30,000 beats', 'hand HRV loop', _medianMicros(() => _handHrv(beats))),
    ('30,000 beats', 'composed, one slice',
        _medianMicros(() => composed.run(beats))),
    ('30,000 beats', 'composed, 24 slices + combine',
        _medianMicros(() => _combined(composed, beats, 24))),
    ('30,000 beats', 'composed, 1-row slices',
        _medianMicros(() => _sliced(composed, beats, 1))),
  ];

  final reference = hrvTime(beats.nnMs.toList(), nnTimesMs: beats.timeMs.toList())
      .value!;
  final result = composed.run(beats);
  final parity = _hrvParity(result, reference);
  final handUs = rows[4].$3;
  final oneSliceUs = rows[5].$3;
  final chunksUs = rows[6].$3;

  print('Median microseconds (7 timed runs after 3 warm-up runs)');
  print('${'workload'.padRight(16)}  ${'operation'.padRight(36)}  us');
  for (final row in rows) {
    print('${row.$1.padRight(16)}  ${row.$2.padRight(36)}  ${row.$3}');
  }
  print('parity composed vs hrvTime (1e-9): $parity');
  print('HRV ratios: one slice ${(oneSliceUs / handUs).toStringAsFixed(2)}x; '
      '24 slices ${(chunksUs / handUs).toStringAsFixed(2)}x (target <= 2.00x)');
  if (!parity || _sink == null) {
    throw StateError('Benchmark parity or result observability failed');
  }
}

(double, int, double, double) _doubleHandLoop(DoubleColumn batch) {
  var sum = 0.0;
  var count = 0;
  var min = double.infinity;
  var max = -double.infinity;
  for (final value in batch.values) {
    if (value.isNaN) continue;
    sum += value;
    count++;
    if (value < min) min = value;
    if (value > max) max = value;
  }
  return (sum, count, min, max);
}

Beats _beats(int count) {
  final random = math.Random(0xA661E6A7);
  final nn = Float64List(count);
  final times = Float64List(count);
  var time = 1000000.0;
  var interval = 900.0;
  for (var i = 0; i < count; i++) {
    interval = (interval + (random.nextDouble() - .5) * 24)
        .clamp(800.0, 1100.0)
        .toDouble();
    final gap = i > 0 && random.nextDouble() < .0007
        ? 1000 + random.nextDouble() * 30000
        : 0.0;
    time += interval + gap;
    nn[i] = interval;
    times[i] = time;
  }
  return Beats(nn, times);
}

R _combined<R>(Aggregator<dynamic, Beats, R> aggregator, Beats batch,
    int chunks) {
  dynamic state = aggregator.empty();
  for (var chunk = 0; chunk < chunks; chunk++) {
    final start = batch.length * chunk ~/ chunks;
    final end = batch.length * (chunk + 1) ~/ chunks;
    state = aggregator.combine(state, aggregator.fold(batch, start, end));
  }
  return aggregator.finish(state);
}

R _sliced<S, B extends Batch<B>, R>(Aggregator<S, B, R> aggregator, B batch,
    int sliceSize) {
  var state = aggregator.empty();
  for (var start = 0; start < batch.length; start += sliceSize) {
    final end = math.min(start + sliceSize, batch.length);
    state = aggregator.addSlice(state, batch, start, end);
  }
  return aggregator.finish(state);
}

int _medianMicros(Object? Function() action) {
  for (var warm = 0; warm < 3; warm++) {
    _sink = action();
  }
  final samples = <int>[];
  for (var run = 0; run < 7; run++) {
    final watch = Stopwatch()..start();
    _sink = action();
    watch.stop();
    samples.add(watch.elapsedMicroseconds);
  }
  samples.sort();
  return samples[samples.length ~/ 2];
}

bool _hrvParity(HrvTime a, HrvTime b) =>
    a.nBeats == b.nBeats &&
    _same(a.rmssd, b.rmssd) &&
    _same(a.sdnn, b.sdnn) &&
    _same(a.sdann, b.sdann) &&
    _same(a.sdnnIndex, b.sdnnIndex) &&
    _same(a.pnn50, b.pnn50) &&
    _same(a.diffAcf1, b.diffAcf1);

bool _same(double? a, double? b) {
  if (a == null || b == null) return a == b;
  return (a - b).abs() <= 1e-9 + 1e-9 * b.abs();
}

class _Moments {
  var count = 0;
  var mean = 0.0;
  var m2 = 0.0;

  void add(double value) {
    count++;
    final delta = value - mean;
    mean += delta / count;
    m2 += delta * (value - mean);
  }

  double? get sampleSd => count < 2 ? null : math.sqrt(m2 / (count - 1));
}

/// Direct baseline for the same metrics, deliberately independent of the
/// aggregate graph.
HrvTime _handHrv(Beats beats) {
  final levels = _Moments();
  final bins = <int, _Moments>{};
  var pairs = 0, over50 = 0, lagPairs = 0;
  var sum = 0.0, squares = 0.0, products = 0.0, endpoints = 0.0;
  for (var i = 0; i < beats.length; i++) {
    final nn = beats.nnMs[i];
    levels.add(nn);
    final key = ((beats.timeMs[i] - beats.timeMs.first) / 300000.0).floor();
    (bins[key] ??= _Moments()).add(nn);
    if (i == 0 || beats.timeMs[i] - beats.timeMs[i - 1] > nn + 0.5) continue;
    final diff = nn - beats.nnMs[i - 1];
    pairs++;
    sum += diff;
    squares += diff * diff;
    if (diff.abs() > 50) over50++;
    if (i >= 2 && beats.timeMs[i - 1] - beats.timeMs[i - 2] <=
        beats.nnMs[i - 1] + 0.5) {
      final previous = beats.nnMs[i - 1] - beats.nnMs[i - 2];
      lagPairs++;
      products += previous * diff;
      endpoints += previous + diff;
    }
  }
  if (levels.count < 2) return HrvTime(nBeats: levels.count);
  double? acf1;
  if (pairs >= 30) {
    final mean = sum / pairs;
    final variance = squares - sum * mean;
    if (variance > 0) {
      acf1 = (products - mean * endpoints + lagPairs * mean * mean) / variance;
    }
  }
  final jittery = acf1 != null && acf1 < kNnDiffAcf1Floor;
  final means = _Moments();
  var sdSum = 0.0, binCount = 0;
  for (final bin in bins.values) {
    if (bin.count < 2) continue;
    means.add(bin.mean);
    sdSum += bin.sampleSd!;
    binCount++;
  }
  return HrvTime(
    nBeats: levels.count,
    rmssd: pairs > 0 && !jittery ? math.sqrt(squares / pairs) : null,
    pnn50: pairs > 0 && !jittery ? 100.0 * over50 / pairs : null,
    sdnn: levels.sampleSd,
    sdann: binCount >= 2 ? means.sampleSd : null,
    sdnnIndex: binCount >= 2 ? sdSum / binCount : null,
    diffAcf1: acf1,
  );
}
