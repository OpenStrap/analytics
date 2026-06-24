// MOTION / ACTIVITY — ENMO + MAD per-minute amplitude index.
//
// van Hees 2013 (ENMO = Euclidean Norm Minus One) / Vähä-Ypyä 2015 (MAD,
// Mean Amplitude Deviation). The foundational 24/7 motion index on a 1 Hz
// gravity-vector accel stream.
//
//   ENMO_i  = max(0, ‖a_i‖ − g_ref)        per sample, then aggregated/min
//   MAD_min = mean_i( |‖a_i‖ − mean_min(‖a‖)| )   per minute
//
// HONESTY (catalog §"what 1 Hz accel CANNOT do", Nyquist):
//   * 1 Hz accel gives an AMPLITUDE index only. NO steps, NO cadence, NO gait,
//     NO frequency-domain activity classification (gait is 1.4–2.5 Hz, far
//     above the 0.5 Hz Nyquist limit of a 1 Hz stream).
//   * Intensity bands here are RELATIVE (within-user, percentile-of-you),
//     NOT absolute METs — wrist 1 Hz cannot calibrate energy in MET units.
//   * The 1 g reference is AUTO-CALIBRATED from the data's own still epochs,
//     since the sensor's zero-g offset/gain drift.

import 'dart:math' as math;
import '../types.dart';
import '../util.dart';

/// Per-minute motion aggregate from a 1 Hz accel stream.
class MotionMinute {
  final double tsMinStartMs; // wall-clock start of the minute (ms)
  final int nSamples; // valid samples that fed this minute
  final double enmo; // mean ENMO over the minute (g), ≥0
  final double mad; // mean amplitude deviation over the minute (g), ≥0
  final double meanMag; // mean ‖a‖ over the minute (g) — for diagnostics
  const MotionMinute(
    this.tsMinStartMs,
    this.nSamples,
    this.enmo,
    this.mad,
    this.meanMag,
  );
  Map<String, dynamic> toJson() => {
        'ts_min_start_ms': tsMinStartMs,
        'n': nSamples,
        'enmo_g': round6(enmo),
        'mad_g': round6(mad),
        'mean_mag_g': round6(meanMag),
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

/// Compute the ENMO + MAD per-minute motion index over a 1 Hz accel series.
///
/// [samples] need not be exactly 1 Hz nor perfectly contiguous — minutes are
/// bucketed by wall-clock `tsMs`. Invalid (off-wrist) samples are dropped.
/// [gRef] overrides auto-calibration when a personal/static reference is known.
/// [minSamplesPerMinute] gates a minute as covered (default 30 = ≥50% @1 Hz).
EnmoResult enmoSeries(
  List<AccelSample> samples, {
  double? gRef,
  int minSamplesPerMinute = 30,
}) {
  final valid = samples.where((s) => s.valid).toList();
  if (valid.isEmpty) return EnmoResult(gRef ?? 1.0, const [], 0.0);

  final mags = <double>[
    for (final s in valid) math.sqrt(s.x * s.x + s.y * s.y + s.z * s.z)
  ];
  final ref = gRef ?? calibrateGRef(mags);

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
    if (idxs.length >= minSamplesPerMinute) covered++;
    minutes.add(MotionMinute(
      k * 60000.0,
      idxs.length,
      enmo,
      mad,
      meanMag,
    ));
  }
  final coverage = minutes.isEmpty ? 0.0 : covered / minutes.length;
  return EnmoResult(ref, minutes, coverage);
}

/// Relative intensity bands. WITHIN-USER percentile cut-points over the
/// supplied ENMO history — NOT absolute METs. Returns one band label per
/// minute: sedentary / light / moderate / vigorous, by quartile of the user's
/// own moving (ENMO>0) distribution. Sedentary is anything at/near zero ENMO.
class IntensityBands {
  /// percentile cut-points (g) on the user's moving distribution
  final double lightCut;
  final double moderateCut;
  final double vigorousCut;
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
Metric<IntensityBands> relativeIntensityBands(
  List<double> enmoPerMin, {
  double sedentaryEnmo = 0.01,
}) {
  const inputs = ['enmo_per_min'];
  if (enmoPerMin.isEmpty) {
    return const Metric<IntensityBands>.absent(
      tier: Tier.relative,
      inputs_used: inputs,
      note: 'no ENMO minutes',
    );
  }
  final moving = enmoPerMin.where((e) => e > sedentaryEnmo).toList();
  // Need a moving distribution to set personal cut-points.
  if (moving.length < 4) {
    final labels = [
      for (final e in enmoPerMin) e > sedentaryEnmo ? 'light' : 'sedentary'
    ];
    final counts = <String, int>{'sedentary': 0, 'light': 0, 'moderate': 0, 'vigorous': 0};
    for (final l in labels) {
      counts[l] = counts[l]! + 1;
    }
    return Metric<IntensityBands>(
      value: IntensityBands(
          double.nan, double.nan, double.nan, labels, counts),
      confidence: 0.25,
      tier: Tier.relative,
      inputs_used: inputs,
      note:
          'too few moving minutes for personal cut-points; RELATIVE, not METs',
    );
  }
  final light = percentile(moving, 50)!;
  final moderate = percentile(moving, 75)!;
  final vigorous = percentile(moving, 90)!;
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
  // confidence scales with how much moving data anchors the percentiles.
  final conf = clamp(moving.length / 60.0, 0.3, 0.8);
  return Metric<IntensityBands>(
    value: IntensityBands(light, moderate, vigorous, labels, counts),
    confidence: conf,
    tier: Tier.relative,
    inputs_used: inputs,
    note: 'RELATIVE within-user intensity (50/75/90th moving pct); NOT METs',
  );
}
