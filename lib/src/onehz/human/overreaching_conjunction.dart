// HUMAN — two facts that happen to point the same way (TS-12).
//
// "Your last 7 days of load are 1.6x your last 28, and your resting heart rate
// has been above your usual on 4 of 5 nights." Two numbers the app already
// computes, and a note when they coincide. Silence when they don't.
//
// IT IS A COINCIDENCE DETECTOR, NOT A DIAGNOSIS OF OVERREACHING. Functional
// overreaching is defined by a PERFORMANCE DECREMENT measured over weeks under
// controlled load. That cannot come from a wrist, and nothing here attempts it.
// Never "you are overtraining", never a rest-day instruction, never a score.
//
// ILLNESS, TRAVEL, ALTITUDE, ALCOHOL AND POOR SLEEP PRODUCE THE IDENTICAL
// CONJUNCTION. The copy has to name them; the detector cannot separate them.
//
// NO NEW SCORE AND NO NEW NOTIFICATION CLASS. In-app feed only. A push channel
// would turn this into exactly the forward alerting MT-10 refuses.

import '../clinical/load_trimp.dart';
import '../foundations/baseline.dart';
import '../types.dart';
import '../util.dart';

/// The two facts, side by side. There is deliberately no combined number.
class OverreachingConjunction {
  /// Acute (7 d) over chronic (42 d) load, straight off the live [LoadState].
  final double loadRatio;

  /// Nights in the recent window whose resting HR was above baseline by more
  /// than the smallest worthwhile change (0.5 × the baseline's robust SD).
  final int nightsElevated;
  final int nightsConsidered;

  /// True only when BOTH facts hold. False is the normal, quiet state.
  final bool bothPointSameWay;

  const OverreachingConjunction({
    required this.loadRatio,
    required this.nightsElevated,
    required this.nightsConsidered,
    required this.bothPointSameWay,
  });

  Map<String, dynamic> toJson() => {
        'load_ratio': round6(loadRatio),
        'nights_elevated': nightsElevated,
        'nights_considered': nightsConsidered,
        'both_point_same_way': bothPointSameWay,
      };
}

/// Read the two live outputs and report whether they coincide.
///
/// [load] the existing `ctlAtlTsb` result — absent in, absent out. [rhrRecent]
/// the last few nights' resting HR, oldest first, nulls for missing nights.
/// [rhrBaselineWindow] the trailing nights the recent ones are judged against;
/// it must NOT contain the recent nights, or the elevation is compared against
/// itself.
///
/// A night counts as elevated only when it clears the smallest worthwhile
/// change — 0.5 × the robust SD of the baseline window, the same Plews-style SWC
/// clinical/readiness_lnrmssd.dart bands lnRMSSD with. A 1 bpm rise on four
/// nights is arithmetic, not physiology. No dispersion in the baseline means no
/// gate means no elevated nights, ever.
///
/// THIS WAS `mdc()` UNTIL 2026-08-17, and with no measured typical error mdc()
/// falls back to the trailing scaled MAD, so the bar was 2.77 × the between-night
/// SD it was gating on: 7.93 bpm on 8 real gen4 nights, which NOTHING cleared on
/// the elevated side, so the conjunction could never fire — not "rarely", never.
/// Requiring [minNightsElevated] nights over the SWC is where this detector's
/// conservatism belongs; the per-night bar only has to mean "above your usual".
Metric<OverreachingConjunction> overreachingConjunction({
  required Metric<LoadState>? load,
  required List<double?> rhrRecent,
  required List<double> rhrBaselineWindow,
  double loadRatioThreshold = 1.5,
  int minNightsElevated = 4,
  int minNightsObserved = 4,
  int minBaseline = 14,
}) {
  const inputs = ['daily_trimp', 'rhr'];
  const note = 'TWO FACTS, no score: recent load against your usual load, and '
      'recent nights against your usual nights. NOT a diagnosis of '
      'overreaching — that needs a performance decrement measured over weeks '
      'and cannot come from a wrist. Illness, travel, altitude, alcohol and a '
      'run of poor sleep all produce this same pair. In-app only: no '
      'notification, no rest-day instruction.';

  final state = load?.value;
  if (state == null || state.ctl <= 0) {
    return const Metric<OverreachingConjunction>.absent(
      tier: Tier.estimate,
      inputs_used: inputs,
      note: 'no load history to compare against. $note',
    );
  }
  final observed = [
    for (final v in rhrRecent)
      if (v != null) v
  ];
  if (observed.length < minNightsObserved) {
    return Metric<OverreachingConjunction>.absent(
      tier: Tier.estimate,
      inputs_used: inputs,
      note: needBaselineNote(have: observed.length, need: minNightsObserved),
    );
  }
  final base = robustBaseline(rhrBaselineWindow, minValid: minBaseline);
  final centre = base.center;
  final scale = base.scale;
  final gate = (scale != null && scale > 0) ? 0.5 * scale : null;
  if (centre == null || gate == null || !base.sufficient) {
    return Metric<OverreachingConjunction>.absent(
      tier: Tier.estimate,
      inputs_used: inputs,
      note: needBaselineNote(have: base.nValid, need: minBaseline),
    );
  }

  var elevated = 0;
  for (final v in observed) {
    if (v - centre >= gate) elevated++;
  }
  final ratio = state.atl / state.ctl;
  final both = ratio >= loadRatioThreshold && elevated >= minNightsElevated;

  return Metric<OverreachingConjunction>(
    value: OverreachingConjunction(
      loadRatio: ratio,
      nightsElevated: elevated,
      nightsConsidered: observed.length,
      bothPointSameWay: both,
    ),
    confidence: 0.4,
    tier: Tier.estimate,
    inputs_used: inputs,
    note: note,
  );
}
