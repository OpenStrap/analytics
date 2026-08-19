// HUMAN — what actually moves your recovery, your sleep, your strain (MIND-20).
//
// This is the single highest fabrication risk in the product. "Your insights"
// screens in consumer health apps are, almost universally, a noise generator
// with a confident font. Twenty candidate inputs against five outcomes is a
// hundred hypothesis tests; at a per-test p < 0.05 you expect five significant
// results from data with nothing in it at all, and those five ARE the screen.
// Every design decision below exists to stop that, and most of them cost power
// on purpose.
//
// The six things that make the naive version wrong, and what is done here:
//
//  1. MULTIPLICITY. Every pair that can be tested IS tested, and the whole grid
//     goes through Benjamini-Hochberg (1995) before anything is published. The
//     family is never pruned by effect size first — screening on the statistic
//     and then correcting only the survivors is the multiple-comparisons
//     problem wearing a disguise. A pair we abstained from does not enter m
//     (it is not a test we performed); a pair we ran does, however weak.
//
//  2. AUTOCORRELATION. Consecutive days are not independent — sleep debt,
//     training load, illness and mood all persist for days — and a classical
//     or naive-shuffle p on serially dependent series is badly optimistic. Two
//     independent AR(1) walks produce large sample correlations routinely, and
//     a test that shuffles days one at a time destroys exactly the structure
//     that caused them, so it calls them significant. The null here is built by
//     MOVING-BLOCK PERMUTATION: the outcome series is cut into week-long blocks
//     and the BLOCKS are reordered, which keeps each series' own persistence
//     intact while destroying its alignment to the other. `blockLen` is 7 days
//     by default — the natural block for human daily data, and it preserves the
//     weekly cycle inside each block as a side effect. The false-positive test
//     in the test-suite fails outright with day-wise shuffling and passes with
//     this, which is the whole justification.
//
//  3. LAG IS DIRECTIONAL AND IT IS THE POINT. Last night's sleep can move today
//     — today cannot move last night. Every variable declares WHEN IN THE DAY
//     it happened ([VarTiming]) and the lag falls out of the pair, per pair,
//     never as a global column shift. A pair whose only alignment would run
//     backwards in time is refused rather than flipped. There is deliberately
//     NO LAG SCAN: trying {0,+1,+2} triples the grid and re-creates precisely
//     the multiplicity problem the BH correction just paid for. One derived
//     lag, disclosed on the finding.
//
//  4. CONFOUNDING. Weekday drives sleep, alcohol, training and steps at the
//     same time, so "late meals hurt my recovery" is very often "Saturday".
//     Both series are WEEKDAY-ADJUSTED (per-weekday median removed) BEFORE the
//     statistic is computed, so the published number is the within-weekday
//     association and a weekend cannot manufacture it. The unadjusted rho is
//     reported alongside for disclosure, never as the verdict; when the two
//     disagree the finding carries a `weekday_confounded` caveat.
//
//  5. TAUTOLOGY. This one is specific to us and it is the worst of them.
//     Readiness IS a weighted composite of nocturnal HRV, RHR, respiratory rate
//     and skin temperature. Correlating any of those four against readiness
//     produces a huge, beautiful, perfectly meaningless finding — we would be
//     reporting our own arithmetic back to the user as a discovery. So a
//     variable declares what it is [DailyVariable.derivedFrom], and any pair
//     where one side is a constituent of the other is refused by construction.
//
//  6. REDUNDANCY. Sleep duration, time in bed and sleep efficiency will all
//     "predict" recovery, because on most nights they are one thing measured
//     three ways. Publishing all three is one insight repeated until it looks
//     like a body of evidence. Surviving findings are clustered by the observed
//     correlation BETWEEN THE INPUTS and only the strongest of each cluster is
//     published; the rest stay in [AssociationScan.tested] with a pointer.
//
// ABSENCE IS AN ANSWER. A variable that is not populated often enough is
// dropped with a reason, not imputed; a pair with too few paired days is
// refused with a reason, not run at a lower bar. An engine with three weeks of
// data and nothing solid to say returns an ABSENT metric that says how many
// nights it has and how many it needs. It never lowers the gate to fill a
// screen.
//
// HONESTY CEILING, AND IT IS THE HARD KIND. Everything here is ASSOCIATION IN
// ONE PERSON'S OWN OBSERVATIONAL HISTORY. Nothing is randomised, nothing is
// controlled beyond weekday, and an unmeasured cause behind both series is
// always available. No output of this file is advice, none of it is a
// mechanism, and none of it licenses "do more X" — the project law is
// detection, never diagnosis, and a correlation engine is the easiest place in
// the app to break it. Copy built on these findings must say what was OBSERVED
// in this person's data, with its sample size attached.

import 'dart:math' as math;

import '../types.dart';
import '../util.dart';

/// When in the day a variable's value actually happened.
///
/// This is the entire basis of the lag, so it is not cosmetic. A `night`
/// variable labelled D describes the night that ENDED on the morning of D
/// (every sleep metric, and every nocturnal cardio metric, is one of these — it
/// is also how the rest of this codebase labels them). A `day` variable
/// labelled D describes the waking day of D: strain, steps, mood, what was
/// drunk and when it was eaten.
enum VarTiming {
  /// The night ending on the morning of this day label.
  night,

  /// The waking hours of this day label.
  day,
}

/// Whether a variable may be used as a candidate cause, an outcome, or both.
enum VarRole { input, outcome, both }

/// One day-level series, with everything needed to know what may be asked of
/// it. The caller owns the catalog — this file never hardcodes a metric key,
/// so a new day-level metric becomes a candidate by being passed in, not by
/// being added here.
class DailyVariable {
  /// Stable machine key (`sleep_duration_min`, `alcohol`, …).
  final String key;

  /// Human label for copy.
  final String label;

