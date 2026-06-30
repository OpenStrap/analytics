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
//   3. cardioStager (motion+HR+RMSSD rule stager) over the WINDOW SLICE ONLY (hr + accel
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
import 'accounting.dart' show SleepStage;
import 'advanced_stager.dart';

/// Minimum in-bed duration to qualify as the main sleep (ARCHITECTURE_V2: ~3 h).
const int _minQualifyingSleepSec = 3 * 3600;

/// Single-source sleep segmentation result. Every accounting figure is derived
/// from the per-second [stages] labels (asleep = stage != wake), so the parts
/// are mutually consistent. When no sleep qualifies, see [SleepSegmentation.absent].
class SleepSegmentation {
  /// The in-bed window (van Hees REST window, optionally HR-refined). Null when absent.
  final SleepWindow? window;

  /// Per-second 3-class labels over the window [onsetIdx, offsetIdx).
  /// Empty when absent. `stages.length == inBedSec`. (Back-compat: wake/nrem/rem;
  /// NREM here is light+deep combined — the Light/Deep split lives in [stages4].)
  final List<SleepStage> stages;

  /// Per-second 4-class hypnogram-ready labels over the SAME window, aligned 1:1
  /// with [stages]: 'wake' | 'light' | 'deep' | 'rem'. 'light' and 'deep' are the
  /// two halves of NREM — 'deep' marks the NREM seconds the LOW-CONFIDENCE
  /// HR-depth overlay flags as deep (see walch_stager STEP 2); 'light' is the
  /// remaining NREM. The Light/Deep split is an UNVALIDATED estimate; surface it
  /// badged low-confidence. Empty when absent.
  final List<String> stages4;

  /// Total sleep time (s): seconds where stage != wake. Null when absent.
  final int? tstSec;

  /// Wake after sleep onset (s): wake seconds between first and last asleep
  /// second within the window. Null when absent.
  final int? wasoSec;

  /// In-bed time (s) = window length (offsetIdx − onsetIdx). Null when absent.
  final int? inBedSec;

  /// Sleep efficiency (%) = 100 · TST / in-bed. Null when absent.
  final double? efficiencyPct;

  /// NREM seconds (stage == nrem) = [lightSec] + [deepSec]. Null when absent.
  /// Kept for back-compat with any reader that still wants combined Core.
  final int? nremSec;

  /// Light-NREM seconds (4-class 'light'). Null when absent.
  final int? lightSec;

  /// Deep-NREM seconds (4-class 'deep') — LOW CONFIDENCE HR-depth overlay
  /// (unvalidated; not PSG). Null when absent.
  final int? deepSec;

  /// REM seconds (stage == rem). Null when absent.
  final int? remSec;

  /// Wake seconds within the window (stage == wake). Null when absent.
  final int? wakeSec;

  /// 0..1 confidence (van Hees window × staging × HR-consensus). 0 when absent.
  final double confidence;

  const SleepSegmentation({
    required this.window,
    required this.stages,
    required this.stages4,
    required this.tstSec,
    required this.wasoSec,
    required this.inBedSec,
    required this.efficiencyPct,
    required this.nremSec,
    required this.lightSec,
    required this.deepSec,
    required this.remSec,
    required this.wakeSec,
    required this.confidence,
  });

