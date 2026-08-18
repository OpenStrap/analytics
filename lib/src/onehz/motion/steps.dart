// MOTION — a real pedometer on one stream, movement volume on the other.
//
// The honest constraint (see motion.dart §"what 1 Hz accel CANNOT do"):
//   * The always-on 24/7 substrate is 1 Hz accel. Human gait is 1.4–2.5 Hz, far
//     above the 0.5 Hz Nyquist limit of a 1 Hz stream — so you CANNOT count
//     individual steps from the stored substrate. Full stop. And even at full
//     rate a WRIST ranks arm work above walking, so amplitude alone cannot
//     isolate gait from cooking or driving.
//   * Real per-step detection is only possible on the ~100 Hz foreground accel
//     (R10 / 0x2B), which exists only while the app is connected and streaming.
//
// So we split the problem the only honest way:
//
//   TIER A — [pedometer] / [livePedometer]: a real step counter on the 100 Hz
//     foreground stream, ported from the OpenStrap backend
//     (openstrap-analytics/src/steps.ts). See [StepParams] for what it actually
//     is and is not — it is NOT AN-2554 verbatim, and the ×1.11 "calibration"
//     it used to carry was measured to be a fabricated +10.6%. Its CONFIRM=8
//     regularity gate rejects IRREGULAR handling and reads 0 at rest; it does
//     NOT reject rhythmic arm work (measured: a steady 1.8 Hz stir over 300 s
//     of no locomotion counts 538 steps at 108 spm). Directly testable: walk N
//     steps with the app open and compare.
//
//   TIER B — [dailyActiveMinutes]: a 24/7 MOVEMENT-VOLUME index from the 1 Hz
//     substrate. It reports MINUTES OF SUSTAINED WRIST MOVEMENT and NOTHING
//     ELSE. It emits no step count and no cadence, because at 1 Hz gait is
//     unidentifiable (aliasing) AND wrist amplitude ranks arm work above
//     walking, so a movement threshold cannot isolate ambulation in principle.
//     A previous version multiplied these minutes by a cadence band; it was
//     measured over-reporting ~6× on a real day and has been removed. Steps
//     come only from a gait-capable source (Tier A, or the phone pedometer).
//
//     Two things make the minute detector stable, and both matter:
//       1. The feature is [MotionMinute.dynAmp] — per-axis high-passed dynamic
//          amplitude — NOT ENMO. ENMO is not empty on this substrate (audit
//          MOT-07 re-measured it: Spearman(ENMO, HR) = 0.244 vs
//          Spearman(dynAmp, HR) = 0.689 over 11,205 covered gen4 minutes), it
//          is CALIBRATION-FRAGILE: it is `‖a‖ − gRef` and the per-family gRef
//          (1.0277 gen4 / 1.0014 MG / 0.9977 W5) is the same order as the
//          movement it is supposed to measure. dynAmp removes gravity as a
//          VECTOR and measures how fast the wrist re-orients, so no reference
//          has to be right. (Vähä-Ypyä 2015 argues for calibration-robust
//          amplitude measures over ENMO for exactly this reason.)
//       2. The cut-point is a MULTI-DAY PERSONAL REFERENCE
//          ([personalDynFloorFromDailySummaries]) that is FROZEN after an
//          enrollment window — neither an absolute g constant
//          (calibration-fragile) nor anything recomputed daily. A threshold
//          recomputed from the signal it thresholds cancels the trend it
//          exists to report: measured, 37 active minutes at 1×, 1.5×, 2× AND
//          3× activity, versus 23 → 254 with a frozen floor.
//
//     There is deliberately NO upper ceiling and NO HR gate. Both existed and
//     both were measured against real substrate: the ceiling rejected zero
//     minutes across every day tested, and the HR gate changed the answer by
//     zero minutes while sitting at ~6% of heart-rate reserve. See the
//     comments at their former sites in [dailyActiveMinutes] before
//     reintroducing either.
//
//     With no personal reference the estimator ABSTAINS (absent Metric with a
//     `need_baseline:` note). It never substitutes a constant — substituting a
//     constant IS the failure mode this design exists to prevent.
//
//   CALIBRATION — [StepCalibration] / [calibrateCadence]: measures THIS user's
//     real walking cadence from the 100 Hz stream. That number is reportable on
//     its own. It is deliberately NOT consumed by Tier B: multiplying movement
//     minutes by a walking cadence produces a number about nothing, because the
//     minutes are not specifically ambulation.
//
// Pure: dart:math only. No I/O, no clock, no randomness.

import 'dart:math' as math;
import '../types.dart';
import '../util.dart';
import 'enmo.dart' show MotionMinute;

// ───────────────────────────── TIER A: live 100 Hz pedometer ────────────────

/// Result of [livePedometer] over one foreground accel buffer.
class PedometerResult {
  final int steps;
  final double durationS; // span the buffer covered (s)
  final double cadenceSpm; // steps / minute over the active span (0 if none)
  final double peakToPeakG; // median stride amplitude (g) — motion strength
  final double confidence; // 0..1 (amplitude + rhythm regularity)
  const PedometerResult(
    this.steps,
    this.durationS,
    this.cadenceSpm,
    this.peakToPeakG,
    this.confidence,
  );

