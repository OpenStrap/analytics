import 'dart:math' as math;

import '../types.dart';
import '../util.dart' show mean, theilSen;

class SleepNeed {
  final double needSec;
  const SleepNeed(this.needSec);
  Map<String, dynamic> toJson() => {'need_sec': needSec};
}

Metric<SleepNeed> sleepNeed({
  required double baselineNeedSec,
  required double sleepDebtSec,
  required double dayStrain,
  required double napCreditSec,
}) {
  final strainBonusSec = (dayStrain.clamp(0.0, 21.0) / 21.0) * 45.0 * 60.0;
  final adjusted =
      (baselineNeedSec + sleepDebtSec + strainBonusSec - napCreditSec).clamp(
    6 * 3600.0,
    11 * 3600.0,
  );
  return Metric<SleepNeed>(
    value: SleepNeed(adjusted),
    confidence: 0.6,
    tier: Tier.estimate,
    inputs_used: const ['sleep_debt', 'strain', 'naps'],
    note: 'baseline need adjusted by debt, strain, and naps',
  );
}

class SleepPerformance {
  final double pct;
  const SleepPerformance(this.pct);
  Map<String, dynamic> toJson() => {'pct': pct};
}

Metric<SleepPerformance> sleepPerformance(double sleepSec, double needSec) {
  if (needSec <= 0) {
    return const Metric<SleepPerformance>.absent(
      tier: Tier.estimate,
      inputs_used: ['sleep_sec', 'need_sec'],
    );
  }
  final pct = ((sleepSec / needSec) * 100.0).clamp(0.0, 100.0);
  return Metric<SleepPerformance>(
    value: SleepPerformance(pct),
    confidence: 0.7,
    tier: Tier.estimate,
    inputs_used: const ['sleep_sec', 'need_sec'],
  );
}

class BedtimeRec {
  final double bedtimeMinOfDay;
  const BedtimeRec(this.bedtimeMinOfDay);
  Map<String, dynamic> toJson() => {'bedtime_min_of_day': bedtimeMinOfDay};
}

/// Time in bed (minutes) that delivers [needSec] of SLEEP at the user's own
/// efficiency. Shared by [recommendedBedtime] and [recommendedWake] so the two
/// ends of the same night can never be built from different durations again.
double _inBedMin(double needSec, double typicalEfficiencyPct) {
  final eff = (typicalEfficiencyPct / 100.0).clamp(0.75, 0.99);
  return needSec / eff / 60.0;
}

Metric<BedtimeRec> recommendedBedtime({
  required double needSec,
  required double typicalWakeMinOfDay,
  required double typicalEfficiencyPct,
}) {
  final bedMin =
      (typicalWakeMinOfDay - _inBedMin(needSec, typicalEfficiencyPct)) % 1440.0;
  return Metric<BedtimeRec>(
    value: BedtimeRec(bedMin < 0 ? bedMin + 1440.0 : bedMin),
    confidence: 0.6,
    tier: Tier.estimate,
    inputs_used: const ['sleep_need', 'wake_time', 'efficiency'],
  );
}

class WakeRec {
  final double wakeMinOfDay;
  const WakeRec(this.wakeMinOfDay);
  Map<String, dynamic> toJson() => {'wake_min_of_day': wakeMinOfDay};
}

