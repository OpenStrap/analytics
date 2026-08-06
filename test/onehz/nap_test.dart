// Nap detector — synthetic known-answer tests.
//
// The regime under test is the one the NIGHT detector deliberately rejects:
// `AdvancedSleepStager.minSleepMin = 60` exists so "daytime naps and stray
// still-blocks stay excluded" (advanced_stager.dart:327), and anything centred
// 11:00–20:00 local additionally needs ≥90 min plus an HR dip. Reusing that
// detector for naps made the canonical 20–45 min afternoon nap structurally
// undetectable. These tests pin the new, purpose-built path.
import 'dart:math' as math;

import 'package:test/test.dart';
import 'package:openstrap_analytics/src/onehz/types.dart';
import 'package:openstrap_analytics/src/onehz/sleep/nap.dart';

/// A synthetic day at 1 Hz. Timestamps are `i * 1000` ms, so absolute epoch
/// seconds equal the array index — which keeps the `[startSec, endSec]` span
/// arguments (off-wrist, charging) readable in tests.
class _Day {
  final accel = <AccelSample>[];
  final hr = <double>[];
  int _i = 0;

  int get cursor => _i;

  /// Advance the CLOCK without emitting samples — a pruning / sync hole. The
  /// substrate is a positional array, so the samples either side of this are
  /// adjacent indices despite being [minutes] apart in wall time.
  void gap(int minutes) => _i += minutes * 60;

  /// Wrist in motion: a SMOOTH angular sweep of up to ~14°/s.
  ///
  /// Deliberately smooth rather than a per-second square wave — van Hees runs
  /// a 5 s rolling median, which erases an alternation between two values
  /// entirely and would make "active" read as perfectly still.
  void active(int minutes, {double bpm = 82}) {
    for (var s = 0; s < minutes * 60; s++, _i++) {
      final deg = 45 + 35 * math.sin(_i * 0.4);
      final rad = deg * math.pi / 180;
      accel.add(AccelSample(_i * 1000.0, math.cos(rad), 0, math.sin(rad)));
      hr.add(bpm);
    }
  }

  /// A motionless block at one fixed orientation.
  /// `bpm <= 0` writes an HR gap — the substrate's own "no reading" encoding,
  /// which is what off-wrist and dropout actually look like.
  void still(int minutes, {double bpm = 54}) {
    for (var s = 0; s < minutes * 60; s++, _i++) {
      accel.add(AccelSample(_i * 1000.0, 0, 0, 1));
      hr.add(bpm);
    }
  }
}

