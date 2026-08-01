// MOTION — foreground 100 Hz-class IMU gait-band cadence + motion energy.
//
// LAYER 2 (docs/ALGORITHM_CATALOG_1HZ.md §"Foreground-only"): "Autocorrelation
// cadence + step/stride regularity" and "frequency-domain activity typing"
// are both catalogued there as planned foreground-tier work. This is that
// work's spectral half, newly buildable because a gen5 (WHOOP5) R22 opt-in
// raw buffer is the first band-native source OpenStrap has ever seen that
// carries a GYROSCOPE at all (protocol spec v21: 100 Hz-class, 6-axis,
// accel+gyro). Gen4 has no gyroscope and no >1 Hz raw path whatsoever, so
// there is no lower-rate or gen4-native equivalent to fold this into — this
// module is purely ADDITIVE (nothing in the existing pipeline calls it) and
// this package never needs to know "gen4 vs gen5" by name: it just consumes
// [ImuSample]s if and when a caller has any to give it, and degrades to an
// honest absent Metric otherwise, like every other metric in this family.
//
// HONESTY / provenance, carried over from the wire-level spec:
//   * The underlying buffer's claimed ~100 Hz rate is, per both independent
//     reference protocol implementations, inferred from sample COUNT alone —
//     neither has ever independently measured it against a clock. This
//     module therefore never assumes a fixed rate: cadence comes out of a
//     Lomb-Scargle periodogram over the buffer's OWN timestamps, which is
//     exact for unevenly-sampled data and degrades gracefully if the true
//     rate isn't 100 Hz.
//   * Gravity is removed the SAME way enmo.dart's `dynAmp` does it — a
//     per-axis rolling-mean high-pass, never a scalar ‖a‖−gRef subtraction —
//     for the identical calibration-invariance reason documented there (a
//     scalar gravity reference estimated from one posture and subtracted
//     from another is exactly the bug a previous audit found in the 1 Hz
//     step pipeline; see steps.dart's file header for the full story).
//   * This is a cadence/energy ESTIMATE, never a step count. Tier is always
//     ESTIMATE. It does not replace or feed [steps.dart]'s Tier A (real,
//     ground-truth-calibrated 100 Hz step counter) or Tier B (1 Hz active-
//     minutes) — a future integration decision, not made here, since this
//     buffer is R22 opt-in and edge does not yet send the enable sequence to
//     receive it at all (nothing to integrate against yet).
//
// Pure: dart:math only. No I/O, no clock, no randomness.

import 'dart:math' as math;
import '../types.dart';
import '../util.dart';

/// One 100 Hz-class 6-axis IMU sample: tri-axial accel (g) + tri-axial gyro
/// (deg/s). Deliberately NOT added to types.dart's 1 Hz-native adapter family
/// (HrSample/AccelSample/AdcSample) — this is a foreground, not an always-on
/// 1 Hz, substrate, exactly like steps.dart's own locally-scoped
/// [PedometerResult] input convention for its 100 Hz tier.
class ImuSample {
  final double tsMs;
  final double ax, ay, az; // g
  final double gx, gy, gz; // deg/s
  const ImuSample(
      this.tsMs, this.ax, this.ay, this.az, this.gx, this.gy, this.gz);
}

/// Gait-band frequency range (Hz), i.e. 72–210 steps/min. Matches noop's own
/// validated constants for this exact buffer family.
const double imuGaitBandLowHz = 1.2;
const double imuGaitBandHighHz = 3.5;

/// Minimum fraction of total accel spectral power that must sit inside the
/// gait band before a cadence is reported (noop's own validated gate).
const double imuGaitMinBandStrength = 0.20;

/// Minimum samples in a buffer before an estimate is attempted at all.
const int imuActivityMinSamples = 150;

/// Minimum buffer TIME SPAN (s) — several gait cycles even at the slow edge
/// of the band (1.2 Hz → 0.83 s/cycle), so the spectral peak is real.
const double imuActivityMinDurationS = 2.5;

/// Per-axis high-pass corner (s) for gravity removal on the ACCEL energy
/// feature only (the cadence estimate itself needs no separate high-pass —
/// see below). Short relative to a gait cycle so it isolates the dynamic
/// component without attenuating the gait signal itself.
const double imuGravityWindowS = 1.0;

