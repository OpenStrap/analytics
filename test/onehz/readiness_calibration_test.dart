import 'dart:math' as math;

import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

List<double> around(double c, double step) =>
    [for (var i = 0; i < 14; i++) c + (i.isEven ? step : -step)];

void main() {
  group('autonomic input (HRV + RHR count once)', () {
    test('HRV and RHR share 0.70 as the mean of their oriented z', () {
      final m = readinessComposite([
        hrvInput(4.0, around(4.5, 0.1)), // well below baseline
        rhrInput(60.0, around(52.0, 2.0)), // well above baseline
        respInput(14.0, around(14.0, 0.5)), // at baseline
        tempInput(2000.0, around(2000.0, 2.0), settledFraction: 0.97),
      ]);
      final c = {for (final d in m.drivers!) d.label: d.contribution};
      double oz(String l) => double.parse(
          m.drivers!.firstWhere((d) => d.label == l).detail!.split('=').last);
      final zH = oz('HRV'), zR = oz('RHR');
      // RR and temp sit on their medians (z 0), so the composite is the
      // autonomic input alone: 0.70 × mean(zH, zR) over a total weight of 1.0.
      expect(m.value!.compositeZ, closeTo(0.70 * (zH + zR) / 2, 1e-5));
      expect(c['HRV'], closeTo(0.35 * zH, 1e-5));
      expect(c['RHR'], closeTo(0.35 * zR, 1e-5));
    });

    test('one autonomic member alone carries the whole 0.70', () {
      final r = combineReadinessZ([
        (label: 'HRV', weight: 0.40, orientedZ: -1.0),
        (label: 'RR', weight: 0.20, orientedZ: 1.0),
      ]);
      expect(r.weightSum, closeTo(0.90, 1e-12));
      expect(r.z, closeTo((0.70 * -1.0 + 0.20 * 1.0) / 0.90, 1e-12));
    });

    test('a correlated HRV/RHR dip no longer outweighs everything else', () {
      // Old weights: (0.4·-2 + 0.3·-2 + 0.2·2 + 0.1·2)/1.0 = -0.8.
      // Autonomic group: (0.7·-2 + 0.2·2 + 0.1·2)/1.0 = -0.8 too — the merge
      // changes nothing when the two agree; it matters when they disagree.
      final agree = combineReadinessZ([
        (label: 'HRV', weight: 0.4, orientedZ: -2.0),
        (label: 'RHR', weight: 0.3, orientedZ: -2.0),
        (label: 'RR', weight: 0.2, orientedZ: 2.0),
        (label: 'temp', weight: 0.1, orientedZ: 2.0),
      ]);
      expect(agree.z, closeTo(-0.8, 1e-12));
      // Disagreeing: HRV -2, RHR +2 → old -0.2 (HRV wins by weight), now 0.
      final disagree = combineReadinessZ([
        (label: 'HRV', weight: 0.4, orientedZ: -2.0),
        (label: 'RHR', weight: 0.3, orientedZ: 2.0),
      ]);
      expect(disagree.z, closeTo(0.0, 1e-12));
    });
  });

  group('personal spread calibration', () {
    test('< 14 prior nights: uncalibrated logistic, marked calibrating', () {
      final r = calibratedReadinessScore(-1.0, List.filled(13, 0.5));
      expect(r.sigma, isNull);
      expect(r.score, closeTo(100 / (1 + math.exp(1.0)), 1e-9));
      final m = readinessComposite([
        hrvInput(4.5, around(4.5, 0.1)),
        rhrInput(52.0, around(52.0, 2.0)),
      ], compositeZHistory: List.filled(5, 0.0));
      expect(m.value!.toJson()['calibration'],
          {'status': 'calibrating', 'nights': 5});
      expect(m.note, contains('calibrating:have=5,need=14'));
    });

    test('≥ 14 nights: z rescaled by 0.65/σ̂, σ̂ and n disclosed', () {
      final hist = [for (var i = 0; i < 20; i++) (i.isEven ? 1.0 : -1.0)];
      final r = calibratedReadinessScore(-1.0, hist);
      final sigma = 1.0 * 1.4826; // MAD 1 × 1.4826
      expect(r.sigma, closeTo(sigma, 1e-9));
      expect(r.nights, 20);
      expect(r.score, closeTo(100 / (1 + math.exp(0.65 / sigma)), 1e-9));
    });

    test('σ̂ is floored so a flat history cannot blow a small z up', () {
      final r = calibratedReadinessScore(-0.3, List.filled(20, 0.0));
      expect(r.sigma, readinessCalibrationSigmaFloor);
      expect(r.score, closeTo(100 / (1 + math.exp(0.65)), 1e-9));
    });

    test('high-variance user: "Rest today" share falls to ~the designed 5%',
        () {
      // Composite z ~ N(0, 1.26) — the spread measured on a real 52-night
      // history (the cut-offs assume 0.65). Deterministic seed.
      final rnd = math.Random(7);
      double gauss() =>
          math.sqrt(-2 * math.log(1 - rnd.nextDouble())) *
          math.cos(2 * math.pi * rnd.nextDouble());
      final zs = [for (var i = 0; i < 600; i++) 1.26 * gauss()];
      var restOld = 0, restNew = 0, scored = 0;
      for (var i = 28; i < zs.length; i++) {
        final hist = zs.sublist(i - 28, i);
        scored++;
        if (100 / (1 + math.exp(-zs[i])) < 26) restOld++;
        if (calibratedReadinessScore(zs[i], hist).score < 26) restNew++;
      }
      expect(restOld / scored, greaterThan(0.12)); // the bug: ~15-20%
      expect(restNew / scored, inInclusiveRange(0.02, 0.09));
    });
  });

  group('capped re-centring', () {
    final rnd = math.Random(11);
    double gauss() =>
        math.sqrt(-2 * math.log(1 - rnd.nextDouble())) *
        math.cos(2 * math.pi * rnd.nextDouble());

    test('a history centred at -0.35 scores a median of ~50', () {
      final zs = [for (var i = 0; i < 400; i++) -0.35 + 0.9 * gauss()];
      final scores = [
        for (var i = 28; i < zs.length; i++)
          calibratedReadinessScore(zs[i], zs.sublist(i - 28, i)).score
      ]..sort();
      expect(scores[scores.length ~/ 2], closeTo(50, 4));
    });

    test('a sustained -1.0 step-down reads low at first, converges slowly', () {
      // 28 nights around 0, then every night 1.0 lower.
      final zs = [
        for (var i = 0; i < 28; i++) 0.6 * math.sin(i * 2.4), // spread, median ~0
        for (var i = 0; i < 40; i++) -1.0 + 0.6 * math.sin((i + 28) * 2.4),
      ];
      final s = [
        for (var i = 28; i < zs.length; i++)
          calibratedReadinessScore(zs[i], zs.sublist(i - 28, i))
      ];
      double meanScore(Iterable<({double score, double? sigma, int nights,
              double? centreRaw, double? centre})> xs) =>
          xs.map((r) => r.score).reduce((a, b) => a + b) / xs.length;
      // First week: the centre has barely moved, so the step shows in full —
      // below the "Take it easy" cut-off (37) on average.
      final first = meanScore(s.take(7));
      expect(first, lessThan(37));
      // Converges slowly: the last week reads higher, but the cap keeps the
      // half of the step past -0.5 from ever being re-centred away.
      final last = meanScore(s.skip(s.length - 7));
      expect(last, greaterThan(first));
      expect(last, lessThan(50));
      expect(s.last.centreRaw!, lessThan(-0.5));
      expect(s.last.centre, -readinessCentreCap);
    });

    test('cap boundary: centre is the median inside ±0.5, clamped outside', () {
      final at = calibratedReadinessScore(0, List.filled(20, 0.5));
      expect(at.centreRaw, 0.5);
      expect(at.centre, 0.5);
      final past = calibratedReadinessScore(0, List.filled(20, -0.8));
      expect(past.centreRaw, -0.8);
      expect(past.centre, -0.5);
      // Flat history → σ̂ floor 0.3: (0 − (−0.5)) · 0.65 / 0.3.
      expect(past.score, closeTo(100 / (1 + math.exp(-0.65 * 0.5 / 0.3)), 1e-9));
      final m = readinessComposite([
        hrvInput(4.5, around(4.5, 0.1)),
        rhrInput(52.0, around(52.0, 2.0)),
      ], compositeZHistory: List.filled(20, -0.8));
      final cal = m.value!.toJson()['calibration'] as Map;
      expect(cal['centre_raw'], -0.8);
      expect(cal['centre'], -0.5);
      expect(m.note, contains('centre=-0.5,centre_raw=-0.8'));
    });
  });

  group('readinessLnRmssd robust centre', () {
    test('one illness night cannot make a low night "normal"', () {
      // The real window: six nights 4.40–4.79 plus one 35.5 ms (3.568) night,
      // then an 88 ms (4.478) night.
      final hist = [4.56, 3.568, 4.623, 4.397, 4.662, 4.794, 4.653, 4.478];
      final m = readinessLnRmssd(hist);
      expect(m.value!.rolling7Mean, closeTo(4.4653, 1e-3));
      expect(m.value!.rolling7Median, closeTo(4.623, 1e-9));
      expect(m.value!.band, 'suppressed'); // mean/SD said 'normal'
      expect(m.value!.z!, lessThan(-1));
    });
  });
}