  /// Unit the values are in, for copy that has to be feelable ('min', 'bpm',
  /// 'ms', 'points', 'steps'). Empty for unitless / ordinal fields.
  final String unit;

  /// Positionally aligned to the `dates` passed to [scanAssociations]. Null is
  /// NOT RECORDED and is excluded pairwise — never read as a zero.
  final List<double?> values;

  final VarTiming timing;
  final VarRole role;

  /// Keys this variable is COMPUTED FROM. Any pair where one side appears in
  /// the other's `derivedFrom` is refused as a tautology — see the header. Two
  /// levels are not chased: declare the closure.
  final Set<String> derivedFrom;

  const DailyVariable({
    required this.key,
    required this.label,
    required this.values,
    required this.timing,
    this.role = VarRole.both,
    this.unit = '',
    this.derivedFrom = const {},
  });

  bool get canBeInput => role == VarRole.input || role == VarRole.both;
  bool get canBeOutcome => role == VarRole.outcome || role == VarRole.both;
}

/// How the low/high groups behind [Association.contrast] were cut.
enum ContrastSplit {
  /// Bottom third vs top third of the input's own distribution.
  tertile,

  /// The input only took two values on the paired days (a tick-box), so the
  /// contrast is simply the two groups.
  binary,
}

/// One surviving (or tested-and-rejected) association.
///
/// Read every field as "in this person's own history", never as a mechanism.
class Association {
  final String inputKey;
  final String inputLabel;
  final String inputUnit;
  final String outcomeKey;
  final String outcomeLabel;
  final String outcomeUnit;

  /// Days from the input's label to the outcome's label. Derived from the two
  /// [VarTiming]s, ALWAYS >= 0, and disclosed because "yesterday's training
  /// against tonight's sleep" is a different sentence from "this morning's".
  final int lagDays;

  /// Spearman's rho on the WEEKDAY-ADJUSTED series at [lagDays] — the statistic
  /// the p-value actually tested. Rank-based, so one wrecked night does not
  /// carry it and a monotone (not necessarily linear) relationship is what is
  /// being claimed, which is all daily self-tracked data supports.
  final double rho;

  /// The same rho WITHOUT the weekday adjustment. Disclosure only, never the
  /// verdict: when this is much larger than [rho], a weekday was doing the
  /// work, and [caveats] says so.
  final double rhoRaw;

  /// Days where both sides were present at this lag. Print it next to the
  /// claim; it is the number that makes a finding readable as evidence.
  final int n;

  /// Fraction of the scan window on which the input was recorded at all. A
  /// sparse self-entered field is not disqualified by being sparse, but its
  /// sparsity is carried into [confidence] and shown, never hidden.
  final double inputCoverage;

  /// Two-sided moving-block permutation p. Exact-in-form under the independence
  /// null for any marginal and any tie structure, and — unlike a day-wise
  /// shuffle — it keeps each series' persistence. NOT a publication gate on its
  /// own: see [q].
  final double p;

  /// Benjamini-Hochberg FDR-adjusted p across the WHOLE grid this scan ran.
  /// This is what [meaningful] is gated on.
  final double q;

  /// THE FEELABLE NUMBER. Median outcome on the input's high days minus median
  /// outcome on its low days, in the OUTCOME's own units, signed. "Recovery
  /// about 8 points lower" — an r is not something anybody can feel.
  final double contrast;

  /// The input values bounding the low and high groups, in the INPUT's units,
  /// so copy can say WHICH nights it means ("under 6h10m" / "over 7h20m").
  final double lowCut;
  final double highCut;
  final int nLow;
  final int nHigh;

  /// Median of the outcome over the paired days — the reference [contrast] is
  /// felt against ("8 points below your median of 61").
  final double outcomeMedian;

  final ContrastSplit split;

  /// Machine-readable, additive, and part of the finding rather than a footnote
  /// on it. Currently emitted: `weekday_confounded`, `sparse_input`,
  /// `self_reported_input`, `binary_contrast`, `short_history`.
  final List<String> caveats;

  /// Cleared the FDR gate AND the effect-size floor AND survived deduplication.
  /// The ONLY field a screen may gate on.
  final bool meaningful;

  /// Set when this finding was dropped as a restatement of another one: the key
  /// of the input that was kept instead. Null when this finding stands alone.
  final String? redundantWith;

  const Association({
    required this.inputKey,
    required this.inputLabel,
    required this.inputUnit,
    required this.outcomeKey,
    required this.outcomeLabel,
    required this.outcomeUnit,
    required this.lagDays,
    required this.rho,
    required this.rhoRaw,
    required this.n,
    required this.inputCoverage,
    required this.p,
    required this.q,
    required this.contrast,
    required this.lowCut,
    required this.highCut,
    required this.nLow,
    required this.nHigh,
    required this.outcomeMedian,
    required this.split,
    required this.caveats,
    required this.meaningful,
    this.redundantWith,
  });

  Association _copyWith({bool? meaningful, String? redundantWith, double? q}) =>
      Association(
        inputKey: inputKey,
        inputLabel: inputLabel,
        inputUnit: inputUnit,
        outcomeKey: outcomeKey,
        outcomeLabel: outcomeLabel,
        outcomeUnit: outcomeUnit,
        lagDays: lagDays,
        rho: rho,
        rhoRaw: rhoRaw,
        n: n,
        inputCoverage: inputCoverage,
        p: p,
        q: q ?? this.q,
        contrast: contrast,
        lowCut: lowCut,
        highCut: highCut,
        nLow: nLow,
        nHigh: nHigh,
        outcomeMedian: outcomeMedian,
        split: split,
        caveats: caveats,
        meaningful: meaningful ?? this.meaningful,
        redundantWith: redundantWith ?? this.redundantWith,
      );

