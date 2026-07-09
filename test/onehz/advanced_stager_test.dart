// AdvancedSleepStager (V1) + SleepStagerV2 — synthetic known-answer tests.
//
// No PSG oracle exists; these pin the algorithm constants/structure:
// a synthetic still+low-HR night must be detected and staged into the 4-class
// {wake,light,deep,rem} label set; the V2 path must run over the same detection
// and produce only the 4 labels.

import 'dart:math' as math;
import 'package:test/test.dart';
import 'package:openstrap_analytics/onehz.dart';

void main() {
  // Build a synthetic capture at 1 Hz: [dayH] active day, [nightH] still night
  // with low sleeping HR + physiological RR, then [tailH] active.
  ({List<GravTs> grav, List<HrTs> hr, List<RrTs> rr, int nightStart, int nightEnd})
      build(int dayH, int nightH, int tailH) {
    final grav = <GravTs>[];
    final hr = <HrTs>[];
    final rr = <RrTs>[];
    var t = 0;
    void active(int secs) {
      for (var i = 0; i < secs; i++) {
        final phase = math.sin(i * 0.5);
        grav.add(GravTs(t, 0.3 * phase, 0.3, 0.9 * (1 - 0.2 * phase)));
        hr.add(HrTs(t, 72 + 2 * math.sin(i / 600.0)));
        t++;
      }
    }

    active(dayH * 3600);
    final nightStart = t;
    for (var i = 0; i < nightH * 3600; i++) {
      // dead-still wrist (tiny jitter below the 0.01 g still threshold).
      grav.add(GravTs(t, 0.001 * math.sin(i * 0.01), 0.001, 1.0));
      hr.add(HrTs(t, 50 + 1.5 * math.sin(i / 1800.0)));
      // one RR beat per second around the HR, with physiological wobble (HRV).
      final rrMs = 60000.0 / (50 + 1.5 * math.sin(i / 1800.0)) +
          (i.isEven ? 20.0 : -20.0);
      rr.add(RrTs(t, rrMs));
      t++;
    }
    final nightEnd = t;
    active(tailH * 3600);
    return (grav: grav, hr: hr, rr: rr, nightStart: nightStart, nightEnd: nightEnd);
  }

  group('AdvancedSleepStager detection + 4-class staging (default: cardio)', () {
    test('still low-HR night → one session with a 4-class hypnogram', () {
      final d = build(2, 7, 1);
      final sessions = AdvancedSleepStager.detectSleep(d.grav, d.hr, rr: d.rr);
      expect(sessions, isNotEmpty);
      final main = sessions.reduce((a, b) =>
          AdvancedSleepStager.hypnogramMetrics(a).tstS >=
                  AdvancedSleepStager.hypnogramMetrics(b).tstS
              ? a
              : b);
      // The session spans ~7h (within the still block).
      expect(main.end - main.start, greaterThan(6 * 3600));
      expect(main.end - main.start, lessThanOrEqualTo(8 * 3600));
      // Only the 4 allowed labels ever appear.
      const allowed = {'wake', 'light', 'deep', 'rem'};
      for (final s in main.stages) {
        expect(allowed.contains(s.stage), isTrue, reason: 'bad label ${s.stage}');
      }
      // Mostly asleep → high efficiency.
      expect(main.efficiency, greaterThan(0.85));
      // AASM metrics are self-consistent.
      final m = AdvancedSleepStager.hypnogramMetrics(main);
      expect(m.tstS, greaterThan(0));
      expect(m.tstS, lessThanOrEqualTo(m.tibS));
      expect(m.deepMin + m.remMin + m.lightMin, closeTo(m.tstS / 60, 1e-6));
    });

    test('all-active capture → no qualifying sleep (honest absent)', () {
      final rnd = math.Random(7);
      final grav = <GravTs>[];
      final hr = <HrTs>[];
      for (var i = 0; i < 4 * 3600; i++) {
        grav.add(GravTs(i, rnd.nextDouble() * 2 - 1, rnd.nextDouble() * 2 - 1,
            rnd.nextDouble() * 2 - 1));
        hr.add(HrTs(i, 75 + rnd.nextDouble() * 10));
      }
      final m = AdvancedSleepStager.mainSleep(grav, hr);
      expect(m.present, isFalse);
      expect(m.confidence, 0);
    });

    test('too-short still block (<60 min) is rejected', () {
      final d = build(1, 1, 1); // 1h night — below the strict >60min gate
      final sessions = AdvancedSleepStager.detectSleep(d.grav, d.hr, rr: d.rr);
      expect(sessions, isEmpty);
    });

    test('16h cap (#547) drops an over-long still span entirely', () {
      final d = build(1, 17, 1); // 17h still > 16h cap
      final sessions = AdvancedSleepStager.detectSleep(d.grav, d.hr, rr: d.rr);
      // The single 17h run exceeds maxMainSleepSpanS and is dropped (not truncated).
      expect(sessions, isEmpty);
    });
  });

  group('Realistic cycled fixture — deep/REM regression (2026-07)', () {
    // Realistic-ish overnight fixture, unlike `build()` above: cycles through
    // light -> deep -> light -> REM phases (mimicking ~110-min sleep cycles),
    // with per-phase HR/breathing signatures instead of one clean tone, PLUS
    // real-world PPG noise (dropped beats, occasional outlier RR values) that
    // `build()`'s one-beat-per-second, always-clean stream does not exercise.
    // Before the fix, `winResp` (raw resp-ADC channel) was ALWAYS empty in
    // production (no such channel exists on WHOOP 4 R24), so `rrv` was always
    // NaN, the primary rrv-gated REM rule could never fire, and the narrow
    // fallback (hrHigh && hrvarHigh simultaneously) rarely fired either — this
    // fixture's REM phases are deliberately built so ONLY the (now-fixed)
    // primary rrv-gated rule can classify them: HR is elevated via `hrVar`
    // (moderate wobble) but deliberately kept BELOW the `hrHigh` (70th
    // percentile) threshold, so the old narrow fallback would still miss them.
    ({List<GravTs> grav, List<HrTs> hr, List<RrTs> rr}) buildCycled() {
      final rnd = math.Random(42);
      final grav = <GravTs>[];
      final hr = <HrTs>[];
      final rr = <RrTs>[];
      var t = 0;
      var rrClockMs = 0.0;

      void emitSecond(double bpm) {
        // Still wrist with tiny jitter (below the 0.01 g still threshold).
        grav.add(GravTs(t, 0.001 * math.sin(t * 0.01), 0.001, 1.0));
        hr.add(HrTs(t, bpm));
        t++;
      }

      // Emit RR beats for [secs] seconds at ~[bpm], RSA-modulated at
      // [breathPeriodFn](beat-index)-seconds-per-breath (allows a varying —
      // irregular — period for REM), with ~8% dropped beats (weak PPG
      // contact) and an occasional single-beat outlier (ectopic-like noise).
      void emitPhase(int secs, double bpm,
          double Function(int beatIdx) breathPeriodFn) {
        final endT = t + secs;
        var beatIdx = 0;
        while (t < endT) {
          emitSecond(bpm);
          final baseRr = 60000.0 / bpm;
          final period = breathPeriodFn(beatIdx);
          final rsa = 25.0 * math.sin(2 * math.pi * (rrClockMs / 1000.0) / period);
          var rrMs = baseRr + rsa;
          rrClockMs += rrMs;
          beatIdx++;
          if (rnd.nextDouble() < 0.08) continue; // dropped beat (weak contact)
          if (rnd.nextDouble() < 0.02) {
            rrMs *= rnd.nextBool() ? 1.8 : 0.55; // isolated ectopic-like outlier
          }
          rr.add(RrTs(t, rrMs));
        }
      }

      // ~1h wind-down (light-ish, regular breathing) before the first cycle.
      emitPhase(3600, 58, (_) => 4.2);
      for (var cycle = 0; cycle < 4; cycle++) {
        emitPhase(25 * 60, 56, (_) => 4.2); // light: regular ~14 br/min
        emitPhase(20 * 60, 49, (_) => 4.8); // deep: low HR, very regular breathing
        emitPhase(15 * 60, 56, (_) => 4.2); // light
        // REM: HR only mildly elevated (kept below the top-30th-pct hrHigh
        // gate by construction — see the phase check below), irregular
        // breathing period (3-7 s, jittered every breath) => high rrv.
        emitPhase(20 * 60, 59, (i) => 3.0 + 4.0 * rnd.nextDouble());
        emitPhase(20 * 60, 56, (_) => 4.2); // light
      }
      return (grav: grav, hr: hr, rr: rr);
    }

    void assertRealDeepAndRem(StagingMethod method) {
      final d = buildCycled();
      final sessions =
          AdvancedSleepStager.detectSleep(d.grav, d.hr, rr: d.rr, method: method);
      expect(sessions, isNotEmpty,
          reason: 'the still+low-HR fixture should still register as sleep');
      final main = sessions.reduce((a, b) =>
          AdvancedSleepStager.hypnogramMetrics(a).tstS >=
                  AdvancedSleepStager.hypnogramMetrics(b).tstS
              ? a
              : b);
      final m = AdvancedSleepStager.hypnogramMetrics(main);

      // The regression this test guards against: pre-fix, V1's `rrv` was
      // always NaN in production, so deepMin/remMin could silently be ~0
      // while lightMin absorbed nearly the whole night. Assert both are real
      // — for whichever staging method is actually running in production.
      expect(m.deepMin, greaterThan(0),
          reason: 'deep sleep should be detected from low-HR, regular-'
              'breathing phases');
      expect(m.remMin, greaterThan(0),
          reason: 'REM should be detected — this fixture\'s REM phases are '
              'deliberately built with only a mild/irregular signature, not '
              'an extreme one, so a collapsed-to-light classifier misses it');

      // Directional plausibility (not tight AASM norms — this is a synthetic
      // fixture, not PSG-validated data): light should NOT be devouring
      // nearly the whole night the way the pre-fix bug produced.
      final totalStageMin = m.deepMin + m.remMin + m.lightMin;
      // *Pct fields are 0-100, not fractions.
      expect(m.lightPct, lessThan(85),
          reason: 'light should not be a near-total catch-all');
      expect(m.deepMin + m.remMin, greaterThan(totalStageMin * 0.10),
          reason: 'deep+REM should be a real, non-trivial share of sleep');
    }

    test(
        'V1 (method: StagingMethod.v1) — deep AND rem are both actually '
        'detected (not collapsed to light) — the rrv/REM fix this group is '
        'named for', () {
      // Before the fix, `winResp` (raw resp-ADC channel) was ALWAYS empty in
      // production (no such channel exists on WHOOP 4 R24), so `rrv` was
      // always NaN, the primary rrv-gated REM rule could never fire, and the
      // narrow fallback (hrHigh && hrvarHigh simultaneously) rarely fired
      // either — this fixture's REM phases are deliberately built so ONLY
      // the (now-fixed) primary rrv-gated rule can classify them: HR is
      // elevated via `hrVar` (moderate wobble) but deliberately kept BELOW
      // the `hrHigh` (70th percentile) threshold, so the old narrow fallback
      // would still miss them.
      assertRealDeepAndRem(StagingMethod.v1);
    });

    test(
        'cardio (method: StagingMethod.cardio, the PRODUCTION default) — '
        'also detects real deep and rem on the same fixture', () {
      assertRealDeepAndRem(StagingMethod.cardio);
    });
  });

  // V1 and V2 are both retired from the production default (see
  // advanced_stager.dart's file header + the 2026-07 cardio/V1/V2
  // comparison) but kept reachable via StagingMethod for regression
  // coverage — these groups just pin that they still run without error.
  group('SleepStagerV1 (regression coverage only, not the default)', () {
    test('V1 path runs over the same detection, emits only the 4 labels', () {
      final d = build(2, 7, 1);
      final v1 = AdvancedSleepStager.detectSleep(d.grav, d.hr,
          rr: d.rr, method: StagingMethod.v1);
      expect(v1, isNotEmpty);
      const allowed = {'wake', 'light', 'deep', 'rem'};
      for (final s in v1.first.stages) {
        expect(allowed.contains(s.stage), isTrue);
      }
      final m = AdvancedSleepStager.mainSleep(d.grav, d.hr,
          rr: d.rr, method: StagingMethod.v1);
      expect(m.present, isTrue);
      expect(m.note, contains('v1'));
    });
  });

  group('SleepStagerV2 (regression coverage only, not the default)', () {
    test('V2 path runs over the same detection, emits only the 4 labels', () {
      final d = build(2, 7, 1);
      final v2 = AdvancedSleepStager.detectSleep(d.grav, d.hr,
          rr: d.rr, method: StagingMethod.v2);
      expect(v2, isNotEmpty);
      const allowed = {'wake', 'light', 'deep', 'rem'};
      for (final s in v2.first.stages) {
        expect(allowed.contains(s.stage), isTrue);
      }
      // mainSleep selects V2 too and reports it in the note.
      final m = AdvancedSleepStager.mainSleep(d.grav, d.hr,
          rr: d.rr, method: StagingMethod.v2);
      expect(m.present, isTrue);
      expect(m.note, contains('v2'));
    });
  });

  group('StagingMethod.cardio (the production default)', () {
    test('cardio path runs over the same detection, emits only the 4 labels',
        () {
      final d = build(2, 7, 1);
      final sessions = AdvancedSleepStager.detectSleep(d.grav, d.hr, rr: d.rr);
      expect(sessions, isNotEmpty);
      const allowed = {'wake', 'light', 'deep', 'rem'};
      for (final s in sessions.first.stages) {
        expect(allowed.contains(s.stage), isTrue);
      }
      final m = AdvancedSleepStager.mainSleep(d.grav, d.hr, rr: d.rr);
      expect(m.present, isTrue);
      expect(m.note, contains('cardio'));
    });
  });

  group('AASM hypnogram metrics (hand-checked)', () {
    test('TIB/TST/SOL/WASO/REM-latency from a crafted hypnogram', () {
      // 1000-s session: 0-100 wake (latency), 100-400 light, 400-600 deep,
      // 600-800 rem, 800-850 wake (WASO), 850-1000 light.
      final session = SleepSession(
        start: 0,
        end: 1000,
        efficiency: 0,
        restingHr: null,
        avgHrv: null,
        stages: const [
          StageSegment(0, 100, 'wake'),
          StageSegment(100, 400, 'light'),
          StageSegment(400, 600, 'deep'),
          StageSegment(600, 800, 'rem'),
          StageSegment(800, 850, 'wake'),
          StageSegment(850, 1000, 'light'),
        ],
      );
      final m = AdvancedSleepStager.hypnogramMetrics(session);
      expect(m.tibS, 1000);
      // TST = sleep seconds = 300+200+200+150 = 850.
      expect(m.tstS, 850);
      // onset = 100, sptEnd = 1000, SOL = 100.
      expect(m.solS, 100);
      expect(m.sptS, 900);
      // WASO = the 800-850 wake (50 s) inside [onset, sptEnd]. 0-100 is pre-onset.
      expect(m.wasoS, 50);
      expect(m.disturbances, 1);
      // REM latency = first REM start (600) − onset (100) = 500.
      expect(m.remLatencyS, 500.0);
      expect(m.deepMin, closeTo(200 / 60, 1e-9));
      expect(m.remMin, closeTo(200 / 60, 1e-9));
      expect(m.efficiency, closeTo(850 / 1000, 1e-9));
    });
  });
}
