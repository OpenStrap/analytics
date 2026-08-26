// Per-bout calorie estimation (calories.py / WorkoutDetector.swift).
//
// HR-based: Keytel et al. 2005 active EE (kJ/min from HR, weight, age, sex) +
// revised Harris–Benedict BMR for the resting floor. Keytel publishes TWO
// coefficient sets, male and female; the third set here (`nonbinary`) is OUR
// element-wise INTERPOLATION of those two, not a third published equation —
// see [Calories.nonbinary]. APPROXIMATE — not laboratory calorimetry, not
// medical advice.
//
// Faithfulness note: the coefficients, the 86_400 BMR/s divisor, the 251.04
// workout divisor (60 s/min × 4.184 kJ/kcal) and the elapsed-time-per-sample
// weighting (capped at mergeGapS = 150 s) are copied verbatim from
// WorkoutDetector.swift. The active gate is NOT — that file's 0.30 HRR is
// superseded, see [Calories.activeHRRFraction]. Pure, dart:math only.

import 'dart:math' as math;

/// User profile for calorie estimation.
class WorkoutUserProfile {
  final double weightKg;
  final double heightCm;
  final double age;

  /// "male" | "female" | "nonbinary" (anything else → nonbinary).
  final String sex;

  const WorkoutUserProfile({
    this.weightKg = 70.0,
    this.heightCm = 170.0,
    this.age = 30.0,
    this.sex = 'nonbinary',
  });
}

/// The Keytel/Harris–Benedict coefficient block for one sex.
class CalorieCoeffs {
  final double restingAlpha;
  final double restingWeight;
  final double restingHeight; // applied to height in METRES
  final double restingAge;
  final double workoutHR;
  final double workoutWeight;
  final double workoutAge;
  final double workoutAlpha;
  const CalorieCoeffs({
    required this.restingAlpha,
    required this.restingWeight,
    required this.restingHeight,
    required this.restingAge,
    required this.workoutHR,
    required this.workoutWeight,
    required this.workoutAge,
    required this.workoutAlpha,
  });
}

/// HR-based calorie estimation (Keytel 2005 active + revised Harris–Benedict BMR).
class Calories {
  static const CalorieCoeffs male = CalorieCoeffs(
    restingAlpha: 88.362,
    restingWeight: 13.397,
    restingHeight: 479.9,
    restingAge: 5.677,
    workoutHR: 0.6309,
    workoutWeight: 0.1988,
    workoutAge: 0.2017,
    workoutAlpha: -55.0969,
  );
  static const CalorieCoeffs female = CalorieCoeffs(
    restingAlpha: 447.593,
    restingWeight: 9.247,
    restingHeight: 309.8,
    restingAge: 4.33,
    workoutHR: 0.4472,
    workoutWeight: -0.1263,
    workoutAge: 0.0740,
    workoutAlpha: -20.4022,
  );
  /// INTERPOLATED, NOT PUBLISHED (audit MOT-10). Keytel 2005 and revised
  /// Harris–Benedict each publish exactly two sex sets; every constant below is
  /// the element-wise ARITHMETIC MEAN of [male] and [female]
  /// ((88.362+447.593)/2 = 267.9775, (0.1988−0.1263)/2 = 0.03625, …). The
  /// weight term is the one to be careful with: male +0.1988 and female −0.1263
  /// have OPPOSITE SIGNS, so the mean 0.03625 kJ/min/kg belongs to neither
  /// regression and is not a fitted quantity at all. It is used deliberately —
  /// `workoutSex` routes null/'other'/unrecognised here by design, and the mean
  /// of the two is a smaller lie than guessing one of them — but nothing about
  /// it is Keytel's. Same convention, same wording, as [mifflinBmrKcalDay]'s
  /// nonbinary constant.
  static const CalorieCoeffs nonbinary = CalorieCoeffs(
    restingAlpha: 267.9775,
    restingWeight: 11.322,
    restingHeight: 394.85,
    restingAge: 5.0035,
    workoutHR: 0.53905,
    workoutWeight: 0.03625,
    workoutAge: 0.13785,
    workoutAlpha: -37.74955,
  );

