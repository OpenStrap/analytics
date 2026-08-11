// Keytel 2005 publishes TWO active-EE models. The one this package shipped
// reads age, body mass and sex; the other adds VO2max and is the more accurate
// of the pair, because fitness is what decides how much energy a given heart
// rate actually represents — a trained athlete at 140 bpm is moving far more
// oxygen than an untrained person at 140 bpm.
//
// The fitness-adjusted model (as published, in kJ/min):
//   male:   -59.3954 - 36.3781 + 0.271*age + 0.394*wt + 0.404*VO2max + 0.634*HR
//   female: -59.3954          + 0.274*age + 0.103*wt + 0.380*VO2max + 0.450*HR
//
// VO2max is OPTIONAL everywhere. Absent, every caller gets exactly the numbers
// it got before — this must not silently move calories for anyone whose
// fitness anchor cannot be estimated.
//
// Expected values below are computed by hand from those two equations so the
// test pins the published arithmetic rather than the implementation.

import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

const _male = WorkoutUserProfile(
  weightKg: 72,
  heightCm: 178,
  age: 34,
  sex: 'male',
);
const _female = WorkoutUserProfile(
  weightKg: 72,
  heightCm: 178,
  age: 34,
  sex: 'female',
);
const _nonbinary = WorkoutUserProfile(
  weightKg: 72,
  heightCm: 178,
  age: 34,
  sex: 'nonbinary',
);

// Tanaka HRmax for 34 y; bout gate = 55 + 0.30*(184.2-55) = 93.76, so the whole
// stream below is active.
const _hrMax = 184.2;
const _restingHr = 55.0;

final _ts = [for (var t = 0; t < 600; t++) t];
final _bpm = [for (var t = 0; t < 600; t++) 140.0];

double _bout(WorkoutUserProfile p, {double? vo2max}) =>
    Calories.estimateBoutCalories(
      _ts,
      _bpm,
      profile: p,
      hrmax: _hrMax,
      restingHr: _restingHr,
      vo2max: vo2max,
    ).kcal;

