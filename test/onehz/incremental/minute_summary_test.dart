import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';
import '../support/energy_day.dart';
import '../support/incremental_compare.dart';
import '../support/incremental_fixtures.dart';

void _summaryClose(
  MinuteMetrics actual,
  List<double> hr, {
  List<double?>? cadence,
  double? rhr = 54,
  double? maxHr = 186,
  Sex sex = Sex.male,
  WorkoutUserProfile? profile,
  int dayMinutes = 1440,
  double? quietHrr = .12,
}) {
  expect(actual.minutes, isNull,
      reason: 'summary requests omit minute artifacts');
  final trimp = banisterTrimp(hr, restingHr: rhr, maxHr: maxHr, sex: sex);
  final strain = strainScoreMetric(trimp.value,
      wakeMinutes: hr.length.toDouble(),
      quietHrr: quietHrr,
      quietSettled: false,
      female: sex == Sex.female);
  metricEnvelope(actual.trimp, trimp);
  numberClose(actual.trimp.value, trimp.value);
  metricEnvelope(actual.strain, strain);
  numberClose(actual.strain.value, strain.value);
  final energy = profile == null || rhr == null || maxHr == null
      ? null
      : Calories.dailyEnergy(hr,
          profile: profile,
          hrmax: maxHr,
          restingHr: rhr,
          dayMinutes: dayMinutes,
          cadenceSpmPerMin: cadence);
  if (energy == null) {
    expect(actual.energy, isNull);
  } else {
    expect(actual.energy, isNotNull);
    numberClose(actual.energy!.total, energy.total);
    numberClose(actual.energy!.active, energy.active);
    numberClose(actual.energy!.basal, energy.basal);
    numberClose(actual.energy!.walking, energy.walking);
  }
}

