// SLEEP/CIRCADIAN TIER-1 — sleep accounting.
//
// Given the van Hees REST window + a per-second wake/sleep classification
// inside it (from the immobility mask, optionally refined by the autonomic
// stager), compute the standard accounting figures (AASM-style definitions):
//   - onset  = first sleep second within the window
//   - offset = last sleep second within the window
//   - TST    = total sleep time (sum of sleep seconds in [onset, offset])
//   - WASO   = wake after sleep onset (wake seconds in [onset, offset])
//   - SPT    = sleep-period time (offset − onset)
//   - efficiency = TST / in-bed, where in-bed = (offset − onset + 1), the sleep
//     PERIOD itself (NOT the whole captured mask). Per ARCHITECTURE_V2:
//     "efficiency = TST/in-bed". Onset latency and post-offset tail are excluded
//     from the denominator so efficiency reflects [onset..offset] only.
//
// NREM–REM cycle detection (~90 min ultradian): we count cycles as the number
// of REM episodes (or, if no stage labels, the number of distinct sleep bouts
// separated by WASO), capped to a plausible 4–6/night. This is a COUNT, not a
// staged hypnogram — honesty: we never emit N1/N2/N3.

import 'dart:math' as math;
import '../types.dart';
import '../util.dart';

/// 3-class label used across the sleep family.
enum SleepStage { wake, nrem, rem }

class SleepAccounting {
  final int onsetIdx; // first sleep second (rel. to window start input)
  final int offsetIdx; // last sleep second
  final int tstSec; // total sleep time
  final int wasoSec; // wake after sleep onset
  final int sptSec; // sleep-period time (offset−onset)
  final double efficiencyPct; // TST / time-in-bed window
  final int cycles; // detected NREM-REM cycles (~90 min)
  const SleepAccounting({
    required this.onsetIdx,
    required this.offsetIdx,
    required this.tstSec,
    required this.wasoSec,
    required this.sptSec,
    required this.efficiencyPct,
    required this.cycles,
  });
  Map<String, dynamic> toJson() => {
        'onset_idx': onsetIdx,
        'offset_idx': offsetIdx,
        'tst_sec': tstSec,
        'waso_sec': wasoSec,
        'spt_sec': sptSec,
        'efficiency_pct': round6(efficiencyPct),
        'cycles': cycles,
      };
}

/// Compute sleep accounting from a per-second sleep/wake classification of the
/// in-bed window. [asleep] = true where the second is classified sleep.
/// Efficiency = TST / in-bed, where in-bed = (offset − onset + 1) — the sleep
/// PERIOD bounded by first/last sleep second, NOT the length of [asleep].
/// [stages] optional per-second 3-class labels (same length); when supplied,
/// REM episode count drives the cycle estimate.
Metric<SleepAccounting> sleepAccounting(
  List<bool> asleep, {
  List<SleepStage>? stages,
}) {
  const inputs = ['in_bed_sleep_wake'];
  final n = asleep.length;
  if (n < 60) {
    return const Metric<SleepAccounting>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'in-bed window too short for sleep accounting',
    );
  }
  // Onset / offset.
  var onset = -1, offset = -1;
  for (var i = 0; i < n; i++) {
    if (asleep[i]) {
      onset = i;
      break;
    }
  }
  for (var i = n - 1; i >= 0; i--) {
    if (asleep[i]) {
      offset = i;
      break;
    }
  }
  if (onset < 0) {
    return const Metric<SleepAccounting>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'no sleep detected within the in-bed window',
    );
  }

  final spt = offset - onset; // sleep-period time (offset − onset)
  var tst = 0, waso = 0;
  for (var i = onset; i <= offset; i++) {
    if (asleep[i]) {
      tst++;
    } else {
      waso++;
    }
  }
  // efficiency = TST / in-bed, where in-bed = [onset..offset] inclusive
  // (offset − onset + 1), the sleep PERIOD — NOT the whole captured mask `n`.
  final inBed = offset - onset + 1;
  final efficiency = inBed > 0 ? 100.0 * tst / inBed : 0.0;

  // Cycle count.
  int cycles;
  if (stages != null && stages.length == n) {
    // Count REM episodes (≥3 contiguous min REM, gap-tolerant).
    cycles = _countEpisodes(
      stages.map((s) => s == SleepStage.rem).toList(),
      onset,
      offset,
      minLenSec: 180,
      bridgeSec: 300,
    );
  } else {
    // No stages: estimate from SPT assuming ~90-min ultradian cycles.
    cycles = (spt / (90 * 60)).round();
  }
  cycles = cycles.clamp(0, 6);

  // Confidence: high efficiency + plausible duration => trust.
  final conf = clamp(0.4 + spt / (8 * 3600) * 0.5, 0.4, 0.9);
  return Metric<SleepAccounting>(
    value: SleepAccounting(
      onsetIdx: onset,
      offsetIdx: offset,
      tstSec: tst,
      wasoSec: waso,
      sptSec: spt,
      efficiencyPct: efficiency,
      cycles: cycles,
    ),
    confidence: conf,
    tier: Tier.high,
    inputs_used: stages != null ? [...inputs, 'stages_3class'] : inputs,
    note: 'onset/offset/WASO/TST/efficiency; cycles ~90-min ultradian '
        '(REM-episode count when staged); 3-class only, never N1/N2/N3',
  );
}

/// Count contiguous episodes where [flag] is true, within [lo,hi], requiring
/// each episode ≥ [minLenSec] and bridging gaps < [bridgeSec].
int _countEpisodes(List<bool> flag, int lo, int hi,
    {required int minLenSec, required int bridgeSec}) {
  var count = 0;
  var i = lo;
  while (i <= hi) {
    if (!flag[i]) {
      i++;
      continue;
    }
    var j = i;
    while (j <= hi) {
      if (flag[j]) {
        j++;
        continue;
      }
      var k = j;
      while (k <= hi && !flag[k] && (k - j) < bridgeSec) {
        k++;
      }
      if (k <= hi && flag[k] && (k - j) < bridgeSec) {
        j = k;
      } else {
        break;
      }
    }
    if ((j - i) >= minLenSec) count++;
    i = math.max(j + 1, i + 1);
  }
  return count;
}
