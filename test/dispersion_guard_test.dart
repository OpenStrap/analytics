// M0 §0.1: dispersionBelowQuantum, extracted verbatim from
// readiness_composite.dart's inline refusal so the same guard can be reused
// by illness_cusum.dart / anomaly.dart in a LATER milestone (M5 — extending
// it now would change a shipped number for quantized-SD-between-0-and-1
// users on a milestone whose gate forbids any kAlgoVersion bump).

import 'package:test/test.dart';
import 'package:openstrap_analytics/onehz.dart';

void main() {
  group('dispersionBelowQuantum', () {
    test('a 3-value baseline with SD 0.577 (quantum 1) refuses', () {
      expect(dispersionBelowQuantum([58, 58, 59], 1), isTrue);
    });

    test('a 5-value baseline with SD >= 1 does not refuse', () {
      expect(dispersionBelowQuantum([58, 59, 58, 60, 57], 1), isFalse);
    });

    test('quantum 0 (an unquantized input) never refuses', () {
      expect(dispersionBelowQuantum([58, 58, 59], 0), isFalse);
      expect(dispersionBelowQuantum([], 0), isFalse);
    });

    test('an empty baseline (SD null) with a real quantum refuses', () {
      expect(dispersionBelowQuantum([], 1), isTrue);
    });
  });

  group('readinessComposite still emits the byte-identical refusal string',
      () {
    test('a 14-night sub-bpm baseline refuses by name via the extracted '
        'guard', () {
      // Same case as wellness_test.dart's "A4 — a 14-night baseline with
      // sub-bpm dispersion is REFUSED by name" — pinned here too because this
      // is the string the edge UI reads, and this file is what proves the
      // extraction changed nothing about it.
      final base = <double>[
        58, 58, 58, 58, 58, 58, 58, 58, 58, 58, 58, 58, 58, 59
      ];
      final m = readinessComposite([rhrInput(52.0, base)],
          minInputs: 1, minWeightSum: 0.0);
      expect(m.present, isFalse);
      expect(m.note, contains('RHR: baseline_dispersion_below_quantum:'));
      expect(m.note, contains('quantum=1'));
    });
  });
}