/// Target wake = the recommended bedtime plus the SAME time-in-bed the bedtime
/// was backed off from.
///
/// It used to add `round(need / 90) × 90` — sleep minutes, cycle-quantized —
/// onto a bedtime built from an IN-BED duration, so the span was always short
/// of the night the card promised: the efficiency gap is need × 0.136 (65 min
/// at an 8 h need) while the largest possible round-UP is 45 min. The pair
/// described a night delivering less than the need printed beside it, target
/// wake landed before the user's own typical wake, and a 0.5 h need increase
/// could push target wake 55 min LATER by crossing a cycle boundary. Cycle
/// alignment is gone with it: quantizing TIME IN BED to 90-minute sleep cycles
/// was never the thing Kleitman's cycles describe.
Metric<WakeRec> recommendedWake({
  required double bedtimeMinOfDay,
  required double needSec,
  required double typicalEfficiencyPct,
}) {
  final wake =
      (bedtimeMinOfDay + _inBedMin(needSec, typicalEfficiencyPct)) % 1440.0;
  return Metric<WakeRec>(
    value: WakeRec(wake < 0 ? wake + 1440.0 : wake),
    confidence: 0.55,
    tier: Tier.estimate,
    inputs_used: const ['sleep_need', 'bedtime', 'efficiency'],
    note: 'wake = bedtime + the time in bed the need and your efficiency imply',
  );
}

class StrainTarget {
  final double targetMin;
  final double targetMax;
  final String band;
  final String rationale;
  const StrainTarget({
    required this.targetMin,
    required this.targetMax,
    required this.band,
    required this.rationale,
  });
  Map<String, dynamic> toJson() => {
        'target_min': targetMin,
        'target_max': targetMax,
        'band': band,
        'rationale': rationale,
      };
}

Metric<StrainTarget> strainTarget({
  required double? recovery0to100,
  required double? ctl,
  required double? atl,
  required double? tsb,
}) {
  if (recovery0to100 == null) {
    return const Metric<StrainTarget>.absent(
      tier: Tier.estimate,
      inputs_used: ['recovery'],
    );
  }
  final rec = recovery0to100.clamp(0.0, 100.0);
  // Bands sit on the SAME distribution `strainScore` now produces: an inactive
  // day ≈0, a rest day with a walk 2–4, a typical active day 8–11, a hard
  // session 14–17, a maximal day 19–21. They used to be sized for a scale the
  // app never produced — "recover 4–8" was below what an inactive worn day
  // scored, and "push 14–18" needed more than a marathon to reach.
  double lo;
  double hi;
  String band;
  if (rec < 40) {
    lo = 0;
    hi = 5;
    band = 'recover';
  } else if (rec < 60) {
    lo = 5;
    hi = 10;
    band = 'ease';
  } else if (rec < 80) {
    lo = 9;
    hi = 14;
    band = 'maintain';
  } else {
    lo = 13;
    hi = 18;
    band = 'push';
  }
  // ctl/atl/tsb arrive as raw daily TRIMP (hundreds), NOT strain points, so
  // these comparisons have to be scale-free. The thresholds used to be absolute
  // (`atl − ctl > 10`, `tsb > 5`) — magnitudes sized for the 0–21 scale — which
  // on TRIMP-scale inputs fired on ordinary week-to-week noise: a 320-vs-300
  // acute:chronic pair is a 6.7 % lift, not fatigue, yet it shrank the window.
  // Expressed against CTL, the same thresholds mean what they were meant to.
  final hasLoad = ctl != null && ctl > 0;
  final fatigueRatio = (hasLoad && atl != null) ? atl / ctl : null;
  final freshnessRatio = (hasLoad && tsb != null) ? tsb / ctl : null;
  if (fatigueRatio != null && fatigueRatio > 1.10) {
    lo -= 1;
    hi -= 2;
  } else if (freshnessRatio != null && freshnessRatio > 0.10) {
    hi += 1;
  }
  lo = lo.clamp(0.0, 21.0);
  hi = hi.clamp(lo + 1, 21.0);
  return Metric<StrainTarget>(
    value: StrainTarget(
      targetMin: lo,
      targetMax: hi,
      band: band,
      rationale: 'Target shaped by recovery and recent load.',
    ),
    confidence: 0.6,
    tier: Tier.estimate,
    inputs_used: const ['recovery', 'load'],
  );
}

