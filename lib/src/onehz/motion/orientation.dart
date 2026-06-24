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
//   * Computed ONLY on low-motion epochs (|‖a‖−g|, sample jitter small); high-
//     motion windows return absent rather than a fabricated posture.
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
  final String position; // supine|prone|lateral_left|lateral_right|upright|unknown
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

/// Estimate the static tilt + body-position proxy over an accel epoch.
///
/// Returns absent when the epoch is too short OR too dynamic (motion swamps
/// gravity, so direction is meaningless). [maxJitterG] is the allowed mean
/// sample-to-sample magnitude change for the epoch to count as "static".
Metric<Tilt> staticTilt(
  List<AccelSample> epoch, {
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
  // mean gravity vector over the epoch
  final mags = <double>[
    for (final s in valid) math.sqrt(s.x * s.x + s.y * s.y + s.z * s.z)
  ];
  // jitter = mean |Δ‖a‖| between consecutive samples
  var jitter = 0.0;
  for (var i = 1; i < mags.length; i++) {
    jitter += (mags[i] - mags[i - 1]).abs();
  }
  jitter = mags.length > 1 ? jitter / (mags.length - 1) : 0.0;
  final stillness = clamp(1.0 - jitter / maxJitterG, 0.0, 1.0);
  if (jitter > maxJitterG) {
    return Metric<Tilt>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note:
          'epoch too dynamic (jitter ${jitter.toStringAsFixed(3)}g > ${maxJitterG}g); '
          'no static posture during motion',
    );
  }
  final mx = mean([for (final s in valid) s.x])!;
  final my = mean([for (final s in valid) s.y])!;
  final mz = mean([for (final s in valid) s.z])!;
  final pitch = math.atan2(-mx, math.sqrt(my * my + mz * mz)) * _rad2deg;
  final roll = math.atan2(my, mz) * _rad2deg;
  final pos = classifyPosition(pitch, roll);
  // confidence blends stillness with epoch length.
  final conf = clamp(stillness * (valid.length / 30.0).clamp(0.3, 1.0), 0.0, 0.9);
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
/// Epochs that are too dynamic/short are skipped (no fabricated posture).
List<Tilt> positionSeries(
  List<AccelSample> samples, {
  int epochSec = 30,
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
    final m = staticTilt(buckets[k]!, maxJitterG: maxJitterG);
    if (m.present) out.add(m.value!);
  }
  return out;
}
