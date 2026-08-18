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

  /// Beat-time (ms) for each NN interval, relative to the START of the first
  /// input beat (so `nnTimesMs.first == rrMs.first` when the first beat is
  /// kept, and adding `rrTsMs.first - rrMs.first` puts it back on the epoch).
  ///
  /// Built by cumulative-summing RR *within a contiguous run*, and RE-ANCHORED
  /// to the beat's real timestamp at every sensor dropout — see [correctRr]'s
  /// `rrTsMs`. Without `rrTsMs` it is a pure cumsum and the dropouts are
  /// spliced out; pass the timestamps.
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
///
/// [rrTsMs] the beat timestamps that came with [rrMs] (same length, sorted,
/// epoch ms). PASS THEM. Without them the output clock is Σrr, which splices
/// every sensor dropout out of the record: the intervals the band never
/// reported are not in [rrMs] at all, so no amount of book-keeping inside this
/// function can recover them. Measured on 13 real nights, the cumsum span was
/// 0.13–0.87 of the true rec_ts span, and the Lomb-Scargle spectrum built on it
/// moved LF/HF across the sympatho-vagal line (0.65 → 1.53 on one MG night).
/// With them, the clock cumsums RR *inside* a contiguous run — the RR values
/// are the only sub-second information that exists, since `rr_ts_ms` is
/// `rec_ts*1000` and therefore whole-second — and re-anchors to the real
/// timestamp whenever the wall step exceeds the interval by more than
/// [reanchorGapMs], i.e. at a dropout.
RrCorrectionResult correctRr(
  List<double> rrMs, {
  List<double>? rrTsMs,
  double alpha = 5.2,
  int windowBeats = 91,
  double minThresholdMs = 100,
  double reanchorGapMs = 1000,
}) {
  final n = rrMs.length;
  // Beat-end time for EVERY input beat, kept or not. One array, built once, so
  // every branch below reads a clock instead of advancing its own.
  final tAll = _beatTimes(rrMs, rrTsMs, reanchorGapMs);
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
    for (var i = 0; i < n; i++) {
      if (classes[i] == BeatClass.normal) {
        nn.add(rrMs[i]);
        times.add(tAll[i]);
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
  var dropped = 0;
  var corrected = 0;
  var i = 0;
  while (i < n) {
    if (!isArtifact[i]) {
      nn.add(rrMs[i]);
      times.add(tAll[i]);
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
        // The beat keeps its REAL time, not the interpolated one. `corr` is our
        // best guess at what the NN *should* have been (a missed beat splits one
        // ~2000 ms interval into two ~1000 ms ones), but the 2000 ms still
        // elapsed. Advancing by `corr` deleted ~1 s of record per corrected beat
        // — 1.6 % of a night at one missed beat in sixty.
        nn.add(corr);
        times.add(tAll[i]);
        corrected++;
      } else {
        dropped++; // no anchors -> honest drop; the clock already elapsed
      }
    } else {
      // Multi-beat run: NEVER interpolate. The clock is not touched here at all
      // — `tAll` already carries the run's elapsed time, so the two sides of a
      // dropped run are not spliced together. Not doing this compacted
      // `nnTimesMs` (299.0 s of real record emitted as a 294.0 s span) and
      // inflated everything keyed off it: cvhr_per_hour's analyzedHours, the
      // Lomb-Scargle axis, spanSec — on exactly the noisy nights that needed
      // the correction most.
      dropped += runLen;
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

/// Beat-end time (ms, relative to the start of beat 0) for every input beat.
///
/// RR intervals tile the timeline, so the clock advances for EVERY interval,
/// kept or dropped — but only for intervals the band actually REPORTED. A
/// sensor dropout is not an interval at all: it is absent from [rrMs], and
/// summing across it splices the two sides of the hole together. [rrTsMs] is
/// the only witness that the hole existed, so when the wall step between two
/// consecutive reported beats exceeds that beat's own interval by more than
/// [reanchorGapMs], the clock is RE-ANCHORED to the real timestamp instead of
/// accumulated. Inside a contiguous run the RR cumsum is kept, because
/// `rr_ts_ms = rec_ts*1000` is whole-second and the RR values are the only
/// sub-second information in the record.
///
/// The slack has to be ≥ the max plausible RR (2,400 ms saturation) minus a
/// normal beat, or ordinary quantisation would re-anchor constantly; 1,000 ms
/// is the audit's figure and is ~1 whole quantisation step.
List<double> _beatTimes(
    List<double> rrMs, List<double>? rrTsMs, double reanchorGapMs) {
  final n = rrMs.length;
  final t = List<double>.filled(n, 0);
  if (n == 0) return t;
  final wall = rrTsMs != null && rrTsMs.length == n;
  final origin = wall ? rrTsMs[0] - rrMs[0] : 0.0;
  var cur = 0.0;
  for (var i = 0; i < n; i++) {
    // The test is LOCAL — this beat's wall step against this beat's own
    // interval — so a run's accumulated cumsum-vs-wall drift never triggers it.
    //
    // That drift is real and NOT resolved here. Inside contiguous runs of ≥200
    // beats, Σrr / rec_ts-span measures 0.9631 on gen4 against 0.9988 (W5) and
    // 1.0013 (MG). Which clock is wrong is not decidable from the exports: the
    // band's `hr` field is computed from the same beat detector as `rr_ms`, so
    // it is not independent evidence, and a low rate of beats the band never
    // reports produces the same deficit with a perfectly correct clock. So
    // there is deliberately no `rrClockScale` — applying 0.963 to gen4's RR
    // values would be actively wrong under that second explanation. The
    // consequence to carry: **gen4 and gen5/MG nights are not comparable on any
    // frequency-domain or per-hour quantity** until it is resolved.
    final dropout =
        wall && i > 0 && (rrTsMs[i] - rrTsMs[i - 1]) - rrMs[i] > reanchorGapMs;
    final anchored = wall ? rrTsMs[i] - origin : 0.0;
    // `> cur` keeps the clock monotonic even if timestamps arrive out of order
    // or the cumsum has run ahead of the wall — a backwards jump is never taken.
    cur = (dropout && anchored > cur) ? anchored : cur + rrMs[i];
    t[i] = cur;
  }
  return t;
}

/// Time-varying threshold: alpha × QD of the SIGNED series x in a sliding
/// window, where QD = (Q3 − Q1)/2 (Lipponen & Tarvainen 2019, eq. for th1/th2:
/// "th = α · quartile deviation of dRR over the 91-beat window", α = 5.2).
///
/// The quartile deviation MUST be taken on the SIGNED series. Taking it on |x|
/// folds the symmetric ±dRR distribution onto one side, collapsing QD by ~an
/// order of magnitude; the threshold then sinks to [floor] and the detector
/// degenerates into a fixed 100 ms cut-off that flags ordinary RSA as ectopy.
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
      seg.add(x[k]);
    }
    final q1 = percentile(seg, 25) ?? 0;
    final q3 = percentile(seg, 75) ?? 0;
    final qd = (q3 - q1) / 2;
    // Floor keeps a gross outlier detectable on (near-)quantized clean data
    // where the QD genuinely collapses to 0 (constant RR). On any series with
    // real beat-to-beat variability α·QD dominates the floor, so the floor
    // never governs a physiological signal.
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