void main() {
  group('detectNaps — the 20–60 min regime the night detector rejects', () {
    test('a 30-minute nap is detected', () {
      final d = _Day()
        ..active(120)
        ..still(30)
        ..active(120);

      final m = detectNaps(d.accel, d.hr);

      expect(m.present, isTrue, reason: 'ran with ample data');
      expect(m.value, hasLength(1),
          reason: 'exactly one still, HR-dipped block in the day');
      final nap = m.value!.single;
      // Tight on purpose. The van Hees rule marks the second that STARTS a
      // sustained-still window, so the last `sustainedMin` of any still block
      // is never itself marked immobile — a naive bout end under-reports every
      // nap by a flat 5 min. This tolerance fails unless the tail is recovered
      // from the actual angle data.
      expect(nap.tstSec, closeTo(30 * 60, 90),
          reason: 'a 30 min nap should report ~30 min ASLEEP, not 25');
      expect(nap.tibSec, greaterThanOrEqualTo(nap.tstSec),
          reason: 'time in bed can never be less than time asleep');
      expect(nap.confidence, inInclusiveRange(0.2, 0.85));
    });

    test('a 20-minute nap is detected', () {
      final d = _Day()
        ..active(90)
        ..still(20)
        ..active(90);

      final m = detectNaps(d.accel, d.hr);

      expect(m.value, hasLength(1));
      expect(m.value!.single.tstSec, closeTo(20 * 60, 90));
    });

    test('a 12-minute rest is below the floor and is not a nap', () {
      final d = _Day()
        ..active(90)
        ..still(12)
        ..active(90);

      expect(detectNaps(d.accel, d.hr).value, isEmpty);
    });

    test('two separate naps are reported separately, not merged', () {
      final d = _Day()
        ..active(60)
        ..still(20)
        ..active(60)
        ..still(25)
        ..active(60);

      final m = detectNaps(d.accel, d.hr);

      expect(m.value, hasLength(2), reason: 'a 60 min gap is not an arousal');
      expect(m.value![0].tstSec, closeTo(20 * 60, 90));
      expect(m.value![1].tstSec, closeTo(25 * 60, 90));
    });

    test('a brief arousal is bridged, and costs TST but not TIB', () {
      final d = _Day()
        ..active(90)
        ..still(20)
        ..active(2) // 2 min arousal — shorter than the 5 min bridge
        ..still(20)
        ..active(90);

      final m = detectNaps(d.accel, d.hr);

      expect(m.value, hasLength(1), reason: 'one nap with an arousal in it');
      final nap = m.value!.single;
      expect(nap.tibSec, closeTo(42 * 60, 120), reason: '20 + 2 + 20 in bed');
      expect(nap.tstSec, lessThan(nap.tibSec),
          reason: 'the arousal is time in bed but NOT time asleep');
      expect(nap.efficiency, lessThan(1.0));
    });
  });

  group('detectNaps — false-positive rejection', () {
    test('still but with no HR dip is desk work, not a nap', () {
      final d = _Day()
        ..active(90, bpm: 80)
        ..still(40, bpm: 80) // motionless, but HR never drops
        ..active(90, bpm: 80);

      final m = detectNaps(d.accel, d.hr);

      expect(m.value, isEmpty);
      expect(m.note, contains('no HR dip'),
          reason: 'the rejection reason must be visible, not silent');
    });

    test('a SEDENTARY DAY is not eight naps — sedentary wake stays in the '
        'awake baseline', () {
      // THE REGRESSION. The baseline once excluded every detected bout, which
      // removed all of the day's still time and left the AMBULATORY HR median
      // in its place. Every motionless block then cleared `medHr > baseline *
      // napRestingHrMult` on nothing but the ordinary sit/walk HR difference:
      // this exact fixture returned EIGHT naps totalling 199 minutes, each at
      // confidence 0.85 — the cap — for a day nobody napped on.
      //
      // The test above cannot catch it: it uses bpm 80 for BOTH its active and
      // still segments, so active and sedentary HR are identical and the
      // baseline cannot be inflated. The contrast IS the bug, so it has to be
      // in the fixture.
      final d = _Day();
      for (var b = 0; b < 8; b++) {
        d
          ..active(6, bpm: 96) // walking
          ..still(25, bpm: 72); // at the desk — awake, just not moving
      }
      d.active(60, bpm: 96);

      final m = detectNaps(d.accel, d.hr);

      expect(m.value, isEmpty,
          reason: 'sitting still at 72 bpm on a day you walk at 96 is not a '
              'nap; keeping the still seconds puts the median at 72, and '
              '0.95 x 72 = 68.4 < 72 rejects every block');
      expect(m.note, contains('no HR dip'));
    });

    test('the same day at a 10% HR contrast is also not a nap', () {
      // The failure did not need a dramatic difference — 84 vs 76 bpm, which is
      // an unremarkable sit-versus-walk gap, produced all eight at 0.84.
      final d = _Day();
      for (var b = 0; b < 8; b++) {
        d
          ..active(6, bpm: 84)
          ..still(25, bpm: 76);
      }
      d.active(60, bpm: 84);

      expect(detectNaps(d.accel, d.hr).value, isEmpty);
    });

    test('an off-wrist span is rejected even though it is perfectly still', () {
      final d = _Day()
        ..active(90)
        ..still(40) // band on a table: still, and "HR" looks restful
        ..active(90);
      final offStart = 90 * 60, offEnd = offStart + 40 * 60;

      final m = detectNaps(
        d.accel,
        d.hr,
        wristOff: [
          [offStart, offEnd]
        ],
      );

      expect(m.value, isEmpty);
      expect(m.note, contains('off-wrist'));
    });

    test('a charging/workout exclusion span is rejected', () {
      final d = _Day()
        ..active(90)
        ..still(40)
        ..active(90);
      final exStart = 90 * 60, exEnd = exStart + 40 * 60;

      final m = detectNaps(
        d.accel,
        d.hr,
        exclude: [
          [exStart, exEnd]
        ],
      );

      expect(m.value, isEmpty);
    });

    test('overlapping off-wrist spans count their union, not their sum', () {
      // Two spans covering the SAME 12 minutes of a 40-min nap. That is 30% of
      // the bout contradicted, under the 50% rejection bar, so the nap stands.
      // Summing the spans independently scores it 60% and throws the nap away —
      // and drives `corroborated` to 0 for any bout that survives. The band's
      // own toggle events do not overlap today, so this pins the contract for
      // every other caller rather than a live symptom.
      final d = _Day()
        ..active(90)
        ..still(40)
        ..active(90);
      final napStart = 90 * 60;
      final dupStart = napStart + 5 * 60, dupEnd = dupStart + 12 * 60;

      final m = detectNaps(
        d.accel,
        d.hr,
        wristOff: [
          [dupStart, dupEnd],
          [dupStart, dupEnd],
        ],
      );

      expect(m.present, isTrue);
      expect(m.value, hasLength(1),
          reason: 'the same 12 minutes listed twice is still 12 minutes');
    });

    test('thin HR coverage abstains for that bout rather than guessing', () {
      final d = _Day()
        ..active(90)
        ..still(40, bpm: 0) // HR gap throughout — nothing to corroborate with
        ..active(90);

      final m = detectNaps(d.accel, d.hr);

      expect(m.value, isEmpty, reason: 'never assert sleep without evidence');
      expect(m.note, contains('unverifiable'));
    });

    test('a block longer than 6 h is not a nap', () {
      final d = _Day()
        ..active(60)
        ..still(7 * 60)
        ..active(60);

      expect(detectNaps(d.accel, d.hr).value, isEmpty);
    });

    test('the main sleep window is carved out', () {
      final d = _Day()
        ..active(60)
        ..still(120)
        ..active(60);
      final start = 60 * 60, end = start + 120 * 60;

      final m = detectNaps(
        d.accel,
        d.hr,
        mainSleep: SleepWindowSpan(start, end),
      );

      expect(m.present, isTrue);
      expect(m.value, isEmpty, reason: 'the only block IS the main sleep');
    });
  });

  group('detectNaps — honest absence', () {
    test('too little data is absent, never an empty list', () {
      final m = detectNaps(const <AccelSample>[], const <double>[]);

      expect(m.present, isFalse);
      expect(m.value, isNull, reason: 'absent and "found none" differ');
      expect(m.confidence, 0);
      expect(m.tier, Tier.estimate);
      expect(m.note, contains('too little data'));
    });

    test('a day with no awake HR is absent, not zero naps', () {
      final d = _Day()
        ..active(90, bpm: 0)
        ..still(30, bpm: 0)
        ..active(90, bpm: 0);

      final m = detectNaps(d.accel, d.hr);

      expect(m.present, isFalse,
          reason: 'no baseline to judge against — abstain');
      expect(m.note, contains('awake daytime HR'));
    });

    test('too few awake HR samples abstains rather than setting a threshold',
        () {
      // Only ~2 min of awake HR in the whole day. A median over that is not a
      // baseline, and every nap verdict hangs off it.
      final d = _Day()
        ..active(2, bpm: 80)
        ..active(120, bpm: 0)
        ..still(30)
        ..active(120, bpm: 0);

      final m = detectNaps(d.accel, d.hr);

      expect(m.present, isFalse);
      expect(m.note, contains('need'));
    });

    test('a judged day holding no nap is an EMPTY list, not absent', () {
      final d = _Day()..active(240);

      final m = detectNaps(d.accel, d.hr);

      expect(m.present, isTrue, reason: 'we did judge this day');
      expect(m.value, isEmpty);
    });
  });

  group('detectNaps — boundary safety', () {
    test('a bout still running at the record end is DEFERRED, not emitted', () {
      // This is the phantom-nap bug: with a 3 h buffer past midnight, the
      // first hours of TONIGHT'S sleep were emitted as a multi-hour "nap" for
      // the day that was ending, then counted again as tomorrow's main sleep.
      final d = _Day()
        ..active(120)
        ..still(90); // record ends mid-sleep

      final m = detectNaps(d.accel, d.hr);

      expect(m.value, isEmpty,
          reason: 'cannot know when a right-censored bout ends');
      expect(m.note, contains('deferred'));
    });

    test('the same bout IS emitted once the record shows it ending', () {
      final d = _Day()
        ..active(120)
        ..still(90)
        ..active(60); // now we can see it end

      expect(detectNaps(d.accel, d.hr).value, hasLength(1));
    });

    test('an awakening inside the unfinished night does not free a phantom nap',
        () {
      // REGRESSION. Deferring only the bout whose LAST second is still is not
      // enough. The nap window runs 3 h past midnight, so tonight's sleep is in
      // it; a perfectly ordinary 6-minute awakening at 01:50 splits that sleep
      // into two bouts, and only the trailing one touches the record end. The
      // leading fragment was emitted as a ~170-minute "nap" for the day that
      // was ending, credited against tonight's sleep need, and then counted a
      // SECOND time as tomorrow's main sleep.
      final d = _Day()
        ..still(360, bpm: 50) // last night's sleep — passed as mainSleep
        ..active(1020, bpm: 82) // the waking day
        ..still(170, bpm: 50) // tonight's sleep begins
        ..active(6, bpm: 70) // a 6 min awakening — longer than the 5 min bridge
        ..still(64, bpm: 50); // still asleep when the record stops

      final m = detectNaps(
        d.accel,
        d.hr,
        mainSleep: const SleepWindowSpan(0, 360 * 60),
      );

      expect(m.present, isTrue);
      expect(m.value, isEmpty,
          reason: 'both halves of an unfinished night must be deferred — '
              'neither is a nap that happened today');
      expect(m.note, contains('deferred'));
    });
  });

  group('detectNaps — the HR baseline is genuinely awake', () {
    test('a real nap is still detected on a sleep-dominated window', () {
      // REGRESSION. The baseline excluded only `mainSleep`, so it still
      // contained the candidate nap's own low-HR seconds AND the hours of
      // tonight's sleep that the nap window deliberately borrows. On a window
      // where sleep outweighs wake, the median collapses toward sleeping HR and
      // the dip gate becomes self-suppressing: the quieter the sleep, the lower
      // the bar it has to beat. Here the contaminated median is ~48 bpm, so a
      // genuine 60 bpm nap could never clear 0.95 x 48.
      final d = _Day()
        ..active(50, bpm: 78)
        ..still(30, bpm: 60) // the genuine nap
        ..active(70, bpm: 78) // > napChainGapSec, so no chained deferral
        ..still(180, bpm: 48); // tonight's sleep, unfinished at the record end

      final m = detectNaps(d.accel, d.hr);

      expect(m.value, hasLength(1),
          reason: 'the awake baseline is ~78 bpm; a 60 bpm nap clears it');
      expect(m.value!.single.tstSec, closeTo(30 * 60, 90));
    });

    test('a real nap is still detected on a SEDENTARY day', () {
      // The other side of the same coin, and the reason the fix keeps sedentary
      // wake in the pool instead of dropping every bout: a day that is mostly
      // sitting still must still be able to report the one block that was
      // actually sleep. Baseline lands at desk HR (~72), and 56 clears
      // 0.95 x 72 = 68.4 comfortably.
      final d = _Day();
      for (var b = 0; b < 4; b++) {
        d
          ..active(6, bpm: 96)
          ..still(25, bpm: 72);
      }
      d.still(50, bpm: 56); // the genuine nap, a real autonomic dip
      for (var b = 0; b < 4; b++) {
        d
          ..active(6, bpm: 96)
          ..still(25, bpm: 72);
      }
      d.active(60, bpm: 96); // end awake: nothing to defer at the record end

      final m = detectNaps(d.accel, d.hr);

      expect(m.value, hasLength(1),
          reason: 'the deep-dip block is a nap even though the day around it '
              'is sedentary');
    });
  });

  group('detectNaps — recording holes are not stillness', () {
    test('a gap inside a still block does not become one long nap', () {
      // The substrate is a POSITIONAL array: pruning and sync holes leave the
      // samples either side of a 2 h absence at adjacent indices. Measuring the
      // bout in sample counts would read that unobserved hole as unbroken
      // stillness and report a 2 h 20 m nap from 20 minutes of evidence.
      final d = _Day()
        ..active(90)
        ..still(10)
        ..gap(120)
        ..still(10)
        ..active(90);

      final m = detectNaps(d.accel, d.hr);

      expect(m.value, isEmpty,
          reason: 'two 10-minute observed blocks, each below the 15 min floor '
              '— the unobserved 2 h between them is not sleep');
    });

    test('a nap reported across no gap has tib matching its own bounds', () {
      final d = _Day()
        ..active(90)
        ..still(30)
        ..active(90);

      final nap = detectNaps(d.accel, d.hr).value!.single;

      expect(nap.tibSec, nap.endSec - nap.startSec,
          reason: 'in-bed seconds must equal the reported span, or the card '
              'and the clock range disagree');
    });
  });

  group('detectNaps — determinism', () {
    test('detection does not depend on wall-clock time of day', () {
      // The old path routed candidates through a local-clock 11:00–20:00 guard,
      // so an identical nap appeared or vanished with the machine timezone.
      List<AccelSample> shifted(List<AccelSample> a, int hours) => [
            for (final s in a)
              AccelSample(s.tsMs + hours * 3600 * 1000, s.x, s.y, s.z)
          ];

      final d = _Day()
        ..active(120)
        ..still(30)
        ..active(120);

      final baseline = detectNaps(d.accel, d.hr);
      for (final h in [3, 7, 11, 14, 19, 23]) {
        final m = detectNaps(shifted(d.accel, h), d.hr);
        expect(m.value!.length, baseline.value!.length,
            reason: 'same nap, shifted $h h — detection must not move');
        expect(m.value!.single.tstSec, baseline.value!.single.tstSec);
      }
    });
  });
}
