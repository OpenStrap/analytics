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

class SriResult {
  final double sri; // −100..100
  final int days; // number of adjacent-day comparisons + 1
  final int cases; // number of epoch comparisons made
  const SriResult(this.sri, this.days, this.cases);
  Map<String, dynamic> toJson() => {
        'sri': round6(sri),
        'days': days,
        'cases': cases,
      };
}

/// True Phillips SRI from a clock-aligned binary sleep/wake vector.
///
/// [sleepWake] one bool per epoch (true = asleep), laid out as consecutive days
/// of exactly [epochsPerDay] epochs each, aligned so index `d*epochsPerDay + e`
/// is epoch `e` of day `d`. [valid] optional same-length mask (false epochs are
/// excluded from the agreement count, so gaps don't fabricate concordance).
Metric<SriResult> phillipsSri(
  List<bool> sleepWake,
  int epochsPerDay, {
  List<bool>? valid,
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

  var agreement = 0;
  var cases = 0;
  for (var d = 1; d < days; d++) {
    for (var e = 0; e < epochsPerDay; e++) {
      final iPrev = (d - 1) * epochsPerDay + e;
      final iCur = d * epochsPerDay + e;
      if (iCur >= n) break;
      if (valid != null && (!valid[iPrev] || !valid[iCur])) continue;
      cases++;
      if (sleepWake[iPrev] == sleepWake[iCur]) agreement++;
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
  final conf = clamp((days - 1) / 7.0, 0.3, 0.95);
  return Metric<SriResult>(
    value: SriResult(sri, days, cases),
    confidence: conf,
    tier: Tier.high,
    inputs_used: inputs,
    note: 'epoch-by-epoch 24-h concordance (Phillips 2017), '
        'SRI=200·agreement/cases−100; NOT SD-of-midsleep',
  );
}