// NOTE: `sex` and `age` used to be required here and in [physiologicalAge] and
// neither formula ever read them — a required argument that promises an
// adjustment the maths does not do. Dropped. Add them back WITH the adjustment.
Metric<double> vo2maxEstimate({
  required double? restingHr,
  required double? maxHr,
}) {
  // Uth-Sørensen-Overgaard-Pedersen 2004: VO2max ≈ 15.3 · (HRmax / HRrest).
  // The ratio is only defined for a STRICTLY POSITIVE resting HR — a 0 (the
  // package's off-skin sentinel, see types.dart HrSample) divides to Infinity,
  // which Metric.toJson emits raw and jsonEncode then throws on. `maxHr <=
  // restingHr` does not catch it, so guard the denominator explicitly and
  // abstain. Non-finite inputs abstain for the same reason.
  if (restingHr == null ||
      maxHr == null ||
      !restingHr.isFinite ||
      !maxHr.isFinite ||
      restingHr <= 0 ||
      maxHr <= restingHr) {
    return const Metric<double>.absent(
      tier: Tier.estimate,
      inputs_used: ['resting_hr', 'max_hr'],
      note:
          'VO2max needs a positive resting HR below HRmax — "—" (never imputed)',
    );
  }
  final vo2 = 15.3 * (maxHr / restingHr);
  return Metric<double>(
    value: vo2,
    confidence: 0.45,
    tier: Tier.estimate,
    inputs_used: const ['resting_hr', 'max_hr'],
    note: 'Uth-style resting VO2max estimate from HRmax:RHR',
  );
}

class PhysioAge {
  final double physioAge;
  final double deltaYears;
  const PhysioAge({required this.physioAge, required this.deltaYears});
  Map<String, dynamic> toJson() => {
        'physio_age': physioAge,
        'delta_years': deltaYears,
      };
}

Metric<PhysioAge> physiologicalAge({
  required double chronologicalAge,
  required double? vo2max,
  required double? restingHr,
  required double? rmssd,
  required double? sleepDurationH,
  required double? sleepEfficiency,
  required double? dailySteps,
}) {
  // ABSTAIN when NOTHING physiological was supplied. `score` starts at the
  // chronological age and only the blocks below move it, so with every
  // physiological input null this used to return a PRESENT metric reading
  // "physioAge == your age, delta 0" — a fabricated result — while claiming six
  // inputs it never saw. A physiological age with no physiology in it is not an
  // estimate, it is the birth date restated.
  final used = <String>[
    if (vo2max != null) 'vo2max',
    if (restingHr != null) 'resting_hr',
    if (rmssd != null) 'rmssd',
    if (sleepDurationH != null) 'sleep_duration',
    if (sleepEfficiency != null) 'sleep_efficiency',
    if (dailySteps != null) 'steps',
  ];
  if (used.isEmpty) {
    return const Metric<PhysioAge>.absent(
      tier: Tier.estimate,
      inputs_used: ['profile'],
      note: 'no physiological input present — "—" (never imputed; '
          'chronological age alone is not a physiological age)',
    );
  }

  var score = chronologicalAge;
  if (vo2max != null) {
    score -= ((vo2max - 35.0) / 5.0).clamp(-8.0, 8.0);
  }
  if (restingHr != null) {
    score += ((restingHr - 60.0) / 6.0).clamp(-5.0, 8.0);
  }
  if (rmssd != null) {
    score -= ((rmssd - 35.0) / 12.0).clamp(-4.0, 6.0);
  }
  if (sleepDurationH != null) {
    // Deviation from the ~7.5 h optimum ages you in BOTH directions — under- and
    // over-sleep both associate with worse outcomes. (Was `(7.5 - h)`, which
    // wrongly made oversleep look biologically YOUNGER.)
    score += (7.5 - sleepDurationH).abs().clamp(0.0, 3.0);
  }
  if (sleepEfficiency != null) {
    score += ((88.0 - sleepEfficiency) / 6.0).clamp(-2.0, 3.0);
  }
  if (dailySteps != null) {
    score -= ((dailySteps - 7000.0) / 3000.0).clamp(-3.0, 3.0);
  }
  score = score.clamp(18.0, 95.0);
  return Metric<PhysioAge>(
    value: PhysioAge(physioAge: score, deltaYears: score - chronologicalAge),
    // Confidence tracks how much physiology actually went in: one input is a
    // hint, all six is the intended estimate.
    confidence: (0.15 + 0.035 * used.length).clamp(0.15, 0.35),
    tier: Tier.estimate,
    // inputs_used reports what was ACTUALLY used, never the full menu.
    inputs_used: ['profile', ...used],
    note: 'directional physiological-age estimate from ${used.length}/6 '
        'physiological inputs',
  );
}

