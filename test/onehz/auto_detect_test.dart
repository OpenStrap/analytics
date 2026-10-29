// AutoWorkoutDetector — synthetic known-answer tests.
//
// RHR 55 / HRmax 190 throughout, so the gate is
// max(55 + 40, round(55 + 0.45·135)) = 116 bpm.
import 'package:test/test.dart';
import 'package:openstrap_analytics/src/onehz/workout/auto_detect.dart';
import 'package:openstrap_analytics/src/onehz/workout/sport.dart';

const _rhr = 55;
const _max = 190;

class _Hr {
  final ts = <int>[];
  final bpm = <int>[];

  /// Constant [v] for seconds [from, to).
  void flat(int from, int to, int v) {
    for (var t = from; t < to; t++) {
      ts.add(t);
      bpm.add(v);
    }
  }

  /// Linear ramp [a] → [b] over seconds [from, to).
  void ramp(int from, int to, int a, int b) {
    final n = to - from;
    for (var t = from; t < to; t++) {
      ts.add(t);
      bpm.add((a + (b - a) * (t - from) / n).round());
    }
  }
}

List<MotionPoint> _motion(int from, int to, double v,
        {int? holeFrom, int? holeTo}) =>
    [
      for (var t = from; t < to; t++)
        if (holeFrom == null || t < holeFrom || t >= holeTo!)
          MotionPoint(t, v),
    ];

List<DetectedWorkout> _detect(_Hr hr,
        {List<MotionPoint>? motion, SportClassifier? classify}) =>
    AutoWorkoutDetector.detect(
      hrTs: hr.ts,
      hrBpm: hr.bpm,
      restingBpm: _rhr,
      maxBpm: _max,
      motion: motion,
      classify: classify ?? defaultSportClassifier,
    );

/// 3 h day: rest, a gradual 20-min warm-up 70→150, 30 min at 150, rest.
/// The warm-up is slow enough that the onset bypass cannot fire.
_Hr _gradualBout() => _Hr()
  ..flat(0, 3600, 70)
  ..ramp(3600, 4800, 70, 150)
  ..flat(4800, 6600, 150)
  ..flat(6600, 10800, 70);

/// 3 h day: rest, a sharp step to 150 for 30 min, rest.
_Hr _sharpBout() => _Hr()
  ..flat(0, 3600, 70)
  ..flat(3600, 5400, 150)
  ..flat(5400, 10800, 70);

