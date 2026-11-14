import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

import '../support/incremental_compare.dart';
import '../support/incremental_fixtures.dart';

void main() {
  const original =
      WorkoutUserProfile(weightKg: 80, heightCm: 180, age: 40, sex: 'male');
  for (final replacement in [
    const WorkoutUserProfile(weightKg: 95, heightCm: 180, age: 40, sex: 'male'),
    const WorkoutUserProfile(weightKg: 80, heightCm: 160, age: 40, sex: 'male'),
    const WorkoutUserProfile(weightKg: 80, heightCm: 180, age: 60, sex: 'male'),
    const WorkoutUserProfile(
        weightKg: 80, heightCm: 180, age: 40, sex: 'female'),
  ]) {
    test(
        'restored minute profile owns checkpoint ${replacement.weightKg}/'
        '${replacement.heightCm}/${replacement.age}/${replacement.sex}', () {
      final f = incrementalFixture(minutes: 35);
      final originalState = IncrementalMinuteMetrics();
      originalState.sync(f.minuteKeys, f.hr,
          cadenceSpm: f.cadence,
          restingHr: 54,
          maxHr: 186,
          quietHrr: .12,
          profile: original);
      final json = originalState.toJson();
      final restored = IncrementalMinuteMetrics.fromJson(json);
      final parameters = json['parameters'] as List;
      final profile = parameters[3] as List;
      profile.setAll(0, [
        replacement.weightKg,
        replacement.heightCm,
        replacement.age,
        replacement.sex
      ]);
      final work = restored.processedMinutes;
      final actual = restored.sync(f.minuteKeys, f.hr,
          cadenceSpm: f.cadence,
          restingHr: 54,
          maxHr: 186,
          quietHrr: .12,
          profile: replacement);
      minuteClose(actual, f.minuteKeys, f.hr,
          cadence: f.cadence, profile: replacement);
      expect(restored.processedMinutes - work, f.hr.length,
          reason: 'changing profile reprices retained contributions');
    });
  }
}
