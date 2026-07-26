import 'dart:math' as math;

import '../types.dart';
import '../sleep/advanced_stager.dart';

/// An index range [start, end) into the day's accel/hr arrays marking the MAIN
/// nocturnal sleep, so [detectNaps] can carve it (and its session) out.
class SleepWindowSpan {
  final int start;
  final int end;
  const SleepWindowSpan(this.start, this.end);
}

class NapWindow {
  final int startSec;
  final int endSec;
  final int durationSec;
  final double confidence;
  const NapWindow({
    required this.startSec,
    required this.endSec,
    required this.durationSec,
    required this.confidence,
  });
}

/// Daytime naps as qualifying NON-MAIN sleep sessions from the single-source
/// [AdvancedSleepStager.detectSleep] pipeline. Reuses the exact same van Hees +
/// HR autonomic machinery the main sleep uses (no second detector): every
/// detected sleep session in [20 min, 3 h] that does NOT overlap [mainSleep] is
/// reported as a nap. HONEST: the same ESTIMATE ceiling as staging (wrist
/// autonomic, never PSG); returns an EMPTY list (present, low confidence) when
/// the detector finds no qualifying nap, and [Metric.absent] only when there is
/// too little data to run at all.
///
/// [accel]/[hr] 1 Hz gravity + HR for the whole day (same length/time base).
/// [mainSleep] index range of the main nocturnal sleep in those arrays, so it
/// (and any session overlapping it) is excluded. NapWindow start/end are seconds
/// RELATIVE to the first sample.
Metric<List<NapWindow>> detectNaps(
  List<AccelSample> accel,
  List<double> hr, {
  SleepWindowSpan? mainSleep,
}) {
  const inputs = ['accel_1hz', 'hr_1hz'];
  const minNapSec = 20 * 60;
  const maxNapSec = 3 * 3600;
  final n = math.min(accel.length, hr.length);
  if (n < minNapSec) {
    return const Metric<List<NapWindow>>.absent(
      tier: Tier.estimate,
      inputs_used: inputs,
      note: 'too little data for nap detection (need ≥20 min)',
    );
  }

  final baseSec = accel.first.tsMs ~/ 1000;
  final grav = <GravTs>[
    for (var i = 0; i < n; i++)
      GravTs(accel[i].tsMs ~/ 1000, accel[i].x, accel[i].y, accel[i].z),
  ];
  final hrTs = <HrTs>[
    for (var i = 0; i < n; i++)
      if (hr[i] > 0) HrTs(accel[i].tsMs ~/ 1000, hr[i]),
  ];

  // Per-timestamp local offset (DST-correct) for the stager's daytime guard.
  int tzAt(int ts) =>
      DateTime.fromMillisecondsSinceEpoch(ts * 1000, isUtc: false)
          .timeZoneOffset
          .inSeconds;

  final sessions =
      AdvancedSleepStager.detectSleep(grav, hrTs, tzOffsetResolver: tzAt);

  // Absolute-second bounds of the main sleep window (for overlap exclusion).
  int? mainStartSec, mainEndSec;
  if (mainSleep != null && mainSleep.end > mainSleep.start) {
    final lo = mainSleep.start.clamp(0, n - 1);
    final hi = (mainSleep.end - 1).clamp(0, n - 1);
    mainStartSec = accel[lo].tsMs ~/ 1000;
    mainEndSec = accel[hi].tsMs ~/ 1000;
  }

  final naps = <NapWindow>[];
  for (final s in sessions) {
    final dur = s.end - s.start;
    if (dur < minNapSec || dur > maxNapSec) continue;
    // Exclude the main nocturnal sleep: any session overlapping its window.
    if (mainStartSec != null &&
        mainEndSec != null &&
        s.start < mainEndSec &&
        s.end > mainStartSec) {
      continue;
    }
    // Require the nap actually hold ≥20 min of asleep time (not just in-bed).
    if (AdvancedSleepStager.hypnogramMetrics(s).tstS < minNapSec) continue;
    naps.add(NapWindow(
      startSec: s.start - baseSec,
      endSec: s.end - baseSec,
      durationSec: dur,
      confidence: s.efficiency.clamp(0.0, 1.0),
    ));
  }

  return Metric<List<NapWindow>>(
    value: naps,
    confidence: naps.isEmpty ? 0.3 : 0.4,
    tier: Tier.estimate,
    inputs_used: inputs,
    note: naps.isEmpty
        ? 'no qualifying naps (20 min–3 h) outside the main sleep window'
        : '${naps.length} nap(s) via van Hees + HR autonomic ESTIMATE '
            '(20 min–3 h, main sleep excluded); wrist estimate, not PSG',
  );
}

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

Metric<BedtimeRec> recommendedBedtime({
  required double needSec,
  required double typicalWakeMinOfDay,
  required double typicalEfficiencyPct,
}) {
  final eff = (typicalEfficiencyPct / 100.0).clamp(0.75, 0.99);
  final inBedSec = needSec / eff;
  final bedMin = (typicalWakeMinOfDay - inBedSec / 60.0) % 1440.0;
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

Metric<WakeRec> recommendedWake({
  required double bedtimeMinOfDay,
  required double needSec,
}) {
  final sleepMin = needSec / 60.0;
  final cycles = math.max(1, (sleepMin / 90.0).round());
  final wake = (bedtimeMinOfDay + cycles * 90.0) % 1440.0;
  return Metric<WakeRec>(
    value: WakeRec(wake),
    confidence: 0.55,
    tier: Tier.estimate,
    inputs_used: const ['sleep_need', 'bedtime'],
    note: '90-minute cycle-aligned wake estimate',
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
  double lo;
  double hi;
  String band;
  if (rec < 40) {
    lo = 4;
    hi = 8;
    band = 'recover';
  } else if (rec < 60) {
    lo = 7;
    hi = 11;
    band = 'ease';
  } else if (rec < 80) {
    lo = 10;
    hi = 15;
    band = 'maintain';
  } else {
    lo = 14;
    hi = 18;
    band = 'push';
  }
  final fatigue = (atl != null && ctl != null) ? (atl - ctl) : null;
  if (fatigue != null && fatigue > 10) {
    lo -= 1;
    hi -= 2;
  } else if (tsb != null && tsb > 5) {
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

Metric<double> vo2maxEstimate({
  required double? restingHr,
  required double? maxHr,
  required Sex sex,
  required double? age,
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
      note: 'VO2max needs a positive resting HR below HRmax — "—" (never imputed)',
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
  required Sex sex,
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
