// WELLNESS family — temperature / anomaly / change-point / readiness.
//
// Synthetic KNOWN-ANSWER tests (no TS oracle exists for this net-new family)
// plus a PLAUSIBILITY pass on the real ../whoop_hist.jsonl capture.
//
// HONESTY of validation: whoop_hist.jsonl is ~9 min of consecutive 1 Hz R24
// records — enough to exercise temp parsing + cosinor plumbing + that nothing
// crashes, but NOT enough for the multi-day methods (nightly z, 3-over-6,
// multivariate-anomaly persistence, multi-week change-points). Those are
// validated by the synthetic known-answer tests ONLY, stated honestly here.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:test/test.dart';
import 'package:openstrap_analytics/src/onehz/wellness/wellness.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

void main() {
  // -------------------------------------------------------------------------
  // 1. Relative skin-temp circadian — cosinor recovers an injected phase.
  // -------------------------------------------------------------------------
  group('tempCircadian (relative, phase only)', () {
    test('cosinor recovers the acrophase of a 24-h cosine temp series', () {
      // Peak at 04:00 (distal temp antiphase-to-core peaks during sleep).
      const peakHour = 4.0;
      final samples = <AdcSample>[];
      // 3 days @ 1 sample / 10 min.
      for (var i = 0; i < 3 * 24 * 6; i++) {
        final tMs = i * 10 * 60 * 1000.0;
        final tHours = tMs / 3.6e6;
        final adc =
            2000 + 300 * math.cos(2 * math.pi / 24 * (tHours - peakHour));
        samples.add(AdcSample(tMs, adc));
      }
      final m = tempCircadian(samples, epochMin: 60);
      expect(m.present, isTrue);
      expect(m.tier, Tier.relative);
      final fit = m.value!.cosinorFit!;
      expect(fit.acrophaseHours, closeTo(peakHour, 0.3));
      expect(fit.amplitude, closeTo(300, 15));
      expect(fit.r2, greaterThan(0.95));
      // Nonparametric: strong clean rhythm => high IS, low IV, high RA.
      final np = m.value!.nonparam!;
      expect(np.interdailyStability, greaterThan(0.7));
      expect(np.intradailyVariability, lessThan(0.5));
      expect(np.relativeAmplitude!, greaterThan(0.05));
      // The warmest 10-h window should centre near the peak.
      expect(np.m10!, greaterThan(np.l5!));
    });

    test('an unobserved hour-of-day leaves M10/L5/RA ABSENT, not grand-mean',
        () {
      // Same clean 3-day cosine, but the strap is off 03:00-06:00 every day —
      // three hours-of-day are never observed, so the averaged 24-h profile is
      // incomplete and there is no warmest/coolest window to report.
      final samples = <AdcSample>[];
      for (var i = 0; i < 3 * 24 * 6; i++) {
        final tMs = i * 10 * 60 * 1000.0;
        final tHours = tMs / 3.6e6;
        final hod = tHours % 24;
        if (hod >= 3 && hod < 6) continue;
        samples.add(
            AdcSample(tMs, 2000 + 300 * math.cos(2 * math.pi / 24 * tHours)));
      }
      final np = tempCircadian(samples, epochMin: 60).value!.nonparam!;
      expect(np.m10, isNull);
      expect(np.l5, isNull);
      expect(np.m10OnsetHour, isNull);
      expect(np.l5OnsetHour, isNull);
      expect(np.relativeAmplitude, isNull);
      // IS/IV still stand — they do not need every hour-of-day.
      expect(np.interdailyStability, greaterThan(0.0));
      final j = np.toJson();
      expect(j.containsKey('m10'), isFalse);
      expect(j.containsKey('relative_amplitude'), isFalse);
    });

    test('activity de-masking drops high-motion epochs', () {
      final samples = <AdcSample>[];
      final accel = <AccelSample>[];
      for (var i = 0; i < 24 * 6; i++) {
        final tMs = i * 10 * 60 * 1000.0;
        samples.add(AdcSample(tMs, 2000.0 + i % 5));
        // Inject big motion every 3rd epoch.
        final motion = i % 3 == 0 ? 0.5 : 0.0;
        accel.add(AccelSample(tMs, 1.0 + motion, 0, 0));
      }
      final m = tempCircadian(samples, accel: accel, motionGate: 0.08);
      expect(m.inputs_used, contains('accel'));
      expect(m.note, contains('demasked'));
    });

    test('absent on too-few epochs', () {
      final m = tempCircadian([AdcSample(0, 2000)]);
      expect(m.present, isFalse);
      expect(m.confidence, 0);
    });
  });

  // -------------------------------------------------------------------------
  // 2. Skin-temp z-score illness flag (cycle-aware).
  // -------------------------------------------------------------------------
  group('tempIllnessFlag (Smarr, cycle-aware)', () {
    List<String> dates(int n) => [for (var i = 0; i < n; i++) 'd$i'];

    test('flags a sustained temp elevation as illness', () {
      // 14 baseline nights ~2000, then a sustained +large jump.
      final temp = <double?>[
        for (var i = 0; i < 14; i++) 2000.0 + (i.isEven ? 3 : -3),
        2060, 2065, 2070, // sustained elevation
      ];
      final out = tempIllnessFlag(dates(temp.length), temp,
          baselineDays: 21, zThresh: 2.0, persistDays: 2, minBaseline: 7);
      // The last two nights (after persistence) should be elevated.
      expect(out.last.flag, TempFlag.elevated);
      expect(out[out.length - 2].flag, TempFlag.elevated);
      // The very first elevated night is NOT yet persistent => normal.
      expect(out[14].flag, TempFlag.normal);
    });

    test('luteal phase suppresses the illness flag (confound tag)', () {
      final temp = <double?>[
        for (var i = 0; i < 14; i++) 2000.0 + (i.isEven ? 3 : -3),
        2060,
        2065,
        2070,
      ];
      final luteal = <bool>[
        for (var i = 0; i < 14; i++) false,
        true,
        true,
        true,
      ];
      final out = tempIllnessFlag(dates(temp.length), temp,
          luteal: luteal, baselineDays: 21, zThresh: 2.0, persistDays: 2);
      expect(out.last.flag, TempFlag.lutealConfound);
      expect(out.last.confidence, lessThan(0.5));
    });

    test('degenerate (flat) baseline => normal, confidence 0 (no fabrication)',
        () {
      final temp = <double?>[for (var i = 0; i < 12; i++) 2000.0, 2050.0];
      final out = tempIllnessFlag(dates(temp.length), temp, minBaseline: 7);
      // Flat baseline -> MAD=0 -> robustZ null -> can't standardize honestly.
      expect(out.last.flag, TempFlag.normal);
      expect(out.last.z, isNull);
      expect(out.last.confidence, 0);
    });
  });

  // -------------------------------------------------------------------------
  // 3. Menstrual 3-over-6 / coverline — fires at the biphasic luteal shift.
  // -------------------------------------------------------------------------
  group('menstrualCoverline (retrospective confirmation only)', () {
    test('confirms ovulation at a biphasic temp shift', () {
      // Follicular plateau ~2000 (8 nights), then a sustained +3 ADC luteal
      // shift to ~2003+ for the rest of the cycle.
      final temp = <double?>[
        for (var i = 0; i < 8; i++) 2000.0 + (i.isEven ? 0.5 : -0.5),
        for (var i = 0; i < 10; i++) 2003.0 + (i.isEven ? 0.5 : -0.5),
      ];
      final m = menstrualCoverline(
          [for (var i = 0; i < temp.length; i++) 'd$i'], temp,
          lookback: 6, confirm: 3, threshold: 1.5);
      expect(m.present, isTrue);
      expect(m.tier, Tier.relative);
      expect(m.value!, isNotEmpty);
      final ev = m.value!.first;
      // The shift starts at index 8; confirmation = index 10 (3rd night).
      expect(ev.estimatedOvulationIndex, inInclusiveRange(6, 8));
      expect(m.note, contains('CONFIRMATION'));
    });

    test('no shift => no confirmation event', () {
      final temp = <double?>[
        for (var i = 0; i < 20; i++) 2000.0 + (i.isEven ? 1 : -1)
      ];
      final m = menstrualCoverline(
          [for (var i = 0; i < temp.length; i++) 'd$i'], temp,
          threshold: 1.5);
      expect(m.value, isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  // 4. Multivariate anomaly — flags a single spiked feature, leaves normal alone.
  // -------------------------------------------------------------------------
  group('multivariateAnomaly (robust Mahalanobis complement)', () {
    List<String> dates(int n) => [for (var i = 0; i < n; i++) 'd$i'];
    final rng = math.Random(7);

    AnomalyFeatures normalNight() => AnomalyFeatures(
          rhr: 55 + rng.nextDouble() * 2 - 1,
          hrv: 4.0 + (rng.nextDouble() * 0.2 - 0.1), // lnRMSSD
          temp: 2000 + rng.nextDouble() * 4 - 2,
          resp: 14 + rng.nextDouble() * 1 - 0.5,
        );

    test('flags two consecutive nights with one feature spiked', () {
      final feats = <AnomalyFeatures>[
        for (var i = 0; i < 20; i++) normalNight(),
        // RHR spikes hard for two consecutive nights.
        AnomalyFeatures(rhr: 75, hrv: 4.0, temp: 2000, resp: 14),
        AnomalyFeatures(rhr: 76, hrv: 4.0, temp: 2000, resp: 14),
      ];
      final out = multivariateAnomaly(dates(feats.length), feats,
          baselineDays: 28, minBaseline: 10, persistDays: 2);
      expect(out[20].candidate, isTrue);
      expect(out[21].flagged, isTrue, reason: 'persistence satisfied');
      // The dominant driver should be RHR.
      expect(out[21].drivers.first.label, 'RHR');
    });

    test('does NOT cry wolf on a normal series', () {
      final feats = [for (var i = 0; i < 25; i++) normalNight()];
      final out = multivariateAnomaly(dates(feats.length), feats,
          baselineDays: 28, minBaseline: 10, persistDays: 2);
      final flags = out.where((d) => d.flagged).length;
      expect(flags, 0, reason: 'no false multivariate alarms on normal data');
    });

    test('a single isolated spike is NOT flagged (persistence gate)', () {
      final feats = <AnomalyFeatures>[
        for (var i = 0; i < 20; i++) normalNight(),
        AnomalyFeatures(rhr: 80, hrv: 4.0, temp: 2000, resp: 14), // one night
        normalNight(),
      ];
      final out = multivariateAnomaly(dates(feats.length), feats,
          baselineDays: 28, minBaseline: 10, persistDays: 2);
      expect(out[20].candidate, isTrue);
      expect(out[20].flagged, isFalse, reason: 'one night cannot flag');
    });
  });

  // -------------------------------------------------------------------------
  // 5. Change-point — PELT/binary segmentation finds a stepped mean.
  // -------------------------------------------------------------------------
  group('changepoint', () {
    test('segmentChangePoints finds a single mean step at the right index', () {
      final x = <double>[
        for (var i = 0; i < 20; i++) 10.0 + (i.isEven ? 0.3 : -0.3),
        for (var i = 0; i < 20; i++) 16.0 + (i.isEven ? 0.3 : -0.3),
      ];
      final m = segmentChangePoints(x, minSeg: 7);
      expect(m.present, isTrue);
      expect(m.value!.changePoints.length, 1);
      expect(m.value!.changePoints.first, closeTo(20, 1));
      // Two segments with clearly different means.
      expect(m.value!.segmentMeans.length, 2);
      expect((m.value!.segmentMeans[1] - m.value!.segmentMeans[0]).abs(),
          greaterThan(4));
    });

    test('segmentChangePoints reports NO change-point on a flat series', () {
      final x = [for (var i = 0; i < 40; i++) 10.0 + (i.isEven ? 0.2 : -0.2)];
      final m = segmentChangePoints(x, minSeg: 7);
      expect(m.value!.changePoints, isEmpty,
          reason: 'no regression-to-mean false split');
    });

    // an-wellness-3. The old case here used a deliberately IMBALANCED 30-low /
    // 15-high split, which put the whole-series median inside the low regime
    // and kept the MAD small — so it passed while hiding the actual behaviour.
    // Standardizing by the whole series folds the post-change data into the
    // scale, which pins |z| at 1/1.4826 ~ 0.675 for ANY balanced two-regime
    // series whatever the step size: detection depended only on how LONG the
    // regimes were, never on how big the shift was.

    // A deterministic 10-day noise cycle: median 0, MAD 1.4826.
    const noise = <double>[0, 1, -1, 2, -2, 1, -1, 0, 2, -2];
    List<double> twoRegime(double base, double step, {int perRegime = 30}) => [
          for (var i = 0; i < perRegime; i++) base + noise[i % 10],
          for (var i = 0; i < perRegime; i++) base + step + noise[i % 10],
        ];

    test('a BALANCED step is detected at every size, once, on the high side',
        () {
      for (final step in [3.0, 7.0, 15.0, 60.0, 145.0]) {
        final dets = cusumChangePoints(twoRegime(55.0, step), h: 5.0);
        expect(dets, hasLength(1), reason: 'step $step announced once');
        expect(dets.single.direction, 1);
        expect(dets.single.index, inInclusiveRange(30, 36),
            reason: 'step $step detected near the change, not drifted');
      }
      // Downward steps too.
      final down = cusumChangePoints(twoRegime(200.0, -60.0), h: 5.0);
      expect(down, hasLength(1));
      expect(down.single.direction, -1);
    });

    test('a large step in a SHORT window is not invisible', () {
      // 30 days, 55 -> 200. The whole-series scale made this return [].
      final dets =
          cusumChangePoints(twoRegime(55.0, 145.0, perRegime: 15), h: 5.0);
      expect(dets, isNotEmpty);
      expect(dets.first.index, inInclusiveRange(15, 17));
      expect(dets.first.direction, 1);
    });

    test('one shift is announced ONCE under the caller`s latest-day gate', () {
      // derivation_engine.dart replays a growing window and notifies only when
      // `dets.last.index == n - 1`. On the whole-series scale that fired on
      // n = 31,32,34,36,39,42,46,50,54,58 — ten critical-priority notifications
      // about one shift.
      final x = twoRegime(55.0, 10.0);
      var fires = 0;
      for (var n = 10; n <= x.length; n++) {
        final dets = cusumChangePoints(x.sublist(0, n), h: 5.0);
        if (dets.isNotEmpty && dets.last.index == n - 1) fires++;
      }
      expect(fires, 1);
    });

    test('no detection when a robust scale cannot be estimated', () {
      // A perfectly constant baseline has no dispersion to standardize
      // against; an absent change-point beats a fabricated one.
      final x = <double>[
        for (var i = 0; i < 30; i++) 55.0,
        for (var i = 0; i < 30; i++) 200.0,
      ];
      expect(cusumChangePoints(x, h: 5.0), isEmpty);
    });

    test('no detection on a series that never shifts', () {
      final x = [for (var i = 0; i < 60; i++) 55.0 + noise[i % 10]];
      expect(cusumChangePoints(x, h: 5.0), isEmpty);
    });

    test('a series shorter than the baseline requirement yields nothing', () {
      expect(cusumChangePoints([for (var i = 0; i < 10; i++) 55.0 + i], h: 5.0),
          isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  // 6. Honest readiness composite — attributes the bad input in the breakdown.
  // -------------------------------------------------------------------------
  group('readinessComposite (glass-box)', () {
    final base = [for (var i = 0; i < 14; i++) 0.0 + (i.isEven ? 1 : -1)];
    // Build baselines centred so a "normal" value sits at the median.
    List<double> around(double c) =>
        [for (var i = 0; i < 14; i++) c + (i.isEven ? 1.0 : -1.0)];

    test('a single bad input dominates the driver breakdown', () {
      // HRV crashed (low), everything else normal-at-baseline.
      final m = readinessComposite([
        hrvInput(40.0, around(60.0)), // far below baseline => bad
        rhrInput(55.0, around(55.0)), // at baseline
        respInput(14.0, around(14.0)),
        tempInput(2000.0, around(2000.0)),
      ]);
      expect(m.present, isTrue);
      expect(m.drivers, isNotNull);
      // HRV should be the top-ranked (largest |contribution|) driver.
      expect(m.drivers!.first.label, 'HRV');
      // HRV dropped => negative contribution => below 50.
      expect(m.value!.score, lessThan(50));
      expect(m.inputs_used, contains('HRV'));
    });

    test('all-at-baseline => ~50', () {
      final m = readinessComposite([
        hrvInput(60.0, around(60.0)),
        rhrInput(55.0, around(55.0)),
        respInput(14.0, around(14.0)),
        tempInput(2000.0, around(2000.0)),
      ]);
      expect(m.value!.score, closeTo(50, 8));
      expect(m.value!.toJson().containsKey('meaningful'), isFalse);
    });

    test('weights renormalize over present inputs; absent => "—"', () {
      final present = readinessComposite([hrvInput(70.0, around(60.0))]);
      expect(present.present, isTrue);
      expect(present.inputs_used, ['HRV']);

      final none = readinessComposite([
        hrvInput(null, around(60.0)),
        rhrInput(55.0, [1, 2]), // baseline too short
      ]);
      expect(none.present, isFalse);
      expect(none.toJson()['value'], '—');
      expect(none.confidence, 0);

      // unused local to keep the analyzer quiet about `base`.
      expect(base.length, 14);
    });

    test(
        'degenerate-MAD baseline is rescued by mean/SD z (no intermittent "—")',
        () {
      // A quantized RHR whose recent baseline clusters tight enough that the
      // median-absolute-deviation collapses to 0 (deviations from the median 52
      // are [0,0,0,0,0,0,1] => MAD 0), but SD > 0. robustZ can't score this, so
      // before the fallback the WHOLE composite blanked to "—" here — the
      // intermittent "readiness sometimes disappears (with sleep present)" bug.
      final tightBase = <double>[52, 52, 52, 52, 52, 52, 53];
      final m = readinessComposite([rhrInput(56.0, tightBase)]);
      expect(m.present, isTrue,
          reason: 'mean/SD z should rescue a MAD==0 (but SD>0) baseline');
      expect(m.inputs_used, ['RHR']);
      // RHR well above a tight baseline => bad for readiness => below 50.
      expect(m.value!.score, lessThan(50));

      // A TRULY constant baseline (SD == 0 too) still honestly abstains — we
      // only rescue degenerate MAD, never fabricate against zero dispersion.
      final flat = readinessComposite([
        rhrInput(56.0, <double>[52, 52, 52, 52])
      ]);
      expect(flat.present, isFalse);
    });
  });

  // -------------------------------------------------------------------------
  // PLAUSIBILITY on the real ~9-min whoop_hist.jsonl capture (no oracle).
  // -------------------------------------------------------------------------
  group('real-capture plausibility (relative temp parses; cosinor runs)', () {
    final histFile = File('../whoop_hist.jsonl');

    test('parse temp ADC + run cosinor without crashing', () {
      if (!histFile.existsSync()) {
        markTestSkipped('whoop_hist.jsonl not found beside the repo');
        return;
      }
      final lines =
          histFile.readAsLinesSync().where((l) => l.trim().isNotEmpty).toList();
      final temp = <AdcSample>[];
      final accel = <AccelSample>[];
      var firstTs = 0, lastTs = 0;
      for (final line in lines) {
        final obj = jsonDecode(line) as Map<String, dynamic>;
        if (obj['t'] != 24) continue;
        final r = parseR24(hexToBytes(obj['hex'] as String));
        if (r == null) continue;
        if (firstTs == 0) firstTs = r.tsEpoch;
        lastTs = r.tsEpoch;
        final tMs = r.tsEpoch * 1000.0 + r.tsSubsec;
        temp.add(AdcSample(tMs, r.skinTempRaw.toDouble()));
        final a = r.accelG;
        if (a.length == 3) accel.add(AccelSample(tMs, a[0], a[1], a[2]));
      }
      // ignore: avoid_print
      print('REAL whoop_hist wellness: tempSamples=${temp.length} '
          'spanSec=${lastTs - firstTs} accelN=${accel.length}');
      expect(temp.length, greaterThan(100));
      // Relative temp ADC is a u16 count.
      for (final s in temp) {
        expect(s.adc, inInclusiveRange(0, 65535));
      }
      // Cosinor runs (the ~9-min span has no full day => low R²/short, but it
      // MUST NOT crash and MUST return an honest Metric).
      final m = tempCircadian(temp, accel: accel, epochMin: 1);
      expect(m.tier, Tier.relative);
      // ignore: avoid_print
      print('REAL temp cosinor: present=${m.present} '
          'r2=${m.value?.cosinorFit?.r2.toStringAsFixed(3)}');

      // HONEST NOTE: multi-day methods (nightly z illness flag, 3-over-6
      // coverline, multivariate-anomaly persistence, multi-week change-points)
      // are NOT exercisable on a ~9-min snippet — they are validated by the
      // synthetic known-answer tests above ONLY.
      expect(lastTs - firstTs, lessThan(24 * 3600),
          reason: 'snippet is sub-day — multi-day methods synthetic-only');
    });
  });

  group('baseline-need signals (need_baseline convention)', () {
    test(
        'readinessComposite: value present but 1-day baseline -> absent + need',
        () {
      final inputs = [
        hrvInput(50.0, [48.0]), // value present, baseline length 1 (< min 3)
      ];
      final m = readinessComposite(inputs);
      expect(m.present, isFalse);
      expect(m.confidence, 0);
      expect(
          m.note, 'need_baseline:have=1,need=$readinessCompositeMinBaseline');
      // With >= minBaseline points it computes.
      final ok = readinessComposite([
        hrvInput(60.0, [48.0, 49.0, 50.0, 51.0, 52.0]),
      ]);
      expect(ok.present, isTrue);
    });

    test('multivariateAnomaly: short baseline night carries need note', () {
      final n = 14;
      final dates = [for (var i = 0; i < n; i++) 'd$i'];
      final feats = [
        for (var i = 0; i < n; i++)
          AnomalyFeatures(
              rhr: 55.0 + (i % 2),
              hrv: 3.5,
              temp: 0.0 + (i % 2) * 0.1,
              resp: 14.0)
      ];
      final days = multivariateAnomaly(dates, feats);
      // Night 1 has only 1 baseline night -> need note, have=1.
      expect(days[1].mahalanobis, isNull);
      expect(days[1].need,
          'need_baseline:have=1,need=$multivariateAnomalyMinBaseline');
      // Past the minimum baseline a distance is computed (no need note).
      expect(days[multivariateAnomalyMinBaseline + 1].need, isNull);
      expect(days[multivariateAnomalyMinBaseline + 1].mahalanobis, isNotNull);
    });

    test('tempIllnessFlag: short baseline night carries need note', () {
      final n = 12;
      final dates = [for (var i = 0; i < n; i++) 'd$i'];
      final temp = [for (var i = 0; i < n; i++) 100.0 + (i % 2)];
      final days = tempIllnessFlag(dates, temp);
      expect(days[0].need, 'need_baseline:have=0,need=$tempIllnessMinBaseline');
      expect(days[0].z, isNull);
      expect(days[tempIllnessMinBaseline].need, isNull);
    });
  });

  // -------------------------------------------------------------------------
  // REGRESSION: degenerate (zero-dispersion) baseline columns must be dropped,
  // not floored to an epsilon scale.
  // -------------------------------------------------------------------------
  group('multivariateAnomaly — degenerate baseline (regression)', () {
    test(
        'an exactly-constant baseline column is DROPPED, never floored to 1e-6',
        () {
      // Ten baseline nights whose skin-temp z is an exactly-constant quantized
      // 0.0 (MAD == 0 AND SD == 0), alongside a real HRV column, then a night
      // where temp moves by a physiologically trivial 0.4.
      //
      // PRE-FIX the scale was `(stddev ?? 1.0).clamp(1e-6, 1e9)` => 1e-6, so
      // zc = 4e5, d2 ~ 1.6e11 >> the chi-square(2) gate of 13.82 and the night
      // surfaced as an illness anomaly candidate off a 0.4 change.
      final feats = <AnomalyFeatures>[
        for (var i = 0; i < 10; i++)
          AnomalyFeatures(hrv: 40.0 + (i.isEven ? 1.0 : -1.0), temp: 0.0),
        const AnomalyFeatures(hrv: 40.0, temp: 0.4),
        const AnomalyFeatures(hrv: 40.0, temp: 0.4),
      ];
      final dates = [for (var i = 0; i < feats.length; i++) 'd$i'];
      final out =
          multivariateAnomaly(dates, feats, minBaseline: 10, persistDays: 2);

      expect(out[10].candidate, isFalse,
          reason: 'a 0.4 move on a scale-less feature is not an anomaly');
      expect(out[10].mahalanobis, isNull,
          reason: 'only one feature survives => no distance is computable');
      expect(out[10].need, 'degenerate_baseline:no_dispersion');
      expect(out.where((d) => d.flagged), isEmpty);
    });

    test('a feature WITH dispersion still computes normally', () {
      // Same shape, but temp now varies => both features are standardizable.
      final feats = <AnomalyFeatures>[
        for (var i = 0; i < 12; i++)
          AnomalyFeatures(
              hrv: 40.0 + (i.isEven ? 1.0 : -1.0), temp: i.isEven ? 0.1 : -0.1),
      ];
      final dates = [for (var i = 0; i < feats.length; i++) 'd$i'];
      final out =
          multivariateAnomaly(dates, feats, minBaseline: 10, persistDays: 2);
      expect(out[11].mahalanobis, isNotNull);
      expect(out[11].need, isNull);
      expect(out[11].drivers, hasLength(2));
    });
  });

  // -------------------------------------------------------------------------
  // REGRESSION: the glass-box driver detail must name the method ACTUALLY used.
  // -------------------------------------------------------------------------
  group('readinessComposite — disclosed method matches the method used', () {
    test('quantized baseline (MAD=0) discloses the mean/SD fallback', () {
      // Whole-bpm RHR pinned at 55 for most of the window: MAD collapses to 0,
      // robustZ abstains and the deliberate `?? z(v, base)` fallback (#26)
      // produced the contribution. PRE-FIX the detail still said "robust-z".
      final base = <double>[55, 55, 55, 55, 55, 55, 55, 58];
      final m = readinessComposite([rhrInput(60, base)]);
      expect(m.present, isTrue, reason: m.note);
      final d = m.drivers!.single;
      expect(d.detail, contains('mean+SD fallback'));
      expect(d.detail, isNot(contains('robust-z')));
    });

    test('a dispersed baseline still discloses robust-z (median+MAD)', () {
      final base = <double>[50, 52, 54, 56, 58, 60, 62];
      final m = readinessComposite([rhrInput(70, base)]);
      expect(m.present, isTrue, reason: m.note);
      expect(m.drivers!.single.detail, contains('robust-z (median+MAD)'));
    });

    test('a fully constant baseline (MAD=0 AND SD=0) still abstains', () {
      // The fallback is NOT a licence to score against zero dispersion.
      final m =
          readinessComposite([rhrInput(60, List<double>.filled(8, 55.0))]);
      expect(m.present, isFalse);
      expect(m.toJson()['value'], '—');
    });
  });
}
