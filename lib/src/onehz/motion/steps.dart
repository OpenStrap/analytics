// STEPS — hybrid pedometry for a wrist that gives us TWO different streams.
//
// The honest constraint (see motion.dart §"what 1 Hz accel CANNOT do"):
//   * The always-on 24/7 substrate is 1 Hz accel. Human gait is 1.4–2.5 Hz, far
//     above the 0.5 Hz Nyquist limit of a 1 Hz stream — so you CANNOT count
//     individual steps from the stored substrate. Full stop.
//   * Real per-step detection is only possible on the ~100 Hz foreground accel
//     (R10 / 0x2B), which exists only while the app is connected and streaming.
//
// So we split the problem the only honest way:
//
//   TIER A — [pedometer] / [livePedometer]: a real step counter on the 100 Hz
//     foreground stream. The locked Analog Devices AN-2554 "full step detection"
//     algorithm, ported VERBATIM from the OpenStrap backend
//     (openstrap-analytics/src/steps.ts) where it was calibrated on a 100-step
//     ground-truth walk (raw ×1.11 gain). Its CONFIRM=8 regularity gate rejects
//     waving/typing/handling and reads 0 at rest. Directly testable: walk N
//     steps with the app open and compare.
//
//   TIER B — [dailyStepEstimate]: a 24/7 estimate from the 1 Hz substrate. We
//     cannot count steps, so the PRIMARY quantity we report is the one that IS
//     resolvable at 1 Hz: ACTIVE (ambulatory) MINUTES. Steps are then reported
//     as a RANGE, minutes × the free-living cadence band (Tudor-Locke 2011,
//     ~100–130 steps/min), never as a single fabricated-precision number.
//
//     Three things make the minute detector stable, and all three matter:
//       1. The feature is [MotionMinute.dynAmp] — per-axis high-passed dynamic
//          amplitude — NOT ENMO. ENMO depends on a scalar gravity reference
//          whose per-day estimate moves by about the same amount as the signal
//          being measured, so an absolute cut-point on ENMO is not stable
//          across days. dynAmp removes gravity as a vector and is invariant to
//          per-axis offset. (Vähä-Ypyä 2015 argues for calibration-robust
//          amplitude measures over ENMO for exactly this reason.)
//       2. The cut-point is a MULTI-DAY PERSONAL REFERENCE ([personalDynFloor],
//          a quantile of the user's POOLED trailing dynAmp minutes) — neither
//          an absolute g constant (calibration-fragile) nor a same-day relative
//          baseline (which collapses on a quiet day and then passes
//          everything). One floor, computed over enough history to be stable,
//          applied to every day.
//       3. Corroboration + duration: HR must be lifted off rest when HR is
//          available, and a minute only counts inside a run of consecutive
//          ambulatory minutes.
//
//     With no personal reference the estimator ABSTAINS (absent Metric with a
//     `need_baseline:` note). It never substitutes a constant — substituting a
//     constant IS the failure mode this design exists to prevent.
//
//   CALIBRATION — [StepCalibration] / [calibrateCadence]: Tier A is also Tier
//     B's teacher. When live walking data exists we measure THIS user's real
//     cadence, and that measured cadence NARROWS the reported step band. It is
//     used only where it is real (cadence, from a 100 Hz count); it is never
//     extrapolated into a per-minute cadence regression, because 1 Hz cannot
//     resolve cadence at all (gait 1.4–2.5 Hz; 2.0 Hz aliases exactly to DC).
//
// Pure: dart:math only. No I/O, no clock, no randomness.
//
// DELIBERATELY NOT CONSUMED HERE: a band's own on-chip cumulative step
// counter. WHOOP5/gen5's per-second record adds one (`step_motion_counter`,
// monotonic, no midnight reset) that gen4 never had — but this package
// already paid, once, for trusting an on-device-adjacent derived quantity
// without independent validation: the original ENMO-scalar approach (see the
// TIER B section header below) read 39,384 steps/day off a gravity-reference
// artifact until it was rebuilt from scratch on dynAmp + a personal floor.
// The gen5 counter comes with no ground-truth cross-check anywhere in the
// protocol spec (contrast Tier A below, calibrated against a real 100-step
// walk) and no documented reset/rollover/pause semantics, so wiring it in now
// would repeat exactly that failure mode on a new field. If a future spec
// revision supplies a validated accuracy characterization, the right seam is
// a NEW optional corroboration signal alongside HR in [dailyStepEstimate]
// (never a replacement for the honest 1 Hz estimate) — not a special-cased
// gen4/gen5 branch, and not a silent substitute for either Tier below.

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