void main() {
  for (final seed in [1, 42, 914]) {
    for (final entry in energyProfiles.entries) {
      for (final chunk in [1, 19]) {
        test(
            'summary append/restore seed=$seed profile=${entry.key} chunk=$chunk',
            () {
          final f = incrementalFixture(seed: seed, minutes: 61);
          final sex = entry.key == 'female' ? Sex.female : Sex.male;
          var state = IncrementalMinuteMetrics();
          for (final n in prefixSizes(f.hr.length, chunk)) {
            final keys = f.minuteKeys.sublist(0, n), hr = f.hr.sublist(0, n);
            final cad = f.cadence.sublist(0, n);
            _summaryClose(
                state.sync(keys, hr,
                    cadenceSpm: cad,
                    restingHr: 54,
                    maxHr: 186,
                    sex: sex,
                    profile: entry.value,
                    quietHrr: .12,
                    dayMinutes: 900,
                    includeMinuteSeries: false),
                hr,
                cadence: cad,
                sex: sex,
                profile: entry.value,
                dayMinutes: 900);
            expect(state.processedMinutes, n);
            if (n == 31) {
              state =
                  IncrementalMinuteMetrics.fromJson(checkpoint(state.toJson()));
            }
          }
          final work = state.processedMinutes;
          minuteClose(
              state.sync(f.minuteKeys, f.hr,
                  cadenceSpm: f.cadence,
                  restingHr: 54,
                  maxHr: 186,
                  sex: sex,
                  profile: entry.value,
                  quietHrr: .12,
                  dayMinutes: 900),
              f.minuteKeys,
              f.hr,
              cadence: f.cadence,
              sex: sex,
              profile: entry.value,
              dayMinutes: 900);
          expect(state.processedMinutes, work,
              reason:
                  'emitting retained minute artifacts requires no repricing');
        });
      }
    }
  }
  test(
      'summary edits/removals/reorder and artifact toggles only reprice changed keys',
      () {
    final f = incrementalFixture(minutes: 50);
    final profile = energyProfiles['male']!;
    final state = IncrementalMinuteMetrics();
    var keys = [...f.minuteKeys], hr = [...f.hr];
    var cadence = [...f.cadence];
    MinuteMetrics sync({bool series = false, bool force = false}) =>
        state.sync(keys, hr,
            cadenceSpm: cadence,
            restingHr: 54,
            maxHr: 186,
            profile: profile,
            quietHrr: .12,
            force: force,
            includeMinuteSeries: series);
    void check() =>
        _summaryClose(sync(), hr, cadence: cadence, profile: profile);
    // The existing default behavior remains the full minute series.
    minuteClose(sync(series: true), keys, hr,
        cadence: cadence, profile: profile);
    expect(state.processedMinutes, 50);
    check();
    expect(state.processedMinutes, 50);
    hr[11] += 29;
    check();
    expect(state.processedMinutes, 51);
    cadence[22] = 123;
    check();
    expect(state.processedMinutes, 52);
    keys.insert(5, 27999999);
    hr.insert(5, 95);
    cadence.insert(5, 120);
    check();
    expect(state.processedMinutes, 53);
    keys.removeAt(8);
    hr.removeAt(8);
    cadence.removeAt(8);
    check();
    expect(state.processedMinutes, 53);
    keys = keys.reversed.toList();
    hr = hr.reversed.toList();
    cadence = cadence.reversed.toList();
    check();
    expect(state.processedMinutes, 53);
    minuteClose(sync(series: true), keys, hr,
        cadence: cadence, profile: profile);
    expect(state.processedMinutes, 53);
    _summaryClose(sync(force: true), hr, cadence: cadence, profile: profile);
    expect(state.processedMinutes, 53 + keys.length);
    keys.clear();
    hr.clear();
    cadence.clear();
    check();
    final work = state.processedMinutes;
    minuteClose(sync(series: true), keys, hr,
        cadence: cadence, profile: profile);
    expect(state.processedMinutes, work);
  });
  test(
      'summary anchor/profile/sex changes and day duration follow batch exactly',
      () {
    final f = incrementalFixture(minutes: 31);
    var state = IncrementalMinuteMetrics();
    for (final p in energyProfiles.values) {
      for (final anchors in <(double?, double?)>[
        (54, 186),
        (65, 197),
        (null, 186),
        (54, null),
        (70, 60),
        (double.nan, 186)
      ]) {
        for (final sex in Sex.values) {
          for (final duration in [0, 900, 1440]) {
            _summaryClose(
                state.sync(f.minuteKeys, f.hr,
                    cadenceSpm: f.cadence,
                    restingHr: anchors.$1,
                    maxHr: anchors.$2,
                    sex: sex,
                    profile: p,
                    quietHrr: .18,
                    dayMinutes: duration,
                    includeMinuteSeries: false),
                f.hr,
                cadence: f.cadence,
                rhr: anchors.$1,
                maxHr: anchors.$2,
                sex: sex,
                profile: p,
                quietHrr: .18,
                dayMinutes: duration);
            state =
                IncrementalMinuteMetrics.fromJson(checkpoint(state.toJson()));
          }
        }
      }
    }
  });
  test('summary nonfinite HR/cadence preserves abstentions and finite energy',
      () {
    final f = energyDay(n: 91);
    final keys = List.generate(f.hr.length, (i) => 28000000 + i * 2);
    final p = energyProfiles['nonbinary']!;
    final state = IncrementalMinuteMetrics();
    for (final n in prefixSizes(f.hr.length, 17)) {
      final k = keys.sublist(0, n),
          h = f.hr.sublist(0, n),
          c = f.cadence.sublist(0, n);
      _summaryClose(
          state.sync(k, h,
              cadenceSpm: c,
              restingHr: 54,
              maxHr: 186,
              profile: p,
              quietHrr: .12,
              includeMinuteSeries: false),
          h,
          cadence: c,
          profile: p);
    }
  });
  test('summary without profile still calculates clinical metrics', () {
    final f = incrementalFixture(minutes: 31);
    final state = IncrementalMinuteMetrics();
    _summaryClose(
        state.sync(f.minuteKeys, f.hr,
            restingHr: 54,
            maxHr: 186,
            quietHrr: .12,
            includeMinuteSeries: false),
        f.hr);
    final work = state.processedMinutes;
    minuteClose(
        state.sync(f.minuteKeys, f.hr,
            restingHr: 54, maxHr: 186, quietHrr: .12),
        f.minuteKeys,
        f.hr);
    expect(state.processedMinutes, work);
    final p = energyProfiles['male']!;
    _summaryClose(
        state.sync(f.minuteKeys, f.hr,
            restingHr: 54,
            maxHr: 186,
            profile: p,
            quietHrr: .12,
            includeMinuteSeries: false),
        f.hr,
        profile: p);
  });
  test('day duration reprices only basal, across short, DST and long days', () {
    final f = incrementalFixture(seed: 5, minutes: 47);
    final p = energyProfiles.values.first;
    final state = IncrementalMinuteMetrics();
    MinuteMetrics sync(int dayMinutes) => state.sync(f.minuteKeys, f.hr,
        cadenceSpm: f.cadence,
        restingHr: 54,
        maxHr: 186,
        profile: p,
        quietHrr: .12,
        dayMinutes: dayMinutes,
        includeMinuteSeries: false);
    sync(1440);
    final work = state.processedMinutes;
    // Empty, one minute, an hour, both DST days, a whole and a double day, and
    // a negative count (batch multiplies it through; parity, not validation).
    for (final minutes in [0, 1, 60, 1380, 1439, 1440, 1441, 1500, 2880, -1]) {
      _summaryClose(sync(minutes), f.hr,
          cadence: f.cadence, profile: p, dayMinutes: minutes);
      expect(state.processedMinutes, work,
          reason: 'basal is a scalar over the day; no minute is repriced');
    }
  });
}
