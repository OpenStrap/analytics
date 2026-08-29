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
  /// [immobile]. `true` marks a second that shows no movement in the data we do
  /// have but whose forward sustained-inactivity window cannot be certified —
  /// either it is truncated by the end of the record (it could still resolve
  /// either way once the next samples arrive) or it spans seconds the device
  /// never measured. Such seconds are `false` in [immobile] (not claimed as
  /// rest) and are excluded from the detected sleep period.
  ///
  /// Consumers that only read [immobile] therefore degrade conservatively (an
  /// unresolved tail second reads as "not asserted immobile"), never
  /// optimistically. Empty when unknown.
  final List<bool> immobileUnknown;

  /// Per-second smoothed z-angle (deg), full length — reused downstream.
  final List<double> zAngleDeg;

  /// Duration of the detected sleep period (seconds).
  final int sptSec;

  /// Seconds per entry of [immobile] / [immobileUnknown] / [zAngleDeg] — the
  /// measured cadence of the accel stream, 1.0 for the 1 Hz substrate. The
  /// masks are per-SAMPLE, so this is what turns a mask count into seconds.
  final double cadenceSec;

  const SleepWindow({
    required this.onsetIdx,
    required this.offsetIdx,
    required this.onsetMs,
    required this.offsetMs,
    required this.immobile,
    required this.zAngleDeg,
    required this.sptSec,
    this.immobileUnknown = const <bool>[],
    this.cadenceSec = 1.0,
  });

  /// Seconds whose immobility is genuinely undecidable — an unresolved record
  /// tail, or a stretch the device never measured (see [immobileUnknown]).
  int get undecidableSec {
    var c = 0;
    for (final u in immobileUnknown) {
      if (u) c++;
    }
    return (c * cadenceSec).round();
  }

  Map<String, dynamic> toJson() => {
        'onset_idx': onsetIdx,
        'offset_idx': offsetIdx,
        if (onsetMs != null) 'onset_ms': onsetMs,
        if (offsetMs != null) 'offset_ms': offsetMs,
        'spt_sec': sptSec,
        if (undecidableSec > 0) 'undecidable_sec': undecidableSec,
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

  /// Undecidable — either the forward window is truncated by the record end, or
  /// it contains seconds the device never measured (see
  /// [SleepWindow.immobileUnknown]).
  final List<bool> immobileUnknown;

  /// Smoothed per-second z-angle (deg). NaN where [AccelSample.valid] is false:
  /// absent gravity is stored as exact (0,0,0), whose z-angle is a perfectly
  /// well-formed 0.0° that is not a measurement of anything.
  final List<double> zAngleDeg;

  /// |Δ z-angle| vs the previous second (index 0 is 0 by definition). NaN when
  /// either endpoint second is invalid — the arm may have moved across the gap
  /// and the record cannot say. Every comparison against NaN is false, so a
  /// consumer testing `deltaDeg[k] < threshold` degrades to "not still", never
  /// to "perfectly still".
  final List<double> deltaDeg;

  /// The sustained-inactivity window actually used, in seconds.
  final int sustainedSec;

  /// The angle-change threshold actually used, in degrees.
  final double thresholdDeg;

  /// Measured sampling cadence of [zAngleDeg] (seconds per sample), or NULL
  /// when the stream has no measurable cadence or is coarser than
  /// [vanHeesMaxCadenceSec]. Null means NOTHING is asserted immobile: every
  /// second is undecidable, because a 5°-between-successive-samples rule cannot
  /// see an arm that moved and came back inside one sampling gap.
  final double? cadenceSec;

  /// [sustainedSec] expressed in SAMPLES at [cadenceSec] — the length the
  /// forward-window scan actually walks. 300 at 1 Hz.
  final int sustainedSamples;

  const ImmobilityMask({
    required this.immobile,
    required this.immobileUnknown,
    required this.zAngleDeg,
    required this.deltaDeg,
    required this.sustainedSec,
    required this.thresholdDeg,
    required this.cadenceSec,
    required this.sustainedSamples,
  });
}

