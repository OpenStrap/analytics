// test/onehz/sleep_unfinished_night_test.dart
//
// A calendar-day slice ends at local midnight while the record carries on. An
// early bedtime is still asleep at that cut, so the detector closes the run at
// the last sample and the first hours of tonight looked like a finished night
// for the day that is ending — and were counted again by the next day's slice.
import 'dart:math' as math;
import 'package:test/test.dart';
import 'package:openstrap_analytics/onehz.dart';

const int _t0 = 1700000000;
final int _midnight = _t0 - (_t0 % 86400); // day D 00:00 UTC

/// Builds 1 Hz streams over [from, to) with the wearer asleep (still, HR 55)
/// inside any of [asleep] and moving (HR 85) otherwise.
({List<AccelSample> accel, List<double> hr}) _record(
    int from, int to, List<(int, int)> asleep) {
  final accel = <AccelSample>[], hr = <double>[];
  final rnd = math.Random(11);
  for (var t = from; t < to; t++) {
    final still = asleep.any((s) => t >= s.$1 && t < s.$2);
    accel.add(AccelSample(t * 1000.0,
        still ? 0.01 * rnd.nextDouble() : 0.4 * math.cos(t / 2), 0.0,
        still ? 1.0 : 1.0 + 0.3 * math.sin(t / 3)));
    hr.add(still ? 55 : 85);
  }
  return (accel: accel, hr: hr);
}

