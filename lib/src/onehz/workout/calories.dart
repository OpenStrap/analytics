// Per-bout calorie estimation (calories.py / WorkoutDetector.swift).
//
// HR-based: Keytel et al. 2005 active EE (kJ/min from HR, weight, age, sex) +
// revised Harris–Benedict BMR for the resting floor. Sex-specific coefficients
// (male / female / nonbinary). APPROXIMATE — not laboratory calorimetry, not
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

  // Keytel's SECOND published active model, which adds a VO2max term. It is
  // the more accurate of the pair: fitness is what decides how much energy a
  // given heart rate represents, because a higher VO2max means a greater
  // stroke volume, so the same beat moves more oxygen. The age/mass/sex-only
  // model above has to bake in the derivation cohort's mean fitness instead,
  // which is why it reads high for untrained people and low for athletes.
  //
  // Used only when the caller supplies a VO2max; every entry point keeps the
  // original model as its fallback so an absent fitness anchor changes nothing.
  final double fitAlpha;
  final double fitAge;
  final double fitWeight;
  final double fitVo2max;
  final double fitHR;

  const CalorieCoeffs({
    required this.restingAlpha,
    required this.restingWeight,
    required this.restingHeight,
    required this.restingAge,
    required this.workoutHR,
    required this.workoutWeight,
    required this.workoutAge,
    required this.workoutAlpha,
    required this.fitAlpha,
    required this.fitAge,
    required this.fitWeight,
    required this.fitVo2max,
    required this.fitHR,
  });
}

/// HR-based calorie estimation (Keytel 2005 active + revised Harris–Benedict BMR).
class Calories {
  // fitAlpha folds Keytel's shared -59.3954 intercept together with the
  // male-only -36.3781 term, so each block carries one flat intercept.
  static const CalorieCoeffs male = CalorieCoeffs(
    restingAlpha: 88.362,
    restingWeight: 13.397,
    restingHeight: 479.9,
    restingAge: 5.677,
    workoutHR: 0.6309,
    workoutWeight: 0.1988,
    workoutAge: 0.2017,
    workoutAlpha: -55.0969,
    fitAlpha: -95.7735, // -59.3954 - 36.3781
    fitAge: 0.271,
    fitWeight: 0.394,
    fitVo2max: 0.404,
    fitHR: 0.634,
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
    fitAlpha: -59.3954,
    fitAge: 0.274,
    fitWeight: 0.103,
    fitVo2max: 0.380,
    fitHR: 0.450,
  );
  static const CalorieCoeffs nonbinary = CalorieCoeffs(
    restingAlpha: 267.9775,
    restingWeight: 11.322,
    restingHeight: 394.85,
    restingAge: 5.0035,
    workoutHR: 0.53905,
    workoutWeight: 0.03625,
    workoutAge: 0.13785,
    workoutAlpha: -37.74955,
    fitAlpha: -77.58445,
    fitAge: 0.2725,
    fitWeight: 0.2485,
    fitVo2max: 0.392,
    fitHR: 0.542,
  );

  /// Bout active gate: a sample burns the Keytel active rate above
  /// resting + this fraction of HRR, else the resting BMR rate.
  static const double activeHRRFraction = 0.30;

  /// Plausibility bounds on a supplied VO2max, in mL/kg/min.
  ///
  /// The fitness term is a bare multiplication, so nothing in the regression
  /// stops an absurd input from producing an absurd answer: 1e6 through a
  /// 10-minute bout yields ~965,000 kcal. The value that reaches here is not
  /// measured — the usual source is a resting-HR ratio estimate, which inherits
  /// every artifact in the resting HR it divides by. A single bad night at
  /// 30 bpm against a 200 bpm HRmax reads as ~102, and unit confusion (L/min
  /// rather than mL/kg/min) fails the same way in the other direction.
  ///
  /// [minVo2max] is below the lowest value seen in severely deconditioned
  /// adults and [maxVo2max] above the highest recorded in elite endurance
  /// athletes, so anything outside is a data error rather than a person.
  /// Such a value is REJECTED, not clamped: it carries no information about
  /// this user's fitness, and the age/mass/sex model is the honest answer when
  /// the fitness anchor is unusable. Values inside the range but outside
  /// Keytel's derivation cohort (~25-65) are still used — that is ordinary
  /// extrapolation of a published linear model, not a broken input.
  static const double minVo2max = 10.0;
  static const double maxVo2max = 95.0;

  /// Whether [vo2max] is usable as the fitness term. Absent, non-finite, or
  /// outside [minVo2max]..[maxVo2max] ⇒ the age/mass/sex model runs instead.
  static bool usableVo2max(double? vo2max) =>
      vo2max != null &&
      vo2max.isFinite &&
      vo2max >= minVo2max &&
      vo2max <= maxVo2max;

