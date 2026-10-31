// HR-LED FALLBACK sleep-window detector (Approach 2).
//
// The primary detector (van Hees, see segment.dart) is ACCELEROMETER-led: it
// finds sleep from sustained wrist immobility. That fails for restless sleepers,
// a loose band, or noisy/ gappy accel — exactly the "no sleep detected" nights.
//
// This fallback ignores motion and leans on the signal that is still good on
// those nights: a sustained NOCTURNAL HR DIP toward the personal resting level.
// It finds the longest run of low, valid HR (gap-aware, bridging brief arousals)
// and returns it as a CANDIDATE in-bed window. It is deliberately conservative —
// a wrong sleep window erodes trust more than a missing one — so it requires a
// real, sustained dip of meaningful duration; otherwise it returns null.
//
// HONESTY: this only proposes a WINDOW. The caller stages it via
// segmentSleep(forcedWindow: …) and surfaces the result as LOW confidence with a
// "is this right?" prompt — never as a confirmed auto detection.

import '../util.dart';
import 'advanced_stager.dart' show AdvancedSleepStager;
import 'segment.dart' show kUnfinishedNightEdgeSec;

/// A proposed in-bed window (epoch seconds). Returned by [hrLedSleepWindow].
class HrLedWindow {
  final int onsetSec;
  final int offsetSec;

  /// Threshold (bpm) the dip had to stay under, for transparency.
  final double thresholdBpm;

  const HrLedWindow(this.onsetSec, this.offsetSec, this.thresholdBpm);

  int get durationSec => offsetSec - onsetSec;
}