  /// THE HR-FLEX POINT, as a fraction of heart-rate RESERVE, for BOTH the day
  /// ([dailyEnergy]) and the bout ([estimateBoutCalories]). One definition —
  /// see [activeGateHr], which is the only place it is turned into a bpm.
  ///
  /// It decides which minutes get billed the Keytel rate at all. Keytel's
  /// regression is fitted on STEADY-STATE SUBMAXIMAL EXERCISE with chest/ECG
  /// HR; below the exercise domain there is no HR↔EE slope to extrapolate along
  /// (that absence is the entire premise of the HR-FLEX method this file cites
  /// — Spurr 1988 / Ceesay 1989 assign resting EE below flex and an
  /// INDIVIDUALLY CALIBRATED line above it). Ours is a population line, so the
  /// gate has to sit where that line is at least approximately true.
  ///
  /// WHY HRR AND NOT A FRACTION OF HRmax (issue #43). The two entry points used
  /// to disagree: the day gated at 0.65 × HRmax, the bout at RHR + 0.30 × HRR,
  /// so the same minute of the same stream was billed active by one and resting
  /// by the other, by 8–35 bpm depending on the profile. A fraction of HRmax
  /// alone is also the wrong shape: 0.65 × Tanaka is 135.2 − 0.455 · age, which
  /// falls with age while resting HR does not, so it drifts toward rest for the
  /// old and away from it for the young and fit.
  ///
  ///   profile          HRmax   old day   old bout   NOW (0.40 HRR)
  ///   70 y, RHR 68     159.0     103.4       95.3        104.4
  ///   34 y, RHR 55     184.2     119.7       93.8        106.7
  ///   25 y, RHR 45     190.5     123.8       88.7        103.2
  ///
  /// 0.40 IS THE SAME BOUNDARY THE 0.65 CHOICE WAS REACHING FOR (audit MOT-02,
  /// 2026-08-17, which raised the day gate 0.50 → 0.65 × HRmax): ACSM puts
  /// moderate intensity at 40–59 % HRR ≡ 64–76 % HRmax, so 0.40 HRR is 0.65
  /// HRmax expressed against the individual's own rest instead of against a
  /// population ceiling. Below it, movement is not counted as exercise at all,
  /// and it is the region Keytel's protocol does not sample. It is a choice,
  /// not a number Keytel prints; what Keytel prints is a regression with no
  /// resting arm. The 0.30 that came over from WorkoutDetector.swift sat below
  /// that boundary, right where Keytel over-reads worst (a 34 y/o at 92 bpm
  /// bills ≈4.6 METs for what is ≈3).
  ///
  /// MEASURED CONSEQUENCE of MOT-02 (whoop-4.db, 9 days, 70 kg/170 cm/30 y male
  /// stand-in, Tanaka HRmax 187): billed minutes 39.4 % → 4.9 % of the wake
  /// window; daily ACTIVE energy min/median/max 769/1,955/4,062 → 9/48/1,917
  /// kcal. On that stand-in RHR is unknown, so the HRR restatement cannot be
  /// replayed against it; on the profiles above it moves the day gate by
  /// +1.0 / −13.0 / −20.6 bpm and the bout gate by +9.1 / +12.9 / +14.5.
  ///
  /// This is still a point estimate with no error band, deliberately: Keytel
  /// publishes a POPULATION MAPE, which is not this user's error distribution,
  /// and drawing bounds around the number would claim we computed them.
  static const double activeHRRFraction = 0.40;

  /// The HR at or above which a sample is billed the Keytel active rate:
  /// `restingHr + [activeHRRFraction] · (hrmax − restingHr)`.
  ///
  /// THE one definition. Both entry points call it, and so does the edge's live
  /// sample-by-sample billing — a second copy of this arithmetic is how the day
  /// and the bout came to disagree in the first place.
  ///
  /// NULL WHEN THE ANCHORS CANNOT DEFINE A GATE: either one non-finite, or not
  /// `0 < restingHr < hrmax`. A NaN gate is not a loose gate, it is NO gate —
  /// every `hr < gate` comparison against NaN is false, so EVERY sample bills
  /// at the Keytel active rate and a silently enormous kcal figure comes out
  /// the far end instead of an obvious failure. Validation lives here rather
  /// than in each entry point because this is the one place both of them (and
  /// the edge's live billing) route through.
  static double? activeGateHr(double hrmax, double restingHr) =>
      (hrmax.isFinite &&
              restingHr.isFinite &&
              restingHr > 0 &&
              restingHr < hrmax)
          ? restingHr + activeHRRFraction * (hrmax - restingHr)
          : null;

  /// 60 s/min × 4.184 kJ/kcal.
  static const double workoutDivisor = 251.04;