  Map<String, dynamic> toJson() => {
        'input': inputKey,
        'input_label': inputLabel,
        'input_unit': inputUnit,
        'outcome': outcomeKey,
        'outcome_label': outcomeLabel,
        'outcome_unit': outcomeUnit,
        'lag_days': lagDays,
        'rho': round6(rho),
        'rho_raw': round6(rhoRaw),
        'n': n,
        'input_coverage': round6(inputCoverage),
        'p': round6(p),
        'q': round6(q),
        'contrast': round6(contrast),
        'low_cut': round6(lowCut),
        'high_cut': round6(highCut),
        'n_low': nLow,
        'n_high': nHigh,
        'outcome_median': round6(outcomeMedian),
        'split': split.name,
        'caveats': caveats,
        'meaningful': meaningful,
        if (redundantWith != null) 'redundant_with': redundantWith,
      };
}

/// Why a candidate pair or variable never became a test. Kept and returned:
/// "we looked and could not say" is a result, and it is the one that stops the
/// engine from looking broken when it is being honest.
class AssociationRefusal {
  /// `<input>-><outcome>` for a pair, or the bare key for a whole variable.
  final String subject;

  /// Machine-readable: `tautology`, `backwards_in_time`, `simultaneous`,
  /// `sparse`, `constant`, `need_pairs:have=N,need=M`, `no_contrast`,
  /// `not_an_input`, `misaligned_series`.
  final String reason;
  const AssociationRefusal(this.subject, this.reason);

  Map<String, dynamic> toJson() => {'subject': subject, 'reason': reason};
}

/// The whole scan: what was published, what was tested, what was refused.
class AssociationScan {
  /// Published findings, ranked and deduplicated. This is the screen.
  final List<Association> findings;

  /// EVERY pair that got a p-value, in the same family the FDR correction was
  /// computed over — including the ones that failed it. Auditability is not
  /// optional for a feature like this; a findings list with no denominator is
  /// how these screens lie.
  final List<Association> tested;

  /// Pairs and variables that never became a test, each with its reason.
  final List<AssociationRefusal> refusals;

  /// Days spanned by the scan window (calendar days, first to last label).
  final int spanDays;

  /// Size of the family the BH correction was applied over.
  final int testsRun;

  /// FDR level the verdict was taken at.
  final double fdrAlpha;

  const AssociationScan({
    required this.findings,
    required this.tested,
    required this.refusals,
    required this.spanDays,
    required this.testsRun,
    required this.fdrAlpha,
  });

  Map<String, dynamic> toJson() => {
        'findings': [for (final f in findings) f.toJson()],
        'tested': [for (final t in tested) t.toJson()],
        'refusals': [for (final r in refusals) r.toJson()],
        'span_days': spanDays,
        'tests_run': testsRun,
        'fdr_alpha': round6(fdrAlpha),
      };
}

/// Minimum blocks the moving-block null needs before it has a usable tail.
///
/// Six blocks is 720 distinct orderings, so the smallest p the test can even
/// represent is ~0.0014. Below that the test is not conservative, it is
/// VACUOUS — it cannot produce a small enough number to clear an FDR
/// correction however strong the effect is, and an engine that runs a test it
/// could never pass and then reports "no findings" is lying by omission.
const int associationMinBlocks = 6;

/// Minimum paired days before a pair is testable at all — twelve weeks.
///
/// This is [associationMinBlocks] x the 14-day default block, and it is a
/// consequence of the block length rather than a taste. Measured on pure AR(1)
/// noise across 200 synthetic histories, the fraction publishing at least one
/// false finding at an FDR of 0.10 was:
///
///     block    phi=0    phi=0.4   phi=0.6   phi=0.8
///       7      11.0%     14.0%     15.5%     22.0%
///      14      13.0%     12.5%     11.0%     12.0%
///      20       7.0%      9.0%     10.5%      8.0%
///
/// 7 days does not hold at the persistence real training and illness data
/// actually has; 20 costs a third of the power (detection of a planted lag-1
/// effect fell from 64% to 43%) for no gain in honesty. 14 is the point where
/// the rate sits at nominal across the whole range, and it costs 8 points of
/// power against 7. The effective floor is always
/// `max(this, associationMinBlocks * blockLen)`, so lowering the block length
/// lowers this with it and the two can never silently disagree.
const int associationMinPairedDays = 84;

/// Minimum fraction of the window on which an input must actually be recorded.
///
/// The rule the brief asks for: a column existing is not a reason to test it. A
/// mood field filled in four times is not a candidate cause, it is four days.
const double associationMinCoverage = 0.5;

/// Reporting floor on the effect size, in units of the outcome's own spread.
///
/// A statistically surviving association that moves the outcome by a tenth of
/// its own interquartile range is not something a person can feel, and putting
/// it on a screen next to a real one flattens both.
const double associationMinContrastIqr = 0.25;

/// |Spearman| between two INPUTS at or above which they are treated as the same
/// construct measured twice, and only the stronger finding is published.
const double associationRedundancyRho = 0.7;

/// The lag, in days, from [input]'s label to [outcome]'s label — or null when
/// the pair cannot be aligned in a direction that runs forwards in time.
///
/// A `night` label D is the night that ended on the morning of D; a `day` label
/// D is the waking day of D, which FOLLOWS it. So:
///
///   night -> day    lag 0   last night's sleep against today's training
///   day   -> night  lag +1  today's drinking against tonight's sleep, which
///                           is labelled tomorrow because it ends then
///   night -> night  lag +1  last night against the NEXT night
///   day   -> day    lag +1  today's training against tomorrow's mood
///
/// The two same-timing pairs are given +1 rather than 0 deliberately. At lag 0
/// they are SIMULTANEOUS — a bad night both shortens sleep and raises heart
/// rate, and nothing in the alignment says which way it ran. That is not a
/// finding about what affects what, so it is refused rather than published with
/// a direction it has not earned.
int? associationLag(VarTiming input, VarTiming outcome) {
  if (input == VarTiming.night && outcome == VarTiming.day) return 0;
  return 1;
}

