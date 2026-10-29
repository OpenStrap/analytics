import 'dart:math' as math;

import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

// Synthetic nights; no personal sensor data. A 70-minute awakening fits the
// inclusive 90-minute continuation limit; the gap remains awake or unobserved.
void main() {
  for (final scenario in [
    (gapMinutes: 70, observed: true),
    (gapMinutes: 100, observed: true),
    (gapMinutes: 70, observed: false),
  ]) {
    final gapMinutes = scenario.gapMinutes;
    test(
        'main sleep after a $gapMinutes-minute break (observed: ${scenario.observed})',
        () {
      final data = _Recording();
      data.block(120 * 60, awake: true);
      data.block(240 * 60, awake: false); // 23:00–03:00
      data.block(gapMinutes * 60, awake: true, observed: scenario.observed);
      data.block(180 * 60, awake: false);
      data.block(120 * 60, awake: true);

      final sleep = segmentSleep(data.accel, data.hr, tzOffsetSec: 0);
      expect(sleep.present, isTrue);
      if (gapMinutes == 70) {
        expect(sleep.inBedSec, greaterThan(8 * 3600),
            reason: 'both overnight blocks belong to the main sleep');
        expect(sleep.tstSec, greaterThan(6 * 3600));
        expect(sleep.tstSec, lessThanOrEqualTo(7 * 3600),
            reason: 'the awake gap must not inflate time asleep');
        if (scenario.observed) {
          expect(sleep.wasoSec, greaterThanOrEqualTo(65 * 60));
        } else {
          expect(sleep.unobservedSec, greaterThanOrEqualTo(70 * 60));
          expect(sleep.wasoSec, lessThan(10 * 60),
              reason: 'missing measurements must not become measured wake');
        }
      } else {
        expect(sleep.inBedSec, lessThan(5 * 3600),
            reason: 'a break beyond the continuation limit stays separate');
      }
    });
  }

  for (final gap in [90 * 60, 90 * 60 + 1]) {
    test('detected session gap of $gap seconds respects the inclusive limit',
        () {
      final data = _Recording();
      data.block(2 * 3600, awake: true);
      data.block(4 * 3600, awake: false);
      // The still-window filter and last-sample run endpoints add 342
      // seconds for this fixture. Verify the detected gap, not the raw one.
      data.block(gap - 342, awake: true);
      data.block(3 * 3600, awake: false);
      data.block(2 * 3600, awake: true);
      final sessions = data.detect();
      expect(sessions, hasLength(2));
      expect(sessions[1].start - sessions[0].end, gap);
      final sleep = segmentSleep(data.accel, data.hr, tzOffsetSec: 0);
      expect(sleep.present, isTrue);
      expect(sleep.inBedSec,
          gap == 90 * 60 ? greaterThan(8 * 3600) : lessThan(5 * 3600));
    });
  }

  for (final hours in [
    <int>[8, 8],
    <int>[6, 5, 5]
  ]) {
    test('fragmented night $hours cannot bypass the 16-hour span cap', () {
      final data = _Recording(startHour: 18);
      data.block(2 * 3600, awake: true);
      for (var i = 0; i < hours.length; i++) {
        if (i > 0) data.block(70 * 60, awake: true);
        data.block(hours[i] * 3600, awake: false);
      }
      data.block(2 * 3600, awake: true);
      final sessions = data.detect();
      expect(sessions, hasLength(hours.length));
      expect(sessions.last.end - sessions.first.start, greaterThan(16 * 3600));
      final sleep = segmentSleep(data.accel, data.hr, tzOffsetSec: 0);
      expect(sleep.present, isTrue);
      expect(sleep.inBedSec, lessThanOrEqualTo(16 * 3600));
      expect(sleep.tstSec, greaterThan(5 * 3600),
          reason:
              'keep a valid main group rather than discard the whole night');
    });
  }
}

class _Recording {
  final accel = <AccelSample>[];
  final hr = <double>[];
  final int start;
  int elapsedSeconds = 0;

  _Recording({int startHour = 21})
      : start = DateTime.utc(2024, 1, 1, startHour).millisecondsSinceEpoch;

  void block(int seconds, {required bool awake, bool observed = true}) {
    for (var i = 0; i < seconds; i++, elapsedSeconds++) {
      if (!observed) continue;
      final phase = math.sin(i * 0.5);
      accel.add(AccelSample(
        start + elapsedSeconds * 1000.0,
        awake ? 0.3 * phase : 0.02,
        awake ? 0.3 : 0.02,
        awake ? 0.9 * (1 - 0.2 * phase) : 1.0,
      ));
      hr.add(awake ? 85 : 49 + 1.5 * math.sin(i / 1800));
    }
  }

  List<SleepSession> detect() => AdvancedSleepStager.detectSleep(
        [for (final a in accel) GravTs(a.tsMs ~/ 1000, a.x, a.y, a.z)],
        [
          for (var i = 0; i < accel.length; i++)
            HrTs(accel[i].tsMs ~/ 1000, hr[i])
        ],
        tzOffsetSec: 0,
      );
}
