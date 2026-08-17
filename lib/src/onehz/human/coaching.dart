import 'dart:math' as math;

import '../types.dart';
import '../util.dart'
    show averageRanks, benjaminiHochberg, mean, normalTwoSidedP, theilSen;

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

/// A BAND, NOT AN INSTRUCTION — and it must stay that way.
///
/// nocturnal RMSSD and RHR are the best-validated things this band produces
/// (CCC 0.94, MAPE ~8% vs ECG over 536 nights), which is precisely why turning
/// them into "do not train hard today" is tempting and why the request keeps
/// arriving. the step from "today's ln-RMSSD is below your 7-day rolling mean"
/// to a training prescription requires an effect on training OUTCOME that has
/// not been established outside small athlete cohorts under daily supervision.
/// the inputs validate; the instruction does not.
///
/// so this returns a range and a `rationale` that describes drivers, and it
/// emits no verb. never "skip your session", never "train hard today", never a
/// session type attached to a recovery state, never a rest day. anything in the
/// imperative mood does not ship. two facts and no verb is the only honest
/// extension. `glassBoxReadiness` sits under the same rule for the same reason
/// — nothing to build there either, it already complies.
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

  /// Strong enough AND surviving the multiplicity correction to be worth
  /// showing: the effect size clears its floor (|rho| ≥ minAbsRho on the dose
  /// path, |d| ≥ minCohensD on the 0/1 path) AND [q] ≤ the FDR level. A rho
  /// alone is not evidence — over ten days, |rho| ≈ 0.5 arises constantly from
  /// noise — and a per-test p is not evidence either once 36 of them run at
  /// once.
  final bool meaningful;

  /// This field only ever took the values 0 and 1 on the paired days, so it was
  /// routed to a DIFFERENCE OF MEANS, not to a rank correlation. A tick-box is
  /// a group membership, not a dose: rho and "slope per unit" on it are a group
  /// difference wearing the wrong clothes. On this path [rho], [slopePerUnit]
  /// and the rho interval are null and [delta]/[cohensD] carry the answer.
  final bool binary;

  /// 0/1 path only: mean(outcome | field = 1) − mean(outcome | field = 0), in
  /// the outcome's own units. Null on the dose path.
  final double? delta;

  /// 0/1 path only: Cohen's d = [delta] / pooled within-group SD. Null on the
  /// dose path, and null when both sides are exactly constant.
  final double? cohensD;

  /// 0/1 path only: days with the field at 1, and at 0. Both null otherwise.
  final int? nWith;
  final int? nWithout;

  /// Two-sided p for this single test, before any correction. Null when no test
  /// could be run. NOT a publication gate on its own — see [q].
  final double? p;

  /// Benjamini-Hochberg (1995) FDR-adjusted p over THE WHOLE GRID returned by
  /// one call — every field × every outcome. This is the number the "meaningful"
  /// verdict is gated on. Null when [p] is null.
  ///
  /// Why it is not optional: 9 built-in numeric fields × 4 outcomes is 36
  /// simultaneous tests. At a per-test 0.05 gate that is ~2 findings from pure
  /// noise for every user, every load — a machine for manufacturing confident
  /// nonsense out of a journal.
  final double? q;

  const JournalNumericEffect({
    required this.outcome,
    required this.rho,
    required this.slopePerUnit,
    required this.rhoLow,
    required this.rhoHigh,
    required this.n,
    required this.insufficient,
    required this.meaningful,
    this.binary = false,
    this.delta,
    this.cohensD,
    this.nWith,
    this.nWithout,
    this.p,
    this.q,
  });
}

class JournalNumericCorrelation {
  final String field;
  final List<JournalNumericEffect> effects;

  /// Days between the journal entry and the outcome it was matched against
  /// (MIND-02). 0 = the same day label, +1 = the following morning's outcome.
  /// Surfaced so a screen can say WHICH night it means — "yesterday's coffee
  /// against last night's HRV" is a different sentence from "today's mood
  /// against last night's HRV", and a user who has already seen a finding is
  /// entitled to know the alignment changed.
  final int lagDays;
  const JournalNumericCorrelation(this.field, this.effects, {this.lagDays = 0});
}

