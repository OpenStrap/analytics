// CLINICAL TIER-1 — training load: TRIMP + CTL/ATL/TSB.
//
// Edwards 1993 zone-sum TRIMP and Banister exponential TRIMP (Morton 1990).
// CTL (Chronic Training Load, 42-day EWMA of daily TRIMP), ATL (Acute, 7-day
// EWMA), TSB = CTL − ATL (Training Stress Balance / "form").
//
// Banister: TRIMP = Σ Δt(min) · ΔHRr · y, where ΔHRr = (HR−RHR)/(HRmax−RHR)
// and y = e^(b·ΔHRr), b = 1.92 (male) / 1.67 (female). Needs measured HRmax+RHR.
//
// HONESTY: ESTIMATE tier (wrist HR, no power/VO2). Non-wear gaps must be guarded
// — pass only valid on-skin minutes. CTL/ATL are descriptive load, not injury
// prediction.

import 'dart:math' as math;
import '../types.dart';
import '../util.dart';

/// Banister TRIMP over a series of per-minute mean HRs.
///
/// TRIMP = Σ Δt(min) · ΔHRr · y(ΔHRr) with the PUBLISHED sex-specific weighting
/// factor (Banister 1991; Morton 1990):
///   men   y = 0.64 · e^(1.92·x)
///   women y = 0.86 · e^(1.67·x)
/// Delegates to [StrainScorer.banisterY] so this file has exactly ONE Banister
/// implementation (it previously dropped the 0.64/0.86 coefficient entirely,
/// disagreeing with [StrainScorer.banisterTRIMP] by a factor of 1.5625).
///
/// [hrPerMin] mean HR for each worn minute (bpm; pass only valid minutes).
/// [restingHr], [maxHr] the personal anchors. [sex] selects the coefficients.
/// Returns absent if anchors are missing/degenerate (no fabrication).
Metric<double> banisterTrimp(
  List<double> hrPerMin, {
  required double? restingHr,
  required double? maxHr,
  required Sex sex,
}) {
  const inputs = ['hr_per_min', 'resting_hr', 'max_hr'];
  if (restingHr == null ||
      maxHr == null ||
      maxHr <= restingHr ||
      hrPerMin.isEmpty) {
    return const Metric<double>.absent(
      tier: Tier.estimate,
      inputs_used: inputs,
      note: 'Banister TRIMP needs measured RHR and HRmax (HRmax>RHR)',
    );
  }
  final reserve = maxHr - restingHr;
  var trimp = 0.0;
  for (final hr in hrPerMin) {
    if (hr <= 0) continue; // off-skin guard
    var hrr = (hr - restingHr) / reserve;
    if (hrr < 0) hrr = 0;
    if (hrr > 1) hrr = 1;
    // ONE Banister implementation for the whole package: the sex-specific
    // weighting factor y lives in [StrainScorer.banisterY]. 1 minute each.
    trimp += 1.0 * hrr * StrainScorer.banisterY(hrr, female: sex == Sex.female);
  }
  return Metric<double>(
    value: trimp,
    confidence: 0.6,
    tier: Tier.estimate,
    inputs_used: inputs,
    note: 'Banister exponential TRIMP (wrist HR estimate)',
  );
}

/// Fraction of heart-rate reserve that simply BEING AWAKE costs.
///
/// Whole-day Banister TRIMP counts every waking minute above resting, so ~16 h
/// of ordinary living accrues ~180 TRIMP before any exercise happens. That is
/// the cost of being alive, not training load, and billing it as load is what
/// put an INACTIVE full-wear day at ~13/21 on the old scale. Quiet waking
/// (sitting, standing, moving about the house) sits ≈20 % of HRR above resting,
/// so that much is treated as the day's overhead rather than as effort.
const double quietWakingHrr = 0.20;

/// Net TRIMP — earned ABOVE the quiet-waking baseline — that defines a maximal
/// day and maps to the top of the scale.
///
/// The old map put 21 at a raw TRIMP of ~4987, i.e. ≈35 h at 80 % HRR: the top
/// third of the scale was unreachable by any human day, so the headline number
/// never used the range it advertised.
const double maximalNetTrimp = 400.0;

