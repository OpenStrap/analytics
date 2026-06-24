// §8 HR recovery (HRR60) + §Recovery — nocturnal-HRV recovery (Plews 2013).
import 'dart:math' as math;
import 'types.dart';
import 'util.dart';

class RecoveryResult {
  final double? score;
  final double? rmssd;
  final double? baseline_rmssd;
  final double? z;
  final String note;
  final double confidence;
  final String tier;
  final List<String> inputs_used;
  final List<Driver>? drivers;
  const RecoveryResult({
    required this.score,
    required this.rmssd,
    required this.baseline_rmssd,
    required this.z,
    required this.note,
    required this.confidence,
    required this.tier,
    required this.inputs_used,
    this.drivers,
  });
  Map<String, dynamic> toJson() {
    final m = <String, dynamic>{
      'score': score,
      'rmssd': rmssd,
      'baseline_rmssd': baseline_rmssd,
      'z': z,
      'note': note,
      'confidence': confidence,
      'tier': tier,
      'inputs_used': inputs_used,
    };
    if (drivers != null) m['drivers'] = drivers!.map((d) => d.toJson()).toList();
    return m;
  }
}

RecoveryResult calcRecovery(double? rmssdToday, List<double> baselineRmssd,
    {String? date}) {
  const note = 'HRV-based';
  final usableBaseline = baselineRmssd.where((x) => x > 0).toList();
  RecoveryResult none() => RecoveryResult(
        score: null,
        rmssd: rmssdToday,
        baseline_rmssd: null,
        z: null,
        note: note,
        confidence: 0,
        tier: 'HIGH',
        inputs_used: const ['hrv_rmssd'],
      );
  if (rmssdToday == null || rmssdToday <= 0 || usableBaseline.length < 5) {
    return none();
  }

  final lnBase = usableBaseline.map((x) => math.log(x)).toList();
  final m = mean(lnBase);
  final sd = stddev(lnBase);
  final baseRmssd = math.exp(m);
  if (sd <= 0) {
    return RecoveryResult(
      score: null,
      rmssd: round(rmssdToday, 1),
      baseline_rmssd: round(baseRmssd, 1),
      z: null,
      note: note,
      confidence: 0.2,
      tier: 'HIGH',
      inputs_used: const ['hrv_rmssd'],
    );
  }
  final z = (math.log(rmssdToday) - m) / sd;
  final score = math.max(0.0, math.min(100.0, jsRound(50 + 25 * z)));
  final ref = MetricRef(metric: 'hrv', date: date, scale: 'day');
  final drivers = <Driver>[
    Driver(
      label: 'Nocturnal HRV (RMSSD)',
      contribution: round(25 * z, 1),
      detail: '${round(rmssdToday, 0)} ms vs baseline ${round(baseRmssd, 0)} ms',
      ref: ref,
    ),
  ];
  final confidence = math.min(1.0, usableBaseline.length / 21);
  return RecoveryResult(
    score: score,
    rmssd: round(rmssdToday, 1),
    baseline_rmssd: round(baseRmssd, 1),
    z: round(z, 2),
    note: note,
    confidence: round(confidence, 4),
    tier: 'HIGH',
    inputs_used: const ['hrv_rmssd', 'baseline.hrv_rmssd'],
    drivers: drivers,
  );
}

class HrRecoveryResult {
  final double? hrr60;
  final double? peak_hr;
  final double confidence;
  final String tier;
  final List<String> inputs_used;
  const HrRecoveryResult({
    required this.hrr60,
    required this.peak_hr,
    required this.confidence,
    required this.tier,
    required this.inputs_used,
  });
  Map<String, dynamic> toJson() => {
        'hrr60': hrr60,
        'peak_hr': peak_hr,
        'confidence': confidence,
        'tier': tier,
        'inputs_used': inputs_used,
      };
}

HrRecoveryResult calcHrRecovery(List<Minute> sessionMinutes, Baseline baseline,
    [Profile? profile]) {
  final sorted = [...sessionMinutes]..sort((a, b) => a.ts.compareTo(b.ts));
  final worn = sorted.where(isHrUsable).toList();

  HrRecoveryResult none() => const HrRecoveryResult(
        hrr60: null,
        peak_hr: null,
        confidence: 0,
        tier: 'HIGH',
        inputs_used: ['hr_max', 'hr_avg'],
      );
  if (worn.isEmpty) return none();

  final mh = resolveMaxHr(sorted, baseline, profile);
  final maxHr = mh.maxHr;
  final rhr = baseline.resting_hr!;
  final threshold = rhr + 0.4 * (maxHr - rhr);

  int peakIdxInSorted = -1;
  double peakVal = double.negativeInfinity;
  for (var i = 0; i < sorted.length; i++) {
    if (!isHrUsable(sorted[i])) continue;
    if (sorted[i].hr_max > peakVal) {
      peakVal = sorted[i].hr_max;
      peakIdxInSorted = i;
    }
  }

  if (peakIdxInSorted < 0 || peakVal < threshold) return none();

  final peakTs = sorted[peakIdxInSorted].ts;
  Minute? after;
  for (var i = peakIdxInSorted + 1; i < sorted.length; i++) {
    if (!isHrUsable(sorted[i])) continue;
    final dt = sorted[i].ts - peakTs;
    if (dt >= 45 && dt <= 90) {
      after = sorted[i];
      break;
    }
    if (dt > 90) break;
  }
  if (after == null) return none();

  final hrr60 = peakVal - after.hr_avg;
  return HrRecoveryResult(
    hrr60: round(hrr60, 1),
    peak_hr: round(peakVal, 1),
    confidence: 0.7,
    tier: 'HIGH',
    inputs_used: const ['hr_max', 'hr_avg', 'baseline.resting_hr'],
  );
}
