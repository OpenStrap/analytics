// wake.ts — sleep/wake state ENSEMBLE for the demand-driven day-close trigger.
import 'dart:math' as math;
import 'types.dart';
import 'util.dart';

// WakeLabel = 'asleep' | 'awake' | 'unknown'

class WakeContext {
  final List<Minute> minutes;
  final Baseline baseline;
  final Map<double, List<double>>? rrByMin;
  final double? now;
  const WakeContext({
    required this.minutes,
    required this.baseline,
    this.rrByMin,
    this.now,
  });
}

typedef Voter = List<String> Function(WakeContext ctx);

class WakeState {
  final String state;
  final double? wake_ts;
  final double? onset_ts;
  final double awake_min;
  final double asleep_min;
  final Map<String, String> votes;
  final double confidence;
  const WakeState({
    required this.state,
    required this.wake_ts,
    required this.onset_ts,
    required this.awake_min,
    required this.asleep_min,
    required this.votes,
    required this.confidence,
  });
  Map<String, dynamic> toJson() => {
        'state': state,
        'wake_ts': wake_ts,
        'onset_ts': onset_ts,
        'awake_min': awake_min,
        'asleep_min': asleep_min,
        'votes': votes,
        'confidence': confidence,
      };
}

const _min = 60;
const _minMainSleepMin = 90;
const _sustainedWakeMin = 10;

double _median(List<double> xs) {
  if (xs.isEmpty) return 0;
  final s = [...xs]..sort();
  final m = s.length >> 1;
  return s.length % 2 != 0 ? s[m] : (s[m - 1] + s[m]) / 2;
}

const List<int> _ckW = [106, 54, 58, 76, 230, 74, 67];
const double _ckP = 0.001;

List<String> coleKripke(WakeContext ctx) {
  final minutes = ctx.minutes;
  final act = minutes.map((m) => m.wrist_on ? m.activity : 0.0).toList();
  final nz = act.where((a) => a > 0).toList();
  final scaleRaw = _median(nz);
  final scale = scaleRaw == 0 ? 1.0 : scaleRaw;
  final n = minutes.length;
  return List<String>.generate(n, (i) {
    if (!isHrUsable(minutes[i]) && minutes[i].activity == 0) return 'unknown';
    double d = 0;
    for (var k = -4; k <= 2; k++) {
      final j = i + k;
      if (j < 0 || j >= n) continue;
      d += _ckW[k + 4] * (act[j] / scale);
    }
    d *= _ckP;
    return d < 1 ? 'asleep' : 'awake';
  });
}

List<String> cardiac(WakeContext ctx) {
  final minutes = ctx.minutes;
  final baseline = ctx.baseline;
  final usable = minutes.where(isHrUsable).map((m) => m.hr_avg).toList();
  final sorted = [...usable]..sort();
  final rhr = baseline.resting_hr ?? 0;
  final p10 = sorted.isNotEmpty ? sorted[(sorted.length * 0.1).floor()] : rhr;
  final trough = _orZero(
      math.max(_orZero(rhr, 0), _orZero(p10, 0)),
      sorted.isNotEmpty ? sorted[0] : 0);
  const wakeMargin = 8;
  final hr = minutes
      .map((m) => isHrUsable(m) ? m.hr_avg : double.nan)
      .toList();
  final hs = List<double>.generate(hr.length, (i) {
    final seg = hr
        .sublist(math.max(0, i - 2), math.min(hr.length, i + 3))
        .where((v) => v.isFinite)
        .toList()
      ..sort();
    return seg.isNotEmpty ? seg[seg.length >> 1] : double.nan;
  });
  return List<String>.generate(minutes.length, (i) {
    if (!hs[i].isFinite) return 'unknown';
    return hs[i] > trough + wakeMargin ? 'awake' : 'asleep';
  });
}

// helper replicating JS `(a) || (b)` where 0 is falsy.
double _orZero(double a, double b) => a != 0 ? a : b;

List<String> inactivity(WakeContext ctx) {
  final minutes = ctx.minutes;
  final act =
      minutes.map((m) => m.wrist_on ? m.activity : double.nan).toList();
  final worn = act.where((a) => a.isFinite).toList();
  final s = [...worn]..sort();
  double pct(double p) =>
      s.isNotEmpty ? s[math.min(s.length - 1, (s.length * p).floor())] : 0;
  final p10 = pct(0.1), p90 = pct(0.9);
  const absMove = 0.05;
  final thr = p10 + math.max(absMove, 0.3 * (p90 - p10));
  const w = 5;
  final n = minutes.length;
  return List<String>.generate(n, (i) {
    if (!act[i].isFinite) return 'unknown';
    int still = 0, seen = 0;
    for (var j = math.max(0, i - w); j <= math.min(n - 1, i + w); j++) {
      if (!act[j].isFinite) continue;
      seen++;
      if (act[j] <= thr) still++;
    }
    if (seen == 0) return 'unknown';
    return still / seen >= 0.7 ? 'asleep' : 'awake';
  });
}