/// Curvature of the 0–21 map; higher gives more resolution at the low end.
///
/// Calibrated together with [maximalNetTrimp] so that, for a representative
/// profile (RHR 60, HRmax 187, 16 h awake), a day scores:
///   inactive → ~0 · rest + a walk → 2–4 · 45 min moderate run → 8–11 ·
///   90 min hard session → 14–17 · 5 h at 160 bpm → 21.
const double strainCurvature = 15.0;

/// The TRIMP that [wakeMinutes] of ordinary waking accrues on its own.
///
/// Scales with the wake window ACTUALLY observed, so a partial-wear day is not
/// charged a full day's overhead (a 2 h inactive wear window would otherwise
/// come out negative and clamp, while a 16 h one read as real effort).
double baselineTrimp(double wakeMinutes, {bool female = false}) =>
    wakeMinutes *
    quietWakingHrr *
    StrainScorer.banisterY(quietWakingHrr, female: female);

/// Log-map the TRIMP EARNED ABOVE baseline into a 0–21 headline "strain" score.
///
///     net    = trimp − baselineTrimp(wakeMinutes)
///     u      = min(1, net / maximalNetTrimp)
///     strain = 21 · ln(1 + u·(C−1)) / ln(C),  C = [strainCurvature]
///
/// [wakeMinutes] is the observed waking wear window that produced [trimp] — it
/// sets the baseline, so it is required rather than assumed.
double strainScore(
  double trimp, {
  required double wakeMinutes,
  bool female = false,
}) {
  final net = trimp - baselineTrimp(wakeMinutes, female: female);
  if (net <= 0) return 0.0;
  final u = math.min(1.0, net / maximalNetTrimp);
  final s =
      21.0 * math.log(1 + u * (strainCurvature - 1)) / math.log(strainCurvature);
  return math.min(21.0, math.max(0.0, s));
}

/// Headline 0–21 strain as a Metric, alongside the raw TRIMP (EST tier).
///
/// [trimp] the raw Banister TRIMP for the day/session, [wakeMinutes] the wake
/// window it was accumulated over. Absent when either is missing: the baseline
/// subtraction is meaningless without a wake window, and guessing one silently
/// mis-scores every partial-wear day.
Metric<double> strainScoreMetric(
  double? trimp, {
  required double? wakeMinutes,
  bool female = false,
}) {
  const inputs = ['trimp', 'wake_minutes'];
  if (trimp == null || trimp < 0 || wakeMinutes == null || wakeMinutes <= 0) {
    return const Metric<double>.absent(
      tier: Tier.estimate,
      inputs_used: inputs,
      note: 'strain needs a TRIMP and the wake window it was measured over',
    );
  }
  return Metric<double>(
    value: strainScore(trimp, wakeMinutes: wakeMinutes, female: female),
    confidence: 0.6,
    tier: Tier.estimate,
    inputs_used: inputs,
    note: 'headline 0–21 strain = log map of TRIMP earned above the '
        'quiet-waking baseline; wrist-HR estimate',
  );
}

/// Edwards zone-sum TRIMP. [zoneMinutes] minutes in each of the 5 HR zones
/// (50–60/60–70/70–80/80–90/90–100 %HRmax); weights 1..5.
Metric<double> edwardsTrimp(List<double> zoneMinutes) {
  const inputs = ['zone_minutes'];
  if (zoneMinutes.length != 5) {
    return const Metric<double>.absent(
      tier: Tier.estimate,
      inputs_used: inputs,
      note: 'Edwards TRIMP needs 5 zone minutes',
    );
  }
  var t = 0.0;
  for (var i = 0; i < 5; i++) {
    t += zoneMinutes[i] * (i + 1);
  }
  return Metric<double>(
    value: t,
    confidence: 0.6,
    tier: Tier.estimate,
    inputs_used: inputs,
    note: 'Edwards zone-sum TRIMP',
  );
}