  /// How long one HR sample may stand in for when the next one is late.
  ///
  /// Named rather than left as a default-parameter literal because it is not
  /// only this package's business: a caller scoring a bout live, sample by
  /// sample, has to give up at the same point as the re-score of the same
  /// stream, or the two disagree by whatever a dropout ran over. A default
  /// argument cannot be referenced from outside, so the two copies of `150.0`
  /// drifted apart by construction.
  static const double defaultMergeGapCapS = 150.0;

  static CalorieCoeffs resolveCoeffs(String sex) {
    switch (sex.toLowerCase()) {
      case 'male':
        return male;
      case 'female':
        return female;
      case 'nonbinary':
        return nonbinary;
      default:
        return nonbinary;
    }
  }

  /// Resting BMR rate (kcal/s) — revised Harris–Benedict ÷ 86 400.
  static double restingKcalPerS(
      CalorieCoeffs c, double weightKg, double heightCm, double age) {
    final heightM = heightCm / 100.0;
    final bmr = c.restingAlpha +
        c.restingWeight * weightKg +
        c.restingHeight * heightM -
        c.restingAge * age;
    return math.max(0.0, bmr) / 86400.0;
  }

  /// Active EE rate (kcal/s) — Keytel 2005 kJ/min ÷ workoutDivisor.
  static double activeKcalPerS(
      CalorieCoeffs c, double hr, double hrmax, double weightKg, double age) {
    final eeKjMin = c.workoutHR * math.min(hr, hrmax) +
        c.workoutWeight * weightKg +
        c.workoutAge * age +
        c.workoutAlpha;
    return math.max(0.0, eeKjMin) / workoutDivisor;
  }

  /// Basal metabolic rate (kcal/DAY) — Mifflin–St Jeor 1990. More accurate on
  /// modern populations than revised Harris–Benedict, and the standard floor for
  /// total daily energy expenditure (TDEE).
  ///
  ///   men:   10·kg + 6.25·cm − 5·age + 5
  ///   women: 10·kg + 6.25·cm − 5·age − 161
  ///   nonbinary / unknown: the mean of the two sex constants (−78).
  static double mifflinBmrKcalDay(
      double weightKg, double heightCm, double age, String sex) {
    final base = 10.0 * weightKg + 6.25 * heightCm - 5.0 * age;
    final double sexConst;
    switch (sex.toLowerCase()) {
      case 'male':
        sexConst = 5.0;
        break;
      case 'female':
        sexConst = -161.0;
        break;
      default:
        sexConst = -78.0; // mean of +5 / −161
    }
    return math.max(0.0, base + sexConst);
  }

  /// Total daily energy expenditure (kcal) via the HR-FLEX method
  /// (Spurr 1988 / Ceesay 1989): for each minute, energy is the GREATER of the
  /// basal rate and the HR-derived active rate — so resting time burns BMR and
  /// active time burns the Keytel rate, with no double counting.
  ///
  /// Returns (total, active, basal):
  ///   * basal  = BMR over the WHOLE day (kcal/day, pro-rated by [dayMinutes]).
  ///   * active = Σ max(0, keytel(HR) − basalPerMin) over minutes with HR.
  ///   * total  = basal + active  ≡  Σ max(basalPerMin, keytel(HR)) with BMR
  ///              filling any minute that has no HR sample.
  ///
  /// [hrPerMin] is per-minute mean HR (bpm); 0/absent minutes fall back to BMR.
  /// The flex point is [activeGateHr] — the SAME gate [estimateBoutCalories]
  /// uses, read its constant before moving it: minutes below it burn BMR only,
  /// so a quiet day reads ≈ basal and Keytel's low-HR extrapolation can't
  /// inflate "active".
  /// [dayMinutes] lets a partial day pro-rate basal (default 1440 = full day).
  ///
  /// [hrmax] IS REQUIRED, and there is deliberately no fallback for it. It used
  /// to default to `220 − age` here, which is a universal formula — a ceiling
  /// invented in this package, applied to whatever strap measured the HR, and
  /// then used as the flex gate that decides which minutes count as active at
  /// all. Whether a wrist can be banded on that number is a property of the
  /// sensor package, so the ceiling is DISPATCHED PER DEVICE FAMILY by the
  /// caller (edge: `hr_max.dart`'s `estimatedMaxHr(age, deviceFamily)`, the one
  /// definition all zone/TRIMP/calorie call sites route through). An unknown
  /// age or an uncalibrated strap yields no ceiling there, and a caller with no
  /// ceiling has no energy figure: it abstains rather than call this. That is
  /// why the old `usedDefaultHrmax` flag is gone — the case it flagged can no
  /// longer reach this function.
  ///
  /// [restingHr] IS REQUIRED FOR THE SAME REASON and likewise has no fallback:
  /// the gate is HRR-relative now (issue #43), so an unknown rest is an unknown
  /// gate. A caller without a measured resting HR has no honest day-energy
  /// figure and abstains rather than have one computed against somebody else's
  /// rest.
  ///
  /// RETURNS NULL when the anchors are present but unusable — non-finite, or
  /// not `0 < restingHr < hrmax`, see [activeGateHr]. Same rule as the absent
  /// case and for the same reason: no gate, no honest energy figure. It is
  /// never the zeros, because a zero here reads downstream as a measured day
  /// with nothing in it.
  /// METs for a measured walking cadence, or null when the cadence carries no
  /// honest MET.
  ///
  /// Tudor-Locke et al. 2019 (CADENCE-Adults, Int J Behav Nutr Phys Act 16:8):
  /// heuristic cadence thresholds of 100, 110, 120 and 130 steps/min
  /// correspond to 3, 4, 5 and 6 METs in adults. Linear between the anchors;
  /// CLAMPED at both ends of the fitted range rather than extrapolated —
  /// below 100 spm is under the study's own moderate floor (the same boundary
  /// [activeHRRFraction] holds on the HR side, ACSM moderate), and above
  /// 130 spm is running, which drives HR over the flex gate and bills there.
  static double? metFromCadenceSpm(double cadenceSpm) {
    if (!cadenceSpm.isFinite || cadenceSpm < 100.0) return null;
    final met = 3.0 + (cadenceSpm - 100.0) * 0.1;
    return met > 6.0 ? 6.0 : met;
  }