void main() {
  // Band on the charger overnight, so day D's slice holds no sleep before
  // tonight's first 3.5 h: bed at 20:30, cut at midnight.
  final evening = _record(_midnight + 12 * 3600, _midnight + 86400, [
    (_midnight + 20 * 3600 + 30 * 60, _midnight + 86400),
  ]);

  test('fixture reproduces the bug: the cut-off evening is published', () {
    final s = segmentSleep(evening.accel, evening.hr, tzOffsetSec: 0);
    expect(s.present, isTrue);
    expect(s.window!.offsetMs! ~/ 1000,
        greaterThan(_midnight + 86400 - 5 * 60)); // "woke" at the cut
  });

  test('record continues past the cut: the unfinished night is deferred', () {
    final s = segmentSleep(evening.accel, evening.hr,
        tzOffsetSec: 0, recordContinues: true);
    expect(s.present, isFalse);
    expect(s.tstSec, isNull);
    expect(s.inBedSec, isNull);
    // A deferral, not "no sleep": the caller must be able to tell them apart
    // or it goes looking for a window by the HR-led route instead.
    expect(s.unfinished, isTrue);
    expect(s.absenceReason, kAbsenceNightUnfinished);
  });

  test('an empty slice is plain absent, not unfinished', () {
    final r = _record(_midnight + 12 * 3600, _midnight + 86400, const []);
    final s = segmentSleep(r.accel, r.hr, tzOffsetSec: 0, recordContinues: true);
    expect(s.present, isFalse);
    expect(s.unfinished, isFalse);
  });

  // The edge runs the HR-led fallback whenever the accel path comes back
  // without a night. Over the same cut-off slice it proposed the same evening
  // as a finished night, so deferring in segmentSleep alone changed nothing.
  group('hrLedSleepWindow over a slice cut at midnight', () {
    List<int> ts(List<AccelSample> a) => [for (final x in a) x.tsMs ~/ 1000];

    test('without the flag it proposes the cut-off evening (the bug)', () {
      final w = hrLedSleepWindow(evening.hr, ts(evening.accel),
          hrBaseline: const [85.0]);
      expect(w, isNotNull);
      expect(w!.offsetSec, greaterThan(_midnight + 86400 - 5 * 60));
    });

    test('record continues: the still-going dip is not proposed', () {
      final w = hrLedSleepWindow(evening.hr, ts(evening.accel),
          hrBaseline: const [85.0], recordContinues: true);
      expect(w, isNull);
    });

    test('record continues: a finished dip earlier in the slice still wins', () {
      final r = _record(_midnight - 4 * 3600, _midnight + 86400, [
        (_midnight - 3600, _midnight + 7 * 3600),
        (_midnight + 20 * 3600 + 30 * 60, _midnight + 86400),
      ]);
      final w = hrLedSleepWindow(r.hr, ts(r.accel),
          hrBaseline: const [85.0], recordContinues: true);
      expect(w, isNotNull);
      expect(w!.offsetSec, lessThan(_midnight + 8 * 3600));
      expect(w.offsetSec, greaterThan(_midnight + 6 * 3600));
    });

    test('a dip that ended well before the cut is unchanged by the flag', () {
      final r = _record(_midnight - 4 * 3600, _midnight + 12 * 3600, [
        (_midnight - 3600, _midnight + 7 * 3600),
      ]);
      final a = hrLedSleepWindow(r.hr, ts(r.accel), hrBaseline: const [85.0]);
      final b = hrLedSleepWindow(r.hr, ts(r.accel),
          hrBaseline: const [85.0], recordContinues: true);
      expect(a, isNotNull);
      expect(b, isNotNull);
      expect(b!.onsetSec, a!.onsetSec);
      expect(b.offsetSec, a.offsetSec);
    });

    test('record continues: a finished daytime dip 75 min before it is kept',
        () {
      // Same day shape as the segmentSleep case below: asleep 12:00 → 15:20,
      // up for 75 min, asleep again from 16:35 to the cut at 20:00. Neither
      // run starts overnight, so the first is not part of the deferred one.
      final r = _record(_midnight + 6 * 3600, _midnight + 20 * 3600, [
        (_midnight + 12 * 3600, _midnight + 15 * 3600 + 20 * 60),
        (_midnight + 16 * 3600 + 35 * 60, _midnight + 20 * 3600),
      ]);
      final w = hrLedSleepWindow(r.hr, ts(r.accel),
          hrBaseline: const [85.0],
          recordContinues: true,
          tzOffsetResolver: (_) => 0);
      expect(w, isNotNull);
      expect(w!.offsetSec, lessThan(_midnight + 16 * 3600));
    });

    test('record continues: the same day read 8 h ahead is one deferred night',
        () {
      // The record above with a +8 h offset: the runs start at 20:00 and
      // 00:35 local, both overnight, so the 75-min gap chains them and
      // neither is a finished night.
      final r = _record(_midnight + 6 * 3600, _midnight + 20 * 3600, [
        (_midnight + 12 * 3600, _midnight + 15 * 3600 + 20 * 60),
        (_midnight + 16 * 3600 + 35 * 60, _midnight + 20 * 3600),
      ]);
      final w = hrLedSleepWindow(r.hr, ts(r.accel),
          hrBaseline: const [85.0],
          recordContinues: true,
          tzOffsetResolver: (_) => 8 * 3600);
      expect(w, isNull);
    });

    test('record continues: an overnight dip 75 min before it is deferred too',
        () {
      // Asleep 20:30 → 23:00, up for 75 min, asleep again from 00:15 to the
      // cut at 03:00: one night split by a long arousal, so neither half is
      // a finished night yet. The first half is long enough to be proposed on
      // its own, so this fails if the chain is lost.
      final r = _record(_midnight + 18 * 3600, _midnight + 27 * 3600, [
        (_midnight + 20 * 3600 + 30 * 60, _midnight + 23 * 3600),
        (_midnight + 24 * 3600 + 15 * 60, _midnight + 27 * 3600),
      ]);
      final w = hrLedSleepWindow(r.hr, ts(r.accel),
          hrBaseline: const [85.0],
          recordContinues: true,
          tzOffsetResolver: (_) => 0);
      expect(w, isNull);
    });
  });

  test('a finished night earlier in the slice is still the main sleep', () {
    final night = (_midnight - 3600, _midnight + 7 * 3600); // 23:00 → 07:00
    final r = _record(_midnight - 4 * 3600, _midnight + 86400, [
      night,
      (_midnight + 20 * 3600 + 30 * 60, _midnight + 86400),
    ]);
    final s = segmentSleep(r.accel, r.hr, tzOffsetSec: 0, recordContinues: true);
    expect(s.present, isTrue);
    final off = s.window!.offsetMs! ~/ 1000;
    expect(off, lessThan(_midnight + 8 * 3600));
    expect(off, greaterThan(_midnight + 6 * 3600));
  });

  test('a finished daytime sleep 75 min before a still-going one is kept', () {
    // Asleep 12:00 → 15:20, up for 75 min, asleep again from 16:35 to the cut
    // at 20:00. The second sleep is deferred; the first is finished and is not
    // part of it, so it must not be deferred along with it.
    final r = _record(_midnight + 6 * 3600, _midnight + 20 * 3600, [
      (_midnight + 12 * 3600, _midnight + 15 * 3600 + 20 * 60),
      (_midnight + 16 * 3600 + 35 * 60, _midnight + 20 * 3600),
    ]);
    final s = segmentSleep(r.accel, r.hr, tzOffsetSec: 0, recordContinues: true);
    expect(s.unfinished, isFalse);
    expect(s.present, isTrue);
    expect(s.window!.offsetMs! ~/ 1000, lessThan(_midnight + 16 * 3600));
  });

  test('a night that ended well before the cut is not deferred', () {
    // Asleep 23:00 → 07:00, awake and moving until the slice ends at 12:00.
    final r = _record(_midnight - 4 * 3600, _midnight + 12 * 3600, [
      (_midnight - 3600, _midnight + 7 * 3600),
    ]);
    expect(
        segmentSleep(r.accel, r.hr, tzOffsetSec: 0, recordContinues: true)
            .toJson(),
        segmentSleep(r.accel, r.hr, tzOffsetSec: 0).toJson());
  });
}