// ════════════════════════════════════════════════════════════════════════════
// StrainScorer — Edwards/Banister TRIMP → 0–100 strain ("Effort").
// Implementation of published exercise-physiology methods.
//
//   1. Heart-Rate Reserve (Karvonen): HRR = HRmax − RHR.
//   2. Per-sample intensity %HRR = (HR − RHR) / HRR × 100, clamped 0..100.
//   3. TRIMP over the window (each sample carries its OWN duration, measured
//      from the real timestamps and capped at the stream's median cadence so a
//      gap is never counted as effort):
//        a. Edwards 5-zone (default): sample contributes its zone weight (1..5 at
//           50/60/70/80/90 %HRR cut-offs) × that sample's duration (min).
//        b. Banister exponential: sample contributes dur × x × y(x), with
//           y = 0.64·e^(1.92x) (men) / 0.86·e^(1.67x) (women).
//   4. strain = 100 × ln(TRIMP + 1) / ln(D), D = 7201 (TRIMP 7200 ≈ max).
//
// References: Karvonen 1957; Edwards 1993; Banister 1991 (y = 0.64·e^(1.92x)
// men / 0.86·e^(1.67x) women); Tanaka 2001 (HRmax = 208 − 0.7·age).
//
// NOTE (steps/active-energy floor): strain is PURELY HR-derived
// (Edwards/Banister TRIMP → log map). Steps and active calories are computed as
// SEPARATE, independent daily metrics and are NEVER fused into, nor floor, the
// strain score.
// ════════════════════════════════════════════════════════════════════════════

/// StrainScorer constants + the strain pipeline.
class StrainScorer {
  /// Minimum HR readings before computing strain on a DENSE stream (≈10 min @1Hz).
  static const int minReadings = 600;

  /// Sparse-stream acceptance (#482): a low-cadence strap also qualifies once the
  /// HR series SPANS at least [minSpanSeconds] with a small sample floor.
  static const int minSparseReadings = 20;

  /// Wall-clock coverage (s) that qualifies a sparse stream (10 min).
  static const int minSpanSeconds = 600;

  /// Top of the strain ("Effort") scale (rescaled 21.0 → 100.0).
  static const double maxStrain = 100.0;

  /// Logarithmic-map denominator D = 7200 + 1: Edwards daily ceiling
  /// (top weight 5 sustained 24h = 7200) maps to exactly maxStrain.
  static const double strainDenominator = 7201.0;

  /// Fallback per-sample duration (minutes) — 1 s at 1 Hz.
  static const double fallbackSampleMin = 1.0 / 60.0;

  static const int defaultAge = 30;
  static const double defaultRestingHR = 60;

  /// Minimum HR samples before the observed high-percentile HRmax is trusted.
  static const int hrmaxMinSamples = 600;

  /// Upper percentile for the observed-HRmax estimate.
  static const double hrmaxPercentile = 99.5;

  /// Banister 1991 weighting factor y = c · e^(b·x), x = fractional %HRR.
  /// PUBLISHED coefficients are sex-specific in BOTH terms:
  ///   men   c = 0.64, b = 1.92
  ///   women c = 0.86, b = 1.67
  /// (Applying the male c = 0.64 to women — as this class used to — understates
  /// female TRIMP by ~26 %.)
  static const double banisterScaleMen = 0.64;
  static const double banisterScaleWomen = 0.86;
  static const double banisterBMen = 1.92;
  static const double banisterBWomen = 1.67;

  /// Deprecated alias for [banisterScaleMen]; kept so existing call sites keep
  /// resolving. Prefer [banisterY], which pairs c and b correctly by sex.
  static const double banisterScale = banisterScaleMen;

  /// The sex-specific Banister weighting factor y(x) — the single source of
  /// truth for Banister weighting in this package.
  static double banisterY(double x, {required bool female}) =>
      (female ? banisterScaleWomen : banisterScaleMen) *
      math.exp((female ? banisterBWomen : banisterBMen) * x);

  /// Edwards zone cut-offs as (%HRR threshold, weight), highest-first.
  static const List<List<num>> edwardsZones = [
    [90.0, 5],
    [80.0, 4],
    [70.0, 3],
    [60.0, 2],
    [50.0, 1],
  ];

  // ── HRmax helpers ───────────────────────────────────────────────────────────

  /// Tanaka (2001): HRmax = 208 − 0.7 × age.
  static double tanakaHRmax(double age) => 208.0 - 0.7 * age;

  /// Classic 220 − age. Last-resort fallback only.
  static int defaultMaxHR([int age = defaultAge]) => 220 - age;

  /// Linear-interpolated percentile of an ALREADY-SORTED sequence (numpy-style).
  static double _percentileSorted(List<double> sortedValues, double pct) {
    final n = sortedValues.length;
    if (n == 0) return 0;
    if (n == 1) return sortedValues[0];
    final position = (pct / 100.0) * (n - 1);
    final lower = position.toInt();
    final upper = math.min(lower + 1, n - 1);
    final frac = position - lower;
    return sortedValues[lower] + frac * (sortedValues[upper] - sortedValues[lower]);
  }

