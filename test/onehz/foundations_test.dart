// Item 2 — FOUNDATIONS. Synthetic, known-answer tests.
import 'package:test/test.dart';
import 'package:openstrap_analytics/onehz.dart';

void main() {
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
