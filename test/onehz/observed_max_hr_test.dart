// TS-03 — the observed HR ceiling and its two guards (hold + motion), and the
// TS-04 %HRR zones that anchor on it.

import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

/// n seconds of HR at [bpm] with the given accel deviation from 1 g, starting
/// at t0 ms. `dev` is applied on z so ‖a‖ = 1 + dev.
({List<HrSample> hr, List<AccelSample> accel}) _run(
  double t0,
  int seconds,
  double bpm,
  double dev,
) {
  final hr = <HrSample>[];
  final accel = <AccelSample>[];
  for (var i = 0; i < seconds; i++) {
    final t = t0 + i * 1000.0;
    hr.add(HrSample(t, bpm));
    accel.add(AccelSample(t, 0, 0, 1.0 + dev));
  }
  return (hr: hr, accel: accel);
}

void main() {
  group('sessionHrCeiling', () {
    test('a held, moving high HR sets the ceiling', () {
      final s = _run(0, 40, 180, 0.20);
      final m = sessionHrCeiling(s.hr, s.accel, deviceFamily: 'gen4');
      expect(m.present, isTrue);
      expect(m.value!.bpm, 180);
      expect(m.value!.heldSeconds, greaterThanOrEqualTo(15));
    });

    test('a one-sample spike cannot inflate the ceiling', () {
      final s = _run(0, 40, 150, 0.20);
      s.hr[20] = HrSample(s.hr[20].tsMs, 205); // PPG artifact
      final m = sessionHrCeiling(s.hr, s.accel, deviceFamily: 'gen4');
      expect(m.value!.bpm, 150, reason: '205 was never held for 15 s');
    });

    test('high HR while still is not a ceiling', () {
      // Same 180 bpm, but the wrist is not moving: stress, fever or artifact.
      final s = _run(0, 40, 180, 0.001);
      final m = sessionHrCeiling(s.hr, s.accel, deviceFamily: 'gen4');
      expect(m.present, isFalse);
      expect(m.note, contains('no_held_ceiling'));
    });

    test('the motion gate is per-family, not shared', () {
      // 0.06 g of wrist motion is inside gen4's own resting noise floor and
      // well outside gen5's. One shared gate would have to be wrong for one.
      final s = _run(0, 40, 175, 0.06);
      expect(sessionHrCeiling(s.hr, s.accel, deviceFamily: 'gen4').present,
          isFalse);
      expect(sessionHrCeiling(s.hr, s.accel, deviceFamily: 'gen5').present,
          isTrue);
    });

    test('unknown family refuses instead of borrowing gen4 numbers', () {
      final s = _run(0, 40, 180, 0.20);
      for (final id in [null, '', 'imported', 'gen6']) {
        final m = sessionHrCeiling(s.hr, s.accel, deviceFamily: id);
        expect(m.present, isFalse, reason: 'id=$id');
        expect(m.note, unknownFamilyNote(id));
      }
    });

    test('motion split across the ends of a long hold still counts', () {
      // Two 3 s bursts of arm swing bracketing a quiet middle. Neither burst
      // alone clears the gate once padded out to a 15 s window (0.076 avg),
      // but the full ~19 s span between them does (0.101 avg) — the minimal
      // 15 s window from any single start index can never see both bursts at
      // once, so a corroborated hold that's real gets missed unless a start
      // is allowed to keep extending past its first duration-qualifying
      // window when that window's motion doesn't (yet) pass the gate.
      const bpm = 180.0;
      final hr = <HrSample>[];
      final accel = <AccelSample>[];
      for (var i = 0; i < 21; i++) {
        final t = i * 1000.0;
        final dev = (i <= 2 || i >= 18) ? 0.4 : 0.001;
        hr.add(HrSample(t, bpm));
        accel.add(AccelSample(t, 0, 0, 1.0 + dev));
      }
      final m = sessionHrCeiling(hr, accel, deviceFamily: 'gen4');
      expect(m.present, isTrue);
      expect(m.value!.bpm, bpm);
    });

    test('a gap in the stream breaks the hold', () {
      final a = _run(0, 10, 180, 0.20);
      final b = _run(60000, 10, 180, 0.20); // 50 s later
      final m = sessionHrCeiling(
        [...a.hr, ...b.hr],
        [...a.accel, ...b.accel],
        deviceFamily: 'gen4',
      );
      expect(m.present, isFalse);
    });
  });

  group('reserveZones (TS-04)', () {
    final rhr28 = List<double>.filled(28, 50);

    test('anchors on the median of the history, not one night', () {
      final z =
          HeartRateZones.reserveZones(restingHrHistory: rhr28, maxHr: 190)!;
      expect(z.zones.first.lower, closeTo(50 + 0.50 * 140, 1e-9));
      expect(z.zones.last.upper, closeTo(190, 1e-9));
      expect(z.source, 'karvonen');
    });

    test('one bad night cannot move the boundaries much', () {
      final polluted = [...rhr28]..[0] = 78;
      final a =
          HeartRateZones.reserveZones(restingHrHistory: rhr28, maxHr: 190)!;
      final b =
          HeartRateZones.reserveZones(restingHrHistory: polluted, maxHr: 190)!;
      expect(b.zones.first.lower, closeTo(a.zones.first.lower, 1.0));
    });

    test('refuses on thin history and on an inverted reserve', () {
      expect(
          HeartRateZones.reserveZones(
              restingHrHistory: List<double>.filled(5, 50), maxHr: 190),
          isNull);
      expect(HeartRateZones.reserveZones(restingHrHistory: rhr28, maxHr: 45),
          isNull);
    });
  });
}