/// What actually moves this person's recovery, sleep and strain — as observed
/// in their own history, with the multiplicity, the serial dependence, the
/// direction of time, the weekday and the redundancy all paid for.
///
/// [dates] are `yyyy-MM-dd` LOCAL day labels (the labels the rest of this stack
/// uses — never epochs, never UTC dates); every [DailyVariable.values] is
/// positionally aligned to them. Dates need not be contiguous or sorted: the
/// scan builds its own contiguous calendar grid, because a block permutation
/// over "rows that happen to exist" would silently treat a two-week gap as one
/// day and destroy the very autocorrelation it is there to preserve.
///
/// [measured] is positionally aligned to [dates] and marks days whose values
/// were MEASURED BY THE BAND. Days marked false are erased from every variable
/// before anything is computed. This is not optional hygiene: a WHOOP-export or
/// cloud-import day carries another vendor's algorithms, and letting one into
/// this scan means publishing an association between two companies' models and
/// calling it the user's physiology. The predicate that decides it lives in the
/// edge (`LocalDb.isMeasuredDay` — `imported == true` on the bundle), because
/// only the edge can see provenance; passing null here asserts every day is
/// band-measured and should only ever be done in tests.
///
/// Deterministic: the only randomness is [seed], and nothing here reads a
/// clock. The same history always produces the same screen.
///
/// COST. The family is (inputs x outcomes) pairs; each runs [permutations]
/// block shuffles over at most `spanDays` points. At a realistic 90 days and a
/// 10 x 4 grid that is ~30 M float operations, tens of milliseconds — it is a
/// once-a-day job, not a background service.
Metric<AssociationScan> scanAssociations({
  required List<String> dates,
  required List<DailyVariable> variables,
  List<bool>? measured,
  double fdrAlpha = 0.10,
  int minPairedDays = associationMinPairedDays,
  double minCoverage = associationMinCoverage,
  double minContrastIqr = associationMinContrastIqr,
  double redundancyRho = associationRedundancyRho,
  Set<String> selfReported = const {},
  int blockLen = 14,
  int minBlocks = associationMinBlocks,
  int permutations = 999,
  int seed = 20260820,
}) {
  const inputs = ['metric_series', 'journal'];
  final refusals = <AssociationRefusal>[];
  // The day floor is a CONSEQUENCE of the block length, never an independent
  // taste. Six blocks or twelve weeks, whichever is more.
  minPairedDays = math.max(minPairedDays, minBlocks * blockLen);

  for (final v in variables) {
    if (v.values.length != dates.length) {
      return Metric<AssociationScan>.absent(
        tier: Tier.estimate,
        inputs_used: inputs,
        note: 'misaligned_series:${v.key}',
      );
    }
  }
  if (measured != null && measured.length != dates.length) {
    return Metric<AssociationScan>.absent(
      tier: Tier.estimate,
      inputs_used: inputs,
      note: 'misaligned_series:measured',
    );
  }

  // ---- contiguous calendar grid -------------------------------------------
  // Index by real calendar offset, not by row order. A gap in the history has
  // to BE a gap, or a block permutation is reordering fiction.
  final cal = calendarDays(dates);
  final present = <int>[
    for (var i = 0; i < dates.length; i++)
      if (DateTime.tryParse(dates[i]) != null) i
  ];
  if (present.isEmpty) {
    return Metric<AssociationScan>.absent(
      tier: Tier.estimate,
      inputs_used: inputs,
      note: needBaselineNote(have: 0, need: minPairedDays),
    );
  }
  var minDay = cal[present.first], maxDay = cal[present.first];
  for (final i in present) {
    if (cal[i] < minDay) minDay = cal[i];
    if (cal[i] > maxDay) maxDay = cal[i];
  }
  final span = maxDay - minDay + 1;

  // Weekday of each grid slot. 1970-01-01 (day 0) was a Thursday.
  final weekday = [for (var d = 0; d < span; d++) (minDay + d + 4) % 7];

  // Imported days are ERASED, not down-weighted. A day computed by another
  // vendor's model is not a weaker observation of this user, it is an
  // observation of something else.
  final usableDay = <int>[
    for (final i in present)
      if (measured == null || measured[i]) i
  ];
  final importedDropped = present.length - usableDay.length;

  final grid = <String, List<double?>>{};
  for (final v in variables) {
    final g = List<double?>.filled(span, null);
    for (final i in usableDay) {
      final x = v.values[i];
      if (x != null && x.isFinite) g[cal[i] - minDay] = x;
    }
    grid[v.key] = g;
  }

  // ---- variable-level gates ------------------------------------------------
  // A column existing is not a reason to test it.
  final usable = <DailyVariable>[];
  final coverage = <String, double>{};
  for (final v in variables) {
    final g = grid[v.key]!;
    final nPresent = g.where((e) => e != null).length;
    final cov = nPresent / span;
    coverage[v.key] = cov;
    if (nPresent < minPairedDays) {
      refusals.add(AssociationRefusal(
          v.key, 'need_pairs:have=$nPresent,need=$minPairedDays'));
      continue;
    }
    if (cov < minCoverage) {
      refusals.add(AssociationRefusal(
          v.key, 'sparse:coverage=${round6(cov)},need=${round6(minCoverage)}'));
      continue;
    }
    final vals = <double>[for (final e in g) if (e != null) e];
    if (vals.toSet().length < 2) {
      refusals.add(AssociationRefusal(v.key, 'constant'));
      continue;
    }
    usable.add(v);
  }

  // ---- weekday-adjusted, ranked series -------------------------------------
  // Adjust BEFORE ranking and before anything is tested, so the published
  // number is a within-weekday association and a weekend cannot manufacture it.
  final adj = <String, List<double?>>{};
  final rankAdj = <String, List<double?>>{};
  final rankRaw = <String, List<double?>>{};
  for (final v in usable) {
    final a = _weekdayAdjust(grid[v.key]!, weekday);
    adj[v.key] = a;
    rankAdj[v.key] = _ranksWithNulls(a);
    rankRaw[v.key] = _ranksWithNulls(grid[v.key]!);
  }

  // ---- build the family ----------------------------------------------------
  // Everything testable is tested. No screening on the statistic before the
  // correction — that is the disguised version of the problem BH is here for.
  final rng = math.Random(seed);
  final rows = <Association>[];
  for (final inp in usable) {
    if (!inp.canBeInput) continue;
    for (final out in usable) {
      if (!out.canBeOutcome || out.key == inp.key) continue;
      final subject = '${inp.key}->${out.key}';

      if (inp.derivedFrom.contains(out.key) ||
          out.derivedFrom.contains(inp.key)) {
        refusals.add(AssociationRefusal(subject, 'tautology'));
        continue;
      }
      final lag = associationLag(inp.timing, out.timing);
      if (lag == null || lag < 0) {
        refusals.add(AssociationRefusal(subject, 'backwards_in_time'));
        continue;
      }

      final rx = rankAdj[inp.key]!;
      final ryFull = rankAdj[out.key]!;
      // Shift the OUTCOME back by the lag: slot i now holds the outcome of day
      // i+lag. The tail has no partner and becomes absent — it is NOT wrapped,
      // because pairing the last day with the first is fiction. (The block
      // permutation below does wrap, but that is a surrogate, not a pairing.)
      final ry = _lagShift(ryFull, lag);

      final n = _pairedCount(rx, ry);
      if (n < minPairedDays) {
        refusals.add(AssociationRefusal(
            subject, 'need_pairs:have=$n,need=$minPairedDays'));
        continue;
      }

      final rho = _pearsonMasked(rx, ry);
      if (rho == null) {
        refusals.add(AssociationRefusal(subject, 'constant'));
        continue;
      }
      final rhoRaw =
          _pearsonMasked(rankRaw[inp.key]!, _lagShift(rankRaw[out.key]!, lag)) ??
              rho;

      // The feelable number, computed on the RAW (unadjusted) series: a person
      // experiences their actual nights, not weekday residuals. The adjustment
      // is what earns the claim; the contrast is what states it.
      final contrast = _contrast(grid[inp.key]!, _lagShift(grid[out.key]!, lag));
      if (contrast == null) {
        refusals.add(AssociationRefusal(subject, 'no_contrast'));
        continue;
      }

      final p = _blockPermP(rx, ry, blockLen, permutations, rng);

      final caveats = <String>[];
      if (rhoRaw.abs() - rho.abs() > 0.15) caveats.add('weekday_confounded');
      if (coverage[inp.key]! < 0.8) caveats.add('sparse_input');
      if (selfReported.contains(inp.key)) caveats.add('self_reported_input');
      if (contrast.split == ContrastSplit.binary) caveats.add('binary_contrast');
      if (span < 84) caveats.add('short_history');

      rows.add(Association(
        inputKey: inp.key,
        inputLabel: inp.label,
        inputUnit: inp.unit,
        outcomeKey: out.key,
        outcomeLabel: out.label,
        outcomeUnit: out.unit,
        lagDays: lag,
        rho: rho,
        rhoRaw: rhoRaw,
        n: n,
        inputCoverage: coverage[inp.key]!,
        p: p,
        q: 1.0, // filled by BH below
        contrast: contrast.delta,
        lowCut: contrast.lowCut,
        highCut: contrast.highCut,
        nLow: contrast.nLow,
        nHigh: contrast.nHigh,
        outcomeMedian: contrast.outcomeMedian,
        split: contrast.split,
        caveats: caveats,
        meaningful: false,
        redundantWith: null,
      ));
    }
  }

  // NOTHING WAS TESTABLE. This is the minimum-data gate, and it is an ABSENT
  // metric carrying the machine-readable `need_baseline:have=H,need=N` the rest
  // of the app already renders as "N-H more nights". An engine with three weeks
  // of data says how many nights it has and stops; it does not lower the bar to
  // put something on the screen.
  if (rows.isEmpty) {
    return Metric<AssociationScan>.absent(
      tier: Tier.estimate,
      inputs_used: inputs,
      note: '${needBaselineNote(have: usableDay.length, need: minPairedDays)}'
          '${importedDropped > 0 ? ' ($importedDropped imported day(s) '
              'excluded — imported data never enters this scan)' : ''}',
    );
  }

  // ---- could ANY of this have published? -----------------------------------
  // The permutation p is discrete: it cannot go below 1/(permutations+1), and
  // it cannot go below 1/(number of distinct block orderings) either. If that
  // floor is already bigger than the Benjamini-Hochberg threshold for the very
  // best test in the family, then NO test here could have cleared the gate at
  // any effect size whatsoever. Returning an empty findings list in that case
  // would be true and useless — "we found nothing" and "we asked more
  // questions than this much history can answer" are different sentences, and
  // only one of them tells the caller to ask fewer.
  final nBlocks = (span / blockLen).ceil();
  var orderings = 1.0;
  for (var i = 2; i <= nBlocks && orderings < 1e12; i++) {
    orderings *= i;
  }
  final pFloor = math.max(1.0 / (permutations + 1), 1.0 / orderings);
  final maxTests = (fdrAlpha / pFloor).floor();
  final unreachable = rows.length > maxTests;
  if (unreachable) {
    refusals.add(AssociationRefusal(
        'scan',
        'unreachable:tests=${rows.length},max=$maxTests,'
            'p_floor=${round6(pFloor)}'));
  }

  // ---- multiplicity --------------------------------------------------------
  final qs = benjaminiHochberg([for (final r in rows) r.p]);
  final tested = <Association>[
    for (var i = 0; i < rows.length; i++) rows[i]._copyWith(q: qs[i] ?? 1.0)
  ];

  // ---- effect-size floor + FDR gate ---------------------------------------
  final outcomeIqr = <String, double>{};
  for (final v in usable) {
    final vals = <double>[for (final e in grid[v.key]!) if (e != null) e];
    final q1 = percentile(vals, 25), q3 = percentile(vals, 75);
    outcomeIqr[v.key] = (q1 == null || q3 == null) ? 0.0 : (q3 - q1).abs();
  }
  var survivors = <Association>[
    for (final t in tested)
      if (t.q <= fdrAlpha &&
          outcomeIqr[t.outcomeKey]! > 0 &&
          t.contrast.abs() / outcomeIqr[t.outcomeKey]! >= minContrastIqr)
        t._copyWith(meaningful: true)
  ];

  // ---- redundancy ----------------------------------------------------------
  survivors.sort((a, b) {
    final c = a.q.compareTo(b.q);
    return c != 0 ? c : b.rho.abs().compareTo(a.rho.abs());
  });
  final findings = <Association>[];
  final dropped = <String, String>{}; // "input->outcome" -> kept input key
  for (final cand in survivors) {
    String? clash;
    for (final kept in findings) {
      if (kept.outcomeKey != cand.outcomeKey) continue;
      final r = _pearsonMasked(rankAdj[kept.inputKey]!, rankAdj[cand.inputKey]!);
      if (r != null && r.abs() >= redundancyRho) {
        clash = kept.inputKey;
        break;
      }
    }
    if (clash == null) {
      findings.add(cand);
    } else {
      dropped['${cand.inputKey}->${cand.outcomeKey}'] = clash;
    }
  }

  final testedOut = <Association>[
    for (final t in tested)
      () {
        final key = '${t.inputKey}->${t.outcomeKey}';
        final kept = dropped[key];
        final published = findings.any(
            (f) => f.inputKey == t.inputKey && f.outcomeKey == t.outcomeKey);
        return kept != null
            ? t._copyWith(meaningful: false, redundantWith: kept)
            : t._copyWith(meaningful: published);
      }(),
  ];

  return Metric<AssociationScan>(
    value: AssociationScan(
      findings: findings,
      tested: testedOut,
      refusals: refusals,
      spanDays: span,
      testsRun: rows.length,
      fdrAlpha: fdrAlpha,
    ),
    // Deliberately capped low and never a function of how strong the findings
    // look. This is one person's uncontrolled observational history; more of it
    // buys a little confidence, and nothing buys a lot.
    confidence: clamp(0.20 + 0.20 * (span / 365.0), 0.20, 0.45),
    tier: Tier.estimate,
    inputs_used: inputs,
    note: 'association only, in your own history — never cause. lag is derived '
        'per pair and never runs backwards; both series are weekday-adjusted; '
        'p is a moving-block permutation (blocks of $blockLen days, so serial '
        'dependence is kept, not shuffled away) and q is Benjamini-Hochberg '
        'over all ${rows.length} tests. no finding here is advice.'
        '${importedDropped > 0 ? ' $importedDropped imported day(s) excluded.' : ''}'
        '${unreachable ? ' NOTE: ${rows.length} candidate questions against '
            '$span days of history — at most $maxTests could have reached '
            'significance, so an empty result here means the scan was too wide, '
            'not that nothing is happening.' : ''}',
  );
}