  /// Estimate a personalized HRmax from a trailing HR series.
  /// Returns (hrmax bpm, source ∈ {"observed","tanaka","unknown"}).
  static (double, String) estimateHRmax(List<double> hrHistory, double? age) {
    final n = hrHistory.length;
    final tanaka = age == null ? null : tanakaHRmax(age);

    if (n >= hrmaxMinSamples) {
      final sorted = [...hrHistory]..sort();
      final observed = _percentileSorted(sorted, hrmaxPercentile);
      if (tanaka == null) return (observed, 'observed');
      return observed >= tanaka ? (observed, 'observed') : (tanaka, 'tanaka');
    }
    if (tanaka != null) return (tanaka, 'tanaka');
    return (0.0, 'unknown');
  }

  // ── Karvonen %HRR and Edwards zone weight ──────────────────────────────────

  /// Karvonen %HRR, clamped [0, 100].
  static double pctHRR(double bpm, double restingHR, double hrReserve) {
    final pct = (bpm - restingHR) / hrReserve * 100.0;
    if (pct < 0) return 0;
    if (pct > 100) return 100;
    return pct;
  }

  /// Edwards 5-zone weight (0–5) from %HRR (unclamped).
  static int zoneWeight(double bpm, double restingHR, double hrReserve) {
    final pct = (bpm - restingHR) / hrReserve * 100.0;
    for (final z in edwardsZones) {
      if (pct >= z[0]) return z[1].toInt();
    }
    return 0;
  }

  // ── TRIMP accumulation ──────────────────────────────────────────────────────

  /// Median inter-sample interval (seconds) of a time-ordered stream, ignoring
  /// non-positive steps and pathological (>[maxPlausibleGapSec]) ones. Floored
  /// at [fallbackSampleMin] minutes' worth. Mirrors the convention already used
  /// by `HeartRateZones.timeInZone`.
  static double medianIntervalSeconds(List<double> tsSec,
      {double maxPlausibleGapSec = 300.0}) {
    final gaps = <double>[];
    for (var i = 1; i < tsSec.length; i++) {
      final g = tsSec[i] - tsSec[i - 1];
      if (g > 0 && g <= maxPlausibleGapSec) gaps.add(g);
    }
    if (gaps.isEmpty) return fallbackSampleMin * 60.0;
    gaps.sort();
    return math.max(gaps[gaps.length ~/ 2], fallbackSampleMin * 60.0);
  }

  /// PER-SAMPLE effort durations (minutes) from the ACTUAL timestamps.
  ///
  /// Sample i is credited with the interval to sample i+1; the tail sample gets
  /// the stream's median cadence. Every interval is CAPPED at that median, so a
  /// hole in the stream can never be counted as sustained effort (the same gap
  /// policy as `HeartRateZones.timeInZone`).
  ///
  /// This replaces the old `sampleDurationMinutes`, which read ONE interval
  /// (the first two timestamps) and applied it to every sample — catastrophic
  /// on exactly the sparse/irregular streams [minSparseReadings] admits: 21
  /// samples over 20 min with the first two 1 s apart scored strain 8.08
  /// instead of ~47, and a 1 Hz stream with a 5-min leading gap scored 104.
  static List<double> sampleDurationsMinutes(List<double> tsSec) {
    final n = tsSec.length;
    if (n == 0) return const [];
    if (n == 1) return [fallbackSampleMin];
    final capSec = medianIntervalSeconds(tsSec);
    final out = List<double>.filled(n, capSec / 60.0);
    for (var i = 0; i < n - 1; i++) {
      final g = tsSec[i + 1] - tsSec[i];
      out[i] = (g > 0 ? math.min(g, capSec) : capSec) / 60.0;
    }
    return out;
  }

  /// Edwards 5-zone TRIMP: Σ zoneWeight(sample) × that sample's duration (min).
  static double edwardsTRIMP(List<double> bpm, double restingHR,
      double hrReserve, List<double> durationsMin) {
    var acc = 0.0;
    for (var i = 0; i < bpm.length; i++) {
      final dur = i < durationsMin.length
          ? durationsMin[i]
          : (durationsMin.isEmpty ? fallbackSampleMin : durationsMin.last);
      acc += zoneWeight(bpm[i], restingHR, hrReserve) * dur;
    }
    return acc;
  }

