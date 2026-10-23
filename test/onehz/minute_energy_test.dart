// Per-minute energy: the SAME computation `Calories.dailyEnergy` does, exposed
// minute by minute. Three things are pinned here:
//
//  1. dailyEnergy's outputs did not move (GOLDEN literals captured from the
//     implementation BEFORE the refactor; `==`, not closeTo). The consuming app
//     versions every derived day on these numbers.
//  2. the minute series folds back to dailyEnergy BIT-FOR-BIT.
//  3. a minute with nothing measured abstains — null and a reason, never a
//     filled or interpolated value.

import 'package:test/test.dart';
import 'package:openstrap_analytics/src/onehz/workout/calories.dart';
import 'support/energy_day.dart';

const _hrmax = 186.0;
const _rhr = 54.0; // gate = 54 + 0.40 * (186 - 54) = 106.8 bpm

// Captured from dailyEnergy at 7fe67a7 (before minuteEnergy existed), over
// `energyDay()` with hrmax 186 / restingHr 54 / dayMinutes 1440.
// (total, active, basal, walking)
const _golden = <String, (double, double, double, double)>{
  'male false': (8251.412972070117, 6460.162972070118, 1791.25, 0.0),
  'male true': (
    8854.354873246793,
    7063.104873246794,
    1791.25,
    602.9419011766767
  ),
  'female false': (5546.635132551552, 4258.885132551552, 1287.75, 0.0),
  'female true': (
    5980.096923613808,
    4692.346923613808,
    1287.75,
    433.4617910622563
  ),
  'nonbinary false': (
    6563.416347695368,
    5008.291347695368,
    1555.1249999999998,
    0.0
  ),
  'nonbinary true': (
    7086.877631194254,
    5531.752631194254,
    1555.1249999999998,
    523.4612834988859
  ),
};
// First 700 minutes, dayMinutes 900, male, with cadence.
const _goldenPartial =
    (4497.553602919252, 3378.0223529192513, 1119.53125, 311.26779559338775);