/// Coarsest cadence the van Hees rule is published at (seconds per sample).
///
/// van Hees 2015/2018 and GGIR specify the rule on a **5-second** rolling
/// median of the z-angle: the 5°/5-min test is a statement about how much the
/// wrist angle changes between successive 5 s values. Sampled slower than that,
/// the successive difference stops bounding the movement it is meant to bound —
/// an arm can lift and return inside one gap — and the rule over-calls rest,
/// which is the unsafe direction for a sleep window.
///
/// ponytail: hard ceiling at the published epoch, so a 15 s band gets an ABSENT
/// sleep window rather than a generous one. Raising it is one edit here plus
/// validation data at that cadence — not a judgement call.
const double vanHeesMaxCadenceSec = 5;

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
      cadenceSec: null,
      sustainedSamples: win,
    );
  }

  // Every window below (the 5 min sustained scan, the 5 s smoother) was written
  // in ARRAY POSITIONS, which is only seconds at 1 Hz. `AccelSample.tsMs`
  // already carries the clock, so measure the cadence instead of assuming one.
  final cadence =
      sampleCadenceSeconds([for (final a in accel) a.tsMs / 1000.0]);
  if (cadence == null || cadence > vanHeesMaxCadenceSec) {
    // Nothing asserted, everything undecidable — the same honest shape the
    // truncated record tail already uses, not a claim of movement either.
    return ImmobilityMask(
      immobile: List<bool>.filled(n, false),
      immobileUnknown: List<bool>.filled(n, true),
      zAngleDeg: List<double>.filled(n, double.nan),
      deltaDeg: List<double>.filled(n, double.nan),
      sustainedSec: win,
      thresholdDeg: angleThresholdDeg,
      cadenceSec: null,
      sustainedSamples: win,
    );
  }
  final winSamples = math.max(1, (win / cadence).round());
  final smoothSamples = math.max(1, (smoothSec / cadence).round());

  // 1–2. z-angle + rolling-median smoothing.
  //
  // A second whose gravity vector was never decoded ([AccelSample.valid] false)
  // is handed over as exact (0,0,0). That has a z-angle — 0.0°, constant — so a
  // run of them reads as a wrist held perfectly still, which is how a decode gap
  // became a "nap" at the confidence cap. Absence is not a measurement: those
  // seconds carry NaN from here on, and every rule below asks about them
  // explicitly instead of comparing against a number that isn't one.
  final raw = List<double>.generate(
      n,
      (i) => accel[i].valid
          ? zAngle(accel[i].x, accel[i].y, accel[i].z)
          : double.nan);
  final ang = _rollingMedian(raw, smoothSamples);

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
  //
  // A window containing an UNMEASURED second lands in the same two cases, for
  // the same reason: movement already seen decides it (the sustained rule has
  // failed on the data in hand), otherwise the arm could have moved where we
  // were not looking ⇒ undecidable, never asserted rest.
  for (var i = 0; i < n; i++) {
    final hi = math.min(n, i + winSamples);
    var maxd = 0.0;
    var gap = !accel[i].valid;
    for (var k = i + 1; k < hi; k++) {
      if (!accel[k].valid) {
        gap = true;
        break;
      }
      if (dAng[k] > maxd) {
        maxd = dAng[k];
        if (maxd >= angleThresholdDeg) break;
      }
    }
    final still = maxd < angleThresholdDeg;
    final fullWindow = hi - i >= winSamples;
    immobile[i] = still && fullWindow && !gap;
    immobileUnknown[i] = still && (!fullWindow || gap);
  }

  return ImmobilityMask(
    immobile: immobile,
    immobileUnknown: immobileUnknown,
    zAngleDeg: ang,
    deltaDeg: dAng,
    sustainedSec: win,
    thresholdDeg: angleThresholdDeg,
    cadenceSec: cadence,
    sustainedSamples: winSamples,
  );
}

