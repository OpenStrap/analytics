// SLEEP/CIRCADIAN TIER-1 — True Phillips Sleep Regularity Index.
//
// Phillips et al. 2017 (Sci Rep) — the CORRECT SRI: epoch-by-epoch 24-h
// concordance, NOT the SD-of-midsleep shortcut that some implementations use.
//
//   SRI = 200 · (agreement / cases) − 100
//
// where each "case" is one within-day epoch index compared between consecutive
// days, and "agreement" counts epochs where the sleep/wake state was the SAME
// at the same clock time on two adjacent days. SRI = 100 means perfectly
// regular (identical state at every epoch every day); 0 means random; can go
// negative (anti-phase). Windred 2023 found epoch-by-epoch SRI predicts
// mortality — hence we implement exactly the published form.
//
// Input is a per-epoch binary sleep/wake vector aligned to clock time, with a
// fixed number of epochs per day (e.g. 1440 one-minute epochs, or 86400 one-
// second epochs). The vector spans ≥2 days.

import '../types.dart';
import '../util.dart';

/// One adjacent-day comparison, broken out of the total.
///
/// [dayIndex] is the LATER day of the pair, indexing the same day sequence the
/// caller laid out (so the pair is `dayIndex-1` vs `dayIndex`) — this class
/// never sees a date, and the caller that built the vector is the only thing
/// that can name the two nights.
///
/// [cases]/[agreement] count ONLY the epochs the validity mask accepted, so
/// [sri] is the concordance over what was actually observed on both days, never
/// over a hole. A pair the mask left too thin is not emitted at all — see
/// [phillipsSri]'s `minPairCases`.
class SriPair {
  final int dayIndex;
  final int agreement;
  final int cases;
  const SriPair(this.dayIndex, this.agreement, this.cases);

  /// This pair's SRI on the same 200·p−100 scale as the whole-record number.
  double get sri => 200.0 * agreement / cases - 100.0;

  Map<String, dynamic> toJson() => {
        'day_index': dayIndex,
        'sri': round6(sri),
        'agreement': agreement,
        'cases': cases,
      };
}

class SriResult {
  final double sri; // −100..100
  final int days; // number of adjacent-day comparisons + 1
  final int cases; // number of epoch comparisons made
  /// Per-adjacent-day-pair decomposition of the SAME arithmetic, in day order.
  /// Empty when no pair cleared the coverage floor. Purely a breakdown of a
  /// number already published — it licenses "these two nights differed most",
  /// never a judgement about which night should have been which.
  final List<SriPair> pairs;
  const SriResult(this.sri, this.days, this.cases,
      [this.pairs = const <SriPair>[]]);
  Map<String, dynamic> toJson() => {
        'sri': round6(sri),
        'days': days,
        'cases': cases,
        'pairs': [for (final p in pairs) p.toJson()],
      };
}

/// True Phillips SRI from a clock-aligned binary sleep/wake vector.
///
/// [sleepWake] one bool per epoch (true = asleep), laid out as consecutive days
/// of exactly [epochsPerDay] epochs each, aligned so index `d*epochsPerDay + e`
/// is epoch `e` of day `d`. [valid] optional same-length mask (false epochs are
/// excluded from the agreement count, so gaps don't fabricate concordance).
///
/// The result also carries a per-pair decomposition ([SriResult.pairs]) of the
/// same sum. A pair is only emitted when the mask accepted at least
/// [minPairCases] epochs on BOTH days (default: half the clock day) — a pair
/// compared on 40 observed minutes is a coverage hole, not an irregular night,
/// and without the floor a half-unobserved weekend tops the "worst pair" list
/// for having no data. The floor does NOT change the published [SriResult.sri]:
/// every accepted epoch still counts toward the total, thin pair or not.
Metric<SriResult> phillipsSri(
  List<bool> sleepWake,
  int epochsPerDay, {
  List<bool>? valid,
  int? minPairCases,
}) {
  const inputs = ['sleep_wake_epochs'];
  final n = sleepWake.length;
  if (epochsPerDay <= 0 || n < 2 * epochsPerDay) {
    return const Metric<SriResult>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'need ≥2 full days of clock-aligned sleep/wake epochs for SRI',
    );
  }
  final days = n ~/ epochsPerDay;
  if (days < 2) {
    return const Metric<SriResult>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'need ≥2 full days for SRI',
    );
  }

  final pairFloor = minPairCases ?? (epochsPerDay ~/ 2);
  var agreement = 0;
  var cases = 0;
  final pairs = <SriPair>[];
  for (var d = 1; d < days; d++) {
    var pairAgreement = 0;
    var pairCases = 0;
    for (var e = 0; e < epochsPerDay; e++) {
      final iPrev = (d - 1) * epochsPerDay + e;
      final iCur = d * epochsPerDay + e;
      if (iCur >= n) break;
      if (valid != null && (!valid[iPrev] || !valid[iCur])) continue;
      pairCases++;
      if (sleepWake[iPrev] == sleepWake[iCur]) pairAgreement++;
    }
    agreement += pairAgreement;
    cases += pairCases;
    // `> 0` is not redundant with the floor: a caller may pass
    // `minPairCases: 0`, and a zero-case pair would make SriPair.sri NaN.
    if (pairCases > 0 && pairCases >= pairFloor) {
      pairs.add(SriPair(d, pairAgreement, pairCases));
    }
  }
  if (cases == 0) {
    return const Metric<SriResult>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'no valid epoch pairs for SRI',
    );
  }

  final sri = 200.0 * agreement / cases - 100.0;
  // Confidence: scales with the number of day-comparisons (more days, more
  // stable). Saturates around a typical 7-day record.
  final conf = ((days - 1) / 7.0).clamp(0.3, 0.95);
  return Metric<SriResult>(
    value: SriResult(sri, days, cases, pairs),
    confidence: conf,
    tier: Tier.high,
    inputs_used: inputs,
    note: 'epoch-by-epoch 24-h concordance (Phillips 2017), '
        'SRI=200·agreement/cases−100; NOT SD-of-midsleep',
  );
}
