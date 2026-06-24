// §1 Resting HR — 5th percentile of HR in the sleep window. Tier HIGH.
import 'dart:math' as math;
import 'types.dart';
import 'util.dart';

class SleepWindow {
  final double? onset_ts;
  final double? wake_ts;
  const SleepWindow({this.onset_ts, this.wake_ts});
}

class RestingHrResult {
  final double? resting_hr;
  final double confidence;
  final String tier;
  final List<String> inputs_used;
  const RestingHrResult({
    required this.resting_hr,
    required this.confidence,
    required this.tier,
    required this.inputs_used,
  });
  Map<String, dynamic> toJson() => {
        'resting_hr': resting_hr,
        'confidence': confidence,
        'tier': tier,
        'inputs_used': inputs_used,
      };
}

RestingHrResult calcRestingHR(List<Minute> minutes, [SleepWindow? sleepWindow]) {
  final hasWindow = sleepWindow != null &&
      sleepWindow.onset_ts != null &&
      sleepWindow.wake_ts != null;

  if (hasWindow) {
    final onset = sleepWindow.onset_ts!;
    final wake = sleepWindow.wake_ts!;
    final inWindow = minutes
        .where((m) => m.ts >= onset && m.ts <= wake && isHrUsable(m))
        .toList();
    final hrs = inWindow.map((m) => m.hr_avg).toList();
    final rhr = percentile(hrs, 5);
    final confidence = clamp(inWindow.length / 240, 0, 1);
    return RestingHrResult(
      resting_hr: rhr == null ? null : round(rhr, 1),
      confidence: round(rhr == null ? 0 : confidence, 4),
      tier: 'HIGH',
      inputs_used: const ['hr_avg', 'sleep_window'],
    );
  }

  final best = _lowestContiguousStretch(minutes, 30);
  if (best == null) {
    return const RestingHrResult(
      resting_hr: null,
      confidence: 0,
      tier: 'HIGH',
      inputs_used: ['hr_avg'],
    );
  }
  final rhr = percentile(best, 5);
  final confidence = math.min(0.5, clamp(best.length / 30, 0, 1) * 0.5);
  return RestingHrResult(
    resting_hr: rhr == null ? null : round(rhr, 1),
    confidence: round(rhr == null ? 0 : confidence, 4),
    tier: 'HIGH',
    inputs_used: const ['hr_avg', 'fallback_30min'],
  );
}

List<double>? _lowestContiguousStretch(List<Minute> minutes, int windowMin) {
  final worn = minutes.where(isHrUsable).toList()
    ..sort((a, b) => a.ts.compareTo(b.ts));
  if (worn.isEmpty) return null;

  const maxGap = 90;
  double bestMean = double.infinity;
  List<double>? bestHrs;

  var runStart = 0;
  for (var i = 1; i <= worn.length; i++) {
    final broken = i == worn.length || worn[i].ts - worn[i - 1].ts > maxGap;
    if (!broken) continue;
    final run = worn.sublist(runStart, i);
    runStart = i;
    if (run.length < windowMin) continue;
    double windowSum = run
        .sublist(0, windowMin)
        .fold<double>(0, (s, x) => s + x.hr_avg);
    for (var j = 0; j + windowMin <= run.length; j++) {
      if (j > 0) {
        windowSum += run[j + windowMin - 1].hr_avg - run[j - 1].hr_avg;
      }
      final m = windowSum / windowMin;
      if (m < bestMean) {
        bestMean = m;
        bestHrs = run
            .sublist(j, j + windowMin)
            .map((s) => s.hr_avg)
            .toList();
      }
    }
  }

  if (bestHrs == null) {
    final lowest = ([...worn]..sort((a, b) => a.hr_avg.compareTo(b.hr_avg)))
        .sublist(0, math.min(windowMin, worn.length))
        .map((m) => m.hr_avg)
        .toList();
    return lowest;
  }
  return bestHrs;
}
