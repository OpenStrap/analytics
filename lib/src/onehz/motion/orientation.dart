// MOTION / ORIENTATION — static gravity-tilt → sleep position.
//
// During LOW-MOTION epochs the 1 Hz accel vector is dominated by gravity, so
// its direction gives wrist pitch/roll. Mapped to a coarse body-position
// proxy: supine / prone / lateral-left / lateral-right / upright.
//
// HONESTY:
//   * This is the WRIST orientation, a body-position PROXY (catalog §Motion).
//     Wrist tilt correlates with, but is not identical to, torso posture.
//   * Static-tilt only. Dynamic/quaternion orientation (Madgwick/Mahony) needs
//     the ~100 Hz foreground stream and is DEFERRED to a foreground module.
//   * Computed ONLY on epochs that are still in BOTH senses — low rotation and
//     low |Δ‖a‖|. A wrist that is turning has no one posture, so those windows
//     return absent rather than a fabricated one.
//
//     The rotation half is what this substrate needs, and it is not a
//     refinement — it is the only half that works here. The gate used to be
//     ONLY mean
//     |Δ‖a‖|, jitter of the vector MAGNITUDE, which is blind to rotation BY
//     CONSTRUCTION: rotating a fixed-length vector does not change its length.
//     And the 1 Hz record ships a firmware-fused ~1 g vector (enmo.dart: p50
//     1.027 g, 1.033 ± 0.006 g during the most vigorous minute of a day), so
//     that gate could not fire on real data at all — measured, a 180° rotation
//     scored jitter 4.6e-17 g, stillness 1.000, confidence 0.90, and ten
//     minutes of continuous rotation published 10 lateral_right + 10
//     lateral_left postures. We now measure the ANGLE between successive
//     gravity vectors.
//
// Pitch/roll convention (device frame, x=lateral, y=longitudinal, z=normal):
//   pitch = atan2(-x, sqrt(y²+z²))   (forward/back tilt)
//   roll  = atan2( y, z)             (left/right tilt)
// expressed in degrees.

import 'dart:math' as math;
import '../types.dart';
import '../util.dart';

const double _rad2deg = 180.0 / math.pi;

/// A static tilt estimate over a low-motion epoch.
class Tilt {
  final double pitchDeg; // forward(+)/back(−)
  final double rollDeg; // right(+)/left(−)
  final String
      position; // supine|prone|lateral_left|lateral_right|upright|unknown
  final int nSamples;
  final double stillness; // 0..1 (1 = perfectly still)
  const Tilt(
    this.pitchDeg,
    this.rollDeg,
    this.position,
    this.nSamples,
    this.stillness,
  );
  Map<String, dynamic> toJson() => {
        'pitch_deg': round6(pitchDeg),
        'roll_deg': round6(rollDeg),
        'position': position,
        'n': nSamples,
        'stillness': round6(stillness),
      };
}

/// Classify a posture from pitch/roll (degrees). Coarse rule:
///   |pitch| > 60  → upright (arm vertical)
///   else by roll: |roll|<45 → supine; |roll|>135 → prone; roll≈±90 → lateral.
String classifyPosition(double pitchDeg, double rollDeg) {
  if (pitchDeg.abs() > 60) return 'upright';
  final r = rollDeg.abs();
  if (r < 45) return 'supine';
  if (r > 135) return 'prone';
  return rollDeg > 0 ? 'lateral_right' : 'lateral_left';
}

/// Allowed mean sample-to-sample ROTATION of the gravity vector (degrees) for
/// an epoch to count as static.
///
/// 3° is the angular equivalent of the 0.05 g magnitude gate this replaced (a
/// 0.05 g chord on a 1 g vector subtends ~2.87°), so the intended strictness is
/// unchanged — it is only now measuring the quantity it always claimed to.
const double defaultMaxRotationDeg = 3.0;