void main() {
  final day = energyDay();

  group('dailyEnergy is unchanged (golden)', () {
    for (final k in energyProfiles.keys) {
      for (final withCad in [false, true]) {
        test('$k cadence=$withCad', () {
          final e = Calories.dailyEnergy(day.hr,
              profile: energyProfiles[k]!,
              hrmax: _hrmax,
              restingHr: _rhr,
              cadenceSpmPerMin: withCad ? day.cadence : null)!;
          final g = _golden['$k $withCad']!;
          expect(e.total, g.$1);
          expect(e.active, g.$2);
          expect(e.basal, g.$3);
          expect(e.walking, g.$4);
        });
      }
    }
    test('partial day, dayMinutes pro-rates basal', () {
      final e = Calories.dailyEnergy(day.hr.sublist(0, 700),
          profile: energyProfiles['male']!,
          hrmax: _hrmax,
          restingHr: _rhr,
          dayMinutes: 900,
          cadenceSpmPerMin: day.cadence.sublist(0, 700))!;
      expect(e.total, _goldenPartial.$1);
      expect(e.active, _goldenPartial.$2);
      expect(e.basal, _goldenPartial.$3);
      expect(e.walking, _goldenPartial.$4);
    });
  });

  group('minuteEnergy folds back to dailyEnergy exactly', () {
    for (final k in energyProfiles.keys) {
      for (final withCad in [false, true]) {
        test('$k cadence=$withCad', () {
          final cad = withCad ? day.cadence : null;
          final d = Calories.dailyEnergy(day.hr,
              profile: energyProfiles[k]!,
              hrmax: _hrmax,
              restingHr: _rhr,
              cadenceSpmPerMin: cad)!;
          final s = Calories.minuteEnergy(day.hr,
              profile: energyProfiles[k]!,
              hrmax: _hrmax,
              restingHr: _rhr,
              cadenceSpmPerMin: cad)!;
          expect(s.minutes.length, day.hr.length);
          expect(s.active, d.active);
          expect(s.walking, d.walking);
          // basal is a rate × minutes, not a sum of 1440 additions.
          expect(s.basalKcalPerMin * 1440, d.basal);
          expect(s.basalKcalPerMin * 1440 + s.active, d.total);
        });
      }
    }

    test('the app path: zero-HR minutes dropped (with their cadence) before '
        'dailyEnergy equals the aligned series with that cadence masked', () {
      // lib/compute/derivation_engine.dart wakeDayEnergy compacts the series.
      final hr = <double>[];
      final cad = <double?>[];
      for (var i = 0; i < day.hr.length; i++) {
        if (day.hr[i] <= 0) continue;
        hr.add(day.hr[i]);
        cad.add(day.cadence[i]);
      }
      final compact = Calories.dailyEnergy(hr,
          profile: energyProfiles['female']!,
          hrmax: _hrmax,
          restingHr: _rhr,
          cadenceSpmPerMin: cad)!;
      final s = Calories.minuteEnergy(day.hr,
          profile: energyProfiles['female']!,
          hrmax: _hrmax,
          restingHr: _rhr,
          cadenceSpmPerMin: [
            for (var i = 0; i < day.hr.length; i++)
              day.hr[i] <= 0 ? null : day.cadence[i]
          ])!;
      expect(s.active, compact.active);
      expect(s.walking, compact.walking);
    });

    test('partial series', () {
      final s = Calories.minuteEnergy(day.hr.sublist(0, 700),
          profile: energyProfiles['male']!,
          hrmax: _hrmax,
          restingHr: _rhr,
          cadenceSpmPerMin: day.cadence.sublist(0, 700))!;
      expect(s.active, _goldenPartial.$2);
      expect(s.walking, _goldenPartial.$4);
      expect(s.basalKcalPerMin * 900, _goldenPartial.$3);
    });
  });

  group('per-minute rules', () {
    const p = WorkoutUserProfile(
        weightKg: 80, heightCm: 180, age: 30, sex: 'male');
    final basal = Calories.mifflinBmrKcalDay(80, 180, 30, 'male') / 1440.0;

    MinuteEnergySeries run(List<double> hr, {List<double?>? cad, List<int>? at}) =>
        Calories.minuteEnergy(hr,
            profile: p,
            hrmax: _hrmax,
            restingHr: _rhr,
            cadenceSpmPerMin: cad,
            epochMinutes: at)!;

    test('resting HR: measured rest, basal only', () {
      final m = run([70.0]).minutes.single;
      expect(m.source, MinuteEnergySource.rest);
      expect(m.abstained, isNull);
      expect(m.basal, basal);
      expect(m.active, 0.0);
      expect(m.walking, isNull);
      expect(m.total, basal);
    });

    test('HR over the gate: Keytel surplus over basal', () {
      final coeffs = Calories.resolveCoeffs('male');
      final surplus = Calories.activeKcalPerS(coeffs, 150.0, _hrmax, 80, 30) *
              60.0 -
          basal;
      final m = run([150.0]).minutes.single;
      expect(m.source, MinuteEnergySource.hr);
      expect(m.active, surplus);
      expect(m.walking, isNull);
      expect(m.total, basal + surplus);
    });

    test('no usable HR and no cadence abstains: null everywhere + reason', () {
      for (final bad in [0.0, -3.0, double.nan, double.infinity]) {
        final m = run([bad]).minutes.single;
        expect(m.abstained, MinuteEnergyAbstain.noHr, reason: '$bad');
        expect(m.source, isNull);
        expect(m.basal, isNull);
        expect(m.active, isNull);
        expect(m.walking, isNull);
        expect(m.total, isNull);
      }
    });

    test('a minute is computed from its own inputs only (no fill, no smoothing)',
        () {
      final a = run([70.0, 0.0, 150.0]).minutes;
      final b = run([70.0, 0.0, 120.0]).minutes;
      expect(a[1].total, isNull);
      expect(b[1].total, isNull);
      expect(a[0].total, b[0].total);
      expect(a[2].total, isNot(b[2].total));
    });

    test('cadence on a sub-flex minute bills walking surplus', () {
      final m = run([80.0], cad: [120.0]).minutes.single; // 5 METs
      expect(m.source, MinuteEnergySource.cadence);
      expect(m.walking, (5.0 - 1.0) * basal);
      expect(m.active, m.walking);
      expect(m.total, basal + m.walking!);
    });

    test('cadence on an HR-billed minute is not billed twice', () {
      final m = run([150.0], cad: [120.0]).minutes.single;
      expect(m.source, MinuteEnergySource.hr);
      expect(m.walking, isNull);
    });

    test('cadence below the CADENCE-Adults floor bills nothing', () {
      expect(run([80.0], cad: [95.0]).minutes.single.source,
          MinuteEnergySource.rest);
      expect(run([0.0], cad: [95.0]).minutes.single.abstained,
          MinuteEnergyAbstain.noHr);
    });

    test('cadence with no HR is still measured gait (same as dailyEnergy)', () {
      final m = run([0.0], cad: [110.0]).minutes.single;
      expect(m.source, MinuteEnergySource.cadence);
      expect(m.walking, (4.0 - 1.0) * basal); // 110 spm = 4 METs
    });

    test('minute carries its epoch minute when given, else its index', () {
      expect(run([70.0, 70.0]).minutes.map((m) => m.minute), [0, 1]);
      expect(run([70.0, 70.0], at: [29000000, 29000007]).minutes
          .map((m) => m.minute), [29000000, 29000007]);
    });

    test('coverage counters', () {
      final s = run([70.0, 0.0, 150.0, double.nan]);
      expect(s.coveredMinutes, 2);
      expect(s.abstainedMinutes, 2);
    });
  });

  group('input contract', () {
    const p = WorkoutUserProfile();
    test('unusable anchors → null, like dailyEnergy', () {
      for (final (mx, rest) in [
        (186.0, 0.0),
        (186.0, 190.0),
        (double.nan, 54.0),
        (186.0, double.nan),
      ]) {
        expect(
            Calories.minuteEnergy([100.0],
                profile: p, hrmax: mx, restingHr: rest),
            isNull);
      }
    });
    test('misaligned cadence / epochMinutes throw', () {
      expect(
          () => Calories.minuteEnergy([100.0, 100.0],
              profile: p,
              hrmax: _hrmax,
              restingHr: _rhr,
              cadenceSpmPerMin: [null]),
          throwsArgumentError);
      expect(
          () => Calories.minuteEnergy([100.0, 100.0],
              profile: p,
              hrmax: _hrmax,
              restingHr: _rhr,
              epochMinutes: [1]),
          throwsArgumentError);
    });
    test('empty input → empty series, zero everything', () {
      final s = Calories.minuteEnergy(const [],
          profile: p, hrmax: _hrmax, restingHr: _rhr)!;
      expect(s.minutes, isEmpty);
      expect(s.active, 0.0);
    });
  });

  group('hourlyRollup', () {
    final s = Calories.minuteEnergy(day.hr,
        profile: energyProfiles['male']!,
        hrmax: _hrmax,
        restingHr: _rhr,
        cadenceSpmPerMin: day.cadence)!;

    test('24 hourly buckets over a full index-aligned day', () {
      final h = Calories.hourlyRollup(s.minutes);
      expect(h.length, 24);
      expect([for (final b in h) b.hour], List.generate(24, (i) => i));
    });

    test('hour sums are the sums of its covered minutes, with coverage', () {
      final h = Calories.hourlyRollup(s.minutes);
      for (final b in h) {
        var active = 0.0, total = 0.0, cov = 0;
        for (var m = b.hour * 60; m < b.hour * 60 + 60; m++) {
          final r = s.minutes[m];
          if (r.abstained != null) continue;
          active += r.active!;
          total += r.total!;
          cov++;
        }
        expect(b.coveredMinutes, cov);
        expect(b.coverage, cov / 60.0);
        expect(b.active, active);
        expect(b.total, total);
      }
      expect(h.fold<double>(0, (a, b) => a + b.active!),
          closeTo(s.active, 1e-9));
    });

    test('an hour with no covered minute is null, not zero', () {
      final hr = [for (var i = 0; i < 120; i++) i < 60 ? 0.0 : 70.0];
      final h = Calories.hourlyRollup(Calories.minuteEnergy(hr,
              profile: energyProfiles['male']!,
              hrmax: _hrmax,
              restingHr: _rhr)!
          .minutes);
      expect(h[0].coveredMinutes, 0);
      expect(h[0].coverage, 0.0);
      expect(h[0].total, isNull);
      expect(h[0].active, isNull);
      expect(h[0].basal, isNull);
      expect(h[1].coveredMinutes, 60);
      expect(h[1].total, isNotNull);
    });

    test('partial hour is a partial sum, flagged by coverage, not scaled', () {
      final r = Calories.minuteEnergy([for (var i = 0; i < 30; i++) 70.0],
          profile: energyProfiles['male']!, hrmax: _hrmax, restingHr: _rhr)!;
      final h = Calories.hourlyRollup(r.minutes);
      expect(h.single.coveredMinutes, 30);
      expect(h.single.coverage, 0.5);
      expect(h.single.basal, closeTo(30 * r.basalKcalPerMin, 1e-9)); // not 60
    });

    test('epoch minutes bucket by local hour via minuteOffset', () {
      // epoch minute 600 = 10:00 UTC. +330 (UTC+5:30) → 15:30.
      final at = [600, 601, 629, 630];
      final r = Calories.minuteEnergy([70.0, 70.0, 70.0, 70.0],
          profile: energyProfiles['male']!,
          hrmax: _hrmax,
          restingHr: _rhr,
          epochMinutes: at)!;
      final utc = Calories.hourlyRollup(r.minutes);
      expect([for (final b in utc) b.hour], [10]);
      final ist = Calories.hourlyRollup(r.minutes, minuteOffset: 330);
      expect([for (final b in ist) b.hour], [15, 16]);
      expect([for (final b in ist) b.coveredMinutes], [3, 1]);
    });
  });
}
