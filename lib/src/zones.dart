// §3 HR zones — minutes per %HRmax band. Tier HIGH.
import 'dart:math' as math;
import 'types.dart';
import 'util.dart';

class HrZonesResult {
  final double zone1_min;
  final double zone2_min;
  final double zone3_min;
  final double zone4_min;
  final double zone5_min;
  final double max_hr_used;
  final String max_hr_source;
  final double confidence;
  final String tier;
  final List<String> inputs_used;
  const HrZonesResult({
    required this.zone1_min,
    required this.zone2_min,
    required this.zone3_min,
    required this.zone4_min,
    required this.zone5_min,
    required this.max_hr_used,
    required this.max_hr_source,
    required this.confidence,
    required this.tier,
    required this.inputs_used,
  });
  // Plain zones object (without metric meta) used inside SessionValue.
  Map<String, dynamic> toZonesJson() => {
        'zone1_min': zone1_min,
        'zone2_min': zone2_min,
        'zone3_min': zone3_min,
        'zone4_min': zone4_min,
        'zone5_min': zone5_min,
        'max_hr_used': max_hr_used,
        'max_hr_source': max_hr_source,
      };
  Map<String, dynamic> toJson() => {
        ...toZonesJson(),
        'confidence': confidence,
        'tier': tier,
        'inputs_used': inputs_used,
      };
}

HrZonesResult calcHrZones(List<Minute> minutes, Baseline baseline,
    [Profile? profile]) {
  final mh = resolveMaxHr(minutes, baseline, profile);
  final maxHr = mh.maxHr;
  final source = mh.source;
  final worn = minutes.where(isHrUsable).toList();

  final z = [0.0, 0.0, 0.0, 0.0, 0.0];
  for (final m in worn) {
    final pct = (m.hr_avg / maxHr) * 100;
    if (pct >= 50 && pct < 60) {
      z[0]++;
    } else if (pct >= 60 && pct < 70) {
      z[1]++;
    } else if (pct >= 70 && pct < 80) {
      z[2]++;
    } else if (pct >= 80 && pct < 90) {
      z[3]++;
    } else if (pct >= 90) {
      z[4]++;
    }
  }

  final base = source == 'measured' ? 0.85 : 0.6;
  final coverage = math.min(1.0, worn.length / 30);
  final confidence = base * coverage;

  return HrZonesResult(
    zone1_min: z[0],
    zone2_min: z[1],
    zone3_min: z[2],
    zone4_min: z[3],
    zone5_min: z[4],
    max_hr_used: maxHr,
    max_hr_source: source,
    confidence: round(confidence, 4),
    tier: 'HIGH',
    inputs_used: source == 'measured'
        ? const ['hr_avg', 'baseline.max_hr']
        : const ['hr_avg', 'profile.age'],
  );
}
