// §5 Sleep — Cole-Kripke actigraphy + HR-dip fusion.
import 'dart:math' as math;
import 'types.dart';
import 'util.dart';
import 'hrv.dart';

const List<double> _ckW = [1.06, 0.54, 0.58, 0.76, 2.3, 0.74, 0.67];

double? _minuteRmssd(List<double>? rr) {
  if (rr == null || rr.length < 12) return null;
  final c = cleanRr(rr);
  if (c.length < 10) return null;
  double s = 0;
  for (var i = 1; i < c.length; i++) {
    final d = c[i] - c[i - 1];
    s += d * d;
  }
  return math.sqrt(s / (c.length - 1));
}

double? _medOfNullable(List<double?> xs) {
  final a = xs.whereType<double>().where((x) => x.isFinite).toList()..sort();
  return a.isNotEmpty ? a[a.length >> 1] : null;
}

const _remRmssdFactor = 0.90;

class SleepResult {
  final double? onset_ts;
  final double? wake_ts;
  final double duration_min;
  final double in_bed_min;
  final double efficiency;
  final SleepStages? stages;
  final bool stages_beta;
  final double confidence;
  final String tier;
  final List<String> inputs_used;
  const SleepResult({
    required this.onset_ts,
    required this.wake_ts,
    required this.duration_min,
    required this.in_bed_min,
    required this.efficiency,
    required this.stages,
    required this.stages_beta,
    required this.confidence,
    required this.tier,
    required this.inputs_used,
  });
  Map<String, dynamic> toJson() => {
        'onset_ts': onset_ts,
        'wake_ts': wake_ts,
        'duration_min': duration_min,
        'in_bed_min': in_bed_min,
        'efficiency': efficiency,
        'stages': stages?.toJson(),
        'stages_beta': stages_beta,
        'confidence': confidence,
        'tier': tier,
        'inputs_used': inputs_used,
      };
}