  static const PedometerResult none =
      PedometerResult(0, 0, 0, 0, 0);

  Map<String, dynamic> toJson() => {
        'steps': steps,
        'duration_s': round6(durationS),
        'cadence_spm': round6(cadenceSpm),
        'p2p_g': round6(peakToPeakG),
        'confidence': round6(confidence),
      };
}

/// WHAT THIS ALGORITHM ACTUALLY IS — the citation, corrected.
///
/// It is NOT AN-2554, despite what this file said for a long time. It is:
///
///   * AN-2554's *structure* — centred-window max/min peak search judged
///     against a dynamic threshold that is refreshed from recent (max+min)/2 —
///     but on Euclidean magnitude √(x²+y²+z²), where AN-2554 uses the sum of
///     absolutes, and retuned for 100 Hz where AN-2554 is specified at 50 Hz;
///   * plus Zhao's ADXL345 Analog Dialogue pedometer's confirm/"regulation"
///     mechanic ([confirm] consecutive valid pairs before anything is credited,
///     then free-running until the run breaks) — also a 50 Hz design;
///   * plus [sens] and [confirm], which appear in NEITHER source. They are
///     ours. Do not defend them by citation.
///
/// What IS taken straight from AN-2554 is the pair of physiological step-
/// interval bounds ([minStepIntervalS] / [maxStepIntervalS]) — max ~5 steps/s
/// running, min ~0.5 steps/s very slow walking. Those were missing from this
/// port until they were added back.
///
/// Neither ancestor is validated evidence: AN-2554's "~97% on a wrist" is a
/// vendor figure on an unpublished protocol, and Zhao's note has no validation
/// at all. Every independent free-living wrist evaluation puts peak detection
/// between 60% and 230% error. Treat this as a counter that is accurate on the
/// walking it supervises, not as an all-day step source.
class StepParams {
  /// Default assembled IMU sample rate (Hz). No longer decorative: it is the
  /// default for [pedometer]'s `sampleRateHz`, which the interval bounds below
  /// are converted through. Every other constant here is in SAMPLES.
  static const double fs = 100;
  static const int filter = 8; // low-pass moving-average taps
  static const int window = 33; // centered peak window (~0.33 s @100 Hz)
  static const double sens = 0.10; // g — dead-zone around the dynamic threshold
  static const int thrOrder = 4; // dynamic-threshold smoothing buffer
  static const int confirm = 8; // consecutive possible steps before counting
  static const int maxMinTimeout = 120; // samples to find a min after a max

  /// AN-2554's step-interval window: a human runs at most ~5 steps/s and walks
  /// at slowest ~0.5 steps/s, so a peak-to-peak interval outside 0.2–2.0 s is
  /// not gait and breaks the run. Distinct from [maxMinTimeout], which bounds
  /// the max→min HALF cycle, not the interval between steps.
  static const double minStepIntervalS = 0.2;
  static const double maxStepIntervalS = 2.0;

  /// Per-user calibration trim. **Default 1.00, and it must stay 1.00 as a
  /// default** — a population fudge factor is not a calibration.
  ///
  /// This was 1.11 and it was shipping a measured +10.6% over-count. The
  /// docstring claimed "raw 90 → ~100 ground truth"; on clean synthetic gait
  /// the raw count is exact — raw/truth 1.00 at 60, 80, 100, 120, 140 and
  /// 180 spm. The 90→100 figure is only reproducible at ~0.050 g peak
  /// amplitude, on the [sens] dead-zone cliff where a 100-step walk counts
  /// 0 → 56 → 98 → 100 across 0.048–0.055 g: n=1, at the least reproducible
  /// operating point in the parameter space.
  ///
  /// The real systematic deficit on a still→walk→still bout is a FLAT −0.9%,
  /// identical from a 20-step bout to a 10,000-step one. Flat means it is
  /// neither a gain error (which would scale) nor an offset (which would
  /// shrink): it is per-minute CHUNK-BOUNDARY loss inside [calcSteps], which
  /// restarts the state machine every minute and pays [confirm] again. Fixing
  /// that means changing how [calcSteps] segments minutes; it is 0.9% and it is
  /// deliberately not chased. Do not re-derive a gain from it.
  ///
  /// A real strap on a real wrist may still need trimming — that is what this
  /// knob is for. Measure it against ground truth, per user, and store it with
  /// the user; never bake a population constant back in here.
  static const double gain = 1.00;
}