  /// Banister exponential TRIMP: Σ duration(min) × x × y(x), y per [banisterY].
  static double banisterTRIMP(List<double> bpm, double restingHR,
      double hrReserve, List<double> durationsMin, {bool female = false}) {
    var acc = 0.0;
    for (var i = 0; i < bpm.length; i++) {
      final dur = i < durationsMin.length
          ? durationsMin[i]
          : (durationsMin.isEmpty ? fallbackSampleMin : durationsMin.last);
      final x = pctHRR(bpm[i], restingHR, hrReserve) / 100.0;
      if (x > 0) acc += dur * x * banisterY(x, female: female);
    }
    return acc;
  }

  // ── Logarithmic map ─────────────────────────────────────────────────────────

  /// Map accumulated TRIMP onto [0, 100] via 100 × ln(TRIMP+1) / ln(D), 2 dp.
  /// TRIMP ≤ 0 → 0; above the D−1 ceiling the score is CLAMPED at [maxStrain]
  /// (it used to run off the top of its own documented range: TRIMP 14400 →
  /// 107.8, while the sibling [strainScore] clamped correctly).
  static double trimpToStrain(double trimp, {double denominator = strainDenominator}) {
    if (trimp <= 0) return 0;
    final value = maxStrain * math.log(trimp + 1.0) / math.log(denominator);
    final clamped = math.min(maxStrain, math.max(0.0, value));
    return (clamped * 100).roundToDouble() / 100;
  }

  // ── TRIMP method ──────────────────────────────────────────────────────────────

  /// Compute strain (0–100) from a time-ordered HR series. APPROXIMATE.
  ///
  /// [bpm] per-sample HR; [tsSec] their timestamps in SECONDS (same length).
  /// Returns null when there isn't enough data to trust the number (fewer than
  /// [minReadings] AND less than [minSpanSeconds] coverage), or when maxHR ≤
  /// restingHR (invalid HRR). [edwards] true → Edwards (default); false → Banister.
  static double? strain(
    List<double> bpm,
    List<double> tsSec, {
    double? maxHR,
    double restingHR = defaultRestingHR,
    bool edwards = true,
    bool female = false,
    double denominator = strainDenominator,
  }) {
    final effMax = maxHR ?? defaultMaxHR().toDouble();
    final bool enoughData;
    if (bpm.length >= minReadings) {
      enoughData = true;
    } else if (bpm.length >= minSparseReadings) {
      if (tsSec.isEmpty) {
        enoughData = false;
      } else {
        var mn = tsSec[0], mx = tsSec[0];
        for (final t in tsSec) {
          if (t < mn) mn = t;
          if (t > mx) mx = t;
        }
        enoughData = (mx - mn) >= minSpanSeconds;
      }
    } else {
      enoughData = false;
    }
    if (!enoughData || effMax <= restingHR) return null;

    final durations = sampleDurationsMinutes(tsSec);
    final hrReserve = effMax - restingHR;

    final double trimp;
    if (edwards) {
      trimp = edwardsTRIMP(bpm, restingHR, hrReserve, durations);
    } else {
      trimp = banisterTRIMP(bpm, restingHR, hrReserve, durations,
          female: female);
    }
    return trimpToStrain(trimp, denominator: denominator);
  }
}

