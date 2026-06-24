// §Fitness — VO2max, Banister fitness/fatigue/form, Foster monotony.
import 'dart:math' as math;
import 'types.dart';
import 'util.dart';

class Vo2MaxResult {
  final double? vo2max;
  final String method;
  final double confidence;
  final String tier;
  final List<String> inputs_used;
  const Vo2MaxResult({
    required this.vo2max,
    required this.method,
    required this.confidence,
    required this.tier,
    required this.inputs_used,
  });
  Map<String, dynamic> toJson() => {
        'vo2max': vo2max,
        'method': method,
        'confidence': confidence,
        'tier': tier,
        'inputs_used': inputs_used,
      };
}

Vo2MaxResult calcVo2Max(double? maxHr, double? restingHr) {
  if (maxHr == null ||
      restingHr == null ||
      restingHr <= 0 ||
      maxHr <= restingHr) {
    return const Vo2MaxResult(
      vo2max: null,
      method: 'Uth–Sørensen',
      confidence: 0,
      tier: 'ESTIMATE',
      inputs_used: [],
    );
  }
  return Vo2MaxResult(
    vo2max: round(15.3 * (maxHr / restingHr), 1),
    method: 'Uth–Sørensen',
    confidence: 0.5,
    tier: 'ESTIMATE',
    inputs_used: const ['baseline.max_hr', 'baseline.resting_hr'],
  );
}

class FitnessModelResult {
  final double? fitness;
  final double? fatigue;
  final double? form;
  final double confidence;
  final String tier;
  final List<String> inputs_used;
  const FitnessModelResult({
    required this.fitness,
    required this.fatigue,
    required this.form,
    required this.confidence,
    required this.tier,
    required this.inputs_used,
  });
  Map<String, dynamic> toJson() => {
        'fitness': fitness,
        'fatigue': fatigue,
        'form': form,
        'confidence': confidence,
        'tier': tier,
        'inputs_used': inputs_used,
      };
}

FitnessModelResult calcFitnessModel(List<DailyStrain> dailyStrain) {
  final sorted = [...dailyStrain]..sort((a, b) => a.ts.compareTo(b.ts));
  final days = sorted.length;
  if (days < 7) {
    return FitnessModelResult(
      fitness: null,
      fatigue: null,
      form: null,
      confidence: round(math.min(1.0, days / 42), 4),
      tier: 'ESTIMATE',
      inputs_used: const ['daily_strain'],
    );
  }
  const aCtl = 2 / (42 + 1), aAtl = 2 / (7 + 1);
  double ctl = sorted[0].strain, atl = sorted[0].strain;
  double prevCtl = ctl, prevAtl = atl;
  for (final d in sorted) {
    prevCtl = ctl;
    prevAtl = atl;
    ctl = ctl + aCtl * (d.strain - ctl);
    atl = atl + aAtl * (d.strain - atl);
  }
  return FitnessModelResult(
    fitness: round(ctl, 2),
    fatigue: round(atl, 2),
    form: round(prevCtl - prevAtl, 2),
    confidence: round(math.min(1.0, days / 42), 4),
    tier: 'ESTIMATE',
    inputs_used: const ['daily_strain'],
  );
}

class MonotonyResult {
  final double? monotony;
  final double? training_strain;
  final double weekly_load;
  final double confidence;
  final String tier;
  final List<String> inputs_used;
  const MonotonyResult({
    required this.monotony,
    required this.training_strain,
    required this.weekly_load,
    required this.confidence,
    required this.tier,
    required this.inputs_used,
  });
  Map<String, dynamic> toJson() => {
        'monotony': monotony,
        'training_strain': training_strain,
        'weekly_load': weekly_load,
        'confidence': confidence,
        'tier': tier,
        'inputs_used': inputs_used,
      };
}

MonotonyResult calcMonotony(List<DailyStrain> dailyStrain) {
  final sortedAll = [...dailyStrain]..sort((a, b) => a.ts.compareTo(b.ts));
  final last7 = (sortedAll.length > 7
          ? sortedAll.sublist(sortedAll.length - 7)
          : sortedAll)
      .map((d) => d.strain)
      .toList();
  final weekly = round(last7.fold<double>(0, (a, b) => a + b), 1);
  if (last7.length < 4) {
    return MonotonyResult(
      monotony: null,
      training_strain: null,
      weekly_load: weekly,
      confidence: round(last7.length / 7, 4),
      tier: 'HIGH',
      inputs_used: const ['daily_strain'],
    );
  }
  final m = mean(last7), sd = stddev(last7);
  final double? monotony = sd > 0 ? m / sd : null;
  return MonotonyResult(
    monotony: monotony == null ? null : round(monotony, 2),
    training_strain: monotony == null ? null : round(weekly * monotony, 1),
    weekly_load: weekly,
    confidence: round(math.min(1.0, last7.length / 7), 4),
    tier: 'HIGH',
    inputs_used: const ['daily_strain'],
  );
}
