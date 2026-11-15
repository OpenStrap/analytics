import 'dart:convert';
import 'dart:math' as math;

import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

void numberClose(double? actual, double? expected, {String? reason}) {
  if (expected == null) {
    expect(actual, isNull, reason: reason);
  } else if (expected.isNaN) {
    expect(actual?.isNaN, isTrue, reason: reason);
  } else if (!expected.isFinite) {
    expect(actual, expected, reason: reason);
  } else {
    expect(actual, isNotNull, reason: reason);
    expect(actual, closeTo(expected, math.max(1e-9, expected.abs() * 1e-8)),
        reason: reason);
  }
}

void metricEnvelope<T>(Metric<T> actual, Metric<T> expected) {
  expect(actual.present, expected.present);
  numberClose(actual.confidence, expected.confidence);
  expect(actual.tier, expected.tier);
  expect(actual.inputs_used, expected.inputs_used);
  expect(actual.note, expected.note);
  expect(actual.drivers?.map((d) => d.toJson()).toList(),
      expected.drivers?.map((d) => d.toJson()).toList());
}

void hrvClose(Metric<HrvTime> actual, Metric<HrvTime> expected) {
  metricEnvelope(actual, expected);
  if (expected.value == null) return;
  final a = actual.value!, e = expected.value!;
  expect(a.nBeats, e.nBeats);
  numberClose(a.rmssd, e.rmssd);
  numberClose(a.sdnn, e.sdnn);
  numberClose(a.sdann, e.sdann);
  numberClose(a.sdnnIndex, e.sdnnIndex);
  numberClose(a.pnn50, e.pnn50);
  numberClose(a.diffAcf1, e.diffAcf1);
}

void spectrumClose(LombScargle? actual, LombScargle? expected) {
  if (expected == null) {
    expect(actual, isNull);
    return;
  }
  expect(actual, isNotNull);
  expect(actual!.spectrum.length, expected.spectrum.length);
  for (var i = 0; i < expected.spectrum.length; i++) {
    expect(actual.spectrum[i].freqHz, expected.spectrum[i].freqHz);
    numberClose(actual.spectrum[i].psd, expected.spectrum[i].psd,
        reason: 'frequency ${expected.spectrum[i].freqHz}');
  }
  for (final band in [(0.0, .04), (.04, .15), (.15, .4)]) {
    numberClose(actual.bandPower(band.$1, band.$2),
        expected.bandPower(band.$1, band.$2));
  }
}

void enmoClose(EnmoResult actual, EnmoResult expected) {
  numberClose(actual.gRef, expected.gRef);
  numberClose(actual.coverage, expected.coverage);
  expect(actual.minutes.length, expected.minutes.length);
  for (var i = 0; i < expected.minutes.length; i++) {
    final a = actual.minutes[i], e = expected.minutes[i];
    expect(a.tsMinStartMs, e.tsMinStartMs);
    expect(a.nSamples, e.nSamples);
    numberClose(a.enmo, e.enmo);
    numberClose(a.mad, e.mad);
    numberClose(a.meanMag, e.meanMag);
    numberClose(a.dynAmp, e.dynAmp);
  }
}

void minuteClose(MinuteMetrics actual, List<int> keys, List<double> hr,
    {List<double?>? cadence,
    double? rhr = 54,
    double? maxHr = 186,
    Sex sex = Sex.male,
    WorkoutUserProfile? profile,
    int dayMinutes = 1440,
    double? quietHrr = .12,
    bool quietSettled = false}) {
  final trimp = banisterTrimp(hr, restingHr: rhr, maxHr: maxHr, sex: sex);
  final strain = strainScoreMetric(trimp.value,
      wakeMinutes: hr.length.toDouble(),
      quietHrr: quietHrr,
      quietSettled: quietSettled,
      female: sex == Sex.female);
  metricEnvelope(actual.trimp, trimp);
  numberClose(actual.trimp.value, trimp.value);
  metricEnvelope(actual.strain, strain);
  numberClose(actual.strain.value, strain.value);
  if (profile == null || rhr == null || maxHr == null) {
    expect(actual.energy, isNull);
    expect(actual.minutes, isNull);
    return;
  }
  final e = Calories.dailyEnergy(hr,
      profile: profile,
      hrmax: maxHr,
      restingHr: rhr,
      dayMinutes: dayMinutes,
      cadenceSpmPerMin: cadence);
  final series = Calories.minuteEnergy(hr,
      profile: profile,
      hrmax: maxHr,
      restingHr: rhr,
      epochMinutes: keys,
      cadenceSpmPerMin: cadence);
  if (e == null) {
    expect(actual.energy, isNull);
  } else {
    expect(actual.energy, isNotNull);
    numberClose(actual.energy!.total, e.total);
    numberClose(actual.energy!.active, e.active);
    numberClose(actual.energy!.basal, e.basal);
    numberClose(actual.energy!.walking, e.walking);
  }
  if (series == null) {
    expect(actual.minutes, isNull);
    return;
  }
  final a = actual.minutes!;
  expect(a.coveredMinutes, series.coveredMinutes);
  expect(a.abstainedMinutes, series.abstainedMinutes);
  numberClose(a.basalKcalPerMin, series.basalKcalPerMin);
  numberClose(a.active, series.active);
  numberClose(a.walking, series.walking);
  expect(a.minutes.length, series.minutes.length);
  for (var i = 0; i < series.minutes.length; i++) {
    final am = a.minutes[i], em = series.minutes[i];
    expect(am.minute, em.minute);
    expect(am.source, em.source);
    expect(am.abstained, em.abstained);
    numberClose(am.basal, em.basal);
    numberClose(am.active, em.active);
    numberClose(am.total, em.total);
    numberClose(am.walking, em.walking);
  }
}

Map<String, dynamic> checkpoint(Map<String, dynamic> json) =>
    jsonDecode(jsonEncode(json)) as Map<String, dynamic>;
