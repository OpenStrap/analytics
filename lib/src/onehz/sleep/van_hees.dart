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

  /// Per-second immobility mask (true = ASSERTED "no movement" second), full
  /// length. `false` means "not asserted immobile" — which is either a real
  /// movement OR an UNDECIDABLE second (see [immobileUnknown]). It is never a
  /// guess: the van Hees rule needs `sustainedMin` of FUTURE angle data, and the
  /// last `sustainedMin` of any record does not have it.
  final List<bool> immobile;

  /// Per-second "undecidable" mask, full length and index-aligned with
  /// [immobile]. `true` marks a second whose forward sustained-inactivity
  /// window is truncated by the end of the record AND which shows no movement
  /// in the data we do have — i.e. it could still resolve either way once the
  /// next samples arrive. Such seconds are `false` in [immobile] (not claimed
  /// as rest) and are excluded from the detected sleep period.
  ///
  /// Consumers that only read [immobile] therefore degrade conservatively (an
  /// unresolved tail second reads as "not asserted immobile"), never
  /// optimistically. Empty when unknown.
  final List<bool> immobileUnknown;

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
    this.immobileUnknown = const <bool>[],
  });

  /// Seconds at the end of the record whose immobility is genuinely
  /// undecidable (see [immobileUnknown]).
  int get unresolvedTailSec {
    var c = 0;
    for (final u in immobileUnknown) {
      if (u) c++;
    }
    return c;
  }

  Map<String, dynamic> toJson() => {
        'onset_idx': onsetIdx,
        'offset_idx': offsetIdx,
        if (onsetMs != null) 'onset_ms': onsetMs,
        if (offsetMs != null) 'offset_ms': offsetMs,
        'spt_sec': sptSec,
        if (unresolvedTailSec > 0) 'unresolved_tail_sec': unresolvedTailSec,
      };
}

/// van Hees z-angle for one accel vector (degrees, arm elevation vs gravity).
double zAngle(double x, double y, double z) {
  final denom = math.sqrt(x * x + y * y);
  return math.atan2(z, denom) * 180 / math.pi;
}

/// Per-second immobility evidence from the 1 Hz gravity vector — steps 1–3 of
/// the van Hees rule, with no window SELECTION applied.
///
/// Extracted so the nocturnal window ([vanHeesSleepWindow], which takes the
/// single longest block) and daytime naps (`sleep/nap.dart`, which enumerates
/// every block) run the SAME immobility primitive rather than two lookalike
/// copies. Being an ANGLE, this is orientation-invariant: it does not inherit
/// the ~13% spread in |accel| across static wrist postures that makes a
/// magnitude-based stillness test false-positive on a resting arm.
class ImmobilityMask {
  /// ASSERTED immobile (see [SleepWindow.immobile]).
  final List<bool> immobile;

  /// Undecidable — forward window truncated by the record end (see
  /// [SleepWindow.immobileUnknown]).
  final List<bool> immobileUnknown;

  /// Smoothed per-second z-angle (deg).
  final List<double> zAngleDeg;

  /// |Δ z-angle| vs the previous second (index 0 is 0 by definition).
  final List<double> deltaDeg;

  /// The sustained-inactivity window actually used, in seconds.
  final int sustainedSec;

  /// The angle-change threshold actually used, in degrees.
  final double thresholdDeg;

  const ImmobilityMask({
    required this.immobile,
    required this.immobileUnknown,
    required this.zAngleDeg,
    required this.deltaDeg,
    required this.sustainedSec,
    required this.thresholdDeg,
  });
}

