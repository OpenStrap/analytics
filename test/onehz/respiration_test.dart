// RESPIRATION & SpO₂ family tests.
//
// (1) Synthetic KNOWN-ANSWER: this family is NET-NEW with no TS oracle, so we
//     drive each method with a signal whose answer we constructed and assert it
//     recovers it.
// (2) PLAUSIBILITY on the real ../whoop_hist.jsonl capture (HR/RR + green/red/
//     IR ADC via parseR24): outputs are physiologically sane and nothing
//     crashes. The capture is a short (~9 min) snippet, so apnea/ODI are
//     synthetic-validated; on real data we only assert sanity + no-crash.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:test/test.dart';
import 'package:openstrap_analytics/onehz.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

// ---------------------------------------------------------------------------
// Synthetic signal builders.
// ---------------------------------------------------------------------------

/// Build an RR (NN) series whose RR is sinusoidally modulated at [modHz]
/// (respiratory sinus arrhythmia). Mean HR [hrBpm], modulation depth [ampMs].
/// Returns (rrMs, beatTimesMs). RR sampled at the beats themselves (the times
/// are the cumulative NN, exactly how the band reports beat-to-beat RR).
({List<double> rr, List<double> times}) syntheticRsaRr({
  required double modHz,
  double hrBpm = 60,
  double ampMs = 40,
  int beats = 400,
}) {
  final meanRr = 60000.0 / hrBpm;
  final rr = <double>[];
  final times = <double>[];
  var t = 0.0; // ms
  for (var i = 0; i < beats; i++) {
    // Phase advances with elapsed time so the modulation is in real-time Hz.
    final phase = 2 * math.pi * modHz * (t / 1000.0);
    final r = meanRr + ampMs * math.sin(phase);
    t += r;
    rr.add(r);
    times.add(t);
  }
  return (rr: rr, times: times);
}

/// Build a 1 Hz ADC sinusoid at [hz] over [seconds] with a DC offset + slow
/// drift, the RIIV target.
({List<double> adc, List<double> ts}) syntheticRiivAdc({
  required double hz,
  int seconds = 120,
  double dc = 10000,
  double amp = 200,
}) {
  final adc = <double>[];
  final ts = <double>[];
  for (var s = 0; s < seconds; s++) {
    final drift = 0.5 * s; // slow baseline wander
    adc.add(dc + drift + amp * math.sin(2 * math.pi * hz * s));
    ts.add(s.toDouble());
  }
  return (adc: adc, ts: ts);
}

