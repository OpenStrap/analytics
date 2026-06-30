// Coaching surface — synthetic known-answer tests, incl. a regression for the
// physiological-age oversleep bug.
import 'package:test/test.dart';
import 'package:openstrap_analytics/src/onehz/types.dart';
import 'package:openstrap_analytics/src/onehz/human/coaching.dart';

void main() {
  group('sleepNeed', () {
    test('21 strain adds the full 45-min bonus', () {
      final m = sleepNeed(
        baselineNeedSec: 28800, // 8h
        sleepDebtSec: 0,
        dayStrain: 21.0,
        napCreditSec: 0,
      );
      expect(m.present, isTrue);
      expect(m.value!.needSec, closeTo(28800 + 2700, 1));
    });
    test('clamps to the 6–11 h band', () {
      final m = sleepNeed(
        baselineNeedSec: 999999,
        sleepDebtSec: 0,
        dayStrain: 0,
        napCreditSec: 0,
      );
      expect(m.value!.needSec, 11 * 3600.0);
    });
  });

  group('strainTarget', () {
    test('null recovery → absent', () {
      final m = strainTarget(
          recovery0to100: null, ctl: null, atl: null, tsb: null);
      expect(m.present, isFalse);
    });
    test('high recovery → push band', () {
      final m = strainTarget(
          recovery0to100: 90, ctl: null, atl: null, tsb: null);
      expect(m.value!.band, 'push');
    });
    test('low recovery → recover band', () {
      final m = strainTarget(
          recovery0to100: 20, ctl: null, atl: null, tsb: null);
      expect(m.value!.band, 'recover');
    });
  });

  group('vo2maxEstimate', () {
    test('Uth ratio; absent when maxHr <= restingHr', () {
      final ok = vo2maxEstimate(
          restingHr: 50, maxHr: 190, sex: Sex.male, age: 30);
      expect(ok.value!, closeTo(15.3 * 190 / 50, 1e-6));
      final bad = vo2maxEstimate(
          restingHr: 190, maxHr: 180, sex: Sex.male, age: 30);
      expect(bad.present, isFalse);
    });
  });

  group('physiologicalAge — sleep deviation (regression)', () {
    PhysioAge run(double h) => physiologicalAge(
          chronologicalAge: 30,
          sex: Sex.male,
          vo2max: null,
          restingHr: null,
          rmssd: null,
          sleepDurationH: h,
          sleepEfficiency: null,
          dailySteps: null,
        ).value!;

    test('oversleep does NOT make you younger', () {
      expect(run(9.0).physioAge, greaterThanOrEqualTo(30.0));
    });
    test('undersleep ages you', () {
      expect(run(6.0).physioAge, greaterThan(30.0));
    });
    test('optimal ~7.5h is neutral', () {
      expect(run(7.5).physioAge, closeTo(30.0, 0.01));
    });
    test('under and over by the same amount age you equally', () {
      expect(run(6.0).physioAge, closeTo(run(9.0).physioAge, 1e-9));
    });
  });
}
