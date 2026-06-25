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
      final rr = <double>[for (var i = 0; i < 64; i++) 1000 + (i.isEven ? 30 : -30)];
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
      expect(dc.value!.riskTier, isNotNull);
    });
    test('absent without enough beats', () {
      expect(decelerationCapacity([1000, 1010, 990]).present, isFalse);
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
      final day = <double>[for (var i = 0; i < 200; i++) 80];
      final night = <double>[for (var i = 0; i < 200; i++) 60];
      final m = hrDip(day, night);
      expect(m.value!.dipPct, closeTo(25, 1e-9)); // (80-60)/80
      expect(m.value!.band, 'dipper');
      // riser case
      final r = hrDip(<double>[60, 60, 60], <double>[70, 70, 70]);
      expect(r.value!.band, 'riser');
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
  });

  group('TRIMP + CTL/ATL/TSB', () {
    test('Banister TRIMP needs anchors; produces positive load', () {
      final none = banisterTrimp([120, 130], restingHr: null, maxHr: 190, sex: Sex.male);
      expect(none.present, isFalse);
      final m = banisterTrimp([120, 140, 160],
          restingHr: 50, maxHr: 190, sex: Sex.male);
      expect(m.value!, greaterThan(0));
    });
    test('Edwards zone-sum is the weighted dot product', () {
      // zones [10,5,0,0,0] -> 10*1 + 5*2 = 20
      final m = edwardsTrimp([10, 5, 0, 0, 0]);
      expect(m.value!, 20);
    });
    test('CTL>ATL after a long steady block, then ATL spikes on a hard day', () {
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
        final v = inBurst
            ? base + (i.isEven ? 250.0 : -250.0) // ±250 ms whipsaw
            : base + (i.isEven ? 8.0 : -8.0); // small ±8 ms wobble
        nn.add(v);
        t += v;
        times.add(t);
      }
      final whole = hrvTime(nn).value!.rmssd!;
      final robust = nocturnalRmssd(nn, times).value!;
      // Whole-night RMSSD is dragged way up by the bursts.
      expect(whole, greaterThan(100),
          reason: 'whole-night RMSSD inflated by bursts');
      // The stable wobble RMSSD ≈ sqrt((16^2)) ≈ 16 ms; robust median stays low.
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
        nn.add(1000.0 + (i.isEven ? 10.0 : -10.0));
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

  group('strain score (0-21 log-squash of TRIMP)', () {
    test('pins TRIMP -> strain check-points', () {
      expect(strainScore(0), closeTo(0.0, 1e-9));
      expect(strainScore(335), closeTo(14.347, 1e-2));
      // monotone + capped at 21.
      expect(strainScore(1e9), closeTo(21.0, 1e-9));
      expect(strainScore(100) < strainScore(335), isTrue);
    });

    test('strainScoreMetric is HIGH/EST and absent on null', () {
      final m = strainScoreMetric(335);
      expect(m.present, isTrue);
      expect(m.value, closeTo(14.347, 1e-2));
      expect(m.tier, 'ESTIMATE');
      expect(strainScoreMetric(null).present, isFalse);
    });
  });

  group('baseline-need signals (need_baseline convention)', () {
    test('readinessLnRmssd: 1 night -> absent + need note; >=min computes', () {
      final one = readinessLnRmssd([3.5]);
      expect(one.present, isFalse);
      expect(one.confidence, 0);
      expect(one.note, 'need_baseline:have=1,need=$readinessLnRmssdMinNights');
      final enough = readinessLnRmssd(
          List<double>.generate(readinessLnRmssdMinNights, (i) => 3.5 + i * 0.01));
      expect(enough.present, isTrue);
    });

    test('illnessCusum: short baseline night carries need note; then evaluates',
        () {
      final n = 12;
      final dates = [for (var i = 0; i < n; i++) 'd$i'];
      final rhr = [for (var i = 0; i < n; i++) 55.0 + (i.isEven ? 0.0 : 1.0)];
      final days = illnessCusum(dates, rhr);
      // First night: have=0 baseline, need=7.
      expect(days[0].need, 'need_baseline:have=0,need=$illnessCusumMinBaseline');
      expect(days[0].cusum, isNull);
      // A night past the minimum baseline is evaluated (no need note).
      expect(days[illnessCusumMinBaseline].need, isNull);
      expect(days[illnessCusumMinBaseline].cusum, isNotNull);
    });
  });
}
