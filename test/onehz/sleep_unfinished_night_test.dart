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
