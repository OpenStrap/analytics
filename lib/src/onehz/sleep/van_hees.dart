// SLEEP/CIRCADIAN TIER-1 — van Hees / GGIR angle-based sleep window.
//
// van Hees et al. 2015 (PLoS ONE) + 2018 (Sci Rep): a COUNT-FREE, heuristic
// rest-detection algorithm that sidesteps the Cole-Kripke count-calibration
// trap (catalog: invalid on 1 Hz). It works purely off the gravity orientation
// of the wrist, which a 1 Hz accel vector resolves perfectly.
//
// Algorithm (per the papers):
//   1. z-angle  = atan2(z, sqrt(x²+y²)) · 180/π   (arm elevation vs gravity)
//   2. smooth the per-second z-angle with a 5 s rolling median (robust to the
//      odd jittery sample) then take the absolute successive change.
//   3. SUSTAINED INACTIVITY: any block where the absolute z-angle change stays
//      below `angleThresholdDeg` (default 5°) for at least `sustainedMin`
//      (default 5 min) is "no movement". The original GGIR uses a 5°/5-min
//      rule; we keep those defaults.
//   4. The SLEEP PERIOD (SPT window) is the single LONGEST such block per day,
//      gap-bridged across brief (<`bridgeGapMin`) interruptions.
//
// This is THE sleep/wake spine; everything downstream (SRI, accounting, the
// autonomic stager) consumes the window + the per-second immobility mask it
// produces. Honesty: this detects a REST window, not PSG sleep — onset/offset
// are the bounds of sustained wrist inactivity.

import 'dart:math' as math;
import '../types.dart';
import '../util.dart';

/// Per-second sleep/wake spine derived from the 1 Hz accel vector.
class SleepWindow {
  /// Index (into the supplied accel array) of detected sleep onset.
  final int onsetIdx;

  /// Index of detected sleep offset (exclusive end).
  final int offsetIdx;

  /// Wall-clock onset / offset (ms), if timestamps were supplied.
  final double? onsetMs;
  final double? offsetMs;

  /// Per-second immobility mask (true = "no movement" second), full length.
  final List<bool> immobile;

  /// Per-second smoothed z-angle (deg), full length — reused downstream.
  final List<double> zAngleDeg;

  /// Duration of the detected sleep period (seconds).
  final int sptSec;

  const SleepWindow({
    required this.onsetIdx,
    required this.offsetIdx,
    required this.onsetMs,
    required this.offsetMs,
    required this.immobile,
    required this.zAngleDeg,
    required this.sptSec,
  });

  Map<String, dynamic> toJson() => {
        'onset_idx': onsetIdx,
        'offset_idx': offsetIdx,
        if (onsetMs != null) 'onset_ms': onsetMs,
        if (offsetMs != null) 'offset_ms': offsetMs,
        'spt_sec': sptSec,
      };
}

/// van Hees z-angle for one accel vector (degrees, arm elevation vs gravity).
double zAngle(double x, double y, double z) {
  final denom = math.sqrt(x * x + y * y);
  return math.atan2(z, denom) * 180 / math.pi;
}

