// AutoWorkoutDetector — synthetic known-answer tests for how a REST inside a
// workout is handled.
//
// The report this covers: "I play tennis for an hour, after 20 min I sit down
// for 5-10 min and then start again, and it splits the workout into 2
// workouts." The sit-down drops HR below the gate, the span closes after
// maxDipS, and the halves landed ~7.5 min apart — past the old 5-min merge.
//
// All series are 1 Hz, HR-only (no motion → no motion gate), RHR 60 /
// HRmax 190: gate = max(60+40, round(60 + 0.45·130)) = 119 bpm, rest-bridge
// floor = round(60 + 0.15·130) = 80 bpm.
import 'dart:math' as math;

import 'package:test/test.dart';
import 'package:openstrap_analytics/src/onehz/workout/auto_detect.dart';

const int _t0 = 1700000000;
const int _rhr = 60;
const int _hrMax = 190;

/// Builds a 1 Hz HR series from consecutive segments. A segment is either a
/// constant level or a recovery curve; `null` bpm means "no samples" (strap
/// off the wrist) for that many seconds.
class _Series {
  final ts = <int>[];
  final bpm = <int>[];
  var _t = _t0;

  int get now => _t;

  void flat(int minutes, int? hr) {
    for (var i = 0; i < minutes * 60; i++, _t++) {
      if (hr == null) continue;
      ts.add(_t);
      bpm.add(hr);
    }
  }

  /// Exponential recovery from [from] toward [to] (τ = 60 s) — what HR does
  /// when you stop and sit down.
  void recover(int minutes, int from, int to) {
    for (var i = 0; i < minutes * 60; i++, _t++) {
      ts.add(_t);
      bpm.add((to + (from - to) * math.exp(-i / 60.0)).round());
    }
  }

  List<DetectedWorkout> detect() => AutoWorkoutDetector.detect(
        hrTs: ts,
        hrBpm: bpm,
        restingBpm: _rhr,
        maxBpm: _hrMax,
      );
}

void main() {
  group('AutoWorkoutDetector rest bridging', () {
    test('tennis 20 min / 8 min sit-down / 30 min is ONE workout', () {
      final s = _Series()..flat(10, 70);
      final playStart = s.now;
      s
        ..flat(20, 140)
        ..recover(8, 140, 90) // sitting: HR falls but stays well above rest
        ..flat(30, 140);
      final playEnd = s.now - 1;
      s.flat(20, 70);

      final w = s.detect();
      expect(w, hasLength(1));
      expect(w.single.startSec, playStart);
      expect(w.single.endSec, playEnd);
      expect(w.single.durationMin, 57); // 58 min of samples, floor((58·60−1)/60)
      // The reported average covers the whole session, the sit-down included:
      // below the 140 of play, above the gate.
      expect(w.single.avgBpm, lessThan(140));
      expect(w.single.avgBpm, greaterThan(119));
    });

    test('the sit-down really is past the unconditional 5-min merge', () {
      // Guards the test above against passing for the wrong reason: the two
      // halves must come out of span-building > mergeGapS apart, so it is
      // the rest bridge that joins them.
      final s = _Series()
        ..flat(10, 70)
        ..flat(20, 140)
        ..recover(8, 140, 90)
        ..flat(30, 140)
        ..flat(20, 70);
      final secondHalfStart = _t0 + 38 * 60;
      // Last at-gate second before play resumes: the tail of the first half
      // plus the few seconds the recovery curve takes to cross the gate.
      final firstHalfEnd = [
        for (var k = 0; k < s.ts.length; k++)
          if (s.bpm[k] >= 119 && s.ts[k] < secondHalfStart) s.ts[k]
      ].last;
      expect(secondHalfStart - firstHalfEnd,
          greaterThan(AutoWorkoutDetector.mergeGapS));
      expect(secondHalfStart - firstHalfEnd,
          lessThanOrEqualTo(AutoWorkoutDetector.restBridgeMaxS));
    });

    test('two sessions 2 h apart stay TWO workouts', () {
      // HR between them is held at 90 — above the bridge floor — so it is the
      // time limit, not HR, that keeps them apart.
      final s = _Series()..flat(10, 70);
      final morningStart = s.now;
      s.flat(30, 140);
      final morningEnd = s.now - 1;
      s.flat(120, 90);
      final laterStart = s.now;
      s
        ..flat(30, 140)
        ..flat(10, 70);

      final w = s.detect();
      expect(w, hasLength(2));
      expect(w[0].startSec, morningStart);
      expect(w[0].endSec, morningEnd);
      expect(w[1].startSec, laterStart);
    });

    test('a 20-min elevated pause is past the bridge limit → TWO', () {
      final s = _Series()
        ..flat(10, 70)
        ..flat(20, 140)
        ..flat(20, 95)
        ..flat(30, 140)
        ..flat(10, 70);
      expect(s.detect(), hasLength(2));
    });

    test('an 8-min pause where HR is back at rest → TWO', () {
      // Done, sat down, fully recovered: the next effort is a new workout.
      final s = _Series()
        ..flat(10, 70)
        ..flat(20, 140)
        ..recover(8, 140, 65)
        ..flat(30, 140)
        ..flat(10, 70);
      expect(s.detect(), hasLength(2));
    });

    test('an 8-min pause with the strap off the wrist → TWO', () {
      // No samples is not evidence the user kept going (see maxGapS).
      final s = _Series()
        ..flat(10, 70)
        ..flat(20, 140)
        ..flat(8, null)
        ..flat(30, 140)
        ..flat(10, 70);
      expect(s.detect(), hasLength(2));
    });

    test('a bridge that would exceed maxWorkoutMin is refused → TWO', () {
      // 70 + 8 + 50 = 128 min > 120: merged it would be dropped whole.
      final s = _Series()
        ..flat(10, 70)
        ..flat(70, 140)
        ..recover(8, 140, 90)
        ..flat(50, 140)
        ..flat(10, 70);
      expect(s.detect(), hasLength(2));
    });

    test('a short (< 5 min) pause still merges as before', () {
      final s = _Series()
        ..flat(10, 70)
        ..flat(20, 140)
        ..flat(3, 65)
        ..flat(20, 140)
        ..flat(10, 70);
      expect(s.detect(), hasLength(1));
    });
  });
}
