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
//   motion = mean ENMO (van Hees 2013 amplitude index, g)
//   hr     = mean valid HR (bpm)
//   rmssd  = RMSSD of cleaned RR beats in a ±2.5-min window (ms), or null
// then classify against night baselines:
//   WAKE  : clearly elevated motion OR HR arousal above the sleeping median
//   REM   : still body + RMSSD well BELOW the night's sleep RMSSD + HR ≥ NREM median
//   DEEP  : HR near the night floor + RMSSD high + very stable (NREM subtype)
//   LIGHT : remaining NREM
// Post: Webster continuity rescore (bridges brief arousals into sleep — this is
// what kills the over-call) + consolidateSleepStages (no single-epoch flicker).
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

  // ── per-second ENMO (motion), with auto-calibrated 1 g reference ───────────
  final mag = List<double>.filled(n, 0);
  for (var i = 0; i < n; i++) {
    final a = accel[i];
    mag[i] = math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z);
  }
  final gRef = _calibrateG(mag);
  final enmo = [for (final m in mag) (m - gRef) > 0 ? (m - gRef) : 0.0];

  // ── per-epoch features ─────────────────────────────────────────────────────
  final motion = List<double>.filled(nEpoch, 0);
  final hr = List<double>.filled(nEpoch, double.nan);
  final hrSd = List<double>.filled(nEpoch, 0);
  final rmssd = List<double>.filled(nEpoch, double.nan);

  for (var e = 0; e < nEpoch; e++) {
    final s = e * epochSec, t = math.min(s + epochSec, n);
    // motion = mean ENMO over the epoch
    var ms = 0.0;
    for (var i = s; i < t; i++) {
      ms += enmo[i];
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
  final hrMed = median(sleepHr) ?? (mean([for (final h in hr) if (!h.isNaN) h]) ?? 60);
  final hrFloor = percentile(sleepHr, 10) ?? hrMed;
  final hrArousal = hrMed + math.max(6.0, (stddev(sleepHr) ?? 6));

  final sleepRmssd = <double>[
    for (var e = 0; e < nEpoch; e++)
      if (still(e) && !rmssd[e].isNaN) rmssd[e]
  ];
  final rmssdMed = median(sleepRmssd);
  final hrSdSample = [for (final s in hrSd) if (s > 0) s];
  final hrSdMed = median(hrSdSample) ?? double.infinity;
  // Deep = HR in the lower half of the night's sleeping HR (the cardiac trough).
  final deepHrCut = hrFloor + 0.5 * (hrMed - hrFloor);

  // ── classify ───────────────────────────────────────────────────────────────
  final stages = List<SleepStage>.filled(nEpoch, SleepStage.wake);
  final deepFlag = List<bool>.filled(nEpoch, false);
  for (var e = 0; e < nEpoch; e++) {
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
    final hrTowardWake = !hr[e].isNaN && hr[e] >= hrMed; // HR up but not arousal
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

/// Auto-calibrate 1 g: median magnitude over the low-motion portion.
double _calibrateG(List<double> mag) {
  if (mag.isEmpty) return 1.0;
  final steps = <double>[
    for (var i = 1; i < mag.length; i++) (mag[i] - mag[i - 1]).abs()
  ];
  final stepMed = steps.isNotEmpty ? (median(steps) ?? 0) : 0;
  final still = <double>[
    for (var i = 1; i < mag.length; i++)
      if ((mag[i] - mag[i - 1]).abs() <= stepMed) mag[i]
  ];
  final g = still.isNotEmpty ? median(still) : median(mag);
  return (g == null || g <= 0 || g.isNaN) ? 1.0 : g;
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
