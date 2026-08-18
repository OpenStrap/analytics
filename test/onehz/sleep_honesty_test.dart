// SLEEP — HONESTY REGRESSIONS (2026-07).
//
// The core contract: absent input yields null / unstaged, NEVER a fabricated
// value. `AdvancedSleepStager.stageWindow`'s own docstring promises "Seconds
// with no data ... simply stay unstaged (wake) — honest about gaps, never
// fabricated". Every test here pins a place where the sleep code broke that
// promise and reported a perfect night out of an empty or fragmented signal.
//
// Each test FAILS against the pre-fix behavior; the pre-fix number is stated in
// the test so a future reader can tell a regression from a re-tune.

import 'dart:math' as math;
import 'package:test/test.dart';
import 'package:openstrap_analytics/onehz.dart';

/// Fixed absolute epoch second so every fixture is deterministic.
const int _t0 = 1700000000;

/// Midnight (UTC) of _t0's day — fixtures anchor local clock times off this and
/// always pass `tzOffsetSec: 0`, so "local" == UTC and nothing depends on the
/// machine timezone.
final int _midnight = _t0 - (_t0 % 86400);

void main() {
  // ═══════════════════════════════════════════════════════════════════════════
  // (1) A window with NO accelerometer at all must not be scored as sleep.
  // ═══════════════════════════════════════════════════════════════════════════
  group('honesty — no accelerometer in the window', () {
    test(
        'a forced window holding zero samples yields NO sleep '
        '(was: 8 h of light sleep, efficiency 100%)', () {
      // 4 h of perfectly good data, then a user-asserted 8 h window ~13 h later
      // that contains not one sample.
      final accel = <AccelSample>[];
      final hr = <double>[];
      for (var i = 0; i < 4 * 3600; i++) {
        accel.add(AccelSample((_t0 + i) * 1000.0, 0.0, 0.0, 1.0));
        hr.add(55);
      }
      final onset = _t0 + 50000;
      final s = segmentSleep(accel, hr,
          forcedWindow: (onsetSec: onset, offsetSec: onset + 8 * 3600));

      // RE-PINNED 2026-08: this used to be `present` with tstSec 0 and
      // efficiencyPct 0.0 — which reads to the user as "0 h 0 m slept, 0 %
      // efficiency", a measurement of a night we never observed. A window in
      // which not one second stages as sleep is an ABSTENTION.
      expect(s.present, isFalse,
          reason:
              'was: present with tst 0 / efficiency 0 %; pre-that: 28800 s');
      expect(s.tstSec, isNull);
      expect(s.efficiencyPct, isNull);
      expect(s.stages, isEmpty);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // (2) HR entirely absent ⇒ abstain, never a fabricated 60 bpm baseline.
  // ═══════════════════════════════════════════════════════════════════════════
  group('honesty — heart rate entirely absent', () {
    test('cardioStager abstains rather than defaulting the HR baseline to 60',
        () {
      // 2 h of perfectly still accel, HR off-skin (0) for every second.
      final accel = <AccelSample>[
        for (var i = 0; i < 2 * 3600; i++)
          AccelSample((_t0 + i) * 1000.0, 0.0, 0.0, 1.0)
      ];
      final hr = List<double>.filled(2 * 3600, 0.0);
      final r = cardioStager(hr, accel);
      // Pre-fix: 240 epochs, every one NREM (the `?? 60` baseline meant the
      // wake / REM / deep gates could never fire, so everything fell through).
      expect(r.base.stages, isEmpty, reason: 'pre-fix: 240 NREM epochs');
      expect(r.confidence, 0);
      // A window that DOES have HR still stages normally.
      final withHr = List<double>.filled(2 * 3600, 52.0);
      expect(cardioStager(withHr, accel).base.stages, isNotEmpty);
    });

    test(
        'the strap-on-the-nightstand night is not reported as a perfect sleep '
        '(was: TST 7h54, efficiency 100%)', () {
      final accel = <AccelSample>[];
      final hr = <double>[];
      var i = 0;
      final start = _midnight + 21 * 3600; // 21:00
      void seg(int secs, {required bool active}) {
        for (var k = 0; k < secs; k++, i++) {
          final x = active ? (k.isEven ? 0.0 : 0.3) : 0.005;
          accel.add(
              AccelSample((start + i) * 1000.0, x, 0.0, active ? 0.95 : 1.0));
          hr.add(0.0); // NO heart rate at all — the band is off the wrist.
        }
      }

      seg(2 * 3600, active: true);
      seg(8 * 3600, active: false); // 8 h of "perfect stillness"
      seg(2 * 3600, active: true);

      final s = segmentSleep(accel, hr, tzOffsetSec: 0);
      // RE-PINNED 2026-08: absent, not "present with zero sleep" — see above.
      expect(s.present, isFalse,
          reason: 'pre-fix: 28438 s of sleep from zero HR');
      expect(s.tstSec, isNull);
      expect(s.efficiencyPct, isNull);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // (3) An accelerometer dropout must not be carried forward into "stillness".
  // ═══════════════════════════════════════════════════════════════════════════
  group('honesty — bounded accel carry-forward', () {
    test(
        'a 6 h dropout inside an 8 h window makes the night ABSENT '
        '(was: TST 8 h, WASO 0, efficiency 100%; then WASO 6 h)', () {
      final accel = <AccelSample>[];
      final hr = <double>[];
      void block(int fromSec, int secs) {
        for (var k = 0; k < secs; k++) {
          accel.add(AccelSample((_t0 + fromSec + k) * 1000.0, 0.005, 0.0, 1.0));
          hr.add(52);
        }
      }

      block(0, 3600); // hour 1: real data
      // hours 2-7: NOTHING
      block(7 * 3600, 3600); // hour 8: real data

      final s = segmentSleep(accel, hr,
          forcedWindow: (onsetSec: _t0, offsetSec: _t0 + 8 * 3600));
      // RE-PINNED 2026-08 (an-sleep-2): only 2 of the 8 h were observed — 25%,
      // below the 50% floor — so there is no honest figure to publish. The
      // previous pin (present, wake ≈ 6 h, efficiency < 30%) was itself the
      // defect: it reported six hours of MEASURED wakefulness for six hours
      // nobody recorded.
      expect(s.present, isFalse);
      expect(s.tstSec, isNull);
      expect(s.wakeSec, isNull);
      expect(s.efficiencyPct, isNull);
      expect(s.absenceReason, contains('observed'),
          reason: 'the absence must carry its reason, not be a bare hole');
    });

    test('a 2 h dropout inside an 8 h window is UNOBSERVED, not WASO', () {
      // 75% observed — above the floor, so the night publishes, but the hole
      // must not be counted as measured wake in any figure.
      final accel = <AccelSample>[];
      final hr = <double>[];
      for (var k = 0; k < 8 * 3600; k++) {
        if (k >= 3 * 3600 && k < 5 * 3600) continue; // 2 h hole
        accel.add(AccelSample((_t0 + k) * 1000.0, 0.005, 0.0, 1.0));
        hr.add(52);
      }
      final s = segmentSleep(accel, hr,
          forcedWindow: (onsetSec: _t0, offsetSec: _t0 + 8 * 3600));
      expect(s.present, isTrue);
      expect(s.inBedSec, 8 * 3600);
      // Exactly the 7200 s hole: the seconds on either side of it have both a
      // sample and a heart rate, so the ±15 s HR-evidence margin adds nothing
      // here (it only bites where samples exist but HR does not).
      expect(s.unobservedSec, 7200, reason: 'pre-fix: 0 (no such state)');
      // NEW VALUES, and why they moved: the denominator is now the OBSERVED
      // 28800-7200 = 21600 s, not the wall-clock 28800. WASO no longer absorbs
      // the hole (pre-fix it was ~7200).
      expect(s.wasoSec!, lessThan(120), reason: 'pre-fix: ~7200');
      expect(s.tstSec! + s.wakeSec!, 8 * 3600 - 7200);
      expect(s.efficiencyPct!, greaterThan(95.0),
          reason:
              'pre-fix: ~74.9 (7200 unrecorded seconds in the denominator)');
      // The hypnogram must break at the hole rather than draw across it.
      expect(s.stages4[4 * 3600], 'unobserved');
    });

    test('a SHORT dropout is still carried forward (the bound is 60 s, not 0)',
        () {
      // Same 8 h window, but the hole is only 45 s — a plausible missed-sample
      // burst, not a data outage. It must stay staged, or every real capture's
      // packet loss would be punched out of the night.
      final accel = <AccelSample>[];
      final hr = <double>[];
      for (var k = 0; k < 4 * 3600; k++) {
        if (k >= 3600 && k < 3600 + 45) continue; // 45 s hole
        accel.add(AccelSample((_t0 + k) * 1000.0, 0.005, 0.0, 1.0));
        hr.add(52);
      }
      final s = segmentSleep(accel, hr,
          forcedWindow: (onsetSec: _t0, offsetSec: _t0 + 4 * 3600));
      expect(s.tstSec!, greaterThan((0.9 * 4 * 3600).round()));
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // (4) Webster rescore must score against an IMMUTABLE snapshot.
  // ═══════════════════════════════════════════════════════════════════════════
  group('honesty — Webster continuity rescore does not cascade', () {
    /// `leadMin` of sleep, then [reps] × (`wakeMin` wake + 1 min sleep), then a
    /// trailing wake block. At 30 s epochs.
    List<SleepStage> fragmented({
      required int leadMin,
      required int wakeMin,
      required int reps,
    }) {
      final out = <SleepStage>[];
      void push(SleepStage s, int mins) {
        for (var k = 0; k < mins * 2; k++) {
          out.add(s);
        }
      }

      push(SleepStage.nrem, leadMin);
      for (var r = 0; r < reps; r++) {
        push(SleepStage.wake, wakeMin);
        push(SleepStage.nrem, 1);
      }
      push(SleepStage.wake, 20);
      return out;
    }

    int wakeInBody(List<SleepStage> sm) {
      var first = -1, last = -1;
      for (var i = 0; i < sm.length; i++) {
        if (sm[i] != SleepStage.wake) {
          if (first < 0) first = i;
          last = i;
        }
      }
      if (first < 0) return 0;
      var c = 0;
      for (var i = first; i <= last; i++) {
        if (sm[i] == SleepStage.wake) c++;
      }
      return c;
    }

    test('cardio_stager: only the bout with REAL flanking sleep is bridged',
        () {
      // 15 min sleep, then 5 × (4 min wake + 1 min sleep). The rule table is
      // now Webster's published one — ≥15 min of flanking sleep bridges ≤4 min
      // of wake — so bout #1 legitimately bridges. Bouts #2-#5 are flanked by
      // ONE minute of sleep and must survive: pre-fix each bridged bout was
      // counted as context for the next, so all five collapsed and WASO hit 0.
      //
      // RE-PINNED with the rule table: this used to use 10-min bouts, which the
      // old non-published [15 → 10] row bridged. Under Webster a 10-min bout is
      // never bridgeable at all, so the case stopped exercising the cascade.
      final sm = fragmented(leadMin: 15, wakeMin: 4, reps: 5);
      websterRescoreCardio(sm, 30);
      expect(wakeInBody(sm), 4 * 8,
          reason: 'four 4-min bouts survive; pre-fix: 0 (full cascade)');
    });

    test('stager: only the bout with REAL flanking sleep is bridged', () {
      // Same shape, sized to the classic Webster table this file uses
      // (≥15 min context bridges ≤5 min of wake).
      final sm = fragmented(leadMin: 15, wakeMin: 4, reps: 5);
      websterRescoreAutonomic(sm, 30);
      expect(wakeInBody(sm), 4 * 8,
          reason: 'four 4-min bouts survive; pre-fix: 0 (full cascade)');
    });

    test('a genuinely fragmented night keeps its WASO end-to-end', () {
      // 5.1 h forced window: 60 min sleep, 6 × (8 min wake + 3 min sleep),
      // 180 min sleep. Bouts #1 and #6 are legitimately bridgeable (≥15 min of
      // REAL flanking sleep); bouts #2-#5 are flanked by 3 min and must stay
      // wake. Measured: 1920 s WASO / 89.5% efficiency with the snapshot,
      // 0 s WASO / 100.0% efficiency with the mutating context.
      final accel = <AccelSample>[];
      final hr = <double>[];
      var i = 0;
      void push(int secs, {required bool awake}) {
        for (var k = 0; k < secs; k++, i++) {
          final ph = math.sin(k * 0.5);
          accel.add(awake
              ? AccelSample(
                  (_t0 + i) * 1000.0, 0.35 * ph, 0.3, 0.9 * (1 - 0.2 * ph))
              : AccelSample((_t0 + i) * 1000.0, 0.005, 0.0, 1.0));
          hr.add(awake ? 88.0 : 50.0);
        }
      }

      push(60 * 60, awake: false);
      for (var r = 0; r < 6; r++) {
        push(8 * 60, awake: true);
        push(3 * 60, awake: false);
      }
      push(180 * 60, awake: false);

      final s = segmentSleep(accel, hr,
          forcedWindow: (onsetSec: _t0, offsetSec: _t0 + 306 * 60));
      expect(s.wasoSec!, greaterThan(25 * 60),
          reason: 'pre-fix: 0 — the cascade swallowed every wake bout');
      expect(s.efficiencyPct!, lessThan(95.0), reason: 'pre-fix: 100.0');
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // (5) Main-sleep selection uses the group's SPAN midpoint, not the
  //     gap-excluding summed duration.
  // ═══════════════════════════════════════════════════════════════════════════
  group('honesty — bridged-group midsleep', () {
    test('a fragmented night is scored at its true circadian centre', () {
      // Two candidate nights in one capture:
      //   A — a single 6 h block, 18:00-00:00 (span == duration, unaffected).
      //   B — three 2 h blocks 01:30-09:00 bridged across two 45-min gaps.
      // B's detected span is 01:32→08:57 (true midsleep 05:14), but its summed
      // session duration excludes the bridges, so the old
      // `start + inBedSec ~/ 2` midpoint read 04:24 — 3043 s (~51 min) early.
      // With the anchor below that error is exactly enough to flip which night
      // is picked as the main sleep.
      final accel = <AccelSample>[];
      final hr = <double>[];
      var i = 0;
      final start = _midnight + 16 * 3600; // 16:00

      void active(int secs, {double bpm = 76}) {
        for (var k = 0; k < secs; k++, i++) {
          final ph = math.sin(k * 0.5);
          accel.add(AccelSample(
              (start + i) * 1000.0, 0.3 * ph, 0.3, 0.9 * (1 - 0.2 * ph)));
          hr.add(bpm + 2 * math.sin(k / 600.0));
        }
      }

      void sleep(int secs, {double bpm = 50}) {
        for (var k = 0; k < secs; k++, i++) {
          accel.add(AccelSample((start + i) * 1000.0, 0.02, 0.02, 1.0));
          hr.add(bpm + 1.5 * math.sin(k / 1800.0));
        }
      }

      active(2 * 3600); // 16:00-18:00
      sleep(6 * 3600); // 18:00-00:00  → night A
      active(90 * 60, bpm: 90); // 00:00-01:30 (>60 min ⇒ A and B never bridge)
      sleep(2 * 3600); // 01:30-03:30  ┐
      active(45 * 60, bpm: 90); //     │ night B — three fragments bridged
      sleep(2 * 3600); // 04:15-06:15  │ across two <60 min gaps
      active(45 * 60, bpm: 90); //     │
      sleep(2 * 3600); // 07:00-09:00  ┘
      active(2 * 3600); // 09:00-11:00

      const anchor = 33840; // 09:24 habitual midsleep
      final s = segmentSleep(accel, hr,
          hrBaseline: List<double>.filled(200, 76),
          tzOffsetSec: 0,
          habitualMidsleepSec: anchor);

      expect(s.present, isTrue);
      final onsetSod = (s.window!.onsetMs! ~/ 1000) % 86400;
      // Night B wins: onset 01:32, in-bed span 7 h 24 min (gaps INCLUDED).
      expect(onsetSod, closeTo(1 * 3600 + 32 * 60, 120),
          reason: 'pre-fix the early midpoint made night A (18:02) win');
      expect(s.inBedSec!, greaterThan(7 * 3600));
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // (6) The habitual-midsleep anchor must convert PER TIMESTAMP (DST).
  // ═══════════════════════════════════════════════════════════════════════════
  group('honesty — habitual midsleep across a DST transition', () {
    test('per-timestamp resolver keeps the anchor at the true local clock time',
        () {
      const stdOffset = -5 * 3600; // e.g. EST
      const dstOffset = -4 * 3600; // e.g. EDT
      const localMidsleep =
          3 * 3600; // the sleeper is dead-on 03:00 every night
      const switchDay = 8;
      // The transition instant: between day 7's and day 8's midsleep.
      final switchTs = _midnight + switchDay * 86400;

      int offsetAt(int ts) => ts < switchTs ? stdOffset : dstOffset;

      final history = <({int startSec, int endSec, String dayKey})>[];
      for (var d = 0; d < 16; d++) {
        // The UTC instant whose LOCAL clock reads 03:00 on day d.
        final off = d < switchDay ? stdOffset : dstOffset;
        final mid = _midnight + d * 86400 + localMidsleep - off;
        history.add((
          startSec: mid - 4 * 3600,
          endSec: mid + 4 * 3600,
          dayKey: 'd$d',
        ));
      }

      final dstCorrect =
          habitualMidsleepSecFromHistory(history, tzOffsetResolver: offsetAt);
      // Every night really was at 03:00 local, so the anchor is 03:00 local.
      expect(dstCorrect, isNotNull);
      expect(dstCorrect!, closeTo(localMidsleep, 2));

      // The old behavior — ONE frozen offset for the whole history — splits the
      // days across two local clock times and lands the anchor half an hour out.
      final frozen =
          habitualMidsleepSecFromHistory(history, tzOffsetSeconds: dstOffset);
      expect(frozen!, closeTo(localMidsleep + 1800, 60));
      expect((frozen - dstCorrect).abs(), greaterThan(1500));
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // (7) Sleep-cycle minute bins must FLOOR, so pre-onset beats are dropped.
  // ═══════════════════════════════════════════════════════════════════════════
  group('honesty — sleep-cycle minute binning', () {
    test('beats 1-59 s BEFORE onset do not land in minute 0', () {
      const onset = _t0;
      const offset = _t0 + 3 * 3600; // 180 min
      final rrMs = <double>[];
      final rrTs = <double>[];

      // 40 beats in the 50 s immediately BEFORE onset. `~/` truncates toward
      // zero, so pre-fix these all binned to minute 0 and slipped past the
      // `m < 0` guard.
      for (var k = 0; k < 40; k++) {
        rrTs.add((onset - 50) * 1000.0 + k * 1200.0);
        rrMs.add(k.isEven ? 520.0 : 660.0);
      }
      // The night's ACTUAL beats start at minute 30 (nothing at all in minutes
      // 0-29), so with correct binning minutes 0-19 have no data at all — not
      // even after the ±10 min smoothing — and no series point exists there.
      for (var m = 30; m < 170; m++) {
        for (var b = 0; b < 40; b++) {
          rrTs.add((onset + m * 60) * 1000.0 + b * 1400.0);
          rrMs.add(
              1000.0 + 30.0 * math.sin(m / 14.0) + (b.isEven ? 6.0 : -6.0));
        }
      }

      final r = detectSleepCycles(rrMs, rrTs, onset, offset);
      expect(r.series, isNotEmpty);
      final firstT = r.series.first['t'] as int;
      expect(firstT, greaterThanOrEqualTo(onset + 19 * 60),
          reason: 'pre-fix the pre-onset beats created a minute-0 point at '
              't == onsetSec');
      expect(r.series.any((p) => p['t'] == onset), isFalse);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // (8) van Hees: the last `sustainedMin` of a record is UNDECIDABLE, and every
  //     second in it is judged on ITS OWN forward window — not on one global
  //     trailing verdict stamped across the whole tail.
  // ═══════════════════════════════════════════════════════════════════════════
  group('honesty — van Hees undecidable tail', () {
    const n = 3600; // 1 h at 1 Hz
    const win = 300; // sustainedMin (5) × 60, the GGIR default

    /// A dead-still hour (z-angle 90°) with one 10 s reorientation burst
    /// starting at [moveAt] (pass a negative value for no movement at all).
    List<AccelSample> record({required int moveAt, int moveLen = 10}) {
      return <AccelSample>[
        for (var i = 0; i < n; i++)
          if (i >= moveAt && i < moveAt + moveLen)
            // Flip between 90° and 30° every second — well over the 5° floor,
            // and long enough to survive the 5 s rolling median.
            AccelSample((_t0 + i) * 1000.0, i.isEven ? 0.87 : 0.0, 0,
                i.isEven ? 0.5 : 1.0)
          else
            AccelSample((_t0 + i) * 1000.0, 0, 0, 1),
      ];
    }

    test(
        'a record still to its last sample does not certify the final 5 min '
        '(pre-fix: spt_sec 3600 and immobile.last == true)', () {
      // Movement at 3280 sits just BEFORE the tail, so the pre-fix global
      // trailing window [n-win, n) never saw it and declared all 299 tail
      // seconds "no movement" — certifying sustained stillness for seconds
      // whose 5 min of following data do not exist.
      final m = vanHeesSleepWindow(record(moveAt: 3280));
      expect(m.present, isTrue);
      final w = m.value!;

      // van Hees 2015/2018: a second qualifies as "no movement" only when the
      // |Δ z-angle| stays under threshold for the FULL sustained window that
      // FOLLOWS it. The last win-1 seconds of any record have no such window.
      expect(w.immobile.last, isFalse,
          reason: 'pre-fix: true — certified from data BEFORE it');
      expect(w.sptSec, 3301,
          reason: 'pre-fix: 3600 — the rest period annexed the whole '
              'uncertifiable tail');
      expect(w.offsetIdx, lessThanOrEqualTo(n - win + 1));

      // ...and the tail is reported as UNDECIDABLE, not as movement.
      expect(w.undecidableSec, win - 1, reason: 'pre-fix: 0 (no such state)');
      expect(w.immobileUnknown.length, n);
      expect(w.immobileUnknown.sublist(n - win + 1).every((u) => u), isTrue);
      for (var i = 0; i < n - win + 1; i++) {
        expect(w.immobileUnknown[i], isFalse,
            reason: 'second $i has a full forward window — it is decided');
      }
      expect(w.toJson()['undecidable_sec'], win - 1);
    });

    test(
        'a move inside the tail is resolved PER SECOND '
        '(pre-fix: one shared verdict for all 299 tail seconds)', () {
      final m = vanHeesSleepWindow(record(moveAt: 3400));
      expect(m.present, isTrue);
      final w = m.value!;

      // A tail second whose own forward window CONTAINS the burst: the
      // sustained-inactivity rule already fails on the data in hand, whatever
      // comes after the record ends ⇒ decided, and decided "moving".
      expect(w.immobile[3350], isFalse);
      expect(w.immobileUnknown[3350], isFalse,
          reason: 'the move at 3400 decides second 3350');

      // A tail second AFTER the burst sees nothing but stillness, but its
      // window is truncated ⇒ undecidable. Pre-fix it inherited the tail-wide
      // "moving" verdict from a burst that had already ended.
      expect(w.immobile[3500], isFalse);
      expect(w.immobileUnknown[3500], isTrue,
          reason: 'pre-fix: false — a brief move ANYWHERE in the last 5 min '
              'flipped every remaining tail second to "moving"');

      // The two seconds must not share one answer — that is the whole bug.
      expect(w.immobileUnknown[3350] == w.immobileUnknown[3500], isFalse);
      expect(w.undecidableSec, 193, reason: 'pre-fix: 0 (no such state)');
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // (9) CPC: the Thomas 2005 HFC/LFC ratio is a MEASUREMENT or it is nothing —
  //     never a sentinel, never a NaN dressed up as a number.
  // ═══════════════════════════════════════════════════════════════════════════
  group('honesty — cardiopulmonary coupling is WITHDRAWN', () {
    test('always absent, with the reason attached', () {
      // It never measured coupling. Thomas 2005 needs a respiration channel
      // INDEPENDENT of the beat times; the "surrogate" here was the NN series
      // linearly detrended, so sqrt(P_rr . P_resp) collapsed to P_rr and
      // cpc_ratio equalled the plain RR periodogram HF/LF ratio — measured
      // 84.493910 vs 84.493190 on this shape, a ratio of 1.0000085. A healthy
      // record used to "still report a real ratio"; that was the bug, not the
      // control case.
      final nn = <double>[];
      final ts = <double>[];
      var t = 0.0;
      for (var i = 0; i < 3600; i++) {
        final rr = 1000 + 40 * math.sin(2 * math.pi * 0.25 * (t / 1000.0));
        t += rr;
        nn.add(rr);
        ts.add(t);
      }
      // ignore: deprecated_member_use_from_same_package
      final m = cardiopulmonaryCoupling(nn, ts);
      expect(m.present, isFalse);
      expect(m.value, isNull);
      expect(m.confidence, 0);
      expect(m.note, contains('respiration channel'));
    });

    test('the ratio it used to publish was the RR periodogram HF/LF', () {
      // The assertion that would have failed from the first commit (T-02).
      final nn = <double>[];
      final tSec = <double>[];
      var t = 0.0;
      for (var i = 0; i < 3600; i++) {
        final rr = 1000 + 40 * math.sin(2 * math.pi * 0.25 * (t / 1000.0));
        t += rr;
        nn.add(rr);
        tSec.add(t / 1000.0);
      }
      final freqs = freqGrid(0.001, 0.45, 200);
      final ls = lombScargle(tSec, nn, freqs)!;
      // The old "coupling spectrum" was sqrt(P_rr . P_resp) with resp = the
      // detrended NN — reconstruct it and show it is P_rr to 5 significant
      // figures, which is why the metric had to go.
      final rrRatio = ls.bandPower(0.1, 0.4) / ls.bandPower(0.01, 0.1);
      final coupling = LombScargle([
        for (final pt in ls.spectrum)
          LsPoint(pt.freqHz, math.sqrt(pt.psd * pt.psd))
      ]);
      final oldCpc =
          coupling.bandPower(0.1, 0.4) / coupling.bandPower(0.01, 0.1);
      expect(oldCpc / rrRatio, closeTo(1.0, 1e-4));
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // (an-sleep-3) An epoch with no heart rate can only ever be labelled asleep.
  // ═══════════════════════════════════════════════════════════════════════════
  group('honesty — no cardiac evidence is not sleep', () {
    test('two 1 h PPG dropouts inside a 6 h still window are not credited', () {
      // HR coverage 0.667 — comfortably above cardio_stager's `minHrCoverage`
      // abstain floor, which only catches the all-or-nothing case. Every gate
      // that can produce WAKE or REM needs a non-NaN HR while the fall-through
      // is an unconditional NREM, so pre-fix all 7200 no-HR seconds came out
      // asleep: tst 21600, efficiency 100.0, wake 0.
      final accel = <AccelSample>[];
      final hr = <double>[];
      for (var k = 0; k < 6 * 3600; k++) {
        accel.add(AccelSample((_t0 + k) * 1000.0, 0.005, 0.0, 1.0));
        final dropout =
            (k >= 3600 && k < 2 * 3600) || (k >= 4 * 3600 && k < 5 * 3600);
        hr.add(dropout ? 0.0 : 52.0);
      }
      final s = segmentSleep(accel, hr,
          forcedWindow: (onsetSec: _t0, offsetSec: _t0 + 6 * 3600));
      expect(s.present, isTrue);
      // 7200 s of dropout, less the +/-15 s HR-evidence margin reaching into
      // each of the four dropout edges: 7200 - 4*15 = 7140.
      expect(s.unobservedSec, 7140, reason: 'pre-fix: 0 (no such state)');
      expect(s.tstSec!, lessThanOrEqualTo(6 * 3600 - 7140),
          reason: 'pre-fix: 21600 — the dropouts were credited as Light');
      expect(s.stages4[90 * 60], 'unobserved');
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // (SLP-03) Run decomposition. A run ends at an unobserved second.
  // ═══════════════════════════════════════════════════════════════════════════
  group('SLP-03 — wake-ups and the longest unbroken stretch', () {
    /// A forced 8 h window built from [blocks] of (offsetSec, lengthSec,
    /// active). Any second not covered by a block has NO sample at all, which
    /// is what makes it unobserved.
    SleepSegmentation night(List<(int, int, bool)> blocks) {
      final accel = <AccelSample>[];
      final hr = <double>[];
      for (final (from, secs, active) in blocks) {
        for (var k = 0; k < secs; k++) {
          accel.add(AccelSample(
            (_t0 + from + k) * 1000.0,
            active ? (k.isEven ? 0.0 : 0.35) : 0.004,
            0.0,
            active ? 0.93 : 1.0,
          ));
          hr.add(active ? 78 : 50);
        }
      }
      return segmentSleep(accel, hr,
          forcedWindow: (onsetSec: _t0, offsetSec: _t0 + 8 * 3600));
    }

    test('the longest stretch STOPS at a hole instead of bridging it', () {
      // 3 h asleep, a 40-min recording hole, then 4 h 20 asleep. A naive
      // longest-run over the stage labels draws straight through the hole and
      // prints 7 h 20 of unbroken sleep — three quarters of an hour of which
      // nobody watched.
      final s = night([
        (0, 3 * 3600, false),
        (3 * 3600 + 2400, 8 * 3600 - (3 * 3600 + 2400), false),
      ]);
      expect(s.present, isTrue);
      expect(s.unobservedSec, 2400);
      expect(s.longestSleepRunSec, 15600, reason: 'the second block alone');
      expect(
        s.longestSleepRunSec!,
        lessThan(s.tstSec!),
        reason: 'pre-fix a naive run would equal or exceed total sleep time',
      );
      expect(s.sustainedAwakenings, 0, reason: 'a hole is not an awakening');
    });

    test('a sustained wake counts; the hole beside it still does not', () {
      // Same night with a 10-minute genuine awakening after the hole.
      final s = night([
        (0, 3 * 3600, false),
        (3 * 3600 + 2400, 600, true),
        (3 * 3600 + 3000, 8 * 3600 - (3 * 3600 + 3000), false),
      ]);
      expect(s.unobservedSec, 2400);
      expect(s.wakeSec, 600);
      expect(s.sustainedAwakenings, 1);
      // 40 min of hole + 10 min of wake, both broken out of the run.
      expect(s.longestSleepRunSec, 15000);
    });

    test('a wake shorter than the stated bar is not an awakening', () {
      final s = night([
        (0, 4 * 3600, false),
        (4 * 3600, 120, true), // 2 min, under the 5-minute bar
        (4 * 3600 + 120, 8 * 3600 - (4 * 3600 + 120), false),
      ]);
      expect(s.sustainedAwakenings, 0);
      // And the bar itself ships with the count so a screen can state it.
      expect(s.toJson()['awakening_min_sec'], kSustainedAwakeningSec);
    });
  });
}
