// Deterministic synthetic day for the per-minute energy tests: no randomness,
// no clock. Mixes every case dailyEnergy distinguishes — resting HR, HR over
// the flex gate, dropped (0) and non-finite HR, cadence on sub-flex minutes,
// cadence on HR-billed minutes, cadence on no-HR minutes.

import 'package:openstrap_analytics/src/onehz/workout/calories.dart';

class EnergyDay {
  final List<double> hr;
  final List<double?> cadence;
  const EnergyDay(this.hr, this.cadence);
}

/// [n] minutes. Same LCG as the rest of the suite's synthetic data.
EnergyDay energyDay({int n = 1440, int seed = 4242}) {
  var s = seed;
  double rnd() {
    s = (s * 1103515245 + 12345) & 0x7fffffff;
    return s / 0x7fffffff;
  }

  final hr = <double>[];
  final cad = <double?>[];
  for (var i = 0; i < n; i++) {
    final r = rnd();
    double h;
    if (r < 0.05) {
      h = 0.0; // off-skin sentinel
    } else if (r < 0.07) {
      h = double.nan;
    } else if (r < 0.60) {
      h = 52.0 + rnd() * 40.0; // resting / light, mostly under the gate
    } else {
      h = 100.0 + rnd() * 75.0; // straddles the gate, tops out near hrmax
    }
    hr.add(h);
    final c = rnd();
    if (c < 0.15) {
      cad.add(90.0 + rnd() * 60.0); // below, inside and past the 100-130 range
    } else if (c < 0.17) {
      cad.add(double.nan);
    } else {
      cad.add(null);
    }
  }
  return EnergyDay(hr, cad);
}

const energyProfiles = <String, WorkoutUserProfile>{
  'male': WorkoutUserProfile(
      weightKg: 82.5, heightCm: 181.0, age: 34, sex: 'male'),
  'female': WorkoutUserProfile(
      weightKg: 61.0, heightCm: 167.0, age: 41, sex: 'female'),
  'nonbinary': WorkoutUserProfile(
      weightKg: 70.0, heightCm: 172.5, age: 29, sex: 'nonbinary'),
};
