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

  group('AdvancedSleepStager V1 detection + 4-class staging', () {
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

  group('SleepStagerV2 (opt-in)', () {
    test('V2 path runs over the same detection, emits only the 4 labels', () {
      final d = build(2, 7, 1);
      final v2 = AdvancedSleepStager.detectSleep(d.grav, d.hr, rr: d.rr, useV2: true);
      expect(v2, isNotEmpty);
      const allowed = {'wake', 'light', 'deep', 'rem'};
      for (final s in v2.first.stages) {
        expect(allowed.contains(s.stage), isTrue);
      }
      // mainSleep selects V2 too and reports it in the note.
      final m = AdvancedSleepStager.mainSleep(d.grav, d.hr, rr: d.rr, useV2: true);
      expect(m.present, isTrue);
      expect(m.note, contains('V2'));
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
