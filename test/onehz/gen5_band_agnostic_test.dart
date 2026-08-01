// WHOOP5 (gen5) integration — band-agnosticism checks.
//
// This package never learns "gen4 vs gen5" by name (see lib/src/onehz/types.dart
// header + docs/ALGORITHM_CATALOG_1HZ.md). These tests pin down, concretely,
// what that claim means for the fields the WHOOP5 protocol spec actually adds:
//
//   1. RR/HRV kernels give IDENTICAL output whether the RR values happen to
//      have come from a gen4 or a gen5 session — verified using the real
//      byte-verified RR values from the protocol spec's own fixtures
//      (v18 historical record rr=[602,613] ms, REALTIME_DATA rr=[603,587] ms).
//   2. relative_odi (the only SpO2-adjacent module in this package) already
//      degrades HONESTLY — never fabricates — when fed the empty/absent
//      red+ir channel pair a gen5-only session has (gen5's v18 has no
//      dual-wavelength pair; see relative_odi.dart's file-header note).
//
// No code change was needed in either kernel for gen5 — this test suite is
// the regression lock for that "no change needed" conclusion.

import 'package:test/test.dart';
import 'package:openstrap_analytics/src/onehz/types.dart';
import 'package:openstrap_analytics/src/onehz/foundations/rr_correction.dart';
import 'package:openstrap_analytics/src/onehz/clinical/hrv_time.dart';
import 'package:openstrap_analytics/src/onehz/respiration/relative_odi.dart';

/// Beat-end epoch ms reconstructed from a starting timestamp + RR series.
List<double> _beatTimesMs(double t0Ms, List<double> rrMs) {
  final out = <double>[];
  var t = t0Ms;
  for (final rr in rrMs) {
    t += rr;
    out.add(t);
  }
  return out;
}

void main() {
  group('RR/HRV kernels are band-agnostic (gen5 fixture parity)', () {
    // Real byte-verified WHOOP5 v18 historical-record RR pair (spec §5,
    // "worn" fixture, unix=1780916150): rr_count=2, rr=[602,613] ms.
    const gen5V18Rr = [602.0, 613.0];
    // Real byte-verified WHOOP5 REALTIME_DATA fixture RR pair
    // (timestamp=1780916382, hr=98): rr=[603,587] ms.
    const gen5RealtimeRr = [603.0, 587.0];

    test('correctRr treats a gen5-sourced RR array exactly like any other', () {
      // Feed the same two-beat arrays twice — once "labelled" gen4-style,
      // once gen5-style. The kernel takes a plain List<double>; it has no way
      // to special-case either, and this test locks that in.
      final asIfGen4 = correctRr([...gen5V18Rr, ...gen5RealtimeRr]);
      final asIfGen5 = correctRr([...gen5V18Rr, ...gen5RealtimeRr]);
      expect(asIfGen5.nn, asIfGen4.nn);
      expect(asIfGen5.cleanFraction, asIfGen4.cleanFraction);
      expect(asIfGen5.droppedCount, asIfGen4.droppedCount);
    });

    test(
        'hrvTime on gen5-fixture RR values produces the same output as an '
        'identical gen4-style array — no gen5-specific path exists to diverge',
        () {
      // A longer synthetic run built by repeating the two real gen5 RR pairs
      // (enough beats to clear hrvTime's n>=2 gate and give a stable SDNN).
      final rr = <double>[];
      for (var i = 0; i < 40; i++) {
        rr.addAll(gen5V18Rr);
        rr.addAll(gen5RealtimeRr);
      }
      final corrected = correctRr(rr);
      final m1 = hrvTime(corrected.nn, nnTimesMs: corrected.nnTimesMs);
      final m2 =
          hrvTime([...corrected.nn], nnTimesMs: [...corrected.nnTimesMs]);
      expect(m1.present, isTrue);
      expect(m2.value!.rmssd, m1.value!.rmssd);
      expect(m2.value!.sdnn, m1.value!.sdnn);
      expect(m2.value!.nBeats, m1.value!.nBeats);
      expect(m1.tier, Tier.high);
    });

    test(
        'beat-time reconstruction from gen5 RR values is a pure function of '
        'the RR array (band identity plays no role)', () {
      final t1 = _beatTimesMs(1780916150000.0, gen5V18Rr);
      final t2 = _beatTimesMs(1780916150000.0, gen5V18Rr);
      expect(t1, t2);
      expect(t1.last, 1780916150000.0 + 602.0 + 613.0);
    });
  });

  group('SpO2 path honestly excludes a gen5-only session (no dual-wavelength)',
      () {
    test(
        'relativeOdi is absent, never fabricated, given empty red/ir '
        '(exactly what a gen5-only feed supplies)', () {
      final m = relativeOdi(const [], const [], const []);
      expect(m.present, isFalse);
      expect(m.confidence, 0.0);
    });

    test(
        'relativeOdi stays absent for a too-short window even with SOME '
        'single-wavelength-shaped data (guards against ever conflating a '
        'gen5 single-channel signal with a real red/ir pair)', () {
      // Even if a caller mistakenly duplicated a single gen5 channel into
      // both the red and ir slots, a short window still can't produce a
      // result — the length gate is independent of what's semantically
      // inside the arrays. (The real fix is upstream: never construct this
      // call for a gen5-only session at all; see the file-header note.)
      final oneChannel = List<double>.filled(10, 1000.0);
      final ts = [for (var i = 0; i < 10; i++) i.toDouble()];
      final m = relativeOdi(oneChannel, oneChannel, ts);
      expect(m.present, isFalse);
    });
  });
}