List<String> hrvArousal(WakeContext ctx) {
  final minutes = ctx.minutes;
  final baseline = ctx.baseline;
  final rrByMin = ctx.rrByMin;
  final usable = minutes.where(isHrUsable).map((m) => m.hr_avg).toList();
  final sorted = [...usable]..sort();
  final rhr = baseline.resting_hr ?? 0;
  final p10 = sorted.isNotEmpty ? sorted[(sorted.length * 0.1).floor()] : rhr;
  final trough = _orZero(
      math.max(_orZero(rhr, 0), _orZero(p10, 0)),
      sorted.isNotEmpty ? sorted[0] : 0);
  const rrSdWake = 45;
  final sdRaw = minutes.map((m) {
    final rr = rrByMin?[(m.ts / _min).floorToDouble() * _min];
    if (rr == null || rr.length < 4) return double.nan;
    final mn = rr.fold<double>(0, (s, v) => s + v) / rr.length;
    return math.sqrt(
        rr.fold<double>(0, (s, v) => s + math.pow(v - mn, 2)) / rr.length);
  }).toList();
  final sd = List<double>.generate(sdRaw.length, (i) {
    final seg = sdRaw
        .sublist(math.max(0, i - 2), math.min(sdRaw.length, i + 3))
        .where((v) => v.isFinite)
        .toList()
      ..sort();
    return seg.isNotEmpty ? seg[seg.length >> 1] : double.nan;
  });
  return List<String>.generate(minutes.length, (i) {
    final m = minutes[i];
    if (!sd[i].isFinite || !isHrUsable(m)) return 'unknown';
    return sd[i] > rrSdWake && m.hr_avg > trough ? 'awake' : 'asleep';
  });
}

class NamedVoter {
  final String name;
  final Voter fn;
  const NamedVoter(this.name, this.fn);
}

const List<NamedVoter> DEFAULT_VOTERS = [
  NamedVoter('coleKripke', coleKripke),
  NamedVoter('cardiac', cardiac),
  NamedVoter('inactivity', inactivity),
  NamedVoter('hrvArousal', hrvArousal),
];

List<String> _consensusPerMinute(List<List<String>> labels, int n,
    [int minAwake = 2]) {
  final out = <String>[];
  for (var i = 0; i < n; i++) {
    int awake = 0, known = 0;
    for (final arr in labels) {
      final l = arr[i];
      if (l == 'awake') {
        awake++;
        known++;
      } else if (l == 'asleep') {
        known++;
      }
    }
    out.add(awake >= minAwake
        ? 'awake'
        : known != 0
            ? 'asleep'
            : 'unknown');
  }
  return out;
}

List<String> _boutSmooth(List<String> labels,
    [int minRun = 10, int passes = 4]) {
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
      if (b - a + 1 >= minRun) continue;
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

WakeState detectWakeState(WakeContext ctx,
    [List<NamedVoter> voters = DEFAULT_VOTERS]) {
  final minutes = ctx.minutes;
  final n = minutes.length;
  final empty = const WakeState(
    state: 'unknown',
    wake_ts: null,
    onset_ts: null,
    awake_min: 0,
    asleep_min: 0,
    votes: {},
    confidence: 0,
  );
  if (n < _sustainedWakeMin) return empty;

  final perVoter = voters.map((v) => v.fn(ctx)).toList();
  final labels = _boutSmooth(_consensusPerMinute(perVoter, n));

  final votes = <String, String>{};
  for (var k = 0; k < voters.length; k++) {
    votes[voters[k].name] = n - 1 >= 0 ? perVoter[k][n - 1] : 'unknown';
  }

  var i = n - 1;
  var awakeRunStart = n;
  while (i >= 0 && labels[i] == 'awake') {
    awakeRunStart = i;
    i--;
  }
  while (i >= 0 && labels[i] == 'unknown') {
    i--;
  }
  final sleepEnd = i;
  while (i >= 0 && labels[i] != 'awake') {
    i--;
  }
  final sleepStart = i + 1;

  final sleepBoutMin = (sleepEnd >= sleepStart && sleepStart >= 0)
      ? jsRound((minutes[sleepEnd].ts - minutes[sleepStart].ts) / _min) + 1
      : 0.0;
  final awakeMin = awakeRunStart < n
      ? jsRound((minutes[n - 1].ts - minutes[awakeRunStart].ts) / _min) + 1
      : 0.0;

  final known = labels.where((l) => l != 'unknown').length;
  final coverage = n != 0 ? known / n : 0.0;
  double agree;
  {
    double acc = 0;
    int c = 0;
    for (var k = 0; k < n; k++) {
      int a = 0, w = 0;
      for (final arr in perVoter) {
        if (arr[k] == 'asleep') {
          a++;
        } else if (arr[k] == 'awake') {
          w++;
        }
      }
      final tot = a + w;
      if (tot == 0) continue;
      acc += math.max(a, w) / tot;
      c++;
    }
    agree = c != 0 ? acc / c : 0;
  }
  final confidence = jsRound(coverage * agree * 100) / 100;

  final current = labels[n - 1];
  final justWoke = current == 'awake' &&
      awakeMin >= _sustainedWakeMin &&
      sleepBoutMin >= _minMainSleepMin;

  return WakeState(
    state: current,
    wake_ts: justWoke ? minutes[awakeRunStart].ts : null,
    onset_ts: justWoke && sleepStart >= 0 && sleepStart <= sleepEnd
        ? minutes[sleepStart].ts
        : null,
    awake_min: awakeMin,
    asleep_min: sleepBoutMin,
    votes: votes,
    confidence: confidence,
  );
}

String peekRecentState(List<Minute> recent, Baseline baseline) {
  final worn = recent.where((m) => m.wrist_on).toList();
  if (worn.length < 3) return 'unknown';
  final rhr = baseline.resting_hr ?? 0;
  final hrUp = worn.where(isHrUsable).any((m) => m.hr_avg > rhr + 6);
  final moving = worn.any((m) => m.activity > 0 && m.steps > 0);
  return hrUp || moving ? 'awake' : 'asleep';
}