/// Locked AN-2554 parameters — ported VERBATIM from the OpenStrap backend
/// pedometer (`openstrap-analytics/src/steps.ts`), which was calibrated against
/// a 100-step ground-truth walk on our ~100 Hz wrist IMU. Do not retune without
/// a fresh ground-truth calibration.
class StepParams {
  static const int fs = 100; // assembled IMU sample rate (Hz)
  static const int filter = 8; // low-pass moving-average taps
  static const int window = 33; // centered peak window (~0.33 s @100 Hz)
  static const double sens = 0.10; // g — dead-zone around the dynamic threshold
  static const int thrOrder = 4; // dynamic-threshold smoothing buffer
  static const int confirm = 8; // consecutive possible steps before counting
  static const int maxMinTimeout = 120; // samples to find a min after a max
  static const double gain = 1.11; // calibration: raw 90 → ~100 ground truth
}

/// AN-2554 time-domain step count over ONE contiguous accelerometer-MAGNITUDE
/// signal (g, ~100 Hz, gravity INCLUDED). Raw count — no calibration gain.
///
/// Faithful port of `pedometer()` from the backend:
///   low-pass (trailing MA) → centered-window max/min extrema → dynamic
///   threshold ± [StepParams.sens]/2 dead-zone → [StepParams.confirm]
///   consecutive "possible steps" before counting (the regularity gate that
///   rejects waving/typing/handling — validated to read 0 at rest).
int pedometer(List<double> sig) {
  final n = sig.length;
  if (n < StepParams.window) return 0;
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
        continue;
      }
      final mx = curMax, mn = cv;
      if (mx > dynVal + StepParams.sens / 2 && mn < dynVal - StepParams.sens / 2) {
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

/// Daily total: AN-2554 over each per-minute contiguous magnitude signal,
/// summed and scaled by the calibration [StepParams.gain]. Faithful port of
/// `calcSteps()`. Per-minute chunking is the configuration the gain was
/// calibrated under — keep it.
int calcSteps(List<List<double>> minuteSignals) {
  var total = 0;
  for (final sig in minuteSignals) {
    total += pedometer(sig);
  }
  return (total * StepParams.gain).round();
}

/// Convenience wrapper for the live foreground stream: AN-2554 over a tri-axial
/// buffer (g, gravity included). Returns the count + an estimated cadence over
/// the buffer span. The RAW (pre-gain) count is in [PedometerResult.steps];
/// apply [StepParams.gain] at the display/daily-sum layer (as [calcSteps] does).
PedometerResult livePedometer(
  List<double> x,
  List<double> y,
  List<double> z, {
  double sampleRateHz = 100.0,
}) {
  final n = math.min(x.length, math.min(y.length, z.length));
  if (n < StepParams.window || sampleRateHz <= 0) return PedometerResult.none;
  final mag = <double>[
    for (var i = 0; i < n; i++)
      math.sqrt(x[i] * x[i] + y[i] * y[i] + z[i] * z[i])
  ];
  final steps = pedometer(mag);
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
/// [cadenceSpm] is the user's measured walking cadence — the one quantity Tier A
/// genuinely measures and the only one Tier B consumes (to narrow its reported
/// step band; see [dailyStepEstimate]). [refEnmo] is the concurrent 1 Hz ENMO
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

/// Free-living walking cadence band (steps/min), Tudor-Locke 2011 (and the
/// cadence-band literature that follows it): purposeful adult ambulation in
/// free living sits around 100 steps/min, with normal walking spanning roughly
/// 100–130. We report the BAND, not a point, because 1 Hz accel cannot resolve
/// cadence at all — see [dailyStepEstimate].
const double freeLivingCadenceLowSpm = 100.0;
const double freeLivingCadenceHighSpm = 130.0;

/// Physiological clamp for any personally-measured cadence used to narrow the
/// band. Outside this, the "measurement" is not walking.
const double cadenceClampLowSpm = 60.0;
const double cadenceClampHighSpm = 180.0;

/// Half-width (fraction) of the band placed around a personally MEASURED
/// cadence. Tier A measures cadence over a bout; ±10% covers the ordinary
/// within-person spread between strolling and purposeful walking.
const double personalCadenceBandFrac = 0.10;

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

/// Daily ACTIVITY estimate from the 1 Hz substrate.
///
/// [activeMinutes] is the PRIMARY, honest quantity: minutes spent ambulatory.
/// It is what a 1 Hz accel stream can actually support, and it is the unit
/// public activity guidance is written in (minutes of moderate activity).
///
/// Steps are reported as the RANGE [stepsLow]–[stepsHigh] = activeMinutes ×
/// the cadence band. [steps] is the midpoint, provided only so callers that
/// must render one scalar can; it carries no more information than the range
/// and should be shown with the range wherever there is room.
class DailyStepEstimate {
  final int activeMinutes; // primary quantity
  final int stepsLow; // activeMinutes × cadenceLowSpm
  final int stepsHigh; // activeMinutes × cadenceHighSpm
  final int steps; // midpoint of the range (back-compat scalar)
  final double cadenceLowSpm;
  final double cadenceHighSpm;
  final double dynFloorG; // personal floor actually applied (g)
  final double coverage; // fraction of the day with valid motion data
  final bool calibrated; // a personally MEASURED cadence narrowed the band

  const DailyStepEstimate({
    required this.activeMinutes,
    required this.stepsLow,
    required this.stepsHigh,
    required this.steps,
    required this.cadenceLowSpm,
    required this.cadenceHighSpm,
    required this.dynFloorG,
    required this.coverage,
    required this.calibrated,
  });

  Map<String, dynamic> toJson() => {
        'active_min': activeMinutes,
        'steps_low': stepsLow,
        'steps_high': stepsHigh,
        'steps': steps,
        'cadence_low_spm': round6(cadenceLowSpm),
        'cadence_high_spm': round6(cadenceHighSpm),
        'cadence_source': calibrated ? 'personal_measured' : 'population_band',
        'dyn_floor_g': round6(dynFloorG),
        'coverage': round6(coverage),
        'calibrated': calibrated,
      };
}

/// 1 Hz ACTIVE-MINUTES estimate, with steps as a derived RANGE.
///
/// NYQUIST, stated plainly: gait is 1.4–2.5 Hz and 2.0 Hz — 120 steps/min, the
/// most common adult cadence — aliases exactly to DC on a 1 Hz stream. Steps
/// are therefore NOT resolvable here and neither is cadence. What IS resolvable
/// is whether a minute contained sustained whole-body movement. So this
/// function detects AMBULATORY MINUTES and converts them to a step RANGE using
/// a cadence band (Tudor-Locke 2011), never a per-minute cadence estimate.
///
/// A covered minute is ambulatory when ALL of these hold:
///   • its [MotionMinute.dynAmp] is above [personalDynFloorG] and at or below
///     `personalDynFloorG × [vigorousCeilingRatio]` (above the ceiling is
///     vigorous/non-ambulatory arm motion, counted as activity elsewhere);
///   • when HR is supplied, its HR is at least `restingHr + [hrMarginBpm]`
///     ([restingHr] if given, else the day's 10th-percentile HR);
///   • it belongs to a run of at least [minBoutMin] CONSECUTIVE ambulatory
///     minutes, where consecutive means adjacent in ORIGINAL minute index — a
///     coverage gap breaks the run and cannot stitch two short stretches into
///     one qualifying bout.
///
/// [personalDynFloorG] is REQUIRED and MAY BE NULL. Null means "not enough
/// history to know this user's movement scale", and the honest answer to that
/// is an ABSENT metric carrying a `need_baseline:have=…,need=…` note — build
/// the floor with [personalDynFloor] and pass [pooledMinutesAvailable] so the
/// note can report progress. There is deliberately NO constant fallback: a
/// constant absolute floor is precisely the failure this design removes.
///
/// [calib] (a personally MEASURED Tier A cadence) narrows the reported band to
/// ±[personalCadenceBandFrac] around that cadence; otherwise the population
/// band is used. Tier is always ESTIMATE.
///
/// IMPORTANT (no double-count): the caller must pass ONLY minutes NOT covered by
/// the live 100 Hz pedometer — 100 Hz steps are real and always preferred for the
/// time they cover. This function never sees those minutes.
Metric<DailyStepEstimate> dailyStepEstimate(
  List<MotionMinute> motion, {
  required double? personalDynFloorG,
  List<double>? hrPerMin,
  double? restingHr,
  StepCalibration? calib,
  double hrMarginBpm = 8.0,
  double minSamplesPerMinute = 30,
  int minBoutMin = 3,
  double vigorousCeilingRatio = defaultVigorousCeilingRatio,
  int pooledMinutesAvailable = 0,
}) {
  const inputs = ['dyn_amp_per_min', 'hr_per_min', 'personal_dyn_floor'];
  if (motion.isEmpty) {
    return const Metric<DailyStepEstimate>.absent(
      tier: Tier.estimate,
      inputs_used: inputs,
      note: 'no motion minutes',
    );
  }

  // COLD START: no personal movement scale → abstain. Never substitute a
  // constant floor; a constant floor is the bug this rewrite exists to fix.
  final floor = personalDynFloorG;
  if (floor == null || !floor.isFinite || floor <= 0) {
    return Metric<DailyStepEstimate>.absent(
      tier: Tier.estimate,
      inputs_used: inputs,
      note: needBaselineNote(
        have: pooledMinutesAvailable,
        need: personalDynFloorMinMinutes,
      ),
    );
  }
  final ceiling = floor * math.max(vigorousCeilingRatio, 1.0);

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
  final coverage = covered / motion.length;
  if (covered < dailyStepMinCoveredMinutes) {
    return Metric<DailyStepEstimate>.absent(
      tier: Tier.estimate,
      inputs_used: inputs,
      note: 'too few covered minutes to estimate activity '
          '(have=$covered, need=$dailyStepMinCoveredMinutes)',
    );
  }

  // Cadence band. A personally MEASURED cadence (Tier A, 100 Hz, real counts)
  // narrows the band; otherwise we use the free-living population band. We do
  // NOT model per-minute cadence — 1 Hz cannot resolve it.
  final measured = calib != null &&
          calib.n >= 3 &&
          calib.cadenceSpm >= cadenceClampLowSpm &&
          calib.cadenceSpm <= cadenceClampHighSpm
      ? calib.cadenceSpm
      : null;
  final calibrated = measured != null;
  final cadLow = calibrated
      ? clamp(measured * (1 - personalCadenceBandFrac), cadenceClampLowSpm,
          cadenceClampHighSpm)
      : freeLivingCadenceLowSpm;
  final cadHigh = calibrated
      ? clamp(measured * (1 + personalCadenceBandFrac), cadenceClampLowSpm,
          cadenceClampHighSpm)
      : freeLivingCadenceHighSpm;

  // HR corroboration: HR must be lifted off rest for a minute to count.
  final useHr = hrPerMin != null && hrPerMin.length == motion.length;
  double restHr = restingHr ?? 0;
  if (useHr && restingHr == null) {
    final hrs = [for (final h in hrPerMin) if (h > 0) h];
    if (hrs.length >= 10) restHr = percentile(hrs, 10)!;
  }
  final hrGate = restHr + hrMarginBpm;

  // pass 1 — per-minute gate: movement inside the ambulatory band, and (when
  // HR is available) HR lifted off rest.
  final gateOk = List<bool>.filled(idx.length, false);
  for (var k = 0; k < idx.length; k++) {
    final d = dyns[k];
    if (d <= floor || d > ceiling) continue; // sedentary, or vigorous non-gait
    if (useHr && restHr > 0) {
      final hr = hrPerMin[idx[k]];
      if (hr > 0 && hr < hrGate) continue; // HR says still at rest
    }
    gateOk[k] = true;
  }

  // pass 2 — bout gate: only credit minutes inside a run of >= minBoutMin
  // CONSECUTIVE gate-passing minutes, so a scattered single minute (a brief
  // movement/HR blip mid-turnover in bed, say) never becomes phantom activity.
  // Runs are broken by ORIGINAL minute index (idx[k]), not position in the
  // covered-minutes array, so a coverage gap can't stitch two separate
  // stretches into one fake long bout.
  var activeMin = 0;
  var k = 0;
  while (k < idx.length) {
    if (!gateOk[k]) {
      k++;
      continue;
    }
    var end = k;
    while (end + 1 < idx.length &&
        gateOk[end + 1] &&
        idx[end + 1] == idx[end] + 1) {
      end++;
    }
    if (end - k + 1 >= minBoutMin) activeMin += end - k + 1;
    k = end + 1;
  }

  final stepsLow = (activeMin * cadLow).round();
  final stepsHigh = (activeMin * cadHigh).round();
  final stepsMid = ((stepsLow + stepsHigh) / 2).round();

  // Confidence reflects (a) how much of the day we could actually judge and
  // (b) whether the cadence band is this user's or the population's. It never
  // reflects the step number itself — that number is a band by construction.
  final conf = clamp(
    (calibrated ? 0.45 : 0.30) * clamp(coverage / 0.6, 0.3, 1.0),
    0.1,
    0.7,
  );

  return Metric<DailyStepEstimate>(
    value: DailyStepEstimate(
      activeMinutes: activeMin,
      stepsLow: stepsLow,
      stepsHigh: stepsHigh,
      steps: stepsMid,
      cadenceLowSpm: cadLow,
      cadenceHighSpm: cadHigh,
      dynFloorG: floor,
      coverage: coverage,
      calibrated: calibrated,
    ),
    confidence: conf,
    tier: Tier.estimate,
    inputs_used: inputs,
    note: calibrated
        ? 'ESTIMATE: active minutes from gravity-removed 1 Hz amplitude vs your '
            'personal movement floor; steps = minutes × your measured cadence '
            '(${cadLow.round()}–${cadHigh.round()} spm) — 1 Hz cannot count steps'
        : 'ESTIMATE: active minutes from gravity-removed 1 Hz amplitude vs your '
            'personal movement floor; steps = minutes × the free-living cadence '
            'band (${cadLow.round()}–${cadHigh.round()} spm). Walk with the app '
            'open to measure your own cadence and narrow the range',
  );
}