SleepResult calcSleep(List<Minute> minutes, Baseline baseline) {
  final sorted = [...minutes]..sort((a, b) => a.ts.compareTo(b.ts));
  final n = sorted.length;

  SleepResult empty() => const SleepResult(
        onset_ts: null,
        wake_ts: null,
        duration_min: 0,
        in_bed_min: 0,
        efficiency: 0,
        stages: null,
        stages_beta: true,
        confidence: 0,
        tier: 'HIGH',
        inputs_used: [],
      );
  if (n == 0) return empty();

  final rhr = baseline.resting_hr;
  if (rhr == null || rhr <= 0) return empty();

  final wornHr = sorted
      .where((m) => m.wrist_on && m.hr_avg > 0)
      .map((m) => m.hr_avg)
      .toList()
    ..sort();
  double pctl(double p) => wornHr.isNotEmpty
      ? wornHr[math.min(wornHr.length - 1, (p * wornHr.length).floor())]
      : rhr;
  final sleepHr = math.max(rhr, pctl(0.10));
  const asleepHi = 1.05;
  const awakeHi = 1.20;
  const absWake = 1.5;

  final asleep = List<bool>.filled(n, false);
  for (var i = 0; i < n; i++) {
    double s = 0;
    for (var k = 0; k < _ckW.length; k++) {
      final off = k - 4;
      final idx = i + off;
      if (idx >= 0 && idx < n) s += _ckW[k] * sorted[idx].activity;
    }
    s *= 0.001;
    final m = sorted[i];
    if (!m.wrist_on) {
      asleep[i] = false;
      continue;
    }
    bool isAsleep = s < 1;
    if (m.hr_avg > 0) {
      if (m.hr_avg > absWake * rhr) {
        isAsleep = false;
      } else if (m.hr_avg <= asleepHi * sleepHr) {
        isAsleep = true;
      } else if (m.hr_avg > awakeHi * sleepHr) {
        isAsleep = false;
      }
    }
    asleep[i] = isAsleep;
  }

  const maxGapMin = 20;

  var bestStart = -1;
  var bestEnd = -1;
  var bestAsleep = 0;
  var periodFirst = -1;
  var periodLast = -1;
  var periodAsleep = 0;
  var gap = 0;

  void closePeriod() {
    if (periodFirst >= 0 && periodAsleep > bestAsleep) {
      bestAsleep = periodAsleep;
      bestStart = periodFirst;
      bestEnd = periodLast;
    }
    periodFirst = -1;
    periodLast = -1;
    periodAsleep = 0;
    gap = 0;
  }

  for (var i = 0; i < n; i++) {
    if (asleep[i]) {
      if (periodFirst < 0) periodFirst = i;
      periodLast = i;
      periodAsleep++;
      gap = 0;
    } else if (periodFirst >= 0) {
      if (++gap > maxGapMin) closePeriod();
    }
  }
  closePeriod();

  if (bestStart < 0 || bestAsleep == 0) return empty();

  var startIdx = bestStart;
  var endIdx = bestEnd;

  const maxSleepMin = 14 * 60;
  if (endIdx - startIdx + 1 > maxSleepMin) {
    for (final tighter in [10, 5, 2]) {
      var bs = -1, be = -1, ba = 0;
      var pf = -1, pl = -1, pa = 0, g = 0;
      void close() {
        if (pf >= 0 && pa > ba) {
          ba = pa;
          bs = pf;
          be = pl;
        }
        pf = -1;
        pl = -1;
        pa = 0;
        g = 0;
      }

      for (var i = 0; i < n; i++) {
        if (asleep[i]) {
          if (pf < 0) pf = i;
          pl = i;
          pa++;
          g = 0;
        } else if (pf >= 0) {
          if (++g > tighter) close();
        }
      }
      close();
      if (bs >= 0 && be - bs + 1 <= maxSleepMin) {
        startIdx = bs;
        endIdx = be;
        break;
      }
      if (bs >= 0) {
        startIdx = bs;
        endIdx = be;
      }
    }
    if (endIdx - startIdx + 1 > maxSleepMin) {
      endIdx = startIdx + maxSleepMin - 1;
    }
  }

  final onsetTs = sorted[startIdx].ts;
  final wakeTs = sorted[endIdx].ts;

  final inBedEpochs = sorted.sublist(startIdx, endIdx + 1);
  final inBedMin = inBedEpochs.length;
  double durationMin = 0;
  for (var i = startIdx; i <= endIdx; i++) {
    if (asleep[i]) durationMin++;
  }
  final efficiency = inBedMin > 0 ? durationMin / inBedMin : 0.0;

  final sleepEpochs = <Minute>[];
  for (var i = 0; i < inBedEpochs.length; i++) {
    if (asleep[startIdx + i]) sleepEpochs.add(inBedEpochs[i]);
  }
  final stages = _estimateStages(sleepEpochs, rhr);

  final hasHr = inBedEpochs.any((m) => m.wrist_on && m.hr_avg > 0);
  final hasActivity = inBedEpochs.any((m) => m.activity > 0);
  final hasTemp = baseline.skin_temp != null;
  final present = [hasHr, hasActivity, hasTemp].where((b) => b).length;
  final inputCompleteness = present / 3;
  final coverage = math.min(1.0, inBedMin / 240);
  final confidence = inputCompleteness * coverage;

  final inputs_used = <String>['activity'];
  if (hasHr) inputs_used.add('hr_avg');
  if (hasTemp) inputs_used.add('baseline.skin_temp');

  return SleepResult(
    onset_ts: onsetTs,
    wake_ts: wakeTs,
    duration_min: durationMin,
    in_bed_min: inBedMin.toDouble(),
    efficiency: round(efficiency, 4),
    stages: stages,
    stages_beta: true,
    confidence: round(confidence, 4),
    tier: 'HIGH',
    inputs_used: inputs_used,
  );
}

class SleepPeriod {
  final double onset_ts;
  final double wake_ts;
  final double duration_min;
  final double in_bed_min;
  final double efficiency;
  final SleepStages? stages;
  bool is_main;
  final double confidence;
  SleepPeriod({
    required this.onset_ts,
    required this.wake_ts,
    required this.duration_min,
    required this.in_bed_min,
    required this.efficiency,
    required this.stages,
    required this.is_main,
    required this.confidence,
  });
  Map<String, dynamic> toJson() => {
        'onset_ts': onset_ts,
        'wake_ts': wake_ts,
        'duration_min': duration_min,
        'in_bed_min': in_bed_min,
        'efficiency': efficiency,
        'stages': stages?.toJson(),
        'is_main': is_main,
        'confidence': confidence,
      };
}

class SleepPeriodsResult {
  final List<SleepPeriod> periods;
  final double total_asleep_min;
  final int? main_idx;
  final bool stages_beta;
  final double confidence;
  final String tier;
  final List<String> inputs_used;
  const SleepPeriodsResult({
    required this.periods,
    required this.total_asleep_min,
    required this.main_idx,
    required this.stages_beta,
    required this.confidence,
    required this.tier,
    required this.inputs_used,
  });
  Map<String, dynamic> toJson() => {
        'periods': periods.map((p) => p.toJson()).toList(),
        'total_asleep_min': total_asleep_min,
        'main_idx': main_idx,
        'stages_beta': stages_beta,
        'confidence': confidence,
        'tier': tier,
        'inputs_used': inputs_used,
      };
}

