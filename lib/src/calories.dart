// §4 Active Calories — Keytel kcal/min ABOVE resting. Tier ESTIMATE.
import 'dart:math' as math;
import 'types.dart';
import 'util.dart';

class CaloriesResult {
  final double kcal;
  final String label;
  final double confidence;
  final String tier;
  final List<String> inputs_used;
  const CaloriesResult({
    required this.kcal,
    required this.label,
    required this.confidence,
    required this.tier,
    required this.inputs_used,
  });
  Map<String, dynamic> toJson() => {
        'kcal': kcal,
        'label': label,
        'confidence': confidence,
        'tier': tier,
        'inputs_used': inputs_used,
      };
}

CaloriesResult calcCalories(
  List<Minute> minutes,
  Profile profile, [
  double? restingHr,
  double? maxHr,
]) {
  final worn = minutes.where(isHrUsable).toList();
  final age = profile.age ?? 30;
  final w = profile.weight_kg ?? 70;

  double perMin(double hr) {
    final male = (-55.0969 + 0.6309 * hr + 0.1988 * w + 0.2017 * age) / 4.184;
    final female = (-20.4022 + 0.4472 * hr - 0.1263 * w + 0.074 * age) / 4.184;
    if (profile.sex == 'm') return male;
    if (profile.sex == 'f') return female;
    return (male + female) / 2;
  }

  final restRef = (restingHr != null && restingHr > 0)
      ? restingHr
      : (percentile(worn.map((m) => m.hr_avg).toList(), 5) ?? 50);
  final restPerMin = perMin(restRef);

  final activeFloor = (maxHr != null && maxHr > restRef) ? 0.5 * maxHr : restRef;

  double kcal = 0;
  for (final m in worn) {
    if (m.hr_avg < activeFloor) continue;
    kcal += math.max(0, perMin(m.hr_avg) - restPerMin);
  }

  final inputs_used = <String>['hr_avg'];
  if (restingHr != null && restingHr > 0) {
    inputs_used.add('baseline.resting_hr');
  }
  if (profile.age != null) inputs_used.add('profile.age');
  if (profile.weight_kg != null) inputs_used.add('profile.weight_kg');
  if (profile.sex != null) inputs_used.add('profile.sex');

  final coverage = math.min(1.0, worn.length / 30);
  final confidence = 0.5 * coverage;

  return CaloriesResult(
    kcal: round(kcal, 1),
    label: '≈ active kcal (est.)',
    confidence: round(confidence, 4),
    tier: 'ESTIMATE',
    inputs_used: inputs_used,
  );
}
