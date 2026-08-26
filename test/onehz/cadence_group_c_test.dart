// GROUP C — cadence-awareness of the metrics that carry a WALL-CLOCK window
// inside them: `nocturnalRhr` (C1) and `riivRespRate` (C6).
//
// Own file so it cannot collide with the concurrent group-C work. The gate that
// matters in both directions: WHOOP behaviour (1 Hz, no timestamps) must be
// bit-identical, and a slower stream must produce the SAME answer or NO answer
// — never a plausible wrong one.

import 'dart:math' as math;

import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

/// A night: [hours] of HR at [baseline], with a [troughMin]-minute block of
/// [trough] starting at [troughAtMin]. One sample per second.
List<double> _night({
  int hours = 8,
  double baseline = 70,
  double trough = 50,
  int troughAtMin = 300,
  int troughMin = 30,
}) =>
    [
      for (var s = 0; s < hours * 3600; s++)
        (s >= troughAtMin * 60 && s < (troughAtMin + troughMin) * 60)
            ? trough
            : baseline
    ];

/// Keep every Nth sample, and hand back the times it kept.
(List<double>, List<double>) _decimate(List<double> hr, int everyN) => (
      [for (var i = 0; i < hr.length; i += everyN) hr[i]],
      [for (var i = 0; i < hr.length; i += everyN) i.toDouble()],
    );

void main() {
  group('C1 nocturnalRhr — the 30-minute window is 30 MINUTES', () {
    test('no timestamps: 1 Hz behaviour is unchanged', () {
      final hr = _night();
      final m = nocturnalRhr(hr);
      expect(m.value!.low30Mean, closeTo(50, 1e-9));
      // The 1 Hz contract also holds when the clock is supplied explicitly.
      final withTs = nocturnalRhr(hr,
          tsSec: [for (var i = 0; i < hr.length; i++) i.toDouble()]);
      expect(withTs.value!.low30Mean, m.value!.low30Mean);
      expect(withTs.confidence, m.confidence);
      expect(withTs.note, m.note);
    });

    test('REGRESSION: 1800 POSITIONS is 7.5 h at 15 s — the wrong-number band',
        () {
      final (hr, ts) = _decimate(_night(), 15);
      expect(hr.length, greaterThan(1800)); // the old path does produce a number
      // Old behaviour, reachable by simply not passing the clock: 1800
      // positions span 7.5 h, so the "lowest 30-min mean" is the night's mean.
      expect(nocturnalRhr(hr).value!.low30Mean, greaterThan(60));
      // With the clock it is the trough, to the same value 1 Hz reports.
      expect(nocturnalRhr(hr, tsSec: ts).value!.low30Mean, closeTo(50, 1e-9));
    });

    test('the whole 2–16 s band converges on the 1 Hz answer', () {
      final truth = nocturnalRhr(_night()).value!.low30Mean;
      for (final n in [2, 5, 10, 15, 60]) {
        final (hr, ts) = _decimate(_night(), n);
        final m = nocturnalRhr(hr, tsSec: ts);
        expect(m.present, isTrue, reason: '${n}s: ${m.note}');
        expect(m.value!.low30Mean, closeTo(truth, 1e-9), reason: '${n}s');
      }
    });

    test('a cadence nothing can vouch for is ABSENT, not a guess', () {
      final (hr, _) = _decimate(_night(), 301);
      final ts = [for (var i = 0; i < hr.length; i++) i * 301.0];
      // 301 s is past what `sampleCadenceSeconds` will vouch for.
      expect(nocturnalRhr(hr, tsSec: ts).present, isFalse);
      // Mismatched lengths are refused rather than zipped short.
      expect(nocturnalRhr(hr, tsSec: const [0, 1, 2]).present, isFalse);
    });

    test('minCoverage still bites at a slow cadence', () {
      // 15 s stream, but only one sample in eight is on-skin: no window holds
      // 90% of the 120 samples 30 min should contain.
      final (hr, ts) = _decimate(_night(), 15);
      final holed = [
        for (var i = 0; i < hr.length; i++) (i % 8 == 0) ? hr[i] : 0.0
      ];
      expect(nocturnalRhr(holed, tsSec: ts).present, isFalse);
    });

    test('window is honoured as a duration at any cadence', () {
      // A 10-min trough is invisible to a 30-min window and found by a 10-min
      // one — at 15 s just as at 1 Hz.
      final hr = _night(troughMin: 10);
      final (d, ts) = _decimate(hr, 15);
      expect(nocturnalRhr(d, tsSec: ts).value!.low30Mean, greaterThan(60));
      expect(
        nocturnalRhr(d, tsSec: ts, window: const Duration(minutes: 10))
            .value!
            .low30Mean,
        closeTo(50, 1e-9),
      );
    });
  });

  group('C6 riivRespRate — Nyquist', () {
    // 0.2 Hz (12 br/min) intensity variation on a DC pedestal.
    (List<double>, List<double>) adcAt(int everyN, {int seconds = 600}) => (
          [
            for (var s = 0; s < seconds; s += everyN)
              10000 + 200 * math.sin(2 * math.pi * 0.2 * s)
          ],
          [for (var s = 0; s < seconds; s += everyN) s.toDouble()],
        );

    test('1 Hz resolves the band it claims to', () {
      final (adc, ts) = adcAt(1);
      final m = riivRespRate(adc, ts);
      expect(m.present, isTrue, reason: m.note);
      expect(m.value!.brpm!, closeTo(12, 1.0));
    });

    test('REGRESSION: 5 s cannot represent 0.1–0.5 Hz, so it ABSTAINS', () {
      // Before: the same night published 10.8 br/min for a true 21.2 — an
      // alias of a rate the stream cannot see, at full RELATIVE confidence.
      for (final n in [2, 5, 15, 60]) {
        final (adc, ts) = adcAt(n, seconds: 3600);
        final m = riivRespRate(adc, ts);
        expect(m.present, isFalse, reason: '${n}s published ${m.value?.brpm}');
        expect(m.confidence, 0);
        expect(m.note, contains('alias'));
      }
    });
  });
}
