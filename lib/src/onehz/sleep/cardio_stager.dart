// SLEEP — transparent cardiorespiratory stager (NO ML).
//
// Replaces the Walch 2019 logistic model. Rationale (validated on real data):
//   • Walch over-calls WAKE — its motion-`count` feature carries a +10.64 wake
//     weight, so normal in-sleep repositioning flips epochs to wake (a solid
//     night read 63% efficiency).
//   • Walch needs a 50 Hz band-pass activity count we CANNOT compute at 1 Hz —
//     we fed an ENMO substitute, a train/serve mismatch baked in.
//   • Walch IGNORES beat-to-beat RR — our single best signal. Sleep stages have
//     a textbook autonomic signature in HR + HRV; we should use it.
//
// This stager is fully transparent: every label traces to a threshold on a real
// signal, z-scored against the SLEEPER'S OWN night baseline (no population model,
// no training). Published basis: Webster/Cole-Kripke actigraphy (wake) + HRV-
// based cardiorespiratory staging (REM = autonomic activation w/ low RMSSD;
// NREM = parasympathetic, high RMSSD; deep = HR/HRV trough).
//
// Per 30-s epoch we measure, over the in-bed window only:
//   motion = mean ENMO (van Hees 2013 amplitude index, g), against a LOCALLY
//            re-estimated 1 g reference (see below), NOT a whole-night scalar
//   hr     = mean valid HR (bpm)          hrSd = within-epoch SD of HR (bpm)
//   rmssd, sdnn = over a ±2.5-min RR window (ms)
//   lfhf, Rk    = over a ±90-s RR window
// then classify against the night's own baselines:
//   WAKE  : clearly elevated motion OR HR arousal above a LOCAL sleeping HR
//           median (a 90-min rolling window, not the whole night)
//   REM   : weighted score over Rk / sdnn / hrSd / lfhf above a cutoff, GATED
//           by atonia (no big movement) and HR ≥ a LOCAL p25 floor
//   DEEP  : weighted score over the same axes in the opposite direction
//           (NREM subtype, low confidence)
//   LIGHT : remaining NREM
//
// 2026-08 — WHY SCORES, NOT CONJUNCTIONS, AND WHY NOT RMSSD. The rules above
// replace an earlier design that AND-ed boolean gates and used an RMSSD drop as
// the PRIMARY REM detector. Measured against 99 PSG-labelled wrist nights
// (DREAMT) via `tool/stager_harness.dart`, that design scored kappa 0.036 —
// deep PPV 5.7% against a 4.5% base rate, REM PPV 12.1% against 14.0%, i.e. at
// or below chance for both minority classes. Per-subject effect sizes explain
// why: RMSSD did not separate the stages in our measurement (54% of subjects,
// d -0.02) — BUT SEE THE NEXT PARAGRAPH, that number is probably wrong — mean
// HR in deep sleep runs
// HIGHER than light on the wrist (62% of subjects, d +0.31 — the old gate was
// inverted), and the two axes that DO separate (Rk d -0.53/+0.43, sdnn
// -0.41/+0.32) were respectively throttled to z>4 and not computed at all.
// AND-ing one good gate with one null and one inverted gate is why deep sleep
// emerged as isolated 30-second specks that the 3-min bout rule then deleted.
// A weighted sum degrades gracefully where a conjunction vetoes.
//
// THE RMSSD d -0.02 IS PROBABLY WRONG, AND IT IS NOT HERZIG'S FAULT (SLP-06).
// R(k) is defined below as mean |ΔIHR| over the window — a successive-difference
// statistic on the SAME beat train RMSSD uses, differing only by the 1/RR²
// rescaling and mean-abs vs RMS. Measured on three real rest blocks at the
// windows this file actually uses (R(k) ±90 s, RMSSD ±150 s) they correlate
// 0.876 / 0.778 / 0.778; at a matched ±90 s, 0.928 / 0.853 / 0.856. And
// corr(R(k), mean HR) is 0.065 / 0.282 / -0.341, so R(k) is not a disguised
// heart-rate feature either. Two statistics correlated 0.78-0.93 on the target
// signal cannot both score d -0.02 and d -0.53 against the same labels; under a
// bivariate-normal argument RMSSD should be at least ~0.4 in the same
// direction. So the local DREAMT effect-size measurement for RMSSD is
// unreliable and Herzig 2017 is currently lending its authority to it.
// TODO: re-run the DREAMT effect size for RMSSD at ±90 s and publish both
// numbers side by side. DO NOT move the shipped weights on the strength of
// this — it says the measurement is untrustworthy, not which way it moves.
// Post: Webster continuity rescore (bridges brief arousals into sleep — this is
// what kills the over-call) + consolidateSleepStages (no single-epoch flicker).
//
// LOCAL vs WHOLE-NIGHT baselines (2026-07, real-data root cause): a real WHOOP-4
// capture showed BOTH the motion and HR features have night-scale
// non-stationarity a single whole-night scalar cannot track — see the detailed
// comments at each baseline below (gravity-magnitude posture drift; sleep-onset
// HR-decay transient; REM's own periodic-elevation self-dilution of a local
// median). Motion's still/bigMove REPOSITIONING thresholds remain whole-night
// scalars deliberately — only the ABSOLUTE-MAGNITUDE references (1 g; sleeping
// HR) needed to become local.
//
// HONESTY: a wrist 3-class (+low-confidence deep) ESTIMATE, never PSG/EEG.
// tier ESTIMATE; confidence reflects RR coverage (RMSSD drives REM/deep).

import 'dart:math' as math;
import '../types.dart';
import '../util.dart';
import 'accounting.dart' show SleepStage;
import 'stager.dart' show StagerResult, consolidateSleepStages;

/// Result: the standard [StagerResult] (W/NREM/REM) + a per-epoch deep flag
/// (deep is an NREM subtype — LOW CONFIDENCE; meaningless for non-NREM epochs).
class CardioStagerResult {
  final StagerResult base;
  final List<bool> deepFlag;
  final double confidence;
  const CardioStagerResult(this.base, this.deepFlag, this.confidence);
}

const int _epochSec = 30;

/// Minimum fraction of epochs that must carry a valid HR before this stager
/// will label anything. Below it every HR-relative gate is silent and the
/// classifier degenerates to "all light sleep" — see the gate in
/// [classifyCardioEpochs].
const double minHrCoverage = 0.5;

// The previous rule OR-ed three boolean axes (RMSSD drop as PRIMARY, plus
// LF/HF and R(k) throttled to z>4.0) and was calibrated against a single
// Apple-Watch-labelled night. Measurement against 99 PSG-labelled wrist nights
// showed the primary axis was at chance and the two throttled axes were the
// informative ones; see the weighted-score block in [classifyCardioEpochs].

// ── Stage-score axis weights ────────────────────────────────────────────────
// These are MEASURED Cohen's d values (DREAMT, 99 PSG-labelled wrist nights,
// per-subject within-night z-scored), not tuned parameters. Under equal
// variance an LD's optimal weights are proportional to d, so the effect size
// IS the weight. Only the two decision cutoffs below are calibrated, on a
// locked development split.
const double _wRemRk = 0.43;
const double _wRemSdnn = 0.32;
const double _wRemHrSd = 0.27;
const double _wRemLfhf = 0.12;

const double _wDeepRk = 0.53;
const double _wDeepHrSd = 0.43;
const double _wDeepSdnn = 0.41;
const double _wDeepLfhf = 0.33;

