// Shared input/output types for openstrap-analytics (1:1 Dart port).
// JSON output is built to be byte-identical to the TS JSON.stringify of the
// equivalent objects: same keys, same order, nulls preserved, undefined omitted.

/// One minute rollup. `activity` is the actigraphy signal (stddev of |accel(g)|).
class Minute {
  final double ts; // unix seconds at the start of the minute
  final double hr_avg;
  final double hr_min;
  final double hr_max;
  final double hr_n;
  final double activity;
  final double steps;
  final bool wrist_on;
  final String? act_class; // ActivityClass

  const Minute({
    required this.ts,
    required this.hr_avg,
    required this.hr_min,
    required this.hr_max,
    required this.hr_n,
    required this.activity,
    required this.steps,
    required this.wrist_on,
    this.act_class,
  });
}

// ActivityClass: 'sedentary' | 'walk' | 'run' | 'cycle' | 'lift' | 'other'

/// One labelled phase of a workout.
class SessionSegment {
  final double start_ts;
  final double end_ts;
  final String type;
  final double confidence;
  const SessionSegment(this.start_ts, this.end_ts, this.type, this.confidence);
  Map<String, dynamic> toJson() => {
        'start_ts': start_ts,
        'end_ts': end_ts,
        'type': type,
        'confidence': confidence,
      };
}

/// User profile.
class Profile {
  final double? age;
  final double? weight_kg;
  final double? height_cm;
  final String? sex; // 'm' | 'f'
  const Profile({this.age, this.weight_kg, this.height_cm, this.sex});
}

/// Rolling baselines.
class Baseline {
  final double? resting_hr;
  final double? max_hr;
  final double? sleep_need_min;
  final double? skin_temp;
  final double? chronic_strain;
  final double? sleeping_hr; // used by nocturnal/wake (extension field)
  const Baseline({
    this.resting_hr,
    this.max_hr,
    this.sleep_need_min,
    this.skin_temp,
    this.chronic_strain,
    this.sleeping_hr,
  });
}

// Tier = 'AUTH' | 'HIGH' | 'ESTIMATE' | 'RELATIVE'  (kept as String constants)

/// A pointer the UI can navigate to.
class MetricRef {
  final String metric;
  final String? date;
  final String? scale;
  const MetricRef({required this.metric, this.date, this.scale});
  Map<String, dynamic> toJson() {
    final m = <String, dynamic>{'metric': metric};
    if (date != null) m['date'] = date;
    if (scale != null) m['scale'] = scale;
    return m;
  }
}

/// One ranked contributor to a metric's value.
class Driver {
  final String label;
  final double contribution;
  final String? detail;
  final MetricRef? ref;
  const Driver({
    required this.label,
    required this.contribution,
    this.detail,
    this.ref,
  });
  Map<String, dynamic> toJson() {
    final m = <String, dynamic>{'label': label, 'contribution': contribution};
    if (detail != null) m['detail'] = detail;
    if (ref != null) m['ref'] = ref!.toJson();
    return m;
  }
}

/// One night's sleep summary (for SRI).
class NightSummary {
  final double? onset_ts;
  final double? wake_ts;
  const NightSummary({this.onset_ts, this.wake_ts});
}

/// One day of aggregate history.
class DayHistory {
  final double? resting_hr;
  final double? sleep_duration_min;
  final double? skin_temp;
  final double? daily_strain;
  final double? session_hr_max;
  final double? hrr60;
  final List<double>? zone_min;
  const DayHistory({
    this.resting_hr,
    this.sleep_duration_min,
    this.skin_temp,
    this.daily_strain,
    this.session_hr_max,
    this.hrr60,
    this.zone_min,
  });
}

/// Per-day strain entry for ACWR / fitness.
class DailyStrain {
  final double ts;
  final double strain;
  const DailyStrain(this.ts, this.strain);
}

/// SleepStages plain value.
class SleepStages {
  final double light_min;
  final double deep_min;
  final double rem_min;
  const SleepStages(this.light_min, this.deep_min, this.rem_min);
  Map<String, dynamic> toJson() =>
      {'light_min': light_min, 'deep_min': deep_min, 'rem_min': rem_min};
}
