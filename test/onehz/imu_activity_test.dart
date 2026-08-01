// IMU gait-band cadence + motion energy (imu_activity.dart) — tests.
//
// Synthetic KNOWN-ANSWER: a gravity vector plus a clean sinusoidal
// oscillation at a known frequency inside the gait band should recover that
// frequency as the reported cadence. No real WHOOP5 R22 hex fixture is cited
// in the protocol spec for this record family (only a magnitude/gravity-shell
// summary), so real-data plausibility isn't available yet — synthetic
// known-answer + honest-degrade coverage is the right bar here.

import 'dart:math' as math;
import 'package:test/test.dart';
import 'package:openstrap_analytics/src/onehz/types.dart';
import 'package:openstrap_analytics/src/onehz/motion/imu_activity.dart';

List<ImuSample> _walkLike({
  required int n,
  required double hz,
  double fs = 100.0,
  double accelAmpG = 0.35,
  double gyroAmpDps = 40.0,
}) {
  final out = <ImuSample>[];
  for (var i = 0; i < n; i++) {
    final t = i / fs;
    final osc = math.sin(2 * math.pi * hz * t);
    out.add(ImuSample(
      t * 1000.0,
      0.0,
      0.0,
      1.0 + accelAmpG * osc, // gravity (z) + gait oscillation
      gyroAmpDps * osc,
      0.0,
      0.0,
    ));
  }
  return out;
}

void main() {
  group('imuActivityFeatures — known-answer cadence', () {
    test('2.0 Hz gait-band oscillation recovers cadence in-band', () {
      final buf = _walkLike(n: 500, hz: 2.0); // 5 s @ 100 Hz
      final m = imuActivityFeatures(buf);
      expect(m.present, isTrue, reason: m.note);
      expect(m.value!.cadenceHz, closeTo(2.0, 0.1));
      expect(m.value!.cadenceSpm, closeTo(120.0, 6.0));
      expect(
          m.value!.bandStrength, greaterThanOrEqualTo(imuGaitMinBandStrength));
      expect(m.value!.nSamples, 500);
      expect(m.tier, Tier.estimate);
      expect(m.confidence, greaterThan(0));
    });

    test('1.5 Hz (slow walk, still in-band) also recovers', () {
      final buf = _walkLike(n: 600, hz: 1.5); // 6 s
      final m = imuActivityFeatures(buf);
      expect(m.present, isTrue, reason: m.note);
      expect(m.value!.cadenceHz, closeTo(1.5, 0.1));
    });

    test('gyro energy and jerk are nonzero for real oscillation', () {
      final buf = _walkLike(n: 500, hz: 2.0);
      final m = imuActivityFeatures(buf);
      expect(m.present, isTrue);
      expect(m.value!.gyroRmsDps, greaterThan(0));
      expect(m.value!.accelDynAmpG, greaterThan(0));
      expect(m.value!.jerkGPerS, greaterThan(0));
    });
  });

  group('imuActivityFeatures — honest degrade', () {
    test('too few samples -> absent with need_baseline note', () {
      final buf = _walkLike(n: 50, hz: 2.0);
      final m = imuActivityFeatures(buf);
      expect(m.present, isFalse);
      expect(m.confidence, 0.0);
      expect(m.note, contains('need_baseline'));
    });

    test('enough samples but too short a time span -> absent', () {
      // 300 samples at 200 Hz spans only 1.5 s (< imuActivityMinDurationS).
      final buf = _walkLike(n: 300, hz: 2.0, fs: 200.0);
      final m = imuActivityFeatures(buf);
      expect(m.present, isFalse);
      expect(m.note, contains('need >='));
    });

    test('perfectly still buffer (zero variance) -> absent, not fabricated',
        () {
      final buf = [
        for (var i = 0; i < 500; i++)
          ImuSample(i * 10.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0)
      ];
      final m = imuActivityFeatures(buf);
      expect(m.present, isFalse);
      expect(m.confidence, 0.0);
    });

    test('below-band oscillation (0.5 Hz) fails the band-strength gate', () {
      final buf = _walkLike(n: 1000, hz: 0.5); // 10 s, well below 1.2 Hz
      final m = imuActivityFeatures(buf);
      expect(m.present, isFalse);
      expect(m.note, contains('band-strength gate'));
    });

    test('non-finite sample is dropped, not propagated as NaN', () {
      final good = _walkLike(n: 500, hz: 2.0);
      final buf = [
        ...good,
        const ImuSample(double.nan, 0, 0, 1, 0, 0, 0),
      ];
      final m = imuActivityFeatures(buf);
      // Still resolves on the 500 good samples; never NaN cadence.
      expect(m.present, isTrue);
      expect(m.value!.cadenceHz.isFinite, isTrue);
      expect(m.value!.nSamples, 500);
    });
  });
}
