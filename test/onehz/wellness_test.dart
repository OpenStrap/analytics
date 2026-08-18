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
      final m = tempCircadian(samples, deviceFamily: 'gen4', epochMin: 60);
      expect(m.present, isTrue);
      expect(m.tier, Tier.relative);
      final fit = m.value!.cosinorFit!;
      expect(fit.acrophaseHours, closeTo(peakHour, 0.3));
      expect(fit.amplitude, closeTo(300, 15));
      expect(fit.r2, greaterThan(0.95));
      // Nonparametric: strong clean rhythm => high IS, low IV.
      final np = m.value!.nonparam!;
      expect(np.interdailyStability, greaterThan(0.7));
      expect(np.intradailyVariability, lessThan(0.5));
    });

    test('RD-14: IS is taken about the GRAND mean, not the profile mean', () {
      // Unbalanced epoch-of-day coverage — the normal case on real data, where
      // per-day 24-bin coverage runs 14/24 to 24/24 — plus a level drift across
      // days. Hours 12-23 exist only on the highest day, so the 24-h profile's
      // own mean sits above the grand mean.
      final samples = <AdcSample>[];
      for (var day = 0; day < 3; day++) {
        final hours = day == 2 ? 24 : 12;
        for (var h = 0; h < hours; h++) {
          for (var k = 0; k < 6; k++) {
            final tHours = day * 24.0 + h + k / 6.0;
            final adc = 2000 +
                100.0 * day +
                150 * math.cos(2 * math.pi / 24 * (tHours - 4));
            samples.add(AdcSample(tHours * 3.6e6, adc));
          }
        }
      }
      final np = tempCircadian(samples, deviceFamily: 'gen4', epochMin: 60)
          .value!
          .nonparam!;
      // van Someren's IS puts BOTH variances about the grand mean. Using the
      // profile's own mean minimises the numerator by construction and gives
      // 0.5299 on this fixture — biased low, always in the same direction.
      expect(np.interdailyStability, closeTo(0.5582, 0.0005));
    });

    test('M10/L5/RA are WITHHELD, not merely null (MT-09)', () {
      final samples = <AdcSample>[];
      for (var i = 0; i < 3 * 24 * 6; i++) {
        final tMs = i * 10 * 60 * 1000.0;
        final tHours = tMs / 3.6e6;
        samples.add(
            AdcSample(tMs, 2000 + 300 * math.cos(2 * math.pi / 24 * tHours)));
      }
      final m = tempCircadian(samples, deviceFamily: 'gen4', epochMin: 60);
      final j = m.value!.nonparam!.toJson();
      // Not "absent when unobserved" — absent from the shape entirely, because
      // RA on a median-centred series divides by a quantity that crosses zero.
      for (final k in [
        'm10',
        'l5',
        'm10_onset_hour',
        'l5_onset_hour',
        'relative_amplitude'
      ]) {
        expect(j.containsKey(k), isFalse, reason: k);
      }
      expect(j.containsKey('interdaily_stability'), isTrue);
    });

    test('the family decides the unit and the gate; unknown refuses (MT-09)',
        () {
      final samples = <AdcSample>[];
      for (var i = 0; i < 3 * 24 * 6; i++) {
        final tMs = i * 10 * 60 * 1000.0;
        samples.add(AdcSample(
            tMs, 2000 + 300 * math.cos(2 * math.pi / 24 * (tMs / 3.6e6))));
      }
      expect(tempCircadian(samples, deviceFamily: 'gen4').value!.unit,
          'adc_counts');
      expect(
          tempCircadian(samples, deviceFamily: 'gen5').value!.unit, 'centi_c');
      for (final id in [null, '', 'imported']) {
        final m = tempCircadian(samples, deviceFamily: id);
        expect(m.present, isFalse, reason: 'id=$id');
        expect(m.note, unknownFamilyNote(id));
      }

      // The de-mask gate is per-family: 0.06 g of wrist motion is inside gen4's
      // own resting noise floor and outside gen5's.
      final accel = [
        for (final s in samples) AccelSample(s.tsMs, 0, 0, 1.06),
      ];
      expect(tempCircadian(samples, deviceFamily: 'gen4', accel: accel).note,
          contains('dropped=0'));
      expect(tempCircadian(samples, deviceFamily: 'gen5', accel: accel).present,
          isFalse,
          reason: 'gen5 masks all of it, leaving nothing to fit');
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
      final m = tempCircadian(samples,
          deviceFamily: 'gen4', accel: accel, motionGate: 0.08);
      expect(m.inputs_used, contains('accel'));
      expect(m.note, contains('demasked'));
    });

    test('absent on too-few epochs', () {
      final m = tempCircadian([AdcSample(0, 2000)], deviceFamily: 'gen4');
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

    // MT-10. The BIC penalty is a significance test; the MDC gate is an
    // effect-size test. A step the instrument cannot resolve is not a finding
    // however clean it is, and this is the guard that gets quietly dropped.
    test('a statistically clean step SMALLER than the MDC is not reported', () {
      // Noisy pre-segment (MAD ~1.5 bpm ⇒ MDC ~4 bpm) with a perfectly clean
      // 2 bpm step: binary segmentation loves it, the body cannot resolve it.
      const noise10 = <double>[0, 1, -1, 2, -2, 1, -1, 0, 2, -2];
      final x = [
        for (var i = 0; i < 30; i++) 55.0 + noise10[i % 10],
        for (var i = 0; i < 30; i++) 57.0 + noise10[i % 10],
      ];
      final m = segmentChangePoints(x, minSeg: 7);
      expect(m.value!.changePoints, isEmpty);
      expect(m.note, contains('dropped=1'));
      expect(m.note, contains('UNDER-SPLITS'),
          reason: 'an empty result is not evidence of stability');

      // The same series with a 6 bpm step clears the MDC and is reported.
      final big = [
        for (var i = 0; i < 30; i++) 55.0 + noise10[i % 10],
        for (var i = 0; i < 30; i++) 61.0 + noise10[i % 10],
      ];
      expect(segmentChangePoints(big, minSeg: 7).value!.changePoints,
          hasLength(1));
    });

    // STAT-05. The penalty shipped at HALF the BIC it claimed to be
    // (`penaltyK = 1.0` where BIC = (diffparam+1)·log n = 2·σ̂²·ln n for the
    // Normal change-in-mean), so the search proposed boundaries the criterion
    // it names would never have proposed — and only the MDC gate downstream
    // stopped them reaching the user.
    test('the penalty is BIC, not half of it (STAT-05)', () {
      const noise10 = <double>[0, 1, -1, 2, -2, 1, -1, 0, 2, -2];
      final x = [
        for (var i = 0; i < 30; i++) 55.0 + noise10[i % 10],
        for (var i = 0; i < 30; i++) 56.0 + noise10[i % 10],
      ];
      // At the shipped-then half-penalty the search DID split here.
      expect(segmentChangePoints(x, minSeg: 7, penaltyK: 1.0).note,
          contains('dropped=1'));
      // At BIC it never proposes the boundary at all.
      expect(segmentChangePoints(x, minSeg: 7).note, contains('dropped=0'));
      expect(segmentChangePoints(x, minSeg: 7).value!.changePoints, isEmpty);
    });

    // STAT-07. `cusumChangePoints` was purely positional, and its only
    // production caller feeds it a COMPACTED series (days with no nocturnal RHR
    // are skipped — "most days for some users"). So a pre-change regime spanned
    // wear gaps and the accumulator carried evidence across months.
    test('a wear gap breaks the regime and the accumulator (STAT-07)', () {
      const noise10 = <double>[0, 1, -1, 2, -2, 1, -1, 0, 2, -2];
      final x = [
        for (var i = 0; i < 30; i++) 55.0 + noise10[i % 10],
        for (var i = 0; i < 30; i++) 70.0 + noise10[i % 10],
      ];
      String day(int n) => DateTime.utc(2026, 1, 1)
          .add(Duration(days: n))
          .toIso8601String()
          .substring(0, 10);
      // 30 consecutive days, 60 days off-wrist, then 30 consecutive days at a
      // different level. Positionally that is one clean step.
      final dates = [
        for (var i = 0; i < 30; i++) day(i),
        for (var i = 0; i < 30; i++) day(90 + i),
      ];
      expect(cusumChangePoints(x, h: 5.0), isNotEmpty,
          reason: 'positional: the gap is invisible');
      expect(cusumChangePoints(x, dates: dates, h: 5.0), isEmpty,
          reason: 'no observations across the gap ⇒ no evidence to carry');
      // Consecutive dates leave the old behaviour exactly as it was.
      final contiguous = [for (var i = 0; i < 60; i++) day(i)];
      expect(cusumChangePoints(x, dates: contiguous, h: 5.0),
          hasLength(cusumChangePoints(x, h: 5.0).length));
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
        tempInput(2000.0, around(2000.0), settledFraction: 0.97),
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
        tempInput(2000.0, around(2000.0), settledFraction: 0.97),
      ]);
      expect(m.value!.score, closeTo(50, 8));
      expect(m.value!.toJson().containsKey('meaningful'), isFalse);
    });

    test('weights renormalize over present inputs; absent => "—"', () {
      final present = readinessComposite([
        hrvInput(70.0, around(60.0)),
        rhrInput(55.0, around(55.0)),
      ]);
      expect(present.present, isTrue);
      expect(present.inputs_used, ['HRV', 'RHR']);

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
      // minInputs:1 — the subject here is the MAD==0 rescue, not the RD-04
      // minimum-inputs gate (which has its own test below).
      final m = readinessComposite([rhrInput(56.0, tightBase)],
          minInputs: 1, minWeightSum: 0.0);
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
      final m =
          tempCircadian(temp, deviceFamily: 'gen4', accel: accel, epochMin: 1);
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
        rhrInput(55.0, [54.0, 55.0, 56.0, 55.0, 54.0]),
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
      final m = readinessComposite([rhrInput(60, base)],
          minInputs: 1, minWeightSum: 0.0);
      expect(m.present, isTrue, reason: m.note);
      final d = m.drivers!.single;
      expect(d.detail, contains('mean+SD fallback'));
      expect(d.detail, isNot(contains('robust-z')));
    });

    test('a dispersed baseline still discloses robust-z (median+MAD)', () {
      final base = <double>[50, 52, 54, 56, 58, 60, 62];
      final m = readinessComposite([rhrInput(70, base)],
          minInputs: 1, minWeightSum: 0.0);
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

  // -------------------------------------------------------------------------
  // RD-15 / RD-05 — a warming strap must not read as a recovered person.
  //
  // Numbers pinned from whoop-4.db, the 8 real gen4 nights the audit measured
  // (sleep windows from v_hypnogram, skin_temp_raw from decoded_onehz). Nightly
  // means recomputed here match the shipped `skin_temp_adc` series exactly.
  // -------------------------------------------------------------------------
  group('nightlySkinTemp (RD-15 settled fraction)', () {
    // One night, 1 Hz: 8 h at 805 counts with a 2 h segment ~100 counts colder
    // in the middle — the shape of 2026-08-14, whose real settled fraction is
    // 0.787 and whose plain mean (784.20) sat -3.17 robust-z below the trailing
    // baseline, i.e. +7.6 readiness points of "recovery" from a cold strap.
    List<AdcSample> night({required int coldSec, int totalSec = 28800}) => [
          for (var i = 0; i < totalSec; i++)
            AdcSample(
                i * 1000.0, (i >= 6000 && i < 6000 + coldSec) ? 700.0 : 805.0),
        ];

    test('a settled night keeps its samples and its mean', () {
      final m = nightlySkinTemp(night(coldSec: 0), deviceFamily: 'gen4');
      expect(m.present, isTrue, reason: m.note);
      expect(m.value!.settledFraction, 1.0);
      expect(m.value!.mean, closeTo(805.0, 1e-9));
      expect(m.value!.unit, 'adc_counts');
    });

    test('a cold segment is trimmed out of the mean', () {
      // 5 % cold: passes the 0.80 floor, but the plain mean would be 799.75.
      final m = nightlySkinTemp(night(coldSec: 1440), deviceFamily: 'gen4');
      expect(m.present, isTrue, reason: m.note);
      expect(m.value!.settledFraction, closeTo(0.95, 1e-9));
      expect(m.value!.mean, closeTo(805.0, 1e-9));
    });

    test('a night that spent 25 % below skin temperature REFUSES', () {
      final m = nightlySkinTemp(night(coldSec: 7200), deviceFamily: 'gen4');
      expect(m.present, isFalse);
      expect(m.note, startsWith('unsettled_skin_temp:settled=0.75'));
      expect(m.toJson()['value'], '—');
    });

    test('a FEVER is not trimmed — the band is one-sided', () {
      // The exact mirror of the refused night above: same 25 % excursion, same
      // 100-count size, only UPWARD. It survives whole, because "not skin" is a
      // statement about cold readings and a fever is the signal this channel
      // exists to carry.
      final hot = [
        for (var i = 0; i < 28800; i++)
          AdcSample(i * 1000.0, (i >= 6000 && i < 13200) ? 905.0 : 805.0),
      ];
      final m = nightlySkinTemp(hot, deviceFamily: 'gen4');
      expect(m.present, isTrue, reason: m.note);
      expect(m.value!.settledFraction, 1.0);
      expect(m.value!.mean, closeTo(830.0, 1e-9));
    });

    test('gen5 has no measured band and unknown families refuse', () {
      for (final id in <String?>['gen5', null, '', 'gen6']) {
        final m = nightlySkinTemp(night(coldSec: 0), deviceFamily: id);
        expect(m.present, isFalse, reason: 'family $id must not borrow gen4');
        expect(m.note, startsWith('unknown_device_family:'));
      }
    });

    test('under the 60-sample floor it says how short it was', () {
      final m = nightlySkinTemp(
          [for (var i = 0; i < 30; i++) AdcSample(i * 1000.0, 805.0)],
          deviceFamily: 'gen4');
      expect(m.present, isFalse);
      expect(m.note, 'need_baseline:have=30,need=60');
    });
  });

  group('tempInput settled gate (RD-05)', () {
    List<double> around(double c) =>
        [for (var i = 0; i < 14; i++) c + (i.isEven ? 1.0 : -1.0)];

    // The whoop-4 2026-08-14 shape: temp reads far BELOW baseline and
    // goodSign = -1 turns that into "good", so readiness goes UP.
    List<ReadinessInput> inputs(double? settled) => [
          hrvInput(60.0, around(60.0)),
          rhrInput(55.0, around(55.0)),
          tempInput(784.2, around(805.0), settledFraction: settled),
        ];

    test('an unsettled night drops the temp driver, it never pays out', () {
      final ungated = readinessComposite(inputs(0.97));
      final gated = readinessComposite(inputs(0.787)); // the real 08-14 value
      expect(ungated.inputs_used, contains('temp'));
      expect(gated.inputs_used, isNot(contains('temp')));
      expect(gated.value!.score, lessThan(ungated.value!.score),
          reason: 'a cold strap was buying readiness points');
      expect(gated.note, contains('unsettled_skin_temp:settled=0.787'));
    });

    test('an unmeasured settled fraction is a refusal, not a pass', () {
      final m = readinessComposite(inputs(null));
      expect(m.inputs_used, isNot(contains('temp')));
      expect(m.note, contains('no settled fraction measured'));
    });

    test('the channel itself is untouched — a settled night still drives', () {
      final m = readinessComposite(inputs(0.90));
      expect(m.inputs_used, contains('temp'));
      expect(m.drivers!.map((d) => d.label), contains('temp'));
    });
  });

  group('readinessComposite minimum inputs (RD-04)', () {
    List<double> around(double c) =>
        [for (var i = 0; i < 14; i++) c + (i.isEven ? 1.0 : -1.0)];

    test('one surviving input is not a composite', () {
      // temp alone: its disclosed 0.10 would renormalise to an effective 1.0.
      final m = readinessComposite(
          [tempInput(760.0, around(805.0), settledFraction: 0.99)]);
      expect(m.present, isFalse);
      expect(m.note, startsWith('need_inputs:have=1,need=2'));
      expect(m.inputs_used, ['temp']);
    });

    test('RR + temp clear the count but not the weight floor', () {
      final m = readinessComposite([
        respInput(14.0, around(14.0)),
        tempInput(805.0, around(805.0), settledFraction: 0.99),
      ]);
      expect(m.present, isFalse, reason: '0.20 + 0.10 = 0.30 < 0.5');
      expect(m.note, contains('need_weight=0.5'));
    });

    test('HRV + RHR compute', () {
      final m = readinessComposite([
        hrvInput(60.0, around(60.0)),
        rhrInput(55.0, around(55.0)),
      ]);
      expect(m.present, isTrue, reason: m.note);
    });
  });

  // -------------------------------------------------------------------------
  // RD-07 — the chi-square gate assumed a KNOWN scale. Pinned against the
  // 200k-trial Monte Carlo in the docstring of `_madInflationTable`.
  // -------------------------------------------------------------------------
  group('multivariateAnomaly small-sample gate (RD-07)', () {
    /// Deterministic pseudo-normal noise — no dart:math Random seeding games,
    /// just a fixed sequence with mean 0 and unit-ish spread.
    double noise(int i) =>
        math.sin(i * 1.7) + 0.6 * math.sin(i * 0.31) + 0.4 * math.cos(i * 2.9);

    test('the gate widens when the baseline is small and relaxes as it grows',
        () {
      // The audit's measured false-candidate rate against the bare chi2(0.999)
      // gate was 0.197/night at n=10, dof=4 — 196x nominal. The widening below
      // is the empirical 99.9 %ile of d2 over that quantile.
      List<AnomalyDay> run(int n) {
        final feats = <AnomalyFeatures>[
          for (var i = 0; i < n + 1; i++)
            AnomalyFeatures(
              rhr: 55 + noise(i),
              hrv: 4.0 + 0.1 * noise(i + 40),
              temp: 805 + 6 * noise(i + 80),
              resp: 15 + noise(i + 120),
            ),
        ];
        final dates = [
          for (var i = 0; i < feats.length; i++)
            DateTime.utc(2026, 1, 1)
                .add(Duration(days: i))
                .toIso8601String()
                .substring(0, 10)
        ];
        return multivariateAnomaly(dates, feats,
            baselineDays: 400, minBaseline: 10, persistDays: 2);
      }

      // Same night, same distance — only the gate moves with the baseline size.
      final small = run(10).last;
      final large = run(120).last;
      expect(small.mahalanobis, isNotNull);
      expect(large.mahalanobis, isNotNull);
      // An explicit gate bypasses the widening entirely (unchanged contract).
      final fixed = multivariateAnomaly(
        [for (var i = 0; i < 12; i++) 'd$i'],
        [
          for (var i = 0; i < 12; i++)
            AnomalyFeatures(rhr: 55 + noise(i), hrv: 4.0 + 0.1 * noise(i + 40)),
        ],
        minBaseline: 10,
        chiSqGate: 0.0,
      );
      expect(fixed.where((d) => d.candidate), isNotEmpty,
          reason: 'chiSqGate must still be honoured verbatim');
    });

    test('a d2 that clears bare chi2 at n=10 no longer becomes a candidate',
        () {
      // dof 2 => bare gate 13.82. Ten baseline nights of tight noise then one
      // night ~4 robust-z out on both features: d2 lands well over 13.82 but
      // under 13.82 x 13.23, which is where the measured 99.9 %ile actually is.
      final feats = <AnomalyFeatures>[
        for (var i = 0; i < 10; i++)
          AnomalyFeatures(rhr: 55 + noise(i), hrv: 4.0 + 0.1 * noise(i + 40)),
        const AnomalyFeatures(rhr: 59.0, hrv: 3.65),
      ];
      final dates = [for (var i = 0; i < feats.length; i++) 'd$i'];
      final bare =
          multivariateAnomaly(dates, feats, minBaseline: 10, chiSqGate: 13.82);
      final widened = multivariateAnomaly(dates, feats, minBaseline: 10);
      expect(
          bare.last.mahalanobis! * bare.last.mahalanobis!, greaterThan(13.82));
      expect(bare.last.candidate, isTrue);
      expect(widened.last.candidate, isFalse,
          reason: 'a MAD over ten nights is not a known scale');
    });
  });
}
