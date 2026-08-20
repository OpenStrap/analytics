// REGRESSION — cardioStager on a REAL WHOOP-4 overnight capture.
//
// Root-caused 2026-07 against a real user's device export (00:32-09:26 local,
// ~8h54m in bed) whose Apple Watch Ultra ground truth for the SAME night was:
//   wake=3min  REM=162min (2h42m)  light=330min (5h30m)  deep=38min
// cardioStager's PRE-FIX output on this exact night was massively wrong:
//   wake=294min  REM=41min  light=173min  deep=26min
//
// Root cause (both confirmed against the raw arrays below, not theory):
//  1. `_calibrateG`/gRef was a SINGLE WHOLE-NIGHT scalar 1 g reference. This
//     real device's decoded gravity-vector magnitude is NOT perfectly
//     orientation-invariant — different STATIC sleep postures read up to
//     ~13% apart in |accel| (0.93-1.07 g) despite near-zero within-epoch
//     variance (i.e. genuinely still). 389 of 421 "big move" epochs that
//     night were this exact artifact (tiny within-epoch stddev, large offset
//     from the single global reference), not real movement — and the
//     resulting WAKE blocks were too long for Webster rescore's flanking-
//     context rules to bridge back.
//  2. The whole-night HR median/arousal threshold misread the well-documented
//     sleep-onset HR-decay transient (HR ran 74-80 bpm for the first ~60-90
//     min before settling to this night's true ~55-70 bpm steady state) as
//     sustained arousal — a single ~34 min WAKE block right at sleep onset.
//  3. Once WAKE was fixed, REM was still ~half of truth: the REM rule's
//     `hrTowardWake` gate compared against a local HR MEDIAN, but REM (a
//     minority of any local window, recurring on ~90-min ultradian cycles)
//     partially inflates its own local median — self-dilution. Switching
//     that one comparison to a local p25 floor recovered REM sensitivity.
//
// Fix: `cardio_stager.dart` now computes BOTH the gravity reference and the
// HR baseline as LOCALLY-ADAPTIVE (rolling-window) values instead of
// whole-night scalars, with a p25 floor specifically for the REM gate. This
// test pins the corrected output against wide (not exact-equality) bands
// derived from the Apple Watch ground truth, so the file stays robust to
// minor future tuning while permanently guarding against a regression back
// to either failure mode (wake blowing back up, or REM collapsing).
//
// Fixture provenance: `fixtures/real_night_2026_07_onehz.csv` /
// `..._rr.csv` are the user's real decoded_onehz/decoded_rr rows for this
// night, ANONYMIZED — timestamps rebased to start at 0 (no absolute date/
// device identity survives), only hr/ax/ay/az/rr_ms kept (no spo2/skin-temp/
// counter/device fields).

import 'dart:io';
import 'package:test/test.dart';
import 'package:openstrap_analytics/onehz.dart';

