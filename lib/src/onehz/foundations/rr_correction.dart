// FOUNDATION — RR artifact correction.
//
// Lipponen & Tarvainen 2019 ("A robust algorithm for heart rate variability
// time series artefact correction using novel beat classification", J Med Eng
// Technol) — the detector Kubios automates. Applies the dRR / mRR / sRR
// decision logic with a time-varying threshold derived from a quantile-based
// dispersion of dRR over a sliding window.
//
// Correction policy (Peltola 2012):
//   * cubic-spline interpolate ONLY isolated single ectopic/missed/extra beats;
//   * flag-and-drop multi-beat runs — never interpolate a run.
//
// This is PRV. Output = cleaned NN series + per-beat artifact mask + clean
// fraction. Multi-beat gaps are never silently bridged.

import 'dart:math' as math;
import '../util.dart';

/// Artifact label for a single beat.
enum BeatClass { normal, ectopic, longShort, missed, extra }

class RrCorrectionResult {
  /// Cleaned NN intervals (ms). Isolated artifacts spline-corrected; multi-beat
  /// runs dropped (length may differ from the input).
  final List<double> nn;

  /// Beat-time (ms) for each NN interval, cumulative from t0.
  final List<double> nnTimesMs;

  /// Per-input-beat classification (same length as the input rr).
  final List<BeatClass> classes;

  /// Fraction of input beats classified normal (0..1).
  final double cleanFraction;

  /// Count of beats dropped (part of a multi-beat run, not interpolated).
  final int droppedCount;

  /// Count of isolated beats that were spline-corrected.
  final int correctedCount;

  const RrCorrectionResult({
    required this.nn,
    required this.nnTimesMs,
    required this.classes,
    required this.cleanFraction,
    required this.droppedCount,
    required this.correctedCount,
  });
}

/// Lipponen–Tarvainen RR artifact correction.
///
/// [rrMs] the raw RR series (ms). [alpha] scales the time-varying threshold
/// (paper default 5.2 on the QD estimate). [windowBeats] sliding window for the
/// local dispersion estimate.
RrCorrectionResult correctRr(
  List<double> rrMs, {
  double alpha = 5.2,
  int windowBeats = 91,
  double minThresholdMs = 100,
}) {
  final n = rrMs.length;
  if (n == 0) {
    return const RrCorrectionResult(
      nn: [],
      nnTimesMs: [],
      classes: [],
      cleanFraction: 0,
      droppedCount: 0,
      correctedCount: 0,
    );
  }
  if (n < 3) {
    // Too short to estimate dispersion: pass through physiologically-plausible
    // beats only, classify the rest as long/short. No fabrication.
    final classes = [
      for (final rr in rrMs)
        (rr >= 300 && rr <= 2000) ? BeatClass.normal : BeatClass.longShort
    ];
    final nn = <double>[];
    final times = <double>[];
    var t = 0.0;
    for (var i = 0; i < n; i++) {
      if (classes[i] == BeatClass.normal) {
        t += rrMs[i];
        nn.add(rrMs[i]);
        times.add(t);
      }
    }
    return RrCorrectionResult(
      nn: nn,
      nnTimesMs: times,
      classes: classes,
      cleanFraction: nn.length / n,
      droppedCount: n - nn.length,
      correctedCount: 0,
    );
  }

  // dRR[i] = rr[i] - rr[i-1].
  final dRR = List<double>.filled(n, 0);
  for (var i = 1; i < n; i++) {
    dRR[i] = rrMs[i] - rrMs[i - 1];
  }

  // Time-varying threshold from a sliding quartile-deviation (QD) of dRR.
  // th1 ~ dispersion of dRR (short artifacts), th2 ~ dispersion of medianed RR.
  final th1 = _slidingThreshold(dRR, windowBeats, alpha, minThresholdMs);

  // medRR: rr minus local median (for missed/extra long-range tests).
  final med = _slidingMedian(rrMs, windowBeats);
  final mRR = List<double>.generate(n, (i) {
    final d = rrMs[i] - med[i];
    return d < 0 ? d * 2 : d; // paper asymmetry weight
  });
  final th2 = _slidingThreshold(mRR, windowBeats, alpha, minThresholdMs);

  final classes = List<BeatClass>.filled(n, BeatClass.normal);
  for (var i = 0; i < n; i++) {
    final hardLong = rrMs[i] > 2000;
    final hardShort = rrMs[i] < 300;
    final bigJump = dRR[i].abs() > th1[i];
    final bigDev = mRR[i].abs() > th2[i];
    if (hardLong || (bigDev && mRR[i] > 0)) {
      // Long interval: likely a MISSED beat (interval ~ multiple of normal).
      classes[i] = (med[i] > 0 && rrMs[i] > 1.5 * med[i])
          ? BeatClass.missed
          : BeatClass.longShort;
    } else if (hardShort || (bigDev && mRR[i] < 0)) {
      // Short interval: likely an EXTRA (spurious) beat.
      classes[i] = (med[i] > 0 && rrMs[i] < 0.6 * med[i])
          ? BeatClass.extra
          : BeatClass.longShort;
    } else if (bigJump) {
      classes[i] = BeatClass.ectopic;
    }
  }

  // Compensatory-pair reconciliation. A single ectopic/extra beat shows up as
  // TWO successive dRR spikes of opposite sign (the bad beat, then the
  // recovery). If beat i was flagged ONLY by the dRR jump (ectopic) but its
  // value is physiologically normal and close to the local median, while its
  // predecessor was a short/extra or long/missed event of opposite-sign dRR,
  // then i is just the recovery — demote it to normal so the event stays a
  // single isolated artifact rather than a spurious 2-beat run.
  for (var k = 1; k < n; k++) {
    if (classes[k] != BeatClass.ectopic) continue;
    final prevBad = classes[k - 1] == BeatClass.extra ||
        classes[k - 1] == BeatClass.missed ||
        classes[k - 1] == BeatClass.ectopic ||
        classes[k - 1] == BeatClass.longShort;
    if (!prevBad) continue;
    final oppositeSign = dRR[k] * dRR[k - 1] < 0;
    final valueNormal = med[k] > 0 &&
        rrMs[k] >= 300 &&
        rrMs[k] <= 2000 &&
        (rrMs[k] - med[k]).abs() <= 0.2 * med[k];
    if (oppositeSign && valueNormal) {
      classes[k] = BeatClass.normal;
    }
  }

  // Build cleaned NN. Isolated single artifact -> cubic-spline (Catmull-Rom on
  // the 4 surrounding NORMAL beats). A run of ≥2 consecutive artifacts -> drop.
  final isArtifact = [for (final c in classes) c != BeatClass.normal];
  final nn = <double>[];
  final times = <double>[];
  var t = 0.0;
  var dropped = 0;
  var corrected = 0;
  var i = 0;
  while (i < n) {
    if (!isArtifact[i]) {
      t += rrMs[i];
      nn.add(rrMs[i]);
      times.add(t);
      i++;
      continue;
    }
    // Measure run length.
    var j = i;
    while (j < n && isArtifact[j]) {
      j++;
    }
    final runLen = j - i;
    if (runLen == 1) {
      // Isolated -> spline-correct from surrounding normals.
      final corr = _splineCorrect(rrMs, isArtifact, i);
      if (corr != null) {
        t += corr;
        nn.add(corr);
        times.add(t);
        corrected++;
      } else {
        dropped++; // no anchors -> honest drop
      }
    } else {
      dropped += runLen; // multi-beat run: NEVER interpolate
    }
    i = j;
  }

  final normalCount = classes.where((c) => c == BeatClass.normal).length;
  return RrCorrectionResult(
    nn: nn,
    nnTimesMs: times,
    classes: classes,
    cleanFraction: normalCount / n,
    droppedCount: dropped,
    correctedCount: corrected,
  );
}

