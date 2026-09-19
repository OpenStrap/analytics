// Regression for the whole-bpm RHR quantization false positive: a baseline
// alternating between two adjacent integers carries a small nonzero MAD that
// is unresolvable rounding noise, not real dispersion. Without
// dispersionBelowQuantum this let a 1 bpm rise clear the gate.

import 'package:test/test.dart';
import 'package:openstrap_analytics/onehz.dart';

void main() {
  group('overreachingConjunction RHR quantum guard', () {
    final load = Metric<LoadState>(
      value: const LoadState(40.0, 65.0, -25.0), // atl/ctl = 1.625 >= 1.5
      confidence: 0.8,
      tier: Tier.high,
      inputs_used: const ['daily_trimp'],
    );

    test('alternating whole-bpm baseline abstains instead of firing', () {
      final baseline = <double>[
        58, 59, 58, 59, 58, 59, 58, 59, 58, 59, 58, 59, 58, 59,
      ];
      // 1 bpm above the median baseline on every recent night — exactly the
      // rounding-noise case the guard exists to catch.
      final recent = <double?>[60.0, 60.0, 60.0, 60.0, 60.0];

      final m = overreachingConjunction(
        load: load,
        rhrRecent: recent,
        rhrBaselineWindow: baseline,
      );

      expect(m.present, isFalse);
    });

    test('real dispersion in the baseline still lets it fire', () {
      final baseline = <double>[
        54, 56, 58, 60, 55, 57, 59, 61, 54, 58, 60, 56, 59, 55,
      ];
      final recent = <double?>[65.0, 65.0, 65.0, 65.0, 65.0];

      final m = overreachingConjunction(
        load: load,
        rhrRecent: recent,
        rhrBaselineWindow: baseline,
      );

      expect(m.present, isTrue);
      expect(m.value!.bothPointSameWay, isTrue);
    });
  });
}
