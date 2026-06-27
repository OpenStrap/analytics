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
/// [hrPerMin] mean HR for each worn minute (bpm; pass only valid minutes).
/// [restingHr], [maxHr] the personal anchors. [sex] selects the b constant.
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
  final b = sex == Sex.male ? 1.92 : 1.67;
  final reserve = maxHr - restingHr;
  var trimp = 0.0;
  for (final hr in hrPerMin) {
    if (hr <= 0) continue; // off-skin guard
    var hrr = (hr - restingHr) / reserve;
    if (hrr < 0) hrr = 0;
    if (hrr > 1) hrr = 1;
    trimp += 1.0 * hrr * math.exp(b * hrr); // 1 minute each
  }
  return Metric<double>(
    value: trimp,
    confidence: 0.6,
    tier: Tier.estimate,
    inputs_used: inputs,
    note: 'Banister exponential TRIMP (wrist HR estimate)',
  );
}

/// Log-squash a raw TRIMP into a 0–21 headline "strain" score.
///
/// Raw Banister TRIMP grows roughly linearly with duration·intensity and lands
/// in the hundreds for a normal active day (~335), which is meaningless as a
/// headline number. A logarithmic squash compresses it into a bounded WHOOP-like
/// 0–21 scale where each extra point is progressively harder to earn:
///
///     strain(trimp) = min(21, ln(trimp + 1) / ln(1.5))
///
/// Check-points: 0 → 0; 335 → ln(336)/ln(1.5) ≈ 14.34 (cap not hit).
double strainScore(double trimp) {
  if (trimp <= 0) return 0.0;
  final s = math.log(trimp + 1) / math.log(1.5);
  return math.min(21.0, s);
}

/// Headline 0–21 strain as a Metric, alongside the raw TRIMP (HIGH/EST tier).
///
/// [trimp] the raw Banister TRIMP for the day/session. Returns absent when no
/// TRIMP is available (never fabricate a strain from nothing).
Metric<double> strainScoreMetric(double? trimp) {
  const inputs = ['trimp'];
  if (trimp == null || trimp < 0) {
    return const Metric<double>.absent(
      tier: Tier.estimate,
      inputs_used: inputs,
      note: 'no TRIMP available for a strain score',
    );
  }
  return Metric<double>(
    value: strainScore(trimp),
    confidence: 0.6,
    tier: Tier.estimate,
    inputs_used: inputs,
    note: 'headline 0–21 strain = log-squash of raw TRIMP '
        '(min(21, ln(trimp+1)/ln(1.5))); wrist-HR estimate',
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
//   3. TRIMP over the window:
//        a. Edwards 5-zone (default): sample contributes its zone weight (1..5 at
//           50/60/70/80/90 %HRR cut-offs) × per-sample duration (min).
//        b. Banister exponential: sample contributes dur × x × 0.64 × e^(b·x).
//   4. strain = 100 × ln(TRIMP + 1) / ln(D), D = 7201 (TRIMP 7200 ≈ max).
//
// References: Karvonen 1957; Edwards 1993; Banister 1991 (b = 1.92 M / 1.67 F);
// Tanaka 2001 (HRmax = 208 − 0.7·age).
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

  /// Banister coefficients.
  static const double banisterScale = 0.64;
  static const double banisterBMen = 1.92;
  static const double banisterBWomen = 1.67;

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

  /// Per-sample duration (minutes) from the first two timestamps (seconds).
  /// Falls back to 1 s when <2 samples or coincident timestamps.
  static double sampleDurationMinutes(List<double> tsSec) {
    if (tsSec.length < 2) return fallbackSampleMin;
    final deltaS = (tsSec[1] - tsSec[0]).abs();
    return deltaS > 0 ? deltaS / 60.0 : fallbackSampleMin;
  }

  static double edwardsTRIMP(List<double> bpm, double restingHR, double hrReserve,
      double sampleDurationMin) {
    var weighted = 0;
    for (final s in bpm) {
      weighted += zoneWeight(s, restingHR, hrReserve);
    }
    return weighted * sampleDurationMin;
  }

  static double banisterTRIMP(List<double> bpm, double restingHR, double hrReserve,
      double sampleDurationMin, double b) {
    var acc = 0.0;
    for (final s in bpm) {
      final x = pctHRR(s, restingHR, hrReserve) / 100.0;
      if (x > 0) acc += sampleDurationMin * x * banisterScale * math.exp(b * x);
    }
    return acc;
  }

  // ── Logarithmic map ─────────────────────────────────────────────────────────

  /// Map accumulated TRIMP onto [0, 100] via 100 × ln(TRIMP+1) / ln(D), 2 dp.
  /// TRIMP ≤ 0 → 0.
  static double trimpToStrain(double trimp, {double denominator = strainDenominator}) {
    if (trimp <= 0) return 0;
    final value = maxStrain * math.log(trimp + 1.0) / math.log(denominator);
    return (value * 100).roundToDouble() / 100;
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

    final sampleDur = sampleDurationMinutes(tsSec);
    final hrReserve = effMax - restingHR;

    final double trimp;
    if (edwards) {
      trimp = edwardsTRIMP(bpm, restingHR, hrReserve, sampleDur);
    } else {
      final b = female ? banisterBWomen : banisterBMen;
      trimp = banisterTRIMP(bpm, restingHR, hrReserve, sampleDur, b);
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
  double restingHr = StrainScorer.defaultRestingHR,
  String method = 'edwards',
  Sex sex = Sex.male,
}) {
  const inputs = ['hr_series', 'resting_hr', 'max_hr'];
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

/// CTL/ATL/TSB from a time-ordered daily-TRIMP series (oldest→newest).
/// EWMA with time constants 42 d (CTL) and 7 d (ATL): λ = 1 − e^(−1/τ).
/// A missing day contributes a 0-load impulse (rest day) — the EWMA decays.
Metric<LoadState> ctlAtlTsb(List<double> dailyTrimp,
    {double ctlDays = 42, double atlDays = 7}) {
  const inputs = ['daily_trimp'];
  if (dailyTrimp.isEmpty) {
    return const Metric<LoadState>.absent(
      tier: Tier.estimate,
      inputs_used: inputs,
      note: 'no daily TRIMP history',
    );
  }
  final lc = 1 - math.exp(-1 / ctlDays);
  final la = 1 - math.exp(-1 / atlDays);
  var ctl = dailyTrimp.first;
  var atl = dailyTrimp.first;
  for (var i = 1; i < dailyTrimp.length; i++) {
    ctl = ctl + lc * (dailyTrimp[i] - ctl);
    atl = atl + la * (dailyTrimp[i] - atl);
  }
  final conf = clamp(dailyTrimp.length / 42.0, 0.3, 0.85);
  return Metric<LoadState>(
    value: LoadState(ctl, atl, ctl - atl),
    confidence: conf,
    tier: Tier.estimate,
    inputs_used: inputs,
    note: 'Banister CTL(42d)/ATL(7d)/TSB; descriptive load, not injury risk',
  );
}