SleepPeriodsResult calcSleepPeriods(List<Minute> minutes, Baseline baseline) {
  final sorted = [...minutes]..sort((a, b) => a.ts.compareTo(b.ts));
  final n = sorted.length;
  final rhr = baseline.resting_hr;

  SleepPeriodsResult empty() => const SleepPeriodsResult(
        periods: [],
        total_asleep_min: 0,
        main_idx: null,
        stages_beta: true,
        confidence: 0,
        tier: 'HIGH',
        inputs_used: [],
      );
  if (n == 0) return empty();
  if (rhr == null || rhr <= 0) return empty();

  final asleep = List<bool>.filled(n, false);
  for (var i = 0; i < n; i++) {
    double s = 0;
    for (var k = 0; k < _ckW.length; k++) {
      final off = k - 4;
      final idx = i + off;
      if (idx >= 0 && idx < n) s += _ckW[k] * sorted[idx].activity;
    }
    s *= 0.001;
    final m = sorted[i];
    if (!m.wrist_on) {
      asleep[i] = false;
      continue;
    }
    bool isAsleep = s < 1;
    if (m.hr_avg > 0) {
      if (m.hr_avg < 0.95 * rhr) {
        isAsleep = true;
      } else if (m.hr_avg > 1.15 * rhr) {
        isAsleep = false;
      }
    }
    asleep[i] = isAsleep;
  }

  const maxGapMin = 20;
  const maxSleepMin = 14 * 60;
  const minPeriodMin = 15;

  final raw = <List<int>>[]; // [start, end, asleepN]
  var pf = -1, pl = -1, pa = 0, gap = 0;
  void close() {
    if (pf >= 0 && pa > 0) raw.add([pf, pl, pa]);
    pf = -1;
    pl = -1;
    pa = 0;
    gap = 0;
  }

  for (var i = 0; i < n; i++) {
    if (asleep[i]) {
      if (pf < 0) pf = i;
      pl = i;
      pa++;
      gap = 0;
    } else if (pf >= 0) {
      if (++gap > maxGapMin) close();
    }
  }
  close();

  final periods = <SleepPeriod>[];
  for (final p in raw) {
    var startIdx = p[0];
    var endIdx = p[1];
    if (endIdx - startIdx + 1 > maxSleepMin) {
      endIdx = startIdx + maxSleepMin - 1;
    }

    final span = sorted.sublist(startIdx, endIdx + 1);
    final inBedMin = span.length;
    double durationMin = 0;
    for (var i = startIdx; i <= endIdx; i++) {
      if (asleep[i]) durationMin++;
    }
    if (durationMin < minPeriodMin) continue;

    final efficiency = inBedMin > 0 ? durationMin / inBedMin : 0.0;
    final sleepEpochs = <Minute>[];
    for (var i = 0; i < span.length; i++) {
      if (asleep[startIdx + i]) sleepEpochs.add(span[i]);
    }
    final stages = _estimateStages(sleepEpochs, rhr);

    final hasHr = span.any((m) => m.wrist_on && m.hr_avg > 0);
    final hasActivity = span.any((m) => m.activity > 0);
    final hasTemp = baseline.skin_temp != null;
    final inputCompleteness =
        [hasHr, hasActivity, hasTemp].where((b) => b).length / 3;
    final coverage = math.min(1.0, inBedMin / 90);

    periods.add(SleepPeriod(
      onset_ts: sorted[startIdx].ts,
      wake_ts: sorted[endIdx].ts,
      duration_min: durationMin,
      in_bed_min: inBedMin.toDouble(),
      efficiency: round(efficiency, 4),
      stages: stages,
      is_main: false,
      confidence: round(inputCompleteness * coverage, 4),
    ));
  }

  if (periods.isEmpty) return empty();

  var mainIdx = 0;
  for (var i = 1; i < periods.length; i++) {
    if (periods[i].duration_min > periods[mainIdx].duration_min) mainIdx = i;
  }
  periods[mainIdx].is_main = true;

  final totalAsleepMin =
      periods.fold<double>(0, (a, p) => a + p.duration_min);

  final inputs_used = <String>['activity'];
  if (sorted.any((m) => m.wrist_on && m.hr_avg > 0)) inputs_used.add('hr_avg');
  if (baseline.skin_temp != null) inputs_used.add('baseline.skin_temp');

  return SleepPeriodsResult(
    periods: periods,
    total_asleep_min: totalAsleepMin,
    main_idx: mainIdx,
    stages_beta: true,
    confidence: periods[mainIdx].confidence,
    tier: 'HIGH',
    inputs_used: inputs_used,
  );
}

