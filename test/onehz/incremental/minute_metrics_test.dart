import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';
import '../support/energy_day.dart';
import '../support/incremental_compare.dart';
import '../support/incremental_fixtures.dart';

void main() {
  for (final entry in energyProfiles.entries) {
    for (final sex in Sex.values) {
      for (final chunk in [1, 19, 128]) {
        test('minutes profile=${entry.key} sex=$sex chunk=$chunk', () {
          final f = incrementalFixture(minutes: 87);
          var state = IncrementalMinuteMetrics();
          for (final n in prefixSizes(f.hr.length, chunk)) {
            final keys = f.minuteKeys.sublist(0, n), hr = f.hr.sublist(0, n);
            final cadence = f.cadence.sublist(0, n);
            final value = state.sync(keys, hr,
                cadenceSpm: cadence,
                restingHr: 54,
                maxHr: 186,
                sex: sex,
                profile: entry.value,
                quietHrr: .12,
                dayMinutes: 900);
            minuteClose(value, keys, hr,
                cadence: cadence,
                sex: sex,
                profile: entry.value,
                dayMinutes: 900);
            final work = state.processedMinutes;
            state.sync(keys, hr,
                cadenceSpm: cadence,
                restingHr: 54,
                maxHr: 186,
                sex: sex,
                profile: entry.value,
                quietHrr: .12,
                dayMinutes: 900);
            expect(state.processedMinutes, work);
            if (n == 31 || n == f.hr.length) {
              state =
                  IncrementalMinuteMetrics.fromJson(checkpoint(state.toJson()));
            }
          }
          expect(state.processedMinutes, f.hr.length,
              reason: 'each new minute is billed once');
        });
      }
    }
  }
  for (final anchors in <(double?, double?)>[
    (null, null),
    (54, null),
    (null, 186),
    (54, 54),
    (70, 60),
    (double.nan, 186),
    (54, double.infinity),
    (54, 186),
  ]) {
    test('minute measured HR anchor gates $anchors', () {
      final f = incrementalFixture(minutes: 31);
      final profile = energyProfiles['male']!;
      final state = IncrementalMinuteMetrics();
      final value = state.sync(f.minuteKeys, f.hr,
          restingHr: anchors.$1,
          maxHr: anchors.$2,
          profile: profile,
          quietHrr: .12);
      minuteClose(value, f.minuteKeys, f.hr,
          rhr: anchors.$1, maxHr: anchors.$2, profile: profile);
    });
  }
  for (final quiet in <double?>[null, 0, -.1, .12, double.nan]) {
    test('minute quiet waking HRR gate $quiet', () {
      final f = incrementalFixture(minutes: 31);
      minuteClose(
          IncrementalMinuteMetrics().sync(f.minuteKeys, f.hr,
              restingHr: 54, maxHr: 186, quietHrr: quiet),
          f.minuteKeys,
          f.hr,
          quietHrr: quiet);
    });
  }
  test('minute sparse arbitrary keyed edits bill only affected minutes', () {
    final f = incrementalFixture(minutes: 50);
    final profile = energyProfiles['female']!;
    var keys = [...f.minuteKeys], hr = [...f.hr];
    var cadence = [...f.cadence];
    final state = IncrementalMinuteMetrics();
    MinuteMetrics sync() => state.sync(keys, hr,
        cadenceSpm: cadence,
        restingHr: 54,
        maxHr: 186,
        profile: profile,
        quietHrr: .12);
    void check() =>
        minuteClose(sync(), keys, hr, cadence: cadence, profile: profile);
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
    expect(state.processedMinutes, 53,
        reason: 'deletion removes existing bill');
    keys = keys.reversed.toList();
    hr = hr.reversed.toList();
    cadence = cadence.reversed.toList();
    check();
    expect(state.processedMinutes, 53,
        reason: 'same keyed minutes may be reordered');
    keys[0] += 10000;
    check();
    expect(state.processedMinutes, 54);
    final work = state.processedMinutes;
    minuteClose(
        state.sync(keys, hr,
            cadenceSpm: cadence,
            restingHr: 54,
            maxHr: 186,
            profile: profile,
            quietHrr: .12,
            force: true),
        keys,
        hr,
        cadence: cadence,
        profile: profile);
    expect(state.processedMinutes - work, keys.length);
  });
  test(
      'minute parameter changes recompute sex, profiles, anchors and day totals',
      () {
    final f = incrementalFixture(minutes: 47);
    final state = IncrementalMinuteMetrics();
    for (final entry in energyProfiles.entries) {
      for (final sex in Sex.values) {
        for (final rhr in [54.0, 65.0]) {
          final value = state.sync(f.minuteKeys, f.hr,
              cadenceSpm: f.cadence,
              restingHr: rhr,
              maxHr: 190,
              profile: entry.value,
              sex: sex,
              quietHrr: .18,
              dayMinutes: 700);
          minuteClose(value, f.minuteKeys, f.hr,
              cadence: f.cadence,
              rhr: rhr,
              maxHr: 190,
              profile: entry.value,
              sex: sex,
              quietHrr: .18,
              dayMinutes: 700);
        }
      }
    }
    final p = energyProfiles['male']!;
    minuteClose(
        state.sync(f.minuteKeys, f.hr,
            restingHr: 54,
            maxHr: 186,
            profile: p,
            dayMinutes: 0,
            quietHrr: .12),
        f.minuteKeys,
        f.hr,
        profile: p,
        dayMinutes: 0);
    minuteClose(
        state.sync(f.minuteKeys, f.hr,
            restingHr: 54,
            maxHr: 186,
            profile: p,
            dayMinutes: 900,
            quietHrr: .12),
        f.minuteKeys,
        f.hr,
        profile: p,
        dayMinutes: 900);
  });
  test('minute nonfinite HR/cadence and absent HR use exact abstentions', () {
    final day = energyDay(n: 100);
    final keys = List.generate(day.hr.length, (i) => i * 3);
    final p = energyProfiles['nonbinary']!;
    final state = IncrementalMinuteMetrics();
    for (final n in prefixSizes(day.hr.length, 13)) {
      final k = keys.sublist(0, n),
          h = day.hr.sublist(0, n),
          c = day.cadence.sublist(0, n);
      minuteClose(
          state.sync(k, h,
              cadenceSpm: c,
              restingHr: 54,
              maxHr: 186,
              profile: p,
              quietHrr: .12),
          k,
          h,
          cadence: c,
          profile: p);
    }
  });
  test(
      'minute JSON checkpoint continues exact precision with keyed replacement',
      () {
    final f = incrementalFixture(minutes: 61);
    final hr = f.hr.map((x) => x + .0123456789123).toList();
    final p = energyProfiles['male']!;
    final first = IncrementalMinuteMetrics();
    first.sync(f.minuteKeys.sublist(0, 31), hr.sublist(0, 31),
        restingHr: 54, maxHr: 186, profile: p, quietHrr: .12);
    final state = IncrementalMinuteMetrics.fromJson(checkpoint(first.toJson()));
    hr[17] += 5.123456789123;
    minuteClose(
        state.sync(f.minuteKeys, hr,
            restingHr: 54, maxHr: 186, profile: p, quietHrr: .12),
        f.minuteKeys,
        hr,
        profile: p);
    expect(state.processedMinutes, 62);
  });
  test(
      'minute real capture means and sparse keys match batch load and calories',
      () {
    final f = realIncrementalFixture();
    expect(f.hr.length, 15);
    final p = energyProfiles['male']!;
    final state = IncrementalMinuteMetrics();
    for (var n = 0; n <= f.hr.length; n++) {
      final k = f.minuteKeys.sublist(0, n), h = f.hr.sublist(0, n);
      minuteClose(
          state.sync(k, h,
              restingHr: 54, maxHr: 186, profile: p, quietHrr: .12),
          k,
          h,
          profile: p);
    }
  });
}
