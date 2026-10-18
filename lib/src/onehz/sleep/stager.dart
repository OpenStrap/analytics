// SLEEP/CIRCADIAN — the shared stage-architecture consolidation post-step and
// the [StagerResult] shape the stagers return.
//
// The 3-class `autonomicStager` that used to live here is GONE (2026-08): it
// was deprecated, hidden from the barrel and reachable only from its own test,
// and it conflated epoch count with sample count (`n ~/ epochSec` assumes a
// 1 Hz stream, so any other cadence silently rescaled every epoch). The live
// stager is `cardioStager` (cardio_stager.dart), which reuses everything below.
// Its arousal-bridging pass lives in cardio_stager.dart only: this file used to
// carry a second copy with a wider rule table (15 min of sleep bridged 5 min of
// wake, not 4) that no stager called any more but the barrel still exported.
//
// HONESTY CEILING (catalog rule 5): wrist staging is at best a 3-class
// AUTONOMIC ESTIMATE, never a PSG 4-stage hypnogram. We NEVER emit N1/N2/N3.
// This is tier ESTIMATE.

import '../util.dart';
import 'accounting.dart' show SleepStage;

class StagerResult {
  final List<SleepStage> stages; // per-epoch
  final int epochSec;
  final double wakePct;
  final double nremPct;
  final double remPct;
  const StagerResult({
    required this.stages,
    required this.epochSec,
    required this.wakePct,
    required this.nremPct,
    required this.remPct,
  });
  Map<String, dynamic> toJson() => {
        'epoch_sec': epochSec,
        'wake_pct': round6(wakePct),
        'nrem_pct': round6(nremPct),
        'rem_pct': round6(remPct),
        'epochs': stages.length,
      };
}

/// Minimum sustained REM episode (min) and minimum NREM/REM bout (min) for the
/// architecture-consolidation post-step. ~5 min reflects the shortest credible
/// REM episode and merges sub-5-min stage flicker into the surrounding stage.
const double remEpisodeMinMin = 5.0;
const double stageBoutMinMin = 5.0;

/// PUBLIC, PURE consolidation of a per-epoch 3-class stage stream into sustained
/// NREM/REM bouts (returns a new list; does not mutate [stages]). Exposed so the
/// edge — and tests — can consolidate a raw label stream directly. See
/// [_consolidateStages] for the rules; WAKE bouts are preserved.
List<SleepStage> consolidateSleepStages(List<SleepStage> stages, int epochSec) {
  final out = List<SleepStage>.from(stages);
  _consolidateStages(out, epochSec);
  return out;
}

/// Consolidate the asleep micro-structure (in place) into sustained NREM/REM
/// bouts so the hypnogram reads as a few cycles, not per-epoch jitter.
///
/// Step 1 — REM-episode gap-bridge: within the asleep span, a NREM gap shorter
///          than [remEpisodeMinMin] that sits BETWEEN two REM runs is rescored
///          to REM (one fragmented episode, not two). WAKE is never bridged.
/// Step 2 — minimum-bout merge: any NREM/REM bout shorter than [stageBoutMinMin]
///          is merged into the LONGER adjacent asleep bout (or its only
///          neighbour). Repeated to a fixed point. WAKE bouts are left intact.
/// Totals are preserved to within ±one bout (a short bout is reassigned whole).
void _consolidateStages(List<SleepStage> sm, int epochSec) {
  final n = sm.length;
  if (n == 0) return;
  final remGapEp = (remEpisodeMinMin * 60.0 / epochSec).round();
  final minBoutEp = (stageBoutMinMin * 60.0 / epochSec).round();
  if (minBoutEp <= 1 && remGapEp <= 1) return;

  bool isSleep(SleepStage s) => s != SleepStage.wake;

  // --- Step 1: bridge short NREM gaps INSIDE a genuine REM episode. ----------
  // Walk runs; a NREM run shorter than remGapEp is rescored to REM only when it
  // is flanked on BOTH sides by REM, the joined episode reaches remGapEp, and
  // the flanking REM is at least as long as the gap — i.e. it is a brief
  // intrusion inside one REM episode, not a NREM stretch between stray REM
  // blips (those are left for step 2 to absorb into NREM).
  {
    // Precompute run boundaries.
    final runs = <List<int>>[];
    var p = 0;
    while (p < n) {
      var q = p;
      while (q < n && sm[q] == sm[p]) {
        q++;
      }
      runs.add([p, q]);
      p = q;
    }
    for (var ri = 0; ri < runs.length; ri++) {
      final start = runs[ri][0], end = runs[ri][1];
      if (sm[start] != SleepStage.nrem) continue;
      final gapLen = end - start;
      if (gapLen >= remGapEp) continue;
      final left = (ri > 0 && sm[runs[ri - 1][0]] == SleepStage.rem)
          ? runs[ri - 1][1] - runs[ri - 1][0]
          : 0;
      final right = (ri + 1 < runs.length && sm[runs[ri + 1][0]] == SleepStage.rem)
          ? runs[ri + 1][1] - runs[ri + 1][0]
          : 0;
      // Bridge only when both sides are REM, the joined episode is ≥ remGapEp,
      // AND the REM outweighs the gap. Without that last check two 2-epoch
      // blips around a 9-epoch NREM gap became 13 epochs of REM. Requiring
      // left + right ≥ remGapEp instead cut the real Apple-Watch-labelled
      // night from 150 to 87 min REM (truth 162); this costs it 5.
      if (left > 0 && right > 0 && left + right >= gapLen &&
          left + right + gapLen >= remGapEp) {
        for (var k = start; k < end; k++) {
          sm[k] = SleepStage.rem;
        }
      }
    }
  }

  // --- Step 2: merge short asleep bouts into the longer adjacent asleep bout.
  // Iterate to a fixed point (merging can create a new short bout).
  var changed = true;
  while (changed) {
    changed = false;
    // Build run boundaries.
    final runs = <List<int>>[]; // [start, endExclusive]
    var p = 0;
    while (p < n) {
      var q = p;
      while (q < n && sm[q] == sm[p]) {
        q++;
      }
      runs.add([p, q]);
      p = q;
    }
    for (var ri = 0; ri < runs.length; ri++) {
      final start = runs[ri][0], end = runs[ri][1];
      final stage = sm[start];
      if (!isSleep(stage)) continue; // never merge wake
      if ((end - start) >= minBoutEp) continue;
      // Find adjacent asleep neighbours.
      SleepStage? left, right;
      var leftLen = 0, rightLen = 0;
      if (ri > 0 && isSleep(sm[runs[ri - 1][0]])) {
        left = sm[runs[ri - 1][0]];
        leftLen = runs[ri - 1][1] - runs[ri - 1][0];
      }
      if (ri + 1 < runs.length && isSleep(sm[runs[ri + 1][0]])) {
        right = sm[runs[ri + 1][0]];
        rightLen = runs[ri + 1][1] - runs[ri + 1][0];
      }
      SleepStage? target;
      if (left != null && right != null) {
        target = leftLen >= rightLen ? left : right;
      } else if (left != null) {
        target = left;
      } else if (right != null) {
        target = right;
      } else {
        continue; // isolated short bout between wake on both sides — leave it
      }
      if (target == stage) continue;
      for (var k = start; k < end; k++) {
        sm[k] = target;
      }
      changed = true;
      break; // re-scan from scratch after a merge
    }
  }
}
