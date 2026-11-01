// Lipponen & Tarvainen 2019 classification with Peltola 2012 correction policy.
// The unpublished artifact-run cap is an internal rule, ESTIMATE with low
// confidence:
// over-cap runs become gaps and each side is re-corrected. Without a cap split
// the result equals uncapped correction. Shared kernel arithmetic and raw seam
// context preserve capped batch NN/classes; settled stream plus provisional tail
// equals capped batch. RrSandwich preserves source-beat absolute timestamps;
// uncapped arbitrarily long artifact runs have no exactness guarantee.
// FOUNDATION — the per-beat pieces of Lipponen–Tarvainen correction that both
// `correctRr` (whole series) and `RrCorrector` (streaming) run.
//
// One copy of the sorted window, the threshold, the leave-one-out median, the
// class decision, the compensatory-pair rule and the spline, so the batch and
// the stream cannot drift apart: the stream's contract is bit-identity with
// `correctRr`, and sharing the arithmetic is what keeps that cheap to hold.
//
// Not exported from `onehz.dart` — internal to foundations/.

import 'dart:math' as math;
import '../util.dart';
import 'rr_correction.dart' show BeatClass;

/// First index whose element is not less than [v] under `compareTo` — the same
/// total order `List<double>.sort()` uses (-0.0 < 0.0, NaN last), so a window
/// kept in this order matches the one a per-beat sort produced.
int lowerBound(List<double> a, double v) {
  var lo = 0;
  var hi = a.length;
  while (lo < hi) {
    final m = (lo + hi) >> 1;
    if (a[m].compareTo(v) < 0) {
      lo = m + 1;
    } else {
      hi = m;
    }
  }
  return lo;
}

/// An ascending multiset of doubles: O(log w) search plus a w-element memmove
/// per add / remove, instead of an O(w log w) sort per beat.
class SortedMultiset {
  /// The values, ascending. Read-only to callers.
  final List<double> a = [];

  void add(double v) => a.insert(lowerBound(a, v), v);

  /// Removes one occurrence of [v], which must be present.
  void remove(double v) => a.removeAt(lowerBound(a, v));

  void resetFrom(Iterable<double> xs) {
    a
      ..clear()
      ..addAll(xs)
      ..sort();
  }
}

/// `alpha × QD` of an ascending window, floored: QD = (Q3 − Q1)/2.
///
/// Floor keeps a gross outlier detectable on (near-)quantized clean data where
/// the QD genuinely collapses to 0 (constant RR). On any series with real
/// beat-to-beat variability α·QD dominates the floor.
double thresholdOfSorted(List<double> sorted, double alpha, double floor) {
  final q1 = percentileSorted(sorted, 25) ?? 0;
  final q3 = percentileSorted(sorted, 75) ?? 0;
  final qd = (q3 - q1) / 2;
  return math.max(alpha * qd, floor);
}

/// `median(sorted minus one occurrence of v)` — [percentile]'s linear
/// interpolation at p = 50 over the sorted list with v's slot skipped, in the
/// same operation order so the result is bit-identical. Null if nothing is left.
double? medianExcluding(List<double> sorted, double v) {
  final len = sorted.length - 1;
  if (len <= 0) return null;
  final skip = lowerBound(sorted, v);
  double at(int j) => j < skip ? sorted[j] : sorted[j + 1];
  if (len == 1) return at(0);
  final rank = (50.0 / 100) * (len - 1);
  final lo = rank.floor();
  final hi = rank.ceil();
  if (lo == hi) return at(lo);
  final frac = rank - lo;
  return at(lo) + (at(hi) - at(lo)) * frac;
}

/// The paper's asymmetric deviation from the local median: below-median
/// deviations count double.
double medianDeviation(double rr, double med) {
  final d = rr - med;
  return d < 0 ? d * 2 : d;
}

/// First-pass class of one beat from its dRR, mRR and the two thresholds.
BeatClass classifyBeat(
    double rr, double dRR, double th1, double med, double mRR, double th2) {
  final hardLong = rr > 2000;
  final hardShort = rr < 300;
  final bigJump = dRR.abs() > th1;
  final bigDev = mRR.abs() > th2;
  if (hardLong || (bigDev && mRR > 0)) {
    // Long interval: likely a MISSED beat (interval ~ multiple of normal).
    return (med > 0 && rr > 1.5 * med) ? BeatClass.missed : BeatClass.longShort;
  } else if (hardShort || (bigDev && mRR < 0)) {
    // Short interval: likely an EXTRA (spurious) beat.
    return (med > 0 && rr < 0.6 * med) ? BeatClass.extra : BeatClass.longShort;
  } else if (bigJump) {
    return BeatClass.ectopic;
  }
  return BeatClass.normal;
}

