// The public batch function of each toleranced calculation IS its aggregator
// run over the whole input in one slice: empty -> addSlice(all) -> finish.
// So the batch result must be BIT-IDENTICAL to that one-slice fold (not merely
// within the chunked-fold tolerance, which the per-calculation *_aggregator
// tests and the laws harness already check).
//
// Hypnogram metrics and SRI are already wired this way. This file covers the
// rest: HRV time domain, Banister TRIMP, Cosinor, time in zone, CTL/ATL/TSB,
// PRSA DC/AC, circadian IS/IV/M10/L5/RA, readiness lnRMSSD.
//
// Readiness already shares readinessLnRmssdFromSuffix with its aggregator, so
// its test is expected to pass today (the no-dates path).

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:openstrap_analytics/aggregate.dart';
import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

import '../support/hrv_beats.dart';
import '../support/property.dart' show Rng;

final _bd = ByteData(8);
int _bits(double d) {
  _bd.setFloat64(0, d);
  return _bd.getInt64(0);
}

/// Equal as bit patterns (NaN == NaN, 0.0 != -0.0); other values by ==.
bool _same(Object? a, Object? b) {
  if (a is double && b is double) return _bits(a) == _bits(b);
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_same(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

List<Object?> _meta(Metric<Object?> m) =>
    [m.present, m.confidence, m.tier, m.inputs_used.join(','), m.note];

void _bitIdentical(List<Object?> got, List<Object?> want, String tag) {
  expect(_same(got, want), isTrue,
      reason: '$tag: batch is not bit-identical to the one-slice aggregator '
          'run\n batch      $got\n aggregator $want');
}

DoubleColumn _col(List<double> x) => DoubleColumn(Float64List.fromList(x));

void main() {
  test('HRV time domain: hrvTime == hrvTimeAggregator one slice', () {
    for (final (mode, seed) in [(0, 11), (1, 12), (2, 13), (3, 14)]) {
      final beats = hrvSeries(Rng(seed), 4000, mode);
      final nn = beats.nnMs.toList();
      final times = beats.timeMs.toList();
      final batch = hrvTime(nn, nnTimesMs: times);
      final agg = hrvTimeAggregator(originMs: beats.timeMs[0]).run(beats);
      final b = batch.value ?? HrvTime(nBeats: beats.length);
      _bitIdentical(
          [...hrvFields(b), b.nBeats], [...hrvFields(agg), agg.nBeats],
          'hrv mode $mode');
    }
  });

  test('Banister TRIMP: banisterTrimp == banisterTrimpAggregator one slice',
      () {
    final r = Rng(21);
    final hr = [
      for (var i = 0; i < 1500; i++)
        r.nextBool(.05) ? double.nan : 45 + r.nextDouble() * 150
    ];
    for (final sex in [Sex.male, Sex.female]) {
      final batch =
          banisterTrimp(hr, restingHr: 52, maxHr: 192, sex: sex);
      final agg = banisterTrimpAggregator(restingHr: 52, maxHr: 192, sex: sex)
          .run(_col(hr));
      _bitIdentical([..._meta(batch), batch.value],
          [..._meta(agg), agg.value], 'trimp $sex');
    }
  });

  test('Cosinor: cosinor == cosinorAggregator one slice', () {
    final r = Rng(31);
    final n = 72 * 4;
    final t = [for (var i = 0; i < n; i++) i * 0.25];
    final y = [
      for (final h in t)
        60 +
            12 * math.cos(2 * math.pi * (h - 15) / 24) +
            (r.nextDouble() - .5) * 6
    ];
    final batch = cosinor(t, y);
    final agg = cosinorAggregator()
        .run(TimedValues(Float64List.fromList(t), Float64List.fromList(y)));
    List<Object?> f(Metric<CosinorFit> m) => [
          ..._meta(m),
          m.value?.mesor,
          m.value?.amplitude,
          m.value?.acrophaseRad,
          m.value?.acrophaseHours,
          m.value?.periodHours,
          m.value?.r2,
          m.value?.r2Adj,
        ];
    _bitIdentical(f(batch), f(agg), 'cosinor');
  });

  test('Time in zone: HeartRateZones.timeInZone == timeInZoneAggregator '
      'one slice', () {
    final r = Rng(41);
    final zones = HeartRateZones.zonesFromMaxHr(190);
    final ts = <double>[];
    final hr = <double>[];
    var t = 1.7e12;
    var h = 120.0;
    for (var i = 0; i < 6000; i++) {
      // Jittered ~1 Hz clock, so the credited seconds are not whole numbers
      // and the float sums depend on summation order.
      t += r.nextBool(.02)
          ? 1000.0 * r.intIn(5, 90)
          : 1000.0 + r.intIn(-37, 37) / 8;
      h = (h + (r.nextDouble() - .5) * 14).clamp(40.0, 195.0);
      ts.add(t);
      hr.add(r.nextBool(.03) ? 0 : h);
    }
    final batch = HeartRateZones.timeInZone(
        [for (var i = 0; i < ts.length; i++) HrSample(ts[i], hr[i])], zones);
    final agg = timeInZoneAggregator(zones).run(
        HrStream(Float64List.fromList(ts), Float64List.fromList(hr)));
    List<Object?> f(TimeInHeartRateZone? z) =>
        z == null ? [null] : [...z.seconds, z.belowZone1];
    expect(batch, isNotNull);
    _bitIdentical(f(batch), f(agg), 'time in zone');
  });

  test('CTL/ATL/TSB: ctlAtlTsb == ctlAtlTsbAggregator one slice', () {
    List<Object?> f(Metric<LoadState> m) =>
        [..._meta(m), m.value?.ctl, m.value?.atl, m.value?.tsb];
    for (final (seed, days) in [(51, 120), (52, 45), (53, 200), (54, 365)]) {
      final r = Rng(seed);
      final trimp = [
        for (var i = 0; i < days; i++)
          i % 7 == 6 ? 0.0 : 40 + r.nextDouble() * 160
      ];
      final batch = ctlAtlTsb(trimp);
      final agg = ctlAtlTsbAggregator().run(_col(trimp));
      expect(batch.present, isTrue);
      _bitIdentical(f(batch), f(agg), 'ctl/atl/tsb seed $seed, $days days');
    }
  });

  test('PRSA DC/AC: decelerationCapacity/accelerationCapacity == '
      'prsaAggregator one slice', () {
    final r = Rng(61);
    var v = 900.0;
    final nn = [
      for (var i = 0; i < 3000; i++)
        v = (v + (r.nextDouble() - .5) * 90).clamp(700.0, 1100.0)
    ];
    List<Object?> f(Metric<PrsaResult> m) => [
          ..._meta(m),
          m.value?.capacity,
          m.value?.profile,
          m.value?.anchors,
          m.value?.kind,
        ];
    for (final dec in [true, false]) {
      final batch =
          dec ? decelerationCapacity(nn) : accelerationCapacity(nn);
      final agg = prsaAggregator(deceleration: dec).run(_col(nn));
      expect(batch.present, isTrue);
      _bitIdentical(f(batch), f(agg), dec ? 'DC' : 'AC');
    }
  });

  test('Circadian IS/IV/M10/L5/RA: circadianNonparametric == '
      'circadianNpAggregator one slice', () {
    final r = Rng(71);
    const perDay = 96;
    final x = [
      for (var i = 0; i < perDay * 6; i++)
        50 +
            40 * math.sin(2 * math.pi * (i % perDay - 30) / perDay) +
            r.nextDouble() * 25
    ];
    final batch = circadianNonparametric(x, perDay);
    final agg = circadianNpAggregator(perDay)
        .run(EpochSeries(Float64List.fromList(x)));
    List<Object?> f(Metric<CircadianNp> m) => [
          ..._meta(m),
          m.value?.interdailyStability,
          m.value?.intradailyVariability,
          m.value?.m10,
          m.value?.l5,
          m.value?.relativeAmplitude,
          m.value?.m10StartEpoch,
          m.value?.l5StartEpoch,
        ];
    expect(batch.present, isTrue);
    _bitIdentical(f(batch), f(agg), 'circadian');
  });

  test('Readiness lnRMSSD: readinessLnRmssd == readinessLnRmssdAggregator '
      'one slice (shares readinessLnRmssdFromSuffix; may already pass)', () {
    final r = Rng(81);
    final hist = [for (var i = 0; i < 40; i++) 3.6 + (r.nextDouble() - .5) * .6];
    List<Object?> f(Metric<ReadinessLnRmssd> m) => [
          ..._meta(m),
          m.value?.lnRmssdToday,
          m.value?.rolling7Mean,
          m.value?.rolling7Median,
          m.value?.cvPct,
          m.value?.z,
          m.value?.swc,
          m.value?.band,
          m.value?.saturationFlag,
        ];
    final batch = readinessLnRmssd(hist, meanNnTodayMs: 880);
    final agg =
        readinessLnRmssdAggregator(meanNnTodayMs: 880).run(_col(hist));
    expect(batch.present, isTrue);
    _bitIdentical(f(batch), f(agg), 'readiness');
  });
}