/// Time-domain step count over ONE contiguous accelerometer-MAGNITUDE signal
/// (g, gravity INCLUDED). Raw count — no calibration gain. See [StepParams] for
/// what this algorithm is (it is not AN-2554 verbatim).
///
///   low-pass (trailing MA) → centered-window max/min extrema → dynamic
///   threshold ± [StepParams.sens]/2 dead-zone → step-interval bounds
///   ([StepParams.minStepIntervalS]…[StepParams.maxStepIntervalS]) →
///   [StepParams.confirm] consecutive "possible steps" before counting (the
///   regularity gate — it rejects IRREGULAR handling and reads 0 at rest, but
///   it does NOT reject rhythmic arm work).
///
/// [sampleRateHz] is the rate of THIS buffer. It is used only to convert the
/// step-interval bounds into samples — every other constant is in samples and
/// the peak window is wide enough that 50–200 Hz all count correctly (measured;
/// 25 Hz collapses to 0.29 of truth at 110 spm and no bound saves that).
int pedometer(List<double> sig, {double sampleRateHz = StepParams.fs}) {
  final n = sig.length;
  if (n < StepParams.window || sampleRateHz <= 0) return 0;
  // Step-interval bounds in SAMPLES, from the buffer's real rate.
  final minGap = StepParams.minStepIntervalS * sampleRateHz;
  final maxGap = StepParams.maxStepIntervalS * sampleRateHz;
  const filter = StepParams.filter;
  // low-pass: trailing moving average
  final lp = List<double>.filled(n, 0);
  var acc = 0.0;
  for (var i = 0; i < n; i++) {
    acc += sig[i];
    if (i >= filter) acc -= sig[i - filter];
    lp[i] = acc / math.min(i + 1, filter);
  }
  final half = StepParams.window >> 1;
  // centered-window extrema candidates
  final candI = <int>[];
  final candMax = <bool>[];
  final candV = <double>[];
  for (var i = half; i < n - half; i++) {
    var isMax = true, isMin = true;
    final v = lp[i];
    for (var j = i - half; j <= i + half; j++) {
      if (lp[j] > v) isMax = false;
      if (lp[j] < v) isMin = false;
      if (!isMax && !isMin) break;
    }
    if (isMax) {
      candI.add(i);
      candMax.add(true);
      candV.add(v);
    } else if (isMin) {
      candI.add(i);
      candMax.add(false);
      candV.add(v);
    }
  }
  // dynamic threshold + CONFIRM-step regularity
  final dyn = <double>[];
  var dynVal = 0.0;
  for (final v in sig) {
    dynVal += v;
  }
  dynVal /= n;
  var steps = 0, poss = 0;
  var regulation = false;
  var stateMax = true; // 'max' → looking for a max; else looking for a min
  var curMax = 0.0;
  var curMaxIdx = -1;
  var lastStepIdx = -1; // peak index of the last credited pair (interval anchor)
  for (var k = 0; k < candI.length; k++) {
    final ci = candI[k], cMax = candMax[k], cv = candV[k];
    if (stateMax) {
      if (cMax) {
        curMax = cv;
        curMaxIdx = ci;
        stateMax = false;
      }
    } else {
      if (cMax) {
        if (cv > curMax) {
          curMax = cv;
          curMaxIdx = ci;
        }
        continue;
      }
      if (ci - curMaxIdx > StepParams.maxMinTimeout) {
        stateMax = true;
        poss = 0;
        regulation = false;
        lastStepIdx = -1;
        continue;
      }
      final mx = curMax, mn = cv;
      if (mx > dynVal + StepParams.sens / 2 && mn < dynVal - StepParams.sens / 2) {
        // Step-interval bound (AN-2554). The interval between two steps is the
        // gap between their peaks; outside 0.2–2.0 s no human produced both, so
        // this pair cannot CONTINUE the run — it can only start a new one.
        // Without it the counter tracks 250, 300 and 320 spm at raw/truth 1.00
        // and only loses lock near 350 spm, by accident of the peak window's
        // width. Checked here rather than above the amplitude test so a noise
        // pair can never move the anchor.
        final gap = lastStepIdx < 0 ? null : curMaxIdx - lastStepIdx;
        lastStepIdx = curMaxIdx;
        if (gap != null && (gap < minGap || gap > maxGap)) {
          poss = 0;
          regulation = false;
          stateMax = true;
          continue;
        }
        if (mx - mn > StepParams.sens) {
          dyn.add((mx + mn) / 2);
          if (dyn.length > StepParams.thrOrder) dyn.removeAt(0);
          var s = 0.0;
          for (final v in dyn) {
            s += v;
          }
          dynVal = s / dyn.length;
        }
        poss++;
        if (regulation) {
          steps++;
        } else if (poss >= StepParams.confirm) {
          steps += poss;
          regulation = true;
        }
      } else {
        poss = 0;
        regulation = false;
      }
      stateMax = true;
    }
  }
  return steps;
}

/// Daily total: [pedometer] over each per-minute contiguous magnitude signal,
/// summed and scaled by [StepParams.gain] (1.00 by default — see there).
///
/// KNOWN, DELIBERATELY UNFIXED: the per-minute chunking costs a flat −0.9%.
/// The state machine restarts at every boundary and has to re-earn
/// [StepParams.confirm], losing ~2 steps per minute of continuous walking.
/// Measured on still→walk→still bouts of 20 / 100 / 1000 / 10000 steps: −0.9%
/// at every size. It is not a gain error and must not be "corrected" with one.
/// Fixing it properly means carrying state across chunk boundaries, i.e.
/// changing how this function segments minutes.
int calcSteps(
  List<List<double>> minuteSignals, {
  double sampleRateHz = StepParams.fs,
}) {
  var total = 0;
  for (final sig in minuteSignals) {
    total += pedometer(sig, sampleRateHz: sampleRateHz);
  }
  return (total * StepParams.gain).round();
}

