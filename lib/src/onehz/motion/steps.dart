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
//     foreground stream. It finds GAIT by stride periodicity (autocorrelation
//     at the stride lag) and counts steps from the measured cadence; see
//     [StepParams] for the algorithm and its OxWalk-measured accuracy. It
//     replaced an AN-2554-shaped peak counter that under-counted real walkers
//     by ~25%. Rhythmic arm work at a gait-like rhythm can still count — a
//     wrist |a| cannot separate it from walking. Directly testable: walk N
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

  static const PedometerResult none = PedometerResult(0, 0, 0, 0, 0);

  Map<String, dynamic> toJson() => {
        'steps': steps,
        'duration_s': round6(durationS),
        'cadence_spm': round6(cadenceSpm),
        'p2p_g': round6(peakToPeakG),
        'confidence': round6(confidence),
      };
}

/// WHAT THIS ALGORITHM IS — a gait-PERIODICITY counter, not a peak counter.
///
/// The previous counter (an AN-2554-shaped max/min peak search behind a 0.10 g
/// dead-zone and a CONFIRM=8 run gate) was scored against OxWalk — 39 adults,
/// unscripted free living, dominant-wrist AX3, camera-annotated heel strikes —
/// and measured MAPE 33.0%, only 5/39 within ±10%, and a uniform −25.4% on the
/// participants who actually walked. No setting of its knobs fixed that: every
/// `sens`/`confirm` that recovered the walkers also tripled-to-sextupled the
/// arm-work participants, because a peak detector cannot tell "regular wrist
/// bumps" from "regular wrist bumps while walking".
///
/// What separates them is STRIDE PERIODICITY. Walking repeats every stride
/// (two steps) with high fidelity; stirring, typing and gesturing mostly do
/// not. So, per 1 s segment, over the [winS]-second window centred on it:
///
///   1. band-pass |a| (two 0.1 s moving averages minus a 1 s one) and, above
///      [decimateAboveHz], block-average down to ~50 Hz. Accuracy is identical
///      at 50 and 100 Hz on OxWalk and the cost drops ~4×.
///   2. normalised autocorrelation over lags [lagLoS]..[lagHiS].
///   3. P = the SHORTEST autocorrelation peak in [peakLoS]..[peakHiS] within
///      [harmonic] of the strongest — the fundamental, not a multiple of it.
///   4. STEP OR STRIDE? At the wrist P is either the step period (|a| bobs
///      once per step) or the stride period (the arm swings once per stride).
///      On OxWalk walking windows the two populations do not overlap: step-P
///      sits at 0.47–0.63 s with the half-lag autocorrelation at −0.96…−0.55
///      (P/2 is anti-phase), stride-P at 0.94–1.27 s with the half-lag at
///      −0.38…+0.70 (P/2 is itself a step). So P ≥ [strideS], or a half-lag
///      above [halfAc], means stride and step = P/2; otherwise step = P. This
///      single decision was the difference between a cadence that was right
///      and one that read ×2 on ~30% of walking windows.
///   5. GAIT GATE: band-passed SD ≥ [ampG] and autocorrelation AT THE STRIDE
///      LAG (2 × step) ≥ [regHi], grown through neighbouring seconds that
///      clear [regLo] (hysteresis), and kept only as a run of ≥ [minRun]
///      consecutive seconds. Below 8 s nothing is credited.
///   6. COUNT = Σ segment seconds / step period over the gait seconds. Steps
///      come from the MEASURED cadence, never from counting individual peaks,
///      so one weak footfall cannot reset a run.
///
/// OxWalk, production chunking (60 s), raw counts, gain 1.00 — measured
/// 2026-10-23 with `tool/oxwalk_validate.dart`:
///
///   Wrist 100 Hz   MAPE 33.0% → 16.7%   within ±10%  5 → 21 of 39
///                  walkers (≥600 steps/h) bias −25.4% → −10.4%
///                  daily totals −19.8% → −7.3%
///   Wrist  50 Hz   MAPE 33.6% → 16.9%
///   Wrist  25 Hz   MAPE 91.9% → 17.3%   (was dead: the old constants were in
///                                        samples; these are in seconds)
///   Hip   100 Hz   MAPE 29.5% → 17.6%
///
/// LIMITS, stated rather than hidden:
///   * Rhythmic arm work at a gait-like rhythm still counts (OxWalk P28:
///     258 true steps, ~690 counted). Nothing on a wrist |a| separates it
///     from walking; the edge's activity-type gate is the defence.
///   * The step/stride decision runs first and [stepLoS]..[stepHiS]
///     (60–240 spm) is checked on its result. A sprint above 240 spm locks
///     onto its stride and reads HALF (the edge never lets the strap count
///     sprints). A slow signal is NOT dropped at 60 spm, see the next point.
///   * A wrist signal with ONLY a step fundamental slower than ~67 spm
///     (P ≥ [strideS]) is read as a stride and counted double, down to
///     ~37.5 spm (P = [peakHiS]); slower than that there is no peak in the
///     band and nothing is counted. On OxWalk that population is empty; on
///     synthetic signals it is not.
///
/// Every constant is in SECONDS, so the counter is rate-agnostic — the caller
/// must pass the buffer's REAL rate as `sampleRateHz`.
class StepParams {
  /// Default assembled IMU sample rate (Hz) for [pedometer]'s `sampleRateHz`.
  static const double fs = 100;

