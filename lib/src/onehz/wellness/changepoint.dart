// WELLNESS — change-point detection on smoothed daily aggregates.
//
// Catalog: "Change-point: PELT-MBIC weekly retro review (Killick 2012,
// min-seg ≥7 d) + BOCPD online ... on smoothed daily aggregates."
//
// Two methods:
//   1. ONLINE two-sided CUSUM (Page 1954) — running detector that standardizes
//      each point against the data BEFORE it (an expanding pre-change baseline,
//      restarted at every detection) and fires when the accumulated deviation
//      crosses a threshold. Cheap, streaming, for "something just shifted".
//   2. OFFLINE GREEDY binary segmentation with a BIC penalty on the Gaussian
//      change-in-mean cost (Killick 2012), min-segment length ≥7. This is an
//      APPROXIMATION to the exact partition, NOT PELT: Killick, Fearnhead &
//      Eckley 2012 (JASA 107(500):1590-1598) is built on exactly that contrast
//      — PELT is exact while binary segmentation "only provides an approximate
//      solution and can lead to poor estimation of the number and position of
//      changepoints", because a greedy first split is not in general the
//      optimal single split of an optimally-partitioned series. We take the
//      approximation on purpose (it is retrospective, gated by a penalty AND an
//      MDC effect-size floor); the header used to claim the two agree, which is
//      the paper's counter-example, not its result.
//
// HONESTY: change-points are reported on SMOOTHED aggregates only and gated by
// the penalty so we don't celebrate regression-to-the-mean noise. min-seg
// prevents over-segmentation.

import 'dart:math' as math;
import '../types.dart';
import '../util.dart';
import '../foundations/baseline.dart';

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

