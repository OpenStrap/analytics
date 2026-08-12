// Coaching surface — synthetic known-answer tests, incl. a regression for the
// physiological-age oversleep bug. Covers PR #11's untested coaching API.
import 'dart:convert';

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

    test('maintain band base window is [9,14]', () {
      final m =
          strainTarget(recovery0to100: 70, ctl: null, atl: null, tsb: null);
      expect(m.value!.targetMin, closeTo(9, 1e-9));
      expect(m.value!.targetMax, closeTo(14, 1e-9));
      expect(m.tier, Tier.estimate);
      expect(m.confidence, closeTo(0.6, 1e-9));
    });

    test('REGRESSION: a recover target is reachable, not below the floor', () {
      // The bands were sized for a scale the app never produced: "recover 4–8"
      // sat BELOW what an inactive worn day scored (~13 on the old map), so a
      // low-recovery day asked for a number the user had already passed before
      // getting out of bed. A recover ceiling must sit above a rest day (2–4)
      // and below a typical active day (8–11).
      final m = strainTarget(recovery0to100: 20, ctl: null, atl: null, tsb: null);
      expect(m.value!.band, 'recover');
      expect(m.value!.targetMin, closeTo(0, 1e-9));
      expect(m.value!.targetMax, greaterThan(4.0));
      expect(m.value!.targetMax, lessThan(8.0));
    });

    test('a push target stays inside what a real day can reach', () {
      // 21 is a maximal day. A push ceiling above ~19 is not a target, it is a
      // dare — the old band topped out at 18 on a scale whose real ceiling was
      // ~16 for a marathon.
      final m = strainTarget(recovery0to100: 90, ctl: null, atl: null, tsb: null);
      expect(m.value!.band, 'push');
      expect(m.value!.targetMin, closeTo(13, 1e-9));
      expect(m.value!.targetMax, lessThanOrEqualTo(19.0));
    });

    test('fatigue is judged on the ATL:CTL RATIO, not a raw TRIMP difference', () {
      // ctl/atl arrive as raw daily TRIMP (hundreds), but the thresholds were
      // sized as if they were 0–21 strain points: `atl − ctl > 10` fired on
      // ordinary week-to-week noise. 320 vs 300 is a 6.7 % lift — not fatigue —
      // yet the old absolute test (diff 20 > 10) shrank the window for it.
      final noise = strainTarget(recovery0to100: 70, ctl: 300, atl: 320, tsb: null);
      expect(noise.value!.targetMin, closeTo(9, 1e-9));
      expect(noise.value!.targetMax, closeTo(14, 1e-9));

      // A genuine 30 % acute lift over chronic still lowers the window.
      final real = strainTarget(recovery0to100: 70, ctl: 100, atl: 130, tsb: null);
      expect(real.value!.targetMin, closeTo(8, 1e-9));
      expect(real.value!.targetMax, closeTo(12, 1e-9));
    });

    test('freshness is judged on TSB relative to CTL, not a raw TRIMP value', () {
      // tsb 6 against a chronic load of 300 is 2 % — noise, not freshness.
      final noise = strainTarget(recovery0to100: 70, ctl: 300, atl: 294, tsb: 6);
      expect(noise.value!.targetMax, closeTo(14, 1e-9));

      // tsb 20 against a chronic load of 100 is a real 20 % taper.
      final real = strainTarget(recovery0to100: 70, ctl: 100, atl: 80, tsb: 20);
      expect(real.value!.targetMax, closeTo(15, 1e-9));
    });

    test('no load history leaves the recovery window untouched', () {
      final m = strainTarget(recovery0to100: 70, ctl: null, atl: null, tsb: null);
      expect(m.value!.targetMin, closeTo(9, 1e-9));
      expect(m.value!.targetMax, closeTo(14, 1e-9));
      // A zero chronic load must not divide by zero into an adjustment.
      final zero = strainTarget(recovery0to100: 70, ctl: 0, atl: 0, tsb: 0);
      expect(zero.value!.targetMin, closeTo(9, 1e-9));
      expect(zero.value!.targetMax, closeTo(14, 1e-9));
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

  // -------------------------------------------------------------------------
  // REGRESSION: physiologicalAge must ABSTAIN with no physiology, and must
  // report the inputs it ACTUALLY used.
  // -------------------------------------------------------------------------
  group('physiologicalAge — honesty envelope (regression)', () {
    test('every physiological input null => ABSENT, not "your age"', () {
      // PRE-FIX: score started at chronologicalAge, nothing moved it, and the
      // function returned a PRESENT metric (physioAge 30, delta 0, conf 0.35)
      // claiming six inputs it had never seen.
      final m = physiologicalAge(
        chronologicalAge: 30,
        sex: Sex.male,
        vo2max: null,
        restingHr: null,
        rmssd: null,
        sleepDurationH: null,
        sleepEfficiency: null,
        dailySteps: null,
      );
      expect(m.present, isFalse);
      expect(m.value, isNull);
      expect(m.confidence, 0);
      expect(m.toJson()['value'], '—');
      expect(m.inputs_used, ['profile']);
    });

    test('inputs_used lists only the inputs actually supplied', () {
      // PRE-FIX this was a hardcoded six-entry list in EVERY partial case.
      final m = physiologicalAge(
        chronologicalAge: 30,
        sex: Sex.male,
        vo2max: null,
        restingHr: 55,
        rmssd: null,
        sleepDurationH: 7.5,
        sleepEfficiency: null,
        dailySteps: null,
      );
      expect(m.present, isTrue);
      expect(m.inputs_used, ['profile', 'resting_hr', 'sleep_duration']);
      expect(m.inputs_used, isNot(contains('vo2max')));
      expect(m.inputs_used, isNot(contains('rmssd')));
      expect(m.inputs_used, isNot(contains('steps')));
    });

    test('confidence scales with how much physiology went in', () {
      Metric<PhysioAge> build(int n) => physiologicalAge(
            chronologicalAge: 40,
            sex: Sex.male,
            vo2max: n >= 1 ? 50 : null,
            restingHr: n >= 2 ? 48 : null,
            rmssd: n >= 3 ? 60 : null,
            sleepDurationH: n >= 4 ? 7.5 : null,
            sleepEfficiency: n >= 5 ? 94 : null,
            dailySteps: n >= 6 ? 12000 : null,
          );
      expect(build(6).confidence, greaterThan(build(1).confidence));
      expect(build(6).inputs_used, hasLength(7)); // profile + 6
    });
  });

  // -------------------------------------------------------------------------
  // REGRESSION: vo2maxEstimate must not divide by a zero resting HR.
  // -------------------------------------------------------------------------
  group('vo2maxEstimate — zero resting HR (regression)', () {
    test('restingHr == 0 (the off-skin sentinel) ABSTAINS, never Infinity', () {
      // PRE-FIX `maxHr <= restingHr` did not catch it: 15.3 * (190/0) produced
      // value: Infinity, which Metric.toJson emits raw and jsonEncode throws on.
      final m = vo2maxEstimate(restingHr: 0, maxHr: 190, sex: Sex.male, age: 30);
      expect(m.present, isFalse);
      expect(m.value, isNull);
      expect(() => jsonEncode(m.toJson()), returnsNormally);
    });

    test('a negative or non-finite resting HR also abstains', () {
      expect(
          vo2maxEstimate(restingHr: -5, maxHr: 190, sex: Sex.male, age: 30)
              .present,
          isFalse);
      expect(
          vo2maxEstimate(
                  restingHr: double.nan, maxHr: 190, sex: Sex.male, age: 30)
              .present,
          isFalse);
    });

    test('a valid pair still computes', () {
      final m = vo2maxEstimate(restingHr: 50, maxHr: 190, sex: Sex.male, age: 30);
      expect(m.present, isTrue);
      expect(m.value!.isFinite, isTrue);
      expect(() => jsonEncode(m.toJson()), returnsNormally);
    });
  });

  // -------------------------------------------------------------------------
  // REGRESSION: journalCorrelations needs a dispersion test, and must not
  // index an outcome list by dates.length without checking.
  // -------------------------------------------------------------------------
  group('journalCorrelations — dispersion + length guard (regression)', () {
    test('a 3% mean gap swamped by within-group spread is NOT meaningful', () {
      // tagged [50,80] mean 65 vs untagged [40,86] mean 63 => +3.17%, which
      // PRE-FIX cleared the bare `pct.abs() >= 3.0` bar. Each side spans 30–46
      // points, so Cohen's d is ~0.07: this is noise, not a journal effect.
      final journal = <JournalDay>[
        const JournalDay('d0', {'coffee'}),
        const JournalDay('d1', {'coffee'}),
        const JournalDay('d2', {}),
        const JournalDay('d3', {}),
      ];
      final out = journalCorrelations(
        journal: journal,
        dates: const ['d0', 'd1', 'd2', 'd3'],
        outcomes: const {
          'recovery': [50, 80, 40, 86]
        },
      );
      final eff = out.firstWhere((c) => c.tag == 'coffee').effects.single;
      expect(eff.insufficient, isFalse);
      expect(eff.pctChange!.abs(), greaterThanOrEqualTo(3.0),
          reason: 'the old percentage bar IS cleared');
      expect(eff.cohensD, isNotNull);
      expect(eff.cohensD!.abs(), lessThan(0.5));
      expect(eff.meaningful, isFalse,
          reason: 'dispersion test must veto it (d=${eff.cohensD})');
    });

    test('a large, well-separated effect is still meaningful', () {
      final out = journalCorrelations(
        journal: const [
          JournalDay('d0', {'alcohol'}),
          JournalDay('d1', {'alcohol'}),
          JournalDay('d2', {}),
          JournalDay('d3', {}),
        ],
        dates: const ['d0', 'd1', 'd2', 'd3'],
        outcomes: const {
          'recovery': [40, 42, 80, 82]
        },
      );
      final eff = out.firstWhere((c) => c.tag == 'alcohol').effects.single;
      expect(eff.meaningful, isTrue);
      expect(eff.cohensD!.abs(), greaterThan(0.5));
    });

    test('two constant sides with only 2 days each are NOT meaningful', () {
      // Pooled SD is 0 so Cohen's d is undefined; refuse to call it.
      final out = journalCorrelations(
        journal: const [
          JournalDay('d0', {'x'}),
          JournalDay('d1', {'x'}),
          JournalDay('d2', {}),
          JournalDay('d3', {}),
        ],
        dates: const ['d0', 'd1', 'd2', 'd3'],
        outcomes: const {
          'recovery': [60, 60, 70, 70]
        },
      );
      final eff = out.firstWhere((c) => c.tag == 'x').effects.single;
      expect(eff.cohensD, isNull);
      expect(eff.meaningful, isFalse);
    });

    test('an outcome list shorter than dates is guarded, not a RangeError', () {
      // PRE-FIX `entry.value[i]` was indexed by dates.length => RangeError.
      late final List<JournalTagCorrelation> out;
      expect(
        () => out = journalCorrelations(
          journal: const [
            JournalDay('d0', {'x'}),
            JournalDay('d1', {'x'}),
            JournalDay('d2', {}),
            JournalDay('d3', {}),
          ],
          dates: const ['d0', 'd1', 'd2', 'd3'],
          outcomes: const {
            'recovery': [60, 62] // misaligned: 2 values for 4 dates
          },
        ),
        returnsNormally,
      );
      final eff = out.firstWhere((c) => c.tag == 'x').effects.single;
      expect(eff.insufficient, isTrue);
      expect(eff.meaningful, isFalse);
      expect(eff.nTagged, 0);
      expect(eff.nUntagged, 0);
    });
  });
}
