// SLEEP — per-stage minute RANGES (D27 revised, 2026-10-19). RED: new API.
//
// The cardio stager has no per-epoch probabilities, only robust-z scores
// against two fixed cutoffs plus a night confidence from RR coverage. So a
// stage's minutes get a BOUND, not a statistical interval:
//
//   lo[s] = epochs that can only be s: covered, labelled s, and every score
//           that decided the label clear of its cutoff by >= margin;
//   hi[s] = lo[s] + epochs that could still be s:
//           • uncovered epochs (no usable HR in the epoch, or no stage label at
//             all) could be ANY stage;
//           • an asleep epoch whose score is within `margin` of a cutoff counts
//             toward both neighbouring stages (remScore ↔ REM / its NREM
//             substage; deepScore ↔ light / deep).
//   nrem = light ∪ deep (an epoch counts toward nrem.lo when every stage it
//          could be is light or deep).
//
// API chosen here (lib/src/onehz/sleep/stage_ranges.dart, exported through
// `package:openstrap_analytics/onehz.dart`):
//
//   class StageEpochEvidence {
//     const StageEpochEvidence({SleepStage? stage, bool deep = false,
//         bool covered = true, double? remScore, double? deepScore});
//   }
//   class MinuteRange { final double lo, hi; }
//   class StageMinuteRanges {
//     final MinuteRange wake, light, deep, rem, nrem;
//     final double windowMin;
//     Map<String, Map<String, double>> toJson(); // wake/light/deep/rem → {lo,hi}
//   }
//   const double kStageScoreMargin;            // calibrated, > 0
//   StageMinuteRanges? stageMinuteRanges(List<StageEpochEvidence>? epochs,
//       {int epochSec = 30, double remScoreCut = kDefaultRemScoreCut,
//        double deepScoreCut = kDefaultDeepScoreCut,
//        double margin = kStageScoreMargin});
//   extension on CardioStagerResult: List<StageEpochEvidence> get epochEvidence
//     — one entry per base.stages epoch, stage/deep equal to the FINAL labels,
//       covered == the epoch carried at least one valid HR sample.
//
// "Point" minutes below are the stager's own labelled minutes (what the edge
// already shows); the range never moves the point, it brackets it.

import 'dart:math' as math;

import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

const int _t0 = 1700000000;

StageEpochEvidence _w() => const StageEpochEvidence(stage: SleepStage.wake);
StageEpochEvidence _l() => const StageEpochEvidence(
    stage: SleepStage.nrem, remScore: -1.5, deepScore: -1.5);
StageEpochEvidence _d() => const StageEpochEvidence(
    stage: SleepStage.nrem, deep: true, remScore: -1.5, deepScore: 1.5);
StageEpochEvidence _r() => const StageEpochEvidence(
    stage: SleepStage.rem, remScore: 2.0, deepScore: -1.5);
StageEpochEvidence _u() =>
    const StageEpochEvidence(stage: SleepStage.nrem, covered: false);

void _expectRange(MinuteRange r, double lo, double hi, String what) {
  expect(r.lo, closeTo(lo, 1e-9), reason: '$what.lo');
  expect(r.hi, closeTo(hi, 1e-9), reason: '$what.hi');
}