/// Two-sided CUSUM over a series, standardized against a PRE-change baseline.
///
/// [x] the (smoothed) series, oldest first. [k] slack in scale-units (reference
/// value), [h] decision threshold in scale-units. [minBaseline] points required
/// before any point can be scored.
///
/// [dates] are the `yyyy-MM-dd` labels of [x], POSITIONALLY ALIGNED. Pass them.
/// Callers feed this a COMPACTED series — only the days that produced a value —
/// so without them the pre-change window and the accumulator are positional and
/// silently span wear gaps: "10 points of baseline" becomes ten scattered days
/// over four months, and evidence accumulated before a two-month gap still fires
/// a critical-priority "your resting HR shifted" on the first day back. A CUSUM
/// is evidence accumulated over CONSECUTIVE observations; across a gap there are
/// no observations, so there is no evidence to carry. This is the same fix
/// `clinical/illness_cusum.dart` already carries, and the failure mode
/// `util.dart`'s [calendarDays] documents.
///
/// Omitting [dates] (or passing a mismatched length) keeps the old positional
/// behaviour — no caller is made worse off — but it is not the honest reading.
///
/// Each point is standardized by the robust median/MAD of the points BEFORE it,
/// back to the start of the current regime — never by the whole series. That is
/// the difference between a detector and a description: standardizing by the
/// whole series folds the post-change data into the scale, which pins |z| at
/// MAD's 1.4826 reciprocal (≈0.675) for ANY balanced two-regime series whatever
/// the step size. A 145 bpm permanent step in a 30-day window was invisible, and
/// detection depended only on how LONG the regimes were. At h = 5 with k = 0.5
/// that also meant the accumulator crept 0.1745/day and re-crossed the threshold
/// on ten separate later days, so the caller's "only when the shift lands on the
/// latest day" guard re-announced one shift as fresh over and over.
///
/// After a detection the baseline restarts at the detection index (the new
/// regime is the new normal) and [minBaseline] points must accrue again, so one
/// shift is announced once.
///
/// NO detection is emitted while a robust scale cannot be estimated — a
/// perfectly flat baseline has no dispersion to standardize against, and an
/// absent change-point beats a fabricated one.
List<CusumDetection> cusumChangePoints(
  List<double> x, {
  List<String>? dates,
  double k = 0.5,
  double h = 5.0,
  int minBaseline = 10,
}) {
  final out = <CusumDetection>[];
  if (x.length <= minBaseline) return out;
  final day =
      (dates != null && dates.length == x.length) ? calendarDays(dates) : null;
  var regimeStart = 0; // first index of the current (pre-change) regime
  var up = 0.0, dn = 0.0;
  for (var i = 0; i < x.length; i++) {
    // A break in the calendar breaks the regime AND the accumulator: the
    // pre-change window restarts here and [minBaseline] consecutive days must
    // accrue again before anything can be scored.
    if (day != null && i > 0 && day[i] - day[i - 1] > 1) {
      up = 0;
      dn = 0;
      regimeStart = i;
    }
    final baseline = x.sublist(regimeStart, i);
    if (baseline.length < minBaseline) continue;
    // ponytail: median/MAD recomputed over the expanding window each step —
    // O(n² log n), and n is a 90-day series. Make it incremental if it ever
    // runs on something longer.
    final c = median(baseline)!;
    final s = mad(baseline) ?? 0;
    if (s <= 0 || !s.isFinite) {
      // Degenerate (constant) baseline: there is no robust dispersion to
      // standardize against. Hold, don't accumulate. Deliberately NO stddev
      // fallback here (unlike illness_cusum, whose baseline window is a fixed
      // 28 calendar days of the user's OWN quiet nights): this window grows
      // until a detection, so on a flat history the SD is driven entirely by
      // the very point under test — sqrt(n)-ish z for a 0.5 bpm move — and a
      // critical-priority notification would fire on noise-free arithmetic.
      continue;
    }
    final z = (x[i] - c) / s;
    up = math.max(0, up + z - k);
    dn = math.max(0, dn - z - k);
    if (up > h || dn > h) {
      final upward = up > h;
      out.add(CusumDetection(i, upward ? 1 : -1, upward ? up : dn));
      up = 0;
      dn = 0;
      regimeStart = i; // the shifted level becomes the new baseline
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

/// Offline change-point detection by greedy binary segmentation with a BIC
/// penalty on the Gaussian change-in-mean cost.
///
/// [x] the (smoothed) daily-aggregate series. [minSeg] minimum segment length
/// (≥7 per catalog). The per-change penalty is `penaltyK · σ̂² · ln(n)` where
/// σ̂² is the variance of the full series; a split is accepted only if it
/// reduces SSE by more than the penalty.
///
/// [penaltyK] DEFAULTS TO 2.0 = BIC, and that 2 is not a taste setting. The
/// reference implementation (`changepoint::penalty_decision`) gives
/// BIC = (diffparam + 1)·log(n); for the Normal change-in-mean with known
/// variance diffparam = 1, so BIC = 2·log(n) on the STANDARDISED cost, which is
/// 2·σ̂²·ln(n) on the raw-SSE scale [_binSeg] compares against. This shipped at
/// 1.0 — exactly HALF the criterion the docstring named — so the detector split
/// more eagerly than the method it claimed to be. Use 3.0 for a flat MBIC-like
/// approximation (the real MBIC also carries Zhang & Siegmund's
/// Σ log(τᵢ − τᵢ₋₁) segment-length term, which this does not implement — so do
/// not call it MBIC).
///
/// It does NOT cancel against the σ̂² inflation the note below describes: on a
/// series containing a real shift the full-series σ̂² already over-penalises,
/// and halving the constant was not a correction for that, it was a second
/// error pointing the other way with no reason to match in size.
///
/// Returns the change-point indices (start of each new segment), segment means,
/// and segment spans.
Metric<Segmentation> segmentChangePoints(
  List<double> x, {
  int minSeg = 7,
  double penaltyK = 2.0,
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

  // EFFECT-SIZE GATE (MT-10). Statistical significance is not a finding: a
  // step the instrument cannot resolve is not a step. Each surviving boundary
  // must move the mean by at least the MDC of the segment BEFORE it — the
  // quiet regime is the only honest noise estimate, since the full series
  // contains the shift itself. No dispersion in the pre-segment ⇒ no MDC ⇒ the
  // boundary is dropped, never waved through.
  var dropped = 0;
  var changed = true;
  while (changed && cps.isNotEmpty) {
    changed = false;
    final edges = [0, ...cps, n];
    for (var i = 1; i < edges.length - 1; i++) {
      final lo = edges[i - 1], cut = edges[i], hi = edges[i + 1];
      final before = x.sublist(lo, cut);
      final step = (mean(x.sublist(cut, hi))! - mean(before)!).abs();
      final gate = mdc(robustBaseline(before, minValid: minSeg));
      if (gate == null || step < gate) {
        cps.remove(cut);
        dropped++;
        changed = true;
        break; // means around the merge moved; re-evaluate from scratch
      }
    }
  }

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
    note:
        'GREEDY binary segmentation (an approximation to the exact partition, '
        'Killick 2012) w/ BIC-penalized change-in-mean; min-seg=$minSeg; '
        'below-MDC boundaries dropped=$dropped. Run on SMOOTHED aggregates '
        'only — do not celebrate regression-to-mean. RETROSPECTIVE ONLY: no '
        'forward alerting, and a boundary is a date that can MOVE when more '
        'data arrives. The penalty is σ̂² of the FULL series, so a series '
        'containing one big real shift inflates its own penalty and the '
        'detector UNDER-SPLITS by construction — an empty result is not '
        'evidence of stability. It cannot separate infection from a training '
        'block, a heat wave, a new medication, altitude or a cycle phase.',
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
