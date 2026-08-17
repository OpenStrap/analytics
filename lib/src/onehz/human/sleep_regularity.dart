// HUMAN LAYER — your longer unconstrained nights vs your habitual sleep.
//
// SRI does NOT live here despite the file name — the live one is `phillipsSri`
// in sleep/sri.dart. This file used to carry a second SRI header and an unused
// result class after the implementation was deleted; both are gone.
//
// THIS IS NOT KITAMURA'S OSD, and it used to say it was (SLP-03). Kitamura 2016
// (PMC5075948) defines optimal sleep duration as the ASYMPTOTE of an
// exponential-decay fit to PSG total sleep time across NINE CONSECUTIVE NIGHTS
// AT 12 h TIME IN BED: OSD 8.41 ± 0.18 h, habitual 7.37 ± 0.27 h, potential debt
// 1.04 ± 0.24 h, with night 1 at 10.59 ± 0.19 h — a 3.22 h rebound that then
// decays. The paper's whole point is that UNCONSTRAINED SLEEP IS NOT OSD; it
// understates it by about an hour.
//
// What we actually compute is `percentile(freeNightSleepH, 75)` over ordinary
// ad-lib nights — a habitual-sleep percentile. So the "debt" it yields is
// systematically near zero or negative, and downstream (`crossday_pipeline`
// clamps this into [7.0, 9.5] h and floors debt at 0.0) what most users see is
// the clamp, not a measurement. Reported as what it is: how long your longer
// unconstrained nights run, against your recent typical night.
//
// Doing it properly needs a saturating fit across a RUN of consecutive free
// days, and a refusal when no such run exists — not a wider percentile.
//
// Returns null when there is no free night yet, rather than assuming a generic
// 8 h target.

import '../types.dart';
import '../util.dart';

class SleepDebt {
  /// p75 of your UNCONSTRAINED nights (h) — "where your longer free nights
  /// land". NOT Kitamura's optimal sleep duration; see the file header.
  final double? osdHours;
  final double habitualHours; // recent habitual sleep (h)

  /// [osdHours] − [habitualHours]. The gap between your longer free nights and
  /// your typical one, not a sleep debt in Kitamura's sense — an ad-lib
  /// percentile understates OSD by ~1 h, so this runs near zero by
  /// construction.
  final double? debtHours;
  final bool hasFreeNight; // did we have any unconstrained night at all?
  const SleepDebt(
      this.osdHours, this.habitualHours, this.debtHours, this.hasFreeNight);
  Map<String, dynamic> toJson() => {
        if (osdHours != null) 'osd_hours': round6(osdHours!),
        'habitual_hours': round6(habitualHours),
        if (debtHours != null) 'debt_hours': round6(debtHours!),
        'has_free_night': hasFreeNight,
      };
}

/// Your longer unconstrained nights vs your habitual night.
///
/// [recentSleepH] recent nightly sleep durations (h), oldest→newest.
/// [freeNightSleepH] sleep durations on UNCONSTRAINED nights (no alarm / free
/// days). We take their 75th percentile. With no free nights we report habitual
/// sleep but DECLINE to compare (honest: "no free night yet").
///
/// NOT Kitamura's OSD — see the file header for what that would require.
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
  // The upper part of free-night durations: "when unconstrained, this is where
  // your longer nights land". A percentile of ad-lib nights, NOT a rebound
  // asymptote — see the file header.
  final osd = percentile(freeNightSleepH, 75)!;
  final debt = osd - habitual;
  return Metric<SleepDebt>(
    value: SleepDebt(osd, habitual, debt, true),
    confidence: clamp(freeNightSleepH.length / 5.0, 0.3, 0.85),
    tier: Tier.high,
    inputs_used: inputs,
    note: 'p75 of your unconstrained nights vs your habitual night — a '
        'percentile of ad-lib sleep, NOT a measured sleep need (that needs a '
        'run of consecutive free days and a saturating fit)',
  );
}