/// Decision cutoffs on the weighted robust-z stage scores.
///
/// The WEIGHTS above come from DREAMT (PSG ground truth) because that is what
/// an external corpus can tell us: which axes carry stage information, and in
/// which direction. The CUTOFFS cannot come from there. They sit on a score
/// whose spread depends on OUR feature extraction, and the DREAMT-optimal
/// values do not transfer: at remCut 0.8 DREAMT yields a normative ~23% REM
/// while real WHOOP captures yield 10.3%, and the same night the Apple-Watch
/// reference put at ~162 min REM came out at 62 min. Calibrating cutoffs on a
/// different sensor's feature distribution is exactly the train/serve mismatch
/// this file's header criticises Walch for.
///
/// So the cutoffs are swept on REAL DEVICE CAPTURES
/// (`tool/whoop_proportions.dart`, 11 nights) and chosen to land the stage
/// proportions in the normative population range — REM 20-25% of TST, Deep
/// 13-23% of TST (Mitterling 2015 percentile curves; Boulos 2019
/// meta-regression, N=5,273, AASM scoring):
///
///   remCut   median %REM of TST        deepCut   median %Deep of TST
///     0.4          28.5%                  0.2           17.6%
///     0.5          23.6%  <- chosen       0.3           14.9%  <- chosen
///     0.6          18.6%                  0.4           11.9%
///     0.8          ~10%   (DREAMT opt)
///
/// NOT calibrated to maximise kappa, on purpose. On the DREAMT dev split kappa
/// rises monotonically as deep is suppressed:
///
///   deepCut   %Deep called   Deep sens   Deep PPV   kappa
///     0.3         14.9%        50.8%      15.0%     0.125
///     0.6          4.8%        22.2%      20.4%     0.148
///     1.0          0.3%         2.3%      31.0%     0.151   <- kappa optimum
///
/// That is arithmetic on a sleep-clinic cohort where deep is only 4.5% of
/// asleep epochs, not physiology, and shipping the kappa optimum would recreate
/// the "user sees ~0 deep sleep" defect this change exists to fix.
///
/// Held-out result at the shipped cutoffs (49 unseen subjects): kappa 0.132,
/// Deep 56.0% sens / 10.9% PPV, REM 51.9% / 21.5%, against base rates of 4.5%
/// Deep and 14% REM — so both minority classes are called well above chance
/// where the previous rules sat at or below it. The bulk of what remains is the
/// WAKE rule (11% sensitivity), untouched by this change.
///
/// THE COMPARATOR (SLP-08). The honest one is the consumer-device range in
/// `segment.dart`'s [kMaxSleepConfidence] — κ 0.21-0.53 on wrist devices vs PSG
/// — which we are BELOW, the vendor firmware on this very band scoring 0.37.
/// This used to measure itself against a "0.60-0.66 literature ceiling". That
/// is Radha et al. 2021 (npj Digital Medicine 4), four-class κ 0.65 ± 0.11,
/// accuracy 76.4 ± 7.6 %, from a deep recurrent network PRETRAINED ON 584 ECG
/// RECORDINGS and transfer-learned to 101 CONTINUOUS WRIST-PPG recordings with
/// beat-to-beat intervals at native sampling resolution. It is the ceiling for
/// continuous-PPG deep models, not for rules on our substrate: `rr_ts_ms` is
/// `rec_ts * 1000` on 100 % of rows, RR is band-saturated at [333, 2400],
/// 3.2-11.8 % of beats in a rest block share a timestamp with another beat,
/// coverage runs 78.5-92.9 %, and there is no PPG waveform in the database at
/// all. Quoting it as a ceiling made 0.132 look like a gap to close rather than
/// a different problem. Reaching 0.65 needs a continuous PPG or true beat
/// timestamps — a protocol/edge change, not a stager change.
///
/// HONESTY: proportion-matching is distributional plausibility, NOT accuracy.
/// It says the hypnogram has a believable shape, not that any given epoch is
/// right. Only concurrent PSG on this device can settle that, and we do not
/// have it.
const double _remScoreCut = 0.5;
const double _deepScoreCut = 0.3;

/// The shipped cutoffs, exposed so calibration tooling reports what actually
/// ships instead of re-declaring its own defaults and silently drifting.
const double kDefaultRemScoreCut = _remScoreCut;
const double kDefaultDeepScoreCut = _deepScoreCut;

/// Physiologic RR gate (project rule): keep 300–2000 ms; drop successive jumps
/// > 200 ms (ectopy / artifact). Used per-window before RMSSD.
const double _rrMin = 300, _rrMax = 2000, _rrMaxStep = 200;

/// PER-USER rolling sleep profile — the "gets better over time" personalization.
///
/// The generic-ML experiment lost badly to this stager's PER-NIGHT LOCAL
/// baselines (a DREAMT-trained model over-called Wake by 100+ min and read
/// ~0 Deep on 3 real nights — between-person variance kills generic models).
/// So the direction is MORE personalization, not less: persist the SLEEPER'S
/// OWN typical sleep signatures across nights and blend them (bounded, never
/// dominant) with tonight's per-night-local baselines.
///
/// Storage: edge `baselines` table, key `sleep_user_profile`, one JSON payload,
/// folded via EWMA (~14-night horizon) after each finalized night. Blend weight
/// grows from 0 (cold start) to a hard 0.5 cap as nights accumulate
/// ([personalWeight]) — a single stored profile can NEVER outvote tonight's own
/// signal, preserving the per-night-local behavior that won the head-to-head.
///
/// All fields nullable: absent ⇒ no personalization on that axis (honesty
/// contract — never fabricate a baseline we don't have).
class SleepUserProfile {
  final int nights; // finalized nights folded so far (drives [personalWeight])
  final double? hrFloorP5; // sleeping-HR 5th pct (bpm) — deep-sleep floor
  final double? hrFloorP25; // sleeping-HR 25th pct (bpm) — REM HR gate
  final double? hrSleepMedian; // sleeping-HR median (bpm)
  final double? hrArousal; // typical arousal/wake HR threshold (bpm)
  final double? rmssdMed; // sleeping RMSSD median (ms)
  final double? rmssdMad; // sleeping RMSSD MAD (ms)
  final double? enmoStillCut; // still/repositioning ENMO cut (g)
  final double? enmoMoveCut; // big-move ENMO cut (g)
  final double? lfhfMed; // sleeping LF/HF median
  final double? rkMed; // sleeping |ΔIHR| median (bpm)
  final int updatedAtMs;

  const SleepUserProfile({
    this.nights = 0,
    this.hrFloorP5,
    this.hrFloorP25,
    this.hrSleepMedian,
    this.hrArousal,
    this.rmssdMed,
    this.rmssdMad,
    this.enmoStillCut,
    this.enmoMoveCut,
    this.lfhfMed,
    this.rkMed,
    this.updatedAtMs = 0,
  });

  /// Personal-vs-local blend weight: 0 at cold start → 0.5 hard cap at ≥14
  /// nights (so per-night-local always holds ≥50% of every threshold).
  double get personalWeight => clamp(nights / 28.0, 0.0, 0.5);

  static double? _d(dynamic v) => (v is num) ? v.toDouble() : null;