  static const double winS = 4.0; // autocorrelation window, centred
  static const double hopS = 1.0; // decision segment
  static const double decimateAboveHz = 50; // block-average down to ~50 Hz
  static const double lagLoS = 0.2;
  static const double lagHiS = 2.0;
  static const double peakLoS = 0.25;
  static const double peakHiS = 1.6;
  static const double harmonic = 0.8; // "within 80% of the best peak"
  static const double strideS = 0.9; // P at/above this is a stride
  static const double halfAc = -0.4; // half-lag above this ⇒ P is a stride
  static const double stepLoS = 0.25; // 240 spm
  static const double stepHiS = 1.0; // 60 spm
  static const double ampG = 0.04; // band-passed SD floor (g)
  static const double regHi = 0.6; // stride autocorrelation to START gait
  static const double regLo = 0.2; // ...to CONTINUE it (hysteresis)
  static const int minRun = 8; // consecutive gait seconds before crediting

  /// Per-user calibration trim. **Default 1.00, and it must stay 1.00 as a
  /// default** — a population fudge factor is not a calibration. It was once
  /// 1.11 and shipped a measured +10.6% over-count. Measure it against ground
  /// truth, per user, and store it with the user.
  static const double gain = 1.00;
}

/// Step count over ONE contiguous accelerometer-MAGNITUDE signal (g, gravity
/// INCLUDED) sampled at [sampleRateHz]. Raw count — no calibration gain. See
/// [StepParams] for the algorithm and its measured accuracy.
int pedometer(List<double> sig, {double sampleRateHz = StepParams.fs}) =>
    _gaitSteps(sig, sampleRateHz).round();

double _gaitSteps(List<double> sig, double sampleRateHz) {
  if (sig.isEmpty || !(sampleRateHz > 0)) return 0;
  var fs = sampleRateHz;
  // 1. band-pass, then decimate.
  final lp = _trailingMean(_trailingMean(sig, fs * 0.1), fs * 0.1);
  final hp = _trailingMean(lp, fs);
  var bp = <double>[for (var i = 0; i < lp.length; i++) lp[i] - hp[i]];
  final k = (fs / StepParams.decimateAboveHz).floor();
  if (k > 1) {
    bp = [
      for (var i = 0; i < bp.length; i += k)
        () {
          final end = math.min(i + k, bp.length);
          var s = 0.0;
          for (var j = i; j < end; j++) {
            s += bp[j];
          }
          return s / (end - i);
        }(),
    ];
    fs = fs / k;
  }
  final n = bp.length;
  final w = (StepParams.winS * fs).round();
  final h = math.max(1, (StepParams.hopS * fs).round());

  // 2-4. per-segment cadence + stride regularity.
  final segS = <double>[];
  final stepS = <double?>[];
  final ok = <bool>[];
  final reg = <double>[];
  for (var c = 0; c < n; c += h) {
    final segLen = math.min(h, n - c);
    var lo = math.max(0, c + segLen ~/ 2 - w ~/ 2);
    final hi = math.min(n, lo + w);
    lo = math.max(0, hi - w);
    final d = _decide(bp, lo, hi, fs);
    segS.add(segLen / fs);
    stepS.add(d.stepS);
    ok.add(d.stepS != null && d.sd >= StepParams.ampG);
    reg.add(d.strideAc);
  }

  // 5. gait gate with hysteresis, then the minimum run.
  final m = ok.length;
  final gait = [
    for (var i = 0; i < m; i++) ok[i] && reg[i] >= StepParams.regHi
  ];
  bool loose(int i) => ok[i] && reg[i] >= StepParams.regLo;
  for (var i = 1; i < m; i++) {
    if (!gait[i] && gait[i - 1] && loose(i)) gait[i] = true;
  }
  for (var i = m - 2; i >= 0; i--) {
    if (!gait[i] && gait[i + 1] && loose(i)) gait[i] = true;
  }

  // 6. steps = time / measured step period, over runs long enough to be gait.
  var steps = 0.0;
  var i = 0;
  while (i < m) {
    if (!gait[i]) {
      i++;
      continue;
    }
    var j = i;
    while (j + 1 < m && gait[j + 1]) {
      j++;
    }
    if (j - i + 1 >= StepParams.minRun) {
      for (var q = i; q <= j; q++) {
        steps += segS[q] / stepS[q]!;
      }
    }
    i = j + 1;
  }
  return steps;
}

