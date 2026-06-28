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
//   TIER B — [dailyStepEstimate]: a 24/7 ESTIMATE from the 1 Hz substrate. We
//     cannot count steps, but we CAN detect ambulatory MINUTES (ENMO in the
//     walking band, optionally confirmed by HR elevation) and multiply by a
//     cadence (steps/min). This is the only method the Nyquist ceiling permits:
//     bout-duration × cadence (Tudor-Locke 2011: free-living walking ≈ 100–120
//     steps/min). It is an ESTIMATE, never a count — tier is ESTIMATE.
//
//   CALIBRATION — [StepCalibration] / [calibrateCadence]: Tier A is also Tier
//     B's teacher. When live walking data exists we measure THIS user's real
//     cadence and the ENMO level it occurred at, and feed that back so the 24/7
//     estimate is personally tuned. The live path both stands alone AND makes
//     the estimate "kinda accurate" per-user.
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

/// A personal cadence model learned from live (100 Hz) walking, used to scale
/// the 1 Hz daily estimate. [cadenceSpm] is the user's measured walking cadence;
/// [refEnmo] is the 1 Hz ENMO level (g) observed during that same walking; [n]
/// counts the live windows folded in (more = more trusted).
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

/// Daily step ESTIMATE from the 1 Hz substrate (never a count — see file head).
class DailyStepEstimate {
  final int steps;
  final int ambulatoryMinutes;
  final double cadenceUsed; // representative steps/min applied
  final double coverage; // fraction of the day with valid motion data
  final bool calibrated; // personal cadence model was used
  const DailyStepEstimate(
    this.steps,
    this.ambulatoryMinutes,
    this.cadenceUsed,
    this.coverage,
    this.calibrated,
  );

  Map<String, dynamic> toJson() => {
        'steps': steps,
        'ambulatory_min': ambulatoryMinutes,
        'cadence_used_spm': round6(cadenceUsed),
        'coverage': round6(coverage),
        'calibrated': calibrated,
      };
}

/// Default uncalibrated free-living walking cadence (Tudor-Locke 2011).
const double defaultCadenceSpm = 110.0;

/// Default ENMO (g) we associate with that default cadence (wrist walking band).
const double defaultRefEnmoG = 0.06;

/// Minute ENMO ceiling (g): above this is vigorous/non-walking arm motion
/// (shaking, lifting, sport) — counted toward activity elsewhere, not steps.
const double ambulatoryEnmoCeilingG = 0.40;

/// Default FIXED movement gate (g) when uncalibrated — above resting 1 Hz noise
/// (~0.05) but below typical walking. Calibration replaces it with refEnmo·0.5.
const double defaultWalkFloorG = 0.05;

/// Per-minute cadence regression coefficients (steps/min), literature ballpark
/// (Tudor-Locke baseline + movement & HR terms). `cadence = C0 + Cm·ENMO_g +
/// Chr·(HR−RHR)`, clamped to a physiological band. Calibration re-centres C0.
const double kStepC0 = 85.0;
const double kStepCm = 220.0;
const double kStepChr = 0.40;