  factory SleepUserProfile.fromJson(Map<String, dynamic> j) => SleepUserProfile(
        nights: (j['nights'] as num?)?.toInt() ?? 0,
        hrFloorP5: _d(j['hr_floor_p5']),
        hrFloorP25: _d(j['hr_floor_p25']),
        hrSleepMedian: _d(j['hr_sleep_median']),
        hrArousal: _d(j['hr_arousal']),
        rmssdMed: _d(j['rmssd_med']),
        rmssdMad: _d(j['rmssd_mad']),
        enmoStillCut: _d(j['enmo_still_cut']),
        enmoMoveCut: _d(j['enmo_move_cut']),
        lfhfMed: _d(j['lfhf_med']),
        rkMed: _d(j['rk_med']),
        updatedAtMs: (j['updated_at_ms'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() => {
        'nights': nights,
        if (hrFloorP5 != null) 'hr_floor_p5': hrFloorP5,
        if (hrFloorP25 != null) 'hr_floor_p25': hrFloorP25,
        if (hrSleepMedian != null) 'hr_sleep_median': hrSleepMedian,
        if (hrArousal != null) 'hr_arousal': hrArousal,
        if (rmssdMed != null) 'rmssd_med': rmssdMed,
        if (rmssdMad != null) 'rmssd_mad': rmssdMad,
        if (enmoStillCut != null) 'enmo_still_cut': enmoStillCut,
        if (enmoMoveCut != null) 'enmo_move_cut': enmoMoveCut,
        if (lfhfMed != null) 'lfhf_med': lfhfMed,
        if (rkMed != null) 'rk_med': rkMed,
        'updated_at_ms': updatedAtMs,
      };

  /// EWMA-fold one finalized night's observation into the profile, returning
  /// the updated copy. Alpha eases from 1.0 (first night — take it whole) toward
  /// a `2/(N+1)` floor (a ~[horizonNights]-night trailing memory), so cold start
  /// adapts fast and settled profiles track the recent few weeks. A null
  /// observed field leaves that axis untouched.
  SleepUserProfile fold(SleepNightObservation o, {int horizonNights = 14}) {
    // horizonNights <= 0 makes the 2/(N+1) alpha floor >= 1 (or divide-by-zero /
    // negative), which over-weights the newest night and corrupts the EWMA.
    assert(horizonNights > 0, 'horizonNights must be positive');
    final n2 = nights + 1;
    final a = math.max(1.0 / n2, 2.0 / (horizonNights + 1));
    double? ew(double? old, double? obs) =>
        obs == null ? old : (old == null ? obs : old * (1 - a) + obs * a);
    return SleepUserProfile(
      nights: n2,
      hrFloorP5: ew(hrFloorP5, o.hrFloorP5),
      hrFloorP25: ew(hrFloorP25, o.hrFloorP25),
      hrSleepMedian: ew(hrSleepMedian, o.hrSleepMedian),
      hrArousal: ew(hrArousal, o.hrArousal),
      rmssdMed: ew(rmssdMed, o.rmssdMed),
      rmssdMad: ew(rmssdMad, o.rmssdMad),
      enmoStillCut: ew(enmoStillCut, o.enmoStillCut),
      enmoMoveCut: ew(enmoMoveCut, o.enmoMoveCut),
      lfhfMed: ew(lfhfMed, o.lfhfMed),
      rkMed: ew(rkMed, o.rkMed),
      updatedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
  }
}

/// One night's observed sleep baselines, emitted by [cardioStager] for folding
/// into a [SleepUserProfile]. [epochs] = staged epoch count (lets the caller
/// pick the MAIN sleep among a night's sessions/naps, and reject short naps).
class SleepNightObservation {
  final int epochs;
  final double? hrFloorP5;
  final double? hrFloorP25;
  final double? hrSleepMedian;
  final double? hrArousal;
  final double? rmssdMed;
  final double? rmssdMad;
  final double? enmoStillCut;
  final double? enmoMoveCut;
  final double? lfhfMed;
  final double? rkMed;
  const SleepNightObservation({
    required this.epochs,
    this.hrFloorP5,
    this.hrFloorP25,
    this.hrSleepMedian,
    this.hrArousal,
    this.rmssdMed,
    this.rmssdMad,
    this.enmoStillCut,
    this.enmoMoveCut,
    this.lfhfMed,
    this.rkMed,
  });
}

/// Ambient per-user profile used by [cardioStager] when no explicit
/// `userProfile` arg is passed. Lets the edge derivation set it ONCE before
/// running `segmentSleep` (which calls `cardioStager` deep inside
/// `AdvancedSleepStager` with no param seam of its own). Single-isolate,
/// synchronous-scope use only.
SleepUserProfile? cardioUserProfile;

/// When true, [cardioStager] appends one [SleepNightObservation] per run to an
/// internal buffer. The edge sets this before a night's staging and reads the
/// buffer with [takeCardioObservations] afterward to fold the MAIN sleep.
bool cardioRecordObservations = false;
final List<SleepNightObservation> _cardioObservations =
    <SleepNightObservation>[];

/// Drain and clear the recorded observations (returns a copy).
List<SleepNightObservation> takeCardioObservations() {
  final c = List<SleepNightObservation>.of(_cardioObservations);
  _cardioObservations.clear();
  return c;
}

/// Clear the observation buffer without reading it.
void resetCardioObservations() => _cardioObservations.clear();

/// Transparent cardiorespiratory stager.
///
/// [hr1hz] HR (bpm; 0 = off-skin) over the in-bed window, one entry per accel
///   sample. [accel] gravity vectors carrying their ABSOLUTE times, SAME
///   length/time base as [hr1hz]. The sampling cadence is MEASURED from
///   `accel[i].tsMs` ([sampleCadenceSeconds]) and the [epochSec] grid is laid
///   out in real seconds on top of it; a stream with no measurable cadence, or
///   one coarser than a single epoch, ABSTAINS (see [_abstain]).
/// [rrMs] / [rrTsMs] beat-to-beat RR (ms) and their ABSOLUTE times (ms), same
///   clock as `accel[i].tsMs`, ASCENDING in [rrTsMs] (the per-epoch window
///   gather lower-bounds into it). Sparse/empty is fine — REM/deep just lean
///   more on HR and confidence drops.
CardioStagerResult cardioStager(
  List<double> hr1hz,
  List<AccelSample> accel, {
  List<double> rrMs = const [],
  List<double> rrTsMs = const [],
  int epochSec = _epochSec,
  SleepUserProfile? userProfile,
  double remScoreCut = _remScoreCut,
  double deepScoreCut = _deepScoreCut,
}) {
  // Explicit arg wins (unit tests); else the ambient profile the edge set for
  // this staging pass; else null ⇒ pure per-night-local (cold-start behavior).
  final profile = userProfile ?? cardioUserProfile;
  // `_cleanBeatsInWindow` binary-searches this, so it has to be non-decreasing.
  // The producer guarantees it — beats inherit their record's second and the
  // records are sorted, and the one path that folds in loose live beats
  // re-sorts the pair explicitly. An `assert` rather than a linear fallback:
  // a fallback would pay the scan back on every window to insure against a
  // state the caller cannot reach, whereas this is free in release and loud in
  // every test the moment somebody builds an unsorted series.
  assert(() {
    for (var i = 1; i < rrTsMs.length; i++) {
      if (rrTsMs[i] < rrTsMs[i - 1]) return false;
    }
    return true;
  }(), 'rrTsMs must be non-decreasing — the beat window is binary-searched');
  final n = math.min(hr1hz.length, accel.length);
  // ── REAL-TIME epoch grid ──────────────────────────────────────────────────
  // `n ~/ epochSec` conflated ARRAY POSITIONS with SECONDS. At 1 Hz they are
  // the same number and everything below is unchanged; off 1 Hz they are not,
  // and the failure was not an accuracy one — a 300 s band gave
  // `96 ~/ 30 = 3` "epochs" of 2.5 REAL HOURS each, which the 30-s-tuned rules
  // labelled NREM end to end and published as `wakePct = 0.0`: a night this
  // stager could not read, reported as zero wake. No new parameter is needed
  // for the fix — `accel[i].tsMs` is already the clock `_cleanBeatsInWindow`
  // binary-searches, so the cadence is measurable from the input we have.
  final cadenceSec =
      sampleCadenceSeconds([for (var i = 0; i < n; i++) accel[i].tsMs / 1000.0]);
  // Coarser than one sample per epoch ⇒ there is no 30-s epoch to score, and
  // the Webster/Cole-Kripke continuity rules below are specified at this epoch
  // length. Stretching `epochSec` to fit the device would make a number appear
  // where the evidence for it does not; abstain instead.
  if (cadenceSec == null || cadenceSec > epochSec) return _abstain(epochSec);
  final perEpoch = math.max(1, (epochSec / cadenceSec).round());
  // `perEpoch` samples at this cadence must actually SPAN `epochSec` — a
  // cadence that does not divide it evenly (4 s against a 30 s epoch rounds
  // `perEpoch` to 8, an 8 * 4 = 32 s epoch) drifts the real grid against the
  // reported one. `epochSec` is not just a label: it is what the result
  // reports (`CardioStagerResult.epochSec`) and what `consolidateSleepStages`
  // / `_websterRescore` / `_mergeShortDeep` derive the Webster and bout
  // thresholds from below, and the drift accumulates over the whole night.
  // Abstain rather than publish a grid whose real spacing does not match its
  // own label.
  if ((perEpoch * cadenceSec - epochSec).abs() > 1e-6) return _abstain(epochSec);
  final nEpoch = n ~/ perEpoch;
  if (nEpoch < 3) return _abstain(epochSec);

  // ── per-second ENMO (motion) against a LOCALLY-ADAPTIVE 1 g reference ──────
  // A single whole-night gravity-magnitude reference (the old approach) is
  // wrong on real WHOOP-4 units: the decoded gravity vector's magnitude is NOT
  // perfectly orientation-invariant (per-axis gain/calibration isn't exact),
  // so different STATIC sleep postures can read meaningfully apart in |accel|
  // even though nothing is moving. Verified on a real overnight capture: a
  // person lying rock-still for 30+ min (within-epoch stddev of |accel| <
  // 0.0003 g) read |accel| = 1.0512 g against that whole-night's calibrated
  // reference of 1.0348 g — a 0.0167 g "motion" score, ~3x the bigMove
  // threshold, purely from holding a different (but equally static) posture
  // than whichever one the night happened to calibrate against. Across that
  // night, 389 of 421 "big move" epochs (92%) were this exact artifact (tiny
  // within-epoch variance, large offset from the single global reference),
  // not real movement — and the resulting misclassified WAKE blocks could not
  // be fully bridged back by Webster rescore below. Recomputing the reference
  // locally (a window wide enough to not react to real short movement bouts,
  // narrow enough to track a genuine posture change within a few minutes)
  // absorbs each posture as its own baseline instead of misreading it as
  // sustained motion.
  final mag = List<double>.filled(n, 0);
  for (var i = 0; i < n; i++) {
    final a = accel[i];
    mag[i] = math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z);
  }
  const int _gRefWinSec = 300; // 5 min window, centered per epoch
  // …in SAMPLES at the measured cadence. 300 at 1 Hz, unchanged.
  final gRefHalf = math.max(1, (_gRefWinSec / cadenceSec).round()) ~/ 2;
  final gRefByEpoch = List<double>.filled(nEpoch, 1.0);
  for (var e = 0; e < nEpoch; e++) {
    final es = e * perEpoch;
    final lo = math.max(0, es - gRefHalf);
    final hi = math.min(n, es + perEpoch + gRefHalf);
    gRefByEpoch[e] = median(mag.sublist(lo, hi)) ?? 1.0;
  }

  // ── per-epoch features ─────────────────────────────────────────────────────
  final motion = List<double>.filled(nEpoch, 0);
  final hr = List<double>.filled(nEpoch, double.nan);
  final hrSd = List<double>.filled(nEpoch, 0);
  final rmssd = List<double>.filled(nEpoch, double.nan);
  final sdnn = List<double>.filled(nEpoch, double.nan);
  // REM autonomic features (P1): LF/HF from the RR spectrum + R(k) = rolling
  // mean |ΔIHR|. REM's signature at 1 Hz beat-timing is a SYMPATHETIC shift —
  // LF/HF rises, RR variability drops (low RMSSD), and instantaneous HR gets
  // "jittery" (elevated |ΔIHR|). The old REM rule leaned only on the RMSSD drop
  // and under-called REM; these two independent axes recover it (OR-combined
  // below), gated by atonia + an HR floor so a plain arousal is not miscalled.
  final lfhf = List<double>.filled(nEpoch, double.nan);
  final rk = List<double>.filled(nEpoch, double.nan);

  for (var e = 0; e < nEpoch; e++) {
    final s = e * perEpoch, t = math.min(s + perEpoch, n);
    // motion = mean ENMO over the epoch, against THIS epoch's local reference.
    final gRefE = gRefByEpoch[e];
    var ms = 0.0;
    for (var i = s; i < t; i++) {
      final d = mag[i] - gRefE;
      ms += d > 0 ? d : 0.0;
    }
    motion[e] = ms / (t - s);
    // hr mean/sd over valid (>0) seconds
    final hv = <double>[
      for (var i = s; i < t; i++)
        if (hr1hz[i] > 0) hr1hz[i]
    ];
    if (hv.isNotEmpty) hr[e] = mean(hv)!;
    if (hv.length >= 2) hrSd[e] = stddev(hv) ?? 0;
    // rmssd over RR beats within a ±2.5-min window centred on the epoch
    rmssd[e] = _windowRmssd(rrMs, rrTsMs, accel, s, t, epochSec);
    sdnn[e] = _windowSdnn(rrMs, rrTsMs, accel, s, t, epochSec);
    // LF/HF + R(k) over a ±90-s RR window centred on the epoch.
    final rem = _windowRemFeatures(rrMs, rrTsMs, accel, s, t, epochSec);
    if (rem.lfhf != null) lfhf[e] = rem.lfhf!;
    if (rem.rk != null) rk[e] = rem.rk!;
  }

  return classifyCardioEpochs(
    CardioEpochFeatures(
      motion: motion,
      hr: hr,
      hrSd: hrSd,
      rmssd: rmssd,
      lfhf: lfhf,
      rk: rk,
      sdnn: sdnn,
    ),
    epochSec: epochSec,
    userProfile: profile,
    remScoreCut: remScoreCut,
    deepScoreCut: deepScoreCut,
  );
}

/// Per-epoch feature vectors — the ONLY thing the staging DECISION layer sees.
///
/// Splitting these out from [cardioStager] draws the line between "turn 1 Hz
/// sensor streams into per-epoch numbers" (device-specific, hard to validate)
/// and "turn per-epoch numbers into stages" (the rules, which are what actually
/// encode our physiological assumptions). Only the second half can be scored
/// against an external PSG-labelled corpus whose raw signals we do not have, so
/// it needs to be callable on its own. All lists must be the same length; NaN
/// marks "not measurable for this epoch" and is never treated as a value.
class CardioEpochFeatures {
  /// Mean positive ENMO over the epoch against a LOCAL 1 g reference (g).
  final List<double> motion;

  /// Mean valid HR over the epoch (bpm); NaN when the epoch had no valid HR.
  final List<double> hr;

  /// Within-epoch SD of HR (bpm); 0 when fewer than 2 valid samples.
  final List<double> hrSd;

  /// RMSSD over a ±2.5-min window centred on the epoch (ms); NaN when sparse.
  final List<double> rmssd;

  /// LF/HF band-power ratio over a ±90 s RR window; NaN when sparse.
  final List<double> lfhf;

  /// R(k) = mean |ΔIHR| over a ±90 s RR window (bpm); NaN when sparse.
  final List<double> rk;

  /// SDNN over the same ±2.5-min window as [rmssd] (ms); NaN when sparse.
  /// Unlike RMSSD, SDNN DOES separate the stages — see the effect sizes in
  /// [classifyCardioEpochs].
  final List<double> sdnn;

  const CardioEpochFeatures({
    required this.motion,
    required this.hr,
    required this.hrSd,
    required this.rmssd,
    required this.lfhf,
    required this.rk,
    required this.sdnn,
  });

  /// Epoch count. All lists are required to be this long; the getter returns
  /// the SHORTEST so a caller that violates the contract truncates instead of
  /// indexing out of range. [classifyCardioEpochs] asserts the equality.
  int get length => [
        motion.length,
        hr.length,
        hrSd.length,
        rmssd.length,
        lfhf.length,
        rk.length,
        sdnn.length,
      ].reduce(math.min);
}

/// The staging DECISION layer: per-epoch features → stages + deep flags.
///
/// Extracted from [cardioStager] verbatim (no behavioural change) so the rules
/// can be scored directly against an external labelled corpus. See
/// [CardioEpochFeatures] for why the seam is here.
///
/// [remScoreCut] / [deepScoreCut] default to the shipped constants and exist so
/// a calibration harness can sweep them on a DEVELOPMENT split and report the
/// held-out result. Production callers should not pass them.
CardioStagerResult classifyCardioEpochs(
  CardioEpochFeatures f, {
  int epochSec = _epochSec,
  SleepUserProfile? userProfile,
  double remScoreCut = _remScoreCut,
  double deepScoreCut = _deepScoreCut,
}) {
  final profile = userProfile ?? cardioUserProfile;
  // [CardioEpochFeatures] documents that every list is the same length, and the
  // in-tree caller guarantees it — but the type is public and the validation
  // harness builds one from parsed external fixture data. A short secondary
  // list would otherwise RangeError deep inside the classify loop, so assert in
  // dev and, in release, fall back to the shortest list rather than throwing
  // (the project's existing idiom: `cardioStager` already clamps to
  // `min(hr1hz.length, accel.length)`).
  assert(
    f.hr.length == f.motion.length &&
        f.hrSd.length == f.motion.length &&
        f.rmssd.length == f.motion.length &&
        f.lfhf.length == f.motion.length &&
        f.rk.length == f.motion.length &&
        f.sdnn.length == f.motion.length,
    'CardioEpochFeatures lists must all be the same length',
  );
  final nEpoch = f.length;
  if (nEpoch < 3) return _abstain(epochSec);
  final motion = f.motion;
  final hr = f.hr;
  final hrSd = f.hrSd;
  final rmssd = f.rmssd;
  final lfhf = f.lfhf;
  final rk = f.rk;
  final sdnn = f.sdnn;

  // ── night baselines (from the LOW-MOTION epochs — the actual sleep) ────────
  // motMed/motMad stay WHOLE-NIGHT scalars: `motion` is now computed against a
  // per-epoch LOCAL reference (above), so genuine stillness reads ~0 almost
  // everywhere and a single still/bigMove threshold over the whole night is
  // the right level — it's the ABSOLUTE-MAGNITUDE reference that needed to be
  // local, not this repositioning-detection threshold.
  final motSample = [for (final m in motion) m];
  final motMed = median(motSample) ?? 0;
  // MAD == 0 means MORE THAN HALF the epochs share one motion value — the
  // guaranteed case when accel is mostly absent. Clamping to 1e-9 made
  // `bigMoveCut` = motMed + 5e-9, so every epoch fractionally above the median
  // became a "big move" and drove the WAKE gate. This is the same MAD-0 class
  // that produced the blank-readiness and nocturnalRhr bugs, and RobustScale.of
  // already refuses it. Abstain from the motion axis instead: null thresholds
  // mean `still` is true everywhere (baseline selection falls back to the whole
  // window) and `bigMove` is never asserted, so WAKE has to come from HR.
  final motMadRaw = mad(motSample) ?? 0;
  final motUsable = motMadRaw > 0 && motMadRaw.isFinite;
  final motMad = motUsable ? motMadRaw : 0.0;
  // Personal-baseline blend (P2): pull each LOCAL threshold a bounded fraction
  // toward the sleeper's rolling profile value. `_pw` (≤0.5) grows with nights,
  // so per-night-local always leads; a null profile axis ⇒ no blend for it.
  final double _pw = profile?.personalWeight ?? 0.0;
  double blendP(double local, double? personal) =>
      (personal == null || _pw == 0)
          ? local
          : local * (1 - _pw) + personal * _pw;
  // "still" (for baseline selection) = motion near the night's typical low.
  final stillCut = blendP(motMed + 1.5 * motMad, profile?.enmoStillCut);
  bool still(int e) => !motUsable || motion[e] <= stillCut;
  // "big move" = clearly elevated motion (getting up / large reposition), used
  // for the WAKE decision — a much higher bar than `still` so normal in-sleep
  // repositioning (which the van-Hees window already certified as sleep) is NOT
  // mistaken for wake.
  final bigMoveCut = blendP(motMed + 5.0 * motMad, profile?.enmoMoveCut);
  bool bigMove(int e) => motUsable && motion[e] > bigMoveCut;

  final sleepHr = <double>[
    for (var e = 0; e < nEpoch; e++)
      if (still(e) && !hr[e].isNaN) hr[e]
  ];
  // HONESTY GATE — no HR anywhere ⇒ ABSTAIN, never substitute a nominal resting
  // HR. Every decision below is HR-RELATIVE (the wake/arousal gate, the REM
  // p25 HR floor, the deep cardiac-trough cut), so with `hr[e]` NaN for every
  // epoch none of them can ever fire and the classifier falls through to NREM
  // for the whole window — i.e. a band sitting on the nightstand would be
  // reported as a perfect night of sleep. The old `?? 60` fallback made that
  // fabrication look like a real baseline. A window with SOME HR still gets the
  // whole-window mean as the baseline when no epoch qualifies as `still` (that
  // is a real measurement, just not a quiet one).
  final hrAll = <double>[
    for (final h in hr)
      if (!h.isNaN) h
  ];
  // ...and "no HR anywhere" is not the same test as "enough HR to stage with".
  // The gate used to be `hrAll.isEmpty`, i.e. ONE valid epoch in 900 passed it.
  // With HR NaN for most epochs neither `hrUp` nor `hrTowardWake` can ever be
  // true, so no epoch can be wake and none can be REM: a sparse HR stream (the
  // gen5 device family) came out ~100 % light sleep, TST = time in bed,
  // efficiency ~100 %, at confidence up to 0.6. Abstention is the honest
  // failure.
  final hrCov = nEpoch == 0 ? 0.0 : hrAll.length / nEpoch.toDouble();
  if (hrCov < minHrCoverage) return _abstain(epochSec);
  final hrMedGlobal = median(sleepHr) ?? mean(hrAll)!;

  // ── LOCAL rolling HR baseline for the WAKE/REM autonomic gates ─────────────
  // A whole-night HR median/arousal threshold has the same non-stationarity
  // problem as the motion reference above. Verified on the same real capture:
  // HR ran 74-80 bpm for the first ~60-90 min after sleep onset (the
  // well-documented sleep-onset HR-decay transient — HR gradually settles
  // into steady-state sleep HR over the first sleep cycle) before dropping to
  // this night's true steady-state ~55-70 bpm. A whole-night arousal threshold
  // (median + max(6, stddev)) misread that entire settling window as
  // "arousal" — a single ~34 min WAKE block right at sleep onset that Webster
  // rescore's flanking-context rules could not bridge (context too short at
  // the very start of the recorded window). A local rolling median tracks the
  // transient instead of comparing it to the whole night.
  //
  // The REM rule's `hrTowardWake` gate specifically uses a LOWER percentile
  // (p25) of that same local window rather than its median: REM recurs
  // periodically (~90 min ultradian cycles) and is itself a MINORITY of any
  // local window, so its own periodic HR elevation partially inflates a local
  // MEDIAN baseline (a self-dilution effect) — a lower percentile is far less
  // sensitive to that and was verified to materially restore REM sensitivity
  // (real capture: REM epochs recovered from 41 min to 139 min against a
  // 162 min ground truth) without reopening the WAKE over-call the local
  // median already fixed for the arousal gate above.
  const int _hrWinEpochs = 180; // 90 min half-window — one ultradian cycle
  final hrMedLocal = List<double>.filled(nEpoch, hrMedGlobal);
  final hrArousalLocal = List<double>.filled(nEpoch, hrMedGlobal + 6.0);
  final hrP25Local = List<double>.filled(nEpoch, hrMedGlobal);
  for (var e = 0; e < nEpoch; e++) {
    final lo = math.max(0, e - _hrWinEpochs);
    final hi = math.min(nEpoch, e + _hrWinEpochs + 1);
    final win = <double>[
      for (var k = lo; k < hi; k++)
        if (still(k) && !hr[k].isNaN) hr[k]
    ];
    // BEFORE the sort, and that is not fussiness: `stddev` sums `(x-m)^2` in
    // list order and mean sums in list order too, so re-ordering the window
    // changes the last bits of both. Algebraically order-free, in float it is
    // not, and this feeds `hrArousalLocal` — which decides wake epochs near the
    // threshold. Computing it here keeps this refactor bit-identical, which is
    // the whole contract of the change.
    final sd = stddev(win);
    // One sort for both percentiles of this 361-epoch window. `win` is freshly
    // built here, so sorting it is local.
    win.sort();
    final m = percentileSorted(win, 50);
    if (m != null) {
      hrMedLocal[e] = m;
      hrArousalLocal[e] = m + math.max(6.0, (sd ?? 6));
      hrP25Local[e] = percentileSorted(win, 25) ?? m;
    }
  }
  // Blend the per-epoch LOCAL HR gates toward the sleeper's rolling profile.
  if (profile != null && _pw > 0) {
    for (var e = 0; e < nEpoch; e++) {
      hrMedLocal[e] = blendP(hrMedLocal[e], profile.hrSleepMedian);
      hrArousalLocal[e] = blendP(hrArousalLocal[e], profile.hrArousal);
      hrP25Local[e] = blendP(hrP25Local[e], profile.hrFloorP25);
    }
  }

  final sleepRmssd = <double>[
    for (var e = 0; e < nEpoch; e++)
      if (still(e) && !rmssd[e].isNaN) rmssd[e]
  ];
  final rmssdMed = median(sleepRmssd);
  // Night sleep distributions for the LF/HF and R(k) REM axes (robust-z base).
  final sleepLfhf = <double>[
    for (var e = 0; e < nEpoch; e++)
      if (still(e) && !lfhf[e].isNaN) lfhf[e]
  ];
  final sleepRk = <double>[
    for (var e = 0; e < nEpoch; e++)
      if (still(e) && !rk[e].isNaN) rk[e]
  ];
  // These three samples are fixed for the rest of the stage, so take their
  // median+MAD once instead of re-deriving them per epoch inside the classify
  // loop below. Same values, ~2,880 fewer sorts on a full night.
  final lfhfScale = RobustScale.of(sleepLfhf);
  final rkScale = RobustScale.of(sleepRk);
  // SDNN and within-epoch HR dispersion get the same night-relative treatment
  // as the other axes, so every term in the stage scores is on one scale.
  final sleepSdnn = <double>[
    for (var e = 0; e < nEpoch; e++)
      if (still(e) && !sdnn[e].isNaN) sdnn[e]
  ];
  final sdnnScale = RobustScale.of(sleepSdnn);
  // hrSd gets the SAME still(e) gating as the other three axes. Pooling wake
  // epochs into this baseline raises its median and widens its MAD, which
  // biases every hrSdZ low — and hrSd carries the second-largest deep weight
  // (0.43), so that alone shifts stage proportions and invalidates the cutoffs.
  //
  // The `> 0` filter is not cosmetic: hrSd is 0-initialised and only assigned
  // when an epoch had >= 2 valid HR samples, so 0 is the "no HR here" sentinel,
  // NOT a real measurement of zero dispersion. Scoring it would make a
  // data-gap epoch read as maximally quiet, i.e. as evidence FOR deep sleep.
  // Measured on real captures: one night with intermittent wear had 226 of
  // 1120 epochs (20%) with no HR, every one of which scored toward deep.
  final sleepHrSd = <double>[
    for (var e = 0; e < nEpoch; e++)
      if (still(e) && hrSd[e] > 0) hrSd[e]
  ];
  final hrSdScale = RobustScale.of(sleepHrSd);

  // ── classify ───────────────────────────────────────────────────────────────
  final stages = List<SleepStage>.filled(nEpoch, SleepStage.wake);
  final deepFlag = List<bool>.filled(nEpoch, false);
  for (var e = 0; e < nEpoch; e++) {
    final hrMed = hrMedLocal[e];
    final hrArousal = hrArousalLocal[e];
    // WAKE is autonomic-led: HR risen to/above the arousal threshold, OR a big
    // movement that ALSO carries some HR lift (truly up), OR sustained big
    // movement. Movement at sleeping HR = repositioning, NOT wake.
    // ASYMMETRY, DELIBERATELY LEFT HERE AND HANDLED UPSTREAM. Every gate that
    // can produce WAKE or REM needs a non-NaN HR, while the fall-through below
    // is an unconditional NREM — so an epoch with no heart rate at all can only
    // ever come out asleep. [minHrCoverage] catches the all-or-nothing case;
    // between 50 % and 100 % coverage it does not. There is no fourth
    // [SleepStage] to express "no cardiac evidence" in, so the abstention is
    // made where the numbers are: `segmentSleep` labels a second with no HR
    // within half an epoch 'unobserved' and keeps it out of TST, WASO and the
    // efficiency denominator.
    final hrUp = !hr[e].isNaN && hr[e] >= hrArousal;
    final bigPrev = e > 0 && bigMove(e - 1);
    final bigMoveWake =
        bigMove(e) && ((!hr[e].isNaN && hr[e] >= hrMed) || bigPrev);
    if (hrUp || bigMoveWake) {
      stages[e] = SleepStage.wake;
      continue;
    }
    // Asleep. REM vs NREM, and deep-within-NREM, are now scored as WEIGHTED
    // SUMS of robust-z axes rather than boolean conjunctions.
    //
    // WHY THE CHANGE. The old rules were an AND of three booleans each, and
    // measurement on 99 PSG-labelled wrist nights (DREAMT) showed two of the
    // three deep gates carry no usable signal — one of them points the wrong
    // way — while the REM primary is at chance. Per-subject agreement and
    // Cohen's d, Deep-vs-Light and REM-vs-Light:
    //
    //   axis      Deep vs Light            REM vs Light        used before?
    //   Rk        91% subj, d -0.53        89% subj, d +0.43   throttled to z>4
    //   hrSd      97% subj, d -0.43                 d +0.27    deep only
    //   sdnn      74% subj, d -0.41                 d +0.32    NOT COMPUTED
    //   lfhf      91% subj, d -0.33        72% subj, d +0.12   throttled to z>4
    //   hr        62% subj, d +0.31 (!)              d +0.18   deep gate, BACKWARDS
    //   rmssd            d -0.13           54% subj, d -0.02   REM PRIMARY (chance)
    //
    // Scored as conjunctions those numbers are fatal: the shipped deep rule
    // ANDs one good axis, one null axis and one inverted axis, so the three can
    // only co-fire by coincidence — which is exactly why deep sleep came out as
    // isolated 30-second specks that the 3-min minimum-bout rule then deleted.
    // A weighted sum degrades gracefully instead: a missing or equivocal axis
    // costs its weight rather than vetoing the whole decision.
    //
    // WEIGHTS ARE THE MEASURED EFFECT SIZES, not tuned. Under equal variance a
    // linear discriminant's optimal weights are proportional to d, so using |d|
    // directly is the principled choice AND leaves nothing fitted to the corpus
    // beyond its sign. This also matches how the published cardiorespiratory
    // stagers combine features (Long 2016, Fonseca 2015/2018 all use linear
    // discriminants; Fonseca 2018 measured a generative HMM at kappa 0.26 vs
    // 0.39 for a plain per-epoch LD on identical features, so the sophistication
    // does not belong in the decoder).
    //
    // rmssd and mean HR are deliberately ABSENT from both scores. Neither
    // earns a weight, and hr's deep contribution was actively harmful.
    final rkZ =
        (sleepRk.length >= 4 && !rk[e].isNaN) ? rkScale?.z(rk[e]) : null;
    final sdnnZ = (sleepSdnn.length >= 4 && !sdnn[e].isNaN)
        ? sdnnScale?.z(sdnn[e])
        : null;
    final lfhfZ = (sleepLfhf.length >= 4 && !lfhf[e].isNaN)
        ? lfhfScale?.z(lfhf[e])
        : null;
    // Same >=4-sample floor and unmeasurable-epoch rejection as the axes above.
    // hrSd[e] == 0 means "fewer than 2 valid HR samples", never "perfectly
    // steady" — see the sleepHrSd comment. An absent input must contribute
    // nothing, not a favourable z.
    final hrSdZ =
        (sleepHrSd.length >= 4 && hrSd[e] > 0) ? hrSdScale?.z(hrSd[e]) : null;

    // Weighted mean over the axes that are actually MEASURABLE this epoch, so
    // a night with no usable RR falls back to the hrSd axis alone instead of
    // silently scoring every epoch as if the missing axes voted "no".
    double? score(List<(double?, double)> terms) {
      var num = 0.0, den = 0.0;
      for (final (z, w) in terms) {
        if (z == null || z.isNaN) continue;
        num += z * w;
        den += w.abs();
      }
      return den == 0 ? null : num / den;
    }

    final remScore = score([
      (rkZ, _wRemRk),
      (sdnnZ, _wRemSdnn),
      (hrSdZ, _wRemHrSd),
      (lfhfZ, _wRemLfhf),
    ]);
    final deepScore = score([
      (rkZ, -_wDeepRk),
      (hrSdZ, -_wDeepHrSd),
      (sdnnZ, -_wDeepSdnn),
      (lfhfZ, -_wDeepLfhf),
    ]);

    // Atonia and the HR floor are RETAINED as gates, not folded into the score:
    // they are not weak evidence for REM, they are preconditions. A large
    // movement rules REM out outright (muscle atonia), and REM is not the
    // quiescent cardiac trough, so HR below the local p25 rules it out too.
    final atonia = !bigMove(e);
    final hrTowardWake = !hr[e].isNaN && hr[e] >= hrP25Local[e];
    if (remScore != null && remScore > remScoreCut && atonia && hrTowardWake) {
      stages[e] = SleepStage.rem;
    } else {
      stages[e] = SleepStage.nrem;
      // Deep (NREM subtype, still LOW CONFIDENCE — this is a cardiac-quiescence
      // overlay, not an EEG slow-wave measurement).
      deepFlag[e] = deepScore != null && deepScore > deepScoreCut;
    }
  }

  // ── post-process: median-filter flicker → Webster continuity → consolidate ──
  // A 3-epoch categorical median (mode) filter first, to drop isolated
  // single-epoch label flips (e.g. a lone REM/deep spike inside a stable run)
  // before the continuity/consolidation stages act on min bouts.
  _modeFilterStages(stages);
  _websterRescore(stages, epochSec);
  final sm = consolidateSleepStages(stages, epochSec);
  // Keep deepFlag in lockstep with the FINAL consolidated stage: the mode filter,
  // Webster rescore, and consolidation can move a deep-flagged NREM epoch to REM
  // or Wake. Clear the flag there so no epoch is ever reported deep while its
  // stage disagrees (_mergeShortDeep only skips non-NREM epochs — it never
  // clears a stale flag left on one).
  for (var e = 0; e < deepFlag.length && e < sm.length; e++) {
    if (deepFlag[e] && sm[e] != SleepStage.nrem) deepFlag[e] = false;
  }
  _mergeShortDeep(deepFlag, sm, epochSec);

  // ── record this night's baselines for the rolling per-user profile (P2) ─────
  // Only when the edge armed recording AND the staged span is a real sleep
  // (≥60 min) — naps must not pollute the sleeper's night profile.
  if (cardioRecordObservations && nEpoch >= 120 && sleepHr.isNotEmpty) {
    final hrSleepMed = median(sleepHr);
    _cardioObservations.add(SleepNightObservation(
      epochs: nEpoch,
      hrFloorP5: percentile(sleepHr, 5),
      hrFloorP25: percentile(sleepHr, 25),
      hrSleepMedian: hrSleepMed,
      hrArousal:
          (hrSleepMed ?? hrMedGlobal) + math.max(6.0, stddev(sleepHr) ?? 6.0),
      rmssdMed: rmssdMed,
      rmssdMad: mad(sleepRmssd),
      enmoStillCut: motMed + 1.5 * motMad,
      enmoMoveCut: motMed + 5.0 * motMad,
      lfhfMed: median(sleepLfhf),
      rkMed: median(sleepRk),
    ));
    if (_cardioObservations.length > 32) _cardioObservations.removeAt(0);
  }

  // ── percentages + confidence ────────────────────────────────────────────────
  var w = 0, nr = 0, r = 0;
  for (final s in sm) {
    if (s == SleepStage.wake) {
      w++;
    } else if (s == SleepStage.nrem) {
      nr++;
    } else {
      r++;
    }
  }
  final tot = sm.length.toDouble();
  // Confidence: a wrist ESTIMATE ceiling, scaled by RR coverage (RMSSD is what
  // makes REM/deep honest — with no RR we're motion+HR only, lower confidence).
  final rrCov = nEpoch == 0 ? 0.0 : sleepRmssd.length / nEpoch.toDouble();
  // HR coverage is folded in: `rrCov` alone said nothing about whether the
  // HR-relative gates (wake, REM floor, deep trough) had anything to fire on.
  final hrCovConf = nEpoch == 0
      ? 0.0
      : clamp(
          [
                for (final h in hr)
                  if (!h.isNaN) h
              ].length /
              nEpoch.toDouble(),
          0.0,
          1.0);
  final conf = clamp((0.35 + 0.25 * rrCov) * hrCovConf, 0.15, 0.6);

  return CardioStagerResult(
    StagerResult(
      stages: sm,
      epochSec: epochSec,
      wakePct: 100 * w / tot,
      nremPct: 100 * nr / tot,
      remPct: 100 * r / tot,
    ),
    deepFlag,
    conf,
  );
}

/// Honest "cannot stage this window" result: NO epochs, no deep flags, zero
/// confidence. Callers must treat an empty [StagerResult.stages] as UNSTAGED
/// (see `advanced_stager._stageSessionCardio`), never as sleep.
CardioStagerResult _abstain(int epochSec) => CardioStagerResult(
      StagerResult(
        stages: const <SleepStage>[],
        epochSec: epochSec,
        wakePct: 0,
        nremPct: 0,
        remPct: 0,
      ),
      const <bool>[],
      0,
    );

/// RMSSD (ms) of cleaned RR beats whose absolute time falls within a ±2.5-min
/// window centred on epoch [s,t). Returns NaN when too few clean beats.
double _windowRmssd(List<double> rrMs, List<double> rrTsMs,
    List<AccelSample> accel, int s, int t, int epochSec) {
  final beats = _cleanBeatsInWindow(rrMs, rrTsMs, accel, s, t).beats;
  if (beats.length < 5) return double.nan;
  var ss = 0.0;
  for (var i = 1; i < beats.length; i++) {
    final d = beats[i] - beats[i - 1];
    ss += d * d;
  }
  return math.sqrt(ss / (beats.length - 1));
}

/// SDNN (ms) of cleaned RR beats over the SAME ±2.5-min window as
/// [_windowRmssd]. Returns NaN when too few clean beats.
///
/// Worth its own feature because SDNN and RMSSD behave completely differently
/// across sleep stages, despite both being "HRV". Measured per-subject on 99
/// PSG-labelled wrist nights (DREAMT): SDNN separates Deep from Light in 74% of
/// subjects (Cohen's d −0.41) and REM from Light at d +0.32, while RMSSD is at
/// chance for both (54% of subjects, d −0.02). Herzig 2017 (PSG+ECG) reports
/// the same split — SDNN 53.8 / 68.5 / 105.5 ms for N3 / N2 / REM against a
/// flat RMSSD of 67.3 / 70.7 / 79.7.
double _windowSdnn(List<double> rrMs, List<double> rrTsMs,
    List<AccelSample> accel, int s, int t, int epochSec) {
  final beats = _cleanBeatsInWindow(rrMs, rrTsMs, accel, s, t).beats;
  if (beats.length < 5) return double.nan;
  final m = mean(beats)!;
  var ss = 0.0;
  for (final v in beats) {
    ss += (v - m) * (v - m);
  }
  return math.sqrt(ss / (beats.length - 1));
}

/// Clean RR beats (ms) inside a ±[halfWinMs] window centred on epoch [s,t),
/// with each beat's time rebased to the window start (seconds).
///
/// The physiologic gate (300–2000 ms, drop big successive jumps) lives here and
/// only here, so every window feature sees exactly the same beats for a given
/// window — [_windowRmssd] and [_windowSdnn] are computed over one window and
/// must agree on its contents.
///
/// [_windowRemFeatures] passes a DIFFERENT [halfWinMs] on purpose (±90 s, not
/// ±2.5 min): its LF/HF grid and its `beats.length` abstain gate are specified
/// against that shorter window. Do not hand it the default list.
({List<double> beats, List<double> tsSec}) _cleanBeatsInWindow(
  List<double> rrMs,
  List<double> rrTsMs,
  List<AccelSample> accel,
  int s,
  int t, {
  int halfWinMs = 150 * 1000,
}) {
  const empty = (beats: <double>[], tsSec: <double>[]);
  if (rrMs.isEmpty || rrTsMs.length != rrMs.length) return empty;
  final mid = (s + t) ~/ 2;
  if (mid >= accel.length) return empty;
  final centreMs = accel[mid].tsMs;
  final lo = centreMs - halfWinMs, hi = centreMs + halfWinMs;
  // [rrTsMs] is ascending, so lower-bound into it and stop at the far edge
  // instead of walking every beat of the night once per epoch per feature.
  //
  // TRUE lower bound — the first index with ts >= lo, NOT the first index
  // strictly greater than lo. `rr_ts_ms` is `rec_ts * 1000`, so beats TIE on
  // the second boundary; dropping the tied beats at a window edge changes
  // RMSSD / SDNN / LF-HF and with them the REM and deep epoch counts, silently.
  var a = 0, b = rrTsMs.length;
  while (a < b) {
    final m = (a + b) >> 1;
    if (rrTsMs[m] < lo) {
      a = m + 1;
    } else {
      b = m;
    }
  }
  final beats = <double>[];
  final tsSec = <double>[];
  double? prev;
  for (var i = a; i < rrMs.length; i++) {
    final ts = rrTsMs[i];
    if (ts > hi) break;
    final v = rrMs[i];
    if (v < _rrMin || v > _rrMax) {
      prev = null;
      continue;
    }
    if (prev != null && (v - prev).abs() > _rrMaxStep) {
      prev = v;
      continue;
    }
    beats.add(v);
    // Rebase to the window start (lo), NOT absolute epoch ms. Lomb–Scargle is
    // time-shift invariant (the τ phase reference cancels any offset), so the
    // LF/HF output is unchanged — but this keeps beat times in [0, 180] s
    // instead of ~1.75e9 s. Absolute epoch seconds force every sin/cos in the
    // periodogram onto libm's __kernel_rem_pio2 multi-precision slow path
    // (args ~9e9 rad), which — run per 30-s epoch over a full night on the
    // main isolate — caused main-thread ANRs on Android (Crashlytics: libm.so
    // __kernel_rem_pio2 / sin / cos, 0.9.13).
    tsSec.add((ts - lo) / 1000.0);
    prev = v;
  }
  return (beats: beats, tsSec: tsSec);
}

/// [_cleanBeatsInWindow]'s beats, exposed so the window-edge regression test
/// can drive the gather directly. Not a staging entry point — call
/// [cardioStager].
List<double> cleanBeatsInWindowForTest(
  List<double> rrMs,
  List<double> rrTsMs,
  List<AccelSample> accel,
  int s,
  int t, {
  int halfWinMs = 150 * 1000,
}) =>
    _cleanBeatsInWindow(rrMs, rrTsMs, accel, s, t, halfWinMs: halfWinMs).beats;

/// Webster sleep-continuity rescore: brief wake bouts flanked by enough sleep
/// are re-labelled sleep (NREM). This is the published actigraphy step that
/// prevents normal in-sleep repositioning from inflating WASO.
///
/// The flanking-sleep CONTEXT is measured against an immutable SNAPSHOT of the
/// hypnogram taken before the pass — Webster's rule scores each wake bout
/// against the ORIGINAL surrounding sleep (Webster et al. 1982; Cole et al.
/// 1992), not against sleep this same pass just manufactured. Reading the list
/// being mutated let every bridged bout count as context for the next one, so
/// bridging CASCADED: a fragmented night of short sleep bouts separated by long
/// wake bouts collapsed into one continuous sleep block (WASO 0, efficiency
/// 100%). Exposed (non-private) so the regression test can drive the rule
/// directly; not part of the package's public barrel.
void websterRescoreCardio(List<SleepStage> sm, int epochSec) =>
    _websterRescore(sm, epochSec);

void _websterRescore(List<SleepStage> sm, int epochSec) {
  bool isSleep(SleepStage s) => s != SleepStage.wake;
  final n = sm.length;
  double minToEp(double m) => m * 60.0 / epochSec;
  // Immutable context snapshot — see the doc comment above.
  final snap = List<SleepStage>.of(sm);
  var onset = -1, lastSleep = -1;
  for (var i = 0; i < n; i++) {
    if (isSleep(snap[i])) {
      if (onset < 0) onset = i;
      lastSleep = i;
    }
  }
  if (onset < 0) return;
  int runBefore(int i) {
    var c = 0, k = i - 1;
    while (k >= onset && isSleep(snap[k])) {
      c++;
      k--;
    }
    return c;
  }

  int runAfter(int i) {
    var c = 0, k = i + 1;
    while (k <= lastSleep && isSleep(snap[k])) {
      c++;
      k++;
    }
    return c;
  }

  // Context (min sleep flanking) → max bridgeable wake (min). THE PUBLISHED
  // TABLE, unmodified: Webster et al. 1982 / Cole et al. 1992 rescoring rules —
  // 4 min of sleep bridges ≤1 min of wake, 10 bridges ≤3, 15 bridges ≤4.
  //
  // This used to run [15→10], [10→5], [4→2] — 2.5x the published bridge — on
  // the argument that the van Hees window had already certified the span as the
  // consolidated rest period. That argument does not hold: on the forced-window
  // paths (manual / confirmed / auto_fallback) van Hees never runs at all, and
  // even where it does, a genuine 9-minute 3 a.m. awakening flanked by 15 min of
  // sleep was being relabelled light sleep. TST was over-reported, WASO
  // under-reported and efficiency inflated, potentially several times a night,
  // disclosed only in a code comment the user never sees.
  final rules = <List<double>>[
    [minToEp(15), minToEp(4)],
    [minToEp(10), minToEp(3)],
    [minToEp(4), minToEp(1)],
  ];
  var i = onset;
  while (i <= lastSleep) {
    if (isSleep(snap[i])) {
      i++;
      continue;
    }
    var j = i;
    while (j <= lastSleep && !isSleep(snap[j])) {
      j++;
    }
    final wakeLen = (j - i).toDouble();
    final ctx = math.max(runBefore(i), runAfter(j - 1)).toDouble();
    for (final r in rules) {
      if (ctx >= r[0] && wakeLen <= r[1]) {
        for (var k = i; k < j; k++) {
          sm[k] = SleepStage.nrem;
        }
        break;
      }
    }
    i = j;
  }
}

/// REM autonomic features over a ±90-s RR window centred on epoch [s,t):
///   • lfhf = LF(0.04–0.15 Hz) / HF(0.15–0.40 Hz) band-power ratio, computed on
///     the NATIVE beat times via Lomb–Scargle (the project's validated PSD for
///     unevenly-sampled RR — no resampling, superior to interpolating to 4 Hz).
///   • rk   = mean |ΔIHR| over the window (IHR = 60000/RR bpm) — the R(k) REM
///     index (instantaneous-HR "jitter" that rises in REM).
/// Beats are cleaned with the same physiologic gate as [_windowRmssd]. Returns
/// nulls when too few clean beats for a stable estimate.
({double? lfhf, double? rk}) _windowRemFeatures(List<double> rrMs,
    List<double> rrTsMs, List<AccelSample> accel, int s, int t, int epochSec) {
  // ±90 s per the REM feature spec — a DIFFERENT window from the RMSSD/SDNN
  // one; see [_cleanBeatsInWindow].
  final win = _cleanBeatsInWindow(rrMs, rrTsMs, accel, s, t,
      halfWinMs: 90 * 1000);
  final beats = win.beats; // clean RR (ms)
  final beatTsSec = win.tsSec; // matching beat times (s), rebased to window
  if (beats.length < 16)
    return (lfhf: null, rk: null); // spectral stability gate
  // R(k): mean absolute successive difference of instantaneous HR (bpm).
  var rkSum = 0.0;
  var rkCnt = 0;
  double? prevIhr;
  for (final v in beats) {
    final ihr = 60000.0 / v;
    if (prevIhr != null) {
      rkSum += (ihr - prevIhr).abs();
      rkCnt++;
    }
    prevIhr = ihr;
  }
  final rk = rkCnt > 0 ? rkSum / rkCnt : null;
  // LF/HF via Lomb–Scargle on native beat times.
  double? lfhf;
  final spanSec = beatTsSec.last - beatTsSec.first;
  if (spanSec > 0) {
    final loHz = (1.0 / spanSec).clamp(0.0005, 0.04).toDouble();
    final ls = lombScargle(beatTsSec, beats, freqGrid(loHz, 0.4, 240));
    if (ls != null) {
      final lf = ls.bandPower(0.04, 0.15);
      final hf = ls.bandPower(0.15, 0.40);
      if (hf > 0) lfhf = lf / hf;
    }
  }
  return (lfhf: lfhf, rk: rk);
}

/// 3-epoch categorical median (mode) filter: flip a lone epoch whose two
/// neighbours agree and differ from it. Removes single-epoch label flicker
/// without touching runs of length ≥2. Operates in place.
void _modeFilterStages(List<SleepStage> s) {
  final n = s.length;
  if (n < 3) return;
  final out = List<SleepStage>.of(s);
  for (var i = 1; i < n - 1; i++) {
    if (s[i - 1] == s[i + 1] && s[i] != s[i - 1]) out[i] = s[i - 1];
  }
  for (var i = 0; i < n; i++) {
    s[i] = out[i];
  }
}

/// Merge deep bouts shorter than 3 min into Light, so deep reads as consolidated
/// SWS rather than single-epoch flicker.
void _mergeShortDeep(List<bool> deepFlag, List<SleepStage> sm, int epochSec) {
  final minEp = (3 * 60.0 / epochSec).round();
  if (minEp <= 1) return;
  final n = deepFlag.length;
  var i = 0;
  while (i < n) {
    if (!deepFlag[i] || sm[i] != SleepStage.nrem) {
      i++;
      continue;
    }
    var j = i;
    while (j < n && deepFlag[j] && sm[j] == SleepStage.nrem) {
      j++;
    }
    if ((j - i) < minEp) {
      for (var k = i; k < j; k++) {
        deepFlag[k] = false;
      }
    }
    i = j;
  }
}