/// Compensatory-pair rule: beat k was flagged ONLY by its dRR jump, the beat
/// before it was an artifact, the two dRR spikes have opposite sign and k's own
/// value is normal and close to the local median — k is just the recovery from
/// the previous beat's event, so it is demoted to normal.
bool isRecoveryBeat({
  required bool prevIsArtifact,
  required double rr,
  required double dRR,
  required double dRRPrev,
  required double med,
}) {
  if (!prevIsArtifact) return false;
  final oppositeSign = dRR * dRRPrev < 0;
  final valueNormal =
      med > 0 && rr >= 300 && rr <= 2000 && (rr - med).abs() <= 0.2 * med;
  return oppositeSign && valueNormal;
}

/// Catmull-Rom at t = 0.5 between the nearest NORMAL beats either side of an
/// isolated artifact. [left] / [right] hold up to two values each, nearest to
/// the artifact LAST in [left] and FIRST in [right]. Null without an anchor on
/// both sides.
double? splineMid(List<double> left, List<double> right) {
  if (left.isEmpty || right.isEmpty) return null;
  final p1 = left.last;
  final p2 = right.first;
  final p0 = left.length >= 2 ? left.first : p1;
  final p3 = right.length >= 2 ? right.last : p2;
  const t = 0.5;
  final t2 = t * t;
  final t3 = t2 * t;
  return 0.5 *
      ((2 * p1) +
          (-p0 + p2) * t +
          (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 +
          (-p0 + 3 * p1 - 3 * p2 + p3) * t3);
}

/// Internal bounded-window evaluator shared by the capped batch and stream.
/// [from] has its complete left window in [rr], or is the segment's first beat.
/// Only classes at and after [from] are evaluated; the preceding class and
/// normal anchors are carried explicitly, so truncating old context cannot
/// change recovery or spline decisions.
class RrCapWindow {
  final List<BeatClass> classes;
  final List<double?> values;
  final List<double> times;
  final List<bool> gaps;
  final List<bool> hardGaps;
  RrCapWindow._(int n)
      : classes = List.filled(n, BeatClass.normal),
        values = List.filled(n, null),
        times = List.filled(n, 0),
        gaps = List.filled(n, false),
        hardGaps = List.filled(n, false);

  static RrCapWindow evaluate(
    List<double> rr, {
    List<double>? ts,
    required int cap,
    double alpha = 5.2,
    int windowBeats = 91,
    double minThresholdMs = 100,
    double reanchorGapMs = 1000,
    int from = 0,
    BeatClass previous = BeatClass.normal,
    List<double> leftNormals = const [],
    bool leadingGap = false,
    bool leadingHardGap = false,
    int segmentStart = 0,
    double clock = 0,
    double? origin,
  }) {
    final out = RrCapWindow._(rr.length);
    if (rr.isEmpty) return out;
    final wall = ts != null && ts.length == rr.length;
    final base = origin ?? (wall ? ts[0] - rr[0] : 0.0);
    final h = windowBeats ~/ 2;

    List<BeatClass> classify(int a, int b, int start, BeatClass prev) {
      final n = b - a;
      if (n < 3) {
        return [
          for (var i = start; i < b; i++)
            rr[i] >= 300 && rr[i] <= 2000
                ? BeatClass.normal
                : BeatClass.longShort
        ];
      }
      final med = List<double>.filled(n, 0);
      final mrr = List<double>.filled(n, 0);
      final th1 = List<double>.filled(n, 0);
      final wd = SortedMultiset(), wr = SortedMultiset();
      var lo = a, hi = a;
      double d(int i) => i == a ? 0 : rr[i] - rr[i - 1];
      for (var i = a; i < b; i++) {
        final nextLo = math.max(a, i - h), nextHi = math.min(b, i + h + 1);
        while (hi < nextHi) {
          wd.add(d(hi));
          wr.add(rr[hi++]);
        }
        while (lo < nextLo) {
          wd.remove(d(lo));
          wr.remove(rr[lo++]);
        }
        med[i - a] = medianExcluding(wr.a, rr[i]) ?? rr[i];
        mrr[i - a] = medianDeviation(rr[i], med[i - a]);
        th1[i - a] = thresholdOfSorted(wd.a, alpha, minThresholdMs);
      }
      final wm = SortedMultiset();
      lo = a;
      hi = a;
      final cl = <BeatClass>[];
      for (var i = start; i < b; i++) {
        final nextLo = math.max(a, i - h), nextHi = math.min(b, i + h + 1);
        if (i == start) lo = nextLo;
        if (i == start) hi = nextLo;
        while (hi < nextHi) wm.add(mrr[hi++ - a]);
        while (lo < nextLo) wm.remove(mrr[lo++ - a]);
        var c = classifyBeat(rr[i], d(i), th1[i - a], med[i - a], mrr[i - a],
            thresholdOfSorted(wm.a, alpha, minThresholdMs));
        if (i > a &&
            c == BeatClass.ectopic &&
            isRecoveryBeat(
                prevIsArtifact: prev != BeatClass.normal,
                rr: rr[i],
                dRR: d(i),
                dRRPrev: d(i - 1),
                med: med[i - a])) {
          c = BeatClass.normal;
        }
        cl.add(c);
        prev = c;
      }
      return cl;
    }

    // A stack avoids recursion depth proportional to the number of gaps.
    final pending = <(int, int, int, BeatClass, List<double>, bool, bool)>[
      (
        segmentStart,
        rr.length,
        from,
        previous,
        leftNormals,
        leadingGap,
        leadingHardGap
      )
    ];
    while (pending.isNotEmpty) {
      final (a, b, start, prev, anchors, inGap, hardLeading) =
          pending.removeLast();
      if (start >= b) continue;
      if (inGap && hardLeading && rr[start] >= 300 && rr[start] <= 2000) {
        pending
            .add((start, b, start, BeatClass.normal, const [], false, false));
        continue;
      }
      var hardCut = false;
      var cutA = -1, cutB = -1;
      // Physiologically impossible intervals are artifacts independently of
      // every dispersion window. Cut these first: otherwise their medians can
      // absorb valid beats on either side into the detected run itself.
      for (var i = start; i < b;) {
        if (rr[i] >= 300 && rr[i] <= 2000) {
          i++;
          continue;
        }
        var j = i + 1;
        while (j < b && (rr[j] < 300 || rr[j] > 2000)) {
          j++;
        }
        if (j - i > cap || (inGap && i == start)) {
          cutA = i;
          cutB = j;
          hardCut = true;
          break;
        }
        i = j;
      }
      final cl = cutA >= 0 ? <BeatClass>[] : classify(a, b, start, prev);
      if (cutA < 0 && inGap && cl.first == BeatClass.normal) {
        pending
            .add((start, b, start, BeatClass.normal, const [], false, false));
        continue;
      }
      if (cutA < 0) {
        for (var i = start; i < b;) {
          if (cl[i - start] == BeatClass.normal) {
            i++;
            continue;
          }
          var j = i + 1;
          while (j < b && cl[j - start] != BeatClass.normal) {
            j++;
          }
          if (j - i > cap || (inGap && i == start)) {
            cutA = i;
            cutB = j;
            break;
          }
          i = j;
        }
      }
      if (cutA >= 0) {
        for (var i = cutA; i < cutB; i++) {
          out.classes[i] = BeatClass.longShort;
          out.gaps[i] = true;
          out.hardGaps[i] = hardCut || (inGap && hardLeading && cutA == start);
        }
        // Cut BEFORE classifying either side, including their dispersion
        // windows. The gap's labels are canonical, never provisional medians.
        pending.add((cutB, b, cutB, BeatClass.normal, const [], false, false));
        pending.add((a, cutA, start, prev, anchors, inGap, hardLeading));
        continue;
      }
      for (var i = start; i < b; i++) {
        out.classes[i] = cl[i - start];
      }
      final normals = List<double>.of(anchors);
      for (var i = start; i < b;) {
        if (out.classes[i] == BeatClass.normal) {
          out.values[i] = rr[i];
          normals.add(rr[i]);
          if (normals.length > 2) normals.removeAt(0);
          i++;
          continue;
        }
        var j = i + 1;
        while (j < b && out.classes[j] != BeatClass.normal) {
          j++;
        }
        if (j == i + 1) {
          final right = <double>[];
          for (var k = j; k < b && right.length < 2; k++) {
            if (out.classes[k] == BeatClass.normal) right.add(rr[k]);
          }
          out.values[i] = splineMid(normals, right);
        }
        i = j;
      }
    }
    var cur = clock;
    var gap = leadingGap;
    for (var i = from; i < rr.length; i++) {
      final reset = gap && !out.gaps[i];
      final dropout =
          wall && i > 0 && ts[i] - ts[i - 1] - rr[i] > reanchorGapMs;
      final anchored = wall ? ts[i] - base : 0.0;
      cur = wall && reset
          ? anchored
          : dropout && anchored > cur
              ? anchored
              : cur + rr[i];
      out.times[i] = cur;
      gap = out.gaps[i];
    }
    return out;
  }
}