/// Convenience wrapper for the live foreground stream: [pedometer] over a
/// tri-axial buffer (g, gravity included). Returns the count + an estimated
/// cadence over the buffer span. The RAW (pre-gain) count is in
/// [PedometerResult.steps]; apply [StepParams.gain] at the display/daily-sum
/// layer (as [calcSteps] does).
PedometerResult livePedometer(
  List<double> x,
  List<double> y,
  List<double> z, {
  double sampleRateHz = StepParams.fs,
}) {
  final n = math.min(x.length, math.min(y.length, z.length));
  if (n < StepParams.window || sampleRateHz <= 0) return PedometerResult.none;
  final mag = <double>[
    for (var i = 0; i < n; i++)
      math.sqrt(x[i] * x[i] + y[i] * y[i] + z[i] * z[i])
  ];
  final steps = pedometer(mag, sampleRateHz: sampleRateHz);
  final durationS = n / sampleRateHz;
  if (steps <= 0) return PedometerResult(0, durationS, 0, 0, 0);
  // Cadence over the buffer span. For a dedicated walk this is the walking
  // cadence; the CONFIRM gate guarantees any nonzero count is confirmed gait,
  // so confidence is high. peakToPeak is the magnitude range (motion strength).
  final cadence = durationS > 0 ? steps / (durationS / 60.0) : 0.0;
  var mn = mag.first, mx = mag.first;
  for (final v in mag) {
    if (v < mn) mn = v;
    if (v > mx) mx = v;
  }
  final conf = clamp(cadence >= 60 && cadence <= 200 ? 0.85 : 0.5, 0.0, 1.0);
  return PedometerResult(steps, durationS, cadence, mx - mn, conf);
}

// ──────────────────────── CALIBRATION: live teaches the estimate ────────────

/// A personal cadence model learned from live (100 Hz) walking.
///
/// [cadenceSpm] is the user's measured walking cadence — a genuine Tier A
/// measurement, reportable on its own. It is deliberately NOT consumed by the
/// 1 Hz path ([dailyActiveMinutes]). [refEnmo] is the concurrent 1 Hz ENMO
/// level (g), retained as a diagnostic of what the norm-based index read during
/// known walking; it is NOT part of any threshold. [n] counts the live windows
/// folded in (more = more trusted).
class StepCalibration {
  final double cadenceSpm;
  final double refEnmo;
  final int n;
  const StepCalibration({
    required this.cadenceSpm,
    required this.refEnmo,
    required this.n,
  });

  Map<String, dynamic> toJson() => {
        'cadence_spm': round6(cadenceSpm),
        'ref_enmo_g': round6(refEnmo),
        'n': n,
      };

  static StepCalibration? fromJson(Map<String, dynamic>? j) {
    if (j == null) return null;
    final c = (j['cadence_spm'] as num?)?.toDouble();
    final r = (j['ref_enmo_g'] as num?)?.toDouble();
    final n = (j['n'] as num?)?.toInt();
    if (c == null || r == null || n == null) return null;
    return StepCalibration(cadenceSpm: c, refEnmo: r, n: n);
  }
}

/// Fold a fresh live walking observation into a running calibration.
///
/// Only accepts plausible walking (cadence 70–140 spm, enough rhythm); ignores
/// fidgeting. The update is an n-weighted running mean, so calibration converges
/// and resists one-off bouts. Returns the prior unchanged if the observation is
/// not credible walking.
StepCalibration? calibrateCadence(
  StepCalibration? prior,
  PedometerResult live,
  double concurrentEnmoG, {
  double minConfidence = 0.5,
  double minDurationS = 20.0,
}) {
  final c = live.cadenceSpm;
  final ok = live.confidence >= minConfidence &&
      live.durationS >= minDurationS &&
      c >= 70 &&
      c <= 140 &&
      concurrentEnmoG > 0;
  if (!ok) return prior;
  if (prior == null) {
    return StepCalibration(cadenceSpm: c, refEnmo: concurrentEnmoG, n: 1);
  }
  // Cap n so the model keeps adapting (recency-weighted).
  final w = math.min(prior.n, 50);
  final nNew = w + 1;
  return StepCalibration(
    cadenceSpm: (prior.cadenceSpm * w + c) / nNew,
    refEnmo: (prior.refEnmo * w + concurrentEnmoG) / nNew,
    n: math.min(prior.n + 1, 200),
  );
}


// ───────────────────────── TIER B: 1 Hz daily estimate ──────────────────────
//
// WHY THIS LOOKS THE WAY IT DOES — the two anchors that DON'T work:
//
//   (a) An ABSOLUTE g cut-point on ENMO. ENMO = max(0, ‖a‖ − gRef), and gRef is
//       estimated per-day from the stillest samples. On a wrist those are the
//       sleep block, whose orientation differs from the waking day; with a few
//       percent of per-axis gain/offset error the still ‖a‖ can differ by
//       ~0.05 g between postures. That bias is added to EVERY waking minute,
//       and it is the same size as the walking signal itself. Sweeping gRef
//       over one real day's raw data moved the daily total from ~42 000 steps
//       to 0 with no stable plateau in between — SNR ≈ 1 by construction.
//
//   (b) A SAME-DAY RELATIVE baseline (e.g. today's p20 + k·MAD). This fails in
//       mirror image: on a genuinely quiet day the baseline collapses toward
//       zero, the floor collapses with it, and ordinary sedentary minutes clear
//       it. Same real day, same failure magnitude, opposite direction.
//
// What DOES work is a MULTI-DAY PERSONAL REFERENCE on a calibration-invariant
// feature: one floor derived from the POOLED distribution of the user's
// [MotionMinute.dynAmp] minutes across trailing history, applied to every day.
// It is stable because it is estimated from thousands of minutes, and it is
// invariant to sensor drift because dynAmp is (see enmo.dart).
//
// And when there is not enough history to estimate that floor, we ABSTAIN.

