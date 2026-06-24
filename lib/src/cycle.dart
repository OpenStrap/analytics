// cycle.ts — menstrual cycle estimation (log-anchored + calendar method).
import 'dart:math' as math;
import 'util.dart';

const _dayMs = 86400000;

int _toMs(String d) =>
    DateTime.parse('${d}T00:00:00Z').millisecondsSinceEpoch;
String _toDate(int ms) {
  final dt = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
  // ISO yyyy-MM-dd
  final y = dt.year.toString().padLeft(4, '0');
  final mo = dt.month.toString().padLeft(2, '0');
  final da = dt.day.toString().padLeft(2, '0');
  return '$y-$mo-$da';
}

int _daysBetween(String a, String b) =>
    ((_toMs(b) - _toMs(a)) / _dayMs).round();

// CyclePhase = 'menstruation' | 'follicular' | 'ovulation' | 'luteal' | 'unknown'

class CycleResult {
  final double? cycle_day;
  final String phase;
  final double? mean_length;
  final List<double> length_history;
  final String? last_start;
  final String? predicted_next;
  final double? days_until_next;
  final String? ovulation_est;
  final String? fertile_start;
  final String? fertile_end;
  final String note;
  final double confidence;
  final String tier;
  final List<String> inputs_used;
  const CycleResult({
    required this.cycle_day,
    required this.phase,
    required this.mean_length,
    required this.length_history,
    required this.last_start,
    required this.predicted_next,
    required this.days_until_next,
    required this.ovulation_est,
    required this.fertile_start,
    required this.fertile_end,
    required this.note,
    required this.confidence,
    required this.tier,
    required this.inputs_used,
  });
  Map<String, dynamic> toJson() => {
        'cycle_day': cycle_day,
        'phase': phase,
        'mean_length': mean_length,
        'length_history': length_history,
        'last_start': last_start,
        'predicted_next': predicted_next,
        'days_until_next': days_until_next,
        'ovulation_est': ovulation_est,
        'fertile_start': fertile_start,
        'fertile_end': fertile_end,
        'note': note,
        'confidence': confidence,
        'tier': tier,
        'inputs_used': inputs_used,
      };
}

const _defaultLen = 28;
const _luteal = 14;
const _menses = 5;

final _dateRe = RegExp(r'^\d{4}-\d{2}-\d{2}$');

CycleResult calcCycle(List<String> startsRaw, String today) {
  CycleResult empty(String note) => CycleResult(
        cycle_day: null,
        phase: 'unknown',
        mean_length: null,
        length_history: const [],
        last_start: null,
        predicted_next: null,
        days_until_next: null,
        ovulation_est: null,
        fertile_start: null,
        fertile_end: null,
        note: note,
        confidence: 0,
        tier: 'ESTIMATE',
        inputs_used: const ['period_log'],
      );

  final starts = startsRaw.toSet().toList()
    ..removeWhere((d) => !_dateRe.hasMatch(d) || _toMs(d) > _toMs(today));
  starts.sort();
  if (starts.isEmpty) {
    return empty('Log a period to start tracking your cycle.');
  }

  final lengths = <double>[];
  for (var i = 1; i < starts.length; i++) {
    final len = _daysBetween(starts[i - 1], starts[i]);
    if (len >= 15 && len <= 60) lengths.add(len.toDouble());
  }
  final med = lengths.isNotEmpty ? median(lengths) : null;
  final double? meanLen = med == null ? null : jsRound(med);
  final useLen = (meanLen ?? _defaultLen).toInt();

  final last = starts[starts.length - 1];
  final cycleDay = _daysBetween(last, today) + 1;

  final nextMs = _toMs(last) + useLen * _dayMs;
  final predictedNext = _toDate(nextMs);
  final daysUntil = _daysBetween(today, predictedNext);
  final ovMs = nextMs - _luteal * _dayMs;
  final ovulation = _toDate(ovMs);
  final fertileStart = _toDate(ovMs - 5 * _dayMs);
  final fertileEnd = _toDate(ovMs + 1 * _dayMs);

  final todayMs = _toMs(today);
  String phase;
  if (cycleDay <= _menses) {
    phase = 'menstruation';
  } else if (todayMs >= _toMs(fertileStart) && todayMs <= _toMs(fertileEnd)) {
    phase = 'ovulation';
  } else if (todayMs < ovMs) {
    phase = 'follicular';
  } else {
    phase = 'luteal';
  }

  double conf = lengths.isEmpty
      ? 0.3
      : math.min(0.9, 0.4 + 0.15 * lengths.length);
  if (cycleDay > useLen * 1.6) {
    phase = 'unknown';
    conf = math.min(conf, 0.2);
  }

  return CycleResult(
    cycle_day: cycleDay.toDouble(),
    phase: phase,
    mean_length: meanLen,
    length_history: lengths,
    last_start: last,
    predicted_next: predictedNext,
    days_until_next: daysUntil.toDouble(),
    ovulation_est: ovulation,
    fertile_start: fertileStart,
    fertile_end: fertileEnd,
    note: lengths.isEmpty
        ? 'Based on one logged period and a 28-day default — accuracy improves as you log more.'
        : 'Based on ${lengths.length + 1} logged periods (median $useLen-day cycle).',
    confidence: conf,
    tier: 'ESTIMATE',
    inputs_used: const ['period_log'],
  );
}
