// MOTION / ENERGY — branched HR + accel energy fusion (Brage 2004).
//
// Brage's "branched equation model" combines accelerometry and heart rate to
// estimate energy expenditure, switching the relative weight of each input by
// which regime the body is in. We have BOTH inputs @1 Hz, so we can apply the
// branch logic directly:
//
//   - LOW motion AND LOW HR  → both agree on rest; weight accel (HR noise/RSA
//                              dominates the small HR signal at rest).
//   - LOW motion AND HIGH HR → non-locomotor load (isometric/stress/recovery);
//                              weight HR (accel blind to it).
//   - HIGH motion AND LOW HR → transient/artifactual motion; weight accel but
//                              discount (HR hasn't responded ⇒ likely brief).
//   - HIGH motion AND HIGH HR → locomotor exercise; both inform; HR-led.
//
// HONESTY (catalog §Motion, MED tier):
//   * Output is a RELATIVE energy-expenditure index (0..1 per sample, summable
//     to a relative load), NOT kcal / METs / joules — UNLESS per-user HR
//     calibration is supplied (restingHr + maxHr), in which case the HR branch
//     uses %HR-reserve (still an estimate, ESTIMATE tier).
//   * Never asserts absolute EE without calibration.

import '../types.dart';
import '../util.dart';

/// Per-sample fused energy estimate.
class EnergyPoint {
  final double tsMs;
  final double index; // relative EE index, 0..1
  final double accelComponent; // normalized accel contribution 0..1
  final double hrComponent; // normalized HR contribution 0..1
  final double accelWeight; // branch weight applied to accel (0..1)
  final String branch; // rest | nonlocomotor | transient | locomotor
  const EnergyPoint(
    this.tsMs,
    this.index,
    this.accelComponent,
    this.hrComponent,
    this.accelWeight,
    this.branch,
  );
}

/// Result of [branchedEnergyFusion].
class EnergyFusion {
  final List<EnergyPoint> points;
  final double relativeLoad; // Σ index (relative cumulative EE)
  final bool calibrated; // true if per-user HR anchors were used
  const EnergyFusion(this.points, this.relativeLoad, this.calibrated);
}

/// Normalize ENMO to 0..1 against a soft saturation reference (g). 0.5 g of
/// ENMO is already vigorous wrist motion, so we saturate there by default.
double _normAccel(double enmo, double satG) {
  if (enmo <= 0) return 0.0;
  final v = enmo / satG;
  return v > 1 ? 1.0 : v;
}

/// Normalize HR to 0..1. With calibration → %HR-reserve. Without → a soft
/// population-ish ramp from 50→180 bpm (RELATIVE only).
double _normHr(double hr, double? restingHr, double? maxHr) {
  if (hr <= 0) return 0.0;
  if (restingHr != null && maxHr != null && maxHr > restingHr) {
    final hrr = (hr - restingHr) / (maxHr - restingHr);
    return clamp(hrr, 0.0, 1.0);
  }
  final v = (hr - 50.0) / (180.0 - 50.0);
  return clamp(v, 0.0, 1.0);
}

/// Branched HR-accel energy fusion over time-aligned 1 Hz HR + ENMO samples.
///
/// [tsMs], [enmo] (per-sample ENMO, g), [hr] (per-sample bpm; 0 = off-skin)
/// must be equal length and time-aligned. [restingHr]/[maxHr] enable the
/// calibrated %HR-reserve branch (ESTIMATE tier); else RELATIVE tier.
/// [accelHi]/[hrHi] are the LOW/HIGH split thresholds on the NORMALIZED
/// (0..1) components.
Metric<EnergyFusion> branchedEnergyFusion(
  List<double> tsMs,
  List<double> enmo,
  List<double> hr, {
  double? restingHr,
  double? maxHr,
  double accelSatG = 0.5,
  double accelHi = 0.15,
  double hrHi = 0.4,
}) {
  const inputs = ['enmo_1hz', 'hr_1hz', 'resting_hr?', 'max_hr?'];
  final n = tsMs.length;
  if (n == 0 || enmo.length != n || hr.length != n) {
    return const Metric<EnergyFusion>.absent(
      tier: Tier.relative,
      inputs_used: inputs,
      note: 'HR/ENMO/ts must be equal-length and time-aligned',
    );
  }
  final calibrated =
      restingHr != null && maxHr != null && maxHr > restingHr;
  final pts = <EnergyPoint>[];
  var load = 0.0;
  var usable = 0;
  for (var i = 0; i < n; i++) {
    final a = _normAccel(enmo[i], accelSatG);
    final hValid = hr[i] > 0;
    if (hValid) usable++;
    final h = _normHr(hr[i], restingHr, maxHr);

    final highA = a >= accelHi;
    // If HR is off-skin we can't read the HR branch; lean fully on accel.
    final highH = hValid && h >= hrHi;

    String branch;
    double wA; // weight on accel; HR gets (1-wA)
    if (!hValid) {
      branch = 'accel_only';
      wA = 1.0;
    } else if (!highA && !highH) {
      branch = 'rest';
      wA = 0.85; // both low: trust accel, HR at rest is RSA-noisy
    } else if (!highA && highH) {
      branch = 'nonlocomotor';
      wA = 0.15; // sitting-but-loaded: HR carries the signal
    } else if (highA && !highH) {
      branch = 'transient';
      wA = 0.7; // motion w/o HR response: accel-led but discounted below
    } else {
      branch = 'locomotor';
      wA = 0.4; // exercise: HR-led, accel confirms
    }
    var idx = wA * a + (1 - wA) * (hValid ? h : 0.0);
    if (branch == 'transient') idx *= 0.7; // discount artifact-prone motion
    idx = clamp(idx, 0.0, 1.0);
    load += idx;
    pts.add(EnergyPoint(tsMs[i], idx, a, hValid ? h : 0.0, wA, branch));
  }
  // confidence: data coverage × (calibration bonus)
  final cov = usable / n;
  final conf = clamp(cov * (calibrated ? 0.7 : 0.5), 0.0, 0.7);
  return Metric<EnergyFusion>(
    value: EnergyFusion(pts, load, calibrated),
    confidence: conf,
    tier: calibrated ? Tier.estimate : Tier.relative,
    inputs_used: inputs,
    note: calibrated
        ? 'Brage branched fusion w/ %HR-reserve; ESTIMATE EE, not kcal/METs'
        : 'Brage branched fusion; RELATIVE EE index (no per-user HR calib)',
  );
}