void main() {
  group('Keytel fitness-adjusted active EE', () {
    test('without a VO2max the published age/mass/sex model is unchanged', () {
      // -55.0969 + 0.6309*140 + 0.1988*72 + 0.2017*34 = 54.4005 kJ/min
      // 54.4005 / 251.04 * 600 s                      = 130.02 kcal
      expect(_bout(_male), closeTo(130.02, 0.05));
    });

    test('an unusable VO2max falls back rather than entering the regression',
        () {
      // The guard rejects on three separate conditions and every one of them
      // has to land on the SAME fallback. VO2max is a strictly positive
      // quantity, so 0 and negatives are "not measured" rather than readings,
      // and a non-finite value would otherwise propagate straight through the
      // linear term and poison the result as NaN/Infinity kcal.
      //
      // Exact equality, not closeTo: a correct fallback runs the identical code
      // path, so anything other than a bit-identical answer means the guard let
      // the value through.
      final baseline = _bout(_male);
      for (final vo2max in <double>[
        0,
        -1,
        -62.5,
        double.nan,
        double.infinity,
        double.negativeInfinity,
      ]) {
        expect(
          _bout(_male, vo2max: vo2max),
          baseline,
          reason: 'vo2max $vo2max must fall back to the age/mass/sex model',
        );
      }
    });

    test('a male bout with a VO2max uses the fitness-adjusted coefficients', () {
      // -95.7735 + 0.271*34 + 0.394*72 + 0.404*50 + 0.634*140 = 50.7685 kJ/min
      // 50.7685 / 251.04 * 600 s                              = 121.34 kcal
      expect(_bout(_male, vo2max: 50), closeTo(121.34, 0.05));
    });

    test('a female bout with a VO2max uses its own coefficient block', () {
      // -59.3954 + 0.274*34 + 0.103*72 + 0.380*50 + 0.450*140 = 39.3366 kJ/min
      // 39.3366 / 251.04 * 600 s                              = 94.02 kcal
      expect(_bout(_female, vo2max: 50), closeTo(94.02, 0.05));
    });

    test('a fitter athlete burns MORE at the same heart rate', () {
      // The whole reason the term is worth threading. Higher VO2max means a
      // greater stroke volume, so the same heart rate moves more oxygen.
      final unfit = _bout(_male, vo2max: 35);
      final mid = _bout(_male, vo2max: 50);
      final fit = _bout(_male, vo2max: 70);

      expect(unfit, lessThan(mid));
      expect(mid, lessThan(fit));
      // -95.7735 + 9.214 + 28.368 + 0.404*70 + 88.76 = 58.8485 kJ/min -> 140.65
      expect(fit, closeTo(140.65, 0.05));
    });

    test('nonbinary stays the mean of the two published blocks', () {
      // Matches how this package already resolves the age/mass/sex model.
      //
      // The equality holds because the model is linear in its coefficients AND
      // both sexes' raw kJ/min are positive here, so no clamp fires. It is NOT
      // a general identity: `max(0.0, eeKjMin)` is applied after the mean block
      // is evaluated, so on a profile extreme enough to drive exactly one sex
      // negative the mean block and the mean of the two results diverge. See
      // the clamp-asymmetry case below.
      expect(
        _bout(_nonbinary, vo2max: 50),
        closeTo((_bout(_male, vo2max: 50) + _bout(_female, vo2max: 50)) / 2, 0.01),
      );
    });

    test('the nonbinary mean is NOT an identity once a clamp fires', () {
      // Pinned so nobody restates the linearity claim as unconditional. The
      // zero floor is applied to each block's own kJ/min, so a profile that
      // drives one sex negative and not the other breaks the equality: the mean
      // block lands under the floor and reads 0 while the mean of the two
      // results does not. Reachable only at a genuinely extreme profile, which
      // is why it is pinned rather than fixed — the alternative is averaging
      // two clamped results, which is not what "the mean coefficient block"
      // means.
      const old = WorkoutUserProfile(
        weightKg: 35,
        heightCm: 150,
        age: 80,
        sex: 'male',
      );
      const oldF = WorkoutUserProfile(
        weightKg: 35,
        heightCm: 150,
        age: 80,
        sex: 'female',
      );
      const oldN = WorkoutUserProfile(
        weightKg: 35,
        heightCm: 150,
        age: 80,
        sex: 'nonbinary',
      );
      final day = <double>[for (var i = 0; i < 600; i++) 76.0];
      double active(WorkoutUserProfile p) =>
          Calories.dailyEnergy(day, profile: p, hrmax: 152.0, vo2max: 15)
              .active;

      expect(active(old), 0.0, reason: 'male block clamps to the floor');
      expect(active(oldF), greaterThan(0.0));
      expect(active(oldN), 0.0, reason: 'the MEAN block also clamps');
      expect(
        active(oldN),
        isNot(closeTo((active(old) + active(oldF)) / 2, 1.0)),
      );
    });

    test('a physiologically impossible VO2max falls back, never scales', () {
      // The guard used to test only the sign and finiteness, so the fitness
      // term was a bare multiplication with no upper bound: 1e6 through this
      // bout returned ~965,000 kcal. The value arriving here is not measured —
      // it is usually a resting-HR ratio estimate, so it inherits every
      // artifact in the resting HR it divides by, and unit confusion (L/min for
      // mL/kg/min) fails the same way at the bottom.
      final baseline = _bout(_male);
      for (final vo2max in <double>[
        1e6,
        1000,
        95.01,
        9.99,
        1e-12,
      ]) {
        expect(
          _bout(_male, vo2max: vo2max),
          baseline,
          reason: 'vo2max $vo2max is not a human and must not price a bout',
        );
      }
      // The bounds themselves are inclusive and DO price the bout.
      expect(_bout(_male, vo2max: Calories.minVo2max), isNot(baseline));
      expect(_bout(_male, vo2max: Calories.maxVo2max), isNot(baseline));
    });

    test('the result says which of the two models priced it', () {
      // Same contract as usedDefaultHrmax/usedDefaultAnchors: a silently
      // rejected fitness anchor is indistinguishable from one that was never
      // supplied unless the result says so.
      double? none;
      expect(
        Calories.estimateBoutCalories(_ts, _bpm,
                profile: _male,
                hrmax: _hrMax,
                restingHr: _restingHr,
                vo2max: none)
            .usedFitnessModel,
        isFalse,
      );
      expect(
        Calories.estimateBoutCalories(_ts, _bpm,
                profile: _male,
                hrmax: _hrMax,
                restingHr: _restingHr,
                vo2max: 1e6)
            .usedFitnessModel,
        isFalse,
        reason: 'rejected as implausible — the caller has to be able to tell',
      );
      expect(
        Calories.estimateBoutCalories(_ts, _bpm,
                profile: _male,
                hrmax: _hrMax,
                restingHr: _restingHr,
                vo2max: 50)
            .usedFitnessModel,
        isTrue,
      );
    });

    test('a bout spent entirely under the gate did not use the fitness model',
        () {
      // The flag reports that the fitness regression PRICED something, not that
      // an anchor was available. Everything below the gate is Harris-Benedict,
      // which has no fitness term in it, so claiming the fitness model for a
      // resting bout credits a calculation that never ran.
      final easy = [for (var t = 0; t < 300; t++) 65.0];
      final bout = Calories.estimateBoutCalories(
        [for (var t = 0; t < 300; t++) t],
        easy,
        profile: _male,
        hrmax: _hrMax,
        restingHr: _restingHr,
        vo2max: 50,
      );
      expect(bout.kcal, greaterThan(0), reason: 'it was still costed');
      expect(bout.usedFitnessModel, isFalse);
    });

    test('a day spent entirely under the flex point reports no fitness model',
        () {
      final quiet = <double>[for (var i = 0; i < 1440; i++) 55.0];
      final e =
          Calories.dailyEnergy(quiet, profile: _male, hrmax: _hrMax, vo2max: 50);
      expect(e.active, 0.0);
      expect(e.usedFitnessModel, isFalse);
    });

    test('resting samples still take the BMR floor, VO2max or not', () {
      // VO2max belongs to the ACTIVE term only. Below the gate the bout bills
      // Harris-Benedict, which has no fitness term at all.
      final easy = [for (var t = 0; t < 300; t++) 65.0];
      final withVo2 = Calories.estimateBoutCalories(
        [for (var t = 0; t < 300; t++) t],
        easy,
        profile: _male,
        hrmax: _hrMax,
        restingHr: _restingHr,
        vo2max: 50,
      );
      final without = Calories.estimateBoutCalories(
        [for (var t = 0; t < 300; t++) t],
        easy,
        profile: _male,
        hrmax: _hrMax,
        restingHr: _restingHr,
      );
      expect(withVo2.kcal, closeTo(without.kcal, 1e-9));
    });
  });

  group('dailyEnergy threads the fitness term', () {
    // 60 min at 140 bpm (above the 0.50*184.2 = 92.1 flex point) + a quiet rest.
    final day = <double>[
      for (var i = 0; i < 60; i++) 140.0,
      for (var i = 0; i < 1380; i++) 55.0,
    ];

    test('active energy moves with VO2max, basal does not', () {
      final base = Calories.dailyEnergy(day, profile: _male, hrmax: _hrMax);
      final fit = Calories.dailyEnergy(
        day,
        profile: _male,
        hrmax: _hrMax,
        vo2max: 70,
      );

      expect(fit.active, greaterThan(base.active));
      expect(
        fit.basal,
        closeTo(base.basal, 1e-9),
        reason: 'Mifflin has no fitness term — only the active surplus moves',
      );
    });

    test('omitting VO2max leaves the daily figures byte-for-byte unchanged', () {
      final a = Calories.dailyEnergy(day, profile: _male, hrmax: _hrMax);
      final b = Calories.dailyEnergy(
        day,
        profile: _male,
        hrmax: _hrMax,
        vo2max: null,
      );
      expect(a.total, b.total);
      expect(a.active, b.active);
    });

    test('an unusable VO2max leaves the daily figures unchanged too', () {
      // Same guard, second entry point. A NaN reaching the active term here
      // would poison a persisted daily total, not just one bout.
      final base = Calories.dailyEnergy(day, profile: _male, hrmax: _hrMax);
      for (final vo2max in <double>[
        0,
        -1,
        double.nan,
        double.infinity,
        double.negativeInfinity,
      ]) {
        final e = Calories.dailyEnergy(
          day,
          profile: _male,
          hrmax: _hrMax,
          vo2max: vo2max,
        );
        expect(e.total, base.total, reason: 'vo2max $vo2max');
        expect(e.active, base.active, reason: 'vo2max $vo2max');
        expect(e.total.isFinite, isTrue);
      }
    });
  });
}