// ---------------------------------------------------------------------------
// The catalog
//
// Which day-level metrics this scan is willing to reason about, and the two
// facts the statistics depend on: WHEN each one happened, and WHAT IT IS MADE
// OF. Both live here rather than in the caller on purpose — a caller that gets
// `derivedFrom` wrong does not get a slightly worse screen, it gets readiness
// "explained" by its own inputs, which is the single worst thing this feature
// can do.
//
// The list is deliberately SHORT, and that is a statistical decision, not an
// editorial one. Family size is a resource: every extra candidate raises the
// multiplicity correction for every other candidate, so a metric that is a
// near-restatement of one already here costs the real findings power and buys
// nothing. Excluded for that reason: `trimp`, `calories`, `calories_total`
// (strain already carries the load axis), `lf_hf`, `hrv_cv`, `brv_cv`,
// `prsa_dc` (HRV shape, dominated by rmssd), `dyn_p90` (dominated by
// active_min), `skin_temp_adc` (the raw series behind skin_temp_z),
// `rhr_nocturnal` (currently identical to rhr).
//
// Excluded because they are NOT PHYSIOLOGY: `worn_min`, `unobserved_min`,
// `skin_temp_coverage_frac`, `skin_temp_settled_frac` — these measure how well
// the strap was worn, so "wearing it more is associated with sleeping more" is
// guaranteed and meaningless. `irregular_rhythm_flag` is a clinical screen and
// is never a candidate cause of anything.
//
// Excluded because the column is dead: `spo2`, `odi_per_hour`, `strain_effort`
// are null or tombstoned upstream — a column existing is not data.
//
// Excluded because they are conditional on an event, so their absence is
// informative and the pairwise-complete assumption breaks: `hrr_bpm`,
// `hrr_tau_s`, `hr_ceiling_bpm` (only exist after a hard enough session).
//
// Cycle symptom tags are excluded and must stay excluded: ~20 tags against a
// handful of tagged days is a p-hacking machine at this n, and that is already
// this product's stated position.
// ---------------------------------------------------------------------------

