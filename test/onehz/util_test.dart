// Item 1 — input types & math utils. Synthetic, known-answer tests.
import 'dart:math' as math;
import 'package:test/test.dart';
import 'package:openstrap_analytics/onehz.dart';

void main() {
  group('basic stats', () {
    test('mean/median/percentile/stddev', () {
      expect(mean([1, 2, 3, 4]), 2.5);
      expect(median([3, 1, 2]), 2);
      // linear-interpolated 50th pct of [1,2,3,4] = 2.5
      expect(percentile([1, 2, 3, 4], 50), 2.5);
      // sample SD of [2,4,4,4,5,5,7,9] = 2.138...
      expect(stddev([2, 4, 4, 4, 5, 5, 7, 9])!, closeTo(2.13809, 1e-4));
      expect(mean([]), isNull);
      expect(stddev([5]), isNull);
    });

    test('percentileSorted matches percentile and stays null on empty', () {
      final sorted = [1.0, 2.0, 3.0, 4.0];
      expect(percentileSorted(sorted, 50), percentile(sorted, 50));
      expect(percentileSorted(sorted, 25), percentile(sorted, 25));
      expect(percentileSorted([7.0], 25), 7.0);
      // NOT 0 — an empty window is no measurement, not a 0 bpm floor.
      expect(percentileSorted([], 25), isNull);
    });

    test('MAD and robust z; MAD=0 guard on quantized data', () {
      // [1,1,1,1,1] -> median 1, MAD 0 => robustZ null (not div-by-zero).
      expect(mad([1, 1, 1, 1, 1], scaled: false), 0);
      expect(robustZ(5, [1, 1, 1, 1, 1]), isNull);
      // [1,2,3,4,5] median 3, abs devs [2,1,0,1,2] median 1, scaled 1.4826
      expect(mad([1, 2, 3, 4, 5], scaled: false), 1);
      final zr = robustZ(7, [1, 2, 3, 4, 5]);
      expect(zr, closeTo((7 - 3) / 1.4826, 1e-6));
    });

    test('clamp', () {
      expect(clamp(5, 0, 3), 3);
      expect(clamp(-1, 0, 3), 0);
      expect(clamp(2, 0, 3), 2);
    });
  });

  group('regression', () {
    test('OLS slope + intercept on exact line y=2x+1', () {
      final y = [1.0, 3.0, 5.0, 7.0, 9.0];
      expect(olsSlope(y), closeTo(2, 1e-9));
      final f = olsFit(y)!;
      expect(f.slope, closeTo(2, 1e-9));
      expect(f.intercept, closeTo(1, 1e-9));
    });

    test('Theil-Sen ignores a gross outlier OLS cannot', () {
      // y = 2x exactly except last point corrupted.
      final x = <double>[0, 1, 2, 3, 4, 5, 6, 7, 8, 9];
      final y = <double>[for (final xi in x) 2 * xi]..[9] = 999;
      final ts = theilSen(y, x)!;
      final ols = olsSlope(y, x)!;
      expect(ts, closeTo(2, 1e-9)); // robust: median pairwise slope = 2
      expect(ols, greaterThan(5)); // OLS dragged way off
    });
  });

  group('Lomb-Scargle', () {
    test('recovers a known sinusoid frequency from uneven samples', () {
      // 0.1 Hz sinusoid, 120 s, jittered sampling.
      final f0 = 0.1;
      final t = <double>[];
      final y = <double>[];
      var cur = 0.0;
      var k = 0;
      while (cur < 120) {
        t.add(cur);
        y.add(math.sin(2 * math.pi * f0 * cur));
        // deterministic jitter (no randomness): 0.8 + 0.4*frac pattern
        cur += 0.8 + 0.4 * ((k % 5) / 5.0);
        k++;
      }
      final grid = freqGrid(0.01, 0.4, 400);
      final ls = lombScargle(t, y, grid)!;
      final peak = ls.peakFreq(0.01, 0.4)!;
      expect(peak, closeTo(f0, 0.01));
    });

    test('returns null on degenerate input', () {
      expect(lombScargle([0, 1], [1, 1], [0.1]), isNull); // <4 pts
      expect(lombScargle([0, 1, 2, 3], [5, 5, 5, 5], [0.1]), isNull); // 0 var
    });
  });

  group('Metric honesty wrapper', () {
    test('present metric encodes value + tier + confidence', () {
      final m = Metric<double>(
        value: 42.0,
        confidence: 0.8,
        tier: Tier.high,
        inputs_used: const ['rr'],
      );
      final j = m.toJson();
      expect(j['value'], 42.0);
      expect(j['confidence'], 0.8);
      expect(j['tier'], 'HIGH');
      expect(j['inputs_used'], ['rr']);
      expect(m.present, isTrue);
    });

    test('absent metric emits "—" and forces confidence 0', () {
      const m = Metric<double>.absent(
        tier: Tier.high,
        inputs_used: ['rr'],
        note: 'no valid beats',
      );
      final j = m.toJson();
      expect(j['value'], '—');
      expect(j['confidence'], 0);
      expect(m.present, isFalse);
    });
  });

  group('multiplicity — benjaminiHochberg', () {
    test('known answer, and the step-up keeps q monotone in p', () {
      // m = 5, q_(k) = p_(k)·m/k with a running minimum applied from the
      // largest p downwards. The raw ratios here are
      // [0.04, 0.025, 0.04, 0.05, 0.6] in p order — NOT monotone, and the
      // smallest p carries the largest raw ratio. The step-up pulls it down to
      // its neighbour, which is the part everyone drops: without it the
      // strongest test in the family is refused while a weaker one publishes.
      final q = benjaminiHochberg([0.01, 0.008, 0.024, 0.04, 0.6]);
      expect(q[1]!, closeTo(0.025, 1e-12)); // raw 0.04, stepped down
      expect(q[0]!, closeTo(0.025, 1e-12)); // 0.01·5/2
      expect(q[2]!, closeTo(0.04, 1e-12)); // 0.024·5/3
      expect(q[3]!, closeTo(0.05, 1e-12)); // 0.04·5/4
      expect(q[4]!, closeTo(0.6, 1e-12));
      // Monotone in p, which is the property the step-up buys.
      final byP = [0, 1, 2, 3, 4]..sort((a, b) => [
            0.01,
            0.008,
            0.024,
            0.04,
            0.6
          ][a]
              .compareTo([0.01, 0.008, 0.024, 0.04, 0.6][b]));
      for (var k = 1; k < byP.length; k++) {
        expect(q[byP[k]]!, greaterThanOrEqualTo(q[byP[k - 1]]!));
      }
    });

    test('a family of one is the identity', () {
      expect(benjaminiHochberg([0.03]).single!, closeTo(0.03, 1e-12));
    });

    test('a null p stays null and does NOT count toward the family size', () {
      // A test we abstained from is not a test we performed. Counting it would
      // punish every other test for a comparison that never ran.
      final q = benjaminiHochberg([0.01, null, 0.02]);
      expect(q[1], isNull);
      expect(q[0]!, closeTo(0.02, 1e-12), reason: 'm = 2, not 3');
    });

    test('q never goes above 1 or below its own p', () {
      final q = benjaminiHochberg([0.9, 0.95, 0.99]);
      for (final v in q) {
        expect(v!, lessThanOrEqualTo(1.0));
      }
    });

    test('empty in, empty out', () {
      expect(benjaminiHochberg(const []), isEmpty);
    });
  });

  group('normalTwoSidedP', () {
    test('matches the standard normal at the landmarks', () {
      expect(normalTwoSidedP(0), closeTo(1.0, 1e-6));
      expect(normalTwoSidedP(1.959964), closeTo(0.05, 1e-5));
      expect(normalTwoSidedP(2.575829), closeTo(0.01, 1e-5));
      expect(normalTwoSidedP(-1.959964), closeTo(0.05, 1e-5),
          reason: 'two-sided: the sign cannot matter');
    });

    test('a non-finite z is no evidence, not a certainty', () {
      expect(normalTwoSidedP(double.nan), 1.0);
    });
  });

  test('RrSeries beat-time reconstruction', () {
    final rr = RrSeries([1000, 1800, 2600], [1000, 800, 800]);
    expect(rr.beatTimesMs(0), [1000.0, 1800.0, 2600.0]);
    expect(rr.length, 3);
  });

  // ── C9: the ONE median-interval helper ────────────────────────────────────
  // Three near-duplicates used to live in load_trimp / hr_zones /
  // advanced_stager with three signatures and three numeric fallbacks (1.0,
  // 1.0 via `fallbackSampleMin * 60`, and 60). The fallbacks fired for a
  // device SLOWER than their 300 s gap filter, not for a device with no data —
  // so a 301 s band had every reading credited with one second.
  //
  // Every case here is at 301 s or 600 s, never 300: a 300 s device passed the
  // old `<= 300` filters cleanly and was never the bug.
  group('sampleCadenceSeconds', () {
    List<double> at(double cadence, int n, {double t0 = 0}) =>
        [for (var i = 0; i < n; i++) t0 + i * cadence];

    test('measures the cadence of a regular stream', () {
      expect(sampleCadenceSeconds(at(1, 100)), closeTo(1.0, 1e-12));
      expect(sampleCadenceSeconds(at(60, 100)), closeTo(60.0, 1e-12));
      // 300 s is SUPPORTED. It always was; the cliff is above it.
      expect(sampleCadenceSeconds(at(300, 100)), closeTo(300.0, 1e-12));
    });

    test('301 s and 600 s ABSTAIN instead of falling back to 1.0 / 60', () {
      expect(sampleCadenceSeconds(at(301, 100)), isNull);
      expect(sampleCadenceSeconds(at(600, 100)), isNull);
    });

    test('nothing to measure → null, never a number', () {
      expect(sampleCadenceSeconds(const []), isNull);
      expect(sampleCadenceSeconds(const [5.0]), isNull);
      // Duplicate timestamps are not a cadence.
      expect(sampleCadenceSeconds(const [5.0, 5.0, 5.0]), isNull);
    });

    test('dropouts do NOT abstain — a hole is a hole, not a cadence', () {
      // A sleep-only source: 8 h of 1 Hz then a 16 h gap. The median is still
      // 1 s and it is still right; the caller caps the hole at that cadence.
      final night = [...at(1, 28800), 28800 + 57600.0];
      expect(sampleCadenceSeconds(night), closeTo(1.0, 1e-12));
      // Mild jitter (1 s alternating with 2 s) stays inside the 2x mode
      // tolerance — a jittering device is still a device we can read.
      final jitter = <double>[0];
      for (var i = 0; i < 200; i++) {
        jitter.add(jitter.last + (i.isEven ? 1 : 2));
      }
      expect(sampleCadenceSeconds(jitter), isNotNull);
    });

    test('a stream with no dominant mode has no cadence → null', () {
      // THREE regimes in equal thirds — 1 s, 60 s, 600 s, which is what one
      // series fed by two devices at different rates looks like. The median
      // (60 s) is a real value but describes only a third of the record, so
      // there is no cadence to hand a caller.
      //
      // This check is DELIBERATELY NARROW. A two-mode stream (dense sampling
      // plus long holes) passes on purpose: there the median IS the cadence
      // and the long gaps are dropouts, which every caller already caps at the
      // median — "a hole in the stream is not elapsed effort". Tightening this
      // enough to catch that case would abstain on ordinary dropout-heavy
      // nights, which is a worse failure than the one it would prevent.
      final mixed = <double>[0];
      for (var i = 0; i < 99; i++) {
        mixed.add(mixed.last + (i % 3 == 0 ? 1 : (i % 3 == 1 ? 60 : 600)));
      }
      expect(sampleCadenceSeconds(mixed), isNull);
    });
  });

  group('C9 callers abstain at 301 s and 600 s', () {
    test('HeartRateZones.timeInZone: 300 s scores, 301 s and 600 s are null',
        () {
      final zoneSet = HeartRateZones.zonesFromMaxHr(200);
      List<HrSample> stream(double cadence, int n) => [
            for (var i = 0; i < n; i++) HrSample(i * cadence * 1000.0, 150)
          ];
      // 300 s: 20 readings, each credited its own 300 s → 6000 s in z3.
      expect(HeartRateZones.timeInZone(stream(300, 20), zoneSet)!.total,
          closeTo(6000, 1e-9));
      // 301 s used to return 20 x 1.0 s = 20 s — a ~300x undercount published
      // as minutes. It is now absent.
      expect(HeartRateZones.timeInZone(stream(301, 20), zoneSet), isNull);
      expect(HeartRateZones.timeInZone(stream(600, 20), zoneSet), isNull);
    });

    test('StrainScorer: 301 s and 600 s produce no durations and no strain',
        () {
      final bpm = List<double>.filled(40, 150.0);
      List<double> ts(double cadence) =>
          [for (var i = 0; i < 40; i++) i * cadence];
      expect(StrainScorer.medianIntervalSeconds(ts(300)), closeTo(300, 1e-12));
      expect(StrainScorer.medianIntervalSeconds(ts(301)), isNull);
      expect(StrainScorer.medianIntervalSeconds(ts(600)), isNull);
      expect(StrainScorer.sampleDurationsMinutes(ts(301)), isEmpty);
      expect(StrainScorer.sampleDurationsMinutes(ts(600)), isEmpty);
      // The abstention has to reach the published number, not stop at the
      // helper: `banisterTRIMP` credits `fallbackSampleMin` per sample when
      // handed an empty list, which is the fabricated 1 s all over again.
      expect(StrainScorer.strain(bpm, ts(301), maxHR: 190, restingHR: 50),
          isNull);
      expect(StrainScorer.strain(bpm, ts(600), maxHR: 190, restingHR: 50),
          isNull);
      expect(StrainScorer.strain(bpm, ts(300), maxHR: 190, restingHR: 50),
          isNotNull);
    });

    test('AdvancedSleepStager stages nothing past its own cadence ceiling', () {
      // A perfectly still, sleep-shaped night. It used to be staged on a 60 s
      // guess at ANY cadence; `sampleCadenceSeconds` stopped that above 300 s.
      //
      // The 300 s case moved in phase 3 (C4) and is now ABSENT too, which is a
      // stricter ceiling than this helper's, not a contradiction of it:
      // `gravityStillThresholdGPerS` is a RATE, so the per-sample cut is
      // `0.01 x cadence` — and |Δg| between two unit gravity vectors saturates
      // at 2, so at 300 s the cut is 3.0 g and EVERY sample reads still whatever
      // the wrist did. This synthetic (all deltas exactly 0) cannot see that;
      // a real 300 s day would have come out as one unbroken 8 h sleep session.
      // See `AdvancedSleepStager.maxStillCadenceSec` and
      // `test/onehz/sleep_cadence_test.dart`.
      List<GravTs> grav(int cadence) => [
            for (var t = 0; t < 8 * 3600; t += cadence) GravTs(t, 0, 0, 1.0)
          ];
      List<HrTs> hr(int cadence) => [
            for (var t = 0; t < 8 * 3600; t += cadence) HrTs(t, 52)
          ];
      expect(AdvancedSleepStager.detectSleep(grav(30), hr(30)), isNotEmpty);
      expect(AdvancedSleepStager.detectSleep(grav(300), hr(300)), isEmpty);
      expect(AdvancedSleepStager.detectSleep(grav(301), hr(301)), isEmpty);
      expect(AdvancedSleepStager.detectSleep(grav(600), hr(600)), isEmpty);
    });

    test('1 Hz is untouched — the refactor moves nothing on a WHOOP stream',
        () {
      final zoneSet = HeartRateZones.zonesFromMaxHr(200);
      final oneHz = [for (var i = 0; i < 3600; i++) HrSample(i * 1000.0, 150)];
      // 3600 samples, each 1 s, tail gets the 1 s median.
      expect(HeartRateZones.timeInZone(oneHz, zoneSet)!.total,
          closeTo(3600, 1e-9));
      final ts = [for (var i = 0; i < 3600; i++) i.toDouble()];
      expect(StrainScorer.medianIntervalSeconds(ts), closeTo(1.0, 1e-12));
      final durs = StrainScorer.sampleDurationsMinutes(ts);
      expect(durs.length, 3600);
      expect(durs.every((d) => (d - 1 / 60.0).abs() < 1e-12), isTrue);
    });
  });
}
