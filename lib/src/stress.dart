// §Stress — HRV-based (Baevsky SI + LF/HF, personal-relative).
import 'dart:math' as math;
import 'types.dart';
import 'util.dart';
import 'hrv.dart';

class StressResult {
  final double? score;
  final double? si;
  final double? lf_hf;
  final double? rmssd;
  final String? level;
  final double confidence;
  final String tier;
  final List<String> inputs_used;
  final List<Driver>? drivers;
  const StressResult({
    required this.score,
    required this.si,
    required this.lf_hf,
    required this.rmssd,
    required this.level,
    required this.confidence,
    required this.tier,
    required this.inputs_used,
    this.drivers,
  });
  Map<String, dynamic> toJson() {
    final m = <String, dynamic>{
      'score': score,
      'si': si,
      'lf_hf': lf_hf,
      'rmssd': rmssd,
      'level': level,
      'confidence': confidence,
      'tier': tier,
      'inputs_used': inputs_used,
    };
    if (drivers != null) m['drivers'] = drivers!.map((d) => d.toJson()).toList();
    return m;
  }
}

StressResult calcStress(List<double> rr, List<double> baselineSI,
    {String? date}) {
  final si = baevskyStressIndex(rr);
  final td = timeDomainHrv(rr);
  final fd = freqDomainHrv(rr);

  StressResult none() => StressResult(
        score: null,
        si: si.si,
        lf_hf: fd.lf_hf,
        rmssd: td.rmssd,
        level: null,
        confidence: 0,
        tier: 'ESTIMATE',
        inputs_used: const [],
      );
  if (si.si == null) return none();

  final usableBase = baselineSI.where((x) => x > 0).toList();
  final ref = MetricRef(metric: 'hrv', date: date, scale: 'day');
  final drivers = <Driver>[
    Driver(
        label: 'Baevsky Stress Index',
        contribution: round(si.si!, 1),
        detail: 'SI ${si.si}',
        ref: ref),
  ];
  if (fd.lf_hf != null) {
    drivers.add(Driver(
        label: 'Sympatho-vagal balance (LF/HF)',
        contribution: round(fd.lf_hf!, 2),
        detail: 'LF/HF ${fd.lf_hf}',
        ref: ref));
  }
  if (td.rmssd != null) {
    drivers.add(Driver(
        label: 'HRV (RMSSD)',
        contribution: round(-(td.rmssd!), 1),
        detail: '${td.rmssd} ms',
        ref: ref));
  }

  if (usableBase.length < 5) {
    return StressResult(
      score: null,
      si: si.si,
      lf_hf: fd.lf_hf,
      rmssd: td.rmssd,
      level: null,
      confidence: round(math.min(0.4, si.n_beats / 300), 4),
      tier: 'ESTIMATE',
      inputs_used: const ['hrv_si', 'hrv_lf_hf'],
      drivers: drivers,
    );
  }

  final lnBase = usableBase.map((x) => math.log(x)).toList();
  final m = mean(lnBase);
  final sd = stddev(lnBase);
  double? score;
  if (sd > 0) {
    final z = (math.log(si.si!) - m) / sd;
    score = math.max(0.0, math.min(100.0, jsRound(50 + 25 * z)));
  }
  final String? level = score == null
      ? null
      : score < 40
          ? 'low'
          : score <= 70
              ? 'moderate'
              : 'elevated';
  final confidence =
      math.min(1.0, usableBase.length / 21) * math.min(1.0, si.n_beats / 300);

  return StressResult(
    score: score,
    si: si.si,
    lf_hf: fd.lf_hf,
    rmssd: td.rmssd,
    level: level,
    confidence: round(confidence, 4),
    tier: 'ESTIMATE',
    inputs_used: const ['hrv_si', 'hrv_lf_hf', 'baseline.hrv_si'],
    drivers: drivers,
  );
}