/// Physiological clamp for a personally-measured (Tier A, 100 Hz) cadence.
/// Outside this, the "measurement" is not walking.
///
/// NOTE: cadence is used ONLY to describe a real 100 Hz walking bout. It is
/// never applied to 1 Hz minutes to synthesise a step count — see
/// [dailyActiveMinutes] for why that conversion was removed.
const double cadenceClampLowSpm = 60.0;
const double cadenceClampHighSpm = 180.0;

/// Quantile of the POOLED trailing dynAmp minutes used as the ambulatory floor.
///
/// p90 means "the top decile of your minutes is where ambulation lives", which
/// is both a sane prior for a wrist-worn 24/7 stream (most minutes of most days
/// are sedentary or asleep) and a hard structural cap: at most ~10% of pooled
/// minutes can clear it, so no calibration excursion can produce a 1000×
/// swing in the daily total.
const double personalDynFloorQuantile = 0.90;

/// Minimum pooled trailing minutes before a personal floor is trustworthy.
/// 2000 minutes ≈ 1.5 days of continuous wear, in practice several partial
/// days — enough that the quantile is not dominated by one posture or one day.
///
/// This gates [personalDynFloor], which needs the RAW minute pool. A caller
/// that prunes its substrate cannot supply that and uses
/// [personalDynFloorFromDailySummaries] instead, which is gated on DAYS —
/// so do NOT report cold-start progress against this constant unless the
/// caller genuinely counted minutes. See [dailyActiveMinutes].
const int personalDynFloorMinMinutes = 2000;

/// Minimum trailing DAYS for [personalDynFloorFromDailySummaries].
const int personalDynFloorMinDays = 5;

/// Multiple of the personal floor above which a minute is VIGOROUS/non-walking
/// arm motion (shaking, lifting, sport) rather than ambulation. Expressed as a
/// RATIO so it inherits the floor's calibration-invariance — an absolute g
/// ceiling would reintroduce exactly the fragility this design removes.
const double defaultVigorousCeilingRatio = 3.0;

/// Minimum covered minutes in a day before an estimate is meaningful at all.
const int dailyStepMinCoveredMinutes = 4;

/// Derive the PERSONAL ambulatory floor (g, in dynAmp units) from pooled
/// trailing history.
///
/// [pooledMinuteDynAmps] is every [MotionMinute.dynAmp] the caller has for this
/// user over its trailing window — pooled ACROSS days, deliberately: a single
/// day's distribution is not a stable anchor (see the section header). Returns
/// the [quantile] of that pooled distribution, or `null` when there is not
/// enough history ([minMinutes]) or the distribution is degenerate (a
/// non-positive quantile would pass every minute).
///
/// This package is pure — no I/O, no clock — so it cannot read history itself.
/// The caller supplies the pool; this function only decides what a floor IS.
double? personalDynFloor(
  List<double> pooledMinuteDynAmps, {
  double quantile = personalDynFloorQuantile,
  int minMinutes = personalDynFloorMinMinutes,
}) {
  final xs = [
    for (final v in pooledMinuteDynAmps)
      if (v.isFinite && v >= 0) v
  ];
  if (xs.length < minMinutes) return null;
  final q = percentile(xs, clamp(quantile, 0.0, 1.0) * 100.0);
  if (q == null || !q.isFinite || q <= 0) return null;
  return q;
}

/// The same personal floor, derived from PER-DAY summaries instead of the raw
/// pooled minutes.
///
/// [personalDynFloor] is the definition, but it needs every trailing minute —
/// and a caller that prunes its raw substrate (as the on-device pipeline does,
/// within days) cannot re-read them later. Persisting one high-quantile value
/// per day is ~1400× cheaper and is what a storage-bound caller can actually
/// keep, so this variant takes that: [dailyHighQuantiles] is each trailing
/// day's own [personalDynFloorQuantile] of `dynAmp`.
///
/// It returns the MEDIAN across days rather than a quantile-of-quantiles. That
/// is the deliberate choice: the median is robust to a single anomalous day —
/// a day spent travelling, or one where the wrist sat in an unusual posture —
/// which is exactly the single-day sensitivity that makes a same-day threshold
/// unusable in the first place. Pooling the raw minutes would let one very long
/// day dominate; the median weights every day equally.
///
/// ⚠️ FREEZE THE RESULT. Call this ONCE, persist it, and keep using the stored
/// value — do NOT recompute it every day. See [enrollmentDaysForFrozenFloor].
///
/// This threshold is derived from the same signal it thresholds, so if it is
/// recomputed continuously it TRACKS the user and cancels the trend it exists
/// to report. Measured on real substrate by scaling one day's `dynAmp` and
/// recomputing both ways:
///
/// ```
///   activity x     FROZEN floor     recomputed floor
///        1.00               23                   37
///        1.50               66                   37
///        2.00              128                   37
///        3.00              254                   37
/// ```
///
/// A recomputed floor reports the SAME number whether the user tripled their
/// activity or did nothing. A frozen one tracks it. The continuously-updating
/// form is a metric that cannot see change.
///
/// (A sleep-quiet anchor was tested as the alternative and REFUTED on the same
/// data: coefficient of variation 138.6% across days versus 9.3% for this
/// estimator, and on one night it landed above the entire day's range, which
/// would report zero movement. The median-of-daily-p90s is the right ESTIMATOR;
/// the bug was only ever that it was never frozen.)
///
/// Returns `null` below [minDays] of history, or when the result is degenerate.
double? personalDynFloorFromDailySummaries(
  List<double> dailyHighQuantiles, {
  int minDays = personalDynFloorMinDays,
}) {
  final xs = [
    for (final v in dailyHighQuantiles)
      if (v.isFinite && v > 0) v
  ];
  if (xs.length < minDays) return null;
  final m = median(xs);
  if (m == null || !m.isFinite || m <= 0) return null;
  return m;
}

