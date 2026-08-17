// MOTION / ACTIVITY — per-minute amplitude indices on a 1 Hz accel stream.
//
// THREE per-minute features live here, computed in one pass:
//
//   ENMO_i   = max(0, ‖a_i‖ − g_ref)                  per sample, mean/minute
//              (van Hees 2013, Euclidean Norm Minus One)
//   MAD_min  = mean_i( |‖a_i‖ − mean_min(‖a‖)| )      per minute
//              (Vähä-Ypyä 2015, Mean Amplitude Deviation)
//   dynAmp   = mean_i( ‖a_i − rollingMean(a)‖ )       per minute  ← see below
//
// WHY dynAmp EXISTS (calibration invariance).
//   ENMO subtracts a SCALAR gravity reference `g_ref` from every sample. That
//   reference has to be estimated from the data, and on a wrist the estimate is
//   orientation-dependent: a consumer MEMS accel carries a few percent of
//   per-axis gain and offset error, so the measured ‖a‖ of a motionless wrist
//   differs by several 0.01 g between, say, a sleeping posture and a sitting
//   posture. Auto-calibration keys off the stillest epochs, which on a 24 h day
//   is the sleep block — so g_ref is biased toward the sleep orientation and is
//   then subtracted from the whole waking day. The resulting bias is the SAME
//   ORDER as the walking signal itself (both ~0.05 g), i.e. SNR ≈ 1 by
//   construction. No threshold on ENMO can be stable against that.
//
//   Vähä-Ypyä 2015 makes exactly this argument for preferring an amplitude
//   measure that does not depend on knowing ‖g‖. dynAmp takes it one step
//   further and removes gravity as a VECTOR rather than as a scalar norm:
//   gravity is constant in the SENSOR frame over a short window, motion is AC,
//   so a per-axis high-pass leaves only the dynamic component.
//
//     dx_i = a_i − rollingMean(a over the last `highPassWindowS` seconds)
//     dyn_i = ‖dx_i‖ ,  dynAmp(minute) = mean(dyn over the minute)
//
//   Under a per-axis affine sensor error a' = G·a + b (G diagonal gain, b
//   offset), the rolling mean maps to G·mean + b, so the OFFSET b CANCELS
//   EXACTLY — every constant per-axis bias, including whatever gravity happens
//   to project onto each axis in the current posture, lands in the DC term and
//   is removed. A residual gain G only SCALES dyn, so any threshold expressed
//   as a quantile of the user's own dynAmp distribution is invariant to it too.
//
// HONESTY (catalog §"what 1 Hz accel CANNOT do", Nyquist):
//   * 1 Hz accel gives an AMPLITUDE index only. NO steps, NO cadence, NO gait,
//     NO frequency-domain activity classification (gait is 1.4–2.5 Hz, far
//     above the 0.5 Hz Nyquist limit of a 1 Hz stream).
//   * Intensity bands here are RELATIVE (within-user, percentile-of-you),
//     NOT absolute METs — wrist 1 Hz cannot calibrate energy in MET units.
//   * The 1 g reference is AUTO-CALIBRATED from the data's own still epochs,
//     since the sensor's zero-g offset/gain drift. [calibrateGRef] and [enmo]
//     are RETAINED for the callers that legitimately want a norm-based index
//     (van Hees sleep detection, Brage energy fusion) — but any decision that
//     needs a STABLE absolute cut-point should use [MotionMinute.dynAmp].

import 'dart:math' as math;
import '../types.dart';
import '../util.dart';

/// Per-minute motion aggregate from a 1 Hz accel stream.
class MotionMinute {
  final double tsMinStartMs; // wall-clock start of the minute (ms)
  final int nSamples; // valid samples that fed this minute