/// Compute [ImmobilityMask] for a 1 Hz accel series. Safe on any length —
/// a series shorter than the sustained window yields an all-undecidable mask
/// rather than an assertion of rest.
ImmobilityMask immobilityMask(
  List<AccelSample> accel, {
  double angleThresholdDeg = 5,
  int sustainedMin = 5,
  int smoothSec = 5,
}) {
  final n = accel.length;
  final win = sustainedMin * 60;
  if (n == 0) {
    return ImmobilityMask(
      immobile: const <bool>[],
      immobileUnknown: const <bool>[],
      zAngleDeg: const <double>[],
      deltaDeg: const <double>[],
      sustainedSec: win,
      thresholdDeg: angleThresholdDeg,
    );
  }

  // 1–2. z-angle + rolling-median smoothing.
  final raw = List<double>.generate(
      n, (i) => zAngle(accel[i].x, accel[i].y, accel[i].z));
  final ang = _rollingMedian(raw, smoothSec);

  // 3. per-second immobility: |Δ z-angle| < threshold sustained for ≥ window.
  final dAng = List<double>.filled(n, 0);
  for (var i = 1; i < n; i++) {
    dAng[i] = (ang[i] - ang[i - 1]).abs();
  }
  final immobile = List<bool>.filled(n, false);
  final immobileUnknown = List<bool>.filled(n, false);
  // A second is "no movement" if the MAX absolute angle change over the `win`
  // seconds STARTING AT IT stays below the threshold (van Hees 2015/2018: the
  // sustained-inactivity rule is a property of the block that follows the
  // second, so it is evaluated PER SECOND on that second's own window).
  //
  // The final `win-1` seconds have a TRUNCATED forward window, which splits
  // them into two honest cases — never into one shared verdict (pre-2026-07 the
  // tail took a single global `[n-win, n)` answer and stamped it on every tail
  // second, so one twitch anywhere in the last 5 min flipped the whole tail to
  // mobile, and stillness observed BEFORE a tail second was used to certify a
  // full sustained window that second never actually had):
  //   * movement seen in [i, n)  → the ≥sustainedMin rule already FAILS on the
  //     data in hand, whatever comes next ⇒ decided, not immobile.
  //   * no movement seen, window short ⇒ UNDECIDABLE. We do not assert rest
  //     (that would extrapolate stillness past the end of the record) and we
  //     record it in `immobileUnknown` rather than guessing either way.
  for (var i = 0; i < n; i++) {
    final hi = math.min(n, i + win);
    var maxd = 0.0;
    for (var k = i + 1; k < hi; k++) {
      if (dAng[k] > maxd) {
        maxd = dAng[k];
        if (maxd >= angleThresholdDeg) break;
      }
    }
    final still = maxd < angleThresholdDeg;
    final fullWindow = hi - i >= win;
    immobile[i] = still && fullWindow;
    immobileUnknown[i] = still && !fullWindow;
  }

  return ImmobilityMask(
    immobile: immobile,
    immobileUnknown: immobileUnknown,
    zAngleDeg: ang,
    deltaDeg: dAng,
    sustainedSec: win,
    thresholdDeg: angleThresholdDeg,
  );
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

  // 1–3. z-angle, smoothing and the per-second sustained-inactivity rule —
  //       the shared primitive, also used by daytime nap detection.
  final mask = immobilityMask(
    accel,
    angleThresholdDeg: angleThresholdDeg,
    sustainedMin: sustainedMin,
    smoothSec: smoothSec,
  );
  final ang = mask.zAngleDeg;
  final win = mask.sustainedSec;
  final immobile = mask.immobile;
  final immobileUnknown = mask.immobileUnknown;

  // 4. longest immobile block, bridging brief gaps. Only ASSERTED immobile
  //    seconds extend a block, so a night still running when the record ends is
  //    reported up to the last second we can actually certify — the undecidable
  //    tail is left out rather than annexed on the assumption it stayed still.
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

  var unresolved = 0;
  for (final u in immobileUnknown) {
    if (u) unresolved++;
  }

  // Confidence grows with the detected SPT length up to a typical night.
  final conf = clamp(bestLen / (7 * 3600), 0.3, 0.95);
  return Metric<SleepWindow>(
    value: SleepWindow(
      onsetIdx: bestStart,
      offsetIdx: bestEnd,
      onsetMs: onsetMs,
      offsetMs: offsetMs,
      immobile: immobile,
      immobileUnknown: immobileUnknown,
      zAngleDeg: ang,
      sptSec: bestLen,
    ),
    confidence: conf,
    tier: Tier.high,
    inputs_used: inputs,
    note: 'van Hees angle-based REST window (5°/${sustainedMin}min); '
        'a rest period, not PSG sleep'
        '${unresolved > 0 ? '; last ${unresolved}s of the record are '
            'undecidable (forward window truncated) and are excluded' : ''}',
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
