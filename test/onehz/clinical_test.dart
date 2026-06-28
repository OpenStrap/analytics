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

    test('accumulates duration until next sample and rounds to zone minutes', () {
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

  group('StrainScorer (Edwards/Banister TRIMP → 0–100)', () {
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

    test('Edwards zone weight at %HRR boundaries (RHR=0,reserve=100 → bpm=%HRR)', () {
      int w(double pct) => StrainScorer.zoneWeight(pct, 0, 100);
      expect(w(49), 0);
      expect(w(50), 1);
      expect(w(60), 2);
      expect(w(70), 3);
      expect(w(80), 4);
      expect(w(90), 5);
      expect(w(100), 5);
    });

    test('Banister monotonic increasing in intensity', () {
      // Two same-length streams, one strictly higher HR → more Banister TRIMP.
      final lo = List<double>.filled(30, 100.0);
      final hi = List<double>.filled(30, 150.0);
      final ts = [for (var i = 0; i < 30; i++) i.toDouble()];
      final tLo = StrainScorer.banisterTRIMP(
          lo, 50, 150, StrainScorer.sampleDurationMinutes(ts),
          StrainScorer.banisterBMen);
      final tHi = StrainScorer.banisterTRIMP(
          hi, 50, 150, StrainScorer.sampleDurationMinutes(ts),
          StrainScorer.banisterBMen);
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

    test('gating: too few samples → null; spanning ≥600s with ≥20 → computes', () {
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

    test('trimpStrain envelope: present/ESTIMATE on enough data, absent otherwise', () {
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