  /// ⚠️ MEANINGLESS ON THE WHOOP 1 Hz SUBSTRATE — diagnostics only.
  ///
  /// ENMO is `mean(max(0, ‖a‖ − gRef))`, which assumes ‖a‖ carries dynamic
  /// acceleration. The band's 1 Hz historical record does NOT: it ships a fused
  /// gravity/orientation vector (see [dynAmp]). Measured over 269,486 real
  /// samples, ‖a‖ sits at p50 = 1.027 g with only 0.030% above 1.3 g — during
  /// the single most vigorous minute of a day it was 1.033 g ± 0.006.
  ///
  /// So on this substrate ENMO reduces to roughly `1.03 − gRef`: a pure
  /// calibration artifact carrying ZERO signal. That is precisely why an early
  /// step estimator built on it reported 42,155 steps at gRef 0.97 and 0 at
  /// 1.02. Do NOT threshold this, and do NOT feed it to anything expecting
  /// accelerometry (Brage fusion, MET/cut-point models). It stays only because
  /// a HIGH-RATE source (the 100 Hz live stream) does carry real accel.
  final double enmo;

  /// ⚠️ Same caveat as [enmo] on the 1 Hz substrate — see above.
  final double mad;
  final double meanMag; // mean ‖a‖ over the minute (g) — for diagnostics

  /// Mean magnitude of the per-axis HIGH-PASSED vector over the minute (g), ≥0.
  ///
  /// WHAT IT ACTUALLY MEASURES: on the WHOOP 1 Hz record this is the rate at
  /// which the wrist is RE-ORIENTING, not how hard it is accelerating. That
  /// record's accel field is a firmware-fused gravity vector — its magnitude is
  /// pinned near 1 g even during the most vigorous minute of a day (measured:
  /// 1.033 g ± 0.006, 0 of 420 samples above 1.2 g). High-passing an
  /// (approximately) unit vector yields how fast its DIRECTION is changing.
  ///
  /// That is still a usable activity-volume index — rotating the wrist a lot is
  /// real movement — but read it honestly:
  ///   • walking with hands in pockets, holding a phone, or pushing a cart
  ///     keeps the forearm still and is nearly INVISIBLE here;
  ///   • stirring, chopping, tool use and gesturing are MAXIMAL here.
  /// It is not a locomotion measure and must never be converted to steps.
  ///
  /// CALIBRATION-INVARIANT, and this is load-bearing: a constant per-axis offset
  /// (sensor bias, or the gravity projection of a held posture) appears in both
  /// the sample and its trailing mean and cancels EXACTLY; a uniform gain error
  /// rescales signal and threshold alike, so a floor derived from this same
  /// signal's own distribution cancels it too (verified numerically: +5% gain
  /// moves the gate decision by 0.0000). Only per-axis ANISOTROPIC gain
  /// survives, at ~1-3%. This is why autocalibration is unnecessary here — but
  /// the invariance is a property of the TRAILING-MEAN REFERENCE, not of the
  /// sensor. Reintroduce any fixed-1 g reference and calibration becomes
  /// mandatory again, and this type's property tests will NOT catch it.
  final double dynAmp;

  const MotionMinute(
    this.tsMinStartMs,
    this.nSamples,
    this.enmo,
    this.mad,
    this.meanMag,
    this.dynAmp,
  );
  Map<String, dynamic> toJson() => {
        'ts_min_start_ms': tsMinStartMs,
        'n': nSamples,
        'enmo_g': round6(enmo),
        'mad_g': round6(mad),
        'mean_mag_g': round6(meanMag),
        'dyn_amp_g': round6(dynAmp),
      };
}

/// Result of [enmoSeries]: the calibrated 1 g reference plus per-minute rows.
class EnmoResult {
  final double gRef; // auto-calibrated 1 g reference (g)
  final List<MotionMinute> minutes;
  final double coverage; // fraction of minutes with ≥ minSamplesPerMinute
  const EnmoResult(this.gRef, this.minutes, this.coverage);
}

