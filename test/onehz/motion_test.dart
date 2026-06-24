// MOTION / ACTIVITY / ENERGY family — tests.
//
// (1) Synthetic KNOWN-ANSWER: still 1 g → ENMO≈0; known oscillation → known
//     ENMO/MAD; axis-aligned gravity → expected posture; Brage branch logic
//     weights accel when both low and HR when sitting-but-loaded.
// (2) PLAUSIBILITY on ../whoop_hist.jsonl (1 Hz accel + HR via parseR24):
//     ENMO small at rest, posture stable, no crashes. No TS oracle exists for
//     this net-new family, so real data is a sanity gate, not a known answer.
//
// Imports the motion barrel by package path (lib/onehz.dart is frozen by the
// task and does not re-export this family).

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:test/test.dart';
import 'package:openstrap_analytics/src/onehz/types.dart';
import 'package:openstrap_analytics/src/onehz/motion/motion.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

List<AccelSample> _still(int n, double x, double y, double z) => [
      for (var i = 0; i < n; i++) AccelSample(i * 1000.0, x, y, z),
    ];

void main() {
  group('ENMO + MAD (van Hees / Vähä-Ypyä)', () {
    test('still 1 g vector → ENMO ≈ 0, MAD ≈ 0', () {
      final s = _still(120, 0, 0, 1.0); // 2 min, ‖a‖=1g, z-up
      final r = enmoSeries(s);
      expect(r.gRef, closeTo(1.0, 1e-9));
      expect(r.minutes.length, 2);
      for (final m in r.minutes) {
        expect(m.enmo, closeTo(0.0, 1e-9));
        expect(m.mad, closeTo(0.0, 1e-9));
        expect(m.meanMag, closeTo(1.0, 1e-9));
      }
      expect(r.coverage, 1.0);
    });

    test('known oscillating magnitude → known ENMO and MAD', () {
      // 60 samples in one minute, magnitude alternating 1.0 / 1.2 g (vary z so
      // ‖a‖ is exactly the target). gRef calibrates to 1.0 (the still floor).
      final s = <AccelSample>[];
      for (var i = 0; i < 60; i++) {
        final mag = i.isEven ? 1.0 : 1.2;
        s.add(AccelSample(i * 1000.0, 0, 0, mag));
      }
      final r = enmoSeries(s, gRef: 1.0);
      final m = r.minutes.single;
      // ENMO: half the samples contribute max(0,1.2-1.0)=0.2, half contribute 0
      //   → mean = 0.5 * 0.2 = 0.10
      expect(m.enmo, closeTo(0.10, 1e-9));
      // meanMag = (1.0+1.2)/2 = 1.1 ; MAD = mean(|mag-1.1|) = 0.1
      expect(m.meanMag, closeTo(1.1, 1e-9));
      expect(m.mad, closeTo(0.10, 1e-9));
    });

    test('auto-calibrated gRef recovers a non-1.0 still reference', () {
      // sensor reads gravity as 1.03 g while still, plus a brief jolt.
      final s = <AccelSample>[];
      for (var i = 0; i < 100; i++) {
        s.add(AccelSample(i * 1000.0, 0, 0, 1.03));
      }
      s[50] = AccelSample(50 * 1000.0, 0, 0, 1.8); // one jolt
      final r = enmoSeries(s);
      expect(r.gRef, closeTo(1.03, 1e-6));
    });

    test('relative intensity bands are within-user percentiles (not METs)', () {
      // ramp of ENMO values; expect monotone cut-points light<moderate<vigorous
      final enmo = [for (var i = 0; i < 100; i++) i * 0.01];
      final m = relativeIntensityBands(enmo);
      expect(m.present, isTrue);
      final b = m.value!;
      expect(b.lightCut, lessThan(b.moderateCut));
      expect(b.moderateCut, lessThan(b.vigorousCut));
      expect(m.tier, Tier.relative);
      // a zero-ENMO minute is sedentary; the largest is vigorous.
      expect(b.labels.first, 'sedentary');
      expect(b.labels.last, 'vigorous');
      expect(b.minutesInBand.values.reduce((a, c) => a + c), 100);
    });

    test('empty input → absent, confidence 0', () {
      final m = relativeIntensityBands(const []);
      expect(m.present, isFalse);
      expect(m.confidence, 0);
      expect(enmoSeries(const []).minutes, isEmpty);
    });
  });

  group('Static gravity-tilt → sleep position', () {
    test('z-up gravity (lying flat, watch face up) → supine', () {
      final m = staticTilt(_still(30, 0, 0, 1.0));
      expect(m.present, isTrue);
      expect(m.value!.position, 'supine');
      expect(m.value!.pitchDeg, closeTo(0, 1e-6));
      expect(m.value!.rollDeg, closeTo(0, 1e-6));
      expect(m.value!.stillness, closeTo(1.0, 1e-9));
    });

    test('gravity along +y (wrist rolled right ~90°) → lateral_right', () {
      final m = staticTilt(_still(30, 0, 1.0, 0.0));
      expect(m.present, isTrue);
      expect(m.value!.rollDeg, closeTo(90, 1e-6));
      expect(m.value!.position, 'lateral_right');
    });

    test('gravity along -y → lateral_left', () {
      final m = staticTilt(_still(30, 0, -1.0, 0.0));
      expect(m.value!.position, 'lateral_left');
    });

    test('gravity along -z (face down) → prone', () {
      final m = staticTilt(_still(30, 0, 0, -1.0));
      expect(m.value!.position, 'prone');
    });

    test('gravity along -x (arm vertical) → upright', () {
      final m = staticTilt(_still(30, -1.0, 0, 0));
      expect(m.value!.pitchDeg, closeTo(90, 1e-6));
      expect(m.value!.position, 'upright');
    });

    test('high-motion epoch → absent (no posture during motion)', () {
      final s = <AccelSample>[];
      for (var i = 0; i < 30; i++) {
        // wild swings → jitter ≫ maxJitterG
        s.add(AccelSample(i * 1000.0, 0, 0, i.isEven ? 0.2 : 2.0));
      }
      final m = staticTilt(s);
      expect(m.present, isFalse);
      expect(m.confidence, 0);
    });

    test('positionSeries segments and emits stable supine posture', () {
      final s = _still(120, 0, 0, 1.0);
      final series = positionSeries(s, epochSec: 30);
      expect(series.length, 4); // 120 s / 30 s
      expect(series.every((t) => t.position == 'supine'), isTrue);
    });
  });

  group('Branched HR-accel energy fusion (Brage 2004)', () {
    test('both LOW → branch=rest, accel-weighted, tiny load', () {
      final ts = [for (var i = 0; i < 60; i++) i * 1000.0];
      final enmo = List<double>.filled(60, 0.0); // still
      final hr = List<double>.filled(60, 55.0); // near resting
      final m = branchedEnergyFusion(ts, enmo, hr);
      expect(m.present, isTrue);
      final f = m.value!;
      expect(f.points.first.branch, 'rest');
      expect(f.points.first.accelWeight, greaterThan(0.5)); // accel-weighted
      // No motion + near-resting HR → tiny per-sample index (only the small
      // residual of the uncalibrated HR ramp leaks through the (1-wA) term).
      expect(f.points.first.index, lessThan(0.02));
      expect(f.relativeLoad, lessThan(1.0)); // ~0.35 over 60 s
      expect(m.tier, Tier.relative); // no calibration
    });

    test('LOW motion + HIGH HR → branch=nonlocomotor, HR-weighted', () {
      final ts = [for (var i = 0; i < 60; i++) i * 1000.0];
      final enmo = List<double>.filled(60, 0.0);
      final hr = List<double>.filled(60, 150.0); // elevated, sitting still
      final m = branchedEnergyFusion(ts, enmo, hr);
      final p = m.value!.points.first;
      expect(p.branch, 'nonlocomotor');
      expect(p.accelWeight, lessThan(0.5)); // HR carries it
      expect(p.index, greaterThan(0.4)); // load is HR-driven, not ~0
    });

    test('HIGH motion + HIGH HR → branch=locomotor, HR-led', () {
      final ts = [for (var i = 0; i < 60; i++) i * 1000.0];
      final enmo = List<double>.filled(60, 0.4); // vigorous wrist motion
      final hr = List<double>.filled(60, 160.0);
      final m = branchedEnergyFusion(ts, enmo, hr);
      final p = m.value!.points.first;
      expect(p.branch, 'locomotor');
      expect(p.accelWeight, lessThan(0.5)); // HR-led
      expect(p.index, greaterThan(0.5));
    });

    test('off-skin HR (0) → accel_only branch, full accel weight', () {
      final ts = [0.0, 1000.0];
      final m = branchedEnergyFusion(ts, [0.3, 0.3], [0.0, 0.0]);
      final p = m.value!.points.first;
      expect(p.branch, 'accel_only');
      expect(p.accelWeight, 1.0);
      expect(p.hrComponent, 0.0);
    });

    test('per-user calibration switches to ESTIMATE tier + %HR-reserve', () {
      final ts = [for (var i = 0; i < 10; i++) i * 1000.0];
      final m = branchedEnergyFusion(
        ts,
        List<double>.filled(10, 0.0),
        List<double>.filled(10, 120.0),
        restingHr: 50,
        maxHr: 190,
      );
      expect(m.value!.calibrated, isTrue);
      expect(m.tier, Tier.estimate);
    });

    test('mismatched lengths → absent', () {
      final m = branchedEnergyFusion([0.0, 1.0], [0.1], [60.0, 60.0]);
      expect(m.present, isFalse);
      expect(m.confidence, 0);
    });
  });

  group('PLAUSIBILITY on real whoop_hist.jsonl (no oracle)', () {
    test('decode real accel + HR; ENMO small at rest, posture stable, no crash',
        () {
      final f = File('../whoop_hist.jsonl');
      if (!f.existsSync()) {
        markTestSkipped('whoop_hist.jsonl not found beside the repo');
        return;
      }
      final lines =
          f.readAsLinesSync().where((l) => l.trim().isNotEmpty).toList();
      final accel = <AccelSample>[];
      final ts = <double>[];
      final hr = <double>[];
      for (final line in lines) {
        final obj = jsonDecode(line) as Map<String, dynamic>;
        if (obj['t'] != 24) continue;
        final r = parseR24(hexToBytes(obj['hex'] as String));
        if (r == null) continue;
        final a = r.accelG;
        if (a.length != 3) continue;
        final tMs = r.tsEpoch * 1000.0;
        accel.add(AccelSample(tMs, a[0], a[1], a[2]));
        ts.add(tMs);
        hr.add(r.hr.toDouble());
      }
      expect(accel.length, greaterThan(100), reason: 'expect ~550 records');

      // ENMO: this capture is a worn-at-rest snippet → ENMO should be small.
      final res = enmoSeries(accel);
      // ignore: avoid_print
      print('REAL motion: gRef=${res.gRef.toStringAsFixed(3)}g '
          'minutes=${res.minutes.length} coverage=${res.coverage.toStringAsFixed(2)}');
      expect(res.gRef, inInclusiveRange(0.5, 1.5),
          reason: 'auto-calibrated gravity reference near 1 g');
      for (final m in res.minutes) {
        expect(m.enmo, inInclusiveRange(0.0, 1.0), reason: 'ENMO bounded/sane');
        expect(m.enmo, lessThan(0.5), reason: 'rest snippet → small ENMO');
        expect(m.mad, inInclusiveRange(0.0, 1.0));
      }
      final medEnmo = res.minutes.isEmpty
          ? 0.0
          : (res.minutes.map((m) => m.enmo).toList()..sort())[
              res.minutes.length ~/ 2];
      // ignore: avoid_print
      print('REAL ENMO median/min = ${medEnmo.toStringAsFixed(4)} g');
      expect(medEnmo, lessThan(0.2), reason: 'median minute is restful');

      // Posture: low-motion epochs → stable, dominant posture, no crash.
      final postures = positionSeries(accel, epochSec: 30, maxJitterG: 0.1);
      // ignore: avoid_print
      print('REAL posture epochs=${postures.length} '
          'positions=${{for (final p in postures) p.position}}');
      expect(postures, isNotEmpty,
          reason: 'a worn-at-rest snippet should yield some static epochs');
      // dominant posture should cover the majority (stable, not flickering)
      final counts = <String, int>{};
      for (final p in postures) {
        counts[p.position] = (counts[p.position] ?? 0) + 1;
      }
      final dominant =
          counts.values.fold<int>(0, (a, c) => math.max(a, c));
      expect(dominant / postures.length, greaterThan(0.5),
          reason: 'one body position dominates a rest snippet');

      // Energy fusion runs end-to-end without crashing; load is finite & small.
      final fuse = branchedEnergyFusion(ts, [
        for (final a in accel)
          math.max(0.0, math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z) - res.gRef)
      ], hr);
      expect(fuse.present, isTrue);
      expect(fuse.value!.relativeLoad.isFinite, isTrue);
      // ignore: avoid_print
      print('REAL energy relativeLoad=${fuse.value!.relativeLoad.toStringAsFixed(2)} '
          'over ${fuse.value!.points.length} samples');
    });
  });
}