Map<double, bool> sleepAwakeMask(List<Minute> minutes, Baseline baseline,
    [Map<double, List<double>>? rrByMin]) {
  final out = <double, bool>{};
  final rhr = baseline.resting_hr;
  if (rhr == null || rhr <= 0) return out;
  final sorted = [...minutes]..sort((a, b) => a.ts.compareTo(b.ts));
  final n = sorted.length;

  List<double?> rms = [];
  double? remCut;
  if (rrByMin != null && rrByMin.isNotEmpty) {
    final rawRm = sorted.map((m) => _minuteRmssd(rrByMin[m.ts])).toList();
    rms = List<double?>.generate(
        rawRm.length,
        (i) => _medOfNullable(
            rawRm.sublist(math.max(0, i - 2), math.min(n, i + 3))));
    final asleepRms = List<double?>.generate(
        sorted.length, (i) => sorted[i].hr_avg > 0 ? rms[i] : null);
    final med = _medOfNullable(asleepRms);
    if (med != null) remCut = _remRmssdFactor * med;
  }

  for (var i = 0; i < n; i++) {
    double s = 0;
    for (var k = 0; k < _ckW.length; k++) {
      final idx = i + (k - 4);
      if (idx >= 0 && idx < n) s += _ckW[k] * sorted[idx].activity;
    }
    s *= 0.001;
    final m = sorted[i];
    if (!m.wrist_on) {
      out[m.ts] = false;
      continue;
    }
    bool isAsleep = s < 1;
    if (m.hr_avg > 0) {
      if (m.hr_avg < 0.95 * rhr) {
        isAsleep = true;
      } else if (m.hr_avg > 1.15 * rhr) {
        final remLike =
            remCut != null && rms.isNotEmpty && rms[i] != null && rms[i]! < remCut;
        isAsleep = remLike;
      }
    }
    out[m.ts] = isAsleep;
  }
  return out;
}

List<String> _boutSmoothStage(List<String> labels,
    [int minRun = 5, int minAwakeRun = 7, int passes = 6]) {
  final s = [...labels];
  for (var p = 0; p < passes; p++) {
    final runs = <List<int>>[];
    for (var i = 0; i < s.length;) {
      var j = i;
      while (j < s.length && s[j] == s[i]) {
        j++;
      }
      runs.add([i, j - 1]);
      i = j;
    }
    if (runs.length <= 1) break;
    bool changed = false;
    for (var r = 0; r < runs.length; r++) {
      final a = runs[r][0], b = runs[r][1];
      final floor = s[a] == 'awake' ? minAwakeRun : minRun;
      if (b - a + 1 >= floor) continue;
      final prev = r > 0 ? runs[r - 1] : null;
      final next = r < runs.length - 1 ? runs[r + 1] : null;
      String? tgt;
      if (prev != null && next != null) {
        tgt = (prev[1] - prev[0]) >= (next[1] - next[0])
            ? s[prev[0]]
            : s[next[0]];
      } else if (prev != null) {
        tgt = s[prev[0]];
      } else if (next != null) {
        tgt = s[next[0]];
      }
      if (tgt != null) {
        for (var x = a; x <= b; x++) {
          s[x] = tgt;
        }
        changed = true;
      }
    }
    if (!changed) break;
  }
  return s;
}

class NightHypnogram {
  final List<Map<String, dynamic>> hypnogram;
  final double light_min;
  final double deep_min;
  final double rem_min;
  final double awake_min;
  final double asleep_min;
  const NightHypnogram({
    required this.hypnogram,
    required this.light_min,
    required this.deep_min,
    required this.rem_min,
    required this.awake_min,
    required this.asleep_min,
  });
  Map<String, dynamic> toJson() => {
        'hypnogram': hypnogram,
        'light_min': light_min,
        'deep_min': deep_min,
        'rem_min': rem_min,
        'awake_min': awake_min,
        'asleep_min': asleep_min,
      };
}

