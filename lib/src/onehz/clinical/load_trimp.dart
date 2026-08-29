// CLINICAL TIER-1 — training load: TRIMP + CTL/ATL/TSB.
//
// Banister exponential TRIMP (Morton 1990) — the ONE TRIMP in this package.
// CTL (Chronic Training Load, 42-day EWMA of daily TRIMP), ATL (Acute, 7-day
// EWMA), TSB = CTL − ATL (Training Stress Balance / "form").
//
// EDWARDS IS GONE (audit MOT-06, deleted 2026-08-17). `StrainScorer` used to
// carry a second, zone-sum TRIMP applying Edwards 1993's 50/60/70/80/90
// cut-offs to %HRR, where Edwards defines them on %HRmax. At RHR 55 / HRmax
// 187, 50 % HRR = 121 bpm = 64.7 % HRmax, so every minute banded about one zone
// low and the two published-looking 0–100 numbers disagreed by 2.8×–184× on the
// same stream (measured on whoop-4.db). Nothing shipped it — `strain_effort`
// was a permanently-null key removed from edge at v68 — so rather than re-derive
// it on the right denominator, the whole second scale is deleted. The app's
// display zones (`hr_zones.dart`) already do %HRmax correctly, with a separately
// labelled Karvonen variant. Do not reintroduce a second 0–100 strain.
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
  // `maxHr <= restingHr` is FALSE when either is NaN, so the finiteness checks
  // are load-bearing: a NaN anchor otherwise makes a NaN reserve, and every
  // clamp below (`hrr < 0`, `hrr > 1`) is false for NaN too, so the sum comes
  // out NaN inside a PRESENT metric.
  if (restingHr == null ||
      maxHr == null ||
      !restingHr.isFinite ||
      !maxHr.isFinite ||
      maxHr <= restingHr ||
      hrPerMin.isEmpty) {
    return const Metric<double>.absent(
      tier: Tier.estimate,
      inputs_used: inputs,
      note: 'Banister TRIMP needs finite measured RHR and HRmax (HRmax>RHR)',
    );
  }
  final reserve = maxHr - restingHr;
  var trimp = 0.0;
  for (final hr in hrPerMin) {
    if (!hr.isFinite || hr <= 0) continue; // off-skin + non-finite guard
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

/// Fraction of heart-rate reserve that simply BEING AWAKE costs — THE REFERENCE
/// VALUE THE ANCHOR TABLE IS GENERATED AT, and nothing else.
///
/// Whole-day Banister TRIMP counts every waking minute above resting, so ~16 h
/// of ordinary living accrues ~180 TRIMP before any exercise happens. That is
/// the cost of being alive, not training load, and billing it as load is what
/// put an INACTIVE full-wear day at ~13/21 on the scale before the baseline
/// subtraction existed.
///
/// IT IS NOT A DEFAULT ANY MORE (audit MOT-03, edge#226). 0.20 was a
/// population figure standing in for a personal one, and it sat below where
/// this user's quiet waking actually is (p50 0.274 HRR, whoop-4.db) — which
/// left a day with no activity at all scoring 6.93–12.14 on a 0–21 scale, the
/// band the anchor table calls "90 min hard session". Every entry point now
/// takes the level as an argument; [dailyQuietWakingHrr] measures it from the
/// user's own day. Passing this constant reproduces the anchor table exactly.
const double quietWakingHrr = 0.20;

/// The most a quiet-waking level may be and still be called quiet waking.
///
/// ACSM's moderate-intensity floor (40 % HRR). A day whose MEDIAN waking minute
/// sits above it was not ordinary living, so it cannot define what ordinary
/// living costs — [dailyQuietWakingHrr] abstains rather than hand back a level
/// that would subtract the day's own training away.
const double maxQuietHrr = 0.40;

/// THIS user's quiet-waking level, measured: the MEDIAN per-minute HRR over a
/// day's waking minutes. Percentile of self, never a population number.
///
/// The median, not the mean, and not a low percentile: a session is a small
/// minority of minutes on any real day, so the median tracks ordinary living
/// and ignores the training — while p10 or p25 would track sitting still
/// specifically, which is lower than living costs and leaves the same
/// over-billing this exists to remove.
///
/// PREFER A TRAILING VALUE. The day's own median is the right measurement of
/// that day, but the quantity wanted is a TRAIT, and a day spent walking for
/// eight hours would otherwise subtract its own effort away. Feed these into a
/// rolling personal median and score against that; the guard below only refuses
/// the most obvious offenders, it does not make a single day robust.
///
/// Returns null — never a stand-in — when the anchors are missing, non-finite
/// or degenerate, when there are fewer than [minMinutes] measured waking
/// minutes, or when the median clears [maxQuietHrr].
double? dailyQuietWakingHrr(
  List<double> hrPerMin, {
  required double? restingHr,
  required double? maxHr,
  int minMinutes = 60,
}) {
  // Finiteness first: `maxHr <= restingHr` is false when either is NaN, and a
  // NaN reserve survives BOTH clamps below (min/max propagate NaN) and both
  // range checks at the bottom, so the function would hand back NaN as if it
  // had measured something.
  if (restingHr == null ||
      maxHr == null ||
      !restingHr.isFinite ||
      !maxHr.isFinite ||
      maxHr <= restingHr) {
    return null;
  }
  final reserve = maxHr - restingHr;
  final hrr = <double>[
    // `hr > 0` already drops NaN, but not +infinity — which would clamp to 1.0
    // and count a garbage sample as a maximal-effort minute.
    for (final hr in hrPerMin)
      if (hr.isFinite && hr > 0)
        math.min(1.0, math.max(0.0, (hr - restingHr) / reserve)),
  ];
  if (hrr.length < minMinutes) return null;
  final q = median(hrr);
  if (q == null || q <= 0 || q > maxQuietHrr) return null;
  return q;
}

/// Net TRIMP — earned ABOVE the quiet-waking baseline — that defines a maximal
/// day and maps to the top of the scale.
///
/// The old map put 21 at a raw TRIMP of ~4987, i.e. ≈35 h at 80 % HRR: the top
/// third of the scale was unreachable by any human day, so the headline number
/// never used the range it advertised.
const double maximalNetTrimp = 400.0;

/// Curvature of the 0–21 map; higher gives more resolution at the low end.
///
/// CALIBRATION ANCHORS — regenerated 2026-08-17 (audit MOT-04), and they only
/// mean anything with the profile and the convention printed next to them:
///
///   PROFILE  RHR 60, HRmax 187 (Tanaka @30), male constants, 960 waking
///            minutes, every NON-SESSION minute sitting at exactly
///            [quietWakingHrr] (= 85 bpm on this profile).
///
///   inactive 16 h                       TRIMP  176.5 → 0.00
///   + 60 min walk @105 bpm              TRIMP  192.3 → 2.70
///   + 45 min moderate run @145 bpm      TRIMP  237.9 → 8.55
///   + 90 min hard session @165 bpm      TRIMP  392.9 → 16.54
///   + 5 h @160 bpm                      TRIMP  806.9 → 21.00 (SATURATED)
///   135 min wear, no activity           TRIMP   24.8 → 0.00
///
/// The old table's "5 h at 160 bpm → 21" was loose, not wrong: with the
/// baseline subtraction included the scale SATURATES AT ≈3.25 h at 160 bpm
/// (195 min) and ≈4.25 h at 150 bpm, so everything above that is one number.
///
/// THE TABLE ONLY HOLDS AT THE QUIET LEVEL IT WAS GENERATED AT, which is the
/// point of MOT-03 (edge#226, fixed 2026-08-19). Generated at 0.20 HRR; this
/// user's measured wake minutes sit at p50 0.274 / p75 0.332 HRR (whoop-4.db,
/// 9 full-wear days, RHR 55 / HRmax 187), and scoring that user against a 0.20
/// baseline put a day containing only 2–6 minutes above 50 % HRR at
/// 6.93 / 11.17 / 11.38 / 11.97 / 12.14 — a NOTHING-DAY in the band this table
/// calls "90 min hard session". The map was never the problem: at their own
/// 0.274 the same day scores 0.00 and the same day plus an hour's walk scores
/// 2.15, which is this table's "60 min walk" row. The quiet level is an
/// argument now, so regenerate the table with whatever you pass, never
/// separately.
const double strainCurvature = 15.0;

/// The TRIMP that [wakeMinutes] of ordinary waking accrues on its own.
///
/// Scales with the wake window ACTUALLY observed, so a partial-wear day is not
/// charged a full day's overhead (a 2 h inactive wear window would otherwise
/// come out negative and clamp, while a 16 h one read as real effort).
///
/// WHY THIS IS STILL SUBTRACTIVE (audit MOT-05, measured 2026-08-17 and NOT
/// adopted). MOT-05 asks for the domain bound to move into the accumulator —
/// sum `x·y(x)` only over minutes above [quietWakingHrr] and drop this
/// subtraction — on the argument that a gated sum depends on data rather than
/// on a fourth-decimal constant. Replayed on all three real corpora at the
/// SHIPPED constant it is strictly worse, because 0.20 HRR is below where quiet
/// waking actually sits: gen4's five nothing-days go 11.2/11.4/12.0/12.1/13.1 →
/// 17.6/17.7/17.8/18.2/21.0, and MG's three genuinely quiet days go 0.00 →
/// 10.72/12.72/0.06. Crediting a quiet minute in FULL the moment it clears the
/// gate is what does it. (Σ(x−Q)·y(x) over the same minutes tracks the current
/// form within ~1.5 points on gen4 but still breaks MG's honest zeros: 0.00 →
/// 4.05/4.83.) The gated form is only defensible once [quietWakingHrr] is this
/// user's own quiet level — MOT-03 — so it is blocked on that, not on taste.
///
/// [quietHrr] is that level: [dailyQuietWakingHrr] measures it, and it is
/// clamped to (0, [maxQuietHrr]] here so no caller can hand over a baseline
/// that either vanishes or eats a whole day's training.
double baselineTrimp(
  double wakeMinutes, {
  required double quietHrr,
  bool female = false,
}) {
  final q = math.min(maxQuietHrr, math.max(0.0, quietHrr));
  return wakeMinutes * q * StrainScorer.banisterY(q, female: female);
}

/// Log-map the TRIMP EARNED ABOVE baseline into a 0–21 headline "strain" score.
///
///     net    = trimp − baselineTrimp(wakeMinutes, quietHrr)
///     u      = min(1, net / maximalNetTrimp)
///     strain = 21 · ln(1 + u·(C−1)) / ln(C),  C = [strainCurvature]
///
/// [wakeMinutes] is the observed waking wear window that produced [trimp] — it
/// sets the baseline, so it is required rather than assumed. [quietHrr] is what
/// a minute of that window costs this user when nothing is happening
/// ([dailyQuietWakingHrr]); it is required for the same reason, and getting it
/// wrong by 0.07 HRR is the difference between a nothing-day scoring 0 and
/// scoring 12.
double strainScore(
  double trimp, {
  required double wakeMinutes,
  required double quietHrr,
  bool female = false,
}) {
  final net =
      trimp - baselineTrimp(wakeMinutes, quietHrr: quietHrr, female: female);
  if (net <= 0) return 0.0;
  final u = math.min(1.0, net / maximalNetTrimp);
  final s =
      21.0 * math.log(1 + u * (strainCurvature - 1)) / math.log(strainCurvature);
  return math.min(21.0, math.max(0.0, s));
}

/// Headline 0–21 strain as a Metric, alongside the raw TRIMP (EST tier).
///
/// [trimp] the raw Banister TRIMP for the day/session, [wakeMinutes] the wake
/// window it was accumulated over, [quietHrr] this user's quiet-waking level
/// ([dailyQuietWakingHrr]). Absent — with the reason in the note — when any is
/// missing, non-finite, or out of range: the baseline
/// subtraction is meaningless without a wake window, guessing one silently
/// mis-scores every partial-wear day, and a stand-in quiet level is what scored
/// a day with no activity in it at 12/21 (MOT-03).
Metric<double> strainScoreMetric(
  double? trimp, {
  required double? wakeMinutes,
  required double? quietHrr,
  bool female = false,
}) {
  const inputs = ['trimp', 'wake_minutes', 'quiet_waking_hrr'];
  // EVERY RANGE CHECK IN THIS FUNCTION IS FALSE FOR NaN, so each one needs its
  // finiteness partner. Without them a NaN input produces a PRESENT metric
  // carrying a NaN value, which is worse than an absent one: everything
  // downstream treats a present metric as measured.
  if (trimp == null || !trimp.isFinite || trimp < 0) {
    return const Metric<double>.absent(
      tier: Tier.estimate,
      inputs_used: inputs,
      note: 'strain needs a finite TRIMP >= 0',
    );
  }
  if (wakeMinutes == null || !wakeMinutes.isFinite || wakeMinutes <= 0) {
    return const Metric<double>.absent(
      tier: Tier.estimate,
      inputs_used: inputs,
      note: 'strain needs a finite wake window (minutes > 0) — it is what the '
          'quiet-waking baseline is subtracted over',
    );
  }
  if (quietHrr == null || !quietHrr.isFinite || quietHrr <= 0) {
    return const Metric<double>.absent(
      tier: Tier.estimate,
      inputs_used: inputs,
      note: 'strain needs this user\'s own quiet-waking HRR to subtract, '
          'finite and > 0; without it the cost of simply being awake reads '
          'as training load',
    );
  }
  // NOT clamped through to [baselineTrimp]. It clamps to maxQuietHrr as a last
  // resort, which would quietly score the day against a level nobody measured;
  // a quiet level above the moderate-intensity floor is a broken measurement,
  // and [dailyQuietWakingHrr] never emits one.
  if (quietHrr > maxQuietHrr) {
    return const Metric<double>.absent(
      tier: Tier.estimate,
      inputs_used: inputs,
      note: 'quiet-waking HRR above $maxQuietHrr is not quiet waking — that '
          'is ACSM\'s moderate-intensity floor, so the level would subtract '
          'the day\'s own training away',
    );
  }
  return Metric<double>(
    value: strainScore(trimp,
        wakeMinutes: wakeMinutes, quietHrr: quietHrr, female: female),
    confidence: 0.6,
    tier: Tier.estimate,
    inputs_used: inputs,
    note: 'headline 0–21 strain = log map of TRIMP earned above the '
        'quiet-waking baseline; wrist-HR estimate',
  );
}

// Two other TRIMPs used to sit here: a top-level `edwardsTrimp` binning minutes
// on %HRmax, and `StrainScorer`'s zone sum binning the SAME cut-offs on %HRR.
// Both are deleted (audit MOT-06) — see the file header. Banister is the one
// TRIMP.

// ════════════════════════════════════════════════════════════════════════════
// StrainScorer — Banister TRIMP → 0–100 strain ("Effort").
// Implementation of published exercise-physiology methods.
//
//   1. Heart-Rate Reserve (Karvonen): HRR = HRmax − RHR.
//   2. Per-sample intensity %HRR = (HR − RHR) / HRR × 100, clamped 0..100.
//   3. TRIMP over the window (each sample carries its OWN duration, measured
//      from the real timestamps and capped at the stream's median cadence so a
//      gap is never counted as effort): sample contributes dur × x × y(x), with
//      y = 0.64·e^(1.92x) (men) / 0.86·e^(1.67x) (women).
//   4. strain = 100 × ln(TRIMP + 1) / ln(D), D = 7201.
//
// References: Karvonen 1957; Banister 1991 (y = 0.64·e^(1.92x) men /
// 0.86·e^(1.67x) women); Tanaka 2001 (HRmax = 208 − 0.7·age).
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

  /// Logarithmic-map denominator D = 7200 + 1.
  ///
  /// It was set from the Edwards daily ceiling (top weight 5 sustained 24 h =
  /// 7200), and Edwards is gone (MOT-06). Kept unchanged anyway: the Banister
  /// ceiling over the same 24 h is 1440 × 1 × y(1) = 6,293, within 15 % of it,
  /// and this is a DISPLAY map — rescaling it would rescore every stored day for
  /// no gain in truth.
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

  // ── HRmax helpers ───────────────────────────────────────────────────────────

  /// Tanaka (2001): HRmax = 208 − 0.7 × age.
  static double tanakaHRmax(double age) => 208.0 - 0.7 * age;

  // `defaultMaxHR([age]) => 220 - age` used to sit here as StrainScorer's
  // "last-resort fallback". It had exactly one caller — `strain` — and its only
  // job there was to keep producing a number when the person's ceiling was
  // unknown (MOT-11). Deleted with that fallback. `AutoWorkoutDetector` keeps
  // its own 190 for the "did you work out?" prompt, which is not a published
  // number.

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

  // ── Karvonen %HRR ──────────────────────────────────────────────────────────

  /// Karvonen %HRR, clamped [0, 100].
  static double pctHRR(double bpm, double restingHR, double hrReserve) {
    final pct = (bpm - restingHR) / hrReserve * 100.0;
    if (pct < 0) return 0;
    if (pct > 100) return 100;
    return pct;
  }

  // ── TRIMP accumulation ──────────────────────────────────────────────────────

  /// Measured cadence (seconds) of a time-ordered stream, or NULL.
  ///
  /// Now a thin alias for [sampleCadenceSeconds], which is the single helper
  /// for all three of the old near-duplicates. Kept because it is public API;
  /// the old `maxPlausibleGapSec` parameter is gone — the ceiling lives on
  /// [maxSupportedCadenceSec] and the old `fallbackSampleMin` floor was the
  /// fabricated 1 s that made a 301 s stream look like a 1 Hz one.
  static double? medianIntervalSeconds(List<double> tsSec) =>
      sampleCadenceSeconds(tsSec);

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
  /// EMPTY when the stream's cadence cannot be measured — see
  /// [sampleCadenceSeconds]. Every duration here is a multiple of that cadence,
  /// so an unmeasurable cadence is an unmeasurable effort, and [strain] turns
  /// it into an absent metric rather than a small confident one.
  static List<double> sampleDurationsMinutes(List<double> tsSec) {
    final n = tsSec.length;
    if (n == 0) return const [];
    if (n == 1) return [fallbackSampleMin];
    final capSec = medianIntervalSeconds(tsSec);
    if (capSec == null) return const [];
    final out = List<double>.filled(n, capSec / 60.0);
    for (var i = 0; i < n - 1; i++) {
      final g = tsSec[i + 1] - tsSec[i];
      out[i] = (g > 0 ? math.min(g, capSec) : capSec) / 60.0;
    }
    return out;
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
  /// [minReadings] AND less than [minSpanSeconds] coverage), when [maxHR] is
  /// missing, or when maxHR ≤ restingHR (invalid HRR).
  ///
  /// [maxHR] IS REQUIRED-AND-NULLABLE, and null means NO NUMBER (audit MOT-11).
  /// It used to fall back to `defaultMaxHR()` = 190, a 220−age ceiling for a 30
  /// y/o applied to whoever's wrist arrived — a fabricated anchor inside the
  /// value, caught (if at all) by the caller. Honesty belongs at the source, so
  /// that helper is gone too. `AutoWorkoutDetector` keeps its own 190 for the
  /// "did you work out?" gate, which is a prompt, not a published number.
  static double? strain(
    List<double> bpm,
    List<double> tsSec, {
    required double? maxHR,
    double restingHR = defaultRestingHR,
    bool female = false,
    double denominator = strainDenominator,
  }) {
    if (maxHR == null) return null;
    final effMax = maxHR;
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
    // No measurable cadence ⇒ no durations ⇒ no effort. Must NOT fall through:
    // `banisterTRIMP` credits `fallbackSampleMin` per sample when handed an
    // empty list, which is the fabricated 1 s this abstention exists to stop.
    if (durations.isEmpty) return null;
    final trimp = banisterTRIMP(bpm, restingHR, effMax - restingHR, durations,
        female: female);
    return trimpToStrain(trimp, denominator: denominator);
  }
}

/// Banister TRIMP strain ("Effort", 0–100) as a Metric, with the honesty
/// envelope: absent when the gates fail (never fabricated).
///
/// [bpm] per-sample HR (bpm). [tsSec] timestamps (s), same length. [maxHr] /
/// [restingHr] the personal anchors (HRmax resolved by the caller via
/// [StrainScorer.estimateHRmax] / Tanaka). [sex] selects the Banister
/// coefficient. The `method` parameter is gone with the Edwards path (MOT-06).
Metric<double> trimpStrain(
  List<double> bpm,
  List<double> tsSec, {
  double? maxHr,
  double? restingHr,
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
    note: 'Banister TRIMP → 0–100 strain '
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
  final conf = (dailyTrimp.length / 42.0).clamp(0.3, 0.85);
  return Metric<LoadState>(
    value: LoadState(ctl, atl, ctl - atl),
    confidence: conf,
    tier: Tier.estimate,
    inputs_used: inputs,
    note: 'Banister CTL(42d)/ATL(7d)/TSB, primed from the first $prime observed '
        'days; descriptive load, not injury risk',
  );
}
