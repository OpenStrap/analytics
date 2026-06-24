// SLEEP & CIRCADIAN family — synthetic known-answer + real-capture plausibility.
//
// No TS oracle exists for the 1 Hz sleep/circadian methods, so every method is
// pinned by a SYNTHETIC KNOWN-ANSWER construction (catalog spec drives the
// expected value), then sanity-checked against the ~9-min real type-24 snippet.
//
// IMPORTANT: ../whoop_hist.jsonl is only ~9 min of 1 Hz records — far too short
// for a real night. So van Hees / SRI / accounting / staging / CPC / circadian
// get SYNTHETIC validation only; on the real capture we only assert the
// pipeline runs and (where applicable) returns honest "absent" rather than a
// fabricated night. That limitation is stated honestly here, not faked.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:test/test.dart';
import 'package:openstrap_analytics/onehz.dart';
import 'package:openstrap_analytics/src/onehz/sleep/sleep.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

void main() {
  // ----------------------------------------------------------------- van Hees
  group('van Hees angle-based sleep window', () {
    test('square-wave activity → finds the inactivity block', () {
      // 12 h "day" with the wrist swinging (z-angle oscillating ±40°), then a
      // 7 h "night" of a perfectly still wrist (constant orientation), then 5 h
      // active again. Sampled @1 Hz. van Hees must return the 7 h still block.
      final accel = <AccelSample>[];
      var t = 0.0;
      const sec = 1000.0;
      // Day 1: active 12h — wrist orientation oscillates each second.
      for (var i = 0; i < 12 * 3600; i++) {
        final phase = math.sin(i * 0.5);
        // tilt the vector so z-angle swings a lot
        accel.add(AccelSample(t, 0.3 * phase, 0.3, 0.9 * (1 - 0.2 * phase)));
        t += sec;
      }
      final nightStart = accel.length;
      // Night: 7h dead still (z down the arm).
      for (var i = 0; i < 7 * 3600; i++) {
        accel.add(AccelSample(t, 0.02, 0.02, 1.0));
        t += sec;
      }
      final nightEnd = accel.length;
      // Day 2: active 5h.
      for (var i = 0; i < 5 * 3600; i++) {
        final phase = math.sin(i * 0.5);
        accel.add(AccelSample(t, 0.3 * phase, 0.3, 0.9 * (1 - 0.2 * phase)));
        t += sec;
      }

      final m = vanHeesSleepWindow(accel);
      expect(m.present, isTrue);
      final w = m.value!;
      // Onset within a few minutes of the true night start, offset near its end.
      expect((w.onsetIdx - nightStart).abs(), lessThan(10 * 60),
          reason: 'onset should land at the start of the still block');
      expect((w.offsetIdx - nightEnd).abs(), lessThan(10 * 60),
          reason: 'offset should land at the end of the still block');
      // Detected SPT ≈ 7 h.
      expect(w.sptSec, greaterThan(6 * 3600));
      expect(w.sptSec, lessThan(8 * 3600));
    });

    test('all-active → no sleep window (honest absent)', () {
      // Large per-second reorientation so the z-angle change always exceeds 5°.
      final rnd = math.Random(7);
      final accel = <AccelSample>[];
      for (var i = 0; i < 3600; i++) {
        // Random unit-ish gravity vector each second (continuous movement).
        final ax = rnd.nextDouble() * 2 - 1;
        final ay = rnd.nextDouble() * 2 - 1;
        final az = rnd.nextDouble() * 2 - 1;
        accel.add(AccelSample(i * 1000.0, ax, ay, az));
      }
      final m = vanHeesSleepWindow(accel);
      expect(m.present, isFalse);
      expect(m.confidence, 0);
    });
  });

  // ---------------------------------------------------------------------- SRI
  group('True Phillips SRI', () {
    test('perfectly-regular 2-day vector → SRI = 100', () {
      // 1-min epochs, 1440/day. Asleep 23:00–07:00 identically both days.
      const epochsPerDay = 1440;
      List<bool> day() => List<bool>.generate(epochsPerDay, (e) {
            // minutes 0..1439; asleep if before 07:00 (0..419) or after 23:00.
            return e < 7 * 60 || e >= 23 * 60;
          });
      final vec = [...day(), ...day()];
      final m = phillipsSri(vec, epochsPerDay);
      expect(m.present, isTrue);
      expect(m.value!.sri, closeTo(100, 1e-6));
    });

    test('shifted second day → SRI < 100', () {
      const epochsPerDay = 1440;
      List<bool> day(int shift) => List<bool>.generate(epochsPerDay, (e) {
            final ee = (e - shift) % epochsPerDay;
            final m = ee < 0 ? ee + epochsPerDay : ee;
            return m < 7 * 60 || m >= 23 * 60;
          });
      // Day 2 shifted by 3 h.
      final vec = [...day(0), ...day(3 * 60)];
      final m = phillipsSri(vec, epochsPerDay);
      expect(m.present, isTrue);
      expect(m.value!.sri, lessThan(100));
      // A 3h shift on an 8h sleep window: 6h of the 24 disagree → SRI=200·(18/24)-100=50.
      expect(m.value!.sri, closeTo(50, 1.0));
    });
  });

  // --------------------------------------------------------------- accounting
  group('sleep accounting', () {
    test('known in-bed window → TST/WASO/efficiency exact', () {
      // 8h in bed (28800 s). Asleep except a 30-min WASO block at hour 3 and a
      // 20-min sleep-latency wake at the very start.
      const total = 8 * 3600;
      final asleep = List<bool>.filled(total, true);
      for (var i = 0; i < 20 * 60; i++) {
        asleep[i] = false; // onset latency
      }
      final wasoStart = 3 * 3600;
      for (var i = wasoStart; i < wasoStart + 30 * 60; i++) {
        asleep[i] = false; // mid-night WASO
      }
      final m = sleepAccounting(asleep);
      expect(m.present, isTrue);
      final a = m.value!;
      expect(a.onsetIdx, 20 * 60);
      expect(a.wasoSec, 30 * 60); // only the mid-night block counts as WASO
      expect(a.tstSec, total - 20 * 60 - 30 * 60);
      // Efficiency = TST / time-in-bed.
      expect(a.efficiencyPct, closeTo(100.0 * a.tstSec / total, 1e-6));
    });
  });

  // ------------------------------------------------------------------- stager
  group('3-class autonomic stager', () {
    test('constructed NREM/REM/wake epochs classify correctly', () {
      // Build 90 min: 30 min deep NREM (low stable HR, immobile), 30 min REM
      // (elevated variable HR, immobile/atonic), 30 min wake (moving).
      final hr = <double>[];
      final immobile = <bool>[];
      final rnd = math.Random(1);
      // NREM: HR ~48 ± 0.5, immobile.
      for (var i = 0; i < 30 * 60; i++) {
        hr.add(48 + (rnd.nextDouble() - 0.5));
        immobile.add(true);
      }
      // REM: HR ~62 ± 6 (variable), immobile (atonia).
      for (var i = 0; i < 30 * 60; i++) {
        hr.add(62 + (rnd.nextDouble() - 0.5) * 12);
        immobile.add(true);
      }
      // Wake: HR ~70, MOVING.
      for (var i = 0; i < 30 * 60; i++) {
        hr.add(70 + (rnd.nextDouble() - 0.5) * 4);
        immobile.add(false);
      }
      final m = autonomicStager(hr, immobile, epochSec: 30);
      expect(m.present, isTrue);
      final s = m.value!;
      // Each phase has 60 epochs of 30s. Check the dominant label per third.
      final third = s.stages.length ~/ 3;
      final nremPart = s.stages.sublist(0, third);
      final remPart = s.stages.sublist(third, 2 * third);
      final wakePart = s.stages.sublist(2 * third);
      expect(_dominant(nremPart), SleepStage.nrem);
      expect(_dominant(remPart), SleepStage.rem);
      expect(_dominant(wakePart), SleepStage.wake);
      // Honesty: tier is ESTIMATE, confidence bounded.
      expect(m.tier, Tier.estimate);
      expect(m.confidence, lessThanOrEqualTo(0.6));
    });
  });

  // ---------------------------------------------------------------------- CPC
  group('Cardiopulmonary Coupling', () {
    test('NN with injected ~0.25 Hz respiration → HF coupling band', () {
      // Synthesize an NN tachogram at mean 1000 ms with a strong RSA at 0.25 Hz
      // (15 breaths/min). Beat-to-beat at ~1 beat/s. The coupling spectrum's
      // dominant frequency should fall in the HFC band (0.1–0.4 Hz).
      final nn = <double>[];
      final times = <double>[];
      var t = 0.0;
      const fResp = 0.25; // Hz
      for (var i = 0; i < 1800; i++) {
        // RR modulated by respiration (RSA): ±40 ms at 0.25 Hz.
        final rr = 1000 + 40 * math.sin(2 * math.pi * fResp * (t / 1000.0));
        t += rr;
        nn.add(rr);
        times.add(t);
      }
      final m = cardiopulmonaryCoupling(nn, times);
      expect(m.present, isTrue);
      final c = m.value!;
      // Dominant coupling frequency near the injected respiration.
      expect(c.dominantHz, closeTo(fResp, 0.05),
          reason: 'coupling peak should sit at the respiratory frequency');
      // HFC should dominate (stable-NREM-like) vs LFC.
      expect(c.hfc, greaterThan(c.lfc));
    });
  });

  // ----------------------------------------------------------- circadian (NP)
  group('nonparametric circadian IS/IV/RA/L5/M10', () {
    test('clean 24-h cosine activity over 7 days → IS≈1, RA high', () {
      // 24 hourly epochs/day, 7 days, activity = 1+cos peaking at hour 14.
      const eph = 24;
      final x = <double>[];
      for (var d = 0; d < 7; d++) {
        for (var h = 0; h < eph; h++) {
          final a =
              1 + math.cos(2 * math.pi * (h - 14) / 24); // 0..2, peak @14
          x.add(a);
        }
      }
      final m = circadianNonparametric(x, eph);
      expect(m.present, isTrue);
      final c = m.value!;
      // Identical every day with no noise → IS ≈ 1.
      expect(c.interdailyStability, closeTo(1.0, 1e-6));
      // Smooth cosine → low IV.
      expect(c.intradailyVariability, lessThan(0.1));
      // M10 centered near the peak (hour 14): the 10h window starting ~hour 9.
      expect(c.m10, greaterThan(c.l5));
      expect(c.relativeAmplitude, greaterThan(0.3));
    });

    test('flat activity → honest absent (no rhythm)', () {
      final x = List<double>.filled(24 * 3, 5.0);
      final m = circadianNonparametric(x, 24);
      expect(m.present, isFalse);
    });
  });

  // ---------------------------------------------------- REAL-CAPTURE plausibility
  group('real capture plausibility (~9 min, short)', () {
    final histFile = File('../whoop_hist.jsonl');

    test('pipeline runs on whoop_hist.jsonl; honest about short window', () {
      if (!histFile.existsSync()) {
        markTestSkipped('whoop_hist.jsonl not found beside the repo');
        return;
      }
      final lines = histFile
          .readAsLinesSync()
          .where((l) => l.trim().isNotEmpty)
          .toList();
      final accel = <AccelSample>[];
      final hr = <double>[];
      final immobileFromRest = <bool>[];
      final rrMs = <double>[];
      var t = 0.0;
      for (final line in lines) {
        final obj = jsonDecode(line) as Map<String, dynamic>;
        if (obj['t'] != 24) continue;
        final r = parseR24(hexToBytes(obj['hex'] as String));
        if (r == null) continue;
        final a = r.accelG;
        if (a.length == 3) {
          accel.add(AccelSample(t, a[0], a[1], a[2]));
        }
        hr.add(r.hr.toDouble());
        for (final rr in r.rrIntervalsMs) {
          if (rr > 0) rrMs.add(rr.toDouble());
        }
        t += 1000.0;
      }
      expect(accel.length, greaterThan(100));

      // van Hees: ~9 min snippet is BELOW the 5-min×(usable block) needs; assert
      // it either honestly returns absent OR a short block — never crashes.
      final sw = vanHeesSleepWindow(accel);
      // No physiological night here; just assert the call is well-formed.
      expect(sw.tier, Tier.high);
      if (sw.present) {
        expect(sw.value!.sptSec, greaterThan(0));
      } else {
        expect(sw.confidence, 0);
      }

      // CPC on real RR via the foundation corrector: should run and produce a
      // dominant frequency in the physiological respiratory range (or absent).
      final corr = correctRr(rrMs);
      if (corr.nn.length >= 60) {
        final cpc = cardiopulmonaryCoupling(corr.nn, corr.nnTimesMs);
        if (cpc.present) {
          expect(cpc.value!.dominantHz, inInclusiveRange(0.0, 0.45));
          expect(cpc.value!.hfc, greaterThanOrEqualTo(0));
        }
      }

      // Stager on the real HR + a built immobility mask (all immobile here as a
      // smoke test): must run and return an ESTIMATE-tier result or absent.
      for (var i = 0; i < hr.length; i++) {
        immobileFromRest.add(true);
      }
      final st = autonomicStager(hr, immobileFromRest, epochSec: 30);
      expect(st.tier, Tier.estimate);
    });
  });
}

SleepStage _dominant(List<SleepStage> xs) {
  final counts = <SleepStage, int>{};
  for (final s in xs) {
    counts[s] = (counts[s] ?? 0) + 1;
  }
  var best = SleepStage.wake;
  var bestN = -1;
  counts.forEach((k, v) {
    if (v > bestN) {
      bestN = v;
      best = k;
    }
  });
  return best;
}
