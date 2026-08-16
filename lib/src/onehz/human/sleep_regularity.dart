// HUMAN LAYER — sleep debt vs personal need.
// Catalog §A: sleep debt vs personal need (Kitamura 2016 OSD) [PUB].
//
// SRI does NOT live here despite the file name — the live one is `phillipsSri`
// in sleep/sri.dart. This file used to carry a second SRI header and an unused
// result class after the implementation was deleted; both are gone.
//
// Sleep debt: Kitamura's "optimal sleep duration" is estimated from the
// rebound on unconstrained (free) nights; debt = OSD − recent habitual sleep.
// Returns null when there is no free night yet, rather than assuming a generic
// 8 h target.

import '../types.dart';
import '../util.dart';

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