  /// 60 s/min × 4.184 kJ/kcal.
  static const double workoutDivisor = 251.04;

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
  ///
  /// With a usable [vo2max], uses Keytel's fitness-adjusted model (see
  /// [CalorieCoeffs.fitAlpha]); without one, the age/mass/sex model, unchanged.
  /// "Usable" is [usableVo2max]: absent, non-finite, or physiologically
  /// impossible values fall back rather than entering the regression. 0 is this
  /// package's "not measured" shape, not a real reading.
  static double activeKcalPerS(
      CalorieCoeffs c, double hr, double hrmax, double weightKg, double age,
      {double? vo2max}) {
    final cappedHr = math.min(hr, hrmax);
    final double eeKjMin;
    if (usableVo2max(vo2max)) {
      eeKjMin = c.fitAlpha +
          c.fitAge * age +
          c.fitWeight * weightKg +
          c.fitVo2max * vo2max! +
          c.fitHR * cappedHr;
    } else {
      eeKjMin = c.workoutHR * cappedHr +
          c.workoutWeight * weightKg +
          c.workoutAge * age +
          c.workoutAlpha;
    }
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
  /// [activeFraction] is the HR-flex point as a fraction of HRmax (default 0.50,
  /// matching the edge pipeline): minutes below it burn BMR only, so a quiet day
  /// reads ≈ basal and Keytel's low-HR over-estimate can't inflate "active".
  /// [dayMinutes] lets a partial day pro-rate basal (default 1440 = full day).
  static ({
    double total,
    double active,
    double basal,
    bool usedDefaultHrmax,
    bool usedFitnessModel,
  }) dailyEnergy(
    List<double> hrPerMin, {
    required WorkoutUserProfile profile,
    double? hrmax,
    double activeFraction = 0.50,
    int dayMinutes = 1440,
    double? vo2max,
  }) {
    // the 220-age hrmax fallback used to just silently apply with nothing
    // telling the caller it wasnt a real anchor. usedDefaultHrmax lets the
    // UI caveat the number instead of showing it as if it were solid.
    // (note: this can only catch hrmax - WorkoutUserProfile's own
    // constructor already defaults weight/height/age to 70/170/30, so by
    // the time a profile object gets here there's no way left to tell "the
    // caller passed 70kg" from "nobody set a weight so it's 70kg". if that
    // ever needs catching too, WorkoutUserProfile's fields need to become
    // nullable at the source - bigger change, not doing it here.)
    final weightKg = profile.weightKg > 0 ? profile.weightKg : 70.0;
    final heightCm = profile.heightCm > 0 ? profile.heightCm : 170.0;
    final age = profile.age > 0 ? profile.age : 30.0;
    final coeffs = resolveCoeffs(profile.sex);
    final effHRmax = hrmax ?? (220.0 - age);
    final flexHr = activeFraction * effHRmax;

    final bmrDay = mifflinBmrKcalDay(weightKg, heightCm, age, profile.sex);
    final basalPerMin = bmrDay / 1440.0;

    var active = 0.0;
    for (final hr in hrPerMin) {
      if (hr < flexHr) continue; // below flex point → basal only
      final activePerMin =
          activeKcalPerS(coeffs, hr, effHRmax, weightKg, age, vo2max: vo2max) *
              60.0;
      final surplus = activePerMin - basalPerMin;
      if (surplus > 0) active += surplus;
    }
    final basal = basalPerMin * dayMinutes;
    return (
      total: basal + active,
      active: active,
      basal: basal,
      usedDefaultHrmax: hrmax == null,
      // Which of Keytel's two published models priced the active term. Same
      // reason usedDefaultHrmax exists: a caller comparing two days, or a user
      // asking why a number moved, cannot otherwise tell that the fitness
      // anchor was supplied and then silently rejected as implausible.
      usedFitnessModel: usableVo2max(vo2max),
    );
  }

  /// Estimate (kcal, kJ) for a workout bout. Each sample is weighted by the
  /// ELAPSED time to the next sample (capped at [mergeGapCapS] = mergeGapS, 150 s),
  /// so a sparse stream is counted over real seconds.
  ///
  /// [hrTsSec]/[hrBpm] are the bout's HR samples (timestamps in SECONDS, same
  /// length). [hrmax]/[restingHr] anchors (null → 220 / 60 fallback, flagged
  /// via [usedDefaultAnchors] on the result so a fabricated-anchor calorie
  /// number can be caveated instead of shown as if it were real).
  static ({
    double kcal,
    double kj,
    bool usedDefaultAnchors,
    bool usedFitnessModel,
  }) estimateBoutCalories(
    List<int> hrTsSec,
    List<double> hrBpm, {
    required WorkoutUserProfile profile,
    double? hrmax,
    double? restingHr,
    double mergeGapCapS = 150.0,
    double? vo2max,
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
        totalKcal +=
            activeKcalPerS(coeffs, b, effHRmax, weightKg, age, vo2max: vo2max) *
                dur;
      }
    }
    return (
      kcal: totalKcal,
      kj: totalKcal * 4.184,
      usedDefaultAnchors: usedDefaultAnchors,
      usedFitnessModel: usableVo2max(vo2max),
    );
  }
}
