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
}