/// PER-FIELD outcome lag, in days (MIND-02).
///
/// The bug this fixes: `_targetDayWindow` searches back 12 h from midnight, so
/// readiness / rmssd / efficiency labelled date D come from the night ENDING on
/// the morning of D. The journal row is written at bedtime of D and describes
/// the DAYTIME of D. Correlating them at lag 0 compares today's coffee against
/// a night that was over before it was drunk.
///
/// It is per-field and NEVER a global shift, because the fields point in
/// opposite directions. Mood, sleep quality, soreness and stress are
/// RETROSPECTIVE — they describe the state the finished night produced, and
/// lag 0 is already correct for them; a blanket +1 would break the ones that
/// work today. Caffeine, alcohol, water and steps are BEHAVIOUR during the day
/// and land on the night that follows, so they take +1.
///
/// A field not listed here keeps lag 0 — a custom field could be either kind,
/// and quietly re-aligning something we cannot classify is the same mistake in
/// the other direction.
///
/// NO LAG SCAN. Trying {0,+1,+2} triples the grid and multiplies exactly the
/// multiplicity problem the Benjamini-Hochberg correction above just paid to
/// fix. One fixed constant, disclosed.
const Map<String, int> journalFieldLagDays = {
  'caffeine': 1,
  'caffeine_at_min': 1,
  'alcohol': 1,
  'water': 1,
  'steps': 1,
  'nicotine': 1,
  'late_meal': 1,
  'screen_time': 1,
  'mood': 0,
  'sleep_quality': 0,
  'soreness': 0,
  'stress': 0,
  'energy': 0,
};