/// Edwards/Banister TRIMP strain ("Effort", 0–100) as a Metric, with the
/// honesty envelope: absent when the gates fail (never fabricated).
///
/// [bpm] per-sample HR (bpm). [tsSec] timestamps (s), same length. [maxHr] /
/// [restingHr] the personal anchors (HRmax resolved by the caller via
/// [StrainScorer.estimateHRmax] / Tanaka). [method] 'edwards' (default) or
/// 'banister'. [sex] selects the Banister coefficient.
Metric<double> trimpStrain(
  List<double> bpm,
  List<double> tsSec, {
  double? maxHr,
  double? restingHr,
  String method = 'edwards',
  Sex sex = Sex.male,
}) {
  const inputs = ['hr_series', 'resting_hr', 'max_hr'];
  // used to fall back to StrainScorer.defaultRestingHR/defaultMaxHR when
  // these were omitted, which fed a made-up anchor into a confident-looking
  // ESTIMATE score with nothing telling anyone it wasn't a real anchor. those
  // defaults are for AutoWorkoutDetector's internal gate, not for this public
  // honesty-wrapped function - if we don't actually have the person's real
  // anchors, we don't have a real number either.
  if (maxHr == null || restingHr == null) {
    return const Metric<double>.absent(
      tier: Tier.estimate,
      inputs_used: inputs,
      note: 'needs a real maxHr and restingHr, not fabricated defaults',
    );
  }
  final s = StrainScorer.strain(
    bpm,
    tsSec,
    maxHR: maxHr,
    restingHR: restingHr,
    edwards: method != 'banister',
    female: sex == Sex.female,
  );
  if (s == null) {
    return const Metric<double>.absent(
      tier: Tier.estimate,
      inputs_used: inputs,
      note: 'strain needs ≥600 HR samples (or ≥20 spanning ≥600 s) and HRmax>RHR',
    );
  }
  return Metric<double>(
    value: s,
    confidence: 0.6,
    tier: Tier.estimate,
    inputs_used: inputs,
    note: '${method == "banister" ? "Banister" : "Edwards"} TRIMP → 0–100 strain '
        '(100·ln(TRIMP+1)/ln(7201)); wrist-HR ESTIMATE, not clinical',
  );
}

class LoadState {
  final double ctl; // chronic (42d)
  final double atl; // acute (7d)
  final double tsb; // form = ctl - atl
  const LoadState(this.ctl, this.atl, this.tsb);
  Map<String, dynamic> toJson() => {
        'ctl': round6(ctl),
        'atl': round6(atl),
        'tsb': round6(tsb),
      };
}

/// Minimum days of daily-TRIMP history before CTL/ATL/TSB are reported.
/// Two weeks: enough for the 7-day ATL to be converged and for the CTL prime
/// to rest on a real week of load rather than a single day.
const int ctlAtlMinDays = 14;

/// CTL/ATL/TSB from a time-ordered daily-TRIMP series (oldest→newest).
/// EWMA with time constants 42 d (CTL) and 7 d (ATL): λ = 1 − e^(−1/τ).
/// A missing day contributes a 0-load impulse (rest day) — the EWMA decays.
///
/// SEEDING (Banister 1975 impulse-response; the load before the record started
/// is UNKNOWN): both accumulators used to be seeded at `dailyTrimp.first`,
/// which asserted that a single observed day had already been sustained for the
/// full 42-day chronic window — `ctlAtlTsb([500])` returned ctl 500 / atl 500 /
/// tsb 0, a fully-adapted, perfectly-fresh athlete conjured from one workout.
/// Now: ABSTAIN below [minDays] with the standard need_baseline note, and prime
/// both accumulators with the MEAN of the first [primeDays] observed days
/// (never a single day, never future days) before running the EWMA over the
/// remainder.
Metric<LoadState> ctlAtlTsb(List<double> dailyTrimp,
    {double ctlDays = 42,
    double atlDays = 7,
    int minDays = ctlAtlMinDays,
    int primeDays = 7}) {
  const inputs = ['daily_trimp'];
  if (dailyTrimp.length < minDays) {
    return Metric<LoadState>.absent(
      tier: Tier.estimate,
      inputs_used: inputs,
      note: needBaselineNote(have: dailyTrimp.length, need: minDays),
    );
  }
  final lc = 1 - math.exp(-1 / ctlDays);
  final la = 1 - math.exp(-1 / atlDays);
  final prime = math.min(math.max(primeDays, 1), dailyTrimp.length);
  final seed = mean(dailyTrimp.sublist(0, prime))!;
  var ctl = seed;
  var atl = seed;
  for (var i = prime; i < dailyTrimp.length; i++) {
    ctl = ctl + lc * (dailyTrimp[i] - ctl);
    atl = atl + la * (dailyTrimp[i] - atl);
  }
  final conf = clamp(dailyTrimp.length / 42.0, 0.3, 0.85);
  return Metric<LoadState>(
    value: LoadState(ctl, atl, ctl - atl),
    confidence: conf,
    tier: Tier.estimate,
    inputs_used: inputs,
    note: 'Banister CTL(42d)/ATL(7d)/TSB, primed from the first $prime observed '
        'days; descriptive load, not injury risk',
  );
}
