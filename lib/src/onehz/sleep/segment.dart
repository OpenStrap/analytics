// SLEEP — SINGLE-SOURCE segmentation entry point.
//
// ARCHITECTURE_V2 invariant 2/4 + "Segmentation (FROZEN — single source)":
// exactly ONE sleep/wake/stage windowing. No component re-detects sleep; every
// downstream figure (TST, WASO, efficiency, stage minutes, hypnogram) derives
// from the SAME per-second stage labels produced here. There is no second
// estimator — this is THE source.
//
// Pipeline:
//   1. vanHeesSleepWindow(accel) with the published 30-min bridge gap → the
//      in-bed REST window [onsetIdx, offsetIdx) + the per-second immobility mask.
//   2. (optional) nocturnal-HR-dip consensus: when a daytime [hrBaseline] is
//      supplied, confirm/refine onset & offset to where HR sustains below the
//      baseline (the cardiac signature of sleep), tightening — never widening —
//      the accel window. This is a CONSENSUS refinement, not a second detector.
//   3. walchStager (Walch et al. 2019) over the WINDOW SLICE ONLY (hr + accel
//      sliced to [onsetIdx, offsetIdx)) → validated 3-class wake/NREM/REM per
//      epoch. (Replaces the deprecated hand-rolled autonomicStager.)
//   4. Expand the per-epoch stages to PER-SECOND labels over the window, and
//      derive TST/WASO/efficiency/stage-seconds ALL from those labels
//      (asleep = stage != wake), so they are mutually consistent and consistent
//      with any hypnogram built from `stages`.
//
// HONESTY: if no qualifying sleep (no window, or in-bed < ~3 h, or staging
// cannot run) we return SleepSegmentation.absent — everything null, confidence
// 0. Never fabricated. Stages are tier ESTIMATE (3-class autonomic, not PSG).

import 'dart:math' as math;
import '../types.dart';
import '../util.dart';
import 'van_hees.dart';
import 'walch_stager.dart';
import 'accounting.dart' show SleepStage;

/// Minimum in-bed duration to qualify as the main sleep (ARCHITECTURE_V2: ~3 h).
const int _minQualifyingSleepSec = 3 * 3600;

/// Single-source sleep segmentation result. Every accounting figure is derived
/// from the per-second [stages] labels (asleep = stage != wake), so the parts
/// are mutually consistent. When no sleep qualifies, see [SleepSegmentation.absent].
class SleepSegmentation {
  /// The in-bed window (van Hees REST window, optionally HR-refined). Null when absent.
  final SleepWindow? window;

  /// Per-second 3-class labels over the window [onsetIdx, offsetIdx).
  /// Empty when absent. `stages.length == inBedSec`.
  final List<SleepStage> stages;

  /// Total sleep time (s): seconds where stage != wake. Null when absent.
  final int? tstSec;

  /// Wake after sleep onset (s): wake seconds between first and last asleep
  /// second within the window. Null when absent.
  final int? wasoSec;

  /// In-bed time (s) = window length (offsetIdx − onsetIdx). Null when absent.
  final int? inBedSec;

  /// Sleep efficiency (%) = 100 · TST / in-bed. Null when absent.
  final double? efficiencyPct;

  /// NREM seconds (stage == nrem). Null when absent.
  final int? nremSec;

  /// REM seconds (stage == rem). Null when absent.
  final int? remSec;

  /// Wake seconds within the window (stage == wake). Null when absent.
  final int? wakeSec;

  /// 0..1 confidence (van Hees window × staging × HR-consensus). 0 when absent.
  final double confidence;

  const SleepSegmentation({
    required this.window,
    required this.stages,
    required this.tstSec,
    required this.wasoSec,
    required this.inBedSec,
    required this.efficiencyPct,
    required this.nremSec,
    required this.remSec,
    required this.wakeSec,
    required this.confidence,
  });