/// Trailing moving average over round([w]) samples (shorter at the start).
List<double> _trailingMean(List<double> x, double w) {
  final taps = math.max(1, w.round());
  final out = List<double>.filled(x.length, 0);
  var acc = 0.0;
  for (var i = 0; i < x.length; i++) {
    acc += x[i];
    if (i >= taps) acc -= x[i - taps];
    out[i] = acc / math.min(i + 1, taps);
  }
  return out;
}

/// Cadence and stride regularity of `bp[lo, hi)`: the step period (s, or null
/// when the window has no gait-band periodicity), the window's SD, and the
/// autocorrelation at the stride lag (−1 when there is none).
({double? stepS, double sd, double strideAc}) _decide(
    List<double> bp, int lo, int hi, double fs) {
  final n = hi - lo;
  if (n <= 0) return (stepS: null, sd: 0.0, strideAc: -1.0);
  var mean = 0.0;
  for (var i = lo; i < hi; i++) {
    mean += bp[i];
  }
  mean /= n;
  final s = <double>[for (var i = lo; i < hi; i++) bp[i] - mean];
  // Prefix energies, so each lag's normalisation is O(1).
  final e = List<double>.filled(n + 1, 0);
  for (var i = 0; i < n; i++) {
    e[i + 1] = e[i] + s[i] * s[i];
  }
  final sd = math.sqrt(e[n] / n);
  const none = -1.0;
  final lagLo = (StepParams.lagLoS * fs).round();
  final lagHi =
      math.min((StepParams.lagHiS * fs).round(), n - (0.5 * fs).round());
  if (lagHi <= lagLo + 2 || sd <= 0) {
    return (stepS: null, sd: sd, strideAc: none);
  }
  final ac = List<double>.filled(lagHi + 1, double.nan);
  for (var l = lagLo; l <= lagHi; l++) {
    var dot = 0.0;
    for (var t = 0; t < n - l; t++) {
      dot += s[t] * s[t + l];
    }
    final den = math.sqrt(e[n - l] * (e[n] - e[l]));
    ac[l] = den > 0 ? dot / den : 0.0;
  }
  double acAt(int l) => (l >= lagLo && l <= lagHi) ? ac[l] : double.nan;

  final pLo = math.max((StepParams.peakLoS * fs).round(), lagLo + 1);
  final pHi = math.min((StepParams.peakHiS * fs).round(), lagHi - 1);
  final peaks = <int>[
    for (var l = pLo; l <= pHi; l++)
      if (ac[l] >= ac[l - 1] && ac[l] >= ac[l + 1]) l,
  ];
  if (peaks.isEmpty) return (stepS: null, sd: sd, strideAc: none);
  var best = ac[peaks.first];
  for (final l in peaks) {
    if (ac[l] > best) best = ac[l];
  }
  if (best <= 0) return (stepS: null, sd: sd, strideAc: none);
  final p = peaks.firstWhere((l) => ac[l] >= StepParams.harmonic * best);
  // Sub-sample peak: parabolic interpolation (a 20 ms lag grid is a ±2%
  // cadence error at 140-180 spm otherwise).
  final a0 = ac[p - 1], a1 = ac[p], a2 = ac[p + 1];
  final curv = a0 - 2 * a1 + a2;
  final pf = p + (curv < 0 ? 0.5 * (a0 - a2) / curv : 0.0);
  final half = (p / 2).round();
  final isStride = p / fs >= StepParams.strideS ||
      (half / fs >= StepParams.peakLoS && acAt(half) > StepParams.halfAc);
  final step = isStride ? pf / 2 : pf;
  final stepS = step / fs;
  if (stepS < StepParams.stepLoS || stepS > StepParams.stepHiS) {
    return (stepS: null, sd: sd, strideAc: none);
  }
  final r = acAt((2 * step).round());
  return (stepS: stepS, sd: sd, strideAc: r.isNaN ? none : r);
}