void main() {
  _resp01Tests();
  // -------------------------------------------------------------------------
  // 1. SYNTHETIC KNOWN-ANSWER
  // -------------------------------------------------------------------------
  group('synthetic known-answer', () {
    test('RSA: RR modulated at 0.25 Hz -> ~15 br/min', () {
      final s = syntheticRsaRr(modHz: 0.25, hrBpm: 60, ampMs: 40, beats: 500);
      final corr = correctRr(s.rr);
      final m = rsaRespRate(corr.nn, corr.nnTimesMs,
          artifactFraction: 1 - corr.cleanFraction);
      expect(m.present, isTrue, reason: m.note);
      final brpm = m.value!.brpm!;
      // 0.25 Hz = 15 br/min.
      expect(brpm, closeTo(15, 1.5), reason: 'got $brpm br/min');
      expect(m.tier, Tier.high);
      expect(m.confidence, greaterThan(0));
    });

    test('RSA: a different rate (0.20 Hz -> ~12 br/min) also recovered', () {
      final s = syntheticRsaRr(modHz: 0.20, hrBpm: 65, ampMs: 35, beats: 500);
      final corr = correctRr(s.rr);
      final m = rsaRespRate(corr.nn, corr.nnTimesMs,
          artifactFraction: 1 - corr.cleanFraction);
      expect(m.present, isTrue, reason: m.note);
      expect(m.value!.brpm!, closeTo(12, 1.5));
    });

    test('RSA: 26.4 br/min is REPORTED, not folded to a plausible 22', () {
      // an-motion-1. The search band stopped at rsaHiHz (0.40 Hz = 24 br/min)
      // while the anti-alias guard tested respHiHz (0.5), so the guard was dead
      // code and any real rate above 24 br/min came back as the largest
      // SPURIOUS in-band peak at confidence 0.90. Measured pre-fix:
      // 26.4 -> 22.23, 28.8 -> 17.43, both present. The search now runs to the
      // window's own beat-rate Nyquist.
      for (final trueBrpm in [26.4, 28.8]) {
        final s = syntheticRsaRr(
            modHz: trueBrpm / 60.0, hrBpm: 75, ampMs: 40, beats: 600);
        final corr = correctRr(s.rr);
        final m = rsaRespRate(corr.nn, corr.nnTimesMs,
            artifactFraction: 1 - corr.cleanFraction);
        expect(m.present, isTrue, reason: m.note);
        expect(m.value!.brpm!, closeTo(trueBrpm, 1.5),
            reason: 'got ${m.value!.brpm} for a true $trueBrpm br/min');
      }
    });

    test('RSA: a rate the BEAT RATE cannot resolve is ABSENT, not a number',
        () {
      // The tachogram is sampled once per beat, so at HR 43 (NN ~1400 ms) the
      // Nyquist is ~21 br/min — below the HF band itself. A 26 br/min breather
      // folds to a full-height peak at 16.9 br/min that no spectral test can
      // tell from a genuine 16.9. The honest output is nothing.
      final s =
          syntheticRsaRr(modHz: 26 / 60.0, hrBpm: 43, ampMs: 40, beats: 600);
      final corr = correctRr(s.rr);
      final m = rsaRespRate(corr.nn, corr.nnTimesMs,
          artifactFraction: 1 - corr.cleanFraction);
      expect(m.present, isFalse, reason: 'got ${m.value?.brpm}');
      expect(m.confidence, 0);
      expect(m.note, contains('alias'));
    });

    test('RSA: the note states the ceiling actually enforced', () {
      // It used to say "1 Hz Nyquist caps rate at 30 br/min" while enforcing 24.
      final s = syntheticRsaRr(modHz: 0.25, hrBpm: 60, ampMs: 40, beats: 500);
      final corr = correctRr(s.rr);
      final m = rsaRespRate(corr.nn, corr.nnTimesMs,
          artifactFraction: 1 - corr.cleanFraction);
      expect(m.note, contains('could resolve up to'));
    });

    test('RSA: absent on too-few beats -> null + confidence 0', () {
      final m =
          rsaRespRate([800, 810, 790], [800, 1610, 2400], artifactFraction: 0);
      expect(m.present, isFalse);
      expect(m.confidence, 0);
    });

    test('RIIV: 1 Hz ADC sinusoid at 0.2 Hz -> ~12 br/min', () {
      final s = syntheticRiivAdc(hz: 0.2, seconds: 150);
      final m = riivRespRate(s.adc, s.ts);
      expect(m.present, isTrue, reason: m.note);
      expect(m.value!.brpm!, closeTo(12, 1.0), reason: 'got ${m.value!.brpm}');
      expect(m.tier, Tier.relative);
    });

    test('RIIV: 0.25 Hz ADC -> ~15 br/min', () {
      final s = syntheticRiivAdc(hz: 0.25, seconds: 150);
      final m = riivRespRate(s.adc, s.ts);
      expect(m.present, isTrue, reason: m.note);
      expect(m.value!.brpm!, closeTo(15, 1.0));
    });

    test('Karlen SD-gate: agreeing RSA+RIIV fuse; disagreeing fall back', () {
      // Both ~15 br/min (0.25 Hz) -> agree -> fused.
      final rsa = syntheticRsaRr(modHz: 0.25, beats: 500);
      final corr = correctRr(rsa.rr);
      final mRsa = rsaRespRate(corr.nn, corr.nnTimesMs,
          artifactFraction: 1 - corr.cleanFraction);
      final adc = syntheticRiivAdc(hz: 0.25, seconds: 150);
      final mRiiv = riivRespRate(adc.adc, adc.ts);
      final fused = fuseRespRate(mRsa, mRiiv);
      expect(fused.present, isTrue);
      expect(fused.value!.agreed, isTrue);
      expect(fused.value!.decision, 'fused');
      expect(fused.value!.brpm!, closeTo(15, 1.5));
      // Fusion of two corroborating estimates is at least as confident.
      expect(fused.confidence, greaterThanOrEqualTo(mRsa.confidence));

      // Now disagree: RSA ~15, RIIV ~24 (0.40 Hz) -> SD-gate trips -> RSA-only.
      final adcHi = syntheticRiivAdc(hz: 0.40, seconds: 150);
      final mRiivHi = riivRespRate(adcHi.adc, adcHi.ts);
      final dis = fuseRespRate(mRsa, mRiivHi);
      expect(dis.present, isTrue);
      expect(dis.value!.agreed, isFalse);
      expect(dis.value!.decision, 'disagree');
      // Falls back to the validated primary (RSA).
      expect(dis.value!.brpm!, closeTo(15, 1.5));
    });

    test('Nyquist: a >30 br/min target is refused (no aliased rate)', () {
      // 0.45 Hz = 27 br/min still valid; push above Nyquist edge handling by
      // confirming we never report >= 30 br/min.
      final s = syntheticRiivAdc(hz: 0.45, seconds: 150);
      final m = riivRespRate(s.adc, s.ts);
      if (m.present) {
        expect(m.value!.brpm!, lessThan(30));
      }
    });

    test('ACAT/CVHR: injected periodic bradycardia cycles are counted', () {
      // Build 1 Hz HR with ~7 apnea-like cycles over ~7 min: baseline HR 60,
      // each cycle = a SMOOTH bradycardia (HR sags ~12 bpm) over ~20 s every
      // ~60 s. A gradual cyclic sag (not a step) is both physiologically
      // realistic for sleep-disordered breathing and survives the RR artifact
      // detector (which legitimately drops abrupt single-beat jumps).
      // We feed the detector an ALREADY-CLEAN NN series (the synthetic is
      // artifact-free by construction). This is the honest unit test of the
      // CVHR detector itself; in the live pipeline correctRr runs first, and
      // it legitimately cannot distinguish a gentle 1 Hz bradycardia swing from
      // a long beat (a stated 1 Hz limitation) — so the detector is validated
      // here on clean input rather than fighting the artifact gate.
      const cycleSec = 60;
      const nCycles = 7;
      const totalSec = cycleSec * nCycles; // 420 s
      final nn = <double>[];
      final nnTimes = <double>[];
      var t = 0.0;
      var s = 0;
      while (s < totalSec) {
        // Sinusoidal HR modulation: 60 ± 6 bpm, period = cycleSec.
        final hr =
            60.0 - 6.0 * math.sin(2 * math.pi * (s % cycleSec) / cycleSec);
        final r = 60000.0 / hr; // ms
        nn.add(r);
        t += r;
        nnTimes.add(t);
        s = (t / 1000.0).floor();
      }
      final m = cvhrApneaScreen(nn, nnTimes, artifactFraction: 0);
      expect(m.present, isTrue, reason: m.note);
      final v = m.value!;
      // We injected 7 cycles; allow detector edge effects (±2).
      expect(v.cycleCount, inInclusiveRange(5, 9),
          reason: 'detected ${v.cycleCount} CVHR cycles');
      expect(v.cvhrPerHour, greaterThan(0));
      // Honesty: it's a screen, never a diagnosis — note says so.
      expect(m.note!.toLowerCase(), contains('screen'));
    });

    test('CVHR: an off-wrist HOLE does not dilute the per-hour index', () {
      // an-motion-6. analyzedHours was the first-to-last beat SPAN and
      // _resampleLinear drew a straight line across the hole, so the identical
      // beats with a 2 h gap in the middle read 53.33/h instead of 80.00/h — a
      // 33% "improvement" in an apnea screen bought by taking the band off.
      const cycleSec = 60;
      final nn = <double>[];
      final nnTimes = <double>[];
      var t = 0.0;
      var s = 0;
      while (s < cycleSec * 14) {
        final hr =
            60.0 - 6.0 * math.sin(2 * math.pi * (s % cycleSec) / cycleSec);
        final r = 60000.0 / hr;
        nn.add(r);
        t += r;
        nnTimes.add(t);
        s = (t / 1000.0).floor();
      }
      final whole = cvhrApneaScreen(nn, nnTimes, artifactFraction: 0);

      // Same beats, second half displaced by a 2 h hole.
      final half = nnTimes.length ~/ 2;
      final gapped = [
        for (var i = 0; i < nnTimes.length; i++)
          i < half ? nnTimes[i] : nnTimes[i] + 2 * 3600 * 1000
      ];
      final holed = cvhrApneaScreen(nn, gapped, artifactFraction: 0);

      expect(holed.present, isTrue, reason: holed.note);
      expect(
          holed.value!.analyzedHours, closeTo(whole.value!.analyzedHours, 0.02),
          reason: 'the 2 h hole is not observed time');
      expect(holed.value!.cvhrPerHour, closeTo(whole.value!.cvhrPerHour, 3.0),
          reason: 'pre-fix this fell by a third');
    });

    test('CVHR: no cycles means mean depth/width are ABSENT, not 0', () {
      // an-motion-7. They were non-nullable and filled with 0, serialising an
      // absence as a measurement.
      final rr = List<double>.filled(400, 1000.0);
      final jit = [
        for (var i = 0; i < rr.length; i++) rr[i] + (i.isEven ? 5 : -5)
      ];
      final corr = correctRr(jit);
      final m = cvhrApneaScreen(corr.nn, corr.nnTimesMs,
          artifactFraction: 1 - corr.cleanFraction);
      expect(m.value!.cycleCount, 0);
      expect(m.value!.meanDepthMs, isNull);
      expect(m.value!.meanWidthSec, isNull);
      expect(m.value!.toJson()['mean_depth_ms'], isNull);
    });

    test('CVHR: a steady (non-cyclic) RR yields ~0 cycles', () {
      final rr = List<double>.filled(400, 1000.0); // flat 60 bpm
      // add tiny jitter so correction has dispersion
      final jit = [
        for (var i = 0; i < rr.length; i++) rr[i] + (i.isEven ? 5 : -5)
      ];
      final corr = correctRr(jit);
      final m = cvhrApneaScreen(corr.nn, corr.nnTimesMs,
          artifactFraction: 1 - corr.cleanFraction);
      expect(m.present, isTrue, reason: m.note);
      expect(m.value!.cycleCount, lessThanOrEqualTo(1));
    });

    test('relative-ODI: injected red/IR dips are counted; never %SpO2', () {
      // 1 Hz red/IR over 600 s. Baseline AC/DC stable. Inject 5 desaturation
      // events: during each, the red AC/DC rises (R rises => oxygenation drops)
      // by adding extra variance to the red channel for ~20 s.
      const totalSec = 600;
      final red = <double>[];
      final ir = <double>[];
      final ts = <double>[];
      final rnd = math.Random(42);
      // event windows (start seconds)
      final events = [80, 200, 320, 440, 540];
      // Pulsatile carrier at 0.3 Hz (well below the 0.5 Hz Nyquist, so it
      // samples cleanly and yields a real rolling-σ AC term).
      const pulsHz = 0.3;
      for (var s = 0; s < totalSec; s++) {
        final inEvent = events.any((e) => s >= e && s < e + 20);
        // IR: steady pulsatile small variation.
        final irPuls =
            50 * math.sin(2 * math.pi * pulsHz * s) + rnd.nextDouble() * 5;
        ir.add(20000 + irPuls);
        // Red: baseline small variation; during an event, amplify red AC (the
        // ratio-of-ratios rises => relative desaturation).
        final redAmp = inEvent ? 400.0 : 60.0;
        final redPuls =
            redAmp * math.sin(2 * math.pi * pulsHz * s) + rnd.nextDouble() * 5;
        red.add(18000 + redPuls);
        ts.add(s.toDouble());
      }
      final m = relativeOdi(red, ir, ts, dipPct: 3.0);
      expect(m.present, isTrue, reason: m.note);
      final v = m.value!;
      expect(v.dipCount, inInclusiveRange(3, 7),
          reason: 'counted ${v.dipCount} relative desaturations');
      expect(v.odiPerHour, greaterThan(0));
      // HONESTY: relative only, never an absolute %.
      expect(m.tier, Tier.relative);
      expect(v.toJson()['absolute_spo2'], isFalse);
      expect(m.note!.toLowerCase(), contains('never an absolute spo₂'));
    });

    test('relativeOdi: all-NaN ratios → honest absent, not a fabricated 0', () {
      // A perfectly CONSTANT IR channel makes acIr (rolling σ) = 0, so the
      // ratio-of-ratios is 0 for every sample and every relR entry is NaN.
      // meanRelR must NOT be reported as 0.0 — the whole screen is absent.
      const n = 300;
      final red = <double>[for (var i = 0; i < n; i++) 18000 + (i % 7) * 3.0];
      final ir = <double>[for (var i = 0; i < n; i++) 20000.0]; // constant
      final ts = <double>[for (var i = 0; i < n; i++) i.toDouble()];
      final m = relativeOdi(red, ir, ts);
      expect(m.present, isFalse);
      expect(m.value, isNull);
      expect(m.tier, Tier.relative);
      expect(m.note, isNotNull);
    });

    test('BRV: variable breathing rates -> CV>0 + Theil-Sen slope', () {
      final brpm = [14.0, 15.0, 13.0, 16.0, 12.0, 17.0, 11.0];
      final m = breathingRateVariability(brpm);
      expect(m.present, isTrue);
      expect(m.value!.sdBrpm, greaterThan(0));
      expect(m.value!.cv, greaterThan(0));
      expect(m.value!.trendSlope, isNotNull);
      // monotone-ish spread, slope sign is the robust trend
      expect(m.value!.nWindows, 7);
    });

    test('BRV: <3 windows -> absent', () {
      final m = breathingRateVariability([14, 15]);
      expect(m.present, isFalse);
      expect(m.confidence, 0);
    });
  });

  // -------------------------------------------------------------------------
  // 2. PLAUSIBILITY on the real capture (no oracle).
  // -------------------------------------------------------------------------
  group('real-capture plausibility (whoop_hist.jsonl)', () {
    final histFile = File('../whoop_hist.jsonl');

    test('decode + run the respiration family; sane, no crash', () {
      if (!histFile.existsSync()) {
        markTestSkipped('whoop_hist.jsonl not found beside the repo');
        return;
      }
      final lines =
          histFile.readAsLinesSync().where((l) => l.trim().isNotEmpty).toList();

      final rrMs = <double>[];
      final green = <double>[];
      final red = <double>[];
      final ir = <double>[];
      final ts = <double>[];
      var firstTs = 0, lastTs = 0;

      for (final line in lines) {
        final obj = jsonDecode(line) as Map<String, dynamic>;
        if (obj['t'] != 24) continue;
        final r = parseR24(hexToBytes(obj['hex'] as String));
        if (r == null) continue;
        if (firstTs == 0) firstTs = r.tsEpoch;
        lastTs = r.tsEpoch;
        for (final rr in r.rrIntervalsMs) {
          if (rr > 0) rrMs.add(rr.toDouble());
        }
        green.add(r.ppgGreen.toDouble());
        red.add(r.spo2RedRaw.toDouble());
        ir.add(r.spo2IrRaw.toDouble());
        ts.add((r.tsEpoch - firstTs).toDouble());
      }
      final spanSec = lastTs - firstTs;
      // ignore: avoid_print
      print('REAL resp: rrBeats=${rrMs.length} adcN=${green.length} '
          'spanSec=$spanSec');

      // --- RSA respiratory rate ---
      final corr = correctRr(rrMs);
      final rsa = rsaRespRate(corr.nn, corr.nnTimesMs,
          artifactFraction: 1 - corr.cleanFraction);
      // ignore: avoid_print
      print('REAL RSA: present=${rsa.present} '
          'brpm=${rsa.value?.brpm?.toStringAsFixed(1)} '
          'conf=${rsa.confidence.toStringAsFixed(2)} note=${rsa.note}');
      if (rsa.present) {
        // plausible adult resting/active respiratory range on a 1 Hz signal.
        expect(rsa.value!.brpm!, inInclusiveRange(6, 30),
            reason: 'RSA respiratory rate plausible');
      }

      // --- RIIV from green ADC ---
      final riiv = riivRespRate(green, ts);
      // ignore: avoid_print
      print('REAL RIIV: present=${riiv.present} '
          'brpm=${riiv.value?.brpm?.toStringAsFixed(1)}');
      if (riiv.present) {
        expect(riiv.value!.brpm!, inInclusiveRange(6, 30));
      }

      // --- fusion never crashes ---
      final fused = fuseRespRate(rsa, riiv);
      // ignore: avoid_print
      print('REAL fused: present=${fused.present} '
          'decision=${fused.value?.decision} '
          'brpm=${fused.value?.brpm?.toStringAsFixed(1)}');
      expect(fused, isNotNull);
      if (fused.present) {
        expect(fused.value!.brpm!, inInclusiveRange(6, 30));
      }

      // --- CVHR screen runs on the short snippet (mostly synthetic-validated)
      final cvhr = cvhrApneaScreen(corr.nn, corr.nnTimesMs,
          artifactFraction: 1 - corr.cleanFraction);
      // ignore: avoid_print
      print('REAL CVHR: present=${cvhr.present} '
          'cycles=${cvhr.value?.cycleCount} '
          'perHour=${cvhr.value?.cvhrPerHour.toStringAsFixed(2)} '
          '(short snippet — apnea screen synthetic-validated)');
      expect(cvhr, isNotNull);
      if (cvhr.present) {
        expect(cvhr.value!.cvhrPerHour, greaterThanOrEqualTo(0));
        expect(cvhr.note!.toLowerCase(), contains('screen'));
      }

      // --- relative ODI never emits a % and never crashes ---
      final odi = relativeOdi(red, ir, ts);
      // ignore: avoid_print
      print('REAL relODI: present=${odi.present} '
          'dips=${odi.value?.dipCount} '
          'meanRelR=${odi.value?.meanRelR.toStringAsFixed(4)}');
      expect(odi, isNotNull);
      if (odi.present) {
        expect(odi.tier, Tier.relative);
        expect(odi.value!.toJson()['absolute_spo2'], isFalse);
        expect(odi.value!.odiPerHour, greaterThanOrEqualTo(0));
      }
    });
  });

  // -------------------------------------------------------------------------
  // REGRESSION: brpm, peak_hz and power inside one RespEstimate must come from
  // ONE source. brpm used to be median(peaks) across the three spectral grids
  // while peakHz/power came from the highest-POWER grid, so `peak_hz * 60` and
  // `brpm` disagreed inside a single result.
  // -------------------------------------------------------------------------
  group('rsaRespRate — internally consistent output (regression)', () {
    for (final hz in const [0.25, 0.20, 0.30]) {
      test('modHz=$hz: peak_hz * 60 == brpm exactly', () {
        final s = syntheticRsaRr(modHz: hz, beats: 500);
        final corr = correctRr(s.rr);
        final m = rsaRespRate(corr.nn, corr.nnTimesMs,
            artifactFraction: 1 - corr.cleanFraction);
        expect(m.present, isTrue, reason: m.note);
        final v = m.value!;
        expect(v.brpm, isNotNull);
        expect(v.peakHz, isNotNull);
        expect(v.power, isNotNull);
        expect(v.peakHz! * 60.0, closeTo(v.brpm!, 1e-9),
            reason: 'brpm ${v.brpm} vs peak_hz*60 ${v.peakHz! * 60}');
        // The reported rate must still be the right one.
        expect(v.brpm!, closeTo(hz * 60.0, 1.5));
      });
    }

    test('the JSON pair round-trips consistently', () {
      final s = syntheticRsaRr(modHz: 0.25, beats: 500);
      final corr = correctRr(s.rr);
      final m = rsaRespRate(corr.nn, corr.nnTimesMs,
          artifactFraction: 1 - corr.cleanFraction);
      final j = m.value!.toJson();
      expect(
          (j['peak_hz'] as double) * 60.0, closeTo(j['brpm'] as double, 1e-4));
    });
  });
}

