// Item 2 — FOUNDATIONS. Synthetic, known-answer tests.
import 'package:test/test.dart';
import 'package:openstrap_analytics/onehz.dart';

void main() {
  group('Winsorized-EWMA baselines', () {
    final cfg = Baselines.hrvCfg; // min5 max250 floor5 hlB14 hlS21

    test('first valid night seeds at the value, floor spread, calibrating', () {
      final s = Baselines.update(null, 60.0, cfg);
      expect(s.baseline, 60.0);
      expect(s.spread, cfg.floorSpread);
      expect(s.nValid, 1);
      expect(s.status, BaselineStatus.calibrating);
    });

    test('out-of-range first night seeds at midpoint, nValid 0', () {
      final s = Baselines.update(null, 999.0, cfg); // > maxVal
      expect(s.baseline, (cfg.minVal + cfg.maxVal) / 2.0);
      expect(s.nValid, 0);
      expect(s.nightsSinceUpdate, 1);
    });

    test('hard-outlier night past early life is SEEN but NOT folded', () {
      // Build a settled (non-young, nValid>=8) flat baseline at 60.
      final vals = <double?>[for (var i = 0; i < 10; i++) 60.0];
      final settled = Baselines.foldHistory(vals, cfg);
      expect(settled.nValid, 10);
      expect(settled.baseline, closeTo(60.0, 1e-9));
      // spread is at the floor (flat history), so a value > 5*floor away is hard-rejected.
      final before = settled.baseline;
      final after = Baselines.update(settled, 60.0 + 6 * cfg.floorSpread, cfg);
      expect(after.baseline, before, reason: 'hard outlier not folded');
      expect(after.nValid, settled.nValid, reason: 'nValid unchanged on reject');
    });

    test('early-life fast adapt: a high seed is pulled toward reality in days', () {
      // Seed high at 90, then feed true lower nights at 55. Young (nValid<8) uses
      // halfLife 3 and a suspended hard-outlier gate, so it tracks down fast.
      var s = Baselines.update(null, 90.0, cfg);
      for (var i = 0; i < 4; i++) {
        s = Baselines.update(s, 55.0, cfg);
      }
      // With earlyHalfLifeB=3 (λ≈0.206) over 4 nights from 90 toward 55,
      // it should drop well below the midpoint, proving the anti-anchoring fix.
      expect(s.baseline, lessThan(80.0));
      expect(s.baseline, greaterThan(55.0));
    });

    test('deviation z = (v-baseline)/(1.253*spread)', () {
      final s = BaselineState(
          baseline: 60.0,
          spread: 5.0,
          nValid: 14,
          nightsSinceUpdate: 0,
          status: BaselineStatus.trusted);
      final d = Baselines.deviation(60.0 + 1.253 * 5.0, s);
      expect(d.z, closeTo(1.0, 1e-9));
      expect(d.delta, closeTo(1.253 * 5.0, 1e-9));
      // A value comfortably inside ±σ is in-normal-range.
      expect(Baselines.deviation(62.0, s).inNormalRange, isTrue);
      final d2 = Baselines.deviation(60.0 + 2 * 1.253 * 5.0, s);
      expect(d2.inNormalRange, isFalse);
    });

    test('status thresholds calibrating<4<=provisional<14<=trusted; stale', () {
      expect(Baselines.computeStatus(3, 0), BaselineStatus.calibrating);
      expect(Baselines.computeStatus(4, 0), BaselineStatus.provisional);
      expect(Baselines.computeStatus(14, 0), BaselineStatus.trusted);
      expect(Baselines.computeStatus(14, 15), BaselineStatus.stale);
    });

    test('skip-and-hold on null night increments nightsSinceUpdate', () {
      final seeded = Baselines.update(null, 60.0, cfg);
      final held = Baselines.update(seeded, null, cfg);
      expect(held.baseline, seeded.baseline);
      expect(held.nValid, seeded.nValid);
      expect(held.nightsSinceUpdate, 1);
    });

    test('trailing-30 fallback: mean + sample SD, σ floor, internal spread', () {
      final vals = <double?>[50.0, 60.0, 70.0]; // mean 60, SD=10
      final s = Baselines.rollingMeanSD(vals, cfg);
      expect(s.baseline, closeTo(60.0, 1e-9));
      // SD=10 > floor σ (5); stored as SD/1.253.
      expect(s.spread, closeTo(10.0 / 1.253, 1e-9));
      expect(s.nValid, 3);
    });
  });

  group('RR artifact correction (Lipponen-Tarvainen)', () {
    test('clean physiological series classifies all normal', () {
      // 60 beats around 1000 ms with small +/-15 ms wobble (HRV).
      final rr = <double>[for (var i = 0; i < 60; i++) 1000 + (i.isEven ? 15 : -15)];
      final r = correctRr(rr);
      expect(r.cleanFraction, closeTo(1.0, 1e-9));
      expect(r.droppedCount, 0);
      expect(r.nn.length, 60);
    });

    test('flags EXACTLY one injected isolated ectopic and spline-corrects it', () {
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

  group('PPG SQI gate (Elgendi + Orphanidou)', () {
    test('rejects off-skin / out-of-range HR', () {
      expect(ppgTrust([1, 2, 3, 2, 1], 0).trusted, isFalse); // off-skin
      expect(ppgTrust([1, 2, 3, 2, 1], 220).trusted, isFalse); // hr too high
    });
    test('rejects flatline PPG even with plausible HR', () {
      final r = ppgTrust([5, 5, 5, 5, 5], 60);
      expect(r.trusted, isFalse);
      expect(r.reasons, contains('flatline'));
    });
    test('accepts a skewed, in-range window', () {
      // right-skewed window (systolic-upstroke-like).
      final w = <double>[0, 0, 0, 1, 4, 9, 2, 0, 0, 0];
      final r = ppgTrust(w, 60);
      expect(r.skewness, greaterThan(0));
      expect(r.trusted, isTrue);
    });
    test('RR physiological-plausibility rule', () {
      expect(rrPhysiologicallyPlausible([900, 950, 1000]), isTrue);
      expect(rrPhysiologicallyPlausible([900, 250]), isFalse); // <300
      expect(rrPhysiologicallyPlausible([300, 1000]), isFalse); // ratio>3
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
    test('lambda from half-life: half-life => 0.5 effective at one HL', () {
      final lam = lambdaFromHalfLife(1); // 1 - 2^-1 = 0.5
      expect(lam, closeTo(0.5, 1e-12));
    });
    test('gap-aware EWMA converges and flags gaps', () {
      final t = <double>[0, 1000, 2000, 3000, 100000];
      final v = <double>[10, 10, 10, 10, 20];
      final e = gapAwareEwma(t, v, halfLifeMs: 1000, maxGapMs: 10000);
      expect(e.first.value, 10);
      expect(e.last.gap, isTrue); // the big jump is a flagged gap
      // clamped: one late sample can't fully take over (<= 0.5 weight).
      expect(e.last.value, lessThan(20));
      expect(e.last.value, greaterThan(10));
    });
    test('MDC gate: small change suppressed, large surfaced', () {
      final b = robustBaseline([10, 11, 9, 10, 12, 8, 10, 11, 9, 10]);
      expect(changeExceedsMdc(0.1, b), isFalse);
      expect(changeExceedsMdc(50, b), isTrue);
      // no dispersion known => never claim a change.
      final flat = robustBaseline([5, 5, 5]);
      expect(changeExceedsMdc(99, flat), isFalse);
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
    test('quality->variance and GUM weighted-sum uncertainty', () {
      expect(varianceFromQuality(1.0, 4), 4);
      expect(varianceFromQuality(0.5, 4), 8); // worse quality => more variance
      // y = 0.5*x1 + 0.5*x2, each u=2 => u_c = sqrt(1+1)=1.414
      expect(gumWeightedSumUncertainty([0.5, 0.5], [2, 2])!,
          closeTo(1.41421, 1e-4));
    });
  });
}