/// Unbiased (n−1) sample variance about a known mean. 0 for n < 2.
double _sampleVar(List<double> xs, double m) {
  if (xs.length < 2) return 0.0;
  var s = 0.0;
  for (final x in xs) {
    final dx = x - m;
    s += dx * dx;
  }
  return s / (xs.length - 1);
}

class JournalDay {
  final String date;
  final Set<String> tags;
  const JournalDay(this.date, this.tags);
}

class JournalEffect {
  final String outcome;
  final double delta;
  final double? pctChange;
  final String higherSide;
  final int nTagged;
  final int nUntagged;
  final bool insufficient;
  final bool meaningful;

  /// Standardized effect size — Cohen's d = delta / pooled SD (Cohen 1988).
  /// Null when the pooled within-group SD is 0 (both sides constant) or the
  /// comparison was not run at all. Disclosed so the "meaningful" verdict is
  /// auditable rather than a bare percentage.
  final double? cohensD;

  /// Pooled within-group SD used for [cohensD]; null when not computed.
  final double? pooledSd;
  const JournalEffect({
    required this.outcome,
    required this.delta,
    required this.pctChange,
    required this.higherSide,
    required this.nTagged,
    required this.nUntagged,
    required this.insufficient,
    required this.meaningful,
    this.cohensD,
    this.pooledSd,
  });
}

class JournalTagCorrelation {
  final String tag;
  final List<JournalEffect> effects;
  const JournalTagCorrelation(this.tag, this.effects);
}