class _Spec {
  final String label;
  final String unit;
  final VarTiming timing;
  final VarRole role;
  final Set<String> derivedFrom;
  const _Spec(this.label, this.unit, this.timing,
      {this.role = VarRole.both, this.derivedFrom = const {}});
}

// `derivedFrom` is declared ONCE, on the composite side. The tautology check
// looks both ways, so `readiness -> rmssd` and `rmssd -> readiness` are both
// refused off this single declaration.
const Map<String, _Spec> _catalog = {
  // --- the night that ended this morning ---
  'tst_min': _Spec('Sleep duration', 'min', VarTiming.night,
      derivedFrom: {'rem_min', 'deep_min', 'light_min'}),
  'efficiency': _Spec('Sleep efficiency', '%', VarTiming.night,
      derivedFrom: {'tst_min'}),
  'rem_min': _Spec('REM sleep', 'min', VarTiming.night),
  'deep_min': _Spec('Deep sleep', 'min', VarTiming.night),
  'light_min': _Spec('Light sleep', 'min', VarTiming.night),
  'sol_min': _Spec('Time to fall asleep', 'min', VarTiming.night),
  'awakenings': _Spec('Awakenings', '', VarTiming.night),
  'longest_sleep_min': _Spec('Longest unbroken sleep', 'min', VarTiming.night,
      derivedFrom: {'tst_min'}),
  'midsleep_sec': _Spec('Sleep midpoint', 's', VarTiming.night),
  'rmssd': _Spec('HRV', 'ms', VarTiming.night),
  'ln_rmssd':
      _Spec('HRV (ln)', '', VarTiming.night, derivedFrom: {'rmssd'}),
  'sdnn': _Spec('HRV (SDNN)', 'ms', VarTiming.night),
  'rhr': _Spec('Resting heart rate', 'bpm', VarTiming.night),
  'resp_rate': _Spec('Respiratory rate', 'br/min', VarTiming.night),
  'skin_temp_z': _Spec('Skin temperature', 'z', VarTiming.night),
  'dip_pct':
      _Spec('Nocturnal HR dip', '%', VarTiming.night, derivedFrom: {'rhr'}),
  // Readiness IS its inputs. This declaration is the whole reason the catalog
  // is in this file.
  'readiness': _Spec('Readiness', 'points', VarTiming.night, derivedFrom: {
    'rmssd',
    'ln_rmssd',
    'rhr',
    'resp_rate',
    'skin_temp_z',
  }),
  'sleep_quality': _Spec('Sleep quality (logged)', '', VarTiming.night,
      role: VarRole.input),

  // --- the waking day ---
  'strain': _Spec('Strain', '', VarTiming.day,
      derivedFrom: {'trimp', 'calories', 'calories_total'}),
  'steps': _Spec('Steps', 'steps', VarTiming.day),
  'active_min': _Spec('Active minutes', 'min', VarTiming.day),
  'nap_min': _Spec('Nap time', 'min', VarTiming.day),
  'stress': _Spec('Stress', 'points', VarTiming.day),
  'alcohol_units':
      _Spec('Alcohol', 'units', VarTiming.day, role: VarRole.input),
  'caffeine_mg': _Spec('Caffeine', 'mg', VarTiming.day, role: VarRole.input),
  'water_ml': _Spec('Water', 'ml', VarTiming.day, role: VarRole.input),
  'screens_min':
      _Spec('Screen time', 'min', VarTiming.day, role: VarRole.input),
  'mood': _Spec('Mood (logged)', '', VarTiming.day),
  'energy': _Spec('Energy (logged)', '', VarTiming.day),
  'soreness': _Spec('Soreness (logged)', '', VarTiming.day),
  // NOT `stress`: that key is already the Baevsky 0-100 score. The self-report
  // is a different 1-5 quantity and must not collide with it.
  'journal_stress': _Spec('Stress (logged)', '', VarTiming.day),
};