  /// [cadenceSpmPerMin], when given, must be index-aligned with [hrPerMin]
  /// (one entry per minute; null = no measured cadence that minute — which is
  /// most minutes: the pedometer that can resolve gait only runs while the
  /// phone holds the live link). It fills the exact gap MOT-02 knowingly
  /// opened: the HR-flex gate refuses everything below the ACSM moderate
  /// floor because Keytel has no fitted data there, so a walk at 95 bpm
  /// added ZERO active kcal for its whole duration. Cadence is the one signal
  /// here that measures walking (MT-05 showed the 1 Hz accel cannot), and
  /// CADENCE-Adults prices it: a minute the HR gate refuses, whose cadence is
  /// at/above the study's own moderate floor, bills (MET − 1) basal-minutes
  /// of surplus via [metFromCadenceSpm]. A minute the HR gate accepts bills
  /// by HR alone — HR sees intensity cadence cannot, and a minute is never
  /// billed twice. The `walking` component of the result is that surplus,
  /// already included in `active`.
  static ({double total, double active, double basal, double walking})?
      dailyEnergy(
    List<double> hrPerMin, {
    required WorkoutUserProfile profile,
    required double hrmax,
    required double restingHr,
    int dayMinutes = 1440,
    List<double?>? cadenceSpmPerMin,
  }) {
    if (cadenceSpmPerMin != null &&
        cadenceSpmPerMin.length != hrPerMin.length) {
      throw ArgumentError(
          'cadenceSpmPerMin (${cadenceSpmPerMin.length}) must align with '
          'hrPerMin (${hrPerMin.length}): one entry per wake minute');
    }
    // (weight/height/age still can't be told apart from their defaults here:
    // WorkoutUserProfile's own constructor bakes 70/170/30 in at construction,
    // so by the time a profile object arrives there is no way left to tell "the
    // caller passed 70kg" from "nobody set a weight". Making those three
    // nullable at the source is the real fix and a bigger change.)
    final weightKg = profile.weightKg > 0 ? profile.weightKg : 70.0;
    final heightCm = profile.heightCm > 0 ? profile.heightCm : 170.0;
    final age = profile.age > 0 ? profile.age : 30.0;
    final coeffs = resolveCoeffs(profile.sex);
    final flexHr = activeGateHr(hrmax, restingHr);
    if (flexHr == null) return null;

    final bmrDay = mifflinBmrKcalDay(weightKg, heightCm, age, profile.sex);
    final basalPerMin = bmrDay / 1440.0;

    var active = 0.0;
    var walking = 0.0;
    for (var i = 0; i < hrPerMin.length; i++) {
      final hr = hrPerMin[i];
      // `hr < flexHr` is false for NaN, so an unfiltered non-finite minute
      // would bill active and carry its NaN into the day total.
      if (hr.isFinite && hr >= flexHr) {
        final activePerMin =
            activeKcalPerS(coeffs, hr, hrmax, weightKg, age) * 60.0;
        final surplus = activePerMin - basalPerMin;
        if (surplus > 0) active += surplus;
        continue; // HR billed the minute — cadence never doubles it.
      }
      // Below flex (or no HR at all — measured gait stands on its own):
      // a measured walking cadence prices the minute the HR gate refused.
      final cad = cadenceSpmPerMin?[i];
      if (cad == null) continue;
      final met = metFromCadenceSpm(cad);
      if (met == null) continue;
      walking += (met - 1.0) * basalPerMin;
    }
    active += walking;
    final basal = basalPerMin * dayMinutes;
    return (
      total: basal + active,
      active: active,
      basal: basal,
      walking: walking,
    );
  }