/// The day label [days] after [label] (`YYYY-MM-DD`), or null when the label is
/// not a date we can shift. UTC arithmetic: a DST boundary must not turn +1 day
/// into +23 h and round to 0.
String? shiftDayLabel(String label, int days) {
  if (days == 0) return label;
  final d = DateTime.tryParse('${label}T00:00:00Z');
  if (d == null) return null;
  final s = d.add(Duration(days: days));
  return '${s.year.toString().padLeft(4, '0')}-'
      '${s.month.toString().padLeft(2, '0')}-'
      '${s.day.toString().padLeft(2, '0')}';
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
    _pearson(averageRanks(a), averageRanks(b));

/// Per-field relationship between numeric journal entries and each outcome.
///
/// [outcomes] values must be POSITIONALLY ALIGNED to [dates], exactly as in
/// [journalCorrelations]; a series of a different length is reported as
/// insufficient rather than silently truncated.
///
/// Two-sided permutation p for a difference of means between two labelled
/// groups: reshuffle the labels [b] times and count how often the shuffled
/// |difference| reaches the observed one.
///
/// Distribution-free, which is the point — the alternative at these sample
/// sizes is a normal approximation to Welch's t over eight days, which is
/// anticonservative exactly where the answer matters. Seeded, so the same
/// journal always yields the same p; the +1s are the standard bias correction
/// that keeps p away from a fabricated 0.
double _permTwoSampleP(List<double> ys, List<bool> inGroup, int b, int seed) {
  double diff(List<bool> g) {
    var s1 = 0.0, s0 = 0.0;
    var n1 = 0, n0 = 0;
    for (var i = 0; i < ys.length; i++) {
      if (g[i]) {
        s1 += ys[i];
        n1++;
      } else {
        s0 += ys[i];
        n0++;
      }
    }
    if (n1 == 0 || n0 == 0) return 0.0;
    return s1 / n1 - s0 / n0;
  }

  final obs = diff(inGroup).abs();
  final rng = math.Random(seed);
  final shuffled = [...inGroup];
  var ge = 0;
  for (var k = 0; k < b; k++) {
    shuffled.shuffle(rng);
    if (diff(shuffled).abs() >= obs - 1e-12) ge++;
  }
  return (ge + 1) / (b + 1);
}

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
///
/// TWO STATISTICS, chosen by what the field actually is:
///   * a field that only ever took 0 and 1 is a TICK BOX — a habit, in this
///     app, since habits are just custom fields with `max == 1`. It gets a
///     difference of means with Cohen's d, the same comparison the tag path
///     runs, because "the difference it made" is the only question a yes/no
///     can answer. A rank correlation and a "slope per unit" on a two-valued
///     field is a group difference wearing the wrong clothes.
///   * anything else carries a dose and gets Spearman.
///
/// MULTIPLICITY. Every test in the grid this call returns is corrected together
/// by Benjamini-Hochberg at [fdrAlpha], and `meaningful` is gated on the
/// resulting q, never on the raw p. With one field and one outcome the
/// correction is the identity, so a single test behaves exactly as it did.
/// Across the built-in grid (9 fields × 4 outcomes) it is the difference
/// between a screen of findings and a screen of noise.
List<JournalNumericCorrelation> journalNumericCorrelations({
  required List<JournalNumericDay> journal,
  required List<String> dates,
  required Map<String, List<double?>> outcomes,
  int minN = 8,
  double minAbsRho = 0.35,
  double minCohensD = 0.5,
  int minPerSide = 3,
  double fdrAlpha = 0.05,
  int permutations = 999,
  int permutationSeed = 20260817,
  Map<String, int> fieldLagDays = journalFieldLagDays,
}) {
  final byDate = <String, Map<String, double>>{
    for (final d in journal) d.date: d.values,
  };
  final indexByDate = <String, int>{
    for (var i = 0; i < dates.length; i++) dates[i]: i,
  };
  final fields = <String>{for (final d in journal) ...d.values.keys}.toList()
    ..sort();

  // One row per (field, outcome) in emission order. Built first, gated second:
  // the FDR correction needs the whole family before any verdict can be given.
  final rows = <({
    String field,
    String outcome,
    int n,
    double? rho,
    double? slope,
    double? lo,
    double? hi,
    bool binary,
    double? delta,
    double? cohensD,
    int? nWith,
    int? nWithout,
    double? p,
    bool floorOk,
    bool insufficient,
  })>[];

  void addNone(String field, String outcome, int n) => rows.add((
        field: field,
        outcome: outcome,
        n: n,
        rho: null,
        slope: null,
        lo: null,
        hi: null,
        binary: false,
        delta: null,
        cohensD: null,
        nWith: null,
        nWithout: null,
        p: null,
        floorOk: false,
        insufficient: true,
      ));

  for (final field in fields) {
    for (final entry in outcomes.entries) {
      final series = entry.value;
      if (series.length != dates.length) {
        addNone(field, entry.key, 0);
        continue;
      }

      // Pairwise-complete: a day counts only when the field was recorded AND
      // the outcome LAG DAYS LATER exists for it. A journal day whose lagged
      // outcome is not in the series is DROPPED, which lowers n — never
      // back-filled with the same day's outcome, which is the mispairing this
      // whole change exists to remove.
      final lag = fieldLagDays[field] ?? 0;
      final xs = <double>[];
      final ys = <double>[];
      for (var i = 0; i < dates.length; i++) {
        final v = byDate[dates[i]]?[field];
        if (v == null) continue;
        final int? at;
        if (lag == 0) {
          at = i;
        } else {
          final label = shiftDayLabel(dates[i], lag);
          at = label == null ? null : indexByDate[label];
        }
        if (at == null) continue;
        final y = series[at];
        if (y == null) continue;
        xs.add(v);
        ys.add(y);
      }

      final n = xs.length;
      if (n < minN) {
        addNone(field, entry.key, n);
        continue;
      }

      // 0/1 FIELD → difference of means (see the doc comment).
      final isBinary = xs.every((v) => v == 0.0 || v == 1.0) &&
          xs.contains(0.0) &&
          xs.contains(1.0);
      if (isBinary) {
        final inGroup = [for (final v in xs) v == 1.0];
        final withIt = <double>[];
        final without = <double>[];
        for (var i = 0; i < n; i++) {
          (inGroup[i] ? withIt : without).add(ys[i]);
        }
        if (withIt.length < minPerSide || without.length < minPerSide) {
          addNone(field, entry.key, n);
          continue;
        }
        final mw = mean(withIt)!;
        final mo = mean(without)!;
        final delta = mw - mo;
        final dof = n - 2;
        final pooledVar = dof > 0
            ? ((withIt.length - 1) * _sampleVar(withIt, mw) +
                    (without.length - 1) * _sampleVar(without, mo)) /
                dof
            : 0.0;
        final pooledSd = pooledVar > 0 ? math.sqrt(pooledVar) : 0.0;
        final d = pooledSd > 0 ? delta / pooledSd : null;
        rows.add((
          field: field,
          outcome: entry.key,
          n: n,
          rho: null,
          slope: null,
          lo: null,
          hi: null,
          binary: true,
          delta: delta,
          cohensD: d,
          nWith: withIt.length,
          nWithout: without.length,
          p: _permTwoSampleP(ys, inGroup, permutations, permutationSeed),
          // Both sides exactly constant leaves d undefined; the per-side floor
          // is already the tag path's zero-spread rule, so a real gap between
          // two constants still counts.
          floorOk: d != null ? d.abs() >= minCohensD : delta.abs() > 0,
          insufficient: false,
        ));
        continue;
      }

      final rho = spearmanRho(xs, ys);
      if (rho == null) {
        addNone(field, entry.key, n);
        continue;
      }

      // Fisher z CI. atanh diverges at |rho| = 1, which a monotone field hits
      // easily — every "more coffee, worse HRV" day in order gives exactly -1.
      // Abstaining there would throw away the strongest evidence there is, and
      // clamping to 1 - 1e-9 would claim near-infinite confidence from twelve
      // days. So the saturated value is pulled in by 1/(2n): the interval
      // still excludes zero, but it widens as the sample shrinks, which is the
      // honest reading of a perfect correlation over very few days.
      double? lo, hi, p;
      if (n > 3) {
        final ceiling = 1.0 - 1.0 / (2.0 * n);
        final r = rho.clamp(-ceiling, ceiling);
        final zr = 0.5 * math.log((1 + r) / (1 - r));
        // Bonett & Wright (2000) standard error, NOT Fisher's 1/sqrt(n−3).
        // That one is derived for Pearson's r under bivariate normality; ranks
        // are neither, and it runs narrow for rho. Since the verdict is gated
        // on this, the narrower SE would let weaker relationships through —
        // the error points the wrong way for a function whose job is to refuse.
        final se = math.sqrt((1.0 + r * r / 2.0) / (n - 3));
        double tanh(double v) {
          final e = math.exp(2 * v);
          return (e - 1) / (e + 1);
        }

        lo = tanh(zr - 1.96 * se);
        hi = tanh(zr + 1.96 * se);
        // The same z the interval is built from, read as a two-sided p. So at
        // a family of one, "q ≤ 0.05" and the old "the 95% interval excludes
        // zero" are the same test — the correction only ever tightens it.
        p = normalTwoSidedP(zr / se);
      }

      rows.add((
        field: field,
        outcome: entry.key,
        n: n,
        rho: rho,
        slope: theilSen(ys, xs),
        lo: lo,
        hi: hi,
        binary: false,
        delta: null,
        cohensD: null,
        nWith: null,
        nWithout: null,
        p: p,
        floorOk: rho.abs() >= minAbsRho,
        insufficient: false,
      ));
    }
  }

  final qs = benjaminiHochberg([for (final r in rows) r.p]);
  final byField = <String, List<JournalNumericEffect>>{};
  for (var i = 0; i < rows.length; i++) {
    final r = rows[i];
    final q = qs[i];
    byField.putIfAbsent(r.field, () => []).add(
          JournalNumericEffect(
            outcome: r.outcome,
            rho: r.rho,
            slopePerUnit: r.slope,
            rhoLow: r.lo,
            rhoHigh: r.hi,
            n: r.n,
            insufficient: r.insufficient,
            meaningful: r.floorOk && q != null && q <= fdrAlpha,
            binary: r.binary,
            delta: r.delta,
            cohensD: r.cohensD,
            nWith: r.nWith,
            nWithout: r.nWithout,
            p: r.p,
            q: q,
          ),
        );
  }

  final out = [
    for (final field in fields)
      JournalNumericCorrelation(field, byField[field] ?? const [],
          lagDays: fieldLagDays[field] ?? 0),
  ];
  out.sort((a, b) => a.field.compareTo(b.field));
  return out;
}