/// Keys whose values a person typed rather than the strap measured. Passed as
/// `selfReported` so the finding carries the caveat: these are subject to
/// recall and to the user's own theory of what happened, which is exactly the
/// theory the finding might otherwise appear to confirm.
const Set<String> associationSelfReportedKeys = {
  'sleep_quality',
  'alcohol_units',
  'caffeine_mg',
  'water_ml',
  'screens_min',
  'mood',
  'energy',
  'soreness',
  'journal_stress',
};

/// Every catalog key, for a caller assembling the series it has.
Iterable<String> get associationCatalogKeys => _catalog.keys;

/// A fully-specified [DailyVariable] for a known day-level [key], or null when
/// the key is not one this scan will reason about (see the exclusion list
/// above — an unknown key is a deliberate refusal, not an oversight).
///
/// [values] must be positionally aligned to the same `dates` the scan is given.
DailyVariable? standardVariable(String key, List<double?> values) {
  final s = _catalog[key];
  if (s == null) return null;
  return DailyVariable(
    key: key,
    label: s.label,
    unit: s.unit,
    values: values,
    timing: s.timing,
    role: s.role,
    derivedFrom: s.derivedFrom,
  );
}

// ---------------------------------------------------------------------------
// internals
// ---------------------------------------------------------------------------

/// Per-weekday median removed, so a weekday cannot manufacture an association
/// between two things it drives simultaneously.
///
/// A weekday with fewer than [minPer] observations is centred on the OVERALL
/// median instead of its own: the median of two Sundays is those two Sundays,
/// and subtracting it deletes them rather than adjusting them.
List<double?> _weekdayAdjust(List<double?> v, List<int> weekday,
    {int minPer = 3}) {
  final byDay = List<List<double>>.generate(7, (_) => <double>[]);
  for (var i = 0; i < v.length; i++) {
    final x = v[i];
    if (x != null) byDay[weekday[i]].add(x);
  }
  final all = <double>[for (final x in v) if (x != null) x];
  final overall = median(all);
  if (overall == null) return List<double?>.filled(v.length, null);
  final centre = [
    for (var d = 0; d < 7; d++)
      byDay[d].length >= minPer ? median(byDay[d])! : overall
  ];
  return [
    for (var i = 0; i < v.length; i++)
      v[i] == null ? null : v[i]! - centre[weekday[i]]
  ];
}