/// Per-tag effect of a journal entry on each outcome series.
///
/// [outcomes] values must be POSITIONALLY ALIGNED to [dates] (same length); a
/// series of a different length cannot be attributed to dates at all, so it is
/// reported as insufficient rather than silently truncated or index-crashed.
///
/// [minEffectPct] and [minCohensD] set the "meaningful" bar. A percentage
/// difference of means alone is NOT evidence: with 2 days per side, two
/// noisy series routinely differ by several percent. The verdict therefore also
/// requires a standardized effect size (Cohen's d = delta / pooled SD ≥ 0.5,
/// Cohen's conventional "medium" effect) so within-group spread is accounted
/// for. When both sides are exactly constant (pooled SD = 0) d is undefined and
/// we require [minNForZeroSpread] observations per side before calling it.
List<JournalTagCorrelation> journalCorrelations({
  required List<JournalDay> journal,
  required List<String> dates,
  required Map<String, List<double?>> outcomes,
  double minEffectPct = 3.0,
  double minCohensD = 0.5,
  int minNForZeroSpread = 3,
}) {
  final allTags = <String>{for (final j in journal) ...j.tags};
  final tagByDate = {for (final j in journal) j.date: j.tags};
  final out = <JournalTagCorrelation>[];
  for (final tag in allTags) {
    final effects = <JournalEffect>[];
    for (final entry in outcomes.entries) {
      // LENGTH GUARD: `entry.value[i]` used to be indexed by dates.length with
      // no check, so any outcome list shorter than `dates` threw RangeError.
      // A misaligned series is not partially usable — we cannot know which
      // dates the values belong to — so abstain for this outcome.
      if (entry.value.length != dates.length) {
        effects.add(
          JournalEffect(
            outcome: entry.key,
            delta: 0,
            pctChange: null,
            higherSide: 'neither',
            nTagged: 0,
            nUntagged: 0,
            insufficient: true,
            meaningful: false,
          ),
        );
        continue;
      }
      final tagged = <double>[];
      final untagged = <double>[];
      for (var i = 0; i < dates.length; i++) {
        final v = entry.value[i];
        if (v == null) continue;
        final hasTag = tagByDate[dates[i]]?.contains(tag) == true;
        (hasTag ? tagged : untagged).add(v);
      }
      final insufficient = tagged.length < 2 || untagged.length < 2;
      if (insufficient) {
        effects.add(
          JournalEffect(
            outcome: entry.key,
            delta: 0,
            pctChange: null,
            higherSide: 'neither',
            nTagged: tagged.length,
            nUntagged: untagged.length,
            insufficient: true,
            meaningful: false,
          ),
        );
        continue;
      }
      final taggedMean = tagged.reduce((a, b) => a + b) / tagged.length;
      final untaggedMean = untagged.reduce((a, b) => a + b) / untagged.length;
      final delta = taggedMean - untaggedMean;
      final pct = untaggedMean.abs() < 1e-9
          ? null
          : (delta / untaggedMean.abs()) * 100.0;

      // DISPERSION TEST. Pooled within-group SD (Cohen 1988):
      //   sp = sqrt( ((n1-1)·s1² + (n2-1)·s2²) / (n1+n2-2) ),  d = delta / sp.
      // Without it, "3% difference of two means" was reported as a meaningful
      // journal effect off 2 days per side — a difference smaller than the
      // day-to-day noise of either side.
      final st = _sampleVar(tagged, taggedMean);
      final su = _sampleVar(untagged, untaggedMean);
      final dof = tagged.length + untagged.length - 2;
      final pooledVar = dof > 0
          ? ((tagged.length - 1) * st + (untagged.length - 1) * su) / dof
          : 0.0;
      final pooledSd = pooledVar > 0 ? math.sqrt(pooledVar) : 0.0;
      final d = pooledSd > 0 ? delta / pooledSd : null;

      final bigEnough = pct != null && pct.abs() >= minEffectPct;
      final separated = d != null
          ? d.abs() >= minCohensD
          // Both sides exactly constant: d is undefined. Only trust it with a
          // real number of observations behind each constant.
          : (delta.abs() > 0 &&
              tagged.length >= minNForZeroSpread &&
              untagged.length >= minNForZeroSpread);

      effects.add(
        JournalEffect(
          outcome: entry.key,
          delta: delta,
          pctChange: pct,
          higherSide: delta >= 0 ? 'tagged' : 'untagged',
          nTagged: tagged.length,
          nUntagged: untagged.length,
          insufficient: false,
          meaningful: bigEnough && separated,
          cohensD: d,
          pooledSd: pooledSd,
        ),
      );
    }
    out.add(JournalTagCorrelation(tag, effects));
  }
  out.sort((a, b) => a.tag.compareTo(b.tag));
  return out;
}

// ---------------------------------------------------------------------------
// Numeric journal fields
//
// [journalCorrelations] above answers "were the tagged days different?", which
// is the only question a tag set can answer. A field that carries a NUMBER —
// three coffees, 700 ml of water, mood 4/5, 90 minutes of screens — carries a
// dose, and collapsing it to present/absent throws that away: it cannot tell
// one coffee from five, which is usually the whole question.
//
// The statistic is Spearman's rank correlation (Spearman 1904), not Pearson.
// Self-reported dose is ordinal at best and routinely spiky (a single
// six-coffee day), and ranks are invariant to both — a monotone relationship is
// what "more of this goes with worse recovery" actually claims, and it is all
// these fields can support.
// ---------------------------------------------------------------------------

