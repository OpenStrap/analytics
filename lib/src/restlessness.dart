// §Restlessness — nocturnal movement fragmentation from per-minute actigraphy.
import 'dart:math' as math;
import 'types.dart';
import 'util.dart';

class RestlessnessResult {
  final double? score;
  final double restless_min;
  final double movement_bouts;
  final double? mobility_pct;
  final double longest_still_min;
  final double confidence;
  final String tier;
  final List<String> inputs_used;
  final List<Driver>? drivers;
  const RestlessnessResult({
    required this.score,
    required this.restless_min,
    required this.movement_bouts,
    required this.mobility_pct,
    required this.longest_still_min,
    required this.confidence,
    required this.tier,
    required this.inputs_used,
    this.drivers,
  });
  Map<String, dynamic> toJson() {
    final m = <String, dynamic>{
      'score': score,
      'restless_min': restless_min,
      'movement_bouts': movement_bouts,
      'mobility_pct': mobility_pct,
      'longest_still_min': longest_still_min,
      'confidence': confidence,
      'tier': tier,
      'inputs_used': inputs_used,
    };
    if (drivers != null) m['drivers'] = drivers!.map((d) => d.toJson()).toList();
    return m;
  }
}

RestlessnessResult calcRestlessness(List<Minute> sleepMinutes) {
  // TS filters `x.wrist_on !== false && x.activity != null` — all Minutes have
  // both, and wrist_on is bool, so this keeps wrist_on==true minutes (and would
  // keep undefined, but our Minute always has it). Replicate: keep wrist_on true.
  final m = sleepMinutes.where((x) => x.wrist_on != false).toList()
    ..sort((a, b) => a.ts.compareTo(b.ts));
  RestlessnessResult empty() => const RestlessnessResult(
        score: null,
        restless_min: 0,
        movement_bouts: 0,
        mobility_pct: null,
        longest_still_min: 0,
        confidence: 0,
        tier: 'ESTIMATE',
        inputs_used: [],
      );
  if (m.length < 20) return empty();

  final acts = m.map((x) => x.activity).toList();
  final p10 = percentile(acts, 10) ?? 0, p90 = percentile(acts, 90) ?? 0;
  final thresh = p10 + 0.4 * (p90 - p10);

  double restless = 0, bouts = 0, longestStill = 0, curStill = 0;
  bool moving = false;
  for (final x in m) {
    final isMove = x.activity > thresh && x.activity > 0;
    if (isMove) {
      restless++;
      if (!moving) bouts++;
      moving = true;
      if (curStill > longestStill) longestStill = curStill;
      curStill = 0;
    } else {
      moving = false;
      curStill++;
    }
  }
  if (curStill > longestStill) longestStill = curStill;

  final total = m.length;
  final mobility = restless / total;
  final hours = math.max(0.5, total / 60);
  final boutsPerHour = bouts / hours;
  final score = math.max(
      0.0, math.min(100.0, jsRound(boutsPerHour * 6 + mobility * 100 * 0.5)));

  final drivers = <Driver>[
    Driver(
        label: 'Movement bouts',
        contribution: bouts,
        detail: '${bouts.toInt()} shifts (${round(boutsPerHour, 1)}/h)',
        ref: const MetricRef(metric: 'activity', scale: 'day')),
    Driver(
        label: 'Mobility',
        contribution: round(mobility * 100, 1),
        detail: '${restless.toInt()}/$total min moving',
        ref: const MetricRef(metric: 'activity', scale: 'day')),
  ];
  return RestlessnessResult(
    score: score,
    restless_min: restless,
    movement_bouts: bouts,
    mobility_pct: round(mobility, 4),
    longest_still_min: longestStill,
    confidence: round(math.min(1.0, total / 240), 4),
    tier: 'ESTIMATE',
    inputs_used: const ['activity'],
    drivers: drivers,
  );
}
