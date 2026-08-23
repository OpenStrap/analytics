// SLEEP — cadence independence (group C, phase 3).
//
// Every window in the sleep family was written in ARRAY POSITIONS, which is
// only seconds at 1 Hz. These are the smallest checks that fail if any of them
// slips back to counting positions — plus the one that is not an accuracy check
// at all: `cardioStager` used to publish `wakePct = 0.0` for a night it could
// not read, and that is a confident wrong number about someone's sleep, not a
// tolerance.
//
// Own file on purpose (concurrent agents), and every case is synthetic and
// deterministic — no fixture, no database.

import 'dart:math' as math;

import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

/// A perfectly static wrist, sampled every [cadence] s over [spanSec].
List<AccelSample> _stillAccel(int cadence, int spanSec) => [
      for (var t = 0; t < spanSec; t += cadence)
        AccelSample(t * 1000.0, 0, 0, 1.0)
    ];

List<double> _flatHr(int cadence, int spanSec, [double bpm = 55]) =>
    [for (var t = 0; t < spanSec; t += cadence) bpm];

/// A wrist rotating at a constant 0.004 rad/s — chosen so |Δg| between
/// SUCCESSIVE SAMPLES is ~0.004 g at 1 Hz and ~0.020 g at 5 s. The same
/// physical motion therefore sits below the 0.01 threshold at 1 Hz and above it
/// at 5 s, which is exactly the trap a bare-`g` threshold falls into.
List<GravTs> _driftGrav(int cadence, int spanSec) => [
      for (var t = 0; t < spanSec; t += cadence)
        GravTs(t, math.sin(0.004 * t), 0, math.cos(0.004 * t))
    ];

List<GravTs> _stillGrav(int cadence, int spanSec) =>
    [for (var t = 0; t < spanSec; t += cadence) GravTs(t, 0, 0, 1.0)];

List<HrTs> _hrTs(int cadence, int spanSec, [double bpm = 52]) =>
    [for (var t = 0; t < spanSec; t += cadence) HrTs(t, bpm)];

void main() {
  const night = 8 * 3600;

  group('cardioStager — real-time epochs, and abstention over zero', () {
    test('a cadence coarser than one epoch ABSTAINS, it does not report 0% wake',
        () {
      // 300 s over 8 h = 96 samples. `n ~/ epochSec` made that 3 "epochs" of
      // 2.5 REAL HOURS, which the 30-s rules labelled NREM end to end and
      // published as wakePct 0.000 — a night with no readable evidence in it,
      // reported as zero wake at up to 0.6 confidence.
      final r = cardioStager(_flatHr(300, night), _stillAccel(300, night));
      expect(r.base.stages, isEmpty, reason: 'no epochs ⇒ nothing staged');
      expect(r.confidence, 0);
      // And the caller's own absence test (the rig's, and
      // `_stageSessionCardio`'s) sees it.
      expect(r.base.wakePct, 0, reason: 'meaningless without stages — the '
          'empty `stages` list is the abstention signal, not this number');
    });

    test('the epoch grid is real seconds, not array positions', () {
      const span = 3 * 3600;
      final at1 = cardioStager(_flatHr(1, span), _stillAccel(1, span));
      final at5 = cardioStager(_flatHr(5, span), _stillAccel(5, span));
      expect(at1.base.stages.length, 360, reason: '3 h of 30 s epochs');
      // Pre-fix this was 2160 ~/ 30 = 72 epochs, i.e. a fifth of the night.
      expect(at5.base.stages.length, at1.base.stages.length);
      expect(at5.base.epochSec, 30);
    });

    test('1 Hz is untouched', () {
      const span = 2 * 3600;
      final r = cardioStager(_flatHr(1, span), _stillAccel(1, span));
      expect(r.base.stages.length, span ~/ 30);
    });
  });

  group('vanHeesSleepWindow — sptSec is SECONDS', () {
    test('a 5 s stream reports the same rest period as the same night at 1 Hz',
        () {
      const span = 3 * 3600;
      final a = vanHeesSleepWindow(_stillAccel(1, span));
      final b = vanHeesSleepWindow(_stillAccel(5, span));
      expect(a.present, isTrue);
      expect(b.present, isTrue);
      // Pre-fix the 5 s answer was a SAMPLE COUNT published as seconds: 2100
      // against 10500, an 80% undercount at tier HIGH.
      // Within ONE SAMPLE: the 5 s block boundary can only land on the 5 s
      // grid. That is quantisation, and it is the whole remaining error.
      expect(b.value!.sptSec, closeTo(a.value!.sptSec, 5));
      expect(a.value!.sptSec, greaterThan(2 * 3600));
    });

    test('coarser than the published van Hees epoch ⇒ absent, with a reason',
        () {
      final m = vanHeesSleepWindow(_stillAccel(15, 3 * 3600));
      expect(m.present, isFalse);
      expect(m.note, contains('cadence'));
    });

    test('the undecidable tail is reported in seconds too', () {
      const span = 3 * 3600;
      final a = vanHeesSleepWindow(_stillAccel(1, span)).value!;
      final b = vanHeesSleepWindow(_stillAccel(5, span)).value!;
      expect(b.undecidableSec, closeTo(a.undecidableSec, 5));
    });
  });

  group('AdvancedSleepStager — gravity thresholds are g/s', () {
    test('the same physical drift is staged the same at 1 Hz and 5 s', () {
      final one = AdvancedSleepStager.detectSleep(
          _driftGrav(1, night), _hrTs(1, night));
      final five = AdvancedSleepStager.detectSleep(
          _driftGrav(5, night), _hrTs(5, night));
      expect(one, isNotEmpty);
      // Pre-fix: EMPTY. 0.020 g per 5 s sample cleared a threshold that meant
      // "0.01 g between whatever two samples this device happened to send", so
      // an identically-still wrist read as moving purely for sampling faster.
      expect(five, isNotEmpty);
      final spanOne = one.first.end - one.first.start;
      final spanFive = five.first.end - five.first.start;
      expect((spanFive - spanOne).abs(), lessThan(spanOne * 0.05));
    });

    test('past the ceiling the rate threshold is vacuous, so it abstains', () {
      // |Δg| between two unit gravity vectors can never exceed 2, and the g/s
      // cut passes 2 at ~200 s — every sample would read still, unconditionally.
      // A perfectly static stream is the case that WOULD be detected on the
      // arithmetic alone, so it is the one that proves the ceiling.
      expect(AdvancedSleepStager.maxStillCadenceSec, 30.0);
      expect(AdvancedSleepStager.detectSleep(_stillGrav(60, night),
          _hrTs(60, night)), isEmpty);
      expect(AdvancedSleepStager.detectSleep(_stillGrav(300, night),
          _hrTs(300, night)), isEmpty);
      // …and at the ceiling it still works.
      expect(AdvancedSleepStager.detectSleep(_stillGrav(30, night),
          _hrTs(30, night)), isNotEmpty);
    });
  });
}
