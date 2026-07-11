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

/// Physiologic RR gate (project rule): keep 300–2000 ms; drop successive jumps
/// > 200 ms (ectopy / artifact). Used per-window before RMSSD.
const double _rrMin = 300, _rrMax = 2000, _rrMaxStep = 200;

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
}) {
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
  // "still" (for baseline selection) = motion near the night's typical low.
  bool still(int e) => motion[e] <= motMed + 1.5 * motMad;
  // "big move" = clearly elevated motion (getting up / large reposition), used
  // for the WAKE decision — a much higher bar than `still` so normal in-sleep
  // repositioning (which the van-Hees window already certified as sleep) is NOT
  // mistaken for wake.
  bool bigMove(int e) => motion[e] > motMed + 5.0 * motMad;

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

  final sleepRmssd = <double>[
    for (var e = 0; e < nEpoch; e++)
      if (still(e) && !rmssd[e].isNaN) rmssd[e]
  ];
  final rmssdMed = median(sleepRmssd);
  final hrSdSample = [for (final s in hrSd) if (s > 0) s];
  final hrSdMed = median(hrSdSample) ?? double.infinity;
  // Deep = HR in the lower half of the night's sleeping HR (the cardiac trough).
  // Stays a whole-night comparison (not part of the diagnosed bug; unchanged).
  final deepHrCut = hrFloor + 0.5 * (hrMedGlobal - hrFloor);

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
    // Asleep. REM vs NREM via autonomic signature.
    final rmZ = (rmssdMed != null && !rmssd[e].isNaN && sleepRmssd.length >= 4)
        ? robustZ(rmssd[e], sleepRmssd)
        : null;
    final rmssdDown = rmZ != null && rmZ < -0.4; // RMSSD notably below sleep base
    final hrTowardWake =
        !hr[e].isNaN && hr[e] >= hrP25Local[e]; // HR up but not arousal
    if (rmssdDown && hrTowardWake) {
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
          rmssdMed == null || rmssd[e].isNaN || rmssd[e] >= rmssdMed * 0.9;
      final stable = hrSd[e] <= hrSdMed * 1.5;
      deepFlag[e] = lowHr && notHighRmssd && stable;
    }
  }

  // ── post-process: Webster continuity (bridge brief arousals) + consolidate ──
  _websterRescore(stages, epochSec);
  final sm = consolidateSleepStages(stages, epochSec);
  _mergeShortDeep(deepFlag, sm, epochSec);

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
