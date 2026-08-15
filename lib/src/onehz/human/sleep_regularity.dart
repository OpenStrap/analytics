// HUMAN LAYER — Sleep Regularity Index + sleep debt vs personal need.
// Catalog §A: True SRI [PUB Phillips 2017; Windred 2023] and sleep debt
// vs personal need (Kitamura 2016 OSD) [PUB].
//
// SRI = 200·(P_agreement) − 100, where P_agreement is the probability that a
// person is in the SAME state (asleep/awake) at two time-points exactly 24 h
// apart, averaged over all epochs. This is the TRUE epoch-by-epoch concordance,
// NOT the SD-of-midsleep shortcut (catalog explicitly forbids the shortcut).
//
// Sleep debt: Kitamura's "optimal sleep duration" is estimated from the
// rebound on unconstrained (free) nights; debt = OSD − recent habitual sleep.
// Returns null when there is no free night yet, rather than assuming a generic
// 8 h target.

import '../types.dart';
import '../util.dart';

class Sri {
  final double sri; // -100..100, higher = more regular
  final int epochsPerDay; // epochs in 24 h (sample rate)
  final int comparedPairs; // # of (t, t+24h) comparisons used
  final String band; // coarse within-context label
  const Sri(this.sri, this.epochsPerDay, this.comparedPairs, this.band);
  Map<String, dynamic> toJson() => {
        'sri': round6(sri),
        'epochs_per_day': epochsPerDay,
        'compared_pairs': comparedPairs,
        'band': band,
      };
}


class SleepDebt {
  final double? osdHours; // estimated personal optimal sleep duration (h)
  final double habitualHours; // recent habitual sleep (h)
  final double? debtHours; // OSD − habitual (positive = under-slept)
  final bool hasFreeNight; // could we estimate OSD honestly?
  const SleepDebt(
      this.osdHours, this.habitualHours, this.debtHours, this.hasFreeNight);
  Map<String, dynamic> toJson() => {
        if (osdHours != null) 'osd_hours': round6(osdHours!),
        'habitual_hours': round6(habitualHours),
        if (debtHours != null) 'debt_hours': round6(debtHours!),
        'has_free_night': hasFreeNight,
      };
}

/// Sleep debt vs personal need (Kitamura OSD).
///
/// [recentSleepH] recent nightly sleep durations (h), oldest→newest.
/// [freeNightSleepH] sleep durations on UNCONSTRAINED nights (no alarm / free
/// days), used to estimate the personal optimal sleep duration as their rebound
/// plateau. With no free nights we report habitual sleep but DECLINE to claim a
/// debt (honest: "no free night yet").
Metric<SleepDebt> sleepDebt(
  List<double> recentSleepH,
  List<double> freeNightSleepH, {
  int minRecent = 3,
}) {
  const inputs = ['sleep_duration_recent', 'sleep_duration_free'];
  if (recentSleepH.length < minRecent) {
    return const Metric<SleepDebt>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'need more recent nights to estimate habitual sleep',
    );
  }
  final habitual = median(recentSleepH)!;
  if (freeNightSleepH.isEmpty) {
    // Honest: we will not invent an "8 hours" need.
    return Metric<SleepDebt>(
      value: SleepDebt(null, habitual, null, false),
      confidence: 0.3,
      tier: Tier.high,
      inputs_used: inputs,
      note: 'no free night yet — cannot honestly estimate your sleep need',
    );
  }
  // OSD ≈ the rebound plateau: the upper part of free-night durations (75th
  // percentile is a robust "when unconstrained, this is where you settle").
  final osd = percentile(freeNightSleepH, 75)!;
  final debt = osd - habitual;
  return Metric<SleepDebt>(
    value: SleepDebt(osd, habitual, debt, true),
    confidence: clamp(freeNightSleepH.length / 5.0, 0.3, 0.85),
    tier: Tier.high,
    inputs_used: inputs,
    note: 'OSD from free-night rebound (Kitamura); debt = need − habitual',
  );
}