/// Time-varying threshold: alpha × (QD = (Q3−Q1)/2) of |x| in a sliding window.
List<double> _slidingThreshold(
    List<double> x, int win, double alpha, double floor) {
  final n = x.length;
  final out = List<double>.filled(n, 0);
  final half = win ~/ 2;
  for (var i = 0; i < n; i++) {
    final lo = math.max(0, i - half);
    final hi = math.min(n - 1, i + half);
    final seg = <double>[];
    for (var k = lo; k <= hi; k++) {
      seg.add(x[k].abs());
    }
    final q1 = percentile(seg, 25) ?? 0;
    final q3 = percentile(seg, 75) ?? 0;
    final qd = (q3 - q1) / 2;
    // Floor keeps a gross outlier detectable even on (near-)quantized clean
    // data where the QD collapses to 0 — but the floor sits well above normal
    // beat-to-beat HRV wobble so it never flags the healthy signal.
    out[i] = math.max(alpha * qd, floor);
  }
  return out;
}

List<double> _slidingMedian(List<double> x, int win) {
  final n = x.length;
  final out = List<double>.filled(n, 0);
  final half = win ~/ 2;
  for (var i = 0; i < n; i++) {
    final lo = math.max(0, i - half);
    final hi = math.min(n - 1, i + half);
    final seg = <double>[];
    for (var k = lo; k <= hi; k++) {
      if (k == i) continue;
      seg.add(x[k]);
    }
    out[i] = median(seg) ?? x[i];
  }
  return out;
}

/// Catmull-Rom cubic interpolation at the artifact index using the nearest two
/// NORMAL beats on each side. Returns null if anchors are unavailable.
double? _splineCorrect(List<double> rr, List<bool> isArtifact, int idx) {
  final left = <double>[];
  for (var k = idx - 1; k >= 0 && left.length < 2; k--) {
    if (!isArtifact[k]) left.insert(0, rr[k]);
  }
  final right = <double>[];
  for (var k = idx + 1; k < rr.length && right.length < 2; k++) {
    if (!isArtifact[k]) right.add(rr[k]);
  }
  if (left.isEmpty || right.isEmpty) return null;
  final p1 = left.last;
  final p2 = right.first;
  final p0 = left.length >= 2 ? left.first : p1;
  final p3 = right.length >= 2 ? right.last : p2;
  // Catmull-Rom at t=0.5 between p1 and p2.
  const t = 0.5;
  final t2 = t * t;
  final t3 = t2 * t;
  final v = 0.5 *
      ((2 * p1) +
          (-p0 + p2) * t +
          (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 +
          (-p0 + 3 * p1 - 3 * p2 + p3) * t3);
  return v;
}