/// One day's numeric journal fields, keyed by field name.
///
/// A field absent from [values] means NOT RECORDED for that day, and is
/// excluded pairwise. It must never be read as a zero: "I logged no caffeine
/// today" and "I did not fill the caffeine field in" are different claims, and
/// treating the second as the first invents a data point at one end of the
/// dose range, which is exactly where a correlation is most sensitive.
class JournalNumericDay {
  final String date;
  final Map<String, double> values;
  const JournalNumericDay(this.date, this.values);
}

/// The relationship between one numeric journal field and one outcome series.
class JournalNumericEffect {
  final String outcome;

  /// Spearman's rho over the pairwise-complete days. Null when it could not be
  /// computed at all (too few days, or no spread on one side).
  final double? rho;

  /// Change in the outcome per one unit of the field, by Theil–Sen (median of
  /// pairwise slopes, ~29% breakdown). This is the interpretable half — "about
  /// 4 ms of RMSSD per extra coffee" — while [rho] carries whether the
  /// relationship holds at all. Null under the same conditions as [rho], and
  /// deliberately reported in the outcome's own units, unstandardized.
  final double? slopePerUnit;

  /// 95% confidence interval on [rho]: Fisher z transform with the Bonett &
  /// Wright (2000) rank standard error, sqrt((1 + rho²/2)/(n−3)). Null below 4
  /// pairs, where that standard error is undefined.
  final double? rhoLow;
  final double? rhoHigh;

  /// Days where both the field and the outcome were present.
  final int n;

  /// Not enough paired days, or the field never varied — no verdict either
  /// way. Distinct from a computed-but-weak relationship.
  final bool insufficient;

  /// Strong enough AND separated from zero to be worth showing: |rho| clears
  /// the floor and the confidence interval excludes 0. A rho alone is not
  /// evidence — over ten days, |rho| ≈ 0.5 arises constantly from noise.
  final bool meaningful;

  const JournalNumericEffect({
    required this.outcome,
    required this.rho,
    required this.slopePerUnit,
    required this.rhoLow,
    required this.rhoHigh,
    required this.n,
    required this.insufficient,
    required this.meaningful,
  });
}

class JournalNumericCorrelation {
  final String field;
  final List<JournalNumericEffect> effects;
  const JournalNumericCorrelation(this.field, this.effects);
}

/// Average ranks, 1-based, ties sharing their mean rank.
///
/// Tie handling is not a detail here: journal fields are full of ties (mood is
/// 1–5, most people log the same 2 coffees most days), and ranking ties
/// arbitrarily would invent an ordering the user never reported.
List<double> _averageRanks(List<double> xs) {
  final idx = List<int>.generate(xs.length, (i) => i)
    ..sort((a, b) => xs[a].compareTo(xs[b]));
  final ranks = List<double>.filled(xs.length, 0);
  var i = 0;
  while (i < idx.length) {
    var j = i;
    while (j + 1 < idx.length && xs[idx[j + 1]] == xs[idx[i]]) {
      j++;
    }
    // Ranks are 1-based, so positions i..j map to ranks i+1..j+1.
    final shared = (i + 1 + j + 1) / 2.0;
    for (var k = i; k <= j; k++) {
      ranks[idx[k]] = shared;
    }
    i = j + 1;
  }
  return ranks;
}

/// Pearson correlation. Null when either side has no spread.
double? _pearson(List<double> a, List<double> b) {
  if (a.length != b.length || a.length < 2) return null;
  final ma = mean(a)!;
  final mb = mean(b)!;
  var num = 0.0, da = 0.0, db = 0.0;
  for (var i = 0; i < a.length; i++) {
    final xa = a[i] - ma;
    final xb = b[i] - mb;
    num += xa * xb;
    da += xa * xa;
    db += xb * xb;
  }
  if (da == 0 || db == 0) return null;
  return num / math.sqrt(da * db);
}

/// Spearman's rho — Pearson on average ranks, so ties are handled correctly.
double? spearmanRho(List<double> a, List<double> b) =>
    _pearson(_averageRanks(a), _averageRanks(b));