/// Days of history to accumulate before FREEZING the movement floor.
///
/// [personalDynFloorMinDays] (5) is the minimum at which the median is
/// meaningful at all; this is the point at which it is stable enough to commit
/// to. Measured CV of the daily p90 across real days is ~9%, so a median over
/// this many days is well inside the estimator's own noise.
const int enrollmentDaysForFrozenFloor = 14;

/// Should the persisted floor be re-estimated?
///
/// Deliberately restrictive. The whole value of freezing is lost if it thaws on
/// its own, so this returns true only for events that genuinely change the
/// signal's scale — never merely because time passed or activity changed.
///
/// [daysSinceFrozen] guards against indefinite staleness; [wearGapDays] catches
/// a device that was off-wrist long enough that the body/device relationship may
/// have changed; [deviceChanged] and [wristChanged] are explicit user events.
bool shouldRefreezeFloor({
  required int daysSinceFrozen,
  int wearGapDays = 0,
  bool deviceChanged = false,
  bool wristChanged = false,
  int maxAgeDays = 365,
}) =>
    deviceChanged ||
    wristChanged ||
    wearGapDays >= 30 ||
    daysSinceFrozen >= maxAgeDays;

/// The per-day value a caller should persist to feed
/// [personalDynFloorFromDailySummaries] — this day's own high quantile of
/// `dynAmp` over its covered minutes. Returns `null` when the day is too thin
/// to summarise, so the caller stores nothing rather than a fabricated level.
double? dailyDynSummary(
  List<MotionMinute> motion, {
  double minSamplesPerMinute = 30,
  double quantile = personalDynFloorQuantile,
  int minCoveredMinutes = 60,
}) {
  final xs = [
    for (final m in motion)
      if (m.nSamples >= minSamplesPerMinute && m.dynAmp.isFinite && m.dynAmp >= 0)
        m.dynAmp
  ];
  if (xs.length < minCoveredMinutes) return null;
  final q = percentile(xs, clamp(quantile, 0.0, 1.0) * 100.0);
  if (q == null || !q.isFinite || q <= 0) return null;
  return q;
}

/// Daily MOVEMENT estimate from the 1 Hz substrate.
///
/// [activeMinutes] — minutes containing sustained wrist movement — is the ONLY
/// quantity this returns, because it is the only one a 1 Hz wrist accel stream
/// supports. There is deliberately no step count and no cadence here; see
/// [dailyActiveMinutes] for why converting these minutes to steps was removed.
///
/// Read it as "minutes the wrist was moving", NOT as "minutes spent walking":
/// at the wrist, ordinary arm work (cooking, dishes, driving, tool use) produces
/// MORE acceleration than walking does, so a high value does not imply
/// ambulation. It is an activity-volume index, not a locomotion measure.
class DailyMovementEstimate {
  final int activeMinutes; // minutes with sustained wrist movement
  final double dynFloorG; // personal floor actually applied (g)

  /// Covered minutes / EXPECTED minutes when the caller supplies
  /// `expectedMinutes` (1440 for a calendar day); otherwise covered minutes /
  /// the worn SPAN, which counts interior holes but not the unworn ends.
  /// Read the two cases differently — only the first is "fraction of the day".
  final double coverage;
  final int boutCount; // number of qualifying bouts

  const DailyMovementEstimate({
    required this.activeMinutes,
    required this.dynFloorG,
    required this.coverage,
    required this.boutCount,
  });

  Map<String, dynamic> toJson() => {
        'active_min': activeMinutes,
        'bout_count': boutCount,
        'dyn_floor_g': round6(dynFloorG),
        'coverage': round6(coverage),
      };
}

