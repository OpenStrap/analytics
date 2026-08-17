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
double strainOfDay(List<double> hr) {
  final trimp = banisterTrimp(
    hr,
    restingHr: kRhr,
    maxHr: kHrMax,
    sex: Sex.male,
  );
  expect(trimp.present, isTrue, reason: 'anchors need a real TRIMP');
  return strainScore(trimp.value!, wakeMinutes: hr.length.toDouble());
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

    test('MOT-04/MOT-03: at this user MEASURED quiet level a nothing-day still '
        'scores ~12 — the known defect, pinned', () {
      // The anchors above put quiet waking at exactly `quietWakingHrr` = 0.20.
      // whoop-4.db says this user's real wake minutes sit at p50 0.274 HRR
      // (RHR 55 / HRmax 187), and at that level a full-wear day with no
      // exercise at all scores in the band the table calls "90 min hard".
      // Measured on the real corpus: 6.93 / 11.17 / 11.38 / 11.97 / 12.14 over
      // the five quiet days. THIS TEST IS EXPECTED TO FAIL WHEN MOT-03 LANDS —
      // when it does, that is the fix arriving, and the anchor table in
      // load_trimp.dart has to be regenerated in the same change.
      const rhr = 55.0, hrMax = 187.0;
      final quietBpm = rhr + 0.274 * (hrMax - rhr); // 91.2 bpm
      final trimp = banisterTrimp(List<double>.filled(960, quietBpm),
          restingHr: rhr, maxHr: hrMax, sex: Sex.male);
      expect(strainScore(trimp.value!, wakeMinutes: 960), closeTo(11.9, 0.6));
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
      expect(strainScore(1e9, wakeMinutes: 960), closeTo(21.0, 1e-9));
      expect(strainScore(0, wakeMinutes: 960), 0.0);
    });

    test('never returns a negative strain when load is under baseline', () {
      // Asleep-ish all day: TRIMP well below the quiet-waking allowance.
      expect(strainScore(1.0, wakeMinutes: 960), 0.0);
    });
  });

  group('strainScoreMetric honesty envelope', () {
    test('abstains without wake minutes rather than assuming a full day', () {
      // Wake minutes set the baseline. Guessing one fabricates the subtraction
      // and silently mis-scores every partial-wear day.
      expect(strainScoreMetric(300, wakeMinutes: null).present, isFalse);
      expect(strainScoreMetric(null, wakeMinutes: 960).present, isFalse);
    });

    test('present and ESTIMATE-tier with both inputs', () {
      final m = strainScoreMetric(392.9, wakeMinutes: 960);
      expect(m.present, isTrue);
      expect(m.tier, Tier.estimate);
      expect(m.value, greaterThan(14.0));
    });
  });
}
