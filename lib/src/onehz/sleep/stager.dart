// SLEEP/CIRCADIAN — 3-class autonomic sleep stager (wake / NREM / REM).
//
// HONESTY CEILING (catalog rule 5): wrist staging is at best a 3-class
// AUTONOMIC ESTIMATE, never a PSG 4-stage hypnogram. We NEVER emit N1/N2/N3.
// This is tier ESTIMATE.
//
// Physiological basis (deterministic, no ML):
//   - NREM (esp. deep): parasympathetic dominance → HR low & stable, HRV high,
//     near-total immobility.
//   - REM: autonomic activation → HR rises toward wake levels and becomes more
//     variable (irregular), while skeletal muscle is ATONIC → still immobile.
//     The "moving but immobile + HR up + HRV variable" pattern is REM's tell.
//   - Wake: movement present OR HR clearly elevated with body motion.
//
// We classify per epoch (default 30 s) using:
//   * immobility from the van Hees mask (motion → wake unless deep in window)
//   * epoch mean HR relative to the night's sleep HR floor (low = NREM)
//   * short-window HR variability (SDNN of per-epoch HR, or RR-RMSSD if given)
// REM is gated by immobility (atonia) AND elevated/variable HR.

import 'dart:math' as math;
import '../types.dart';
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

/// 3-class autonomic stager.
///
/// DEPRECATED: superseded by [cardioStager] (transparent motion+HR+RMSSD rule
/// stager), which `segmentSleep` now uses. This hand-rolled deterministic stager
/// is retained only for its proven Webster-rescore + [consolidateSleepStages]
/// post-processing (which the cardio stager reuses); it is no longer the
/// segmentation engine. Prefer [cardioStager] for new code.
///
/// [hr] per-second HR (bpm; 0 = off-skin). [immobile] per-second van Hees
/// immobility mask (same length). [epochSec] epoch granularity (default 30 s).
/// All inputs are within the in-bed window. RR is optional — when absent we use
/// per-epoch HR dispersion as the variability proxy (honest, coarser).
@Deprecated('Use cardioStager (motion+HR+RMSSD rule stager); kept for back-compat.')
Metric<StagerResult> autonomicStager(
  List<double> hr,
  List<bool> immobile, {
  int epochSec = 30,
}) {
  const inputs = ['hr_1hz', 'immobility_mask'];
  final n = math.min(hr.length, immobile.length);
  if (n < epochSec * 4) {
    return const Metric<StagerResult>.absent(
      tier: Tier.estimate,
      inputs_used: inputs,
      note: 'too short for 3-class staging',
    );
  }
  final nEpoch = n ~/ epochSec;
  if (nEpoch < 3) {
    return const Metric<StagerResult>.absent(
      tier: Tier.estimate,
      inputs_used: inputs,
      note: 'too few epochs for 3-class staging',
    );
  }

  // Per-epoch features.
  final epHr = List<double>.filled(nEpoch, double.nan);
  final epVar = List<double>.filled(nEpoch, 0); // HR SDNN within epoch
  final epImmobile = List<bool>.filled(nEpoch, false);
  for (var e = 0; e < nEpoch; e++) {
    final lo = e * epochSec;
    final hi = lo + epochSec;
    final vals = <double>[];
    var immobCount = 0;
    for (var i = lo; i < hi; i++) {
      if (hr[i] > 0) vals.add(hr[i]);
      if (immobile[i]) immobCount++;
    }
    if (vals.isNotEmpty) epHr[e] = mean(vals)!;
    epVar[e] = vals.length >= 2 ? (stddev(vals) ?? 0) : 0;
    epImmobile[e] = immobCount > epochSec / 2;
  }

  // Sleep HR floor: 10th percentile of valid epoch HR (the deep-NREM bottom).
  final validHr = [for (final h in epHr) if (!h.isNaN) h];
  if (validHr.length < 3) {
    return const Metric<StagerResult>.absent(
      tier: Tier.estimate,
      inputs_used: inputs,
      note: 'insufficient valid HR for staging',
    );
  }
  final floor = percentile(validHr, 10)!;
  final hrMedian = median(validHr)!;
  // Variability scale: median epoch SDNN (used as REM threshold reference).
  final varVals = [for (final v in epVar) if (v > 0) v];
  final varMed = varVals.isNotEmpty ? median(varVals)! : 0.0;

  // --- Wake-HR threshold -----------------------------------------------------
  // A genuine arousal/awakening shows BOTH motion AND a cardiac rise toward the
  // waking level. The van Hees mask alone over-flags wake: its 5-min forward
  // window smears a single reposition (a few seconds of >5° change) across the
  // whole window, so a normal turn becomes ~5 min of "mobile". During such a
  // reposition the heart rate stays in the sleep range, so requiring an HR rise
  // before declaring WAKE removes that artifact while keeping true arousals.
  //
  // wakeHr = floor + 0.55·(median − floor): roughly mid-way between the deep
  // sleep HR floor and the night-median, the cardiac signature of being awake.
  final wakeHr = floor + 0.55 * (hrMedian - floor);

  final stages = List<SleepStage>.filled(nEpoch, SleepStage.wake);
  for (var e = 0; e < nEpoch; e++) {
    final h = epHr[e];
    if (h.isNaN) {
      stages[e] = SleepStage.wake; // off-skin → can't claim sleep
      continue;
    }
    if (!epImmobile[e] && h > wakeHr) {
      // Motion AND elevated HR → a real arousal/awakening (atonia broken with
      // a cardiac rise). Motion WITHOUT an HR rise is treated as a reposition
      // (or mask smear) and falls through to sleep classification below.
      stages[e] = SleepStage.wake;
      continue;
    }
    // Asleep (immobile, or moving without a cardiac arousal).
    // Distinguish NREM vs REM by HR level + variability.
    // NREM: HR near the floor, low variability (parasympathetic).
    // REM: HR elevated toward median/wake + higher variability, still immobile.
    final elevated = h > floor + 0.4 * (hrMedian - floor);
    final variable = epVar[e] > 1.15 * varMed && varMed > 0;
    if (elevated && variable) {
      stages[e] = SleepStage.rem;
    } else {
      stages[e] = SleepStage.nrem;
    }
  }

  // Smooth singleton epochs (median-of-3) to suppress thrash.
  final sm = List<SleepStage>.from(stages);
  for (var e = 1; e < nEpoch - 1; e++) {
    if (stages[e - 1] == stages[e + 1] && stages[e] != stages[e - 1]) {
      sm[e] = stages[e - 1];
    }
  }

  // --- Webster / Cole-Kripke sleep-continuity rescoring -----------------------
  // Standard actigraphy post-processing: once sleep is established, brief WAKE
  // bouts bracketed by sustained sleep are arousals, not real WASO, and are
  // rescored to SLEEP. Real WASO requires a SUSTAINED arousal. We apply the
  // classic Webster rules (durations in minutes, converted to epochs):
  //   after ≥ 4 min sleep, ≤ 1 min wake → sleep
  //   after ≥10 min sleep, ≤ 3 min wake → sleep
  //   after ≥15 min sleep, ≤ 4 min wake → sleep
  // (Symmetric in both directions: "surrounded by" sleep on either side.)
  _websterRescore(sm, epochSec);

  // --- Stage-architecture consolidation ---------------------------------------
  // The raw per-epoch labels flip-flop nrem↔rem because the REM gate (elevated
  // HR + above-median variability) is met intermittently within a single REM
  // episode and during NREM micro-fluctuations. Real sleep architecture is a
  // few SUSTAINED NREM/REM bouts within ~90-min cycles, not per-epoch jitter.
  // Enforce: (a) REM only survives as EPISODES ≥ minRemMin, gap-bridged so a
  // brief NREM intrusion inside an otherwise-REM run doesn't split it; (b) any
  // remaining stage bout shorter than minBoutMin is merged into its neighbour.
  // WAKE bouts are preserved (Webster already governs WASO); only the asleep
  // NREM/REM micro-structure is consolidated.
  _consolidateStages(sm, epochSec);

  var w = 0, nr = 0, r = 0;
  for (final s in sm) {
    switch (s) {
      case SleepStage.wake:
        w++;
        break;
      case SleepStage.nrem:
        nr++;
        break;
      case SleepStage.rem:
        r++;
        break;
    }
  }
  final tot = sm.length.toDouble();
  return Metric<StagerResult>(
    value: StagerResult(
      stages: sm,
      epochSec: epochSec,
      wakePct: 100 * w / tot,
      nremPct: 100 * nr / tot,
      remPct: 100 * r / tot,
    ),
    confidence: 0.5, // honesty-bounded: a 3-class estimate, not PSG
    tier: Tier.estimate,
    inputs_used: inputs,
    note: 'wrist 3-class autonomic ESTIMATE (wake/NREM/REM); '
        'REM gated by atonia+HR; never N1/N2/N3, not PSG',
  );
}