  /// Honest "no qualifying sleep" result — all figures null, confidence 0.
  static const SleepSegmentation absent = SleepSegmentation(
    window: null,
    stages: <SleepStage>[],
    tstSec: null,
    wasoSec: null,
    inBedSec: null,
    efficiencyPct: null,
    nremSec: null,
    remSec: null,
    wakeSec: null,
    confidence: 0,
  );

  bool get present => window != null;

  Map<String, dynamic> toJson() => {
        'window': window?.toJson(),
        'tst_sec': tstSec,
        'waso_sec': wasoSec,
        'in_bed_sec': inBedSec,
        'efficiency_pct':
            efficiencyPct == null ? null : round6(efficiencyPct!),
        'nrem_sec': nremSec,
        'rem_sec': remSec,
        'wake_sec': wakeSec,
        'epochs': stages.length,
        'confidence': round6(confidence),
      };
}

/// THE single-source sleep segmentation.
///
/// [accel] 1 Hz gravity vectors. [hr1hz] 1 Hz HR (bpm; 0 = off-skin), same time
/// base / length as [accel]. [hrBaseline] optional daytime HR samples (bpm) used
/// for a nocturnal-HR-dip consensus that refines onset/offset; when omitted the
/// accel window stands alone.
SleepSegmentation segmentSleep(
  List<AccelSample> accel,
  List<double> hr1hz, {
  List<double>? hrBaseline,
}) {
  // 1. van Hees REST window (30-min bridge baked into vanHeesSleepWindow).
  final wm = vanHeesSleepWindow(accel);
  final w = wm.value;
  if (w == null) return SleepSegmentation.absent;

  var onset = w.onsetIdx;
  var offset = math.min(w.offsetIdx, math.min(accel.length, hr1hz.length));
  if (offset <= onset) return SleepSegmentation.absent;

  // 2. Optional nocturnal-HR-dip consensus: tighten (never widen) onset/offset
  //    to where HR sustains below the daytime baseline. The cardiac trough is
  //    the physiological confirmation of sleep; this trims pre-sleep / post-wake
  //    lying-still that the accel window can over-include.
  var hrConsensus = 1.0;
  if (hrBaseline != null) {
    final baseValid = hrBaseline.where((h) => h > 0).toList();
    final baseMed = median(baseValid);
    if (baseMed != null && baseValid.length >= 3) {
      // Sleep HR is sustained below the daytime median (a conservative dip
      // threshold of ~95% of the daytime median; sleep HR typically dips ≥10%).
      final thresh = 0.95 * baseMed;
      const sustain = 300; // 5-min sustained below-baseline to confirm a bound
      final refined =
          _refineByHrDip(hr1hz, onset, offset, thresh, sustain);
      if (refined != null) {
        onset = refined[0];
        offset = refined[1];
        hrConsensus = 0.95; // agreement found
      } else {
        // No sustained cardiac dip inside the window: keep the accel window but
        // lower confidence (honest — the two signals disagree).
        hrConsensus = 0.6;
      }
    }
  }

  final inBed = offset - onset;
  if (inBed < _minQualifyingSleepSec) return SleepSegmentation.absent;

  // 3. Stager over the WINDOW SLICE ONLY — Walch et al. 2019 (validated 3-class
  //    wrist stager) replaces the hand-rolled autonomicStager. Walch consumes
  //    HR + raw accel (it derives its own motion/HR/cosine features). The
  //    cosine sleep-drive feature is anchored to ELAPSED time from window onset
  //    (clockHourAtStart = null), EXACTLY matching Walch's `build_cosine`
  //    (cosine_proxy of epoch.timestamp − first_timestamp): the window onset IS
  //    the model's t0, so the sleep-drive cosine sweeps toward its trough ~5 h
  //    in. This is the convention the embedded coefficients were trained under;
  //    passing a wall-clock hour here would introduce train/serve phase skew.
  final hrSlice = hr1hz.sublist(onset, offset);
  final accelSlice = accel.sublist(onset, offset);
  final sm = walchStager(hrSlice, accelSlice, clockHourAtStart: null);
  final st = sm.value;
  if (st == null) return SleepSegmentation.absent;

  // 4. Expand per-epoch stages to PER-SECOND over the window, then derive every
  //    figure from these labels (asleep = stage != wake) — the SINGLE source.
  final perSec = _expandToPerSecond(st.stages, st.epochSec, inBed);
  var tst = 0, waso = 0, nrem = 0, rem = 0, wake = 0;
  var firstSleep = -1, lastSleep = -1;
  for (var i = 0; i < perSec.length; i++) {
    switch (perSec[i]) {
      case SleepStage.wake:
        wake++;
        break;
      case SleepStage.nrem:
        nrem++;
        tst++;
        break;
      case SleepStage.rem:
        rem++;
        tst++;
        break;
    }
    if (perSec[i] != SleepStage.wake) {
      if (firstSleep < 0) firstSleep = i;
      lastSleep = i;
    }
  }
  // WASO = wake seconds strictly between first and last asleep second.
  if (firstSleep >= 0) {
    for (var i = firstSleep; i <= lastSleep; i++) {
      if (perSec[i] == SleepStage.wake) waso++;
    }
  }
  final efficiency = inBed > 0 ? 100.0 * tst / inBed : 0.0;

  // Confidence = window conf × staging conf × HR-consensus, bounded by the
  // staging ESTIMATE ceiling (never claim more certainty than the stager).
  final conf =
      clamp(wm.confidence * sm.confidence * hrConsensus, 0.0, sm.confidence);

  return SleepSegmentation(
    window: SleepWindow(
      onsetIdx: onset,
      offsetIdx: offset,
      onsetMs: onset < accel.length ? accel[onset].tsMs : w.onsetMs,
      offsetMs: (offset - 1) < accel.length && (offset - 1) >= 0
          ? accel[offset - 1].tsMs
          : w.offsetMs,
      immobile: w.immobile,
      zAngleDeg: w.zAngleDeg,
      sptSec: inBed,
    ),
    stages: perSec,
    tstSec: tst,
    wasoSec: waso,
    inBedSec: inBed,
    efficiencyPct: efficiency,
    nremSec: nrem,
    remSec: rem,
    wakeSec: wake,
    confidence: conf,
  );
}

