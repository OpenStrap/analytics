// §Sleep stress / nocturnal arousal.
import 'dart:math' as math;
import 'types.dart';
import 'util.dart';

class SleepStressResult {
  final double? score;
  final double arousal_events;
  final double restless_min;
  final double? mean_sleeping_hr;
  final List<Map<String, dynamic>> events;
  final double confidence;
  final String tier;
  final List<String> inputs_used;
  final List<Driver>? drivers;
  const SleepStressResult({
    required this.score,
    required this.arousal_events,
    required this.restless_min,
    required this.mean_sleeping_hr,
    required this.events,
    required this.confidence,
    required this.tier,
    required this.inputs_used,
    this.drivers,
  });
  Map<String, dynamic> toJson() {
    final m = <String, dynamic>{
      'score': score,
      'arousal_events': arousal_events,
      'restless_min': restless_min,
      'mean_sleeping_hr': mean_sleeping_hr,
      'events': events,
      'confidence': confidence,
      'tier': tier,
      'inputs_used': inputs_used,
    };
    if (drivers != null) m['drivers'] = drivers!.map((d) => d.toJson()).toList();
    return m;
  }
}

SleepStressResult calcSleepStress(List<Minute> sleepMinutes, Baseline baseline) {
  final worn = sleepMinutes.where(isHrUsable).toList()
    ..sort((a, b) => a.ts.compareTo(b.ts));
  SleepStressResult empty() => const SleepStressResult(
        score: null,
        arousal_events: 0,
        restless_min: 0,
        mean_sleeping_hr: null,
        events: [],
        confidence: 0,
        tier: 'ESTIMATE',
        inputs_used: [],
      );
  if (worn.length < 20) return empty();

  final hrs = worn.map((m) => m.hr_avg).toList();
  final meanHr = mean(hrs);
  final sdHr = stddev(hrs);
  final acts = worn.map((m) => m.activity).toList();
  final meanAct = mean(acts);
  final surgeThresh = meanHr + math.max(8, 1.5 * sdHr);

  double arousalEvents = 0;
  double restless = 0;
  final events = <Map<String, dynamic>>[];
  bool inSurge = false;
  for (final m in worn) {
    final moving = m.activity > meanAct && m.activity > 0;
    if (moving) restless++;
    final surge = m.hr_avg >= surgeThresh && moving;
    if (surge && !inSurge) {
      arousalEvents++;
      events.add({'ts': m.ts, 'kind': 'arousal'});
      inSurge = true;
    } else if (!surge) {
      inSurge = false;
      if (moving && m.activity > meanAct * 2 && events.length < 60) {
        events.add({'ts': m.ts, 'kind': 'restless'});
      }
    }
  }

  final hours = math.max(0.5, worn.length / 60);
  final eventsPerHour = arousalEvents / hours;
  final restlessFrac = restless / worn.length;
  final score = math.max(
      0.0,
      math.min(
          100.0, jsRound(eventsPerHour * 12 + restlessFrac * 100 * 0.5)));

  final drivers = <Driver>[
    Driver(
        label: 'Arousal events',
        contribution: arousalEvents,
        detail: '${arousalEvents.toInt()} HR-surge+motion events',
        ref: const MetricRef(metric: 'hr', scale: 'day')),
    Driver(
        label: 'Restlessness',
        contribution: round(restlessFrac * 100, 1),
        detail: '${restless.toInt()} restless min',
        ref: const MetricRef(metric: 'activity', scale: 'day')),
  ];

  final confidence = math.min(1.0, worn.length / 240);
  return SleepStressResult(
    score: score,
    arousal_events: arousalEvents,
    restless_min: restless,
    mean_sleeping_hr: round(meanHr, 0),
    events: events,
    confidence: round(confidence, 4),
    tier: 'ESTIMATE',
    inputs_used: const ['hr_avg', 'activity'],
    drivers: drivers,
  );
}
