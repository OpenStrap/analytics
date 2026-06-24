// §7 Auto-workout detection.
import 'dart:math' as math;
import 'types.dart';
import 'util.dart';
import 'strain.dart';
import 'calories.dart';
import 'zones.dart';
import 'recovery.dart';
import 'har.dart';

class SessionResult {
  final double start_ts;
  final double end_ts;
  final double duration_min;
  final double avg_hr;
  final double max_hr;
  final double strain;
  final double trimp;
  final double kcal;
  final HrZonesResult zones;
  final double? hrr60;
  final double mean_activity;
  final double peak_activity;
  final String type;
  final double type_confidence;
  final List<WorkoutSegment>? segments;
  final String? detected_type;
  final double confidence;
  final String tier;
  final List<String> inputs_used;
  const SessionResult({
    required this.start_ts,
    required this.end_ts,
    required this.duration_min,
    required this.avg_hr,
    required this.max_hr,
    required this.strain,
    required this.trimp,
    required this.kcal,
    required this.zones,
    required this.hrr60,
    required this.mean_activity,
    required this.peak_activity,
    required this.type,
    required this.type_confidence,
    required this.segments,
    required this.detected_type,
    required this.confidence,
    required this.tier,
    required this.inputs_used,
  });
  Map<String, dynamic> toJson() {
    final m = <String, dynamic>{
      'start_ts': start_ts,
      'end_ts': end_ts,
      'duration_min': duration_min,
      'avg_hr': avg_hr,
      'max_hr': max_hr,
      'strain': strain,
      'trimp': trimp,
      'kcal': kcal,
      'zones': zones.toZonesJson(),
      'hrr60': hrr60,
      'mean_activity': mean_activity,
      'peak_activity': peak_activity,
      'type': type,
      'type_confidence': type_confidence,
    };
    if (segments != null) {
      m['segments'] = segments!.map((s) => s.toJson()).toList();
    }
    m['detected_type'] = detected_type;
    m['confidence'] = confidence;
    m['tier'] = tier;
    m['inputs_used'] = inputs_used;
    return m;
  }
}

class _Seg {
  int startIdx;
  int endIdx;
  _Seg(this.startIdx, this.endIdx);
}

List<SessionResult> detectSessions(List<Minute> minutes, Baseline baseline,
    [Profile? profile]) {
  final sorted = [...minutes]..sort((a, b) => a.ts.compareTo(b.ts));
  final worn = sorted.where(isHrUsable).toList();
  if (worn.isEmpty) return [];

  final mh = resolveMaxHr(sorted, baseline, profile);
  final maxHr = mh.maxHr;
  final rhr = baseline.resting_hr!;
  final threshold = rhr + 0.4 * (maxHr - rhr);
  final dailyMedianAct = median(sorted.map((m) => m.activity).toList()) ?? 0;

  bool above(Minute m) => isHrUsable(m) && m.hr_avg >= threshold;

  final segs = <_Seg>[];
  var i = 0;
  while (i < worn.length) {
    if (!above(worn[i])) {
      i++;
      continue;
    }
    var j = i;
    var belowRun = 0;
    var lastAboveIdx = i;
    while (j < worn.length) {
      if (above(worn[j])) {
        belowRun = 0;
        lastAboveIdx = j;
      } else {
        belowRun++;
        if (belowRun >= 3) break;
      }
      j++;
    }
    segs.add(_Seg(i, lastAboveIdx));
    i = lastAboveIdx + 1;
  }

  final qualified = segs.where((s) {
    final slice = worn.sublist(s.startIdx, s.endIdx + 1);
    if (slice.length < 2) return false;
    final meanAct = mean(slice.map((m) => m.activity).toList());
    return meanAct > dailyMedianAct;
  }).toList();

  final merged = <_Seg>[];
  for (final s in qualified) {
    if (merged.isEmpty) {
      merged.add(_Seg(s.startIdx, s.endIdx));
      continue;
    }
    final prev = merged[merged.length - 1];
    final gapMin = (worn[s.startIdx].ts - worn[prev.endIdx].ts) / 60;
    if (gapMin < 5) {
      prev.endIdx = s.endIdx;
    } else {
      merged.add(_Seg(s.startIdx, s.endIdx));
    }
  }

  final out = <SessionResult>[];
  for (final s in merged) {
    final slice = worn.sublist(s.startIdx, s.endIdx + 1);
    final durationMin =
        (slice[slice.length - 1].ts - slice[0].ts) / 60 + 1;
    if (durationMin < 2) continue;

    final hrs = slice.map((m) => m.hr_avg).toList();
    final avgHr = mean(hrs);
    final maxHrSeen = slice.map((m) => m.hr_max).reduce(math.max);
    final acts = slice.map((m) => m.activity).toList();
    final meanAct = mean(acts);
    final peakAct = acts.reduce(math.max);

    final strain = calcStrain(slice, baseline, profile);
    final cals = calcCalories(
        slice, profile ?? const Profile(), baseline.resting_hr, maxHr);
    final zones = calcHrZones(slice, baseline, profile);
    final hrr = calcHrRecovery(slice, baseline, profile);

    final votes = slice
        .where((m) => m.act_class != null)
        .map((m) => ClassVote(m.ts, m.act_class!, 1))
        .toList();
    String type;
    double typeConf;
    List<WorkoutSegment>? segments;
    if (votes.length >= 2) {
      final seg = segmentWorkout(votes, minPhaseSec: 120);
      type = seg.primary;
      typeConf = math.min(0.75, math.max(0.4, seg.type_confidence));
      segments = seg.segments.length > 1 ? seg.segments : null;
    } else {
      type = _classifyType(meanAct, dailyMedianAct, avgHr, rhr, maxHr);
      typeConf = 0.4;
    }

    out.add(SessionResult(
      start_ts: slice[0].ts,
      end_ts: slice[slice.length - 1].ts,
      duration_min: round(durationMin, 0),
      avg_hr: round(avgHr, 1),
      max_hr: round(maxHrSeen, 1),
      strain: strain.score,
      trimp: strain.trimp,
      kcal: cals.kcal,
      zones: zones,
      hrr60: hrr.hrr60,
      mean_activity: round(meanAct, 4),
      peak_activity: round(peakAct, 4),
      type: type,
      type_confidence: round(typeConf, 2),
      segments: segments,
      detected_type: type,
      confidence: 0.8,
      tier: 'HIGH',
      inputs_used: const [
        'hr_avg',
        'hr_max',
        'activity',
        'baseline.resting_hr'
      ],
    ));
  }

  return out;
}

String _classifyType(double meanAct, double dailyMedianAct, double avgHr,
    double rhr, double maxHr) {
  final reserve = maxHr - rhr;
  final hrReservePct = reserve > 0 ? (avgHr - rhr) / reserve : 0;
  final highActivity = meanAct > dailyMedianAct * 2;
  if (highActivity && hrReservePct >= 0.6) return 'run/cardio';
  if (!highActivity && hrReservePct >= 0.6) return 'strength/other';
  return 'walk';
}