/// 1 Hz MOVEMENT-MINUTES estimate. Returns NO step count, by design.
///
/// WHY THERE IS NO STEP COUNT HERE (this replaced a step estimator that was
/// measured to over-report by ~6× on a real day, and the reason is structural,
/// not a calibration error):
///
///   1. NYQUIST. Gait is 1.4–2.3 Hz (Straczkiewicz 2023, npj Digit Med,
///      doi:10.1038/s41746-022-00745-z). At 1 Hz sampling every gait
///      fundamental is sub-Nyquist and the alias map is many-to-one: 80, 100,
///      140 and 160 spm all alias to 0.333 Hz. Cadence is not merely noisy, it
///      is NOT IDENTIFIABLE. No published step detector exists below 10 Hz.
///
///   2. AMPLITUDE IS INVERTED AT THE WRIST. Walking produces LESS wrist
///      acceleration than ordinary arm work — walking ≈ 66 mg ENMO vs stirring
///      ≈ 104 mg and chopping ≈ 139 mg. So a movement threshold cannot isolate
///      walking: walking sits mid-pack in a normal day's distribution. Wrist
///      devices are documented to emit 22–27 false steps/min during dishes,
///      reaching and cycling (O'Connell 2017, PLoS ONE,
///      doi:10.1371/journal.pone.0169616) while detecting slow walking with
///      sensitivity 0.05 — the two errors have OPPOSITE sign, so no gain
///      constant can fix both.
///
/// A real step count must come from a source that can see gait: the Tier A
/// 100 Hz pedometer ([pedometer]/[livePedometer]) or the phone's own pedometer.
/// Absent those, the honest output is no number at all.
///
/// What IS resolvable at 1 Hz is whether a minute contained sustained movement,
/// which is what this returns. A covered minute counts when BOTH of these hold:
///   • its [MotionMinute.dynAmp] is above [personalDynFloorG];
///   • it belongs to a run of at least [minBoutMin] CONSECUTIVE qualifying
///     minutes, where consecutive means ADJACENT ON THE CLOCK — the next
///     minute's `tsMinStartMs` is exactly 60 s later. A coverage gap breaks the
///     run and cannot stitch two short stretches into one qualifying bout. This
///     is a DENOISER, not a health threshold: the 2018 US Physical Activity
///     Guidelines removed the 10-minute minimum-bout rule, so do not defend
///     this number physiologically.
///
/// [expectedMinutes] mirrors `enmoSeries`: pass 1440 for a calendar day so
/// [DailyMovementEstimate.coverage] is measured against the day rather than
/// against the worn span. Without it, a day worn 4 h out of 24 reports 1.0
/// while `enmoSeries` reports 0.167 for the identical substrate.
///
/// There is deliberately no upper ceiling and no HR gate. Both were measured
/// against real substrate and found to be dead or harmful — see the comments
/// at their former sites before reintroducing either.
///
/// [personalDynFloorG] is REQUIRED and MAY BE NULL. Null means "not enough
/// history to know this user's movement scale", and the honest answer to that
/// is an ABSENT metric carrying a `need_baseline:have=…,need=…` note — build
/// the floor with [personalDynFloorFromDailySummaries] and pass
/// [historyDaysAvailable] so the note can report progress. There is
/// deliberately NO constant fallback: a constant absolute floor is precisely
/// the failure this design removes.
///
/// The note counts DAYS, against [personalDynFloorMinDays]. It used to count
/// them against [personalDynFloorMinMinutes] (2000) while every caller passed a
/// day count, so a user three days in was told `have=3,need=2000` — ~1997 more
/// of a unit nobody was measuring, for a metric that unlocks in two.
///
/// Tier is always ESTIMATE.
///
/// This function is intentionally independent of the 100 Hz pedometer: it
/// measures movement volume, not steps, so there is nothing to double-count.
/// Callers may still exclude 100 Hz-covered minutes if they want the two
/// quantities to describe disjoint spans.
Metric<DailyMovementEstimate> dailyActiveMinutes(
  List<MotionMinute> motion, {
  required double? personalDynFloorG,
  double minSamplesPerMinute = 30,
  int minBoutMin = 3,
  int historyDaysAvailable = 0,
  int? expectedMinutes,
}) {
  const inputs = ['dyn_amp_per_min', 'personal_dyn_floor'];
  if (motion.isEmpty) {
    return const Metric<DailyMovementEstimate>.absent(
      tier: Tier.estimate,
      inputs_used: inputs,
      note: 'no motion minutes',
    );
  }

  // COLD START: no personal movement scale → abstain. Never substitute a
  // constant floor; a constant floor is the bug this rewrite exists to fix.
  final floor = personalDynFloorG;
  if (floor == null || !floor.isFinite || floor <= 0) {
    return Metric<DailyMovementEstimate>.absent(
      tier: Tier.estimate,
      inputs_used: inputs,
      note: needBaselineNote(
        have: historyDaysAvailable,
        need: personalDynFloorMinDays,
      ),
    );
  }
  // NO CEILING. A `floor x 3` upper bound used to reject "vigorous non-gait"
  // motion. It was MEASURED against 4 days of real substrate and rejected
  // ZERO minutes on every one of them, with 0.42-0.55 g of headroom to the
  // day's maximum. It cannot fire on artifacts either: a 3-second knock
  // averages to ~0.23 g over its minute, which does not even reach the FLOOR.
  // So the only thing it could ever exclude is a genuinely hard session — a
  // volume metric that discards its highest-volume minutes is broken by
  // definition. Removed rather than retuned.

  // Covered minutes only — sparse minutes can't be judged.
  final idx = <int>[];
  final dyns = <double>[];
  for (var i = 0; i < motion.length; i++) {
    if (motion[i].nSamples >= minSamplesPerMinute) {
      idx.add(i);
      dyns.add(motion[i].dynAmp);
    }
  }
  final covered = idx.length;
  // COVERAGE DENOMINATOR — same rule as enmo.dart, and it must be the same
  // rule, because both are published for the same day. The worn SPAN counts
  // interior holes but NOT the unworn ends, so a day worn 4 h out of 24 read
  // coverage 1.0 here while enmoSeries(expectedMinutes: 1440) read 0.167 on the
  // identical substrate. Pass [expectedMinutes] to count the ends too.
  final spanMinutes =
      ((motion.last.tsMinStartMs - motion.first.tsMinStartMs) / 60000).round() + 1;
  final denom = expectedMinutes ?? spanMinutes;
  final coverage = denom <= 0 ? 0.0 : clamp(covered / denom, 0.0, 1.0);
  if (covered < dailyStepMinCoveredMinutes) {
    return Metric<DailyMovementEstimate>.absent(
      tier: Tier.estimate,
      inputs_used: inputs,
      note: 'too few covered minutes to estimate activity '
          '(have=$covered, need=$dailyStepMinCoveredMinutes)',
    );
  }

  // NO CADENCE BAND. Converting these minutes to steps via any cadence — even a
  // personally measured one — is the fabrication this function was rewritten to
  // remove. See the doc comment: cadence is not identifiable at 1 Hz, and the
  // minutes being counted are not specifically ambulation.

  // NO HR GATE. A `restingHr + 8 bpm` corroboration gate used to sit here. It
  // was MEASURED across 4 days of real substrate and changed the answer by
  // exactly ZERO minutes on every day: at a resting HR of ~62 the gate lands
  // at ~6% of heart-rate reserve, below every ACSM band -- physiologically
  // "not lying down" -- and 73-100% of covered minutes already cleared it.
  //
  // It was worse than merely useless. It implied a physiological corroboration
  // it never performed, it is satisfied all day in a hot climate (passive heat
  // raises HR 10-25 bpm at zero metabolic cost), and it failed in the WRONG
  // DIRECTION: PPG-derived HR is least reliable during exactly the motion
  // being gated, so a dropout deleted minutes the accelerometer measured
  // perfectly well. An honestly accelerometer-only metric is more defensible
  // than one carrying a decorative HR gate.

  // pass 1 — per-minute gate: dynAmp above the personal movement floor. That
  // is the WHOLE gate. There is no upper band and no HR condition; both were
  // measured dead and removed (see the two comments above).
  final gateOk = List<bool>.filled(idx.length, false);
  for (var k = 0; k < idx.length; k++) {
    gateOk[k] = dyns[k] > floor;
  }

  // pass 2 — bout gate: only credit minutes inside a run of >= minBoutMin
  // CONSECUTIVE gate-passing minutes, so a scattered single minute (a brief
  // movement/HR blip mid-turnover in bed, say) never becomes phantom activity.
  //
  // Adjacency is tested ON THE CLOCK. It used to be `idx[end+1] == idx[end]+1`,
  // which is adjacency in the gap-COMPACTED list: enmoSeries emits no
  // MotionMinute at all for a fully-absent minute, so an off-wrist minute never
  // occupies a slot and could not break a run. Measured: four isolated moving
  // minutes an HOUR apart were credited as one 4-minute bout. Partially-covered
  // minutes were already handled — they stay in `motion` and are excluded from
  // `idx` — so only the fully-absent (off-wrist) case slipped through.
  var activeMin = 0;
  var boutCount = 0;
  var k = 0;
  while (k < idx.length) {
    if (!gateOk[k]) {
      k++;
      continue;
    }
    var end = k;
    while (end + 1 < idx.length &&
        gateOk[end + 1] &&
        ((motion[idx[end + 1]].tsMinStartMs - motion[idx[end]].tsMinStartMs) /
                    60000)
                .round() ==
            1) {
      end++;
    }
    if (end - k + 1 >= minBoutMin) {
      activeMin += end - k + 1;
      boutCount++;
    }
    k = end + 1;
  }

  // Confidence reflects how much of the day we could actually judge. It is
  // capped low because this is a movement-volume index from a wrist sensor: it
  // cannot distinguish walking from arm work, which is a limitation of the
  // measurement site, not of the estimator.
  // Upper bound is 0.30, which is what the expression can actually reach —
  // the inner clamp caps at 1.0, so `0.30 * 1.0` is the ceiling. Writing a
  // larger outer bound would imply a confidence this metric never claims.
  final conf = clamp(0.30 * clamp(coverage / 0.6, 0.3, 1.0), 0.1, 0.30);

  return Metric<DailyMovementEstimate>(
    value: DailyMovementEstimate(
      activeMinutes: activeMin,
      dynFloorG: floor,
      coverage: coverage,
      boutCount: boutCount,
    ),
    confidence: conf,
    tier: Tier.estimate,
    inputs_used: inputs,
    note: 'ESTIMATE: minutes of sustained wrist movement, measured against your '
        'personal movement floor. This is activity volume, NOT walking — at the '
        'wrist, arm work (cooking, dishes, driving) registers as strongly as '
        'walking does. It is deliberately not converted to a step count',
  );
}