/// Find a sleep window from a sustained nocturnal HR dip.
///
/// [hr1hz] 1 Hz HR (bpm; 0 / non-finite = off-skin), aligned 1:1 with [tsSec]
/// (epoch seconds). [hrBaseline] optional daytime HR samples (bpm) — when given,
/// the dip threshold is anchored to the user's own waking level; otherwise it
/// falls back to the lower quartile of the night's own valid HR.
///
/// Returns the longest qualifying low-HR run (≥ [minDurationSec], brief
/// arousals < [bridgeGapSec] bridged), or null when no convincing dip exists.
///
/// [recordContinues]: the caller cut this slice out of a longer record (a
/// calendar day ending at local midnight). A dip still going at the last sample
/// has no knowable end, so it is never proposed — the same deferral
/// `segmentSleep(recordContinues: true)` applies, and for the same reason: a
/// fallback run over the slice the detector just deferred would otherwise
/// propose exactly that cut-off stretch as a finished night. Runs chained to
/// that dip are deferred with it on the same rule segmentSleep uses: under
/// 60 min apart always, up to 90 min only when the chain is overnight (some run
/// in it starts outside the daytime band, read in local time via
/// [tzOffsetResolver], default the machine's offset at that instant).
HrLedWindow? hrLedSleepWindow(
  List<double> hr1hz,
  List<int> tsSec, {
  List<double>? hrBaseline,
  int minDurationSec = 2 * 3600,
  int bridgeGapSec = 30 * 60,
  double smoothSec = 300,
  int maxSampleGapSec = 5 * 60,
  bool recordContinues = false,
  int Function(int tsSec)? tzOffsetResolver,
}) {
  final n = hr1hz.length < tsSec.length ? hr1hz.length : tsSec.length;
  if (n < minDurationSec ~/ 2) return null;

  // 1. Threshold: sleep HR sits meaningfully below the waking level. Prefer the
  //    daytime baseline (×0.90 ≈ a 10% dip); else the night's own lower quartile.
  final valid = <double>[for (var i = 0; i < n; i++) if (hr1hz[i].isFinite && hr1hz[i] > 0) hr1hz[i]];
  if (valid.length < minDurationSec ~/ 4) return null;
  double? threshold;
  if (hrBaseline != null) {
    final clean = hrBaseline.where((h) => h.isFinite && h > 0).toList();
    final med = median(clean);
    if (med != null) threshold = med * 0.90;
  }
  // No baseline: the lower-third of the window's own valid HR. This naturally
  // self-bounds — on a flat record p30 sits at the flat level, so almost nothing
  // reads "low" and we return null (no false dip). With a baseline we trust the
  // ×0.90 waking-relative threshold and do NOT second-guess it against the
  // window's own median (which is itself dragged down when the window is mostly
  // night — that would push the threshold below the dip and miss it entirely).
  threshold ??= percentile(valid, 30);
  if (threshold == null) return null;

  // 2. Smoothed HR (rolling median over ~[smoothSec] samples) so a single spike
  //    or dropout doesn't fragment the dip. Off-skin (≤0) stays off-skin.
  final win = smoothSec.round().clamp(1, n);
  final smooth = _rollingMedianValidOnly(hr1hz, win);

  // 3. "Low" mask: valid AND under threshold.
  bool low(int i) => smooth[i] > 0 && smooth[i] < threshold!;

  // 4. Longest low run, bridging brief arousals (gap-aware via real timestamps).
  final runs = <({int start, int end, int dur})>[];
  var i = 0;
  while (i < n) {
    if (!low(i)) {
      i++;
      continue;
    }
    var j = i;
    while (j < n) {
      // A HOLE IN THE RECORD ends the run. Two "low" samples three hours apart
      // are two observations, not a three-hour low-HR stretch — and the run's
      // duration below is WALL CLOCK, so without this the proposed window (the
      // one the user is shown and asked to confirm) was inflated by hours of
      // data we never had.
      if (j > i && tsSec[j] - tsSec[j - 1] > maxSampleGapSec) break;
      if (low(j)) {
        j++;
        continue;
      }
      // Look ahead: bridge a short non-low gap (arousal / brief wake) by TIME.
      var k = j;
      while (k < n &&
          !low(k) &&
          (tsSec[k] - tsSec[j]) < bridgeGapSec &&
          (k == 0 || tsSec[k] - tsSec[k - 1] <= maxSampleGapSec)) {
        k++;
      }
      // A look-ahead that stopped on a hole bridged nothing: taking k there
      // would end the run on the awake stretch just before the hole.
      if (k < n &&
          low(k) &&
          (tsSec[k] - tsSec[j]) < bridgeGapSec &&
          tsSec[k] - tsSec[k - 1] <= maxSampleGapSec) {
        j = k;
      } else {
        break;
      }
    }
    final dur = tsSec[(j - 1).clamp(0, n - 1)] - tsSec[i];
    runs.add((start: i, end: j, dur: dur));
    i = j + 1;
  }

  // 5. Defer a dip still going at the cut, and every dip chained to it the
  //    way segmentSleep chains a night (a long arousal splits tonight in two;
  //    only the trailing half touches the cut). A finished daytime sleep that
  //    ended 60-90 min before it is not part of that night and stays eligible.
  final deferred = List<bool>.filled(runs.length, false);
  if (recordContinues && runs.isNotEmpty) {
    final int Function(int tsSec) tzAt = tzOffsetResolver ??
        (int t) => DateTime.fromMillisecondsSinceEpoch(t * 1000, isUtc: false)
            .timeZoneOffset
            .inSeconds;
    bool overnightOnset(int start) {
      final local = start + tzAt(start);
      final hour = (((local % 86400) + 86400) % 86400) ~/ 3600;
      return hour < AdvancedSleepStager.daytimeBandStartHour ||
          hour >= AdvancedSleepStager.daytimeBandEndHour;
    }

    int endTs(int r) => tsSec[(runs[r].end - 1).clamp(0, n - 1)];
    // Forward pass: which earlier run each run's chain starts at.
    final chainStart = List<int>.filled(runs.length, 0);
    for (var r = 1; r < runs.length; r++) {
      final gap = tsSec[runs[r].start] - endTs(r - 1);
      final from = chainStart[r - 1];
      var chained = false;
      if (gap >= 0 && gap < 60 * 60) {
        chained = true;
      } else if (gap >= 0 &&
          gap <= AdvancedSleepStager.nightContinuationGapMin * 60) {
        chained = overnightOnset(tsSec[runs[r].start]);
        for (var q = from; !chained && q < r; q++) {
          chained = overnightOnset(tsSec[runs[q].start]);
        }
      }
      chainStart[r] = chained ? from : r;
    }
    final lastTs = tsSec[n - 1];
    final unfinishedChains = <int>{
      for (var r = 0; r < runs.length; r++)
        if (lastTs - endTs(r) <= kUnfinishedNightEdgeSec) chainStart[r],
    };
    for (var r = 0; r < runs.length; r++) {
      deferred[r] = unfinishedChains.contains(chainStart[r]);
    }
  }

  var bestStart = -1, bestEnd = -1, bestDur = 0;
  for (var r = 0; r < runs.length; r++) {
    if (deferred[r]) continue;
    if (runs[r].dur > bestDur) {
      bestDur = runs[r].dur;
      bestStart = runs[r].start;
      bestEnd = runs[r].end;
    }
  }

  if (bestStart < 0 || bestDur < minDurationSec) return null;
  final onsetSec = tsSec[bestStart];
  final offsetSec = tsSec[(bestEnd - 1).clamp(0, n - 1)] + 1;
  if (offsetSec <= onsetSec) return null;
  return HrLedWindow(onsetSec, offsetSec, threshold);
}

/// Rolling median over a centered window of [win] samples, treating ≤0 / NaN as
/// missing (they are skipped, not counted as 0). Output ≤0 marks "still missing".
List<double> _rollingMedianValidOnly(List<double> xs, int win) {
  final n = xs.length;
  final out = List<double>.filled(n, 0);
  final half = win ~/ 2;
  for (var i = 0; i < n; i++) {
    final lo = (i - half).clamp(0, n);
    final hi = (i + half + 1).clamp(0, n);
    final buf = <double>[];
    for (var k = lo; k < hi; k++) {
      if (xs[k].isFinite && xs[k] > 0) buf.add(xs[k]);
    }
    out[i] = buf.isEmpty ? 0 : (median(buf) ?? 0);
  }
  return out;
}
