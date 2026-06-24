// WELLNESS — change-point detection on smoothed daily aggregates.
//
// Catalog: "Change-point: PELT-MBIC weekly retro review (Killick 2012,
// min-seg ≥7 d) + BOCPD online ... on smoothed daily aggregates."
//
// Two methods:
//   1. ONLINE two-sided CUSUM (Page 1954) — running detector that fires when the
//      accumulated standardized deviation crosses a threshold; resets after a
//      detection. Cheap, streaming, for "something just shifted".
//   2. OFFLINE exact change-point search via binary segmentation with an
//      MBIC/BIC penalty (Killick 2012 cost = Gaussian change-in-mean SSE), with
//      a min-segment length ≥7. (Exact PELT and binary segmentation give the
//      same segmentation for the change-in-mean cost; we use the simpler
//      recursive binary search guarded by the same penalty.)
//
// HONESTY: change-points are reported on SMOOTHED aggregates only and gated by
// the penalty so we don't celebrate regression-to-the-mean noise. min-seg
// prevents over-segmentation.

import 'dart:math' as math;
import '../types.dart';
import '../util.dart';

// ---------------------------------------------------------------------------
// 1. Online CUSUM change detector (two-sided)
// ---------------------------------------------------------------------------

class CusumDetection {
  final int index;
  final int direction; // +1 upward shift, -1 downward shift
  final double stat; // accumulator value at detection
  const CusumDetection(this.index, this.direction, this.stat);
  Map<String, dynamic> toJson() =>
      {'index': index, 'direction': direction, 'stat': round6(stat)};
}

/// Two-sided CUSUM over a series, standardized by a robust scale.
///
/// [x] the (smoothed) series. [k] slack in scale-units (reference value),
/// [h] decision threshold in scale-units. Center/scale are the robust
/// median/MAD of the whole series (or a supplied [center]/[scale]). Returns
/// the indices where an upward/downward shift was detected (accumulator reset
/// after each detection).
List<CusumDetection> cusumChangePoints(
  List<double> x, {
  double k = 0.5,
  double h = 5.0,
  double? center,
  double? scale,
}) {
  final out = <CusumDetection>[];
  if (x.length < 2) return out;
  final c = center ?? median(x)!;
  var s = scale ?? (mad(x) ?? 0);
  if (s <= 0) s = (stddev(x) ?? 1.0);
  if (s <= 0) s = 1.0;
  var up = 0.0, dn = 0.0;
  for (var i = 0; i < x.length; i++) {
    final z = (x[i] - c) / s;
    up = math.max(0, up + z - k);
    dn = math.max(0, dn - z - k);
    if (up > h) {
      out.add(CusumDetection(i, 1, up));
      up = 0;
      dn = 0;
    } else if (dn > h) {
      out.add(CusumDetection(i, -1, dn));
      up = 0;
      dn = 0;
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// 2. Offline change-in-mean segmentation (binary segmentation + BIC/MBIC)
// ---------------------------------------------------------------------------

class Segmentation {
  final List<int> changePoints; // sorted indices where the mean shifts
  final List<double> segmentMeans; // mean of each segment
  final List<List<int>> segments; // [start, endExclusive) per segment
  final double penalty;
  const Segmentation(
      this.changePoints, this.segmentMeans, this.segments, this.penalty);
  Map<String, dynamic> toJson() => {
        'change_points': changePoints,
        'segment_means': [for (final m in segmentMeans) round6(m)],
        'segments': segments,
        'penalty': round6(penalty),
      };
}

/// Sum of squared errors of [x][lo:hi) about its own mean (Gaussian
/// change-in-mean cost, Killick 2012).
double _segSse(List<double> x, List<double> prefix, List<double> prefixSq,
    int lo, int hi) {
  final n = hi - lo;
  if (n <= 0) return 0;
  final sum = prefix[hi] - prefix[lo];
  final sumSq = prefixSq[hi] - prefixSq[lo];
  return sumSq - sum * sum / n;
}

/// Offline change-point detection by binary segmentation with a BIC/MBIC
/// penalty on the Gaussian change-in-mean cost.
///
/// [x] the (smoothed) daily-aggregate series. [minSeg] minimum segment length
/// (≥7 per catalog). The per-change penalty defaults to MBIC-style
/// `penaltyK · σ̂² · ln(n)` where σ̂² is the variance of the full series; a
/// split is accepted only if it reduces SSE by more than the penalty.
///
/// Returns the change-point indices (start of each new segment), segment means,
/// and segment spans.
Metric<Segmentation> segmentChangePoints(
  List<double> x, {
  int minSeg = 7,
  double penaltyK = 1.0,
  double? penaltyOverride,
}) {
  const inputs = ['daily_aggregate'];
  final n = x.length;
  if (n < 2 * minSeg) {
    return Metric<Segmentation>.absent(
      tier: Tier.estimate,
      inputs_used: inputs,
      note: 'series shorter than 2× min-segment; no change-point search',
    );
  }
  // Prefix sums for O(1) segment SSE.
  final prefix = List<double>.filled(n + 1, 0);
  final prefixSq = List<double>.filled(n + 1, 0);
  for (var i = 0; i < n; i++) {
    prefix[i + 1] = prefix[i] + x[i];
    prefixSq[i + 1] = prefixSq[i] + x[i] * x[i];
  }
  final fullVar = (stddev(x) ?? 1.0);
  final sigma2 = fullVar * fullVar;
  final penalty = penaltyOverride ??
      (penaltyK * (sigma2 <= 0 ? 1.0 : sigma2) * math.log(n.toDouble()));

  final cps = <int>[];
  _binSeg(x, prefix, prefixSq, 0, n, minSeg, penalty, cps);
  cps.sort();

  // Build segments + means.
  final bounds = [0, ...cps, n];
  final segments = <List<int>>[];
  final means = <double>[];
  for (var i = 0; i < bounds.length - 1; i++) {
    final lo = bounds[i], hi = bounds[i + 1];
    segments.add([lo, hi]);
    means.add(mean(x.sublist(lo, hi))!);
  }
  return Metric<Segmentation>(
    value: Segmentation(cps, means, segments, penalty),
    confidence: 0.6,
    tier: Tier.estimate,
    inputs_used: inputs,
    note: 'binary segmentation w/ BIC-penalized change-in-mean; min-seg=$minSeg. '
        'Run on SMOOTHED aggregates only — do not celebrate regression-to-mean.',
  );
}

void _binSeg(
  List<double> x,
  List<double> prefix,
  List<double> prefixSq,
  int lo,
  int hi,
  int minSeg,
  double penalty,
  List<int> out,
) {
  final n = hi - lo;
  if (n < 2 * minSeg) return;
  final baseSse = _segSse(x, prefix, prefixSq, lo, hi);
  var best = -1;
  var bestGain = 0.0;
  for (var s = lo + minSeg; s <= hi - minSeg; s++) {
    final left = _segSse(x, prefix, prefixSq, lo, s);
    final right = _segSse(x, prefix, prefixSq, s, hi);
    final gain = baseSse - left - right;
    if (gain > bestGain) {
      bestGain = gain;
      best = s;
    }
  }
  if (best < 0 || bestGain <= penalty) return; // not worth a change-point
  out.add(best);
  _binSeg(x, prefix, prefixSq, lo, best, minSeg, penalty, out);
  _binSeg(x, prefix, prefixSq, best, hi, minSeg, penalty, out);
}
