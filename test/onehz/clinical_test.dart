// Item 3 — CLINICAL TIER-1. Synthetic, known-answer tests.
import 'dart:math' as math;
import 'package:test/test.dart';
import 'package:openstrap_analytics/onehz.dart';

void main() {
  group('time-domain HRV (hand-computed)', () {
    test('RMSSD/SDNN/pNN50 on a constant-then-stepped NN series', () {
      final nn = <double>[800, 800, 800, 900, 900, 900];
      final m = hrvTime(nn);
      final v = m.value!;
      // diffs [0,0,100,0,0] -> RMSSD=sqrt(10000/5)=44.7214
      expect(v.rmssd, closeTo(44.72136, 1e-4));
      // mean 850, sample SD = sqrt(6*2500/5)=54.7723
      expect(v.sdnn, closeTo(54.77226, 1e-4));
      // one diff >50 out of 5 -> 20%
      expect(v.pnn50, closeTo(20.0, 1e-9));
      expect(v.nBeats, 6);
      expect(m.tier, 'HIGH');
    });

    test('absent on too-few beats', () {
      expect(hrvTime([800]).present, isFalse);
    });

    test('HRV-02: RMSSD/pNN50 refused when the differences are white noise',
        () {
      // Differencing a smooth tachogram leaves ACF1 near 0; differencing white
      // noise leaves exactly -0.5. gen5/MG nights measure -0.426..-0.517 —
      // essentially pure jitter — while every gen4 night sits at -0.057..-0.324.
      final rnd = math.Random(7);
      final jitter = <double>[
        for (var i = 0; i < 600; i++) 1000 + (rnd.nextDouble() - 0.5) * 120
      ];
      final noisy = hrvTime(jitter);
      expect(noisy.value!.diffAcf1!, lessThan(kNnDiffAcf1Floor));
      expect(noisy.value!.diffAcf1!, closeTo(-0.5, 0.1),
          reason: 'differenced white noise');
      expect(noisy.value!.rmssd, isNull, reason: 'jitter, not vagal tone');
      expect(noisy.value!.pnn50, isNull);
      // SDNN is a dispersion of LEVELS and survives — the header's advice.
      expect(noisy.value!.sdnn, isNotNull);
      expect(noisy.note, contains('rmssd_refused:acf1='));

      // A smooth respiratory-sinus-shaped series keeps its RMSSD.
      final smooth = <double>[
        for (var i = 0; i < 600; i++) 1000 + 40 * math.sin(2 * math.pi * i / 16)
      ];
      final clean = hrvTime(smooth);
      expect(clean.value!.diffAcf1!, greaterThan(kNnDiffAcf1Floor));
      expect(clean.value!.rmssd, isNotNull);
      expect(clean.value!.pnn50, isNotNull);
    });

    test('HRV-02: confidence carries jitter and artifact, not beat count alone',
        () {
      // It used to be clamp(n/250, .3, .95), which published 0.95 on all 13
      // nights of the audit corpus. n/250 saturates after ~4 min, so on a whole
      // night confidence was a constant.
      final smooth = <double>[
        for (var i = 0; i < 600; i++) 1000 + 40 * math.sin(2 * math.pi * i / 16)
      ];
      final base = hrvTime(smooth).confidence;
      expect(base, closeTo(0.95, 1e-9),
          reason: 'a clean series still tops out');
      expect(hrvTime(smooth, artifactFraction: 0.15).confidence,
          closeTo(0.85, 1e-9),
          reason: '15% artifact must cost confidence, as hrvFreq already does');
      final rnd = math.Random(7);
      final jitter = <double>[
        for (var i = 0; i < 600; i++) 1000 + (rnd.nextDouble() - 0.5) * 120
      ];
      expect(hrvTime(jitter).confidence, 0.3,
          reason: 'confidence bottoms out where RMSSD is refused');
    });

    test('successive differences do not span a DROPPED run', () {
      // an-clinical-6. correctRr drops multi-beat artifact runs while advancing
      // its clock across them, so nn[i-1] and nn[i] can sit either side of a
      // seconds-long hole. Differencing straight down the compacted list
      // manufactured one large difference per dropped run — a fraction of a ms
      // on a night's RMSSD, but pNN50 can be entirely seam-driven.
      // 800-ms beats, a 3-beat hole, then 900-ms beats: the seam Δ is 100 ms
      // (a pNN50 hit) and the real Δs are all 0.
      final nn = <double>[800, 800, 800, 900, 900, 900];
      final times = <double>[800, 1600, 2400, 5700, 6600, 7500]; // 3.3 s hole
      final seamed = hrvTime(nn).value!; // no beat times -> seam included
      expect(seamed.pnn50, closeTo(100.0 / 5, 1e-9));
      final clean = hrvTime(nn, nnTimesMs: times).value!;
      expect(clean.rmssd, 0.0, reason: '4 contiguous pairs, all Δ = 0');
      expect(clean.pnn50, 0.0);
      // SDNN is a dispersion of levels, not of differences — unaffected.
      expect(clean.sdnn, closeTo(seamed.sdnn!, 1e-12));
    });
  });

  group('frequency-domain HRV (Lomb-Scargle on beat times)', () {
    test('puts spectral peak at an injected RSA frequency in the HF band', () {
      // RR modulated at 0.25 Hz (respiration ~15 br/min) around 1000 ms.
      final rr = <double>[];
      final times = <double>[];
      var t = 0.0;
      for (var i = 0; i < 256; i++) {
        final v = 1000 + 40 * math.sin(2 * math.pi * 0.25 * (t / 1000));
        rr.add(v);
        t += v;
        times.add(t);
      }
      final m = hrvFreq(rr, times, artifactFraction: 0.0);
      expect(m.present, isTrue);
      expect(m.value!.hfGated, isFalse);
      // HF band should carry meaningful power.
      expect(m.value!.hf, isNotNull);
      expect(m.value!.hf!, greaterThan(0));
    });

    test('GATES HF when artifact fraction exceeds the threshold', () {
      // RE-PINNED 2026-08: 400 beats, not 64. Band powers are now Welch-
      // averaged over segments long enough to RESOLVE the band (10 cycles of
      // its lowest frequency: 250 s for LF), so a 64 s record honestly reports
      // no LF and no HF at all rather than a grid-aliased number.
      final rr = <double>[
        for (var i = 0; i < 400; i++) 1000 + (i.isEven ? 30 : -30)
      ];
      final times = <double>[];
      var t = 0.0;
      for (final v in rr) {
        t += v;
        times.add(t);
      }
      final m = hrvFreq(rr, times, artifactFraction: 0.5); // heavy artifacts
      expect(m.value!.hfGated, isTrue);
      expect(m.value!.hf, isNull); // HF withheld honestly
      expect(m.value!.lf, isNotNull); // LF still reported
    });

    test('MAGNITUDE: total power ≈ SDNN², and lf_hf is grid-stable', () {
      // T-01. Nothing used to assert a spectral MAGNITUDE, which is how three
      // separate defects survived: lombScargle returned Horne–Baliunas
      // variance-NORMALISED power (dimensionless) that was labelled ms², and a
      // fixed 600-point grid undersampled a night's periodogram ~19x so band
      // power was a lucky sample rather than an integral.
      //
      // Known-answer synthetic: 30 ms LF tone at 0.10 Hz (variance 450 ms²) +
      // 20 ms HF tone at 0.25 Hz (variance 200 ms²) on 9000 beats.
      final nn = <double>[];
      final ts = <double>[];
      var t = 0.0;
      for (var i = 0; i < 9000; i++) {
        final tsec = t / 1000.0;
        final v = 1000.0 +
            30.0 * math.sin(2 * math.pi * 0.10 * tsec) +
            20.0 * math.sin(2 * math.pi * 0.25 * tsec);
        nn.add(v);
        t += v;
        ts.add(t);
      }
      final sd = stddev(nn)!;
      final m = hrvFreq(nn, ts, artifactFraction: 0.0);
      final v = m.value!;
      // Bands land on their injected variances, in ms².
      expect(v.lf!, closeTo(450.0, 45.0));
      expect(v.hf!, closeTo(200.0, 20.0));
      // Parseval: the total is the series variance = SDNN². Pre-fix this
      // printed 0.1 for a 651 ms² night.
      expect(v.total!, closeTo(sd * sd, 0.05 * sd * sd));
      // And the ratio no longer depends on how finely we happened to sample.
      final coarse = hrvFreq(nn, ts, artifactFraction: 0.0, oversample: 1.0);
      final fine = hrvFreq(nn, ts, artifactFraction: 0.0, oversample: 16.0);
      expect(coarse.value!.lfhf!, closeTo(fine.value!.lfhf!, 0.1));
    });

    test('a band the record cannot RESOLVE is absent, not 0.0', () {
      // ULF needs a 24-h record (its own header says so); the gate used to be
      // 333 s, and `bandPower` skipped the grid's lowest point, so any session
      // of 333–429 s emitted `ulf` as exactly 0.0.
      final nn = <double>[for (var i = 0; i < 400; i++) 1000.0 + (i % 7)];
      final ts = <double>[];
      var t = 0.0;
      for (final v in nn) {
        t += v;
        ts.add(t);
      }
      final m = hrvFreq(nn, ts, artifactFraction: 0.0);
      expect(m.value!.ulf, isNull);
      expect(m.value!.toJson().containsKey('ulf'), isFalse);
    });

    test('REGRESSION: a gated HF is not republished through `total`', () {
      // total used to sum hfRaw back in, so the gated and ungated totals were
      // bit-identical (0.49944 in both) — the suppression was cosmetic.
      final rr = <double>[];
      final times = <double>[];
      var t = 0.0;
      for (var i = 0; i < 400; i++) {
        final v = 1000 + 40 * math.sin(2 * math.pi * 0.25 * (t / 1000));
        rr.add(v);
        t += v;
        times.add(t);
      }
      final clean = hrvFreq(rr, times, artifactFraction: 0.0);
      final gated = hrvFreq(rr, times, artifactFraction: 0.5);
      expect(clean.value!.total, isNotNull);
      expect(gated.value!.hfGated, isTrue);
      expect(gated.value!.total, isNull,
          reason: 'total power is a sum over ALL bands; with HF withheld it is '
              'not computable');
      expect(gated.value!.toJson().containsKey('total'), isFalse);
      expect(gated.note, contains('total'));
    });

    test('total NAMES what it summed instead of folding absent bands in as 0',
        () {
      // an-clinical-3. `total` was `(ulf ?? 0) + (vlf ?? 0) + lf + hfRaw`, and
      // ULF can never resolve on a night — _welchBandPower needs 10 cycles at
      // 0.0003 Hz = 33 333 s of span and a night is ~28 700 s — so the ULF term
      // entered the published total as a literal 0 on every single night, while
      // the comment above it claimed total was withheld when an unresolvable
      // band was missing. The number is unchanged (0 adds nothing); what
      // changes is that the sum now says which bands it is a sum OVER.
      final nn = <double>[for (var i = 0; i < 400; i++) 1000.0 + (i % 7)];
      final ts = <double>[];
      var t = 0.0;
      for (final v in nn) {
        t += v;
        ts.add(t);
      }
      final v = hrvFreq(nn, ts, artifactFraction: 0.0).value!;
      expect(v.ulf, isNull, reason: 'a 400-beat record cannot resolve ULF');
      expect(v.totalBands, isNotNull);
      expect(v.totalBands, isNot(contains('ulf')));
      // The sum is EXACTLY the named bands, with nothing implicit in it.
      final named = {'ulf': v.ulf, 'vlf': v.vlf, 'lf': v.lf, 'hf': v.hf};
      var sum = 0.0;
      for (final b in v.totalBands!) {
        sum += named[b]!;
      }
      expect(v.total!, closeTo(sum, 1e-9));
      expect(v.toJson()['total_bands'], v.totalBands);
    });
  });

  group('PRSA DC/AC (Bauer 2006)', () {
    test('DC sign: a decelerating-biased series gives positive DC', () {
      // Slow oscillation so anchors capture genuine decel/accel phases.
      final rr = <double>[];
      for (var i = 0; i < 400; i++) {
        rr.add(1000 + 20 * math.sin(2 * math.pi * i / 20));
      }
      final dc = decelerationCapacity(rr);
      final ac = accelerationCapacity(rr);
      expect(dc.present, isTrue);
      // DC quantifies decelerations -> positive; AC negative (mirror).
      expect(dc.value!.capacity, greaterThan(0));
      expect(ac.value!.capacity, lessThan(0));
      expect(dc.value!.kind, 'DC');
      // HRV-03. Bauer's post-MI mortality tier is GONE from the payload — its
      // cut-offs are 24-h Holter ECG in post-MI patients, and on one subject in
      // one 9-day window it read 'low' on gen4 (DC 7.6-9.9), 'intermediate' on
      // MG and 'high' on WHOOP 5 (DC 1.70): the tier was decided by the strap.
      expect(dc.toJson((v) => v.toJson()).toString(), isNot(contains('risk')));
    });
    test('absent without enough beats', () {
      expect(decelerationCapacity([1000, 1010, 990]).present, isFalse);
    });
    test('REGRESSION: l=1 is refused, not a RangeError', () {
      // The Haar contrast at wavelet scale s=2 reads X(-2) = profile[l-2],
      // i.e. profile[-1] for l=1 — it used to throw RangeError.
      final rr = <double>[
        for (var i = 0; i < 200; i++) 1000 + 20 * math.sin(2 * math.pi * i / 20)
      ];
      final dc = decelerationCapacity(rr, l: 1);
      expect(dc.present, isFalse);
      expect(dc.confidence, 0);
      expect(dc.note, contains('l≥2'));
      expect(accelerationCapacity(rr, l: 1).present, isFalse);
      // l=2 (the default) still works on the same series.
      expect(decelerationCapacity(rr, l: 2).present, isTrue);
    });
  });

  group('nocturnal RHR + dip', () {
    test('lowest-30-min mean tracks the quiet trough; HR=0 excluded', () {
      // 3600 s: first half ~70 bpm, a 1800 s quiet block at ~50 bpm, some 0s.
      final hr = <double>[];
      for (var i = 0; i < 1800; i++) {
        hr.add(70);
      }
      for (var i = 0; i < 1800; i++) {
        hr.add(50);
      }
      hr.addAll(List.filled(50, 0)); // off-skin, must be ignored
      final m = nocturnalRhr(hr);
      expect(m.value!.low30Mean, closeTo(50, 1e-9));
      expect(m.value!.p1, closeTo(50, 1.0));
    });
    test('dip band classification', () {
      final day = <double>[for (var i = 0; i < 400; i++) 80];
      final night = <double>[for (var i = 0; i < 400; i++) 60];
      final m = hrDip(day, night);
      expect(m.value!.dipPct, closeTo(25, 1e-9)); // (80-60)/80
      expect(m.value!.band, 'dipper');
      // riser case. NOTE: this used to use 3 samples a side; a 3-sample "day"
      // and "night" is exactly the fabrication hrDipMinSamples now refuses, so
      // the case is expressed with a real (5-min) period of coverage instead.
      final r = hrDip(<double>[for (var i = 0; i < 400; i++) 60],
          <double>[for (var i = 0; i < 400; i++) 70]);
      expect(r.value!.band, 'riser');
    });

    test('REGRESSION: lowest-30-min mean needs a REAL contiguous 30-min window',
        () {
      // 900 valid samples ramping 100 -> 50 bpm. The gate admitted
      // length >= windowSamples~/2 and then w = min(1800, 900) made the sliding
      // loop never execute, so low30Mean was the WHOLE-STREAM mean (75.0) —
      // published as a "lowest-30-min" trough with confidence 0.4.
      final ramp = <double>[for (var i = 0; i < 900; i++) 100 - i * 50 / 900];
      final m = nocturnalRhr(ramp);
      expect(m.present, isFalse);
      expect(m.value, isNull);
      expect(m.confidence, 0);
    });

    test('REGRESSION: off-skin gaps are not compacted into a fake window', () {
      // 1800 valid samples scattered one-per-16-s across 8 h. Compacting the
      // valid stream made this a "30-min" window that actually spans 8 hours.
      final scattered = <double>[
        for (var i = 0; i < 28800; i++) (i % 16 == 0) ? 60.0 : 0.0
      ];
      expect(nocturnalRhr(scattered).present, isFalse);
      // A genuinely contiguous 30-min block of the same samples DOES resolve.
      final contiguous = <double>[
        ...List<double>.filled(1000, 0),
        ...List<double>.filled(1800, 60.0),
        ...List<double>.filled(1000, 0),
      ];
      final ok = nocturnalRhr(contiguous);
      expect(ok.present, isTrue);
      expect(ok.value!.low30Mean, closeTo(60, 1e-9));
    });

    test('REGRESSION: hrDip refuses a 1-sample day and a 1-sample night', () {
      final m = hrDip([70], [60]);
      expect(m.present, isFalse);
      expect(m.confidence, 0);
      expect(m.note, contains('${hrDipMinSamples}'));
    });
  });

  group('illness CUSUM FSM (NightSignal)', () {
    test('fires (yellow->red) on a sustained RHR step, recovers after', () {
      // 30 stable nights at 55, then 5 elevated nights at 65, then back to 55.
      final dates = <String>[];
      final rhr = <double?>[];
      // realistic night-to-night RHR spread (~±2 bpm) so MAD is physiological.
      for (var i = 0; i < 30; i++) {
        dates.add('d$i');
        rhr.add(55 + 2.0 * math.sin(i.toDouble())); // wobble in [~53,57]
      }
      for (var i = 0; i < 5; i++) {
        dates.add('e$i');
        rhr.add(65); // sustained elevation
      }
      for (var i = 0; i < 12; i++) {
        dates.add('r$i');
        rhr.add(55); // recovery
      }
      final out = illnessCusum(dates, rhr, h: 4, k: 0.5, persistDays: 2);
      // Pre-step nights are green.
      expect(out[20].state, IllnessState.green);
      // Somewhere in the elevated block it reaches red.
      final elevated = out.sublist(30, 35).map((d) => d.state).toList();
      expect(elevated, contains(IllnessState.red));
      // After return to baseline + decay, it recovers to green.
      expect(out.last.state, IllnessState.green);
    });
    test('never flags without a baseline (no fabrication)', () {
      final out = illnessCusum(['a', 'b', 'c'], [60, 90, 90]);
      expect(out.every((d) => d.state == IllnessState.green), isTrue);
      expect(out.every((d) => d.cusum == null), isTrue);
    });
    test(
        'REGRESSION: a DEGENERATE (zero-dispersion) baseline abstains instead '
        'of standardizing against a fabricated 1 bpm scale', () {
      // 9 identical quantized nights, then a 5 bpm bump. MAD = 0 AND SD = 0, so
      // there is no dispersion at all. The old `max(1.0, SD)` fallback made
      // scale = 1 bpm => z = 5 => cusum 4.5 > h=4 => yellow, red by night 12:
      // a one-night bump latching a sustained "illness" red.
      final rhr = <double?>[...List<double>.filled(9, 55.0), 60.0, 58.0, 58.0];
      final dates = [for (var i = 0; i < rhr.length; i++) 'd$i'];
      final out = illnessCusum(dates, rhr);
      // Before: green×9, then yellow, then RED, RED.
      expect(out.every((d) => d.state == IllnessState.green), isTrue,
          reason: 'no alarm can be raised without a dispersion estimate');
      // Night 9 has a long-enough baseline that is perfectly constant
      // (MAD = 0 AND SD = 0) => abstained, not standardized against 1 bpm.
      expect(out[9].cusum, isNull);
      expect(out[9].z, isNull);
      expect(out[9].need, degenerateBaselineNote);
      // Nights 10-11 gain a real SD once the 60 enters the window, so they are
      // evaluated — but from an honest scale, and they never trip the alarm.
      expect(out[10].z, isNotNull);
      expect(out[10].cusum!, lessThan(4.0));
    });
    test('a merely QUANTIZED baseline (MAD=0 but SD>0) still evaluates', () {
      // MAD collapses on this baseline but SD does not — same convention as
      // wellness/readiness_composite.dart: fall back to SD, only abstain when
      // BOTH are zero.
      final rhr = <double?>[...List<double>.filled(8, 55.0), 56.0, 60.0];
      final dates = [for (var i = 0; i < rhr.length; i++) 'd$i'];
      final out = illnessCusum(dates, rhr);
      expect(out.last.z, isNotNull);
      expect(out.last.cusum, isNotNull);
      expect(out.last.need, isNull);
    });
  });

  group('lnRMSSD readiness stack', () {
    test('suppressed band when tonight drops below mean - SWC', () {
      // 7 nights ln(RMSSD) ~ 4.0, tonight a clear drop.
      final hist = <double>[4.0, 4.05, 3.95, 4.0, 4.1, 3.9, 3.2];
      final m = readinessLnRmssd(hist);
      expect(m.present, isTrue);
      expect(m.value!.band, 'suppressed');
      expect(m.value!.z, lessThan(0));
    });
    test('absent under min nights', () {
      expect(readinessLnRmssd([4.0, 4.1]).present, isFalse);
    });
    test(
        "rolling mean is prior nights only, doesn't include tonight's own value",
        () {
      // 3 identical prior nights + a low tonight. baseline mean should be
      // 4.0 (the prior nights), not 3.5 (which is what you get if tonight's
      // own drop gets averaged into its own comparison baseline).
      final hist = <double>[4.0, 4.0, 4.0, 2.0];
      final m = readinessLnRmssd(hist);
      expect(m.present, isTrue);
      expect(m.value!.rolling7Mean, 4.0);
    });
    test(
        'REGRESSION: an UNDEFINED baseline SD abstains instead of emitting '
        'cvPct 0.0 / band "normal"', () {
      // One prior night => stddev() is null => CV, SWC and the band are
      // undefined. The metric used to publish cvPct 0.0, swc null and
      // band 'normal' anyway: "tonight is typical", asserted from nothing.
      final m = readinessLnRmssd([4.0, 2.0], minNights: 2);
      expect(m.present, isFalse);
      expect(m.value, isNull);
      expect(m.confidence, 0);
      expect(m.note, contains('dispersion undefined'));
      // A DEFINED (even zero) dispersion still computes — CV really is 0 there.
      final flat = readinessLnRmssd([4.0, 4.0, 4.0, 2.0]);
      expect(flat.present, isTrue);
      expect(flat.value!.cvPct, 0.0);
      expect(flat.value!.z, isNull); // z is undefined at SD = 0
      expect(flat.value!.band, 'suppressed');
    });
  });

  group('cosinor', () {
    test('recovers MESOR, amplitude, and acrophase of a known cosine', () {
      // y = 60 + 10*cos(2π t/24 - phase) ; peak at t=18h (acrophase).
      const peakHour = 18.0;
      final t = <double>[];
      final y = <double>[];
      for (var h = 0; h < 48; h++) {
        t.add(h.toDouble());
        y.add(60 + 10 * math.cos(2 * math.pi * (h - peakHour) / 24));
      }
      final m = cosinor(t, y);
      final f = m.value!;
      expect(f.mesor, closeTo(60, 1e-6));
      expect(f.amplitude, closeTo(10, 1e-6));
      expect(f.acrophaseHours, closeTo(peakHour, 1e-4));
      expect(f.r2, closeTo(1.0, 1e-9));
    });
    test('low R² on pure noise-like alternating signal', () {
      final t = <double>[for (var i = 0; i < 24; i++) i.toDouble()];
      final y = <double>[for (var i = 0; i < 24; i++) i.isEven ? 1.0 : -1.0];
      final m = cosinor(t, y);
      expect(m.value!.r2, lessThan(0.2));
    });
    test('REGRESSION: 4 random points never score a confident circadian fit',
        () {
      // A 3-parameter fit (M, β, γ) on 4 points has ONE residual degree of
      // freedom: 4 random points scored raw r² 0.76–0.99 and were published at
      // confidence 0.95, tier HIGH. Now: refused outright (< cosinorMinPoints).
      final rnd = math.Random(20260726);
      for (var trial = 0; trial < 200; trial++) {
        final t = <double>[0, 6, 12, 18];
        final y = <double>[for (var i = 0; i < 4; i++) rnd.nextDouble()];
        final m = cosinor(t, y);
        expect(m.present, isFalse);
        expect(m.confidence, 0);
      }
    });
    test('REGRESSION: confidence comes from the ADJUSTED R² (3 fitted params)',
        () {
      // 8 points of noise: raw R² is upward-biased, adjusted R² is not.
      final rnd = math.Random(4242);
      final t = <double>[for (var i = 0; i < 8; i++) i * 3.0];
      final y = <double>[for (var i = 0; i < 8; i++) rnd.nextDouble()];
      final m = cosinor(t, y);
      expect(m.present, isTrue);
      expect(m.value!.r2Adj, lessThan(m.value!.r2));
      expect(m.confidence, closeTo(m.value!.r2Adj.clamp(0.1, 0.95), 1e-12));
      // A genuine 24-h rhythm still earns full confidence.
      final tt = <double>[for (var h = 0; h < 48; h++) h.toDouble()];
      final yy = <double>[
        for (var h = 0; h < 48; h++) 60 + 10 * math.cos(2 * math.pi * h / 24)
      ];
      final good = cosinor(tt, yy);
      expect(good.value!.r2Adj, closeTo(1.0, 1e-6));
      expect(good.confidence, 0.95);
    });
  });

  group('TRIMP + CTL/ATL/TSB', () {
    test('Banister TRIMP needs anchors; produces positive load', () {
      final none =
          banisterTrimp([120, 130], restingHr: null, maxHr: 190, sex: Sex.male);
      expect(none.present, isFalse);
      final m = banisterTrimp([120, 140, 160],
          restingHr: 50, maxHr: 190, sex: Sex.male);
      expect(m.value!, greaterThan(0));
    });

    test(
        'REGRESSION: ONE Banister implementation, matching the published '
        'sex-specific y = c·e^(b·x)', () {
      // The two implementations in this file disagreed by 1.5625× (the
      // top-level one dropped the 0.64/0.86 coefficient entirely) and the
      // StrainScorer one applied the MALE 0.64 to women (−26% on female load).
      const x = (150.0 - 50.0) / (190.0 - 50.0); // 0.714286 %HRR
      final expectedMale = x * 0.64 * math.exp(1.92 * x);
      final expectedFemale = x * 0.86 * math.exp(1.67 * x);

      final male =
          banisterTrimp([150], restingHr: 50, maxHr: 190, sex: Sex.male);
      final female =
          banisterTrimp([150], restingHr: 50, maxHr: 190, sex: Sex.female);
      expect(male.value!, closeTo(expectedMale, 1e-9));
      expect(female.value!, closeTo(expectedFemale, 1e-9));
      // 1 min at 150 bpm (RHR 50, HRmax 190): 1.8016 male / 2.0250 female.
      // Before: 2.8150 from the top-level fn (no c at all) and 1.5070 from
      // StrainScorer for a woman (male c on the female b).
      expect(male.value!, closeTo(1.801589, 1e-5));
      expect(female.value!, closeTo(2.024984, 1e-5));

      // The StrainScorer path agrees exactly with the top-level one.
      expect(StrainScorer.banisterTRIMP([150], 50, 140, [1.0], female: false),
          closeTo(male.value!, 1e-12));
      expect(StrainScorer.banisterTRIMP([150], 50, 140, [1.0], female: true),
          closeTo(female.value!, 1e-12));
      expect(StrainScorer.banisterY(x, female: false),
          closeTo(0.64 * math.exp(1.92 * x), 1e-12));
      expect(StrainScorer.banisterY(x, female: true),
          closeTo(0.86 * math.exp(1.67 * x), 1e-12));
    });
    test('CTL>ATL after a long steady block, then ATL spikes on a hard day',
        () {
      final steady = <double>[for (var i = 0; i < 60; i++) 50.0];
      final base = ctlAtlTsb(steady);
      // both converge to ~50, TSB ~ 0.
      expect(base.value!.ctl, closeTo(50, 1.0));
      expect(base.value!.tsb.abs(), lessThan(1.0));
      // append one very hard day -> ATL jumps above CTL -> negative TSB.
      final spiked = [...steady, 300.0];
      final s = ctlAtlTsb(spiked);
      expect(s.value!.atl, greaterThan(s.value!.ctl));
      expect(s.value!.tsb, lessThan(0));
    });

    test(
        'REGRESSION: one training day does NOT fabricate 42 days of chronic '
        'load', () {
      // ctlAtlTsb([500]) used to seed BOTH accumulators at dailyTrimp.first →
      // ctl 500, atl 500, tsb 0.0: a fully-adapted, perfectly-fresh athlete
      // conjured from a single workout.
      final one = ctlAtlTsb([500.0]);
      expect(one.present, isFalse);
      expect(one.value, isNull);
      expect(one.confidence, 0);
      expect(one.note, 'need_baseline:have=1,need=$ctlAtlMinDays');
      // Still absent one day short of the minimum...
      expect(ctlAtlTsb(List<double>.filled(ctlAtlMinDays - 1, 50.0)).present,
          isFalse);
      // ...and present at the minimum.
      expect(
          ctlAtlTsb(List<double>.filled(ctlAtlMinDays, 50.0)).present, isTrue);
    });

    test('REGRESSION: the seed is a week of observed load, not day one', () {
      // A single huge opening day must not become the chronic baseline.
      final hist = <double>[600.0, for (var i = 0; i < 20; i++) 0.0];
      final m = ctlAtlTsb(hist);
      expect(m.present, isTrue);
      // Prime = mean of the first 7 days = 600/7 ≈ 85.7, then 14 rest days
      // decay it — nowhere near the old ctl≈600 anchor.
      expect(m.value!.ctl, lessThan(90));
      expect(m.value!.atl, lessThan(m.value!.ctl));
    });
  });

  group('display heart-rate zones', () {
    test('builds Tanaka %HRmax zones and includes HRmax in zone 5', () {
      final zones = HeartRateZones.zones(age: 40);
      expect(zones.source, 'tanaka');
      expect(zones.maxHr, closeTo(180.0, 1e-9));
      expect(zones.zoneNumber(89.9), 0);
      expect(zones.zoneNumber(90.0), 1);
      expect(zones.zoneNumber(108.0), 2);
      expect(zones.zoneNumber(180.0), 5);
    });

    test('accumulates duration until next sample and rounds to zone minutes',
        () {
      final zoneSet = HeartRateZones.zonesFromMaxHr(200);
      final time = HeartRateZones.timeInZone([
        const HrSample(0, 110), // z1 for 60 s
        const HrSample(60000, 130), // z2 for 60 s
        const HrSample(120000, 150), // z3 for 60 s
        const HrSample(180000, 170), // z4 for 60 s
        const HrSample(240000, 190), // z5 for tail median 60 s
      ], zoneSet);
      expect(time.secondsInZone(1), closeTo(60, 1e-9));
      expect(time.secondsInZone(2), closeTo(60, 1e-9));
      expect(time.secondsInZone(3), closeTo(60, 1e-9));
      expect(time.secondsInZone(4), closeTo(60, 1e-9));
      expect(time.secondsInZone(5), closeTo(60, 1e-9));
      expect(time.toRoundedMinuteMap(),
          {'z1': 1, 'z2': 1, 'z3': 1, 'z4': 1, 'z5': 1});
    });

    test('caps pathological gaps at the median plausible interval', () {
      final zoneSet = HeartRateZones.zonesFromMaxHr(200);
      final time = HeartRateZones.timeInZone([
        const HrSample(0, 130), // z2
        const HrSample(1000, 150), // z3
        const HrSample(2000, 190), // z5, next gap huge
        const HrSample(700000, 190), // huge gap capped to 1 s
      ], zoneSet);
      expect(time.secondsInZone(2), closeTo(1, 1e-9));
      expect(time.secondsInZone(3), closeTo(1, 1e-9));
      expect(time.secondsInZone(5), closeTo(2, 1e-9));
    });
  });

  group('robust nocturnal RMSSD (median-of-5min-windows)', () {
    test('robust RMSSD tracks the stable level while whole-night is inflated',
        () {
      // Build ~40 min of NN at 1 beat/s. Mostly a stable RR ~1000 ms with small
      // ±8 ms beat-to-beat wobble (RMSSD ~tens of ms). Inject a few high-variance
      // bursts (REM/arousal-like) that whipsaw RR by ±250 ms — these inflate a
      // single whole-night RMSSD but should NOT dominate the median-of-windows.
      final nn = <double>[];
      final times = <double>[];
      var t = 0.0;
      for (var i = 0; i < 2400; i++) {
        // 8 consecutive 5-min windows (~300 beats each at ~1 s RR). Mark TWO of
        // the eight windows (idx 2 and 5) as high-variance REM/arousal bursts;
        // the other six are stable. A whole-night RMSSD is dragged up by the two
        // bursts, but the MEDIAN of eight window RMSSDs picks a stable window.
        final win = i ~/ 300;
        final inBurst = win == 2 || win == 5;
        final base = 1000.0;
        // Both parts are OSCILLATIONS, not alternations: a perfectly
        // alternating series has diff-ACF1 = −1, which the jitter floor now
        // (correctly) refuses as pure beat-timing noise, and no real arousal
        // burst looks like that.
        final v = inBurst
            ? base + 250.0 * math.sin(2 * math.pi * i / 4) // fast ±250 ms swing
            : base + 16.0 * math.sin(2 * math.pi * i / 12);
        nn.add(v);
        t += v;
        times.add(t);
      }
      final whole = hrvTime(nn).value!.rmssd!;
      final robust = nocturnalRmssd(nn, times).value!;
      // Whole-night RMSSD is dragged way up by the bursts.
      expect(whole, greaterThan(100),
          reason: 'whole-night RMSSD inflated by bursts');
      // The stable wobble RMSSD ≈ 8 ms; robust median stays low.
      expect(robust, lessThan(40),
          reason: 'median-of-windows is robust to a few burst windows');
      expect(robust, lessThan(whole / 3),
          reason: 'robust << whole-night when bursts are present');
    });

    test('stage mask keeps only NREM windows', () {
      final nn = <double>[];
      final times = <double>[];
      var t = 0.0;
      for (var i = 0; i < 1200; i++) {
        // Slow oscillation, not an alternation — see the burst test above.
        nn.add(1000.0 + 10.0 * math.sin(2 * math.pi * i / 12));
        t += nn.last;
        times.add(t);
      }
      // Mask out the entire first 5-min window (mark as wake/false), keep rest.
      final mask = List<bool>.filled(1300, true);
      for (var s = 0; s < 300; s++) {
        mask[s] = false;
      }
      final m = nocturnalRmssd(nn, times, stageMaskPerSec: mask);
      expect(m.present, isTrue);
      expect(m.note, contains('PRV not ECG'));
    });

    test('absent without enough beats', () {
      expect(nocturnalRmssd([800, 810], [800, 1610]).present, isFalse);
    });
  });

  group('sleep-session nightly RMSSD (mean of cleaned 5-min windows)', () {
    test('matches the arithmetic mean of per-window RMSSDs', () {
      final rr = <double>[];
      final ts = <double>[];
      var beatTsMs = 0.0;

      void addWindow(List<double> vals, double startTsMs) {
        beatTsMs = startTsMs;
        for (final v in vals) {
          rr.add(v);
          ts.add(beatTsMs);
          beatTsMs += 1000.0;
        }
      }

      addWindow([1000, 1010, 990], 1000.0); // bucket 0, RMSSD = 15.8113883...
      addWindow([1000, 1050, 950], 301000.0); // bucket 1, RMSSD = 79.0569415...

      final m = sleepSessionWindowedRmssd(
        rr,
        ts,
        startSec: 1,
        endSec: 601,
        windowSec: 300,
      );
      expect(m.present, isTrue);
      expect(m.value, closeTo((15.8113883 + 79.0569415) / 2.0, 1e-6));
    });

    test('drops out-of-range and Malik-style ectopic beats before RMSSD', () {
      final rr = <double>[1000, 1000, 200, 1000, 1000];
      final ts = <double>[1000, 2000, 3000, 4000, 5000];
      final m = sleepSessionWindowedRmssd(rr, ts, startSec: 1, endSec: 301);
      expect(m.present, isTrue);
      expect(m.value, closeTo(0.0, 1e-9));
    });

    test('HRV-02: no difference is manufactured across a REJECTED beat', () {
      // The window cleaner compacts, so differencing straight down its output
      // spanned every rejected beat with one invented difference. Here the two
      // sides of the ectopic sit 100 ms apart, so the seam Δ is 100 ms while
      // every real Δ is 0. THIS is most of the "gen5 reads 2x gen4" gap: on the
      // real corpus it inflated the nightly headline by 51-102 % on MG
      // (87.7 -> 58.2, 82.9 -> 53.0, 76.9 -> 48.4 ms) and 2-13 % on gen4.
      final rr = <double>[900, 900, 900, 200, 1000, 1000, 1000];
      final ts = <double>[for (var i = 0; i < 7; i++) 1000.0 + i * 1000.0];
      final m = sleepSessionWindowedRmssd(rr, ts, startSec: 1, endSec: 301);
      expect(m.present, isTrue);
      expect(m.value, closeTo(0.0, 1e-9),
          reason: '2 runs of flat beats, no seam difference');
    });

    test('HRV-02: the nightly headline is ABSENT on a jitter-dominated night',
        () {
      // WHOOP 5 measures ACF1 -0.50/-0.51 on this series even after the
      // window cleaner, so the headline 111.8 / 118.7 ms was noise. Absent
      // beats plausible: readiness treats a null HRV driver as absent.
      final rnd = math.Random(11);
      final rr = <double>[
        for (var i = 0; i < 900; i++) 1000 + (rnd.nextDouble() - 0.5) * 120
      ];
      final ts = <double>[for (var i = 0; i < 900; i++) 1000.0 + i * 1000.0];
      final m = sleepSessionWindowedRmssd(rr, ts, startSec: 1, endSec: 1801);
      expect(m.present, isFalse);
      expect(m.note, contains('rmssd_refused:acf1='));
    });
  });

  // The CALIBRATION of this scale (what a rest / active / hard / maximal day
  // scores) lives in strain_calibration_test.dart, asserted on real days rather
  // than on the formula restated. This group keeps only the mechanical
  // properties of the map itself.
  group('strain score (0-21 map of TRIMP above the waking baseline)', () {
    test('subtracts the quiet-waking baseline for the observed wake window',
        () {
      // 960 waking minutes accrue ~180 TRIMP just by being awake at 0.20 HRR.
      // Charging that as effort is what put an inactive day at 12.8/21.
      expect(baselineTrimp(960, quietHrr: quietWakingHrr), closeTo(180.4, 0.5));
      expect(strainScore(180.0, wakeMinutes: 960, quietHrr: quietWakingHrr),
          0.0);
      // Half the wear window, half the allowance.
      expect(baselineTrimp(480, quietHrr: quietWakingHrr),
          closeTo(baselineTrimp(960, quietHrr: quietWakingHrr) / 2, 1e-9));
      // A higher personal quiet level costs more allowance, always.
      expect(baselineTrimp(960, quietHrr: 0.274),
          greaterThan(baselineTrimp(960, quietHrr: 0.20)));
      // And no caller can hand over one that eats a day's training whole.
      expect(baselineTrimp(960, quietHrr: 0.9),
          closeTo(baselineTrimp(960, quietHrr: maxQuietHrr), 1e-9));
    });

    test('is monotone, floored at 0 and capped at 21', () {
      expect(strainScore(0, wakeMinutes: 960, quietHrr: quietWakingHrr),
          closeTo(0.0, 1e-9));
      expect(strainScore(1e9, wakeMinutes: 960, quietHrr: quietWakingHrr),
          closeTo(21.0, 1e-9));
      expect(
        strainScore(300, wakeMinutes: 960, quietHrr: quietWakingHrr) <
            strainScore(400, wakeMinutes: 960, quietHrr: quietWakingHrr),
        isTrue,
      );
    });

    test('strainScoreMetric is EST tier and absent without any input', () {
      final m =
          strainScoreMetric(392.9, wakeMinutes: 960, quietHrr: quietWakingHrr);
      expect(m.present, isTrue);
      expect(m.tier, 'ESTIMATE');
      expect(
          strainScoreMetric(null, wakeMinutes: 960, quietHrr: quietWakingHrr)
              .present,
          isFalse);
      expect(
          strainScoreMetric(335, wakeMinutes: null, quietHrr: quietWakingHrr)
              .present,
          isFalse);
      expect(strainScoreMetric(335, wakeMinutes: 960, quietHrr: null).present,
          isFalse);
    });

    test('a non-finite input never produces a PRESENT strain', () {
      // EVERY range check in strainScoreMetric is false for NaN (`NaN < 0`,
      // `NaN <= 0`, `NaN > 0.40` — all false), so a NaN used to walk straight
      // through into a present metric carrying a NaN value. That is worse than
      // an absent one: everything downstream treats present as measured.
      for (final m in [
        strainScoreMetric(double.nan,
            wakeMinutes: 960, quietHrr: quietWakingHrr),
        strainScoreMetric(double.infinity,
            wakeMinutes: 960, quietHrr: quietWakingHrr),
        strainScoreMetric(392.9,
            wakeMinutes: double.nan, quietHrr: quietWakingHrr),
        strainScoreMetric(392.9,
            wakeMinutes: double.infinity, quietHrr: quietWakingHrr),
        strainScoreMetric(392.9, wakeMinutes: 960, quietHrr: double.nan),
        strainScoreMetric(392.9, wakeMinutes: 960, quietHrr: double.infinity),
      ]) {
        expect(m.present, isFalse);
        expect(m.value, isNull);
        expect(m.note, isNotEmpty, reason: 'absent needs a debuggable reason');
      }

      // REFUSED, not clamped. A quiet level above ACSM's moderate floor is a
      // broken measurement; baselineTrimp would silently pull it back to
      // maxQuietHrr and score the day against a level nobody measured.
      expect(
          strainScoreMetric(392.9, wakeMinutes: 960, quietHrr: maxQuietHrr)
              .present,
          isTrue);
      expect(
          strainScoreMetric(392.9,
                  wakeMinutes: 960, quietHrr: maxQuietHrr + 0.01)
              .present,
          isFalse);
    });

    test('non-finite anchors and samples never reach a number', () {
      final hr = List<double>.filled(120, 90.0);
      // `maxHr <= restingHr` is false when either is NaN, so the finiteness
      // check is the only thing standing between a NaN anchor and a NaN result.
      for (final (rhr, hrMax) in [
        (double.nan, 187.0),
        (55.0, double.nan),
        (55.0, double.infinity),
        (double.infinity, 187.0),
      ]) {
        expect(dailyQuietWakingHrr(hr, restingHr: rhr, maxHr: hrMax), isNull,
            reason: 'quiet level for rhr=$rhr hrmax=$hrMax');
        expect(
            banisterTrimp(hr, restingHr: rhr, maxHr: hrMax, sex: Sex.male)
                .present,
            isFalse,
            reason: 'TRIMP for rhr=$rhr hrmax=$hrMax');
      }

      // +infinity passes `hr > 0` and clamps to 1.0 — a garbage sample read as
      // a maximal-effort minute. Dropped now, so it moves neither the median
      // nor the TRIMP sum.
      final dirty = [...hr, ...List<double>.filled(200, double.infinity)];
      expect(dailyQuietWakingHrr(dirty, restingHr: 55, maxHr: 187),
          dailyQuietWakingHrr(hr, restingHr: 55, maxHr: 187));
      expect(banisterTrimp(dirty, restingHr: 55, maxHr: 187, sex: Sex.male).value,
          banisterTrimp(hr, restingHr: 55, maxHr: 187, sex: Sex.male).value);
      // Nothing measurable left once they are dropped.
      expect(
          dailyQuietWakingHrr(List<double>.filled(120, double.infinity),
              restingHr: 55, maxHr: 187),
          isNull);
    });
  });

  group('StrainScorer (Banister TRIMP → 0–100)', () {
    test('trimpToStrain pins: 0→0, 7200→~100, monotone, 2dp', () {
      expect(StrainScorer.trimpToStrain(0), 0.0);
      // ln(7201)/ln(7201)=1 → 100.
      expect(StrainScorer.trimpToStrain(7200), closeTo(100.0, 1e-9));
      expect(StrainScorer.trimpToStrain(100) < StrainScorer.trimpToStrain(335),
          isTrue);
      // Rounded to 2 decimals.
      final v = StrainScorer.trimpToStrain(123.456);
      expect((v * 100).round() / 100, v);
    });

    test('REGRESSION: trimpToStrain is CLAMPED to maxStrain', () {
      // Docstring says "Map accumulated TRIMP onto [0, 100]" but nothing
      // clamped: 14400 → 107.8. (The sibling strainScore() always clamped.)
      expect(StrainScorer.trimpToStrain(14400), 100.0);
      expect(StrainScorer.trimpToStrain(1e9), StrainScorer.maxStrain);
      expect(StrainScorer.trimpToStrain(7200), closeTo(100.0, 1e-9));
      // Below the ceiling nothing changed.
      expect(StrainScorer.trimpToStrain(335), lessThan(100.0));
    });

    test(
        'REGRESSION: strain integrates PER-SAMPLE durations, not the first '
        'inter-sample gap applied to everything', () {
      const bpmv = 150.0;
      // (a) 21 samples over 20 min whose FIRST two are 1 s apart — exactly the
      // sparse stream minSparseReadings admits. sampleDuration was 1 s for all
      // 21 samples → strain 8.08 instead of ~47.
      final tsIrregular = <double>[
        0,
        1,
        for (var i = 1; i < 20; i++) 1 + i * 63.1
      ];
      final bpm21 = List<double>.filled(21, bpmv);
      final irregular =
          StrainScorer.strain(bpm21, tsIrregular, maxHR: 190, restingHR: 50)!;
      final uniform = StrainScorer.strain(
          bpm21, [for (var i = 0; i < 21; i++) i * 60.0],
          maxHR: 190, restingHR: 50)!;
      expect(irregular, greaterThan(40.0));
      expect(irregular, closeTo(uniform, 3.0),
          reason: 'same HR over the same wall-clock span → similar strain');

      // (b) The inverse: 700 samples at 1 Hz behind a 300 s leading gap. The
      // 5-min first gap became every sample's duration → strain 104.25.
      final tsGap = <double>[0, for (var i = 0; i < 699; i++) 300.0 + i];
      final gapped = StrainScorer.strain(List<double>.filled(700, bpmv), tsGap,
          maxHR: 190, restingHR: 50)!;
      final dense = StrainScorer.strain(List<double>.filled(700, bpmv),
          [for (var i = 0; i < 700; i++) i.toDouble()],
          maxHR: 190, restingHR: 50)!;
      expect(gapped, lessThanOrEqualTo(StrainScorer.maxStrain));
      expect(gapped, closeTo(dense, 1.0),
          reason: 'a hole in the stream is not elapsed effort');
      expect(gapped, lessThan(60.0));

      // Per-sample durations: gaps capped at the median cadence, tail gets it.
      final durs = StrainScorer.sampleDurationsMinutes(tsGap);
      expect(durs.length, 700);
      expect(durs.first, closeTo(1 / 60.0, 1e-12));
      expect(durs.reduce(math.max), closeTo(1 / 60.0, 1e-12));
    });

    test('MOT-11: no HRmax → no number, not a 220−age stand-in', () {
      // `strain` used to fall back to defaultMaxHR() = 190 — a 30 y/o's
      // ceiling applied to whoever's wrist arrived. The perimeter caught it;
      // the source now does.
      final bpm = List<double>.filled(700, 150.0);
      final ts = [for (var i = 0; i < 700; i++) i.toDouble()];
      expect(StrainScorer.strain(bpm, ts, maxHR: null), isNull);
      expect(StrainScorer.strain(bpm, ts, maxHR: 190), isNotNull);
    });

    test('Banister monotonic increasing in intensity', () {
      // Two same-length streams, one strictly higher HR → more Banister TRIMP.
      final lo = List<double>.filled(30, 100.0);
      final hi = List<double>.filled(30, 150.0);
      final ts = [for (var i = 0; i < 30; i++) i.toDouble()];
      // API change: TRIMP now integrates PER-SAMPLE durations, and the
      // Banister sex is selected by name (b and its scale must stay paired).
      final durs = StrainScorer.sampleDurationsMinutes(ts);
      final tLo = StrainScorer.banisterTRIMP(lo, 50, 150, durs);
      final tHi = StrainScorer.banisterTRIMP(hi, 50, 150, durs);
      expect(tHi, greaterThan(tLo));
    });

    test('Tanaka HRmax = 208 − 0.7·age', () {
      expect(StrainScorer.tanakaHRmax(30), closeTo(187.0, 1e-9));
      expect(StrainScorer.tanakaHRmax(40), closeTo(180.0, 1e-9));
    });

    test('estimateHRmax: observed≥600 wins over Tanaka, else Tanaka', () {
      // <600 samples → Tanaka.
      final (h1, src1) = StrainScorer.estimateHRmax([180, 185], 30);
      expect(src1, 'tanaka');
      expect(h1, closeTo(187.0, 1e-9));
      // ≥600 samples with a high observed 99.5pct (>Tanaka) → observed.
      final hist = [for (var i = 0; i < 700; i++) 100.0 + (i % 100)];
      final (h2, src2) = StrainScorer.estimateHRmax(hist, 30);
      expect(src2, 'observed');
      expect(h2, greaterThan(StrainScorer.tanakaHRmax(30)));
    });

    test('gating: too few samples → null; spanning ≥600s with ≥20 → computes',
        () {
      // 30 samples but spanning only 30s → fails sparse-span gate → null.
      final ts30 = [for (var i = 0; i < 30; i++) i.toDouble()];
      expect(
          StrainScorer.strain(List<double>.filled(30, 150), ts30,
              maxHR: 190, restingHR: 50),
          isNull);
      // 20 samples spanning 600s → qualifies.
      final tsSpan = [for (var i = 0; i < 20; i++) i * 32.0]; // 19*32=608s
      final s = StrainScorer.strain(List<double>.filled(20, 150), tsSpan,
          maxHR: 190, restingHR: 50);
      expect(s, isNotNull);
    });

    test('maxHR ≤ restingHR → null (invalid HRR)', () {
      final ts = [for (var i = 0; i < 700; i++) i.toDouble()];
      expect(
          StrainScorer.strain(List<double>.filled(700, 100), ts,
              maxHR: 50, restingHR: 60),
          isNull);
    });

    test(
        'trimpStrain envelope: present/ESTIMATE on enough data, absent otherwise',
        () {
      final ts = [for (var i = 0; i < 700; i++) i.toDouble()];
      final m = trimpStrain(List<double>.filled(700, 140), ts,
          maxHr: 190, restingHr: 50);
      expect(m.present, isTrue);
      expect(m.tier, 'ESTIMATE');
      expect(m.value!, greaterThan(0));
      final absent = trimpStrain([100, 110], [0, 1], maxHr: 190, restingHr: 50);
      expect(absent.present, isFalse);
      expect(absent.confidence, 0);
    });

    test(
        'trimpStrain is absent (not fabricated) when maxHr or restingHr is missing',
        () {
      final ts = [for (var i = 0; i < 700; i++) i.toDouble()];
      final bpm = List<double>.filled(700, 140);
      final noMax = trimpStrain(bpm, ts, restingHr: 50);
      expect(noMax.present, isFalse);
      expect(noMax.confidence, 0);
      final noResting = trimpStrain(bpm, ts, maxHr: 190);
      expect(noResting.present, isFalse);
      expect(noResting.confidence, 0);
    });
  });

  group('baseline-need signals (need_baseline convention)', () {
    test('readinessLnRmssd: 1 night -> absent + need note; >=min computes', () {
      final one = readinessLnRmssd([3.5]);
      expect(one.present, isFalse);
      expect(one.confidence, 0);
      expect(one.note, 'need_baseline:have=1,need=$readinessLnRmssdMinNights');
      final enough = readinessLnRmssd(List<double>.generate(
          readinessLnRmssdMinNights, (i) => 3.5 + i * 0.01));
      expect(enough.present, isTrue);
    });

    test('illnessCusum: short baseline night carries need note; then evaluates',
        () {
      final n = 12;
      final dates = [for (var i = 0; i < n; i++) 'd$i'];
      final rhr = [for (var i = 0; i < n; i++) 55.0 + (i.isEven ? 0.0 : 1.0)];
      final days = illnessCusum(dates, rhr);
      // First night: have=0 baseline, need=7.
      expect(
          days[0].need, 'need_baseline:have=0,need=$illnessCusumMinBaseline');
      expect(days[0].cusum, isNull);
      // A night past the minimum baseline is evaluated (no need note).
      expect(days[illnessCusumMinBaseline].need, isNull);
      expect(days[illnessCusumMinBaseline].cusum, isNotNull);
    });
  });

  // -------------------------------------------- Baevsky Stress Index (#6)
  group('baevskyStressIndex — direct coverage', () {
    test('too few clean beats → honest absent', () {
      final m =
          baevskyStressIndex(<double>[for (var i = 0; i < 10; i++) 900.0]);
      expect(m.present, isFalse);
      expect(m.value, isNull);
      expect(m.tier, Tier.estimate);
      expect(m.note, contains('30 clean beats'));
    });

    test('a narrow, near-regular RR distribution yields a finite SI + band',
        () {
      // ~300 beats around 900 ms with small bounded variation → a well-defined
      // mode and a non-zero MxDMn, so SI is finite (not the degenerate ÷0 case).
      final nn = <double>[
        for (var i = 0; i < 300; i++) 900.0 + 15.0 * math.sin(i.toDouble())
      ];
      final m = baevskyStressIndex(nn);
      expect(m.present, isTrue);
      expect(m.tier, Tier.estimate);
      final v = m.value!;
      expect(v.si, greaterThan(0));
      expect(v.si.isFinite, isTrue);
      expect(v.modeS, greaterThan(0));
      expect(v.mxdmnS, greaterThan(0));
      expect(['low', 'normal', 'elevated', 'high'], contains(v.level));
      expect(v.toJson()['si'], isNotNull);
    });

    test('a constant RR series has zero range → no valid SI window (absent)',
        () {
      // MxDMn = 0 makes SI degenerate; the impl must return absent, never ∞/0.
      final m =
          baevskyStressIndex(<double>[for (var i = 0; i < 300; i++) 900.0]);
      expect(m.present, isFalse);
      expect(m.value, isNull);
    });

    test(
        'REGRESSION: a NEAR-degenerate RR range abstains instead of reporting '
        'SI 48780 / "high"', () {
      // 300 beats alternating 1000/1001 ms — plausible 1 Hz beat-timing
      // quantization at a steady sleeping HR. The guard was only mxdmnS <= 0,
      // so MxDMn = 0.001 s blew the 1/MxDMn denominator up to si 48780,
      // level 'high'.
      final nn = <double>[
        for (var i = 0; i < 300; i++) i.isEven ? 1000.0 : 1001.0
      ];
      final m = baevskyStressIndex(nn);
      expect(m.present, isFalse);
      expect(m.value, isNull);
      expect(m.confidence, 0);
      // A genuinely varying series of the same length still computes.
      final ok = baevskyStressIndex(<double>[
        for (var i = 0; i < 300; i++) 900.0 + 15.0 * math.sin(i.toDouble())
      ]);
      expect(ok.present, isTrue);
    });
  });

  group('cardiac coherence (McCraty & Zayas 2014)', () {
    // Synthesize ~2.5 min of RR cleanly modulated at 5.5 breaths/min
    // (0.0917 Hz) — the guided resonance-breathing pace this feature targets.
    List<double> pacedRr({double amplitudeMs = 60, int nBeats = 180}) {
      final rr = <double>[];
      var t = 0.0;
      for (var i = 0; i < nBeats; i++) {
        final v =
            900 + amplitudeMs * math.sin(2 * math.pi * 0.0917 * (t / 1000));
        rr.add(v);
        t += v;
      }
      return rr;
    }

    List<double> beatTimes(List<double> rr) {
      final times = <double>[];
      var t = 0.0;
      for (final v in rr) {
        t += v;
        times.add(t);
      }
      return times;
    }

    test(
        'finds the peak at the guided pace and reports a high ratio/score on a clean paced signal',
        () {
      final rr = pacedRr();
      final times = beatTimes(rr);
      final m = cardiacCoherence(rr, times, pacedHz: 0.0917);
      expect(m.present, isTrue);
      expect(m.tier, Tier.estimate);
      final v = m.value!;
      // Peak should land within Lomb-Scargle grid resolution of 0.0917 Hz.
      expect(v.peakHz, closeTo(0.0917, 0.01));
      expect(v.ratio, greaterThan(1)); // a single clean oscillation dominates
      expect(v.score, greaterThan(50));
      expect(v.score, lessThanOrEqualTo(100));
      expect(m.note, contains('matches guided pace'));
    });

    test(
        'a noisy, unpaced tachogram yields a lower ratio/score than the clean paced one',
        () {
      final rng = math.Random(7);
      final noisyRr = <double>[
        for (var i = 0; i < 180; i++) 900 + (rng.nextDouble() - 0.5) * 200,
      ];
      final noisyTimes = beatTimes(noisyRr);
      final noisy = cardiacCoherence(noisyRr, noisyTimes, pacedHz: 0.0917);

      final cleanRr = pacedRr();
      final cleanTimes = beatTimes(cleanRr);
      final clean = cardiacCoherence(cleanRr, cleanTimes, pacedHz: 0.0917);

      expect(noisy.present, isTrue);
      expect(clean.present, isTrue);
      expect(noisy.value!.ratio, lessThan(clean.value!.ratio));
      expect(noisy.value!.score, lessThan(clean.value!.score));
    });

    test('absent on too few beats', () {
      final rr = pacedRr(nBeats: 10);
      final m = cardiacCoherence(rr, beatTimes(rr));
      expect(m.present, isFalse);
      expect(m.value, isNull);
      expect(m.confidence, 0);
    });

    test('absent on a span under 30s even with enough beats', () {
      // 25 beats at ~1s each ≈ 25s span — plenty of beats, too short a window.
      final rr = <double>[for (var i = 0; i < 25; i++) 1000.0];
      final m = cardiacCoherence(rr, beatTimes(rr));
      expect(m.present, isFalse);
      expect(m.note, contains('too short'));
    });

    test('never fabricates: absent stays absent regardless of pacedHz', () {
      final m = cardiacCoherence(<double>[800], <double>[800], pacedHz: 0.0917);
      expect(m.present, isFalse);
      expect(m.value, isNull);
      expect(m.confidence, 0);
    });
  });

  group('trailing windows are CALENDAR days, not rows', () {
    test('a wear gap breaks the illness CUSUM persistence run', () {
      // T-14 / B-01. `persistDays: 2` used to mean two RECORDED nights, and the
      // caller only passes days that produced a derived row — so an elevated
      // Monday and an elevated night three weeks later escalated to red
      // "sustained elevation". The 28-day baseline stretched over months the
      // same way.
      final dates = <String>[];
      final rhr = <double?>[];
      for (var i = 1; i <= 20; i++) {
        dates.add('2026-06-${i.toString().padLeft(2, '0')}');
        rhr.add(55.0 + (i % 3));
      }
      dates.add('2026-06-21');
      rhr.add(75.0); // elevated
      dates.add('2026-07-14');
      rhr.add(75.0); // elevated, but 23 days later

      final out = illnessCusum(dates, rhr);
      expect(out[20].state, IllnessState.yellow);
      expect(out[21].state, IllnessState.green,
          reason: 'pre-fix: red, "sustained elevation" across a 3-week gap');
      // And with no recent baseline left, it says so rather than scoring.
      expect(out[21].cusum, isNull);
      expect(out[21].need, contains('need_baseline'));
    });

    test('a wear gap clears the ACCUMULATOR, not just the run counters', () {
      // an-clinical-2. The gap guard zeroed yellowRun/normalRun but cusum is a
      // loop-external accumulator, so an episode's charge survived an
      // arbitrarily long gap: 5 illness nights, 70 days off-wrist, then the
      // first scorable night back fired yellow at cusum 28.55 on a night
      // measured z = -0.12 BELOW baseline — health_screen rendered that as
      // "tracking above your own baseline, 0.1 standardised deviations below
      // it". A CUSUM is evidence accumulated over CONSECUTIVE observations;
      // across a gap there are none, so there is nothing to carry.
      String d(int dayOffset) => DateTime.utc(2026, 1, 1)
          .add(Duration(days: dayOffset))
          .toIso8601String()
          .substring(0, 10);
      final dates = <String>[];
      final rhr = <double?>[];
      var off = 0;
      for (var i = 0; i < 30; i++) {
        dates.add(d(off++));
        rhr.add(55 + 2.0 * math.sin(i.toDouble()));
      }
      for (var i = 0; i < 5; i++) {
        dates.add(d(off++));
        rhr.add(64); // illness episode: ends red with a large accumulator
      }
      off += 70; // 70-day wear gap
      for (var i = 0; i < 14; i++) {
        dates.add(d(off++));
        rhr.add(55 + 2.0 * math.sin(i.toDouble())); // fully normal nights
      }
      final out = illnessCusum(dates, rhr);
      expect(
          out.sublist(30, 35).map((e) => e.state), contains(IllnessState.red),
          reason: 'the episode itself must still fire');
      final back = out.sublist(35);
      // Every night back is green, and the first one that CAN be scored starts
      // from a cleared accumulator rather than 28.55.
      expect(back.every((e) => e.state == IllnessState.green), isTrue);
      final firstScored = back.firstWhere((e) => e.cusum != null);
      expect(firstScored.cusum, lessThan(1.0));
    });
  });
}