// ---------------------------------------------------------------------------
// RESP-01 / RESP-02 (gate half) — the 30-night personal CVHR distribution.
// ---------------------------------------------------------------------------
void _resp01Tests() {
  CvhrNight night(int day, double perHour,
          {double hours = 7, bool irregular = false}) =>
      CvhrNight(
        dayKey: '2026-01-${day.toString().padLeft(2, '0')}',
        cvhrPerHour: perHour,
        analyzedHours: hours,
        irregularRhythm: irregular,
      );

  group('RESP-01 personal distribution', () {
    test('under 5 qualifying nights is ABSENT with a machine-readable note',
        () {
      final m = cvhrPersonalDistribution([
        for (var d = 1; d <= 4; d++) night(d, 10),
      ]);
      expect(m.present, isFalse);
      expect(m.value, isNull);
      expect(m.note, contains('need_baseline:nights=4/5'));
    });

    test('thin nights (<4 analyzed hours) never weigh on the screen', () {
      final m = cvhrPersonalDistribution([
        for (var d = 1; d <= 5; d++) night(d, 10),
        for (var d = 6; d <= 10; d++) night(d, 90, hours: 1),
      ]);
      expect(m.present, isTrue);
      expect(m.value!.nightsUsed, 5);
      expect(m.value!.nightsExcludedThin, 5);
      expect(m.value!.weightedMean, closeTo(10, 1e-9));
    });

    test(
        'RESP-02 cross-gate: irregular-rhythm nights are EXCLUDED, not weighted',
        () {
      final withAf = cvhrPersonalDistribution([
        for (var d = 1; d <= 5; d++) night(d, 10),
        night(6, 200, irregular: true),
      ]);
      expect(withAf.value!.nightsUsed, 5);
      expect(withAf.value!.nightsExcludedIrregular, 1);
      // the AF night's 200/h moved nothing
      expect(withAf.value!.weightedMean, closeTo(10, 1e-9));
    });

    test('nights are weighted by their OWN analyzed hours', () {
      final m = cvhrPersonalDistribution([
        night(1, 20, hours: 8),
        night(2, 10, hours: 4),
        night(3, 10, hours: 4),
        night(4, 10, hours: 4),
        night(5, 10, hours: 4),
      ]);
      // unweighted mean would be 12.0; hours-weighted is 20*8+10*16 over 24
      expect(m.value!.weightedMean, closeTo((20 * 8 + 10 * 16) / 24, 1e-9));
    });

    test('the only comparison is against the user own retained spread', () {
      final quiet = cvhrPersonalDistribution([
        for (var d = 1; d <= 10; d++) night(d, 10),
      ]);
      expect(quiet.value!.aboveOwnUsual, isFalse);
      final rising = cvhrPersonalDistribution([
        for (var d = 1; d <= 8; d++) night(d, 5),
        night(9, 40),
        night(10, 40),
        night(11, 40),
      ]);
      expect(rising.value!.aboveOwnUsual, isTrue);
      // and it still refuses to be an AHI or a severity
      expect(rising.toJson().toString(), isNot(contains('ahi')));
    });

    test('a re-derived day counts once', () {
      final m = cvhrPersonalDistribution([
        for (var d = 1; d <= 5; d++) night(d, 10),
        night(5, 10),
      ]);
      expect(m.value!.nightsUsed, 5);
    });
  });
}