void main() {
  group('motion series with no sample inside the window', () {
    test('is judged on HR alone, like a null motion series', () {
      final hr = _gradualBout();
      final hrOnly = _detect(hr);
      expect(hrOnly, hasLength(1));

      // Motion present for the rest of the day, absent across the bout.
      final motion = _motion(0, 10800, 0.3, holeFrom: 3600, holeTo: 6600);
      final withHole = _detect(hr, motion: motion);
      expect(withHole, hasLength(1));
      expect(withHole.single.startSec, hrOnly.single.startSec);
      expect(withHole.single.endSec, hrOnly.single.endSec);
    });

    test('hands the classifier no motion features', () {
      final seen = <MotionFeatures?>[];
      final out = _detect(
        _sharpBout(),
        motion: _motion(0, 10800, 0.3, holeFrom: 3000, holeTo: 6000),
        classify: (bout, feats) {
          seen.add(feats);
          return 'x';
        },
      );
      expect(out, hasLength(1));
      expect(seen, [isNull]);
    });

    test('a measured still wrist still fails the gate without an onset', () {
      final out = _detect(_gradualBout(), motion: _motion(0, 10800, 0.01));
      expect(out, isEmpty);
    });

    test('measured motion above the gate confirms and reaches the classifier',
        () {
      final seen = <MotionFeatures?>[];
      final out = _detect(
        _gradualBout(),
        motion: _motion(0, 10800, 0.3),
        classify: (bout, feats) {
          seen.add(feats);
          return 'x';
        },
      );
      expect(out, hasLength(1));
      expect(seen.single!.meanIntensity, closeTo(0.3, 1e-9));
    });
  });

  group('onset bypass', () {
    test('a sharp HR onset survives a low-motion window', () {
      final seen = <MotionFeatures?>[];
      final out = _detect(
        _sharpBout(),
        motion: _motion(0, 10800, 0.01),
        classify: (bout, feats) {
          seen.add(feats);
          return 'x';
        },
      );
      expect(out, hasLength(1));
      expect(out.single.avgBpm, 150);
      expect(seen.single!.meanIntensity, closeTo(0.01, 1e-9));
    });

    test('abstains when there is no pre-window to measure the onset against',
        () {
      // Recording starts mid-elevation: nothing before the span.
      final hr = _Hr()
        ..flat(0, 1800, 150)
        ..flat(1800, 5400, 70);
      expect(_detect(hr), hasLength(1));
      expect(_detect(hr, motion: _motion(0, 5400, 0.01)), isEmpty);
    });
  });

  group('maxGapS', () {
    test('a hole in the record longer than maxGapS splits the span', () {
      // Two 15-min efforts with 40 min of no samples between them.
      final hr = _Hr()
        ..flat(0, 1800, 70)
        ..flat(1800, 2700, 150)
        ..flat(5100, 6000, 150)
        ..flat(6000, 9000, 70);
      final out = _detect(hr);
      expect(out, hasLength(2));
      expect(out[0].endSec, 2699);
      expect(out[1].startSec, 5100);
    });

    test('a hole no longer than maxGapS is bridged', () {
      final hr = _Hr()
        ..flat(0, 1800, 70)
        ..flat(1800, 2700, 150)
        ..flat(2760, 3600, 150)
        ..flat(3600, 6000, 70);
      final out = _detect(hr);
      expect(out, hasLength(1));
      expect(out.single.startSec, 1800);
      expect(out.single.endSec, 3599);
    });
  });

  group('merge', () {
    test('spans less than mergeGapS apart merge into one bout', () {
      // 3 min of present, resting HR between two 15-min efforts.
      final hr = _Hr()
        ..flat(0, 1800, 70)
        ..flat(1800, 2700, 150)
        ..flat(2700, 2880, 70)
        ..flat(2880, 3780, 150)
        ..flat(3780, 7000, 70);
      final out = _detect(hr);
      expect(out, hasLength(1));
      expect(out.single.startSec, 1800);
      expect(out.single.endSec, 3779);
    });

    test('spans at least mergeGapS apart stay separate', () {
      final hr = _Hr()
        ..flat(0, 1800, 70)
        ..flat(1800, 2700, 150)
        ..flat(2700, 3300, 70)
        ..flat(3300, 4200, 150)
        ..flat(4200, 7000, 70);
      expect(_detect(hr), hasLength(2));
    });
  });

  group('HRmax', () {
    test('absent ceiling abstains instead of assuming 190', () {
      final hr = _sharpBout();
      expect(_detect(hr), hasLength(1));
      expect(
        AutoWorkoutDetector.detect(
            hrTs: hr.ts, hrBpm: hr.bpm, restingBpm: _rhr, maxBpm: null),
        isEmpty,
      );
      final m = autoDetectWorkouts(
          hrTs: hr.ts, hrBpm: hr.bpm, restingBpm: _rhr, maxBpm: null);
      expect(m.value, isNull);
      expect(m.note, 'need_input:hr_max');
    });

    test("the gate follows the caller's ceiling", () {
      // RHR 62, HRmax 165: gate = max(102, round(62 + 0.45·103)) = 108, so a
      // 25-min bout at 115 is a suggestion. A 190 ceiling would put the gate
      // at 120 and drop it.
      final hr = _Hr()
        ..flat(0, 3600, 70)
        ..flat(3600, 5100, 115)
        ..flat(5100, 9000, 70);
      final out = AutoWorkoutDetector.detect(
          hrTs: hr.ts, hrBpm: hr.bpm, restingBpm: 62, maxBpm: 165);
      expect(out, hasLength(1));
      expect(
        AutoWorkoutDetector.detect(
            hrTs: hr.ts, hrBpm: hr.bpm, restingBpm: 62, maxBpm: 190),
        isEmpty,
      );
    });
  });
}
