// Target upstream main 9db83ce default staging path, frozen as a test oracle.
// The former pre-bump oracle now uses main's pooled night baselines, per-run
// coverage gate and run-boundary continuity. Only private names are qualified.
import 'package:openstrap_analytics/onehz.dart';

List<StageSegment> preBumpStageSessionCardio(int start, int end,
      List<GravTs> grav, List<HrTs> hr, List<RrTs> rr) {
    final span = end - start;
    if (span <= 0) return const <StageSegment>[];
    final epSec = AdvancedSleepStager.epochS.round();
    final minStageableSec = 3 * epSec;
    if (span < minStageableSec) return [StageSegment(start, end, 'unobserved')];

    // Invalid samples are NOT samples: they must not seed `usable`, and they
    // must not become the source of a carry-forward. A second with only an
    // undecoded vector falls through to the same unstaged→unobserved path as a
    // second with no row at all (cardioStager itself never reads
    // [AccelSample.valid], so it can only be protected here).
    final gByTs = <int, GravTs>{
      for (final g in grav)
        if (g.valid && g.ts >= start && g.ts < end) g.ts: g
    };
    final hByTs = <int, HrTs>{for (final h in hr) if (h.ts >= start && h.ts < end) h.ts: h};
    final accel = List<AccelSample>.filled(
        span, AccelSample(start * 1000.0, 0, 0, 1.0));
    final hr1hz = List<double>.filled(span, 0.0);
    // usable[i] — second i has a real accel sample or a BOUNDED carry-forward.
    final usable = List<bool>.filled(span, false);
    var lastRealIdx = -1;
    for (var i = 0; i < span; i++) {
      final ts = start + i;
      final g = gByTs[ts];
      if (g != null) {
        accel[i] = AccelSample(ts * 1000.0, g.x, g.y, g.z);
        lastRealIdx = i;
        usable[i] = true;
      } else if (lastRealIdx >= 0 && (i - lastRealIdx) <= AdvancedSleepStager.maxAccelCarryForwardSec) {
        // Bounded carry-forward — see [maxAccelCarryForwardSec]. The TIMESTAMP
        // is this second's, not the stale sample's: cardioStager centres its RR
        // windows on `accel[mid].tsMs`, so copying the old sample wholesale
        // mis-centred every RMSSD/LF-HF window inside a gap.
        final p = accel[i - 1];
        accel[i] = AccelSample(ts * 1000.0, p.x, p.y, p.z);
        usable[i] = true;
      }
      hr1hz[i] = hByTs[ts]?.bpm ?? 0.0; // 0 = off-skin, cardioStager's own contract.
    }

    final rSeg = [for (final r in rr) if (r.ts >= start && r.ts < end) r];
    final rrMs = [for (final r in rSeg) r.rrMs];
    final rrTsMs = [for (final r in rSeg) r.ts * 1000.0];

    // Everything not staged below stays 'unobserved' — no stage, no wake.
    final perSec = List<String>.filled(span, 'unobserved');
    // Stageable runs. All but the last are trimmed to whole epochs so every run
    // boundary sits on the epoch grid; cardioStager scores no sub-epoch tail
    // anyway, and the tail takes the run's last label below.
    final runs = <({int from, int to, int nEp})>[];
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
        final nEp = (j - i) ~/ epSec;
        // cardioStager's HR-coverage abstention, applied per run as it was
        // when each run was staged alone: pooled with well-covered runs, a run
        // with no HR would pass the window-wide gate and fall through to NREM.
        var withHr = 0;
        for (var e = 0; e < nEp; e++) {
          final lo = i + e * epSec;
          for (var k = lo; k < lo + epSec; k++) {
            if (hr1hz[k] > 0) {
              withHr++;
              break;
            }
          }
        }
        if (withHr >= minHrCoverage * nEp) {
          runs.add((from: i, to: j, nEp: nEp));
        }
      }
      i = j;
    }

    if (runs.isNotEmpty) {
      final hrCat = <double>[];
      final accelCat = <AccelSample>[];
      final runStarts = <int>[];
      for (var ri = 0; ri < runs.length; ri++) {
        final r = runs[ri];
        runStarts.add(hrCat.length);
        // The last run keeps its tail (no boundary follows it), so a window
        // with a single run is staged exactly as before.
        final stop = ri == runs.length - 1 ? r.to : r.from + r.nEp * epSec;
        hrCat.addAll(hr1hz.sublist(r.from, stop));
        accelCat.addAll(accel.sublist(r.from, stop));
      }
      final result = cardioStager(
        hrCat,
        accelCat,
        rrMs: rrMs,
        rrTsMs: rrTsMs,
        runStarts: runStarts,
      );
      final stages = result.base.stages;
      // Empty = cardioStager abstained: everything stays 'unobserved'.
      if (stages.isNotEmpty) {
        var g = 0; // epoch index into the concatenated result
        for (final r in runs) {
          for (var e = 0; e < r.nEp; e++, g++) {
            if (g >= stages.length) break;
            final label = switch (stages[g]) {
              SleepStage.wake => 'wake',
              SleepStage.rem => 'rem',
              SleepStage.nrem =>
                (g < result.deepFlag.length && result.deepFlag[g])
                    ? 'deep'
                    : 'light',
            };
            final lo = r.from + e * epSec;
            // The last epoch absorbs the run's sub-epoch remainder, exactly as
            // [_buildSegments] extends the final segment to the window end.
            final hi = e == r.nEp - 1 ? r.to : lo + epSec;
            for (var k = lo; k < hi; k++) {
              perSec[k] = label;
            }
          }
        }
      }
    }

    // Coalesce the per-second labels into contiguous [StageSegment]s tiling
    // [start, end) — same segment semantics [_buildSegments] produces.
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