/// 1 Hz STEP ESTIMATE (the only step method that survives the Nyquist ceiling).
///
/// We can't peak-count gait at 1 Hz (1.4–2.5 Hz aliases past 0.5 Hz), so we
/// detect WALKING minutes from the accel amplitude and multiply by a cadence —
/// the standard sub-Nyquist pedometry method. Walking detection is self-calibrated
/// + HR-corroborated + bout-gated so it CANNOT inflate (the old fixed 0.02 g floor
/// counted resting noise → ~100k/day):
///   • a minute is "ambulatory" only if its ENMO clears the day's OWN sedentary
///     baseline (p30 + 2·MAD, floored at +0.015 g) and ≤ the vigorous ceiling,
///   • AND (when HR is present) sits above the day's resting HR + [hrMarginBpm]
///     (resting = supplied RHR, else the day's 10th-percentile HR),
///   • AND belongs to a run of ≥[minBoutMin] consecutive ambulatory minutes.
/// Then steps = Σ ambulatory-minutes × cadence, where cadence is the personal
/// model ([calib]) or a default, scaled gently by intensity and clamped to a
/// physiological band. Tier is always ESTIMATE.
///
/// IMPORTANT (no double-count): the caller must pass ONLY minutes NOT covered by
/// the live 100 Hz pedometer — 100 Hz steps are real and always preferred for the
/// time they cover. This function never sees those minutes.
Metric<DailyStepEstimate> dailyStepEstimate(
  List<MotionMinute> motion, {
  List<double>? hrPerMin,
  double? restingHr,
  StepCalibration? calib,
  double hrMarginBpm = 8.0,
  double minSamplesPerMinute = 30,
}) {
  const inputs = ['enmo_per_min', 'hr_per_min', 'cadence_calibration'];
  if (motion.isEmpty) {
    return const Metric<DailyStepEstimate>.absent(
      tier: Tier.estimate,
      inputs_used: inputs,
      note: 'no motion minutes',
    );
  }

  final baseCadence = calib?.cadenceSpm ?? defaultCadenceSpm;
  final refEnmo =
      (calib != null && calib.refEnmo > 0) ? calib.refEnmo : defaultRefEnmoG;

  // Covered minutes only — sparse minutes can't be judged.
  final idx = <int>[];
  final enmos = <double>[];
  for (var i = 0; i < motion.length; i++) {
    if (motion[i].nSamples >= minSamplesPerMinute) {
      idx.add(i);
      enmos.add(motion[i].enmo);
    }
  }
  final covered = idx.length;
  final coverage = covered / motion.length;
  final calibrated = calib != null && calib.n >= 3;
  if (covered < 4) {
    return Metric<DailyStepEstimate>(
      value: DailyStepEstimate(0, 0, baseCadence, coverage, calibrated),
      confidence: 0.15,
      tier: Tier.estimate,
      inputs_used: inputs,
      note: 'too few covered minutes to estimate steps',
    );
  }

  // FIXED gate + CONTINUOUS cadence (the ChatGPT-style multi-signal regression).
  // We do NOT peak-count (Nyquist) and we do NOT use a per-day relative threshold
  // (that self-suppressed on active days → the over/under whipsaw). A minute is
  // "walking" by a STABLE gate — movement above a fixed floor AND HR lifted off
  // rest — and within walking minutes the cadence scales continuously with
  // movement + HR excess. Calibration tightens the floor + re-centres cadence to
  // the user; uncalibrated runs a sensible ballpark (refined after a real walk).
  final moveFloor =
      (calibrated && refEnmo > 0) ? refEnmo * 0.5 : defaultWalkFloorG;

  final useHr = hrPerMin != null && hrPerMin.length == motion.length;
  double restHr = restingHr ?? 0;
  if (useHr && restingHr == null) {
    final hrs = [for (final h in hrPerMin) if (h > 0) h];
    if (hrs.length >= 10) restHr = percentile(hrs, 10)!;
  }
  final hrGate = restHr + hrMarginBpm; // HR must be lifted off rest to count

  // Re-centre the cadence intercept on the personal cadence when calibrated
  // (default 110 → C0 85, the literature baseline).
  final c0 = calibrated ? (baseCadence - 25.0) : kStepC0;

  var steps = 0.0;
  var ambMin = 0;
  final cadences = <double>[];
  for (var k = 0; k < idx.length; k++) {
    final i = idx[k];
    final m = enmos[k];
    if (m <= moveFloor || m > ambulatoryEnmoCeilingG) continue; // not walking
    final hr = useHr ? hrPerMin[i] : 0.0;
    if (useHr && restHr > 0 && hr > 0 && hr < hrGate) continue; // HR at rest → skip
    final hrExcess = (useHr && hr > 0) ? math.max(hr - restHr, 0.0) : 0.0;
    final cad = clamp(c0 + kStepCm * m + kStepChr * hrExcess, 70.0, 170.0);
    steps += cad; // one minute of this cadence
    cadences.add(cad);
    ambMin++;
  }

  final cadenceUsed = mean(cadences) ?? baseCadence;
  final conf = clamp(
    (calibrated ? 0.55 : 0.35) * clamp(coverage / 0.6, 0.3, 1.0),
    0.1,
    0.7,
  );

  return Metric<DailyStepEstimate>(
    value: DailyStepEstimate(
        steps.round(), ambMin, cadenceUsed, coverage, calibrated),
    confidence: conf,
    tier: Tier.estimate,
    inputs_used: inputs,
    note: calibrated
        ? 'ESTIMATE: per-minute cadence (movement + HR) over walking minutes, '
            'personalized — 1 Hz cannot count steps directly'
        : 'ESTIMATE: per-minute cadence (movement + HR); walk with the app open '
            'on open ground to calibrate to your stride',
  );
}