/// Detect the nocturnal sleep window from a sequence of 1 Hz accel vectors.
///
/// [accel] one gravity vector per second (assumed ~1 Hz, contiguous). [tsMs]
/// optional matching wall-clock times. Parameters follow GGIR defaults.
Metric<SleepWindow> vanHeesSleepWindow(
  List<AccelSample> accel, {
  double angleThresholdDeg = 5,
  int sustainedMin = 5,
  // Bridge brief intra-sleep interruptions (position changes / awakenings) when
  // joining sustained-inactivity blocks into one sleep period. The published
  // van Hees/GGIR HDCZA bridges ~30–60 min; a too-small value (was 1 min)
  // fragments a real night at every reposition and keeps only the longest sliver.
  // Validated on real 1 Hz data: 1 min → 28-min sliver; 30 min → full ~6.9 h night.
  int bridgeGapMin = 30,
  int smoothSec = 5,
}) {
  const inputs = ['accel_1hz'];
  final n = accel.length;
  if (n < sustainedMin * 60) {
    return const Metric<SleepWindow>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'too few accel samples for a sustained-inactivity block',
    );
  }

  // 1–2. z-angle + 5 s rolling-median smoothing.
  final raw = List<double>.generate(
      n, (i) => zAngle(accel[i].x, accel[i].y, accel[i].z));
  final ang = _rollingMedian(raw, smoothSec);

  // 3. per-second immobility: |Δ z-angle| < threshold sustained for ≥ window.
  //    First mark seconds whose change vs the previous second is small, then
  //    require the change to STAY small across the sustained window (GGIR uses
  //    a rolling 5-min check of the absolute angle change).
  final dAng = List<double>.filled(n, 0);
  for (var i = 1; i < n; i++) {
    dAng[i] = (ang[i] - ang[i - 1]).abs();
  }
  final win = sustainedMin * 60;
  final immobile = List<bool>.filled(n, false);
  // A second is "no movement" if the MAX absolute angle change over the
  // surrounding `win` seconds stays below the threshold.
  for (var i = 0; i < n; i++) {
    final lo = i;
    final hi = math.min(n, i + win);
    if (hi - lo < win) {
      // Tail shorter than a full window: fall back to the trailing window.
      final lo2 = math.max(0, n - win);
      var maxd = 0.0;
      for (var k = lo2 + 1; k < n; k++) {
        if (dAng[k] > maxd) maxd = dAng[k];
      }
      immobile[i] = maxd < angleThresholdDeg && (n - lo2) >= win;
      continue;
    }
    var maxd = 0.0;
    for (var k = lo + 1; k < hi; k++) {
      if (dAng[k] > maxd) {
        maxd = dAng[k];
        if (maxd >= angleThresholdDeg) break;
      }
    }
    immobile[i] = maxd < angleThresholdDeg;
  }

  // 4. longest immobile block, bridging brief gaps.
  final bridge = bridgeGapMin * 60;
  var bestStart = -1, bestEnd = -1, bestLen = 0;
  var i = 0;
  while (i < n) {
    if (!immobile[i]) {
      i++;
      continue;
    }
    var j = i;
    while (j < n) {
      if (immobile[j]) {
        j++;
        continue;
      }
      // Look ahead: bridge a short active gap.
      var k = j;
      while (k < n && !immobile[k] && (k - j) < bridge) {
        k++;
      }
      if (k < n && immobile[k] && (k - j) < bridge) {
        j = k; // bridge the gap, continue the block
      } else {
        break;
      }
    }
    final len = j - i;
    if (len > bestLen) {
      bestLen = len;
      bestStart = i;
      bestEnd = j;
    }
    i = j + 1;
  }

  if (bestStart < 0 || bestLen < win) {
    return Metric<SleepWindow>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'no sustained-inactivity block ≥${sustainedMin}min found',
    );
  }

  final hasTs = accel.every((a) => a.tsMs != 0) || accel.first.tsMs != 0;
  final onsetMs = hasTs ? accel[bestStart].tsMs : null;
  final offsetMs =
      hasTs ? accel[math.min(bestEnd, n - 1)].tsMs : null;

  // Confidence grows with the detected SPT length up to a typical night.
  final conf = clamp(bestLen / (7 * 3600), 0.3, 0.95);
  return Metric<SleepWindow>(
    value: SleepWindow(
      onsetIdx: bestStart,
      offsetIdx: bestEnd,
      onsetMs: onsetMs,
      offsetMs: offsetMs,
      immobile: immobile,
      zAngleDeg: ang,
      sptSec: bestLen,
    ),
    confidence: conf,
    tier: Tier.high,
    inputs_used: inputs,
    note: 'van Hees angle-based REST window (5°/${sustainedMin}min); '
        'a rest period, not PSG sleep',
  );
}

/// Centered rolling median (window `w`, odd-ish), edge-clamped.
List<double> _rollingMedian(List<double> x, int w) {
  final n = x.length;
  if (w <= 1) return [...x];
  final half = w ~/ 2;
  final out = List<double>.filled(n, 0);
  for (var i = 0; i < n; i++) {
    final lo = math.max(0, i - half);
    final hi = math.min(n - 1, i + half);
    final seg = x.sublist(lo, hi + 1);
    out[i] = median(seg)!;
  }
  return out;
}