  /// Estimate (kcal, kJ) for a workout bout. Each sample is weighted by the
  /// ELAPSED time to the next sample (capped at [mergeGapCapS], which defaults
  /// to [defaultMergeGapCapS] = 150 s), so a sparse stream is counted over real
  /// seconds.
  ///
  /// [hrTsSec]/[hrBpm] are the bout's HR samples (timestamps in SECONDS, same
  /// length). [hrmax]/[restingHr] anchors (null OR unusable, see [activeGateHr]
  /// → 220 / 60 fallback, flagged
  /// via [usedDefaultAnchors] on the result so a fabricated-anchor calorie
  /// number can be caveated instead of shown as if it were real).
  static ({double kcal, double kj, bool usedDefaultAnchors})
      estimateBoutCalories(
    List<int> hrTsSec,
    List<double> hrBpm, {
    required WorkoutUserProfile profile,
    double? hrmax,
    double? restingHr,
    double mergeGapCapS = defaultMergeGapCapS,
  }) {
    final weightKg = profile.weightKg > 0 ? profile.weightKg : 70.0;
    final heightCm = profile.heightCm > 0 ? profile.heightCm : 170.0;
    final age = profile.age > 0 ? profile.age : 30.0;
    final coeffs = resolveCoeffs(profile.sex);

    // same caveat as dailyEnergy's usedDefaultHrmax: this only catches
    // hrmax/restingHr, not weight/height/age (WorkoutUserProfile bakes
    // 70/170/30 in at construction, so there's nothing left here to tell
    // "given" from "defaulted" on those three).
    //
    // AN UNUSABLE ANCHOR IS AN ABSENT ANCHOR: non-finite, or a rest that isn't
    // below the ceiling, cannot define a gate ([activeGateHr] returns null), so
    // it takes the SAME documented 220/60 fallback and is flagged like any
    // other missing anchor. Anything else here means a NaN gate, and a NaN gate
    // bills every sample of the bout at the active rate.
    final usedDefaultAnchors = hrmax == null ||
        restingHr == null ||
        activeGateHr(hrmax, restingHr) == null;
    final effHRmax = usedDefaultAnchors ? 220.0 : hrmax;
    final effResting = usedDefaultAnchors ? 60.0 : restingHr;
    final activeThreshold = activeGateHr(effHRmax, effResting)!;

    final restingRate = restingKcalPerS(coeffs, weightKg, heightCm, age);

    // Order by timestamp.
    final idx = List<int>.generate(hrTsSec.length, (i) => i)
      ..sort((a, b) => hrTsSec[a].compareTo(hrTsSec[b]));
    final ts = [for (final i in idx) hrTsSec[i]];
    final bpm = [for (final i in idx) hrBpm[i]];

    var totalKcal = 0.0;
    for (var i = 0; i < ts.length; i++) {
      final b = bpm[i];
      if (!b.isFinite) continue; // `b < threshold` is false for NaN
      final double dur;
      if (i < ts.length - 1) {
        final gap = (ts[i + 1] - ts[i]).toDouble();
        dur = gap > 0 ? math.min(gap, mergeGapCapS) : 1.0;
      } else {
        dur = 1.0; // last sample carries one representative second
      }
      if (b < activeThreshold) {
        totalKcal += restingRate * dur;
      } else {
        totalKcal += activeKcalPerS(coeffs, b, effHRmax, weightKg, age) * dur;
      }
    }
    return (
      kcal: totalKcal,
      kj: totalKcal * 4.184,
      usedDefaultAnchors: usedDefaultAnchors,
    );
  }
}
