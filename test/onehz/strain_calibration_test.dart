// Behavioural anchors for the 0–21 headline strain scale.
//
// These tests deliberately assert on WHAT A DAY SHOULD SCORE, not on the
// formula's own arithmetic. The previous test only pinned `strainScore(335) ≈
// 14.347` — the formula restated as an expectation — which let a badly
// calibrated scale pass forever: whole-waking-day Banister TRIMP through a
// log base 1.5 put an INACTIVE full-wear day at ~13/21 and left strain 21
// needing a TRIMP of ~4987 (≈35 h at 80 % HRR, i.e. unreachable).
//
// Every day here is built from real per-minute HR and run through the real
// `banisterTrimp`, so the anchors constrain the whole pipeline, not just the map.

import 'package:test/test.dart';
import 'package:openstrap_analytics/onehz.dart';

// One representative profile, matching the `max_hr_used` seen in real bundles.
const double kRhr = 60.0;
const double kHrMax = 187.0;

/// A day's per-minute WAKING HR: [totalMin] minutes at [quietHr], with the
/// leading minutes replaced by each (minutes, hr) bout.
List<double> dayHr(
  int totalMin,
  double quietHr, [
  List<(int, double)> bouts = const [],
]) {
  final hr = List<double>.filled(totalMin, quietHr);
  var i = 0;
  for (final (mins, bpm) in bouts) {
    for (var k = 0; k < mins && i < totalMin; k++, i++) {
      hr[i] = bpm;
    }
  }
  return hr;
}

/// Full pipeline: per-minute HR → Banister TRIMP → headline 0–21 strain.
///
/// [quietHrr] defaults to the convention the anchor table in load_trimp.dart is
/// generated at, so these anchors reproduce that table exactly. Real callers
/// pass the user's own measured level ([dailyQuietWakingHrr]) — see the MOT-03
/// group below for what that does.
double strainOfDay(List<double> hr, {double quietHrr = quietWakingHrr}) {
  final trimp = banisterTrimp(
    hr,
    restingHr: kRhr,
    maxHr: kHrMax,
    sex: Sex.male,
  );
  expect(trimp.present, isTrue, reason: 'anchors need a real TRIMP');
  return strainScore(trimp.value!,
      wakeMinutes: hr.length.toDouble(), quietHrr: quietHrr);
}