/// Per-field relationship between numeric journal entries and each outcome.
///
/// [outcomes] values must be POSITIONALLY ALIGNED to [dates], exactly as in
/// [journalCorrelations]; a series of a different length is reported as
/// insufficient rather than silently truncated.
///
/// [minN] is the floor on paired days. It is higher than the tag path's
/// requirement because a correlation over a handful of points is close to
/// meaningless — with 5 days, |rho| > 0.8 happens by chance often enough to
/// fill a screen with confident nonsense.
List<JournalNumericCorrelation> journalNumericCorrelations({
  required List<JournalNumericDay> journal,
  required List<String> dates,
  required Map<String, List<double?>> outcomes,
  int minN = 8,
  double minAbsRho = 0.35,
}) {
  final byDate = <String, Map<String, double>>{
    for (final d in journal) d.date: d.values,
  };
  final fields = <String>{for (final d in journal) ...d.values.keys}.toList()
    ..sort();

  JournalNumericEffect none(String outcome, int n) => JournalNumericEffect(
        outcome: outcome,
        rho: null,
        slopePerUnit: null,
        rhoLow: null,
        rhoHigh: null,
        n: n,
        insufficient: true,
        meaningful: false,
      );

  final out = <JournalNumericCorrelation>[];
  for (final field in fields) {
    final effects = <JournalNumericEffect>[];
    for (final entry in outcomes.entries) {
      final series = entry.value;
      if (series.length != dates.length) {
        effects.add(none(entry.key, 0));
        continue;
      }

      // Pairwise-complete: a day counts only when the field was recorded AND
      // the outcome exists for it.
      final xs = <double>[];
      final ys = <double>[];
      for (var i = 0; i < dates.length; i++) {
        final v = byDate[dates[i]]?[field];
        final y = series[i];
        if (v == null || y == null) continue;
        xs.add(v);
        ys.add(y);
      }

      final n = xs.length;
      final rho = n >= minN ? spearmanRho(xs, ys) : null;
      if (rho == null) {
        effects.add(none(entry.key, n));
        continue;
      }

      // Fisher z CI. atanh diverges at |rho| = 1, which a monotone field hits
      // easily — every "more coffee, worse HRV" day in order gives exactly -1.
      // Abstaining there would throw away the strongest evidence there is, and
      // clamping to 1 - 1e-9 would claim near-infinite confidence from twelve
      // days. So the saturated value is pulled in by 1/(2n): the interval
      // still excludes zero, but it widens as the sample shrinks, which is the
      // honest reading of a perfect correlation over very few days.
      double? lo, hi;
      if (n > 3) {
        final ceiling = 1.0 - 1.0 / (2.0 * n);
        final r = rho.clamp(-ceiling, ceiling);
        final zr = 0.5 * math.log((1 + r) / (1 - r));
        // Bonett & Wright (2000) standard error, NOT Fisher's 1/sqrt(n−3).
        // That one is derived for Pearson's r under bivariate normality; ranks
        // are neither, and it runs narrow for rho. Since `meaningful` is gated
        // on this interval excluding zero, the narrower SE would let weaker
        // relationships through — the error points the wrong way for a
        // function whose job is to refuse.
        final se = math.sqrt((1.0 + r * r / 2.0) / (n - 3));
        double tanh(double v) {
          final e = math.exp(2 * v);
          return (e - 1) / (e + 1);
        }

        lo = tanh(zr - 1.96 * se);
        hi = tanh(zr + 1.96 * se);
      }

      final separated = lo != null && hi != null && (lo > 0) == (hi > 0);
      effects.add(
        JournalNumericEffect(
          outcome: entry.key,
          rho: rho,
          slopePerUnit: theilSen(ys, xs),
          rhoLow: lo,
          rhoHigh: hi,
          n: n,
          insufficient: false,
          meaningful: rho.abs() >= minAbsRho && separated,
        ),
      );
    }
    out.add(JournalNumericCorrelation(field, effects));
  }
  out.sort((a, b) => a.field.compareTo(b.field));
  return out;
}
