// The pre-bump default staging path, frozen as a test oracle.
//
// Verbatim logic of `AdvancedSleepStager._stageSessionCardio` at analytics
// 83fc308 (the base of the combined bump), with only the class-private names
// qualified. It anchors every 30 s epoch at the START OF EACH USABLE RUN inside
// the session window: the first run at the first usable second at or after
// `start` (the session start when the data reaches it), and every later run at
// the first usable second after a dropout the 60 s carry-forward cannot bridge.
// Samples outside [start, end) are not read at all (features are clipped at the
// session edges).
//
// Grid option 2 (owner decision 2026-10-23) restores exactly this behaviour:
// `AdvancedSleepStager.stageWindow(...).stages` must equal this function.
import 'dart:math' as math;

import 'package:openstrap_analytics/onehz.dart';

List<StageSegment> preBumpStageSessionCardio(int start, int end,
    List<GravTs> grav, List<HrTs> hr, List<RrTs> rr) {
  final span = end - start;
  if (span <= 0) return const <StageSegment>[];
  const epSec = 30;
  const minStageableSec = 3 * epSec;
  if (span < minStageableSec) return [StageSegment(start, end, 'unobserved')];

  final gByTs = <int, GravTs>{
    for (final g in grav)
      if (g.valid && g.ts >= start && g.ts < end) g.ts: g
  };
  final hByTs = <int, HrTs>{
    for (final h in hr)
      if (h.ts >= start && h.ts < end) h.ts: h
  };
  final accel = List<AccelSample>.filled(
      span, AccelSample(start * 1000.0, 0, 0, 1.0));
  final hr1hz = List<double>.filled(span, 0.0);
  final usable = List<bool>.filled(span, false);
  var lastRealIdx = -1;
  for (var i = 0; i < span; i++) {
    final ts = start + i;
    final g = gByTs[ts];
    if (g != null) {
      accel[i] = AccelSample(ts * 1000.0, g.x, g.y, g.z);
      lastRealIdx = i;
      usable[i] = true;
    } else if (lastRealIdx >= 0 &&
        (i - lastRealIdx) <= AdvancedSleepStager.maxAccelCarryForwardSec) {
      final p = accel[i - 1];
      accel[i] = AccelSample(ts * 1000.0, p.x, p.y, p.z);
      usable[i] = true;
    }
    hr1hz[i] = hByTs[ts]?.bpm ?? 0.0;
  }

  final rSeg = [for (final r in rr) if (r.ts >= start && r.ts < end) r];
  final rrMs = [for (final r in rSeg) r.rrMs];
  final rrTsMs = [for (final r in rSeg) r.ts * 1000.0];

  final perSec = List<String>.filled(span, 'unobserved');
  var i = 0;
  while (i < span) {
    if (!usable[i]) {
      i++;
      continue;
    }
    var j = i;
    while (j < span && usable[j]) {
      j++;
    }
    if ((j - i) >= minStageableSec) {
      final result = cardioStager(
        hr1hz.sublist(i, j),
        accel.sublist(i, j),
        rrMs: rrMs,
        rrTsMs: rrTsMs,
      );
      final nEpoch = result.base.stages.length;
      for (var e = 0; e < nEpoch; e++) {
        final label = switch (result.base.stages[e]) {
          SleepStage.wake => 'wake',
          SleepStage.rem => 'rem',
          SleepStage.nrem => (e < result.deepFlag.length && result.deepFlag[e])
              ? 'deep'
              : 'light',
        };
        final lo = i + e * epSec;
        final hi = e == nEpoch - 1 ? j : math.min(j, lo + epSec);
        for (var k = lo; k < hi; k++) {
          perSec[k] = label;
        }
      }
    }
    i = j;
  }

  final segments = <StageSegment>[];
  var k = 0;
  while (k < span) {
    var m = k;
    while (m < span && perSec[m] == perSec[k]) {
      m++;
    }
    segments.add(StageSegment(start + k, start + m, perSec[k]));
    k = m;
  }
  return segments;
}

String showSegments(List<StageSegment> l) =>
    [for (final g in l) '${g.start}-${g.end}:${g.stage}'].join(' ');