  /// Honest "no qualifying sleep" result — all figures null, confidence 0.
  static const SleepSegmentation absent = SleepSegmentation(
    window: null,
    stages: <SleepStage>[],
    stages4: <String>[],
    tstSec: null,
    wasoSec: null,
    inBedSec: null,
    efficiencyPct: null,
    nremSec: null,
    lightSec: null,
    deepSec: null,
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
        'light_sec': lightSec,
        'deep_sec': deepSec,
        'rem_sec': remSec,
        'wake_sec': wakeSec,
        'epochs': stages.length,
        'confidence': round6(confidence),
        // Deep is a LOW-CONFIDENCE, unvalidated HR-depth overlay (see
        // walch_stager STEP 2). Carry the flag so the UI badges it honestly.
        'deep_low_confidence': true,
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
  List<double> rrMs = const [],
  List<double> rrTsMs = const [],
  int? habitualMidsleepSec,
  ({int onsetSec, int offsetSec})? forcedWindow,
}) {
  final n = math.min(accel.length, hr1hz.length);
  // A forced window (manual entry / user confirmation, Approach 1) is asserted
  // by the human, so it skips the 3 h sample-count gate the auto path enforces —
  // a user may log a 2 h nap, and partial data inside the window is fine (those
  // seconds just stay unstaged/wake). We still need SOME data to stage.
  if (forcedWindow == null && n < _minQualifyingSleepSec) {
    return SleepSegmentation.absent;
  }
  if (n == 0) return SleepSegmentation.absent;

  final trimmedAccel = accel.sublist(0, n);
  final trimmedHr = hr1hz.sublist(0, n);
  // van Hees only runs on the AUTO path; a forced window replaces it entirely.
  final wm = forcedWindow == null
      ? vanHeesSleepWindow(trimmedAccel)
      : const Metric<SleepWindow>.absent(
          tier: Tier.estimate, inputs_used: ['forced_window']);
  final fallbackWindow = wm.value;

  final tzOffsetSeconds = DateTime.fromMillisecondsSinceEpoch(
    trimmedAccel.first.tsMs.toInt(),
    isUtc: false,
  ).timeZoneOffset.inSeconds;
  final grav = <GravTs>[
    for (var i = 0; i < n; i++)
      GravTs(
        trimmedAccel[i].tsMs ~/ 1000,
        trimmedAccel[i].x,
        trimmedAccel[i].y,
        trimmedAccel[i].z,
      ),
  ];
  final hr = <HrTs>[
    for (var i = 0; i < n; i++)
      if (trimmedHr[i] > 0) HrTs(trimmedAccel[i].tsMs ~/ 1000, trimmedHr[i])
  ];
  final rr = <RrTs>[
    for (var i = 0; i < math.min(rrMs.length, rrTsMs.length); i++)
      if (rrMs[i].isFinite && rrMs[i] > 0)
        RrTs((rrTsMs[i] / 1000.0).round(), rrMs[i])
  ];

  final _SleepGroup? chosen;
  if (forcedWindow != null) {
    final onsetSec = forcedWindow.onsetSec;
    final offsetSec = forcedWindow.offsetSec;
    if (offsetSec <= onsetSec) return SleepSegmentation.absent;
    // Stage the user-asserted window directly — no detection, no gates.
    final session =
        AdvancedSleepStager.stageWindow(onsetSec, offsetSec, grav, hr, rr: rr);
    chosen = _SleepGroup(
      sessions: [session],
      start: onsetSec,
      end: offsetSec,
      asleepMin: AdvancedSleepStager.hypnogramMetrics(session).tstS / 60.0,
      inBedSec: offsetSec - onsetSec,
    );
  } else {
    final sessions = AdvancedSleepStager.detectSleep(
      grav,
      hr,
      rr: rr,
      tzOffsetSec: tzOffsetSeconds,
    );
    if (sessions.isEmpty) return SleepSegmentation.absent;

    chosen = _pickMainSleepGroup(
      _bridgeAdjacentSessions(sessions),
      tzOffsetSeconds,
      habitualMidsleepSec: habitualMidsleepSec,
    );
  }
  if (chosen == null) return SleepSegmentation.absent;

  final tsSec = [for (final a in trimmedAccel) a.tsMs ~/ 1000];
  final onset = _lowerBoundInt(tsSec, chosen.start);
  final offset = _lowerBoundInt(tsSec, chosen.end);
  final inBed = chosen.end - chosen.start;
  if (inBed <= 0) return SleepSegmentation.absent;
  // The empty-index and 3 h in-bed floors are AUTO-path sanity gates; a forced
  // window is the user's word — honor any positive-length window.
  if (forcedWindow == null &&
      (offset <= onset || inBed < _minQualifyingSleepSec)) {
    return SleepSegmentation.absent;
  }

  final stages4 = List<String>.filled(inBed, 'wake');
  for (final session in chosen.sessions) {
    for (final seg in session.stages) {
      final lo = math.max(0, seg.start - chosen.start);
      final hi = math.min(inBed, seg.end - chosen.start);
      for (var i = lo; i < hi; i++) {
        stages4[i] = seg.stage;
      }
    }
  }

  final perSec = List<SleepStage>.generate(
    inBed,
    (i) => _sleepStageFor(stages4[i]),
    growable: false,
  );
  var tst = 0, waso = 0, nrem = 0, light = 0, deep = 0, rem = 0, wake = 0;
  var firstSleep = -1, lastSleep = -1;
  for (var i = 0; i < perSec.length; i++) {
    switch (perSec[i]) {
      case SleepStage.wake:
        wake++;
        break;
      case SleepStage.nrem:
        nrem++;
        tst++;
        if (stages4[i] == 'deep') {
          deep++;
        } else {
          light++;
        }
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
  if (firstSleep >= 0) {
    for (var i = firstSleep; i <= lastSleep; i++) {
      if (perSec[i] == SleepStage.wake) waso++;
    }
  }
  final efficiency = inBed > 0 ? 100.0 * tst / inBed : 0.0;
  final conf = clamp(((wm.confidence > 0 ? wm.confidence : 0.45) + 0.5) / 2.0, 0.0, 0.6);

  return SleepSegmentation(
    window: SleepWindow(
      onsetIdx: onset,
      offsetIdx: offset,
      onsetMs: chosen.start * 1000.0,
      offsetMs: chosen.end * 1000.0,
      immobile:
          fallbackWindow?.immobile ?? List<bool>.filled(trimmedAccel.length, false),
      zAngleDeg:
          fallbackWindow?.zAngleDeg ?? List<double>.filled(trimmedAccel.length, 0.0),
      sptSec: inBed,
    ),
    stages: perSec,
    stages4: stages4,
    tstSec: tst,
    wasoSec: waso,
    inBedSec: inBed,
    efficiencyPct: efficiency,
    nremSec: nrem,
    lightSec: light,
    deepSec: deep,
    remSec: rem,
    wakeSec: wake,
    confidence: conf,
  );
}

class _SleepGroup {
  final List<SleepSession> sessions;
  final int start;
  final int end;
  final double asleepMin;
  final int inBedSec;

  const _SleepGroup({
    required this.sessions,
    required this.start,
    required this.end,
    required this.asleepMin,
    required this.inBedSec,
  });
}

List<_SleepGroup> _bridgeAdjacentSessions(List<SleepSession> sessions) {
  if (sessions.isEmpty) return const [];
  final sorted = [...sessions]..sort((a, b) => a.start.compareTo(b.start));
  const bridgeGapSec = 60 * 60;
  final out = <_SleepGroup>[];
  for (final session in sorted) {
    final asleepMin = AdvancedSleepStager.hypnogramMetrics(session).tstS / 60.0;
    if (out.isEmpty) {
      out.add(
        _SleepGroup(
          sessions: [session],
          start: session.start,
          end: session.end,
          asleepMin: asleepMin,
          inBedSec: session.end - session.start,
        ),
      );
      continue;
    }
    final last = out.removeLast();
    final gap = session.start - last.end;
    if (gap >= 0 && gap < bridgeGapSec) {
      out.add(
        _SleepGroup(
          sessions: [...last.sessions, session],
          start: last.start,
          end: math.max(last.end, session.end),
          asleepMin: last.asleepMin + asleepMin,
          inBedSec: last.inBedSec + (session.end - session.start),
        ),
      );
    } else {
      out.add(last);
      out.add(
        _SleepGroup(
          sessions: [session],
          start: session.start,
          end: session.end,
          asleepMin: asleepMin,
          inBedSec: session.end - session.start,
        ),
      );
    }
  }
  return out;
}

_SleepGroup? _pickMainSleepGroup(
  List<_SleepGroup> groups,
  int tzOffsetSeconds, {
  int? habitualMidsleepSec,
}) {
  if (groups.isEmpty) return null;
  const alignmentBonusMin = 90.0;
  const fullWindowSec = 2 * 3600;
  const zeroWindowSec = 5 * 3600;
  const overnightStartHour = 20;
  const overnightEndHour = 11;
  const secondsPerDay = 86400;
  final overnightSpanSec =
      (((overnightEndHour - overnightStartHour) * 3600) + secondsPerDay) %
          secondsPerDay;
  final coldStartAnchorSec =
      ((overnightStartHour * 3600) + overnightSpanSec ~/ 2) % secondsPerDay;
  final targetMidsleepSec = habitualMidsleepSec ?? coldStartAnchorSec;

  int localSecOfDay(int ts) {
    final local = ts + tzOffsetSeconds;
    return ((local % secondsPerDay) + secondsPerDay) % secondsPerDay;
  }

  int circularDistanceSec(int a, int b) {
    final raw = (a - b).abs() % secondsPerDay;
    return math.min(raw, secondsPerDay - raw);
  }

  double alignmentBonusFor(_SleepGroup g) {
    final mid = g.start + (g.inBedSec ~/ 2);
    final dist = circularDistanceSec(localSecOfDay(mid), targetMidsleepSec);
    if (dist <= fullWindowSec) return alignmentBonusMin;
    if (dist >= zeroWindowSec) return 0.0;
    final frac = (zeroWindowSec - dist) / (zeroWindowSec - fullWindowSec);
    return alignmentBonusMin * frac;
  }

  _SleepGroup winner = groups.first;
  var bestScore = winner.asleepMin + alignmentBonusFor(winner);
  for (final g in groups.skip(1)) {
    final score = g.asleepMin + alignmentBonusFor(g);
    if (score > bestScore ||
        (score == bestScore &&
            g.start < winner.start)) {
      winner = g;
      bestScore = score;
    }
  }
  return winner;
}

int? habitualMidsleepSecFromHistory(
  List<({int startSec, int endSec, String dayKey})> history, {
  required int tzOffsetSeconds,
  int minDays = 14,
}) {
  if (history.isEmpty) return null;
  final longestByDay = <String, ({int startSec, int endSec, String dayKey})>{};
  for (final block in history) {
    final cur = longestByDay[block.dayKey];
    final dur = block.endSec - block.startSec;
    final curDur = cur == null ? -1 : cur.endSec - cur.startSec;
    if (cur == null ||
        dur > curDur ||
        (dur == curDur && block.startSec < cur.startSec)) {
      longestByDay[block.dayKey] = block;
    }
  }
  if (longestByDay.length < minDays) return null;
  final mids = [
    for (final block in longestByDay.values)
      _localSecOfDay(
        block.startSec + ((block.endSec - block.startSec) ~/ 2),
        tzOffsetSeconds,
      ),
  ];
  return _circularMeanSec(mids);
}

int _localSecOfDay(int ts, int offsetSec) {
  const secondsPerDay = 86400;
  final local = ts + offsetSec;
  return ((local % secondsPerDay) + secondsPerDay) % secondsPerDay;
}

int? _circularMeanSec(List<int> secs) {
  if (secs.isEmpty) return null;
  const secondsPerDay = 86400;
  const minResultant = 1e-9;
  var sumSin = 0.0;
  var sumCos = 0.0;
  final k = 2.0 * math.pi / secondsPerDay;
  for (final s in secs) {
    final a = s * k;
    sumSin += math.sin(a);
    sumCos += math.cos(a);
  }
  final resultant = math.sqrt(sumSin * sumSin + sumCos * sumCos) / secs.length;
  if (resultant < minResultant) return null;
  var ang = math.atan2(sumSin, sumCos);
  if (ang < 0) ang += 2.0 * math.pi;
  final sec = (ang / k).round() % secondsPerDay;
  return ((sec % secondsPerDay) + secondsPerDay) % secondsPerDay;
}

SleepStage _sleepStageFor(String label) {
  switch (label) {
    case 'rem':
      return SleepStage.rem;
    case 'light':
    case 'deep':
      return SleepStage.nrem;
    default:
      return SleepStage.wake;
  }
}

int _lowerBoundInt(List<int> xs, int target) {
  var lo = 0, hi = xs.length;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (xs[mid] < target) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  return lo;
}