/// Webster/Cole-Kripke sleep-continuity rescoring (in place).
///
/// After sleep onset (first sleep epoch), a contiguous run of WAKE epochs that
/// is short enough relative to the SUSTAINED sleep bracketing it is rescored to
/// SLEEP (NREM) — it is an arousal, not real WASO. Runs longer than the
/// allowed bout, or with insufficient surrounding sleep, are LEFT as wake (a
/// genuine, sustained awakening). Rules (Webster, in epochs):
///   sleep-before ≥ 4 min  AND wake-run ≤ 1 min → sleep
///   sleep-before ≥10 min  AND wake-run ≤ 3 min → sleep
///   sleep-before ≥15 min  AND wake-run ≤ 4 min → sleep
/// "sleep-before" is satisfied by sustained sleep on EITHER bracketing side,
/// so an arousal sandwiched between two long sleep bouts is bridged.
void _websterRescore(List<SleepStage> sm, int epochSec) {
  bool isSleep(SleepStage s) => s != SleepStage.wake;
  final n = sm.length;
  // epochs-per-minute (rounded; epochSec=30 → 2/min).
  double minToEp(double m) => m * 60.0 / epochSec;

  // Locate sleep onset & final sleep epoch — only rescore within the sleep body.
  var onset = -1, lastSleep = -1;
  for (var i = 0; i < n; i++) {
    if (isSleep(sm[i])) {
      if (onset < 0) onset = i;
      lastSleep = i;
    }
  }
  if (onset < 0) return; // never slept — nothing to rescore.

  // Sustained sleep run immediately before index `i` (epochs), within body.
  int sleepRunBefore(int i) {
    var c = 0;
    var k = i - 1;
    while (k >= onset && isSleep(sm[k])) {
      c++;
      k--;
    }
    return c;
  }

  // Sustained sleep run immediately after index `i` (epochs), within body.
  int sleepRunAfter(int i) {
    var c = 0;
    var k = i + 1;
    while (k <= lastSleep && isSleep(sm[k])) {
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
    if (isSleep(sm[i])) {
      i++;
      continue;
    }
    // WAKE run [i, j).
    var j = i;
    while (j <= lastSleep && !isSleep(sm[j])) {
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