void main() {
  group('strain scale — behavioural anchors', () {
    test('an inactive full-wear day scores near zero, not 13', () {
      // THE REPORTED BUG. 16 h awake at a quiet 85 bpm — no exercise at all.
      // Old scale: TRIMP 176.5 → ln(177.5)/ln(1.5) = 12.8. Merely being awake
      // and having a pulse consumed 61 % of the scale.
      expect(strainOfDay(dayHr(960, 85)), lessThan(2.0));
    });

    test('a rest day with a light walk scores 2–4', () {
      final s = strainOfDay(dayHr(960, 85, [(60, 105)]));
      expect(s, greaterThanOrEqualTo(2.0));
      expect(s, lessThanOrEqualTo(4.0));
    });

    test('a typical active day with a 45-min moderate run scores 8–11', () {
      final s = strainOfDay(dayHr(960, 85, [(45, 145)]));
      expect(s, greaterThanOrEqualTo(8.0));
      expect(s, lessThanOrEqualTo(11.0));
    });

    test('a hard 90-min session day scores 14–17', () {
      final s = strainOfDay(dayHr(960, 85, [(90, 165)]));
      expect(s, greaterThanOrEqualTo(14.0));
      expect(s, lessThanOrEqualTo(17.0));
    });

    test('a maximal day scores 19–21 and is reachable', () {
      // 5 h at 160 bpm. Under the old scale 21 needed TRIMP ~4987 — no human
      // day reached it, so the top of the scale was decorative.
      final s = strainOfDay(dayHr(960, 85, [(300, 160)]));
      expect(s, greaterThanOrEqualTo(19.0));
      expect(s, lessThanOrEqualTo(21.0));
    });

    test('MOT-04: the scale saturates at ~3.25 h at 160 bpm, not 5 h', () {
      // The docstring's "5 h at 160 bpm → 21" was loose: with the baseline
      // subtraction included, 195 min already tops out, so every session past
      // that is the same number. Regenerate this with `quietWakingHrr` if that
      // constant ever moves (MOT-03) — it moves every anchor in the table.
      expect(strainOfDay(dayHr(960, 85, [(190, 160)])), lessThan(21.0));
      expect(strainOfDay(dayHr(960, 85, [(195, 160)])), closeTo(21.0, 1e-9));
    });

    test('short wear with no activity is not scored as effort', () {
      // Real bundle 2026-07-10: band worn ~135 waking minutes, 23 steps.
      // The baseline must scale with wear, or a 2-hour inactive wear window
      // borrows a full day's allowance and reads as rest-day effort.
      expect(strainOfDay(dayHr(135, 85)), lessThan(1.0));
    });

    test('is monotone in load and clamped to the 0–21 range', () {
      final easy = strainOfDay(dayHr(960, 85, [(30, 130)]));
      final mid = strainOfDay(dayHr(960, 85, [(60, 150)]));
      final hard = strainOfDay(dayHr(960, 85, [(120, 170)]));
      expect(easy, lessThan(mid));
      expect(mid, lessThan(hard));
      expect(strainScore(1e9, wakeMinutes: 960, quietHrr: quietWakingHrr),
          closeTo(21.0, 1e-9));
      expect(strainScore(0, wakeMinutes: 960, quietHrr: quietWakingHrr), 0.0);
    });

    test('never returns a negative strain when load is under baseline', () {
      // Asleep-ish all day: TRIMP well below the quiet-waking allowance.
      expect(strainScore(1.0, wakeMinutes: 960, quietHrr: quietWakingHrr), 0.0);
    });
  });

  // THE FIX for edge#226 / MOT-03. The 0.20 convention above is not this user's
  // quiet level, and scoring them against it billed the cost of being awake as
  // training load.
  group('MOT-03 — the quiet-waking level is the USER\'S, not a constant', () {
    // whoop-4.db: this user's wake minutes sit at p50 0.274 HRR, RHR 55.
    const rhr = 55.0, hrMax = 187.0;
    final quietBpm = rhr + 0.274 * (hrMax - rhr); // 91.2 bpm

    double scored(List<double> hr, {double? quietHrr}) {
      final trimp =
          banisterTrimp(hr, restingHr: rhr, maxHr: hrMax, sex: Sex.male);
      return strainScore(trimp.value!,
          wakeMinutes: hr.length.toDouble(),
          quietHrr: quietHrr ??
              dailyQuietWakingHrr(hr, restingHr: rhr, maxHr: hrMax)!);
    }

    test('a nothing-day scores 0, where it used to score ~12', () {
      final nothing = List<double>.filled(960, quietBpm);
      expect(scored(nothing, quietHrr: 0.20), closeTo(11.93, 0.05),
          reason: 'what the shipped constant published for doing nothing');
      expect(scored(nothing), 0.0);
    });

    test('and a light day is NOT flattened into the same bucket', () {
      // The defect flattened the whole bottom of the scale: doing nothing and
      // doing an hour's walk were 11.93 vs 12.61, indistinguishable on a 0–21
      // dial. They now sit two and a half points apart, and the rest of the
      // scale stays graded rather than collapsing to zero with it.
      final walk = <double>[
        ...List<double>.filled(900, quietBpm),
        ...List<double>.filled(60, 105.0),
      ];
      final run = <double>[
        ...List<double>.filled(915, quietBpm),
        ...List<double>.filled(45, 145.0),
      ];
      final hard = <double>[
        ...List<double>.filled(870, quietBpm),
        ...List<double>.filled(90, 165.0),
      ];
      expect(scored(walk, quietHrr: 0.20), closeTo(12.61, 0.05));
      expect(scored(walk), closeTo(2.78, 0.05));
      expect(scored(run), closeTo(8.72, 0.05));
      expect(scored(hard), closeTo(16.49, 0.05));
    });

    test('a user whose quiet really IS 0.20 barely moves', () {
      // The anchor profile: RHR 60, quiet waking at 85 bpm = 0.1969 HRR. The
      // fix is not a global re-scaling — it only bites where the constant was
      // wrong for the person.
      final nothing = List<double>.filled(960, 85.0);
      expect(dailyQuietWakingHrr(nothing, restingHr: 60, maxHr: hrMax),
          closeTo(0.1969, 0.001));
      expect(strainOfDay(nothing), 0.0);
      expect(
          strainOfDay(nothing,
              quietHrr:
                  dailyQuietWakingHrr(nothing, restingHr: 60, maxHr: hrMax)!),
          0.0);
    });

    test('an exercise-dominated day cannot define quiet waking', () {
      // Otherwise an all-day hike subtracts its own effort away and scores 0.
      final hike = List<double>.filled(960, rhr + 0.45 * (hrMax - rhr));
      expect(dailyQuietWakingHrr(hike, restingHr: rhr, maxHr: hrMax), isNull);
      // Just under the moderate floor it is still ordinary living.
      final busy = List<double>.filled(960, rhr + 0.35 * (hrMax - rhr));
      expect(dailyQuietWakingHrr(busy, restingHr: rhr, maxHr: hrMax),
          closeTo(0.35, 1e-9));
    });

    test('no anchors, or too few minutes, is null — never a stand-in', () {
      final day = List<double>.filled(960, quietBpm);
      expect(dailyQuietWakingHrr(day, restingHr: null, maxHr: hrMax), isNull);
      expect(dailyQuietWakingHrr(day, restingHr: rhr, maxHr: null), isNull);
      expect(dailyQuietWakingHrr(day.take(30).toList(), restingHr: rhr, maxHr: hrMax),
          isNull);
      // Off-skin zeros are not minutes.
      expect(
          dailyQuietWakingHrr(List<double>.filled(960, 0), restingHr: rhr, maxHr: hrMax),
          isNull);
    });
  });

  group('strainScoreMetric honesty envelope', () {
    test('abstains without wake minutes rather than assuming a full day', () {
      // Wake minutes set the baseline. Guessing one fabricates the subtraction
      // and silently mis-scores every partial-wear day.
      expect(
          strainScoreMetric(300, wakeMinutes: null, quietHrr: quietWakingHrr, quietSettled: true)
              .present,
          isFalse);
      expect(
          strainScoreMetric(null, wakeMinutes: 960, quietHrr: quietWakingHrr, quietSettled: true)
              .present,
          isFalse);
    });

    test('abstains without a quiet-waking level rather than assuming one', () {
      // The whole of MOT-03: a stand-in level is what billed being awake as
      // training load. No level, no score.
      final m = strainScoreMetric(392.9, wakeMinutes: 960, quietHrr: null, quietSettled: true);
      expect(m.present, isFalse);
      expect(m.note, contains('quiet-waking'));
      expect(m.inputs_used, contains('quiet_waking_hrr'));
    });

    test('a calibrating quiet level lowers confidence and says so', () {
      // Same disclosure as the live scorer: fewer than a week of days behind
      // the level is a real but wider measurement. The value is unchanged.
      final settled = strainScoreMetric(392.9,
          wakeMinutes: 960, quietHrr: quietWakingHrr, quietSettled: true);
      final cal = strainScoreMetric(392.9,
          wakeMinutes: 960, quietHrr: quietWakingHrr, quietSettled: false);
      expect(cal.value, settled.value);
      expect(cal.confidence, lessThan(settled.confidence));
      expect(cal.note, contains('calibrating'));
      expect(settled.note, isNot(contains('calibrating')));
    });

    test('present and ESTIMATE-tier with every input', () {
      final m =
          strainScoreMetric(392.9, wakeMinutes: 960, quietHrr: quietWakingHrr, quietSettled: true);
      expect(m.present, isTrue);
      expect(m.tier, Tier.estimate);
      expect(m.value, greaterThan(14.0));
    });
  });

  // MOT-03 shipped the level as an argument; these pin what scoring against it
  // from a per-minute series does. Quiet time is netted among itself, never
  // against exercise minutes (>= 40 % HRR), so a quiet afternoon cannot erase
  // a morning run.
  group('guarded net: quiet time never debits exercise', () {
    const rhr = 50.0, hrMax = 187.0;
    double q(double x) => rhr + x * (hrMax - rhr);

    Metric<double> scored(List<double> hr, double quietHrr,
            {double r = rhr, double m = hrMax}) =>
        strainScoreFromSeries(hr,
            restingHr: r,
            maxHr: m,
            quietHrr: quietHrr,
            sex: Sex.male,
            quietSettled: true);

    double lump(List<double> hr, double quietHrr,
        {double r = rhr, double m = hrMax}) {
      final t = banisterTrimp(hr, restingHr: r, maxHr: m, sex: Sex.male);
      return strainScore(t.value!,
          wakeMinutes: hr.length.toDouble(), quietHrr: quietHrr);
    }

    final lowQuietRun = [
      ...List<double>.filled(45, 145.0),
      ...List<double>.filled(855, q(0.10)),
    ];
    final jitter = [
      for (var i = 0; i < 900; i++) i.isEven ? q(0.17) : q(0.23),
    ];

    test('a low-quiet user\'s 45-min run is not erased', () {
      expect(lump(lowQuietRun, 0.20), 0.0,
          reason: 'the lump form lets 855 quiet minutes cancel the run');
      expect(scored(lowQuietRun, 0.20).value, closeTo(9.38, 0.02));
      expect(scored(lowQuietRun, 0.10).value, closeTo(9.77, 0.02));
    });

    test('a nothing-day with spread around Q keeps lump\'s honest value', () {
      expect(lump(jitter, 0.20), closeTo(0.46, 0.02));
      expect(scored(jitter, 0.20).value, closeTo(lump(jitter, 0.20), 1e-9));
    });

    test('anchor table, guarded at Q = 0.20', () {
      double at(List<double> hr) => scored(hr, 0.20, r: kRhr, m: kHrMax).value!;
      expect(at(dayHr(960, 85)), 0.0);
      expect(at(dayHr(960, 85, [(60, 105)])), closeTo(2.70, 0.01));
      expect(at(dayHr(960, 85, [(45, 145)])), closeTo(8.88, 0.01));
      expect(at(dayHr(960, 85, [(90, 165)])), closeTo(16.65, 0.01));
      expect(at(dayHr(960, 85, [(190, 160)])), lessThan(21.0));
      expect(at(dayHr(960, 85, [(195, 160)])), closeTo(21.0, 1e-9));
    });

    test('never below the exercise minutes alone', () {
      for (final hr in [
        lowQuietRun,
        jitter,
        dayHr(960, 85, [(45, 145)])
      ]) {
        final n = netTrimpAboveQuiet(hr,
            restingHr: rhr, maxHr: hrMax, quietHrr: 0.20, sex: Sex.male)!;
        expect(scored(hr, 0.20).value,
            greaterThanOrEqualTo(strainFromNetTrimp(n.exercise)));
      }
    });

    test('strainFromNetTrimp is strainScore\'s map', () {
      final t = banisterTrimp(dayHr(960, 85, [(45, 145)]),
              restingHr: kRhr, maxHr: kHrMax, sex: Sex.male)
          .value!;
      expect(
          strainFromNetTrimp(t - baselineTrimp(960, quietHrr: quietWakingHrr)),
          strainScore(t, wakeMinutes: 960, quietHrr: quietWakingHrr));
      expect(strainFromNetTrimp(-5), 0.0);
      expect(strainFromNetTrimp(double.nan), 0.0);
    });

    test('calibrating lowers confidence, never the value', () {
      final settled = scored(lowQuietRun, 0.20);
      final calibrating = strainScoreFromSeries(lowQuietRun,
          restingHr: rhr,
          maxHr: hrMax,
          quietHrr: 0.20,
          sex: Sex.male,
          quietSettled: false);
      expect(calibrating.value, settled.value);
      expect(settled.confidence, 0.6);
      expect(calibrating.confidence, 0.45);
      expect(calibrating.note, startsWith('calibrating'));
    });
  });

  group('cumulative curve', () {
    const rhr = 50.0, hrMax = 187.0;
    double q(double x) => rhr + x * (hrMax - rhr);
    final hr = [
      ...List<double>.filled(120, q(0.10)),
      ...List<double>.filled(45, 145.0),
      ...List<double>.filled(735, q(0.10)),
    ];

    test('banked exercise never falls back out, and last == headline', () {
      final curve = strainCurveFromSeries(hr,
          restingHr: rhr, maxHr: hrMax, quietHrr: 0.20, sex: Sex.male)!;
      expect(curve.length, 900);
      expect(curve[164], closeTo(9.38, 0.02));
      for (var i = 164; i < curve.length; i++) {
        expect(curve[i], greaterThanOrEqualTo(curve[164] - 1e-9));
      }
      expect(
          curve.last,
          strainScoreFromSeries(hr,
                  restingHr: rhr,
                  maxHr: hrMax,
                  quietHrr: 0.20,
                  sex: Sex.male,
                  quietSettled: true)
              .value);
    });

    test('after the last exercise minute only ordinary living moves it', () {
      // Positive living (0.30 HRR before the run) is banked in the living
      // block, and a quiet evening below Q nets it back out — so the curve CAN
      // decline after exercise. What it can never do is debit the exercise:
      // the exercise contribution is fixed from the last exercise minute on,
      // and the curve never drops below what that alone scores.
      final hr = [
        ...List<double>.filled(120, q(0.30)),
        ...List<double>.filled(45, 145.0),
        ...List<double>.filled(735, q(0.10)),
      ];
      final curve = strainCurveFromSeries(hr,
          restingHr: rhr, maxHr: hrMax, quietHrr: 0.20, sex: Sex.male)!;
      expect(curve[164], closeTo(10.74, 0.02));
      expect(curve.last, closeTo(9.38, 0.02));
      expect(
          curve.last,
          strainScoreFromSeries(hr,
                  restingHr: rhr,
                  maxHr: hrMax,
                  quietHrr: 0.20,
                  sex: Sex.male,
                  quietSettled: true)
              .value);
      double exerciseUpTo(int i) => netTrimpAboveQuiet(hr.sublist(0, i + 1),
              restingHr: rhr, maxHr: hrMax, quietHrr: 0.20, sex: Sex.male)!
          .exercise;
      final banked = exerciseUpTo(164);
      for (var i = 165; i < hr.length; i += 15) {
        expect(exerciseUpTo(i), banked, reason: 'minute $i');
        expect(
            curve[i], greaterThanOrEqualTo(strainFromNetTrimp(banked) - 1e-9),
            reason: 'minute $i');
      }
    });

    test('an invalid minute repeats the previous value', () {
      final curve = strainCurveFromSeries([145, double.nan, 0, 145],
          restingHr: rhr, maxHr: hrMax, quietHrr: 0.20, sex: Sex.male)!;
      expect(curve.length, 4);
      expect(curve[1], curve[0]);
      expect(curve[2], curve[0]);
      expect(curve[3], greaterThan(curve[0]));
    });

    test('null when the level or anchors are missing', () {
      expect(
          strainCurveFromSeries(hr,
              restingHr: rhr, maxHr: hrMax, quietHrr: null, sex: Sex.male),
          isNull);
      expect(
          strainCurveFromSeries(hr,
              restingHr: null, maxHr: hrMax, quietHrr: 0.2, sex: Sex.male),
          isNull);
    });
  });

  group('personalQuietWakingHrr', () {
    test('fewer than 3 prior days abstains with the baseline grammar', () {
      final none = personalQuietWakingHrr(const []);
      expect(none.present, isFalse);
      expect(none.note, 'need_baseline:have=0,need=3');
      expect(personalQuietWakingHrr(const [0.2, 0.3]).note,
          'need_baseline:have=2,need=3');
    });

    test('3 days is a calibrating median', () {
      final m = personalQuietWakingHrr(const [0.20, 0.30, 0.25]);
      expect(m.value!.hrr, closeTo(0.25, 1e-12));
      expect(m.value!.days, 3);
      expect(m.value!.settled, isFalse);
      expect(m.confidence, 0.4);
      expect(m.toJson((v) => v.toJson())['value'],
          {'hrr': 0.25, 'days': 3, 'settled': false});
    });

    test('7 days is settled', () {
      final m = personalQuietWakingHrr(List<double>.filled(7, 0.2));
      expect(m.value!.settled, isTrue);
      expect(m.confidence, 0.7);
    });

    test('only the trailing 28 days count', () {
      final m = personalQuietWakingHrr([
        ...List<double>.filled(12, 0.39),
        ...List<double>.filled(28, 0.20),
      ]);
      expect(m.value!.hrr, 0.20);
      expect(m.value!.days, 28);
    });

    test('invalid levels are filtered, not counted', () {
      final m =
          personalQuietWakingHrr(const [double.nan, 0, 0.5, 0.2, 0.2, 0.2]);
      expect(m.value!.hrr, 0.20);
      expect(m.value!.days, 3);
    });
  });

  group('strainScoreFromSeries absent envelope', () {
    final hr = List<double>.filled(100, 120);
    Metric<double> s(
            {double? restingHr = 50,
            double? quietHrr = 0.2,
            List<double>? series}) =>
        strainScoreFromSeries(series ?? hr,
            restingHr: restingHr,
            maxHr: 187,
            quietHrr: quietHrr,
            sex: Sex.male,
            quietSettled: true);

    test('abstains on every missing or out-of-range input', () {
      expect(s(quietHrr: null).present, isFalse);
      expect(s(quietHrr: 0.45).present, isFalse);
      expect(s(quietHrr: 0).present, isFalse);
      expect(s(restingHr: null).present, isFalse);
      expect(s(series: List<double>.filled(100, 0)).present, isFalse);
      expect(s(quietHrr: null).inputs_used, contains('quiet_waking_hrr'));
    });
  });
}