/// Daily total: [pedometer] over each per-minute contiguous magnitude signal,
/// summed and scaled by [StepParams.gain] (1.00 by default — see there).
///
/// Chunking costs little: each chunk's gait runs restart at its edges, so a
/// walk crossing a boundary can lose up to [StepParams.minRun] seconds on each
/// side only when a fragment is shorter than that. Measured on OxWalk wrist
/// 100 Hz, 60 s chunks cost −2.4% of the total vs one contiguous buffer.
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
  if (n < 2 || sampleRateHz <= 0) return PedometerResult.none;
  final mag = <double>[
    for (var i = 0; i < n; i++)
      math.sqrt(x[i] * x[i] + y[i] * y[i] + z[i] * z[i])
  ];
  final steps = pedometer(mag, sampleRateHz: sampleRateHz);
  final durationS = n / sampleRateHz;
  if (steps <= 0) return PedometerResult(0, durationS, 0, 0, 0);
  // Cadence over the buffer span. For a dedicated walk this is the walking
  // cadence; the gait gate guarantees any nonzero count came from a periodic
  // run of at least StepParams.minRun seconds, so confidence is high. peakToPeak is the magnitude range (motion strength).
  final cadence = durationS > 0 ? steps / (durationS / 60.0) : 0.0;
  var mn = mag.first, mx = mag.first;
  for (final v in mag) {
    if (v < mn) mn = v;
    if (v > mx) mx = v;
  }
  final conf = (cadence >= 60 && cadence <= 200 ? 0.85 : 0.5).clamp(0.0, 1.0);
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
  final q = percentile(xs, quantile.clamp(0.0, 1.0) * 100.0);
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
      if (m.nSamples >= minSamplesPerMinute &&
          m.dynAmp.isFinite &&
          m.dynAmp >= 0)
        m.dynAmp
  ];
  if (xs.length < minCoveredMinutes) return null;
  final q = percentile(xs, quantile.clamp(0.0, 1.0) * 100.0);
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
/// The note counts DAYS, against [requiredHistoryDays]. It used to count
/// them against [personalDynFloorMinMinutes] (2000) while every caller passed a
/// day count, so a user three days in was told `have=3,need=2000` — ~1997 more
/// of a unit nobody was measuring, for a metric that unlocks in two.
///
/// [requiredHistoryDays] must be the gate the caller actually applies before
/// it stops passing a null floor. It defaults to [enrollmentDaysForFrozenFloor]
/// because a caller that freezes the floor keeps it null until then; reporting
/// against [personalDynFloorMinDays] made days 5-13 read `have=9,need=5`, a
/// met gate on a metric that was still absent. A caller that uses the bare
/// [personalDynFloorFromDailySummaries] median passes that function's minimum.
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
  int requiredHistoryDays = enrollmentDaysForFrozenFloor,
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
      // With the history gate already met, a missing or unusable floor is
      // not a baseline shortfall; a met `need_baseline` note would read as
      // "unlocked" on a metric that is still absent.
      note: historyDaysAvailable < requiredHistoryDays
          ? needBaselineNote(
              have: historyDaysAvailable,
              need: requiredHistoryDays,
            )
          : 'no usable personal movement floor',
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
      ((motion.last.tsMinStartMs - motion.first.tsMinStartMs) / 60000).round() +
          1;
  final denom = expectedMinutes ?? spanMinutes;
  final coverage = denom <= 0 ? 0.0 : (covered / denom).clamp(0.0, 1.0);
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
  final conf = (0.30 * (coverage / 0.6).clamp(0.3, 1.0)).clamp(0.1, 0.30);

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
    note:
        'ESTIMATE: minutes of sustained wrist movement, measured against your '
        'personal movement floor. This is activity volume, NOT walking — at the '
        'wrist, arm work (cooking, dishes, driving) registers as strongly as '
        'walking does. It is deliberately not converted to a step count',
  );
}
