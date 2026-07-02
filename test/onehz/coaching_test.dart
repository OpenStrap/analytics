// Coaching surface — synthetic known-answer tests, incl. a regression for the
// physiological-age oversleep bug. Covers PR #11's untested coaching API.
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
      expect(m.tier, Tier.estimate);
      expect(m.confidence, closeTo(0.6, 1e-9));
      expect(m.value!.needSec, closeTo(28800 + 2700, 1));
    });

    test('mid case: baseline + debt + partial strain bonus − nap credit', () {
      // strain 10.5 → bonus = (10.5/21)*2700 = 1350 s.
      // 28800 + 3600 + 1350 − 1800 = 31950, inside the [6h,11h] band.
      final m = sleepNeed(
        baselineNeedSec: 28800,
        sleepDebtSec: 3600,
        dayStrain: 10.5,
        napCreditSec: 1800,
      );
      expect(m.value!.needSec, closeTo(31950, 1e-6));
    });

    test('nap credit is subtracted', () {
      final base = sleepNeed(
        baselineNeedSec: 28800,
        sleepDebtSec: 0,
        dayStrain: 0,
        napCreditSec: 0,
      ).value!.needSec;
      final withNap = sleepNeed(
        baselineNeedSec: 28800,
        sleepDebtSec: 0,
        dayStrain: 0,
        napCreditSec: 1800,
      ).value!.needSec;
      expect(withNap, closeTo(base - 1800, 1e-6));
    });

    test('clamps to the 11 h ceiling', () {
      final m = sleepNeed(
        baselineNeedSec: 999999,
        sleepDebtSec: 0,
        dayStrain: 0,
        napCreditSec: 0,
      );
      expect(m.value!.needSec, 11 * 3600.0);
    });

    test('clamps to the 6 h floor (huge nap credit cannot go below 6h)', () {
      final m = sleepNeed(
        baselineNeedSec: 28800,
        sleepDebtSec: 0,
        dayStrain: 0,
        napCreditSec: 999999,
      );
      expect(m.value!.needSec, 6 * 3600.0);
    });
  });

  group('sleepPerformance', () {
    test('exact need → 100%', () {
      final m = sleepPerformance(28800, 28800);
      expect(m.present, isTrue);
      expect(m.tier, Tier.estimate);
      expect(m.confidence, closeTo(0.7, 1e-9));
      expect(m.value!.pct, closeTo(100.0, 1e-9));
    });

    test('half of need → 50%', () {
      expect(sleepPerformance(14400, 28800).value!.pct, closeTo(50.0, 1e-9));
    });

    test('over-need caps at 100%', () {
      expect(sleepPerformance(40000, 28800).value!.pct, closeTo(100.0, 1e-9));
    });

    test('zero sleep → 0%', () {
      expect(sleepPerformance(0, 28800).value!.pct, closeTo(0.0, 1e-9));
    });

    test('non-positive need → absent (no divide-by-zero)', () {
      expect(sleepPerformance(28800, 0).present, isFalse);
      expect(sleepPerformance(28800, -1).present, isFalse);
    });
  });

  group('recommendedBedtime', () {
    test('backward math from wake time, efficiency-adjusted time-in-bed', () {
      // need 8h=28800s, eff 90%→0.90, inBed=32000s=533.333min.
      // wake 07:00 = 420 min. bed = (420 − 533.333) mod 1440 → 1326.667.
      final m = recommendedBedtime(
        needSec: 28800,
        typicalWakeMinOfDay: 420,
        typicalEfficiencyPct: 90,
      );
      expect(m.present, isTrue);
      expect(m.tier, Tier.estimate);
      expect(m.value!.bedtimeMinOfDay, closeTo(1326.6667, 1e-3));
    });

    test('efficiency is clamped to [0.75, 0.99]', () {
      // A wild 200% efficiency is clamped to 0.99, not >1.
      final m = recommendedBedtime(
        needSec: 28800,
        typicalWakeMinOfDay: 600,
        typicalEfficiencyPct: 200,
      );
      // inBed = 28800/0.99 = 29090.9s = 484.848 min; bed = 600 − 484.848 = 115.152.
      expect(m.value!.bedtimeMinOfDay, closeTo(115.1515, 1e-3));
    });

    test('minute-of-day never goes negative (wraparound to [0,1440))', () {
      final m = recommendedBedtime(
        needSec: 28800,
        typicalWakeMinOfDay: 60, // 01:00 wake → bed the previous "day"
        typicalEfficiencyPct: 90,
      );
      expect(m.value!.bedtimeMinOfDay, greaterThanOrEqualTo(0.0));
      expect(m.value!.bedtimeMinOfDay, lessThan(1440.0));
    });
  });

  group('recommendedWake', () {
    test('90-minute cycle-aligned wake from bedtime', () {
      // bed 23:00 = 1380, need 7.5h=27000s=450min → round(450/90)=5 cycles.
      // wake = (1380 + 5*90) mod 1440 = 1830 mod 1440 = 390 = 06:30.
      final m = recommendedWake(bedtimeMinOfDay: 1380, needSec: 27000);
      expect(m.present, isTrue);
      expect(m.tier, Tier.estimate);
      expect(m.confidence, closeTo(0.55, 1e-9));
      expect(m.value!.wakeMinOfDay, closeTo(390.0, 1e-9));
    });

    test('cycles floor at 1 for tiny need', () {
      // need 30 min → round(30/90)=0 → max(1,0)=1 cycle = 90 min.
      final m = recommendedWake(bedtimeMinOfDay: 100, needSec: 1800);
      expect(m.value!.wakeMinOfDay, closeTo(190.0, 1e-9));
    });

    test('wraps around midnight into [0,1440)', () {
      // bed 23:30=1410, need ~7.5h → 5 cycles=450 → 1860 mod 1440 = 420.
      final m = recommendedWake(bedtimeMinOfDay: 1410, needSec: 27000);
      expect(m.value!.wakeMinOfDay, closeTo(420.0, 1e-9));
      expect(m.value!.wakeMinOfDay, lessThan(1440.0));
    });
  });

  group('strainTarget', () {
    test('null recovery → absent', () {
      final m =
          strainTarget(recovery0to100: null, ctl: null, atl: null, tsb: null);
      expect(m.present, isFalse);
    });

    test('recovery bands: recover / ease / maintain / push', () {
      expect(
          strainTarget(recovery0to100: 20, ctl: null, atl: null, tsb: null)
              .value!
              .band,
          'recover');
      expect(
          strainTarget(recovery0to100: 50, ctl: null, atl: null, tsb: null)
              .value!
              .band,
          'ease');
      expect(
          strainTarget(recovery0to100: 70, ctl: null, atl: null, tsb: null)
              .value!
              .band,
          'maintain');
      expect(
          strainTarget(recovery0to100: 90, ctl: null, atl: null, tsb: null)
              .value!
              .band,
          'push');
    });

    test('maintain band base window is [10,15]', () {
      final m =
          strainTarget(recovery0to100: 70, ctl: null, atl: null, tsb: null);
      expect(m.value!.targetMin, closeTo(10, 1e-9));
      expect(m.value!.targetMax, closeTo(15, 1e-9));
      expect(m.tier, Tier.estimate);
      expect(m.confidence, closeTo(0.6, 1e-9));
    });

    test('high fatigue (atl−ctl>10) lowers the window', () {
      // maintain base [10,15]; fatigue = 30−10 = 20 (>10) → lo−1, hi−2 → [9,13].
      final m = strainTarget(recovery0to100: 70, ctl: 10, atl: 30, tsb: null);
      expect(m.value!.targetMin, closeTo(9, 1e-9));
      expect(m.value!.targetMax, closeTo(13, 1e-9));
    });

    test('positive freshness (tsb>5) raises the ceiling', () {
      // maintain base [10,15]; low fatigue so tsb branch applies → hi+1 → [10,16].
      final m = strainTarget(recovery0to100: 70, ctl: 20, atl: 20, tsb: 8);
      expect(m.value!.targetMin, closeTo(10, 1e-9));
      expect(m.value!.targetMax, closeTo(16, 1e-9));
    });

    test('targets stay within [0,21] and hi > lo', () {
      final m = strainTarget(recovery0to100: 90, ctl: null, atl: null, tsb: 99);
      expect(m.value!.targetMin, greaterThanOrEqualTo(0.0));
      expect(m.value!.targetMax, lessThanOrEqualTo(21.0));
      expect(m.value!.targetMax, greaterThan(m.value!.targetMin));
    });
  });

  group('vo2maxEstimate', () {
    test('Uth ratio 15.3×maxHr/restingHr on a known value', () {
      final m = vo2maxEstimate(restingHr: 50, maxHr: 190, sex: Sex.male, age: 30);
      expect(m.present, isTrue);
      expect(m.tier, Tier.estimate);
      expect(m.confidence, closeTo(0.45, 1e-9));
      expect(m.value!, closeTo(15.3 * 190 / 50, 1e-6)); // 58.14
    });

    test('absent when maxHr <= restingHr (no divide-by-invalid)', () {
      expect(
          vo2maxEstimate(restingHr: 190, maxHr: 180, sex: Sex.male, age: 30)
              .present,
          isFalse);
    });

    test('absent on null restingHr / null maxHr (no divide-by-zero)', () {
      expect(
          vo2maxEstimate(restingHr: null, maxHr: 190, sex: Sex.male, age: 30)
              .present,
          isFalse);
      expect(
          vo2maxEstimate(restingHr: 50, maxHr: null, sex: Sex.male, age: 30)
              .present,
          isFalse);
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
      expect(run(10.0).physioAge, greaterThan(30.0));
    });
    test('undersleep ages you', () {
      expect(run(5.0).physioAge, greaterThan(30.0));
    });
    test('optimal ~7.5h is neutral', () {
      expect(run(7.5).physioAge, closeTo(30.0, 0.01));
    });
    test('symmetry: 5h and 10h age you by the same amount', () {
      // Both are 2.5h from the 7.5h optimum → identical penalty.
      expect(run(5.0).physioAge, closeTo(run(10.0).physioAge, 1e-9));
    });

    test('baseline case: better-than-average biomarkers lower physio age', () {
      final m = physiologicalAge(
        chronologicalAge: 40,
        sex: Sex.male,
        vo2max: 50, // above 35 → subtracts
        restingHr: 48, // below 60 → subtracts
        rmssd: 60, // above 35 → subtracts
        sleepDurationH: 7.5, // optimal → neutral
        sleepEfficiency: 94, // above 88 → subtracts
        dailySteps: 12000, // above 7000 → subtracts
      );
      expect(m.present, isTrue);
      expect(m.tier, Tier.estimate);
      expect(m.value!.physioAge, lessThan(40.0));
      expect(m.value!.deltaYears, lessThan(0.0));
      expect(m.value!.deltaYears,
          closeTo(m.value!.physioAge - 40.0, 1e-9));
    });

    test('physio age is clamped to [18,95]', () {
      final young = physiologicalAge(
        chronologicalAge: 18,
        sex: Sex.female,
        vo2max: 80,
        restingHr: 40,
        rmssd: 120,
        sleepDurationH: 7.5,
        sleepEfficiency: 99,
        dailySteps: 20000,
      );
      expect(young.value!.physioAge, greaterThanOrEqualTo(18.0));
      final old = physiologicalAge(
        chronologicalAge: 95,
        sex: Sex.male,
        vo2max: 10,
        restingHr: 100,
        rmssd: 5,
        sleepDurationH: 3,
        sleepEfficiency: 60,
        dailySteps: 0,
      );
      expect(old.value!.physioAge, lessThanOrEqualTo(95.0));
    });
  });

  group('journalCorrelations', () {
    test('insufficient sample (<2 per side) is gated as insufficient', () {
      // Only one tagged day for "coffee" → cannot compare.
      final journal = <JournalDay>[
        const JournalDay('d0', {'coffee'}),
        const JournalDay('d1', {}),
        const JournalDay('d2', {}),
      ];
      final dates = ['d0', 'd1', 'd2'];
      final outcomes = <String, List<double?>>{
        'recovery': [60, 62, 64],
      };
      final out = journalCorrelations(
          journal: journal, dates: dates, outcomes: outcomes);
      final coffee = out.firstWhere((c) => c.tag == 'coffee');
      final eff = coffee.effects.single;
      expect(eff.insufficient, isTrue);
      expect(eff.meaningful, isFalse);
      expect(eff.nTagged, 1);
      expect(eff.higherSide, 'neither');
    });

    test('clear positive correlation is detected and marked meaningful', () {
      // "alcohol" days have clearly lower recovery than untagged days.
      final journal = <JournalDay>[
        const JournalDay('d0', {'alcohol'}),
        const JournalDay('d1', {'alcohol'}),
        const JournalDay('d2', {}),
        const JournalDay('d3', {}),
      ];
      final dates = ['d0', 'd1', 'd2', 'd3'];
      final outcomes = <String, List<double?>>{
        'recovery': [40, 42, 80, 82], // tagged mean 41, untagged mean 81
      };
      final out = journalCorrelations(
          journal: journal, dates: dates, outcomes: outcomes);
      final eff =
          out.firstWhere((c) => c.tag == 'alcohol').effects.single;
      expect(eff.insufficient, isFalse);
      expect(eff.meaningful, isTrue);
      expect(eff.delta, closeTo(41 - 81, 1e-9)); // −40
      expect(eff.higherSide, 'untagged'); // untagged (non-alcohol) recovers more
      expect(eff.nTagged, 2);
      expect(eff.nUntagged, 2);
      expect(eff.pctChange, isNotNull);
      expect(eff.pctChange!.abs(), greaterThanOrEqualTo(3.0));
    });

    test('nulls are dropped from both sides before comparing', () {
      final journal = <JournalDay>[
        const JournalDay('d0', {'x'}),
        const JournalDay('d1', {'x'}),
        const JournalDay('d2', {}),
        const JournalDay('d3', {}),
      ];
      final dates = ['d0', 'd1', 'd2', 'd3'];
      final outcomes = <String, List<double?>>{
        'hrv': [50, null, 60, 60], // tagged has only 1 valid → insufficient
      };
      final out = journalCorrelations(
          journal: journal, dates: dates, outcomes: outcomes);
      final eff = out.firstWhere((c) => c.tag == 'x').effects.single;
      expect(eff.nTagged, 1);
      expect(eff.insufficient, isTrue);
    });

    test('empty journal yields no correlations', () {
      final out = journalCorrelations(
        journal: const [],
        dates: const ['d0', 'd1'],
        outcomes: const {
          'recovery': [50, 60]
        },
      );
      expect(out, isEmpty);
    });
  });

  group('detectNaps (honest stub)', () {
    test('returns an empty nap list with zero confidence — no fabrication', () {
      final m = detectNaps(const <AccelSample>[], const <double>[]);
      expect(m.value, isNotNull); // an (empty) list, not a null
      expect(m.value, isEmpty);
      expect(m.confidence, 0);
      expect(m.tier, Tier.estimate);
      expect(m.note, contains('nap detection unavailable'));
    });

    test('still empty even when handed plausible sleep-like input', () {
      final accel = <AccelSample>[
        for (var i = 0; i < 100; i++) AccelSample(i * 1000.0, 0, 0, 1),
      ];
      final hr = <double>[for (var i = 0; i < 100; i++) 52.0];
      final m = detectNaps(accel, hr,
          mainSleep: const SleepWindowSpan(0, 30000));
      expect(m.value, isEmpty);
    });
  });
}