/// Auto-calibrate the 1 g reference from the still epochs of the stream.
///
/// We take the per-sample magnitude ‖a‖ and use the MEDIAN over the lowest-
/// variability portion as the gravity reference. Concretely: the median of all
/// magnitudes whose local |Δ‖a‖| is below the sample-set's own median step —
/// i.e. magnitudes recorded while essentially still — which is where ‖a‖≈g.
/// Falls back to the overall median, then to 1.0, never returning a degenerate
/// (≤0) reference.
double calibrateGRef(List<double> mags) {
  if (mags.isEmpty) return 1.0;
  if (mags.length == 1) return mags.first > 0 ? mags.first : 1.0;
  // local first-difference magnitude
  final steps = <double>[];
  for (var i = 1; i < mags.length; i++) {
    steps.add((mags[i] - mags[i - 1]).abs());
  }
  final stepThresh = median(steps) ?? 0.0;
  final still = <double>[];
  for (var i = 1; i < mags.length; i++) {
    if ((mags[i] - mags[i - 1]).abs() <= stepThresh) still.add(mags[i]);
  }
  final g = (still.length >= 2 ? median(still) : median(mags)) ?? 1.0;
  return g > 0 ? g : 1.0;
}

/// Default high-pass window (s) that separates GRAVITY from MOTION.
///
/// Gravity is a constant vector in the sensor frame over short windows, so
/// everything slower than ~1/[defaultGravityWindowS] Hz is treated as gravity
/// (plus per-axis sensor bias) and removed; everything faster is motion.
/// 15 s ≈ a 0.067 Hz corner: well below any voluntary movement, well above the
/// timescale on which a wrist changes posture.
const double defaultGravityWindowS = 15.0;

/// Compute the per-minute motion indices (ENMO + MAD + dynAmp) over a 1 Hz
/// accel series, in a single pass.
///
/// [samples] need not be exactly 1 Hz nor perfectly contiguous — minutes are
/// bucketed by wall-clock `tsMs`, and samples are sorted by `tsMs` first so the
/// high-pass window is causal in real time. Invalid (off-wrist) samples are
/// dropped. [gRef] overrides auto-calibration when a personal/static reference
/// is known. [minSamplesPerMinute] gates a minute as covered (default 30 =
/// ≥50% @1 Hz). [gravityWindowS] is THE GRAVITY BAND: the trailing window whose
/// per-axis mean is treated as gravity + constant sensor bias and subtracted
/// from each axis before taking the magnitude (see [MotionMinute.dynAmp]).
///
/// Edge/gap handling is honest, not padded: the trailing mean is taken over
/// whatever samples actually fall inside the window, so the first samples of a
/// series average over fewer points (the very first sample has dyn = 0 by
/// construction, since it is its own mean), and a recording gap longer than
/// [gravityWindowS] simply empties the window rather than carrying a stale
/// gravity estimate across the gap.
EnmoResult enmoSeries(
  List<AccelSample> samples, {
  double? gRef,
  int minSamplesPerMinute = 30,
  double gravityWindowS = defaultGravityWindowS,
  int? expectedMinutes,
}) {
  final valid = samples.where((s) => s.valid).toList()
    ..sort((a, b) => a.tsMs.compareTo(b.tsMs));
  if (valid.isEmpty) return EnmoResult(gRef ?? 1.0, const [], 0.0);

  final mags = <double>[
    for (final s in valid) math.sqrt(s.x * s.x + s.y * s.y + s.z * s.z)
  ];
  final ref = gRef ?? calibrateGRef(mags);

  // ── per-axis high-pass → dynamic-vector magnitude (calibration-invariant) ──
  // dx = a − trailingMean(a, gravityWindowS). A constant per-axis offset (and
  // the constant gravity projection of the current posture) appears identically
  // in a and in its mean, so it cancels EXACTLY. Window is bounded by TIME, not
  // sample count, so it is sample-rate agnostic and gap-safe.
  final dyn = List<double>.filled(valid.length, 0.0);
  final windowMs = gravityWindowS * 1000.0;
  var lo = 0;
  var sx = 0.0, sy = 0.0, sz = 0.0;
  for (var i = 0; i < valid.length; i++) {
    final s = valid[i];
    sx += s.x;
    sy += s.y;
    sz += s.z;
    while (lo < i && (s.tsMs - valid[lo].tsMs) >= windowMs) {
      sx -= valid[lo].x;
      sy -= valid[lo].y;
      sz -= valid[lo].z;
      lo++;
    }
    final n = i - lo + 1;
    final dx = s.x - sx / n;
    final dy = s.y - sy / n;
    final dz = s.z - sz / n;
    dyn[i] = math.sqrt(dx * dx + dy * dy + dz * dz);
  }

  // bucket sample indices by minute
  final buckets = <int, List<int>>{};
  for (var i = 0; i < valid.length; i++) {
    final minIdx = (valid[i].tsMs / 60000).floor();
    (buckets[minIdx] ??= <int>[]).add(i);
  }

  final minutes = <MotionMinute>[];
  var covered = 0;
  final keys = buckets.keys.toList()..sort();
  for (final k in keys) {
    final idxs = buckets[k]!;
    final magsMin = [for (final i in idxs) mags[i]];
    final meanMag = mean(magsMin)!;
    // ENMO: per-sample max(0, ‖a‖ − gRef), averaged.
    var enmoSum = 0.0;
    for (final m in magsMin) {
      final e = m - ref;
      enmoSum += e > 0 ? e : 0.0;
    }
    final enmo = enmoSum / magsMin.length;
    // MAD: mean absolute deviation of ‖a‖ from the minute mean.
    var madSum = 0.0;
    for (final m in magsMin) {
      madSum += (m - meanMag).abs();
    }
    final mad = madSum / magsMin.length;
    // dynAmp: mean gravity-removed vector magnitude over the minute.
    var dynSum = 0.0;
    for (final i in idxs) {
      dynSum += dyn[i];
    }
    final dynAmp = dynSum / idxs.length;
    if (idxs.length >= minSamplesPerMinute) covered++;
    minutes.add(MotionMinute(
      k * 60000.0,
      idxs.length,
      enmo,
      mad,
      meanMag,
      dynAmp,
    ));
  }
  // COVERAGE DENOMINATOR. `minutes` holds only the minutes that had at least
  // one sample, so `covered / minutes.length` reported 1.0 for a day worn 4 h
  // out of 24. Divide by the elapsed minute SPAN instead, which at least counts
  // interior holes; pass [expectedMinutes] (e.g. 1440 for a calendar day) to
  // count the unworn ends too.
  final spanMinutes = minutes.isEmpty ? 0 : keys.last - keys.first + 1;
  final denom = expectedMinutes ?? spanMinutes;
  final coverage = denom <= 0 ? 0.0 : clamp(covered / denom, 0.0, 1.0);
  return EnmoResult(ref, minutes, coverage);
}