/// Estimate the static tilt + body-position proxy over an accel epoch.
///
/// Returns absent when the epoch is too short, the wrist is TURNING (a rotating
/// wrist has no single posture), or ‖a‖ is swinging (linear acceleration along
/// the gravity axis, which rotation cannot see). [maxRotationDeg] is the allowed
/// mean sample-to-sample angle between consecutive accel vectors;
/// [maxJitterG] the allowed mean |Δ‖a‖|. BOTH gates are needed: rotation is
/// blind to an axial shake, and magnitude is blind to rotation — and on this
/// substrate the magnitude one alone is blind to everything.
Metric<Tilt> staticTilt(
  List<AccelSample> epoch, {
  double maxRotationDeg = defaultMaxRotationDeg,
  double maxJitterG = 0.05,
  int minSamples = 3,
}) {
  const inputs = ['accel_1hz'];
  final valid = epoch.where((s) => s.valid).toList();
  if (valid.length < minSamples) {
    return const Metric<Tilt>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'epoch too short for a static-tilt estimate',
    );
  }
  final mags = <double>[
    for (final s in valid) math.sqrt(s.x * s.x + s.y * s.y + s.z * s.z)
  ];
  // Rotation = mean angle between consecutive accel vectors. Samples with a
  // degenerate (zero) magnitude carry no direction and are skipped.
  var rotSum = 0.0;
  var rotN = 0;
  for (var i = 1; i < valid.length; i++) {
    final a = valid[i - 1], b = valid[i];
    final ma = mags[i - 1], mb = mags[i];
    if (ma <= 0 || mb <= 0) continue;
    final cos =
        ((a.x * b.x + a.y * b.y + a.z * b.z) / (ma * mb)).clamp(-1.0, 1.0);
    rotSum += math.acos(cos) * _rad2deg;
    rotN++;
  }
  if (rotN == 0) {
    return const Metric<Tilt>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'accel vectors carry no direction (degenerate magnitude)',
    );
  }
  final rotDeg = rotSum / rotN;
  // Magnitude jitter — the old gate, kept as the SECOND condition. It is the
  // only one that sees a linear shake along the gravity axis (direction
  // constant, ‖a‖ swinging). It cannot see rotation, which is why it is no
  // longer the only one.
  var jitter = 0.0;
  for (var i = 1; i < mags.length; i++) {
    jitter += (mags[i] - mags[i - 1]).abs();
  }
  jitter = mags.length > 1 ? jitter / (mags.length - 1) : 0.0;
  // Stillness is the WORSE of the two — a posture is only as trustworthy as
  // the loosest thing that could have disturbed it.
  final stillness =
      (math.min(1.0 - rotDeg / maxRotationDeg, 1.0 - jitter / maxJitterG))
          .clamp(0.0, 1.0);
  if (rotDeg > maxRotationDeg) {
    return Metric<Tilt>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'wrist rotating ${rotDeg.toStringAsFixed(2)}°/sample > '
          '${maxRotationDeg}°; no single posture during motion',
    );
  }
  if (jitter > maxJitterG) {
    return Metric<Tilt>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'epoch too dynamic (jitter ${jitter.toStringAsFixed(3)}g > '
          '${maxJitterG}g); no static posture during motion',
    );
  }
  final mx = mean([for (final s in valid) s.x])!;
  final my = mean([for (final s in valid) s.y])!;
  final mz = mean([for (final s in valid) s.z])!;
  final pitch = math.atan2(-mx, math.sqrt(my * my + mz * mz)) * _rad2deg;
  final roll = math.atan2(my, mz) * _rad2deg;
  final pos = classifyPosition(pitch, roll);
  // confidence blends stillness with epoch length.
  final conf =
      (stillness * (valid.length / 30.0).clamp(0.3, 1.0)).clamp(0.0, 0.9);
  return Metric<Tilt>(
    value: Tilt(pitch, roll, pos, valid.length, stillness),
    confidence: conf,
    tier: Tier.high,
    inputs_used: inputs,
    note: 'wrist gravity-tilt; body-position PROXY (static, low-motion only)',
  );
}

/// Segment a night/stream into low-motion epochs and emit a posture per epoch.
///
/// Splits [samples] into fixed [epochSec] windows (bucketed by wall-clock
/// `tsMs`), runs [staticTilt] on each, and returns the present postures.
/// Epochs the wrist spent turning, or that are too short, are skipped (no
/// fabricated posture).
List<Tilt> positionSeries(
  List<AccelSample> samples, {
  int epochSec = 30,
  double maxRotationDeg = defaultMaxRotationDeg,
  double maxJitterG = 0.05,
}) {
  if (samples.isEmpty) return const [];
  final buckets = <int, List<AccelSample>>{};
  final win = epochSec * 1000;
  for (final s in samples) {
    if (!s.valid) continue;
    final k = (s.tsMs / win).floor();
    (buckets[k] ??= <AccelSample>[]).add(s);
  }
  final out = <Tilt>[];
  final keys = buckets.keys.toList()..sort();
  for (final k in keys) {
    final m = staticTilt(buckets[k]!,
        maxRotationDeg: maxRotationDeg, maxJitterG: maxJitterG);
    if (m.present) out.add(m.value!);
  }
  return out;
}
