// Item 2 — FOUNDATIONS. Synthetic, known-answer tests.
import 'dart:math' as math;
import 'package:test/test.dart';
import 'package:openstrap_analytics/onehz.dart';

void main() {
  group('Winsorized-EWMA baselines', () {
    final cfg = Baselines.hrvCfg; // min5 max250 floor5 hlB14 hlS21

    test('first valid night seeds at the value, floor spread, calibrating', () {
      final s = Baselines.update(null, 60.0, cfg)!;
      expect(s.baseline, 60.0);
      expect(s.spread, cfg.floorSpread);
      expect(s.nValid, 1);
      expect(s.status, BaselineStatus.calibrating);
    });

    test('out-of-range first night yields NO baseline (was: the midpoint)', () {
      // an-clinical-1. This used to return a state whose baseline was
      // (minVal + maxVal) / 2 = 127.5 ms — a number nobody measured — against
      // which deviation() reported z = -13 for an ordinary 45 ms night.
      expect(Baselines.update(null, 999.0, cfg), isNull); // > maxVal
      expect(Baselines.update(null, null, cfg), isNull);
    });

    test('foldHistory over no usable night is absent, not an invented centre',
        () {
      expect(Baselines.foldHistory(const <double?>[], cfg), isNull);
      expect(Baselines.foldHistory(const <double?>[null, null], cfg), isNull);
      // A single usable night later in the series still builds a real state.
      final s = Baselines.foldHistory(<double?>[null, 52.0], cfg)!;
      expect(s.baseline, 52.0);
      expect(s.nValid, 1);
    });

    test('deviation abstains on a zero-night state', () {
      const empty = BaselineState(
          baseline: 127.5,
          spread: 5.0,
          nValid: 0,
          nightsSinceUpdate: 0,
          status: BaselineStatus.calibrating);
      expect(Baselines.deviation(45.0, empty), isNull);
    });

    test('hard-outlier night past early life is SEEN but NOT folded', () {
      // Build a settled (non-young, nValid>=8) flat baseline at 60.
      final vals = <double?>[for (var i = 0; i < 10; i++) 60.0];
      final settled = Baselines.foldHistory(vals, cfg)!;
      expect(settled.nValid, 10);
      expect(settled.baseline, closeTo(60.0, 1e-9));
      // spread is at the floor (flat history), so a value > 5*floor away is hard-rejected.
      final before = settled.baseline;
      final after = Baselines.update(settled, 60.0 + 6 * cfg.floorSpread, cfg)!;
      expect(after.baseline, before, reason: 'hard outlier not folded');
      expect(after.nValid, settled.nValid,
          reason: 'nValid unchanged on reject');
    });

    test('early-life fast adapt: a high seed is pulled toward reality in days',
        () {
      // Seed high at 90, then feed true lower nights at 55. Young (nValid<8) uses
      // halfLife 3 and a suspended hard-outlier gate, so it tracks down fast.
      var s = Baselines.update(null, 90.0, cfg);
      for (var i = 0; i < 4; i++) {
        s = Baselines.update(s, 55.0, cfg);
      }
      // With earlyHalfLifeB=3 (λ≈0.206) over 4 nights from 90 toward 55,
      // it should drop well below the midpoint, proving the anti-anchoring fix.
      expect(s!.baseline, lessThan(80.0));
      expect(s.baseline, greaterThan(55.0));
    });

    test('deviation z = (v-baseline)/(1.253*spread)', () {
      const s = BaselineState(
          baseline: 60.0,
          spread: 5.0,
          nValid: 14,
          nightsSinceUpdate: 0,
          status: BaselineStatus.trusted);
      final d = Baselines.deviation(60.0 + 1.253 * 5.0, s)!;
      expect(d.z, closeTo(1.0, 1e-9));
      expect(d.delta, closeTo(1.253 * 5.0, 1e-9));
      // A value comfortably inside ±σ is in-normal-range.
      expect(Baselines.deviation(62.0, s)!.inNormalRange, isTrue);
      final d2 = Baselines.deviation(60.0 + 2 * 1.253 * 5.0, s)!;
      expect(d2.inNormalRange, isFalse);
    });

    test('status thresholds calibrating<4<=provisional<14<=trusted; stale', () {
      expect(Baselines.computeStatus(3, 0), BaselineStatus.calibrating);
      expect(Baselines.computeStatus(4, 0), BaselineStatus.provisional);
      expect(Baselines.computeStatus(14, 0), BaselineStatus.trusted);
      expect(Baselines.computeStatus(14, 15), BaselineStatus.stale);
    });

    test('skip-and-hold on null night increments nightsSinceUpdate', () {
      final seeded = Baselines.update(null, 60.0, cfg)!;
      final held = Baselines.update(seeded, null, cfg)!;
      expect(held.baseline, seeded.baseline);
      expect(held.nValid, seeded.nValid);
      expect(held.nightsSinceUpdate, 1);
    });
  });

  group('RR artifact correction (Lipponen-Tarvainen)', () {
    test('clean physiological series classifies all normal', () {
      // 60 beats around 1000 ms with small +/-15 ms wobble (HRV).
      final rr = <double>[
        for (var i = 0; i < 60; i++) 1000 + (i.isEven ? 15 : -15)
      ];
      final r = correctRr(rr);
      expect(r.cleanFraction, closeTo(1.0, 1e-9));
      expect(r.droppedCount, 0);
      expect(r.correctedCount, 0);
      expect(r.nn.length, 60);
      // Nothing was substituted: the cleaned series IS the input.
      for (var i = 0; i < rr.length; i++) {
        expect(r.nn[i], closeTo(rr[i], 1e-12));
      }
    });

    // 400 beats of ORDINARY resting variability: RSA at ~13 beats/breath +
    // a slow LF wave + a little jitter. RR 928-1172 ms, max |dRR| 56 ms,
    // ZERO injected artifacts.
    List<double> cleanRsa() {
      final rnd = math.Random(11);
      return [
        for (var i = 0; i < 400; i++)
          1050 +
              95 * math.sin(2 * math.pi * i / 13.0) +
              25 * math.sin(2 * math.pi * i / 61.0) +
              (rnd.nextDouble() - 0.5) * 10
      ];
    }

    test(
        'REGRESSION: a clean physiological RSA record is NOT flagged — the '
        'quartile deviation is taken on the SIGNED dRR series '
        '(Lipponen-Tarvainen 2019)', () {
      // Taking the QD of |dRR| folds the symmetric ±dRR distribution onto one
      // side, collapsing the dispersion so far that the threshold sinks to the
      // minThresholdMs floor and the detector degenerates into a fixed 100 ms
      // cut-off. On THIS artifact-free record that flagged 32 of 400 healthy
      // beats (cleanFraction 0.92) and shrank SDNN 69.82 -> 64.78 (-7%).
      final rr = cleanRsa();
      var maxAbsDrr = 0.0;
      for (var i = 1; i < rr.length; i++) {
        final d = (rr[i] - rr[i - 1]).abs();
        if (d > maxAbsDrr) maxAbsDrr = d;
      }
      expect(maxAbsDrr, lessThan(100),
          reason: 'sanity: every beat-to-beat step is below the 100 ms floor');

      final r = correctRr(rr);
      expect(r.cleanFraction, 1.0);
      expect(r.correctedCount, 0);
      expect(r.droppedCount, 0);
      expect(r.nn.length, 400);
      // The HRV of a clean record must survive correction untouched.
      final before = hrvTime(rr).value!;
      final after = hrvTime(r.nn).value!;
      expect(after.rmssd!, closeTo(before.rmssd!, 1e-9));
      expect(after.sdnn!, closeTo(before.sdnn!, 1e-9));
    });

    test('a genuine gross outlier is still caught on that same record', () {
      // The signed-QD threshold must not have blinded the detector.
      final rr = cleanRsa();
      rr[200] = 350; // impossible beat
      final r = correctRr(rr);
      expect(r.classes[200], isNot(BeatClass.normal));
      expect(r.cleanFraction, lessThan(1.0));
    });

    test('flags EXACTLY one injected isolated ectopic and spline-corrects it',
        () {
      final rr = <double>[for (var i = 0; i < 60; i++) 1000.0];
      rr[30] = 500; // single short extra beat (isolated)
      final r = correctRr(rr);
      final flagged = [
        for (var i = 0; i < r.classes.length; i++)
          if (r.classes[i] != BeatClass.normal) i
      ];
      expect(flagged, [30]); // exactly the injected index
      expect(r.correctedCount, 1); // isolated -> spline corrected
      expect(r.droppedCount, 0);
      expect(r.nn.length, 60); // length preserved by interpolation
      // Corrected value pulled back toward the ~1000 ms neighborhood.
      expect(r.nn[30], greaterThan(800));
    });

    test('multi-beat run is DROPPED, never interpolated', () {
      final rr = <double>[for (var i = 0; i < 60; i++) 1000.0];
      rr[30] = 400;
      rr[31] = 420; // consecutive => a run of 2
      final r = correctRr(rr);
      expect(r.correctedCount, 0);
      expect(r.droppedCount, greaterThanOrEqualTo(2));
      expect(r.nn.length, lessThan(60)); // dropped, not bridged
    });
  });

  group('robust baseline', () {
    test('median+MAD with Iglewicz-Hoaglin outlier flag', () {
      final b = robustBaseline([10, 11, 9, 10, 12, 8, 10]);
      expect(b.center, 10);
      expect(b.sufficient, isTrue);
      // a value far out is flagged.
      expect(b.isOutlier(100), isTrue);
      expect(b.isOutlier(10), isFalse);
    });
    test('MAD=0 on quantized data => modZ null (no div-by-zero)', () {
      final b = robustBaseline([5, 5, 5, 5, 5]);
      expect(b.scale, 0);
      expect(b.modZ(9), isNull);
      expect(b.isOutlier(9), isNull);
    });
    test('coverage gate', () {
      expect(robustBaseline([1, 2], minValid: 3).sufficient, isFalse);
      expect(robustBaseline([1, 2, 3], minValid: 3).sufficient, isTrue);
    });
    test('MDC: a dispersion-free baseline has no detectable change', () {
      final b = robustBaseline([10, 11, 9, 10, 12, 8, 10, 11, 9, 10]);
      expect(mdc(b)!, greaterThan(0.1));
      expect(mdc(b)!, lessThan(50));
      // no dispersion known => no MDC => never claim a change.
      expect(mdc(robustBaseline([5, 5, 5])), isNull);
    });
  });

  group('inverse-variance fusion + GUM', () {
    test('fuses two estimates, fused variance below each input', () {
      final r = inverseVarianceFuse([
        const FusionInput(100, 4, label: 'a'), // σ=2
        const FusionInput(110, 4, label: 'b'), // σ=2
      ]);
      expect(r.value, closeTo(105, 1e-9)); // equal weights => midpoint
      expect(r.variance, closeTo(2, 1e-9)); // 1/(1/4+1/4)=2 < 4
      expect(r.used, ['a', 'b']);
    });
    test('GATES OUT an untrusted (motion-artifact) channel entirely', () {
      final r = inverseVarianceFuse([
        const FusionInput(100, 1, label: 'good'),
        const FusionInput(50, 1, trusted: false, label: 'artifact'),
      ]);
      expect(r.value, 100); // artifact dropped, not down-weighted
      expect(r.dropped, ['artifact']);
    });
    test('absent when nothing trusted', () {
      final r = inverseVarianceFuse(
          [const FusionInput(1, 1, trusted: false, label: 'x')]);
      expect(r.value, isNull);
    });
  });

  group('RR correction — the beat clock is WALL CLOCK', () {
    test('a dropped run still advances nnTimesMs', () {
      // T-12. Dropped runs used only to bump a counter, never `t`, so the two
      // sides of every dropped run were spliced together: 299.0 s of real
      // record came out as a 294.0 s span. cvhr_per_hour divides by that span,
      // so the apnea screen read high on exactly the noisy nights that needed
      // the correction.
      final rr = <double>[for (var i = 0; i < 300; i++) 1000.0];
      for (var k = 100; k < 105; k++) {
        rr[k] = 250.0; // 5-beat artifact run -> dropped, never interpolated
      }
      var real = 0.0;
      for (final v in rr) {
        real += v;
      }
      final c = correctRr(rr);
      expect(c.droppedCount, greaterThan(1));
      // times[0] is the END of the first interval, so the span is the total
      // elapsed time minus that first interval — exactly, no compaction.
      final span = c.nnTimesMs.last - c.nnTimesMs.first;
      expect(span, closeTo(real - rr.first, 1e-6));
    });

    test('a spline-corrected isolated beat advances by the REAL interval', () {
      // an-clinical-4, the sibling the dropped-run fix above missed. Every
      // ~60th beat is a MISSED detection: one ~2000 ms interval where two
      // ~1000 ms ones belong. The spline emits ~1000 ms as the NN value (right)
      // but the clock used to advance by that 1000 too (wrong) — deleting ~1 s
      // of record per corrected beat, 1.6 % of a night at this rate, which
      // inflated cvhr_per_hour and shortened hrvFreq's spanSec.
      final rr = <double>[
        // The anomaly sits at i % 60 == 30 so the first and last beats are
        // normal — the span below is then exactly total-minus-first-interval.
        for (var i = 0; i < 3600; i++) i % 60 == 30 ? 2000.0 : 1000.0,
      ];
      var real = 0.0;
      for (final v in rr) {
        real += v;
      }
      final c = correctRr(rr);
      expect(c.correctedCount, greaterThan(50),
          reason: 'spline path exercised');
      final span = c.nnTimesMs.last - c.nnTimesMs.first;
      // Exact wall clock: total elapsed minus the first interval. Before the
      // fix this came out ~59 s (1.6 %) short of it.
      expect(span, closeTo(real - rr.first, 1e-6));
      // The emitted NN value is still the interpolated one, not the raw 2000.
      expect(c.nn.reduce((a, b) => a > b ? a : b), lessThan(1500.0));
    });
  });
}
