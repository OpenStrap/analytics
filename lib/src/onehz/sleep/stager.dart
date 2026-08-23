// SLEEP/CIRCADIAN — the shared staging POST-PROCESSING (Webster rescore +
// stage-architecture consolidation) and the [StagerResult] shape both stagers
// return.
//
// The 3-class `autonomicStager` that used to live here is GONE (2026-08): it
// was deprecated, hidden from the barrel and reachable only from its own test,
// and it conflated epoch count with sample count (`n ~/ epochSec` assumes a
// 1 Hz stream, so any other cadence silently rescaled every epoch). The live
// stager is `cardioStager` (cardio_stager.dart), which reuses everything below.
//
// HONESTY CEILING (catalog rule 5): wrist staging is at best a 3-class
// AUTONOMIC ESTIMATE, never a PSG 4-stage hypnogram. We NEVER emit N1/N2/N3.
// This is tier ESTIMATE.

import 'dart:math' as math;
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

/// Test seam for [_websterRescore] — exposed (non-private) so the regression
/// test can drive the continuity rule directly. Not part of the public barrel.
void websterRescoreAutonomic(List<SleepStage> sm, int epochSec) =>
    _websterRescore(sm, epochSec);

/// Webster/Cole-Kripke sleep-continuity rescoring (in place).
///
/// After sleep onset (first sleep epoch), a contiguous run of WAKE epochs that
/// is short enough relative to the SUSTAINED sleep bracketing it is rescored to
/// SLEEP (NREM) — it is an arousal, not real WASO. Runs longer than the
/// allowed bout, or with insufficient surrounding sleep, are LEFT as wake (a
/// genuine, sustained awakening). Rules (Webster, in epochs):
///   sleep-before ≥ 4 min  AND wake-run ≤ 1 min → sleep
///   sleep-before ≥10 min  AND wake-run ≤ 3 min → sleep
///   sleep-before ≥15 min  AND wake-run ≤ 5 min → sleep
/// The top row is 5, not Webster's 4, and the widening is deliberate: it
/// absorbs the van Hees 5-min mask-smear artifact. See the rules table below.
/// `cardio_stager`'s copy runs the published 4 because van Hees does not run
/// on its forced-window paths at all.
/// "sleep-before" is satisfied by sustained sleep on EITHER bracketing side,
/// so an arousal sandwiched between two long sleep bouts is bridged.
///
/// The flanking-sleep CONTEXT is measured against an immutable SNAPSHOT of the
/// hypnogram taken before the pass — Webster's rule scores each wake bout
/// against the ORIGINAL surrounding sleep (Webster et al. 1982; Cole et al.
/// 1992), not against sleep this same pass just manufactured. Reading the list
/// being mutated let every bridged bout count as context for the next one, so
/// bridging CASCADED and a genuinely fragmented night collapsed into one
/// continuous sleep block (WASO 0, efficiency 100%).
void _websterRescore(List<SleepStage> sm, int epochSec) {
  bool isSleep(SleepStage s) => s != SleepStage.wake;
  final n = sm.length;
  // epochs-per-minute (rounded; epochSec=30 → 2/min).
  double minToEp(double m) => m * 60.0 / epochSec;
  // Immutable context snapshot — see the doc comment above.
  final snap = List<SleepStage>.of(sm);

  // Locate sleep onset & final sleep epoch — only rescore within the sleep body.
  var onset = -1, lastSleep = -1;
  for (var i = 0; i < n; i++) {
    if (isSleep(snap[i])) {
      if (onset < 0) onset = i;
      lastSleep = i;
    }
  }
  if (onset < 0) return; // never slept — nothing to rescore.

  // Sustained sleep run immediately before index `i` (epochs), within body.
  int sleepRunBefore(int i) {
    var c = 0;
    var k = i - 1;
    while (k >= onset && isSleep(snap[k])) {
      c++;
      k--;
    }
    return c;
  }

  // Sustained sleep run immediately after index `i` (epochs), within body.
  int sleepRunAfter(int i) {
    var c = 0;
    var k = i + 1;
    while (k <= lastSleep && isSleep(snap[k])) {
      c++;
      k++;
    }
    return c;
  }

  // (sleep-context-epochs, max-wake-run-epochs) thresholds, longest context first.
  // The top rule allows up to 5 min of wake to be bridged when flanked by ≥15
  // min of consolidated sleep: this is the empirical floor for "real WASO needs
  // a SUSTAINED arousal", and it absorbs the van Hees 5-min mask-smear artifact
  // (a single reposition inflated to ~300 s) without bridging genuine multi-
  // minute awakenings (which exceed 5 min and stay scored as wake).
  final rules = <List<double>>[
    [minToEp(15), minToEp(5)],
    [minToEp(10), minToEp(3)],
    [minToEp(4), minToEp(1)],
  ];

  var i = onset;
  while (i <= lastSleep) {
    if (isSleep(snap[i])) {
      i++;
      continue;
    }
    // WAKE run [i, j).
    var j = i;
    while (j <= lastSleep && !isSleep(snap[j])) {
      j++;
    }
    final wakeLen = j - i;
    final before = sleepRunBefore(i);
    final after = sleepRunAfter(j - 1);
    final context = math.max(before, after).toDouble();
    var rescore = false;
    for (final r in rules) {
      if (context >= r[0] && wakeLen <= r[1]) {
        rescore = true;
        break;
      }
    }
    if (rescore) {
      for (var k = i; k < j; k++) {
        sm[k] = SleepStage.nrem;
      }
    }
    i = j;
  }
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
  // is flanked on BOTH sides by SUBSTANTIAL REM runs (each ≥ remGapEp epochs) —
  // i.e. it is a brief intrusion inside one sustained REM episode, not a stray
  // single-epoch REM flicker sitting inside a NREM block (that flicker is left
  // for step 2 to absorb into NREM).
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
      // Bridge only when both sides are REM AND the COMBINED episode (the two
      // flanking REM runs plus the gap) is a genuine REM episode ≥ remGapEp.
      // This stitches an intrusion inside a real episode, but never fuses two
      // single-epoch REM flickers that merely straddle a NREM stretch.
      if (left > 0 && right > 0 && (left + right + gapLen) >= remGapEp) {
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
