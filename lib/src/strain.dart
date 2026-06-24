// §2 Strain — Banister TRIMP over HR reserve, log-scaled to 0..21. Tier HIGH.
import 'dart:math' as math;
import 'types.dart';
import 'util.dart';

class StrainResult {
  final double score;
  final double trimp;
  final double max_hr_used;
  final String max_hr_source;
  final double confidence;
  final String tier;
  final List<String> inputs_used;
  const StrainResult({
    required this.score,
    required this.trimp,
    required this.max_hr_used,
    required this.max_hr_source,
    required this.confidence,
    required this.tier,
    required this.inputs_used,
  });
  Map<String, dynamic> toJson() => {
        'score': score,
        'trimp': trimp,
        'max_hr_used': max_hr_used,
        'max_hr_source': max_hr_source,
        'confidence': confidence,
        'tier': tier,
        'inputs_used': inputs_used,
      };
}

StrainResult calcStrain(List<Minute> minutes, Baseline baseline,
    [Profile? profile]) {
  final mh = resolveMaxHr(minutes, baseline, profile);
  final maxHr = mh.maxHr;
  final source = mh.source;
  final rhr = baseline.resting_hr!;
  final worn = minutes.where(isHrUsable).toList();

  final k = profile?.sex == 'f' ? 0.86 : 0.64;
  final b = profile?.sex == 'f' ? 1.67 : 1.92;
  double trimp = 0;
  final denom = maxHr - rhr;
  for (final m in worn) {
    if (denom <= 0) continue;
    final ratio = clamp((m.hr_avg - rhr) / denom, 0, 1);
    trimp += ratio * k * math.exp(b * ratio);
  }

  final score = math.min(21.0, math.log(trimp + 1) / math.log(1.5));
  final confidence = clamp(worn.length / 30, 0, 1);

  final inputs_used = <String>['hr_avg', 'baseline.resting_hr'];
  inputs_used.add(source == 'measured' ? 'baseline.max_hr' : 'profile.age');

  return StrainResult(
    score: round(score, 2),
    trimp: round(trimp, 4),
    max_hr_used: maxHr,
    max_hr_source: source,
    confidence: round(confidence, 4),
    tier: 'HIGH',
    inputs_used: inputs_used,
  );
}
