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
  /// [activeFraction] is the HR-flex point as a fraction of HRmax (default 0.50,
  /// matching the edge pipeline): minutes below it burn BMR only, so a quiet day
  /// reads ≈ basal and Keytel's low-HR over-estimate can't inflate "active".
  /// [dayMinutes] lets a partial day pro-rate basal (default 1440 = full day).
  static ({double total, double active, double basal}) dailyEnergy(
    List<double> hrPerMin, {
    required WorkoutUserProfile profile,
    double? hrmax,
    double activeFraction = 0.50,
    int dayMinutes = 1440,
  }) {
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
          activeKcalPerS(coeffs, hr, effHRmax, weightKg, age) * 60.0;
      final surplus = activePerMin - basalPerMin;
      if (surplus > 0) active += surplus;
    }
    final basal = basalPerMin * dayMinutes;
    return (total: basal + active, active: active, basal: basal);
  }

  /// Estimate (kcal, kJ) for a workout bout. Each sample is weighted by the
  /// ELAPSED time to the next sample (capped at [mergeGapCapS] = mergeGapS, 150 s),
  /// so a sparse stream is counted over real seconds.
  ///
  /// [hrTsSec]/[hrBpm] are the bout's HR samples (timestamps in SECONDS, same
  /// length). [hrmax]/[restingHr] anchors (null → 220 / 60 fallback).
  static (double kcal, double kj) estimateBoutCalories(
    List<int> hrTsSec,
    List<double> hrBpm, {
    required WorkoutUserProfile profile,
    double? hrmax,
    double? restingHr,
    double mergeGapCapS = 150.0,
  }) {
    final weightKg = profile.weightKg > 0 ? profile.weightKg : 70.0;
    final heightCm = profile.heightCm > 0 ? profile.heightCm : 170.0;
    final age = profile.age > 0 ? profile.age : 30.0;
    final coeffs = resolveCoeffs(profile.sex);

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
            activeKcalPerS(coeffs, b, effHRmax, weightKg, age) * dur;
      }
    }
    return (totalKcal, totalKcal * 4.184);
  }
}
