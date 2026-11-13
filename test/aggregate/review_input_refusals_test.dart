import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:openstrap_analytics/aggregate.dart';
import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

// why: batch guards alone leave chunked, combined and restored states unsafe.
// proves: CLAIM(review-input-refusals)
// catches: keeping the old aggregator finalizers while fixing only batch APIs.
Map<String, R> _paths<B extends Batch<B>, R>(
    Aggregator<dynamic, B, R> agg, B batch) {
  final split = batch.length ~/ 2;
  final saved =
      jsonDecode(jsonEncode(agg.encodeState(agg.fold(batch, 0, split))));
  return {
    'one slice': agg.run(batch),
    'successive slices': agg.finish(
        agg.addSlice(agg.fold(batch, 0, split), batch, split, batch.length)),
    'combined': agg.finish(agg.combine(
        agg.fold(batch, 0, split), agg.fold(batch, split, batch.length))),
    'restored': agg.finish(
        agg.addSlice(agg.decodeState(saved), batch, split, batch.length)),
  };
}

void _refuses<T>(Map<String, Metric<T>> results, String note) {
  for (final entry in results.entries) {
    expect(entry.value.value, isNull, reason: entry.key);
    expect(entry.value.present, isFalse, reason: entry.key);
    expect(entry.value.note, note, reason: entry.key);
  }
}

TimedValues _signal() => TimedValues(
    Float64List.fromList([for (var i = 0; i < 48; i++) i.toDouble()]),
    Float64List.fromList([
      for (var i = 0; i < 48; i++) 60 + 4 * math.cos(2 * math.pi * i / 24),
    ]));

void main() {
  test('finite cosinor remains measurable through every streaming path', () {
    // Independent oracle: y = 60 + 4*cos(2*pi*t/24) has MESOR 60, amplitude 4.
    for (final result in _paths(cosinorAggregator(), _signal()).values) {
      expect(result.value!.mesor, closeTo(60, 1e-12));
      expect(result.value!.amplitude, closeTo(4, 1e-12));
    }
  });

  test('invalid cosinor periods refuse even with insufficient observations',
      () {
    for (final period in [
      0.0,
      -24.0,
      double.nan,
      double.infinity,
      double.negativeInfinity
    ]) {
      final agg = cosinorAggregator(periodHours: period);
      for (final batch in [_signal(), _signal().copyRange(0, 3)]) {
        _refuses(_paths(agg, batch), 'invalid cosinor period');
      }
      _refuses({'empty': agg.finish(agg.empty())}, 'invalid cosinor period');
    }
  });

  test('subnormal cosinor period refuses its overflowing design', () {
    _refuses(_paths(cosinorAggregator(periodHours: 1e-320), _signal()),
        'non-finite cosinor design');
  });

  test('non-finite time and response poison either side of a cosinor merge',
      () {
    for (final bad in [double.nan, double.infinity, double.negativeInfinity]) {
      for (final index in [0, 12, 47]) {
        for (final axis in ['time', 'response']) {
          final batch = _signal();
          (axis == 'time' ? batch.tHours : batch.y)[index] = bad;
          _refuses(
              _paths(cosinorAggregator(), batch), 'non-finite cosinor design');
        }
      }
    }
  });

  test('finite response overflow refuses non-finite cosinor moments', () {
    final batch = _signal();
    for (var i = 0; i < batch.length; i++) {
      batch.y[i] = i.isEven ? 1e308 : -1e308;
    }
    _refuses(_paths(cosinorAggregator(), batch), 'non-finite cosinor design');
  });

  test('unknown daily TRIMP refuses in prime, tail and short history', () {
    // NaN is unknown, never an observed rest day. Infinities are invalid load.
    for (final bad in [double.nan, double.infinity, double.negativeInfinity]) {
      for (final index in [0, 6, 7, 13]) {
        final batch = DoubleColumn(
            Float64List.fromList(List<double>.filled(14, 50)..[index] = bad));
        _refuses(
            _paths(ctlAtlTsbAggregator(), batch), 'non-finite daily TRIMP');
      }
      final short = DoubleColumn(Float64List.fromList([50, bad, 50]));
      _refuses(_paths(ctlAtlTsbAggregator(), short), 'non-finite daily TRIMP');
    }
  });

  test('load checkpoints without validity evidence are refused', () {
    // Old checkpoints may already have skipped unknown load. Refusing them
    // forces a replay instead of asserting that all prior days were observed.
    final agg = ctlAtlTsbAggregator();
    final batch = DoubleColumn(Float64List.fromList(List.filled(14, 50.0)));
    final state =
        jsonDecode(jsonEncode(agg.encodeState(agg.fold(batch)))) as List;
    state[0] = 14;
    expect(() => agg.decodeState(state), throwsFormatException);
  });

  test('load checkpoints cannot claim more finite days than observed days', () {
    final agg = ctlAtlTsbAggregator();
    final batch = DoubleColumn(Float64List.fromList(List.filled(14, 50.0)));
    final state =
        jsonDecode(jsonEncode(agg.encodeState(agg.fold(batch)))) as List;
    state[0] = [14, 15];
    expect(() => agg.decodeState(state), throwsFormatException);
  });

  test('observed zero-load days decay through every streaming path', () {
    // Seven 50-load days prime at 50; seven zero-load days give 50*exp(-7/tau).
    final batch = DoubleColumn(Float64List.fromList([
      ...List<double>.filled(7, 50),
      ...List<double>.filled(7, 0),
    ]));
    for (final result in _paths(ctlAtlTsbAggregator(), batch).values) {
      expect(result.value!.ctl, closeTo(42.3240862445307, 1e-12));
      expect(result.value!.atl, closeTo(18.3939720585721, 1e-12));
    }
  });
}