NightHypnogram? stageHypnogram(
    List<Minute> minutes, double onset, double wake, Baseline baseline,
    [Map<double, List<double>>? rrByMin]) {
  final rhr = baseline.resting_hr;
  if (rhr == null || rhr <= 0) return null;
  final mask = sleepAwakeMask(minutes, baseline, rrByMin);
  final win = minutes
      .where((m) => m.ts >= onset && m.ts <= wake)
      .toList()
    ..sort((a, b) => a.ts.compareTo(b.ts));
  if (win.length < 5) return null;

  final sleepHr = win
      .where((m) => mask[m.ts] != false && m.hr_avg > 0)
      .map((m) => m.hr_avg)
      .toList();
  final hrs = sleepHr.isNotEmpty
      ? sleepHr
      : win.where((m) => m.hr_avg > 0).map((m) => m.hr_avg).toList();
  final sortedHr = [...hrs]..sort();
  final meanHr = hrs.isNotEmpty
      ? hrs.fold<double>(0, (a, b) => a + b) / hrs.length
      : rhr;
  double q(double p) => sortedHr.isNotEmpty
      ? sortedHr[math.min(sortedHr.length - 1, (p * sortedHr.length).floor())]
      : meanHr;
  final deepEdge = q(0.22), remEdge = q(0.79);
  final bigJump = math.max(
      6.0, (hrs.isNotEmpty ? math.max(1.0, q(0.9) - q(0.1)) : 1.0) * 0.6);
  final acts = win.map((m) => m.activity).toList();
  final meanAct = acts.fold<double>(0, (a, b) => a + b) /
      (acts.isEmpty ? 1 : acts.length);

  final raw = List<String>.generate(win.length, (i) {
    final m = win[i];
    if (mask[m.ts] == false || m.hr_avg <= 0) return 'awake';
    final hr = m.hr_avg;
    final prev =
        i > 0 && win[i - 1].hr_avg > 0 ? win[i - 1].hr_avg : hr;
    final next =
        i + 1 < win.length && win[i + 1].hr_avg > 0 ? win[i + 1].hr_avg : hr;
    final hrJump = math.max((hr - prev).abs(), (hr - next).abs());
    final lowAct = m.activity <= meanAct;
    if (lowAct && hr <= deepEdge) return 'deep';
    if (lowAct && hr >= remEdge) return 'rem';
    if (lowAct && hrJump > bigJump) return 'rem';
    return 'light';
  });
  final sm = _boutSmoothStage(raw);
  double light = 0, deep = 0, rem = 0, awake = 0;
  for (final s in sm) {
    if (s == 'awake') {
      awake++;
    } else if (s == 'deep') {
      deep++;
    } else if (s == 'rem') {
      rem++;
    } else {
      light++;
    }
  }
  return NightHypnogram(
    hypnogram:
        List.generate(win.length, (i) => {'t': win[i].ts, 'stage': sm[i]}),
    light_min: light,
    deep_min: deep,
    rem_min: rem,
    awake_min: awake,
    asleep_min: light + deep + rem,
  );
}

SleepStages? _estimateStages(List<Minute> sleepEpochs, double rhr) {
  if (sleepEpochs.isEmpty) return null;
  final hrs =
      sleepEpochs.where((m) => m.hr_avg > 0).map((m) => m.hr_avg).toList();
  final meanHr = hrs.isNotEmpty ? mean(hrs) : rhr;
  final acts = sleepEpochs.map((m) => m.activity).toList();
  final meanAct = mean(acts);

  final sortedHr = [...hrs]..sort();
  double q(double p) => sortedHr.isNotEmpty
      ? sortedHr[math.min(sortedHr.length - 1, (p * sortedHr.length).floor())]
      : meanHr;
  final deepEdge = q(0.22);
  final remEdge = q(0.79);
  final hrSpread = hrs.isNotEmpty ? math.max(1.0, q(0.9) - q(0.1)) : 1.0;
  final bigJump = math.max(6.0, hrSpread * 0.6);

  double light = 0, deep = 0, rem = 0;
  for (var i = 0; i < sleepEpochs.length; i++) {
    final m = sleepEpochs[i];
    final lowAct = m.activity <= meanAct;
    final hr = m.hr_avg > 0 ? m.hr_avg : meanHr;
    final prev = i > 0 && sleepEpochs[i - 1].hr_avg > 0
        ? sleepEpochs[i - 1].hr_avg
        : hr;
    final next = i + 1 < sleepEpochs.length && sleepEpochs[i + 1].hr_avg > 0
        ? sleepEpochs[i + 1].hr_avg
        : hr;
    final hrJump = math.max((hr - prev).abs(), (hr - next).abs());
    if (lowAct && hr <= deepEdge) {
      deep++;
    } else if (lowAct && hr >= remEdge) {
      rem++;
    } else if (lowAct && hrJump > bigJump) {
      rem++;
    } else {
      light++;
    }
  }
  return SleepStages(light, deep, rem);
}