/// Tighten [onset,offset) to the first/last second of a sustained (≥[sustain] s)
/// run of HR below [thresh]. Returns null if no such sustained dip exists in the
/// window (signals disagree). HR=0 (off-skin) does not count as "below".
List<int>? _refineByHrDip(
    List<double> hr, int onset, int offset, double thresh, int sustain) {
  // below[i] = valid HR sample under the dip threshold.
  int? firstDip, lastDip;
  var run = 0;
  for (var i = onset; i < offset; i++) {
    final h = i < hr.length ? hr[i] : 0.0;
    final below = h > 0 && h < thresh;
    if (below) {
      run++;
      if (run >= sustain) {
        firstDip ??= i - run + 1;
        lastDip = i;
      }
    } else {
      run = 0;
    }
  }
  if (firstDip == null || lastDip == null) return null;
  // Tighten only: never push the bound outward past the accel window.
  final newOnset = math.max(onset, firstDip);
  final newOffset = math.min(offset, lastDip + 1);
  if (newOffset <= newOnset) return null;
  return [newOnset, newOffset];
}

/// Expand per-epoch [stages] (each [epochSec] long) to a per-second vector of
/// length [lenSec], clamping the final partial epoch.
List<SleepStage> _expandToPerSecond(
    List<SleepStage> stages, int epochSec, int lenSec) {
  final out = List<SleepStage>.filled(lenSec, SleepStage.wake);
  for (var i = 0; i < lenSec; i++) {
    final e = i ~/ epochSec;
    out[i] = e < stages.length ? stages[e] : SleepStage.wake;
  }
  return out;
}