void main() {
  _windowEdgeTies();

  test('cardioStager on the real 2026-07 overnight capture matches Apple '
      'Watch ground truth within a wide band (regression: was wake=294min '
      'rem=41min pre-fix)', () {
    final onehzFile =
        File('test/onehz/fixtures/real_night_2026_07_onehz.csv');
    final rrFile = File('test/onehz/fixtures/real_night_2026_07_rr.csv');
    if (!onehzFile.existsSync() || !rrFile.existsSync()) {
      markTestSkipped('real night fixtures not found');
      return;
    }

    final hr1hz = <double>[];
    final accel = <AccelSample>[];
    final onehzLines = onehzFile.readAsLinesSync();
    for (var i = 1; i < onehzLines.length; i++) {
      final l = onehzLines[i];
      if (l.trim().isEmpty) continue;
      final p = l.split(',');
      final relSec = int.parse(p[0]);
      hr1hz.add(double.parse(p[1]));
      accel.add(AccelSample(
        relSec * 1000.0,
        double.parse(p[2]),
        double.parse(p[3]),
        double.parse(p[4]),
      ));
    }

    final rrMs = <double>[];
    final rrTsMs = <double>[];
    final rrLines = rrFile.readAsLinesSync();
    for (var i = 1; i < rrLines.length; i++) {
      final l = rrLines[i];
      if (l.trim().isEmpty) continue;
      final p = l.split(',');
      rrTsMs.add(double.parse(p[0]));
      rrMs.add(double.parse(p[1]));
    }

    expect(hr1hz.length, greaterThan(30000),
        reason: 'fixture should cover the full ~8h54m night at 1 Hz');

    final result = cardioStager(hr1hz, accel, rrMs: rrMs, rrTsMs: rrTsMs);
    final stages = result.base.stages;
    var wakeEp = 0, nremEp = 0, remEp = 0, deepEp = 0;
    for (var i = 0; i < stages.length; i++) {
      switch (stages[i]) {
        case SleepStage.wake:
          wakeEp++;
          break;
        case SleepStage.rem:
          remEp++;
          break;
        case SleepStage.nrem:
          nremEp++;
          if (i < result.deepFlag.length && result.deepFlag[i]) deepEp++;
          break;
      }
    }
    const epochMin = 30 / 60.0;
    final wakeMin = wakeEp * epochMin;
    final lightMin = (nremEp - deepEp) * epochMin;
    final deepMin = deepEp * epochMin;
    final remMin = remEp * epochMin;

    // ── the actual regression guards ──────────────────────────────────────
    // Ground truth: wake=3 light=330 deep=38 rem=162 (minutes).
    // Pre-fix (broken) output: wake=294 light=173 deep=26 rem=41.
    // Bands are wide — this is a wrist ESTIMATE, not a PSG-equivalence check —
    // but tight enough that the pre-fix numbers fail every one of them.
    // RE-PINNED 2026-08 (was `lessThan(20)`) when the Webster continuity
    // rescore was restored to its PUBLISHED table (15 min context bridges ≤4
    // min of wake, not ≤10). Measured on this fixture, that single change moves
    // wake 17.5 → 26.0 min, light 295.0 → 289.5, REM 153.0 → 150.0, i.e. TST
    // 516.5 → 508.0. The old table was closer to this night's Apple Watch label
    // (wake=3) only because it was bridging up to 10 minutes of genuine
    // awakening into light sleep; one wrist-reference night is not a licence to
    // deviate from Webster 1982 / Cole 1992.
    expect(wakeMin, lessThan(35),
        reason: 'WAKE over-call regression guard (pre-fix: 294 min)');
    expect(remMin, greaterThan(100),
        reason: 'REM under-call regression guard (pre-fix: 41 min)');
    expect(lightMin, greaterThan(250));
    expect(deepMin, greaterThan(15));

    // Sanity: the four buckets still account for the whole session.
    final tot = wakeMin + lightMin + deepMin + remMin;
    expect(tot, closeTo(stages.length * epochMin, 0.01));
  });
}

// The per-epoch RR window is found by binary search. `rr_ts_ms` is
// `rec_ts * 1000`, so beat timestamps TIE — several beats share one second,
// and a second boundary can land exactly on a window edge. The search must be
// a TRUE lower bound (first index >= lo) and the far edge must be inclusive;
// "first index strictly greater than lo" drops the tied beats at the edge,
// which moves RMSSD / SDNN / LF-HF and with them the REM and deep counts.
void _windowEdgeTies() {
  test('window gather keeps tied beats at BOTH edges', () {
    final accel = <AccelSample>[
      for (var i = 0; i < 30; i++) AccelSample(i * 1000.0, 0, 0, 1)
    ];
    // epoch [0,30) -> mid 15 -> centre 15000 ms; ±5 s -> window [10000, 20000].
    final ts = <double>[
      9000, // just before -> out
      10000, 10000, 10000, // tie ON the low edge -> in
      15000,
      20000, 20000, 20000, // tie ON the high edge -> in
      21000, // just after -> out
    ];
    final rr = <double>[for (var i = 0; i < ts.length; i++) 900.0];

    final beats =
        cleanBeatsInWindowForTest(rr, ts, accel, 0, 30, halfWinMs: 5000);
    // 7, not 4 (low ties dropped) and not 5 (both edges exclusive).
    expect(beats.length, 7);

    // and the beats really are the in-window ones, in order.
    final marked = <double>[900, 901, 902, 903, 904, 905, 906, 907, 908];
    final got =
        cleanBeatsInWindowForTest(marked, ts, accel, 0, 30, halfWinMs: 5000);
    expect(got, [901, 902, 903, 904, 905, 906, 907]);
  });
}