/// One buffer's gait-band cadence + motion-energy features.
class ImuActivityFeatures {
  /// Dominant frequency (Hz) inside the gait band — an ESTIMATE of stepping
  /// rate, not a measured cadence (contrast [steps.dart]'s live pedometer,
  /// which counts real steps).
  final double cadenceHz;
  final double cadenceSpm; // cadenceHz * 60, for display convenience
  final double bandStrength; // 0..1: fraction of accel spectral power in-band
  final double accelDynAmpG; // RMS gravity-removed (vector high-pass) accel
  final double gyroRmsDps; // RMS bias-removed gyro magnitude
  final double jerkGPerS; // RMS d(|accel|)/dt
  final int nSamples;
  final double durationS;

  const ImuActivityFeatures({
    required this.cadenceHz,
    required this.cadenceSpm,
    required this.bandStrength,
    required this.accelDynAmpG,
    required this.gyroRmsDps,
    required this.jerkGPerS,
    required this.nSamples,
    required this.durationS,
  });

  Map<String, dynamic> toJson() => {
        'cadence_hz': round6(cadenceHz),
        'cadence_spm': round6(cadenceSpm),
        'band_strength': round6(bandStrength),
        'accel_dyn_amp_g': round6(accelDynAmpG),
        'gyro_rms_dps': round6(gyroRmsDps),
        'jerk_g_per_s': round6(jerkGPerS),
        'n': nSamples,
        'duration_s': round6(durationS),
      };
}

