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
// workout divisor (60 s/min × 4.184 kJ/kcal), the 0.30 active-HRR bout gate, and
// the elapsed-time-per-sample weighting (capped at mergeGapS = 150 s) are copied
// verbatim from WorkoutDetector.swift. Pure, dart:math only.

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

  /// Bout active gate: a sample burns the Keytel active rate above
  /// resting + this fraction of HRR, else the resting BMR rate.
  static const double activeHRRFraction = 0.30;

  /// THE HR-FLEX POINT for [dailyEnergy], as a fraction of HRmax.
  ///
  /// RAISED 0.50 → 0.65 on 2026-08-17 (audit MOT-02). This number decides which
  /// waking minutes get billed the Keytel rate at all, and 0.50 put it at
  /// 0.50 × 187 = 93.5 bpm for a 30 y/o — a heart rate a person reaches by
  /// standing up. Keytel's regression is fitted on STEADY-STATE SUBMAXIMAL
  /// EXERCISE with chest/ECG HR; below the exercise domain there is no HR↔EE
  /// slope to extrapolate along (that absence is the entire premise of the
  /// HR-FLEX method this function cites — Spurr 1988 / Ceesay 1989 assign
  /// resting EE below flex and an INDIVIDUALLY CALIBRATED line above it). Ours
  /// is a population line, so the gate has to sit where that line is at least
  /// approximately true. 0.65 × HRmax is the ACSM moderate-intensity floor
  /// (64 % HRmax ≈ 40 % HRR) — the published boundary below which movement is
  /// not counted as exercise at all, and the region Keytel's submaximal
  /// exercise protocol does not sample. It is a choice, not a number Keytel
  /// prints; what Keytel prints is a regression with no resting arm.
  ///
  /// MEASURED CONSEQUENCE, whoop-4.db, 9 days, 70 kg/170 cm/30 y male stand-in,
  /// Tanaka HRmax 187: billed minutes 39.4 % → 4.9 % of the wake window; daily
  /// ACTIVE energy min/median/max 769/1,955/4,062 → 9/48/1,917 kcal; daily
  /// TOTAL 1,544–5,582 → 793–3,437 kcal. Quiet days lose essentially all their
  /// "active" energy, which is the correction: they never earned it. Real
  /// sessions keep most of theirs (a 103-min-above-50 %-HRR day: 3,462 → 1,202).
  ///
  /// This is still a point estimate with no error band, deliberately: Keytel
  /// publishes a POPULATION MAPE, which is not this user's error distribution,
  /// and drawing bounds around the number would claim we computed them.
  static const double defaultActiveFraction = 0.65;

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
  /// [activeFraction] is the HR-flex point as a fraction of HRmax
  /// ([defaultActiveFraction] = 0.65 — read its doc before moving it, it is the
  /// single number that decides what "active" means): minutes below it burn BMR
  /// only, so a quiet day reads ≈ basal and Keytel's low-HR extrapolation can't
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
  static ({double total, double active, double basal}) dailyEnergy(
    List<double> hrPerMin, {
    required WorkoutUserProfile profile,
    required double hrmax,
    double activeFraction = defaultActiveFraction,
    int dayMinutes = 1440,
  }) {
    // (weight/height/age still can't be told apart from their defaults here:
    // WorkoutUserProfile's own constructor bakes 70/170/30 in at construction,
    // so by the time a profile object arrives there is no way left to tell "the
    // caller passed 70kg" from "nobody set a weight". Making those three
    // nullable at the source is the real fix and a bigger change.)
    final weightKg = profile.weightKg > 0 ? profile.weightKg : 70.0;
    final heightCm = profile.heightCm > 0 ? profile.heightCm : 170.0;
    final age = profile.age > 0 ? profile.age : 30.0;
    final coeffs = resolveCoeffs(profile.sex);
    final flexHr = activeFraction * hrmax;

    final bmrDay = mifflinBmrKcalDay(weightKg, heightCm, age, profile.sex);
    final basalPerMin = bmrDay / 1440.0;

    var active = 0.0;
    for (final hr in hrPerMin) {
      if (hr < flexHr) continue; // below flex point → basal only
      final activePerMin =
          activeKcalPerS(coeffs, hr, hrmax, weightKg, age) * 60.0;
      final surplus = activePerMin - basalPerMin;
      if (surplus > 0) active += surplus;
    }
    final basal = basalPerMin * dayMinutes;
    return (total: basal + active, active: active, basal: basal);
  }

  /// Estimate (kcal, kJ) for a workout bout. Each sample is weighted by the
  /// ELAPSED time to the next sample (capped at [mergeGapCapS], which defaults
  /// to [defaultMergeGapCapS] = 150 s), so a sparse stream is counted over real
  /// seconds.
  ///
  /// [hrTsSec]/[hrBpm] are the bout's HR samples (timestamps in SECONDS, same
  /// length). [hrmax]/[restingHr] anchors (null → 220 / 60 fallback, flagged
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
    final usedDefaultAnchors = hrmax == null || restingHr == null;
    final effHRmax = hrmax ?? 220.0;
    final effResting = restingHr ?? 60.0;
    final activeThreshold =
        effResting + activeHRRFraction * (effHRmax - effResting);

    final restingRate = restingKcalPerS(coeffs, weightKg, heightCm, age);

    // Order by timestamp.
    final idx = List<int>.generate(hrTsSec.length, (i) => i)
      ..sort((a, b) => hrTsSec[a].compareTo(hrTsSec[b]));
    final ts = [for (final i in idx) hrTsSec[i]];
    final bpm = [for (final i in idx) hrBpm[i]];

    var totalKcal = 0.0;
    for (var i = 0; i < ts.length; i++) {
      final b = bpm[i];
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
