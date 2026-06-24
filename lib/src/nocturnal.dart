// §13 Nocturnal Heart.
import 'types.dart';
import 'util.dart';

class NocturnalResult {
  final double? sleeping_hr_avg;
  final double? sleeping_hr_min;
  final double? nadir_ts;
  final double? day_hr_avg;
  final double? dip_pct;
  final double? vs_baseline_bpm;
  final bool elevated;
  final double confidence;
  final String tier;
  final List<String> inputs_used;
  const NocturnalResult({
    required this.sleeping_hr_avg,
    required this.sleeping_hr_min,
    required this.nadir_ts,
    required this.day_hr_avg,
    required this.dip_pct,
    required this.vs_baseline_bpm,
    required this.elevated,
    required this.confidence,
    required this.tier,
    required this.inputs_used,
  });
  Map<String, dynamic> toJson() => {
        'sleeping_hr_avg': sleeping_hr_avg,
        'sleeping_hr_min': sleeping_hr_min,
        'nadir_ts': nadir_ts,
        'day_hr_avg': day_hr_avg,
        'dip_pct': dip_pct,
        'vs_baseline_bpm': vs_baseline_bpm,
        'elevated': elevated,
        'confidence': confidence,
        'tier': tier,
        'inputs_used': inputs_used,
      };
}

NocturnalResult calcNocturnalHeart(
    List<Minute> sleepMinutes, List<Minute> dayMinutes, Baseline baseline) {
  final sleepHrs = sleepMinutes
      .where((m) => m.wrist_on && m.hr_avg > 0)
      .toList()
    ..sort((a, b) => a.ts.compareTo(b.ts));

  NocturnalResult empty() => const NocturnalResult(
        sleeping_hr_avg: null,
        sleeping_hr_min: null,
        nadir_ts: null,
        day_hr_avg: null,
        dip_pct: null,
        vs_baseline_bpm: null,
        elevated: false,
        confidence: 0,
        tier: 'HIGH',
        inputs_used: [],
      );
  if (sleepHrs.isEmpty) return empty();

  final hrVals = sleepHrs.map((m) => m.hr_avg).toList();
  final sleepingHrAvg = jsRound(mean(hrVals));

  _Nadir? nadir;
  const w = 5;
  if (sleepHrs.length >= w) {
    for (var i = 0; i + w <= sleepHrs.length; i++) {
      final win = sleepHrs.sublist(i, i + w);
      final m = mean(win.map((x) => x.hr_avg).toList());
      if (nadir == null || m < nadir.v) {
        nadir = _Nadir(sleepHrs[i + (w ~/ 2)].ts, m);
      }
    }
  } else {
    final lo = sleepHrs.reduce((p, c) => c.hr_avg < p.hr_avg ? c : p);
    nadir = _Nadir(lo.ts, lo.hr_avg);
  }

  final dayHr = dayMinutes
      .where((m) => m.wrist_on && m.hr_avg > 0)
      .map((m) => m.hr_avg)
      .toList();
  final double? dayHrAvg = dayHr.isNotEmpty ? jsRound(mean(dayHr)) : null;
  final double? dipPct = (dayHrAvg != null && dayHrAvg > 0)
      ? jsRound(clamp((dayHrAvg - sleepingHrAvg) / dayHrAvg, 0, 1) * 1000) / 1000
      : null;

  final double? baseSleepHr =
      (baseline.sleeping_hr != null && baseline.sleeping_hr! > 0)
          ? baseline.sleeping_hr
          : null;
  final double? vsBaseline = baseSleepHr != null
      ? jsRound((sleepingHrAvg - baseSleepHr) * 10) / 10
      : null;
  final elevated = baseSleepHr != null &&
      sleepingHrAvg >= baseSleepHr + 4 &&
      sleepingHrAvg >= baseSleepHr * 1.05;

  final coverage = clamp(sleepHrs.length / 180, 0, 1);

  return NocturnalResult(
    sleeping_hr_avg: sleepingHrAvg,
    sleeping_hr_min: nadir != null ? jsRound(nadir.v) : null,
    nadir_ts: nadir?.ts,
    day_hr_avg: dayHrAvg,
    dip_pct: dipPct,
    vs_baseline_bpm: vsBaseline,
    elevated: elevated,
    confidence: jsRound(coverage * 1000) / 1000,
    tier: 'HIGH',
    inputs_used: [
      'hr_avg',
      'sleep.onset_ts',
      'sleep.wake_ts',
      if (baseSleepHr != null) 'baseline.sleeping_hr',
    ],
  );
}

class _Nadir {
  final double ts;
  final double v;
  _Nadir(this.ts, this.v);
}
