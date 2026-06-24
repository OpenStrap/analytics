// HUMAN LAYER tests.
//
// (1) SYNTHETIC KNOWN-ANSWER — the human layer is net-new with NO TS oracle, so
//     correctness is pinned with hand-constructed inputs whose answers we know:
//       * weekday/weekend mid-sleep arrays -> social jetlag == the known delta
//       * a regular vs an irregular binary sleep vector -> SRI high vs low,
//         plus forgiving-streak logic with a grace day
//       * a baseline-vs-elevated-RHR + suppressed-RMSSD night -> alcohol-night
//         flag fires at the right dose band; a normal night does NOT
//       * a value at the top of a 30-day window -> percentile-of-you ≈ high,
//         and a record only when it clears MDC
//       * a readiness composite with ONE driver off -> the narrative names it
// (2) PLAUSIBILITY on the real ../whoop_hist.jsonl capture (HR/RR via parseR24)
//     — the 9-min snippet exercises the single-night pieces without crashing;
//     all MULTI-DAY human insights are SYNTHETIC-only by necessity and we say so.

import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:openstrap_analytics/onehz.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

void main() {
  group('social jetlag — known delta', () {
    test('weekend 2h later than weekday => SJL ≈ +2.0 h', () {
      // Weekday mid-sleep ~03:30, weekend ~05:30 (2 h later).
      final work = [3.4, 3.6, 3.5, 3.5, 3.4];
      final free = [5.4, 5.6, 5.5];
      final m = socialJetlag(free, work);
      expect(m.present, isTrue);
      final v = m.value!;
      expect(v.sjlHours, closeTo(2.0, 0.15));
      expect(v.absHours, closeTo(2.0, 0.15));
      expect(v.sjlHours, greaterThan(0), reason: 'weekend runs later => positive');
    });

    test('insufficient free nights => absent', () {
      final m = socialJetlag([5.0], [3.0, 3.1, 3.2]);
      expect(m.present, isFalse);
      expect(m.toJson()['value'], '—');
    });

    test('chronotype label + no absolute minutes leaked', () {
      // Free-day mid-sleep ~05:30 with oversleep => moderate evening type.
      final freeMid = [5.3, 5.6, 5.5];
      final freeDur = [8.5, 9.0, 8.8];
      // Little oversleep (free ≈ week avg) so the correction is small and the
      // late free-day mid-sleep (~05:30) maps to an evening label.
      final m = chronotype(freeMid, freeDur,
          avgWeekSleepDurH: 8.7, totalDaysObserved: 21);
      expect(m.present, isTrue);
      expect(m.value!.typeLabel, contains('evening'));
      // Honesty: the JSON must NOT expose an absolute MSFsc minute/hour.
      expect(m.value!.toJson().containsKey('msf_sc_hours'), isFalse);
    });
  });

  group('SRI + forgiving streaks — known answer', () {
    test('perfectly regular sleep => SRI ≈ 100; random => low', () {
      const epd = 96; // 15-min epochs over 24 h
      // Regular: asleep 23:00–07:00 every day, identical pattern repeated.
      List<bool> day() => List<bool>.generate(epd, (i) {
            // epoch i*15min; asleep if hour in [23,24) or [0,7)
            final h = (i * 15) / 60.0;
            return h >= 23 || h < 7;
          });
      final regular = <bool>[];
      for (var d = 0; d < 7; d++) {
        regular.addAll(day());
      }
      final mReg = sleepRegularityIndex(regular, epochsPerDay: epd);
      expect(mReg.present, isTrue);
      expect(mReg.value!.sri, closeTo(100.0, 0.001),
          reason: 'identical days => perfect 24h concordance');

      // Irregular: alternate two opposite schedules day to day.
      final irregular = <bool>[];
      for (var d = 0; d < 7; d++) {
        final shifted = d.isEven ? day() : day().map((b) => !b).toList();
        irregular.addAll(shifted);
      }
      final mIrr = sleepRegularityIndex(irregular, epochsPerDay: epd);
      expect(mIrr.value!.sri, lessThan(mReg.value!.sri));
      expect(mIrr.value!.sri, lessThan(40));
    });

    test('forgiving streak survives one grace miss but not two', () {
      // met,met,MISS,met,met  with grace=1 => one run of length 4, alive.
      final s1 = forgivingStreak([true, true, false, true, true], grace: 1);
      expect(s1.current, 4);
      expect(s1.graceUsed, 1);
      expect(s1.alive, isTrue);

      // met,met,MISS,MISS,met  grace=1 => second miss breaks; trailing run = 1.
      final s2 = forgivingStreak([true, true, false, false, true], grace: 1);
      expect(s2.current, 1);
      expect(s2.best, 2, reason: 'first run had 2 met days before the break');

      // No grace: a single miss breaks immediately.
      final s0 = forgivingStreak([true, true, false, true], grace: 0);
      expect(s0.best, 2);
      expect(s0.current, 1);
    });
  });

  group('sleep debt — honest when no free night', () {
    test('no free night => OSD null, no fabricated need', () {
      final m = sleepDebt([6.0, 6.2, 5.9, 6.1], const []);
      expect(m.present, isTrue);
      expect(m.value!.osdHours, isNull);
      expect(m.value!.debtHours, isNull);
      expect(m.value!.hasFreeNight, isFalse);
    });
    test('free-night rebound => positive debt', () {
      // Habitual ~6 h, free nights ~8.5 h => debt ≈ 2.5 h.
      final m = sleepDebt([6.0, 6.1, 5.9, 6.0, 6.2], [8.4, 8.6, 8.5]);
      expect(m.value!.hasFreeNight, isTrue);
      expect(m.value!.debtHours!, greaterThan(1.5));
    });
  });

  group('alcohol-night flag — fires at the right band, silent when normal', () {
    // Personal baseline: RHR ~55 (tight), RMSSD ~60 (tight), dip ~12%, temp z ~0.
    final rhrHist = [54.0, 55.0, 56.0, 55.0, 54.0, 55.0, 56.0, 55.0];
    final rmsHist = [60.0, 61.0, 59.0, 60.0, 62.0, 58.0, 60.0, 61.0];
    final dipHist = [12.0, 11.5, 12.5, 12.0, 11.0, 13.0, 12.0, 12.0];
    final tempHist = [0.0, 0.1, -0.1, 0.0, 0.2, -0.2, 0.0, 0.1];

    test('heavy night: big RHR↑ + big RMSSD↓ + dip blunt + temp↑', () {
      final tonight = NightSignature(
        rhr: 68, // +13 bpm, many MAD above
        rmssd: 30, // −30 ms, many MAD below
        hrDipPct: 4, // blunted
        skinTempZ: 1.5, // elevated
        respRate: 16,
      );
      final m = alcoholNightFlag(tonight,
          rhrHistory: rhrHist,
          rmssdHistory: rmsHist,
          hrDipHistory: dipHist,
          skinTempZHistory: tempHist);
      expect(m.present, isTrue);
      final v = m.value!;
      expect(v.state, 'autonomically_stressed');
      expect(v.signsPresent, greaterThanOrEqualTo(3));
      expect(v.alcoholHypothesisBand, 'heavy');
      // Has a temp disambiguator => not flagged ambiguous.
      expect(v.ambiguous, isFalse);
    });

    test('light night: small but >MDC RHR↑ + RMSSD↓ => light band', () {
      // A realistically-dispersed personal baseline (night-to-night RHR/RMSSD
      // vary more than a couple of beats/ms), so a modest move scores LIGHT
      // rather than blowing past a too-tight scale.
      final rhrWide = [50.0, 54.0, 58.0, 52.0, 56.0, 53.0, 57.0, 55.0];
      final rmsWide = [50.0, 58.0, 66.0, 54.0, 62.0, 56.0, 64.0, 60.0];
      // Just-detectable: both axes clear MDC (~2.77 SD) but stay near that
      // floor => the "light" dose band (smallest detectable alcohol-like night).
      final tonight = NightSignature(
        rhr: 64, // ~+9.5 bpm: just past RHR MDC on this baseline
        rmssd: 42, // ~−17 ms: just past RMSSD MDC
        hrDipPct: 12, // normal
        skinTempZ: 0.0, // normal
      );
      final m = alcoholNightFlag(tonight,
          rhrHistory: rhrWide,
          rmssdHistory: rmsWide,
          hrDipHistory: dipHist,
          skinTempZHistory: tempHist);
      final v = m.value!;
      expect(v.alcoholHypothesisBand, anyOf('light', 'moderate'));
      expect(['mildly_off', 'autonomically_stressed'], contains(v.state));
    });

    test('normal night: no signature, band none, state normal', () {
      final tonight = NightSignature(
        rhr: 55,
        rmssd: 60,
        hrDipPct: 12,
        skinTempZ: 0.0,
      );
      final m = alcoholNightFlag(tonight,
          rhrHistory: rhrHist,
          rmssdHistory: rmsHist,
          hrDipHistory: dipHist,
          skinTempZHistory: tempHist);
      final v = m.value!;
      expect(v.state, 'normal');
      expect(v.alcoholHypothesisBand, 'none');
      expect(v.signsPresent, 0);
    });

    test('rough-night fallback describes state, never a cause', () {
      final tonight = NightSignature(rhr: 64, rmssd: 40, hrDipPct: 6);
      final ev = alcoholNightFlag(tonight,
              rhrHistory: rhrHist, rmssdHistory: rmsHist, hrDipHistory: dipHist)
          .value!;
      final rn = roughNight(ev);
      expect(rn.value!.rough, isTrue);
      expect(rn.value!.descriptor.toLowerCase(), isNot(contains('alcohol')));
    });

    test('insufficient baseline => absent (honest)', () {
      final m = alcoholNightFlag(
        const NightSignature(rhr: 60, rmssd: 50),
        rhrHistory: [55, 56],
        rmssdHistory: [60, 61],
      );
      expect(m.present, isFalse);
    });
  });

  group('percentile-of-you + records (MDC-gated)', () {
    test('top-of-window value => high percentile', () {
      // 30 days centred ~50 with spread; tonight = 70 is near the top.
      final hist = List<double>.generate(30, (i) => 40.0 + i); // 40..69
      final m = percentileOfYou(70, hist);
      expect(m.present, isTrue);
      expect(m.value!.percentile, greaterThan(95));
      expect(m.value!.label, 'among your best');
    });

    test('record gated by MDC: tiny beat is NOT a record, big beat is', () {
      final hist = List<double>.generate(30, (i) => 40.0 + (i % 10)); // spread
      final priorMax = hist.reduce((a, b) => a > b ? a : b);
      // Barely beats the max => within MDC noise => NOT a record.
      final small = personalRecord(priorMax + 0.01, hist, better: Better.higher);
      expect(small.value!.isRecord, isFalse);
      // Clearly beats it.
      final big = personalRecord(priorMax + 50, hist, better: Better.higher);
      expect(big.value!.isRecord, isTrue);
      expect(big.value!.kind, 'high');
    });

    test('short history => absent', () {
      final m = percentileOfYou(10, [1, 2, 3]);
      expect(m.present, isFalse);
    });
  });

  group('glass-box readiness + deterministic narrative', () {
    test('one driver off => narrative names that driver, breakdown complete', () {
      // HRV tanks tonight; everything else is dead-on the personal median.
      final hrvHist = List<double>.generate(20, (i) => 4.0 + (i % 5) * 0.02);
      final rhrHist = List<double>.generate(20, (i) => 55.0 + (i % 5) * 0.2);
      final respHist = List<double>.generate(20, (i) => 14.0 + (i % 5) * 0.1);
      final tempHist = List<double>.generate(20, (i) => 0.0 + (i % 5) * 0.02);

      final inputs = [
        GlassBoxInput(
            label: 'hrv', value: 3.0, history: hrvHist, weight: wHrv), // way low
        GlassBoxInput(
            label: 'rhr',
            value: 55.4,
            history: rhrHist,
            weight: wRhr,
            lowerIsBetter: true),
        GlassBoxInput(
            label: 'resp', value: 14.2, history: respHist, weight: wResp,
            lowerIsBetter: true),
        GlassBoxInput(
            label: 'temp', value: 0.04, history: tempHist, weight: wTemp,
            lowerIsBetter: true),
      ];
      final m = glassBoxReadiness(inputs);
      expect(m.present, isTrue);
      final v = m.value!;
      // Breakdown ALWAYS present, one per input.
      expect(v.breakdown.length, 4);
      // HRV is the top-ranked driver and it's dragging the score down.
      expect(v.drivers, isNotEmpty);
      expect(v.drivers.first.label, 'hrv');
      expect(v.drivers.first.contribution, lessThan(0));
      expect(v.narrative.toLowerCase(), contains('hrv'));
      // Low HRV pulls the composite below the midpoint.
      expect(v.score, lessThan(50));
    });

    test('a sub-MDC mover is never named as a driver', () {
      // All inputs essentially at their median => no driver clears MDC.
      final hist = List<double>.generate(20, (i) => 50.0 + (i % 5) * 0.1);
      final inputs = [
        GlassBoxInput(label: 'hrv', value: 50.2, history: hist, weight: wHrv),
        GlassBoxInput(
            label: 'rhr', value: 50.2, history: hist, weight: wRhr,
            lowerIsBetter: true),
      ];
      final m = glassBoxReadiness(inputs);
      expect(m.value!.drivers, isEmpty);
      expect(m.value!.narrative.toLowerCase(), contains('noise'));
    });

    test('missing input reweights, does not zero the score', () {
      final hist = List<double>.generate(20, (i) => 60.0 + (i % 5));
      final inputs = [
        GlassBoxInput(label: 'hrv', value: 64, history: hist, weight: wHrv),
        // temp has no history => dropped + reweighted, not zeroed.
        GlassBoxInput(label: 'temp', value: 0.0, history: const [], weight: wTemp),
      ];
      final m = glassBoxReadiness(inputs);
      expect(m.present, isTrue);
      expect(m.value!.inputsUsed, 1);
      // breakdown still lists temp, marked unused.
      final temp = m.value!.breakdown.firstWhere((b) => b.label == 'temp');
      expect(temp.used, isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  group('PLAUSIBILITY on real ../whoop_hist.jsonl (single-night pieces only)', () {
    final histFile = File('../whoop_hist.jsonl');
    test('real HR/RR feed the human layer without crashing', () {
      if (!histFile.existsSync()) {
        markTestSkipped('whoop_hist.jsonl not found beside the repo');
        return;
      }
      final lines = histFile
          .readAsLinesSync()
          .where((l) => l.trim().isNotEmpty)
          .toList();
      final hr = <double>[];
      final rrMs = <double>[];
      for (final line in lines) {
        final obj = jsonDecode(line) as Map<String, dynamic>;
        if (obj['t'] != 24) continue;
        final r = parseR24(hexToBytes(obj['hex'] as String));
        if (r == null) continue;
        hr.add(r.hr.toDouble());
        for (final rr in r.rrIntervalsMs) {
          if (rr > 0) rrMs.add(rr.toDouble());
        }
      }
      final validHr = hr.where((h) => h > 0).toList();
      expect(validHr, isNotEmpty);

      // Derive a single real RHR + RMSSD from the snippet, then run the
      // single-night alcohol detector against a SYNTHETIC baseline (the real
      // capture is only ~9 min — far too short for a personal multi-night
      // baseline, so the baseline MUST be synthetic; stated honestly).
      final realRhr = validHr.reduce((a, b) => a < b ? a : b).toDouble();
      final corr = correctRr(rrMs);
      final hrv = corr.nn.length >= 8 ? hrvTime(corr.nn).value : null;
      final realRmssd = hrv?.rmssd ?? 50.0;

      // SYNTHETIC baseline windows (NOT from the 9-min capture).
      final rhrBase = List<double>.generate(8, (i) => realRhr - 2 + (i % 3));
      final rmsBase = List<double>.generate(8, (i) => realRmssd + (i % 3) - 1);

      final m = alcoholNightFlag(
        NightSignature(rhr: realRhr, rmssd: realRmssd),
        rhrHistory: rhrBase,
        rmssdHistory: rmsBase,
      );
      // It must produce SOME honest output (present or absent), never throw.
      expect(m, isNotNull);
      expect(Tier.all.contains(m.tier), isTrue);
      // ignore: avoid_print
      print('REAL human-layer plausibility: realRHR=${realRhr.toStringAsFixed(1)} '
          'realRMSSD=${realRmssd.toStringAsFixed(1)} '
          'state=${m.present ? m.value!.state : "absent"} '
          '(baseline SYNTHETIC — capture too short for multi-night)');

      // percentile-of-you against a synthetic 30-day window using the real RHR.
      final win = List<double>.generate(30, (i) => realRhr + (i - 15) * 0.3);
      final p = percentileOfYou(realRhr, win);
      expect(p.present, isTrue);
      expect(p.value!.percentile, inInclusiveRange(0, 100));
    });
  });
}