/// Detect the nocturnal sleep window from a sequence of accel vectors.
///
/// [accel] gravity vectors carrying their own absolute times. The cadence is
/// MEASURED from `tsMs` ([sampleCadenceSeconds]) — there was never a `tsMs`
/// parameter, and the every-window-is-a-position assumption that stood in for
/// one only held at 1 Hz. Coarser than [vanHeesMaxCadenceSec] ⇒ absent.
/// Parameters follow GGIR defaults.
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

  // 1–3. z-angle, smoothing and the per-second sustained-inactivity rule —
  //       the shared primitive, also used by daytime nap detection.
  final mask = immobilityMask(
    accel,
    angleThresholdDeg: angleThresholdDeg,
    sustainedMin: sustainedMin,
    smoothSec: smoothSec,
  );
  final cadence = mask.cadenceSec;
  if (cadence == null) {
    return const Metric<SleepWindow>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'accel cadence not measurable, or coarser than the published '
          'van Hees epoch (see vanHeesMaxCadenceSec) — the successive-angle '
          'rule cannot bound movement inside a sampling gap',
    );
  }
  final win = mask.sustainedSamples;
  if (n < win) {
    return const Metric<SleepWindow>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'too few accel samples for a sustained-inactivity block',
    );
  }
  final ang = mask.zAngleDeg;
  final immobile = mask.immobile;
  final immobileUnknown = mask.immobileUnknown;

  // 4. longest immobile block, bridging brief gaps. Only ASSERTED immobile
  //    seconds extend a block, so a night still running when the record ends is
  //    reported up to the last second we can actually certify — the undecidable
  //    tail is left out rather than annexed on the assumption it stayed still.
  final bridge = math.max(1, ((bridgeGapMin * 60) / cadence).round());
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
  final offsetMs = hasTs ? accel[math.min(bestEnd, n - 1)].tsMs : null;

  var unresolved = 0;
  for (final u in immobileUnknown) {
    if (u) unresolved++;
  }

  // `bestLen` is a SAMPLE count; the published SPT is seconds. Identical at
  // 1 Hz, and the only place the two units were ever silently the same number.
  final sptSec = (bestLen * cadence).round();
  final undecidableSec = (unresolved * cadence).round();

  // Confidence grows with the detected SPT length up to a typical night.
  final conf = (sptSec / (7 * 3600)).clamp(0.3, 0.95);
  return Metric<SleepWindow>(
    value: SleepWindow(
      onsetIdx: bestStart,
      offsetIdx: bestEnd,
      onsetMs: onsetMs,
      offsetMs: offsetMs,
      immobile: immobile,
      immobileUnknown: immobileUnknown,
      zAngleDeg: ang,
      sptSec: sptSec,
      cadenceSec: cadence,
    ),
    confidence: conf,
    tier: Tier.high,
    inputs_used: inputs,
    note: 'van Hees angle-based REST window (5°/${sustainedMin}min); '
        'a rest period, not PSG sleep'
        '${unresolved > 0 ? '; ${undecidableSec}s are undecidable (forward window '
            'truncated by the record end, or unmeasured gravity) and are '
            'excluded' : ''}',
  );
}

/// Centered rolling median (window `w`, odd-ish), edge-clamped.
///
/// NaN in = NaN out AT THAT INDEX: an unmeasured second must not inherit an
/// angle smoothed out of its measured neighbours, or the whole point of marking
/// it absent is undone one line later. Neighbouring NaNs are simply skipped
/// when smoothing a second that WAS measured.
List<double> _rollingMedian(List<double> x, int w) {
  final n = x.length;
  if (w <= 1) return [...x];
  final half = w ~/ 2;
  final out = List<double>.filled(n, double.nan);
  for (var i = 0; i < n; i++) {
    if (x[i].isNaN) continue;
    final lo = math.max(0, i - half);
    final hi = math.min(n - 1, i + half);
    final seg = <double>[
      for (var k = lo; k <= hi; k++)
        if (!x[k].isNaN) x[k]
    ];
    out[i] = median(seg)!;
  }
  return out;
}
