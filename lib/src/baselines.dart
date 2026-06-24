// §11 Baselines — rolling 30-day medians feeding everything.
import 'dart:math' as math;
import 'types.dart';
import 'util.dart';

class BaselinesResult {
  final double? resting_hr;
  final double? sleep_need_min;
  final double? skin_temp;
  final double? max_hr;
  final String max_hr_source;
  final double? chronic_strain;
  final List<double>? zone_min;
  final int days_used;
  final double confidence;
  final String tier;
  final List<String> inputs_used;
  const BaselinesResult({
    required this.resting_hr,
    required this.sleep_need_min,
    required this.skin_temp,
    required this.max_hr,
    required this.max_hr_source,
    required this.chronic_strain,
    required this.zone_min,
    required this.days_used,
    required this.confidence,
    required this.tier,
    required this.inputs_used,
  });
  Map<String, dynamic> toJson() => {
        'resting_hr': resting_hr,
        'sleep_need_min': sleep_need_min,
        'skin_temp': skin_temp,
        'max_hr': max_hr,
        'max_hr_source': max_hr_source,
        'chronic_strain': chronic_strain,
        'zone_min': zone_min,
        'days_used': days_used,
        'confidence': confidence,
        'tier': tier,
        'inputs_used': inputs_used,
      };
}

double _meanLocal(List<double> xs) =>
    xs.isNotEmpty ? xs.fold<double>(0, (a, b) => a + b) / xs.length : 0;

BaselinesResult calcBaselines(List<DayHistory> history, [Profile? profile]) {
  final window = history.length > 30
      ? history.sublist(history.length - 30)
      : history;
  final days = window.length;

  final rhrs = window
      .map((d) => d.resting_hr)
      .whereType<double>()
      .toList();
  final sleeps = window
      .map((d) => d.sleep_duration_min)
      .whereType<double>()
      .toList();
  final temps = window.map((d) => d.skin_temp).whereType<double>().toList();
  final strains =
      window.map((d) => d.daily_strain).whereType<double>().toList();

  final rhr = median(rhrs);
  final realNights = sleeps.where((s) => s >= 120).toList();
  final sleepNeedRaw = median(realNights);
  final double? sleepNeed = (realNights.length >= 3 &&
          sleepNeedRaw != null &&
          sleepNeedRaw >= 240)
      ? sleepNeedRaw
      : null;
  final temp = median(temps);
  final double? chronic = strains.isNotEmpty ? _meanLocal(strains) : null;

  final zoneCols = <List<double>>[[], [], [], [], []];
  for (final d in window) {
    if (d.zone_min != null) {
      for (var z = 0; z < 5; z++) {
        zoneCols[z].add(d.zone_min![z]);
      }
    }
  }
  final List<double>? zoneMed = zoneCols.every((c) => c.isNotEmpty)
      ? zoneCols.map((c) => median(c) ?? 0).toList()
      : null;

  final observedMax = window
      .map((d) => d.session_hr_max)
      .whereType<double>()
      .toList();
  final observedPeak =
      observedMax.isNotEmpty ? observedMax.reduce(math.max) : 0.0;
  final double? ageMax = (profile?.age != null && profile!.age! > 0)
      ? jsRound(208 - 0.7 * profile.age!)
      : null;
  double? maxHr;
  String maxHrSource;
  if (ageMax != null) {
    if (observedPeak > ageMax) {
      maxHr = observedPeak;
      maxHrSource = 'measured';
    } else {
      maxHr = ageMax;
      maxHrSource = 'age';
    }
  } else if (observedPeak > 0) {
    maxHr = observedPeak;
    maxHrSource = 'age';
  } else {
    maxHr = null;
    maxHrSource = 'age';
  }

  final confidence = math.min(1.0, days / 30);

  final inputs_used = <String>[];
  if (rhrs.isNotEmpty) inputs_used.add('resting_hr');
  if (sleeps.isNotEmpty) inputs_used.add('sleep_duration_min');
  if (temps.isNotEmpty) inputs_used.add('skin_temp');
  if (strains.isNotEmpty) inputs_used.add('daily_strain');
  if (maxHrSource == 'measured') {
    inputs_used.add('session_hr_max');
  } else if (profile?.age != null && profile!.age! != 0) {
    inputs_used.add('profile.age');
  }

  return BaselinesResult(
    resting_hr: rhr == null ? null : round(rhr, 1),
    sleep_need_min: sleepNeed == null ? null : round(sleepNeed, 0),
    skin_temp: temp == null ? null : round(temp, 2),
    max_hr: maxHr == null ? null : round(maxHr, 0),
    max_hr_source: maxHrSource,
    chronic_strain: chronic == null ? null : round(chronic, 3),
    zone_min: zoneMed,
    days_used: days,
    confidence: round(days == 0 ? 0 : confidence, 4),
    tier: 'HIGH',
    inputs_used: inputs_used,
  );
}
