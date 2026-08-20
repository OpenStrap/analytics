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
          strainScoreMetric(300, wakeMinutes: null, quietHrr: quietWakingHrr)
              .present,
          isFalse);
      expect(
          strainScoreMetric(null, wakeMinutes: 960, quietHrr: quietWakingHrr)
              .present,
          isFalse);
    });

    test('abstains without a quiet-waking level rather than assuming one', () {
      // The whole of MOT-03: a stand-in level is what billed being awake as
      // training load. No level, no score.
      final m = strainScoreMetric(392.9, wakeMinutes: 960, quietHrr: null);
      expect(m.present, isFalse);
      expect(m.note, contains('quiet-waking'));
      expect(m.inputs_used, contains('quiet_waking_hrr'));
    });

    test('present and ESTIMATE-tier with every input', () {
      final m =
          strainScoreMetric(392.9, wakeMinutes: 960, quietHrr: quietWakingHrr);
      expect(m.present, isTrue);
      expect(m.tier, Tier.estimate);
      expect(m.value, greaterThan(14.0));
    });
  });
}