/// Relative intensity bands. WITHIN-USER percentile cut-points over the
/// supplied ENMO history — NOT absolute METs. Returns one band label per
/// minute: sedentary / light / moderate / vigorous, by quartile of the user's
/// own moving (ENMO>0) distribution. Sedentary is anything at/near zero ENMO.
class IntensityBands {
  /// percentile cut-points (g) on the user's moving distribution.
  /// NULL when there were too few moving minutes to set personal cut-points —
  /// the labels are still valid (sedentary/light), the cut-points are simply
  /// not yet knowable. Never NaN.
  final double? lightCut;
  final double? moderateCut;
  final double? vigorousCut;
  final List<String> labels; // per input minute
  final Map<String, int> minutesInBand;
  const IntensityBands(
    this.lightCut,
    this.moderateCut,
    this.vigorousCut,
    this.labels,
    this.minutesInBand,
  );
}

/// Build RELATIVE intensity bands from a sequence of per-minute ENMO values.
///
/// Cut-points are personal percentiles (50/75/90) of the user's MOVING
/// minutes (ENMO above [sedentaryEnmo]); minutes at/under that floor are
/// "sedentary". Honest: this is percentile-of-you, never a MET threshold.
///
/// THE CUT-POINTS MUST BE FROZEN. Without [frozenCuts] this takes percentiles
/// OF ITS OWN INPUT, which means fed one day it labels the top decile of a rest
/// day "vigorous" and a deconditioning period silently lowers the vigorous
/// threshold to meet it — the same defect `personalDynFloor` is already frozen
/// to avoid. Pass cut-points established once over a pooled history and
/// persisted; the self-percentile path stays only for computing that pool the
/// first time (and for tests), and its note says so.
///
/// SO: THE CONDITION FOR CALLING THIS AT ALL is that [frozenCuts] exists and is
/// persisted. it has zero callers today for exactly that reason — nothing in
/// edge stores a cut-point triple yet. wiring it on the self-percentile path
/// "just to see it on screen" ships a label that redefines itself every time
/// the user's week changes, which is worse than no label. build the pool and
/// the column first, then call this with them.
Metric<IntensityBands> relativeIntensityBands(
  List<double> enmoPerMin, {
  double sedentaryEnmo = 0.01,
  ({double light, double moderate, double vigorous})? frozenCuts,
}) {
  const inputs = ['enmo_per_min'];
  if (enmoPerMin.isEmpty) {
    return const Metric<IntensityBands>.absent(
      tier: Tier.relative,
      inputs_used: inputs,
      note: 'no ENMO minutes',
    );
  }
  if (frozenCuts != null) {
    // Monotone or the labelling is nonsense (a "vigorous" cut under the
    // "moderate" one makes every moderate minute vigorous). Refuse rather than
    // reorder them: whatever produced them is wrong and should hear about it.
    if (!(frozenCuts.light < frozenCuts.moderate &&
        frozenCuts.moderate < frozenCuts.vigorous)) {
      return const Metric<IntensityBands>.absent(
        tier: Tier.relative,
        inputs_used: inputs,
        note: 'frozen cut-points not strictly increasing',
      );
    }
    return _labelWithCuts(
      enmoPerMin,
      sedentaryEnmo,
      frozenCuts.light,
      frozenCuts.moderate,
      frozenCuts.vigorous,
      // The anchoring quality belongs to whoever froze the cuts, not to this
      // day's minute count, so it is not re-derived from this input.
      0.8,
      'RELATIVE within-user intensity vs FROZEN personal cut-points; NOT METs',
    );
  }
  final moving = enmoPerMin.where((e) => e > sedentaryEnmo).toList();
  // Need a moving distribution to set personal cut-points.
  if (moving.length < 4) {
    final labels = [
      for (final e in enmoPerMin) e > sedentaryEnmo ? 'light' : 'sedentary'
    ];
    final counts = <String, int>{
      'sedentary': 0,
      'light': 0,
      'moderate': 0,
      'vigorous': 0
    };
    for (final l in labels) {
      counts[l] = counts[l]! + 1;
    }
    return Metric<IntensityBands>(
      value: IntensityBands(null, null, null, labels, counts),
      confidence: 0.25,
      tier: Tier.relative,
      inputs_used: inputs,
      note:
          'too few moving minutes for personal cut-points; RELATIVE, not METs',
    );
  }
  return _labelWithCuts(
    enmoPerMin,
    sedentaryEnmo,
    percentile(moving, 50)!,
    percentile(moving, 75)!,
    percentile(moving, 90)!,
    // confidence scales with how much moving data anchors the percentiles.
    clamp(moving.length / 60.0, 0.3, 0.8),
    'RELATIVE within-user intensity (50/75/90th moving pct OF THIS INPUT — '
    'cut-points not frozen); NOT METs',
  );
}

/// The labelling half, shared by the frozen-cut and self-percentile paths so
/// the two can never band the same minute differently.
Metric<IntensityBands> _labelWithCuts(
  List<double> enmoPerMin,
  double sedentaryEnmo,
  double light,
  double moderate,
  double vigorous,
  double confidence,
  String note,
) {
  final labels = <String>[];
  final counts = <String, int>{
    'sedentary': 0,
    'light': 0,
    'moderate': 0,
    'vigorous': 0
  };
  for (final e in enmoPerMin) {
    String l;
    if (e <= sedentaryEnmo) {
      l = 'sedentary';
    } else if (e >= vigorous) {
      l = 'vigorous';
    } else if (e >= moderate) {
      l = 'moderate';
    } else {
      l = 'light';
    }
    labels.add(l);
    counts[l] = counts[l]! + 1;
  }
  return Metric<IntensityBands>(
    value: IntensityBands(light, moderate, vigorous, labels, counts),
    confidence: confidence,
    tier: Tier.relative,
    inputs_used: const ['enmo_per_min'],
    note: note,
  );
}