/// Gait-band spectral cadence + accel/gyro motion energy over ONE contiguous
/// foreground IMU buffer.
///
/// Absent (never fabricated) when: the buffer is too thin/short to trust a
/// spectrum ([imuActivityMinSamples]/[imuActivityMinDurationS]); any sample
/// carries a non-finite field; the accel signal has zero variance (perfectly
/// still — nothing to estimate); or no frequency in
/// [bandLowHz]-[bandHighHz] clears [minBandStrength] — this last case is an
/// honest "no gait-like motion detected right now", not an error.
Metric<ImuActivityFeatures> imuActivityFeatures(
  List<ImuSample> buf, {
  double bandLowHz = imuGaitBandLowHz,
  double bandHighHz = imuGaitBandHighHz,
  double minBandStrength = imuGaitMinBandStrength,
  int minSamples = imuActivityMinSamples,
  double minDurationS = imuActivityMinDurationS,
  double gravityWindowS = imuGravityWindowS,
}) {
  const inputs = ['imu_accel', 'imu_gyro', 'imu_ts'];

  final valid = [
    for (final s in buf)
      if (s.tsMs.isFinite &&
          s.ax.isFinite &&
          s.ay.isFinite &&
          s.az.isFinite &&
          s.gx.isFinite &&
          s.gy.isFinite &&
          s.gz.isFinite)
        s
  ]..sort((a, b) => a.tsMs.compareTo(b.tsMs));

  if (valid.length < minSamples) {
    return Metric<ImuActivityFeatures>.absent(
      tier: Tier.estimate,
      inputs_used: inputs,
      note: needBaselineNote(have: valid.length, need: minSamples),
    );
  }

  final n = valid.length;
  final durationS = (valid.last.tsMs - valid.first.tsMs) / 1000.0;
  if (durationS < minDurationS) {
    return Metric<ImuActivityFeatures>.absent(
      tier: Tier.estimate,
      inputs_used: inputs,
      note: 'buffer spans ${durationS.toStringAsFixed(2)}s, need '
          '>= ${minDurationS}s for a gait-band estimate',
    );
  }

  final t0 = valid.first.tsMs;
  final tSec = [for (final s in valid) (s.tsMs - t0) / 1000.0];
  final mags = [
    for (final s in valid) math.sqrt(s.ax * s.ax + s.ay * s.ay + s.az * s.az)
  ];

  // Gravity-removed accel energy: per-axis rolling-mean high-pass (same
  // technique as enmo.dart's dynAmp), NOT a scalar ‖a‖−gRef subtraction.
  final dyn = List<double>.filled(n, 0.0);
  final windowMs = gravityWindowS * 1000.0;
  var lo = 0;
  var sx = 0.0, sy = 0.0, sz = 0.0;
  for (var i = 0; i < n; i++) {
    final s = valid[i];
    sx += s.ax;
    sy += s.ay;
    sz += s.az;
    while (lo < i && (s.tsMs - valid[lo].tsMs) >= windowMs) {
      sx -= valid[lo].ax;
      sy -= valid[lo].ay;
      sz -= valid[lo].az;
      lo++;
    }
    final cnt = i - lo + 1;
    final dx = s.ax - sx / cnt, dy = s.ay - sy / cnt, dz = s.az - sz / cnt;
    dyn[i] = math.sqrt(dx * dx + dy * dy + dz * dz);
  }
  final accelDynAmpG = _rms(dyn);

  // Gyro: bias(mean)-removed RMS magnitude.
  final gMagRaw = [
    for (final s in valid) math.sqrt(s.gx * s.gx + s.gy * s.gy + s.gz * s.gz)
  ];
  final gMean = mean(gMagRaw) ?? 0.0;
  final gyroRmsDps = _rms([for (final v in gMagRaw) v - gMean]);

  // Jerk: RMS of d(|accel|)/dt on the buffer's ACTUAL (possibly irregular) dt
  // — never an assumed sample interval.
  final jerks = <double>[];
  for (var i = 1; i < n; i++) {
    final dt = tSec[i] - tSec[i - 1];
    if (dt > 0) jerks.add((mags[i] - mags[i - 1]) / dt);
  }
  final jerkGPerS = jerks.isEmpty ? 0.0 : _rms(jerks);

  // Cadence via Lomb-Scargle on raw accel magnitude — gravity is ~DC and is
  // mean-subtracted internally by lombScargle, so no separate high-pass is
  // needed for the spectral estimate itself. Native timestamps in, so this
  // is exact even if the buffer's rate is not truly a uniform 100 Hz.
  final freqs = <double>[];
  for (var f = 0.3; f <= 5.0; f += 0.02) {
    freqs.add(f);
  }
  final ls = lombScargle(tSec, mags, freqs);
  if (ls == null) {
    return Metric<ImuActivityFeatures>.absent(
      tier: Tier.estimate,
      inputs_used: inputs,
      note: 'degenerate accel signal (zero variance or too few points)',
    );
  }
  final totalPower = ls.bandPower(0.3, 5.0);
  final gaitBandPower = ls.bandPower(bandLowHz, bandHighHz);
  final peak = ls.peakFreq(bandLowHz, bandHighHz);
  final strength =
      totalPower > 0 ? clamp(gaitBandPower / totalPower, 0.0, 1.0) : 0.0;

  if (peak == null || strength < minBandStrength) {
    return Metric<ImuActivityFeatures>.absent(
      tier: Tier.estimate,
      inputs_used: inputs,
      note: 'no gait-band ($bandLowHz-$bandHighHz Hz) signal cleared the '
          '${(minBandStrength * 100).round()}% band-strength gate',
    );
  }

  final conf = clamp(strength, 0.2, 0.9);
  return Metric<ImuActivityFeatures>(
    value: ImuActivityFeatures(
      cadenceHz: peak,
      cadenceSpm: peak * 60.0,
      bandStrength: strength,
      accelDynAmpG: accelDynAmpG,
      gyroRmsDps: gyroRmsDps,
      jerkGPerS: jerkGPerS,
      nSamples: n,
      durationS: durationS,
    ),
    confidence: conf,
    tier: Tier.estimate,
    inputs_used: inputs,
    note: 'ESTIMATE: gait-band spectral cadence + accel/gyro motion energy '
        'from a foreground 100 Hz-class IMU buffer (WHOOP5 R22 opt-in only '
        "today). NOT a step count — see steps.dart's Tier A/B split for the "
        "honest step estimate. The buffer's claimed sample rate is itself "
        'hardware-unconfirmed; cadence is derived from its own timestamps, '
        'never an assumed 100 Hz.',
  );
}

double _rms(List<double> xs) {
  if (xs.isEmpty) return 0.0;
  var s = 0.0;
  for (final v in xs) {
    s += v * v;
  }
  return math.sqrt(s / xs.length);
}