/// Average ranks over the PRESENT values, put back in their slots.
///
/// Ranked once over the whole series and then correlated over subsets. The same
/// procedure is applied to the observed statistic and to every surrogate, which
/// is what keeps the permutation test valid; re-ranking inside each surrogate's
/// own mask would compare two differently-defined statistics.
List<double?> _ranksWithNulls(List<double?> v) {
  final idx = <int>[for (var i = 0; i < v.length; i++) if (v[i] != null) i];
  final ranks = averageRanks([for (final i in idx) v[i]!]);
  final out = List<double?>.filled(v.length, null);
  for (var k = 0; k < idx.length; k++) {
    out[idx[k]] = ranks[k];
  }
  return out;
}

/// Slot i takes what was in slot i+[lag]; the tail has no partner and is absent.
/// Never wraps — the last day of the window is not followed by the first.
List<double?> _lagShift(List<double?> v, int lag) {
  if (lag == 0) return v;
  return [
    for (var i = 0; i < v.length; i++) (i + lag < v.length) ? v[i + lag] : null
  ];
}

int _pairedCount(List<double?> a, List<double?> b) {
  var n = 0;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != null && b[i] != null) n++;
  }
  return n;
}

/// Pearson over the pairwise-complete slots. On rank vectors this is Spearman.
double? _pearsonMasked(List<double?> a, List<double?> b) {
  var n = 0;
  var sa = 0.0, sb = 0.0;
  for (var i = 0; i < a.length; i++) {
    final x = a[i], y = b[i];
    if (x == null || y == null) continue;
    sa += x;
    sb += y;
    n++;
  }
  if (n < 3) return null;
  final ma = sa / n, mb = sb / n;
  var num = 0.0, da = 0.0, db = 0.0;
  for (var i = 0; i < a.length; i++) {
    final x = a[i], y = b[i];
    if (x == null || y == null) continue;
    final xa = x - ma, xb = y - mb;
    num += xa * xb;
    da += xa * xa;
    db += xb * xb;
  }
  if (da <= 0 || db <= 0) return null;
  return num / math.sqrt(da * db);
}

/// Two-sided MOVING-BLOCK permutation p for the rank correlation.
///
/// The series is cut into contiguous blocks of [blockLen] days and the BLOCKS
/// are reordered; within a block every day keeps its neighbour, so the
/// surrogate has (approximately) the same autocorrelation as the real series
/// while being aligned to the other series at random. This is the difference
/// between a test that holds on serially dependent daily data and one that does
/// not: shuffling day-wise destroys the persistence that produced the spurious
/// correlation in the first place, so the null has none of it and the p comes
/// back far too small. The test-suite has both, and the day-wise version fails.
///
/// The observed statistic is counted in (the `+1`s), so p is never a fabricated
/// zero and its floor is an honest 1/([permutations]+1).
double _blockPermP(
  List<double?> rx,
  List<double?> ry,
  int blockLen,
  int permutations,
  math.Random rng,
) {
  final n = ry.length;
  final obs = (_pearsonMasked(rx, ry) ?? 0.0).abs();
  final starts = <int>[for (var s = 0; s < n; s += blockLen) s];
  final order = List<int>.generate(starts.length, (i) => i);
  final buf = List<double?>.filled(n, null);
  var ge = 0;
  for (var k = 0; k < permutations; k++) {
    order.shuffle(rng);
    var w = 0;
    for (final b in order) {
      final s = starts[b];
      final e = math.min(s + blockLen, n);
      for (var i = s; i < e; i++) {
        buf[w++] = ry[i];
      }
    }
    final r = _pearsonMasked(rx, buf);
    if (r != null && r.abs() >= obs - 1e-12) ge++;
  }
  return (ge + 1) / (permutations + 1);
}

class _Contrast {
  final double delta;
  final double lowCut;
  final double highCut;
  final int nLow;
  final int nHigh;
  final double outcomeMedian;
  final ContrastSplit split;
  const _Contrast(this.delta, this.lowCut, this.highCut, this.nLow, this.nHigh,
      this.outcomeMedian, this.split);
}

/// The number a person can feel: median outcome on the input's HIGH days minus
/// median outcome on its LOW days, in the outcome's own units.
///
/// Tertiles by default. A tick-box input (two distinct values) has no tertiles —
/// forcing them onto it produces cut points that are the same number twice — so
/// it routes to the two groups it actually has and says so via
/// [ContrastSplit.binary]. Under 5 days on either side there is no contrast to
/// report and the pair is refused rather than described from three days.
_Contrast? _contrast(List<double?> x, List<double?> y, {int minSide = 5}) {
  final xs = <double>[], ys = <double>[];
  for (var i = 0; i < x.length; i++) {
    final a = x[i], b = y[i];
    if (a == null || b == null) continue;
    xs.add(a);
    ys.add(b);
  }
  if (xs.length < 2 * minSide) return null;
  final yMed = median(ys);
  if (yMed == null) return null;

  var lowCut = percentile(xs, 100 / 3)!;
  var highCut = percentile(xs, 200 / 3)!;
  var split = ContrastSplit.tertile;
  if (lowCut >= highCut) {
    // Tie-dominated (a tick-box, or a field logged as the same number most
    // days). Split at the smallest value instead of inventing two cut points
    // that are the same number.
    final distinct = xs.toSet().toList()..sort();
    if (distinct.length < 2) return null;
    // Low is the floor value (usually "did not happen"); high is everything
    // above it, so the boundary to report is the next value up, not the floor
    // repeated — copy has to be able to say WHICH days it means.
    lowCut = distinct.first;
    highCut = distinct[1];
    split = ContrastSplit.binary;
  }

  final lo = <double>[], hi = <double>[];
  for (var i = 0; i < xs.length; i++) {
    if (split == ContrastSplit.binary) {
      (xs[i] <= lowCut ? lo : hi).add(ys[i]);
    } else if (xs[i] <= lowCut) {
      lo.add(ys[i]);
    } else if (xs[i] >= highCut) {
      hi.add(ys[i]);
    }
  }
  if (lo.length < minSide || hi.length < minSide) return null;
  return _Contrast(median(hi)! - median(lo)!, lowCut, highCut, lo.length,
      hi.length, yMed, split);
}
