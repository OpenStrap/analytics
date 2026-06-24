// §6 Sleep timing regularity. Tier HIGH (≥3 nights).
import 'dart:math' as math;
import 'types.dart';
import 'util.dart';

const _dayMin = 24 * 60;

double _minuteOfDay(double ts) {
  final totalMin = (ts / 60).floorToDouble();
  return ((totalMin % _dayMin) + _dayMin) % _dayMin;
}

double _circularStdMin(List<double> minutesOfDay) {
  if (minutesOfDay.length < 2) return 0;
  double sumCos = 0;
  double sumSin = 0;
  for (final m in minutesOfDay) {
    final theta = (2 * math.pi * m) / _dayMin;
    sumCos += math.cos(theta);
    sumSin += math.sin(theta);
  }
  final n = minutesOfDay.length;
  final r = math.sqrt(sumCos * sumCos + sumSin * sumSin) / n;
  final rClamped = math.max(1e-9, math.min(1.0, r));
  final sigmaRad = math.sqrt(-2 * math.log(rClamped));
  return sigmaRad * (_dayMin / (2 * math.pi));
}

class SleepRegularityResult {
  final double sri;
  final double onset_std_min;
  final double wake_std_min;
  final double nights_used;
  final double confidence;
  final String tier;
  final List<String> inputs_used;
  const SleepRegularityResult({
    required this.sri,
    required this.onset_std_min,
    required this.wake_std_min,
    required this.nights_used,
    required this.confidence,
    required this.tier,
    required this.inputs_used,
  });
  Map<String, dynamic> toJson() => {
        'sri': sri,
        'onset_std_min': onset_std_min,
        'wake_std_min': wake_std_min,
        'nights_used': nights_used,
        'confidence': confidence,
        'tier': tier,
        'inputs_used': inputs_used,
      };
}

SleepRegularityResult calcSleepRegularity(List<NightSummary> nights) {
  final valid =
      nights.where((nn) => nn.onset_ts != null && nn.wake_ts != null).toList();
  final onsets = valid.map((nn) => _minuteOfDay(nn.onset_ts!)).toList();
  final wakes = valid.map((nn) => _minuteOfDay(nn.wake_ts!)).toList();

  if (valid.length < 3) {
    return SleepRegularityResult(
      sri: 0,
      onset_std_min: 0,
      wake_std_min: 0,
      nights_used: valid.length.toDouble(),
      confidence: 0,
      tier: 'HIGH',
      inputs_used: const ['nights.onset_ts', 'nights.wake_ts'],
    );
  }

  final onsetStd = _circularStdMin(onsets);
  final wakeStd = _circularStdMin(wakes);
  final avgStd = (onsetStd + wakeStd) / 2;
  final sri = math.max(0.0, 100 - (avgStd / 120) * 100);

  return SleepRegularityResult(
    sri: round(sri, 2),
    onset_std_min: round(onsetStd, 2),
    wake_std_min: round(wakeStd, 2),
    nights_used: valid.length.toDouble(),
    confidence: 0.7,
    tier: 'HIGH',
    inputs_used: const ['nights.onset_ts', 'nights.wake_ts'],
  );
}
