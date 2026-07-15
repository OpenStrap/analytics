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
//   hr     = mean valid HR (bpm)
//   rmssd  = RMSSD of cleaned RR beats in a ±2.5-min window (ms), or null
// then classify against baselines:
//   WAKE  : clearly elevated motion OR HR arousal above a LOCAL sleeping HR
//           median (a 90-min rolling window, not the whole night)
//   REM   : still body + RMSSD well BELOW the night's sleep RMSSD + HR ≥ a
//           LOCAL p25 HR floor (see below for why p25, not median)
//   DEEP  : HR near the night floor + RMSSD high + very stable (NREM subtype)
//   LIGHT : remaining NREM
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

/// Robust-z cutoffs for the SECONDARY REM axes (LF/HF elevation, R(k) burst).
/// Deliberately STRICT (4.0 robust-SD): the RMSSD drop is the PRIMARY REM
/// detector; LF/HF and R(k) only ADD REM where a strong, unambiguous autonomic
/// shift the RMSSD rule missed exists, so the OR-combination recovers
/// under-called REM without stealing normal light sleep. Calibrated on the real
/// 2026-07 overnight fixture (Apple-Watch GT: wake 3 / light 330 / deep 38 /
/// REM 162 min). RMSSD-only under-called REM at 134 min; a threshold sweep
/// showed z=2.5→204, 3.0→191, 3.5→182, 4.0→172 min REM. 4.0 lands closest to GT
/// (REM 172, light 304) while still adding +38 min of strong-signature REM over
/// RMSSD-only — a conservative, bounded sensitivity gain for the nights the
/// RMSSD rule under-calls (the motivating case: 64 min REM vs a ~115 signature),
/// erring toward specificity so the axes never re-open a Wake/REM over-call.
const double _remLfhfZ = 4.0;
const double _remRkZ = 4.0;

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
final List<SleepNightObservation> _cardioObservations = <SleepNightObservation>[];

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
/// [hr1hz] per-second HR (bpm; 0 = off-skin) over the in-bed window.
/// [accel] per-second gravity vectors, SAME length/time base as [hr1hz].
/// [rrMs] / [rrTsMs] beat-to-beat RR (ms) and their ABSOLUTE times (ms), same
///   clock as `accel[i].tsMs`. Sparse/empty is fine — REM/deep just lean more on
///   HR and confidence drops.
CardioStagerResult cardioStager(
  List<double> hr1hz,
  List<AccelSample> accel, {
  List<double> rrMs = const [],
  List<double> rrTsMs = const [],
  int epochSec = _epochSec,
  SleepUserProfile? userProfile,
}) {
  // Explicit arg wins (unit tests); else the ambient profile the edge set for
  // this staging pass; else null ⇒ pure per-night-local (cold-start behavior).
  final profile = userProfile ?? cardioUserProfile;
  final n = math.min(hr1hz.length, accel.length);
  final nEpoch = n ~/ epochSec;
  if (nEpoch < 3) {
    return CardioStagerResult(
      const StagerResult(
          stages: <SleepStage>[],
          epochSec: _epochSec,
          wakePct: 0,
          nremPct: 0,
          remPct: 0),
      const <bool>[],
      0,
    );
  }

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
  final gRefByEpoch = List<double>.filled(nEpoch, 1.0);
  for (var e = 0; e < nEpoch; e++) {
    final es = e * epochSec;
    final lo = math.max(0, es - _gRefWinSec ~/ 2);
    final hi = math.min(n, es + epochSec + _gRefWinSec ~/ 2);
    gRefByEpoch[e] = median(mag.sublist(lo, hi)) ?? 1.0;
  }

  // ── per-epoch features ─────────────────────────────────────────────────────
  final motion = List<double>.filled(nEpoch, 0);
  final hr = List<double>.filled(nEpoch, double.nan);
  final hrSd = List<double>.filled(nEpoch, 0);
  final rmssd = List<double>.filled(nEpoch, double.nan);
  // REM autonomic features (P1): LF/HF from the RR spectrum + R(k) = rolling
  // mean |ΔIHR|. REM's signature at 1 Hz beat-timing is a SYMPATHETIC shift —
  // LF/HF rises, RR variability drops (low RMSSD), and instantaneous HR gets
  // "jittery" (elevated |ΔIHR|). The old REM rule leaned only on the RMSSD drop
  // and under-called REM; these two independent axes recover it (OR-combined
  // below), gated by atonia + an HR floor so a plain arousal is not miscalled.
  final lfhf = List<double>.filled(nEpoch, double.nan);
  final rk = List<double>.filled(nEpoch, double.nan);

  for (var e = 0; e < nEpoch; e++) {
    final s = e * epochSec, t = math.min(s + epochSec, n);
    // motion = mean ENMO over the epoch, against THIS epoch's local reference.
    final gRefE = gRefByEpoch[e];
    var ms = 0.0;
    for (var i = s; i < t; i++) {
      final d = mag[i] - gRefE;
      ms += d > 0 ? d : 0.0;
    }
    motion[e] = ms / (t - s);
    // hr mean/sd over valid (>0) seconds
    final hv = <double>[for (var i = s; i < t; i++) if (hr1hz[i] > 0) hr1hz[i]];
    if (hv.isNotEmpty) hr[e] = mean(hv)!;
    if (hv.length >= 2) hrSd[e] = stddev(hv) ?? 0;
    // rmssd over RR beats within a ±2.5-min window centred on the epoch
    rmssd[e] = _windowRmssd(rrMs, rrTsMs, accel, s, t, epochSec);
    // LF/HF + R(k) over a ±90-s RR window centred on the epoch.
    final rem = _windowRemFeatures(rrMs, rrTsMs, accel, s, t, epochSec);
    if (rem.lfhf != null) lfhf[e] = rem.lfhf!;
    if (rem.rk != null) rk[e] = rem.rk!;
  }

  // ── night baselines (from the LOW-MOTION epochs — the actual sleep) ────────
  // motMed/motMad stay WHOLE-NIGHT scalars: `motion` is now computed against a
  // per-epoch LOCAL reference (above), so genuine stillness reads ~0 almost
  // everywhere and a single still/bigMove threshold over the whole night is
  // the right level — it's the ABSOLUTE-MAGNITUDE reference that needed to be
  // local, not this repositioning-detection threshold.
  final motSample = [for (final m in motion) m];
  final motMed = median(motSample) ?? 0;
  final motMad = (mad(motSample) ?? 0).clamp(1e-9, double.infinity);
  // Personal-baseline blend (P2): pull each LOCAL threshold a bounded fraction
  // toward the sleeper's rolling profile value. `_pw` (≤0.5) grows with nights,
  // so per-night-local always leads; a null profile axis ⇒ no blend for it.
  final double _pw = profile?.personalWeight ?? 0.0;
  double blendP(double local, double? personal) =>
      (personal == null || _pw == 0) ? local : local * (1 - _pw) + personal * _pw;
  // "still" (for baseline selection) = motion near the night's typical low.
  final stillCut = blendP(motMed + 1.5 * motMad, profile?.enmoStillCut);
  bool still(int e) => motion[e] <= stillCut;
  // "big move" = clearly elevated motion (getting up / large reposition), used
  // for the WAKE decision — a much higher bar than `still` so normal in-sleep
  // repositioning (which the van-Hees window already certified as sleep) is NOT
  // mistaken for wake.
  final bigMoveCut = blendP(motMed + 5.0 * motMad, profile?.enmoMoveCut);
  bool bigMove(int e) => motion[e] > bigMoveCut;

  final sleepHr = <double>[
    for (var e = 0; e < nEpoch; e++)
      if (still(e) && !hr[e].isNaN) hr[e]
  ];
  final hrMedGlobal =
      median(sleepHr) ?? (mean([for (final h in hr) if (!h.isNaN) h]) ?? 60);
  final hrFloor = percentile(sleepHr, 10) ?? hrMedGlobal;

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
  final hrArousalLocal =
      List<double>.filled(nEpoch, hrMedGlobal + 6.0);
  final hrP25Local = List<double>.filled(nEpoch, hrMedGlobal);
  for (var e = 0; e < nEpoch; e++) {
    final lo = math.max(0, e - _hrWinEpochs);
    final hi = math.min(nEpoch, e + _hrWinEpochs + 1);
    final win = <double>[
      for (var k = lo; k < hi; k++)
        if (still(k) && !hr[k].isNaN) hr[k]
    ];
    final m = median(win);
    if (m != null) {
      hrMedLocal[e] = m;
      hrArousalLocal[e] = m + math.max(6.0, (stddev(win) ?? 6));
      hrP25Local[e] = percentile(win, 25) ?? m;
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
  final hrSdSample = [for (final s in hrSd) if (s > 0) s];
  final hrSdMed = median(hrSdSample) ?? double.infinity;
  // RMSSD reference for the deep "not-elevated-HRV" gate, blended toward profile.
  final rmssdRef = rmssdMed == null
      ? profile?.rmssdMed
      : blendP(rmssdMed, profile?.rmssdMed);
  // Deep = HR in the lower half of the night's sleeping HR (the cardiac trough),
  // with the floor/median blended toward the personal profile (P2).
  final deepFloor = blendP(hrFloor, profile?.hrFloorP5);
  final deepMed = blendP(hrMedGlobal, profile?.hrSleepMedian);
  final deepHrCut = deepFloor + 0.5 * (deepMed - deepFloor);

  // ── classify ───────────────────────────────────────────────────────────────
  final stages = List<SleepStage>.filled(nEpoch, SleepStage.wake);
  final deepFlag = List<bool>.filled(nEpoch, false);
  for (var e = 0; e < nEpoch; e++) {
    final hrMed = hrMedLocal[e];
    final hrArousal = hrArousalLocal[e];
    // WAKE is autonomic-led: HR risen to/above the arousal threshold, OR a big
    // movement that ALSO carries some HR lift (truly up), OR sustained big
    // movement. Movement at sleeping HR = repositioning, NOT wake.
    final hrUp = !hr[e].isNaN && hr[e] >= hrArousal;
    final bigPrev = e > 0 && bigMove(e - 1);
    final bigMoveWake =
        bigMove(e) && ((!hr[e].isNaN && hr[e] >= hrMed) || bigPrev);
    if (hrUp || bigMoveWake) {
      stages[e] = SleepStage.wake;
      continue;
    }
    // Asleep. REM vs NREM via autonomic signature. REM is OR-combined across
    // three independent RR axes (any one suffices), THEN gated by atonia (no
    // large movement) AND an HR floor (HR ≥ the local p25 — REM is not the
    // quiescent cardiac trough). This recovers REM the RMSSD-only rule missed.
    final rmZ = (rmssdMed != null && !rmssd[e].isNaN && sleepRmssd.length >= 4)
        ? robustZ(rmssd[e], sleepRmssd)
        : null;
    final rmssdDown = rmZ != null && rmZ < -0.4; // RMSSD notably below sleep base
    // LF/HF elevated (sympathetic shift) vs the night's sleeping LF/HF.
    final lfhfZ = (sleepLfhf.length >= 4 && !lfhf[e].isNaN)
        ? robustZ(lfhf[e], sleepLfhf)
        : null;
    final lfhfHigh = lfhfZ != null && lfhfZ > _remLfhfZ;
    // R(k) burst: instantaneous-HR variability elevated vs sleeping R(k).
    final rkZ = (sleepRk.length >= 4 && !rk[e].isNaN)
        ? robustZ(rk[e], sleepRk)
        : null;
    final rkBurst = rkZ != null && rkZ > _remRkZ;
    final remAutonomic = rmssdDown || lfhfHigh || rkBurst;
    final atonia = !bigMove(e); // muscle-atonia proxy — no large movement
    final hrTowardWake =
        !hr[e].isNaN && hr[e] >= hrP25Local[e]; // HR up but not arousal
    if (remAutonomic && atonia && hrTowardWake) {
      stages[e] = SleepStage.rem;
    } else {
      stages[e] = SleepStage.nrem;
      // Deep (NREM subtype, LOW CONFIDENCE): the cardiac trough — HR in the
      // lower half of the night's sleeping HR AND not HR-variable (deep sleep is
      // autonomically quiet). RMSSD, when present, reinforces (high RMSSD) but
      // isn't required (RR is sparse). Below NREM median, not the lowest third,
      // so deep lands in a physiologic range instead of ~0.
      final lowHr = !hr[e].isNaN && hr[e] <= deepHrCut;
      final notHighRmssd =
          rmssdRef == null || rmssd[e].isNaN || rmssd[e] >= rmssdRef * 0.9;
      final stable = hrSd[e] <= hrSdMed * 1.5;
      deepFlag[e] = lowHr && notHighRmssd && stable;
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
    _cardioObservations.add(SleepNightObservation(
      epochs: nEpoch,
      hrFloorP5: percentile(sleepHr, 5),
      hrFloorP25: percentile(sleepHr, 25),
      hrSleepMedian: median(sleepHr),
      hrArousal: (median(sleepHr) ?? hrMedGlobal) +
          math.max(6.0, stddev(sleepHr) ?? 6.0),
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
  final rrCov = nEpoch == 0
      ? 0.0
      : sleepRmssd.length / nEpoch.toDouble();
  final conf = clamp(0.35 + 0.25 * rrCov, 0.3, 0.6);

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

/// RMSSD (ms) of cleaned RR beats whose absolute time falls within a ±2.5-min
/// window centred on epoch [s,t). Returns NaN when too few clean beats.
double _windowRmssd(List<double> rrMs, List<double> rrTsMs,
    List<AccelSample> accel, int s, int t, int epochSec) {
  if (rrMs.isEmpty || rrTsMs.length != rrMs.length) return double.nan;
  final mid = (s + t) ~/ 2;
  if (mid >= accel.length) return double.nan;
  final centreMs = accel[mid].tsMs;
  const halfWinMs = 150 * 1000; // ±2.5 min for a stable RMSSD on sparse RR
  final lo = centreMs - halfWinMs, hi = centreMs + halfWinMs;
  // Gather clean beats in window (300–2000 ms, drop big successive jumps).
  final beats = <double>[];
  double? prev;
  for (var i = 0; i < rrMs.length; i++) {
    final ts = rrTsMs[i];
    if (ts < lo || ts > hi) continue;
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
    prev = v;
  }
  if (beats.length < 5) return double.nan;
  var ss = 0.0;
  for (var i = 1; i < beats.length; i++) {
    final d = beats[i] - beats[i - 1];
    ss += d * d;
  }
  return math.sqrt(ss / (beats.length - 1));
}

/// Webster sleep-continuity rescore: brief wake bouts flanked by enough sleep
/// are re-labelled sleep (NREM). This is the published actigraphy step that
/// prevents normal in-sleep repositioning from inflating WASO.
void _websterRescore(List<SleepStage> sm, int epochSec) {
  bool isSleep(SleepStage s) => s != SleepStage.wake;
  final n = sm.length;
  double minToEp(double m) => m * 60.0 / epochSec;
  var onset = -1, lastSleep = -1;
  for (var i = 0; i < n; i++) {
    if (isSleep(sm[i])) {
      if (onset < 0) onset = i;
      lastSleep = i;
    }
  }
  if (onset < 0) return;
  int runBefore(int i) {
    var c = 0, k = i - 1;
    while (k >= onset && isSleep(sm[k])) {
      c++;
      k--;
    }
    return c;
  }
  int runAfter(int i) {
    var c = 0, k = i + 1;
    while (k <= lastSleep && isSleep(sm[k])) {
      c++;
      k++;
    }
    return c;
  }
  // Context (min sleep flanking) → max bridgeable wake (min). Slightly more
  // generous than Webster's classic table: the van Hees window already certified
  // this span as the consolidated rest period, so brief arousals inside it are
  // far more likely repositioning than true wake.
  final rules = <List<double>>[
    [minToEp(15), minToEp(10)],
    [minToEp(10), minToEp(5)],
    [minToEp(4), minToEp(2)],
  ];
  var i = onset;
  while (i <= lastSleep) {
    if (isSleep(sm[i])) {
      i++;
      continue;
    }
    var j = i;
    while (j <= lastSleep && !isSleep(sm[j])) {
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
  if (rrMs.isEmpty || rrTsMs.length != rrMs.length) {
    return (lfhf: null, rk: null);
  }
  final mid = (s + t) ~/ 2;
  if (mid >= accel.length) return (lfhf: null, rk: null);
  final centreMs = accel[mid].tsMs;
  const halfWinMs = 90 * 1000; // ±90 s per the REM feature spec
  final lo = centreMs - halfWinMs, hi = centreMs + halfWinMs;
  final beats = <double>[]; // clean RR (ms)
  final beatTsSec = <double>[]; // matching beat times (s)
  double? prev;
  for (var i = 0; i < rrMs.length; i++) {
    final ts = rrTsMs[i];
    if (ts < lo || ts > hi) continue;
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
    beatTsSec.add(ts / 1000.0);
    prev = v;
  }
  if (beats.length < 16) return (lfhf: null, rk: null); // spectral stability gate
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