void main() {
  test('the margin is a real, positive number', () {
    expect(kStageScoreMargin, greaterThan(0));
    expect(kStageScoreMargin.isFinite, isTrue);
  });

  group('absent input abstains', () {
    test('null ⇒ null', () => expect(stageMinuteRanges(null), isNull));
    test('empty ⇒ null', () => expect(stageMinuteRanges(const []), isNull));
  });

  test('every epoch covered and clear ⇒ lo == hi == point for every stage', () {
    // 20 wake, 60 light, 30 deep, 40 rem epochs = 10/30/15/20 min.
    final ev = [
      for (var i = 0; i < 20; i++) _w(),
      for (var i = 0; i < 60; i++) _l(),
      for (var i = 0; i < 30; i++) _d(),
      for (var i = 0; i < 40; i++) _r(),
    ];
    final r = stageMinuteRanges(ev, margin: 0.2)!;
    _expectRange(r.wake, 10, 10, 'wake');
    _expectRange(r.light, 30, 30, 'light');
    _expectRange(r.deep, 15, 15, 'deep');
    _expectRange(r.rem, 20, 20, 'rem');
    _expectRange(r.nrem, 45, 45, 'nrem');
    expect(r.windowMin, closeTo(75, 1e-9));
  });

  test('nothing covered ⇒ every stage is [0, window]', () {
    final ev = [for (var i = 0; i < 120; i++) _u()];
    final r = stageMinuteRanges(ev)!;
    for (final (name, range) in [
      ('wake', r.wake),
      ('light', r.light),
      ('deep', r.deep),
      ('rem', r.rem),
      ('nrem', r.nrem),
    ]) {
      _expectRange(range, 0, 60, name);
    }
  });

  test('an epoch with no stage label at all is uncovered, not dropped', () {
    final ev = [
      for (var i = 0; i < 10; i++) _l(),
      for (var i = 0; i < 10; i++) const StageEpochEvidence(),
    ];
    final r = stageMinuteRanges(ev, margin: 0.2)!;
    expect(r.windowMin, closeTo(10, 1e-9));
    _expectRange(r.light, 5, 10, 'light');
    _expectRange(r.wake, 0, 5, 'wake');
    _expectRange(r.rem, 0, 5, 'rem');
  });

  test('uncovered epochs widen every stage by their minutes', () {
    // 40 covered light + 20 uncovered (stager fell through to NREM there).
    final ev = [
      for (var i = 0; i < 40; i++) _l(),
      for (var i = 0; i < 20; i++) _u(),
    ];
    final r = stageMinuteRanges(ev, margin: 0.2)!;
    _expectRange(r.light, 20, 30, 'light');
    _expectRange(r.wake, 0, 10, 'wake');
    _expectRange(r.deep, 0, 10, 'deep');
    _expectRange(r.rem, 0, 10, 'rem');
    _expectRange(r.nrem, 20, 30, 'nrem');
  });

  test('a REM score inside the margin counts toward REM and its NREM neighbour',
      () {
    const cut = kDefaultRemScoreCut;
    final ev = [
      for (var i = 0; i < 10; i++) _l(),
      // labelled REM, but only 0.05 above the cutoff (margin 0.2)
      for (var i = 0; i < 10; i++)
        const StageEpochEvidence(stage: SleepStage.rem, remScore: cut + 0.05),
      // labelled light, 0.05 below the cutoff
      for (var i = 0; i < 10; i++)
        const StageEpochEvidence(stage: SleepStage.nrem, remScore: cut - 0.05),
    ];
    final r = stageMinuteRanges(ev, margin: 0.2)!;
    _expectRange(r.rem, 0, 10, 'rem');
    _expectRange(r.light, 5, 15, 'light');
    _expectRange(r.deep, 0, 0, 'deep');
    _expectRange(r.wake, 0, 0, 'wake');
  });

  test('a deep score inside the margin counts toward light and deep', () {
    const cut = kDefaultDeepScoreCut;
    final ev = [
      for (var i = 0; i < 10; i++)
        const StageEpochEvidence(
            stage: SleepStage.nrem,
            deep: true,
            remScore: -1.5,
            deepScore: cut + 0.05),
      for (var i = 0; i < 10; i++) _d(),
    ];
    final r = stageMinuteRanges(ev, margin: 0.2)!;
    _expectRange(r.deep, 5, 10, 'deep');
    _expectRange(r.light, 0, 5, 'light');
    // An epoch that is light-or-deep is certainly NREM.
    _expectRange(r.nrem, 10, 10, 'nrem');
  });

  test('scores exactly at the margin are clear', () {
    const cut = kDefaultRemScoreCut;
    final ev = [
      for (var i = 0; i < 10; i++)
        const StageEpochEvidence(stage: SleepStage.rem, remScore: cut + 0.25),
    ];
    final r = stageMinuteRanges(ev, margin: 0.25)!;
    _expectRange(r.rem, 5, 5, 'rem');
  });

  test('epochSec scales minutes', () {
    final ev = [for (var i = 0; i < 12; i++) _w()];
    final r = stageMinuteRanges(ev, epochSec: 60)!;
    _expectRange(r.wake, 12, 12, 'wake');
    expect(r.windowMin, closeTo(12, 1e-9));
  });

  test('toJson carries the four display stages as {lo, hi}', () {
    final r = stageMinuteRanges([_w(), _l(), _d(), _r(), _u()], margin: 0.2)!;
    final j = r.toJson();
    expect(j.keys.toSet(), {'wake', 'light', 'deep', 'rem'});
    for (final v in j.values) {
      expect(v.keys.toSet(), {'lo', 'hi'});
      expect(v['lo']!, lessThanOrEqualTo(v['hi']!));
    }
    expect(j['wake'], {'lo': 0.5, 'hi': 1.0});
  });

  group('CardioStagerResult.epochEvidence', () {
    // 3 h still night at a steady 55 bpm with a 30-min off-skin gap in the
    // middle (HR 0), RR absent: the gap's epochs must come out uncovered.
    final n = 3 * 3600;
    final accel = <AccelSample>[
      for (var i = 0; i < n; i++)
        AccelSample((_t0 + i) * 1000.0, 0.0, 0.0, 1.0)
    ];
    final rng = math.Random(7);
    final hr = <double>[
      for (var i = 0; i < n; i++)
        (i >= 3600 && i < 5400) ? 0.0 : 55 + rng.nextDouble() * 4
    ];
    final res = cardioStager(hr, accel);

    test('one entry per staged epoch, labels equal the final stages', () {
      expect(res.base.stages, isNotEmpty);
      final ev = res.epochEvidence;
      expect(ev.length, res.base.stages.length);
      for (var e = 0; e < ev.length; e++) {
        expect(ev[e].stage, res.base.stages[e], reason: 'epoch $e stage');
        expect(ev[e].deep, res.deepFlag[e], reason: 'epoch $e deep');
      }
    });

    test('epochs with no valid HR are uncovered, the rest covered', () {
      final ev = res.epochEvidence;
      for (var e = 0; e < ev.length; e++) {
        final inGap = e * 30 >= 3600 && (e + 1) * 30 <= 5400;
        expect(ev[e].covered, !inGap, reason: 'epoch $e');
      }
    });

    test('the gap widens every stage range by its 30 minutes', () {
      final r = stageMinuteRanges(res.epochEvidence)!;
      expect(r.windowMin, closeTo(res.base.stages.length * 0.5, 1e-9));
      for (final range in [r.wake, r.light, r.deep, r.rem]) {
        expect(range.hi - range.lo, greaterThanOrEqualTo(30 - 1e-9));
      }
    });

    test('an abstaining stager yields no evidence and therefore no range', () {
      final off = cardioStager(List<double>.filled(n, 0.0), accel);
      expect(off.epochEvidence, isEmpty);
      expect(stageMinuteRanges(off.epochEvidence), isNull);
    });
  });
}
