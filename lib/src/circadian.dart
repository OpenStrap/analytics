// §Circadian — CircaCP cosinor + bounded change-point.
import 'dart:math' as math;
import 'types.dart';
import 'util.dart';
import 'hrv.dart';

const _day = 86400;
final double _w = (2 * math.pi) / _day;

class _Pt {
  final double t;
  final double y;
  const _Pt(this.t, this.y);
}

class _Cosinor {
  final double mesor;
  final double b1;
  final double b2;
  final double amp;
  final double phi;
  const _Cosinor(this.mesor, this.b1, this.b2, this.amp, this.phi);
}

_Cosinor? _fitCosinor(List<_Pt> pts) {
  final n = pts.length;
  if (n < 120) return null;
  final rows = pts
      .map((p) => [math.cos(_w * p.t), math.sin(_w * p.t), p.y])
      .toList();
  var w = List<double>.filled(n, 1);
  double M = 0, b1 = 0, b2 = 0;
  for (var iter = 0; iter < 8; iter++) {
    final A = [
      [0.0, 0.0, 0.0],
      [0.0, 0.0, 0.0],
      [0.0, 0.0, 0.0]
    ];
    final bv = [0.0, 0.0, 0.0];
    for (var i = 0; i < n; i++) {
      final x = [1.0, rows[i][0], rows[i][1]];
      final wi = w[i];
      for (var r = 0; r < 3; r++) {
        bv[r] += wi * x[r] * rows[i][2];
        for (var cc = 0; cc < 3; cc++) {
          A[r][cc] += wi * x[r] * x[cc];
        }
      }
    }
    final sol = _solve3(A, bv);
    if (sol == null) return null;
    M = sol[0];
    b1 = sol[1];
    b2 = sol[2];
    final res =
        rows.map((r) => r[2] - (M + b1 * r[0] + b2 * r[1])).toList();
    final absr = res.map((e) => e.abs()).toList()..sort();
    final madRaw = absr[absr.length >> 1];
    final mad = madRaw == 0 ? 1.0 : madRaw;
    final cc = 4.685 * 1.4826 * mad;
    w = res
        .map((e) => e.abs() < cc ? math.pow(1 - math.pow(e / cc, 2), 2).toDouble() : 0.0)
        .toList();
  }
  return _Cosinor(M, b1, b2, _hypot(b1, b2), math.atan2(b2, b1));
}

double _hypot(double a, double b) => math.sqrt(a * a + b * b);

List<double>? _solve3(List<List<double>> A, List<double> b) {
  final m = List.generate(3, (i) => [...A[i], b[i]]);
  for (var col = 0; col < 3; col++) {
    var piv = col;
    for (var r = col + 1; r < 3; r++) {
      if (m[r][col].abs() > m[piv][col].abs()) piv = r;
    }
    if (m[piv][col].abs() < 1e-12) return null;
    final t = m[col];
    m[col] = m[piv];
    m[piv] = t;
    final pv = m[col][col];
    for (var k = col; k < 4; k++) {
      m[col][k] /= pv;
    }
    for (var r = 0; r < 3; r++) {
      if (r == col) continue;
      final f = m[r][col];
      for (var k = col; k < 4; k++) {
        m[r][k] -= f * m[col][k];
      }
    }
  }
  return [m[0][3], m[1][3], m[2][3]];
}

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

double? _medOf(List<double?> xs) {
  final a = xs.whereType<double>().where((x) => x.isFinite).toList()..sort();
  return a.isNotEmpty ? a[a.length >> 1] : null;
}

List<double> _smooth(List<double> ys, int k) {
  final n = ys.length;
  final out = List<double>.filled(n, 0);
  for (var i = 0; i < n; i++) {
    final lo = math.max(0, i - k), hi = math.min(n, i + k + 1);
    final seg = ys.sublist(lo, hi)..sort();
    out[i] = seg[seg.length >> 1];
  }
  return out;
}

double? _changePoint(List<_Pt> pts, String want) {
  const minPts = 15;
  if (pts.length < 2 * minPts) return null;
  final ys = _smooth(pts.map((p) => p.y).toList(), 5);
  final n = ys.length;
  final pre = List<double>.filled(n + 1, 0);
  final pre2 = List<double>.filled(n + 1, 0);
  for (var i = 0; i < n; i++) {
    pre[i + 1] = pre[i] + ys[i];
    pre2[i + 1] = pre2[i] + ys[i] * ys[i];
  }
  double sse(int a, int b) {
    final cnt = b - a;
    if (cnt <= 0) return 0;
    final sum = pre[b] - pre[a];
    return (pre2[b] - pre2[a]) - (sum * sum) / cnt;
  }

  final total = sse(0, n);
  double? bestGain;
  int? bestTau;
  for (var tau = minPts; tau < n - minPts; tau++) {
    final d = (pre[n] - pre[tau]) / (n - tau) - pre[tau] / tau;
    if (want == 'rise' && d <= 0) continue;
    if (want == 'drop' && d >= 0) continue;
    final gain = total - (sse(0, tau) + sse(tau, n));
    if (bestGain == null || gain > bestGain) {
      bestGain = gain;
      bestTau = tau;
    }
  }
  return bestTau != null ? pts[bestTau].t : null;
}

class _Period {
  final double onset;
  final double wake;
  const _Period(this.onset, this.wake);
}

_Period? _mainSleepPeriod(List<_Pt> pts, double bath, double mesor) {
  final n = pts.length;
  if (n < 30) return null;
  final ys = _smooth(pts.map((p) => p.y).toList(), 5);
  final asleep = ys.map((v) => v < mesor).toList();
  var a = 0;
  for (var i = 1; i < n; i++) {
    if ((pts[i].t - bath).abs() < (pts[a].t - bath).abs()) a = i;
  }
  const bridge = 60 * 60;
  var end = a;
  for (var i = a + 1; i < n;) {
    if (asleep[i]) {
      end = i;
      i++;
      continue;
    }
    var k = i;
    while (k < n && !asleep[k]) {
      k++;
    }
    if (pts[(k < n ? k : n) - 1].t - pts[i].t > bridge) break;
    i = k;
  }
  var start = a;
  for (var i = a - 1; i >= 0;) {
    if (asleep[i]) {
      start = i;
      i--;
      continue;
    }
    var k = i;
    while (k >= 0 && !asleep[k]) {
      k--;
    }
    if (pts[i].t - pts[k + 1].t > bridge) break;
    i = k;
  }
  final onsetCp = _changePoint(
      pts.where((p) => p.t >= bath - 8 * 3600 && p.t <= bath).toList(), 'drop');
  final onset =
      (onsetCp != null && onsetCp >= pts[start].t) ? onsetCp : pts[start].t;
  return _Period(onset, pts[end].t);
}

class SleepStaging {
  final double in_bed_min;
  final double asleep_min;
  final double efficiency;
  final double awake_min;
  final double light_min;
  final double deep_min;
  final double rem_min;
  final List<Map<String, dynamic>> hypnogram;
  const SleepStaging({
    required this.in_bed_min,
    required this.asleep_min,
    required this.efficiency,
    required this.awake_min,
    required this.light_min,
    required this.deep_min,
    required this.rem_min,
    required this.hypnogram,
  });
  Map<String, dynamic> toJson() => {
        'in_bed_min': in_bed_min,
        'asleep_min': asleep_min,
        'efficiency': efficiency,
        'awake_min': awake_min,
        'light_min': light_min,
        'deep_min': deep_min,
        'rem_min': rem_min,
        'hypnogram': hypnogram,
      };
}

class StageMinute {
  final double ts;
  final double hr_avg;
  final List<double>? rr;
  const StageMinute(this.ts, this.hr_avg, [this.rr]);
}

SleepStaging stageSleep(
    List<StageMinute> minutes, double onset, double wake, double mesor) {
  final inBed = math.max(1, jsRound((wake - onset) / 60)).toInt();
  final win = minutes
      .where((m) => m.ts >= onset && m.ts <= wake)
      .toList()
    ..sort((a, b) => a.ts.compareTo(b.ts));
  final empty = SleepStaging(
    in_bed_min: inBed.toDouble(),
    asleep_min: 0,
    efficiency: 0,
    awake_min: inBed.toDouble(),
    light_min: 0,
    deep_min: 0,
    rem_min: 0,
    hypnogram: const [],
  );
  final worn = win.where((m) => m.hr_avg > 0).toList();
  if (worn.length < 5) return empty;
  final hrs = worn.map((m) => m.hr_avg).toList();
  final floor = percentile(hrs, 10) ?? hrs.reduce(math.min);
  final span = math.max(1.0, mesor - floor);
  final tAwake = math.max(floor + 10, floor + 0.70 * span);
  final tRem = floor + 0.40 * span;
  final tDeep = floor + 0.12 * span;

  final ys = _smooth(
      win.map((m) => (m.hr_avg > 0 ? m.hr_avg : tAwake + 50)).toList(), 5);

  final rmRaw = win.map((m) => _minuteRmssd(m.rr)).toList();
  final rmS = List<double?>.generate(rmRaw.length, (i) {
    final seg = <double?>[];
    for (var j = math.max(0, i - 2); j < math.min(win.length, i + 3); j++) {
      seg.add(rmRaw[j]);
    }
    return _medOf(seg);
  });
  final asleepI = <int>[];
  for (var i = 0; i < win.length; i++) {
    if (win[i].hr_avg > 0 && ys[i] < tAwake) asleepI.add(i);
  }
  final rmRef = _medOf(asleepI.map((i) => rmS[i]).toList());
  final hrRef = _medOf(asleepI.map((i) => ys[i] as double?).toList());
  final rrUsable = rmRef != null &&
      hrRef != null &&
      asleepI.where((i) => rmS[i] != null).length >=
          math.max(20, (asleepI.length * 0.4).floor());
  const deepR = 1.15, remR = 0.88;

  final stage = List<String>.filled(win.length, 'light');
  for (var k = 0; k < win.length; k++) {
    if (win[k].hr_avg <= 0) {
      stage[k] = 'awake';
      continue;
    }
    final v = ys[k];
    if (v >= tAwake) {
      stage[k] = 'awake';
      continue;
    }
    if (rrUsable && rmS[k] != null) {
      final rm = rmS[k]!;
      stage[k] = (rm >= deepR * rmRef && v <= hrRef)
          ? 'deep'
          : (rm <= remR * rmRef)
              ? 'rem'
              : 'light';
    } else {
      stage[k] = v < tDeep
          ? 'deep'
          : v >= tRem
              ? 'rem'
              : 'light';
    }
  }
  var k = 0;
  while (k < win.length) {
    if (stage[k] == 'awake' && win[k].hr_avg > 0) {
      var j = k;
      while (j < win.length && stage[j] == 'awake' && win[j].hr_avg > 0) {
        j++;
      }
      if ((win[j - 1].ts - win[k].ts) / 60 < 20) {
        for (var x = k; x < j; x++) {
          stage[x] = 'rem';
        }
      }
      k = j;
    } else {
      k++;
    }
  }
  const minBout = 6, minAwakeBout = 10;
  for (var iter = 0; iter < 4; iter++) {
    final runs = <List<int>>[];
    for (var i = 0; i < win.length;) {
      var j = i;
      while (j < win.length && stage[j] == stage[i]) {
        j++;
      }
      runs.add([i, j - 1]);
      i = j;
    }
    if (runs.length <= 1) break;
    bool changed = false;
    for (var r = 0; r < runs.length; r++) {
      final s = runs[r][0], e = runs[r][1];
      final lenMin = e - s + 1;
      final floorMin = stage[s] == 'awake' ? minAwakeBout : minBout;
      if (lenMin >= floorMin) continue;
      final prev = r > 0 ? runs[r - 1] : null;
      final next = r < runs.length - 1 ? runs[r + 1] : null;
      String? target;
      if (prev != null && next != null) {
        target = (prev[1] - prev[0]) >= (next[1] - next[0])
            ? stage[prev[0]]
            : stage[next[0]];
      } else if (prev != null) {
        target = stage[prev[0]];
      } else if (next != null) {
        target = stage[next[0]];
      }
      if (target != null) {
        for (var x = s; x <= e; x++) {
          stage[x] = target;
        }
        changed = true;
      }
    }
    if (!changed) break;
  }
  double light = 0, deep = 0, rem = 0, awake = 0;
  for (final s in stage) {
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
  final asleep = light + deep + rem;
  return SleepStaging(
    in_bed_min: inBed.toDouble(),
    asleep_min: asleep,
    efficiency: clamp(asleep / inBed, 0, 1),
    awake_min: awake,
    light_min: light,
    deep_min: deep,
    rem_min: rem,
    hypnogram: List.generate(
        win.length, (idx) => {'t': win[idx].ts, 'stage': stage[idx]}),
  );
}

class CircadianOpts {
  final double? now;
  final double? settleSec;
  final double? anchorTs;
  const CircadianOpts({this.now, this.settleSec, this.anchorTs});
}

class CircadianResult {
  final double? mesor;
  final double? amplitude;
  final double? acrophase_ts;
  final double? bathyphase_ts;
  final double? onset_ts;
  final double? wake_ts;
  final double in_bed_min;
  final bool settled;
  final double confidence;
  final String tier;
  final List<String> inputs_used;
  const CircadianResult({
    required this.mesor,
    required this.amplitude,
    required this.acrophase_ts,
    required this.bathyphase_ts,
    required this.onset_ts,
    required this.wake_ts,
    required this.in_bed_min,
    required this.settled,
    required this.confidence,
    required this.tier,
    required this.inputs_used,
  });
  Map<String, dynamic> toJson() => {
        'mesor': mesor,
        'amplitude': amplitude,
        'acrophase_ts': acrophase_ts,
        'bathyphase_ts': bathyphase_ts,
        'onset_ts': onset_ts,
        'wake_ts': wake_ts,
        'in_bed_min': in_bed_min,
        'settled': settled,
        'confidence': confidence,
        'tier': tier,
        'inputs_used': inputs_used,
      };
}

CircadianResult calcCircadian(List<Minute> minutes,
    [CircadianOpts opts = const CircadianOpts()]) {
  final usable = minutes
      .where(isHrUsable)
      .map((m) => _Pt(m.ts, m.hr_avg))
      .toList()
    ..sort((a, b) => a.t.compareTo(b.t));
  final settle = opts.settleSec ?? 600;

  CircadianResult empty() => const CircadianResult(
        mesor: null,
        amplitude: null,
        acrophase_ts: null,
        bathyphase_ts: null,
        onset_ts: null,
        wake_ts: null,
        in_bed_min: 0,
        settled: false,
        confidence: 0,
        tier: 'HIGH',
        inputs_used: [],
      );
  if (usable.length < 120) return empty();

  final now = opts.now ?? usable[usable.length - 1].t;
  final fit = _fitCosinor(usable);
  if (fit == null) return empty();
  if (fit.amp < 3) return empty();

  final bathBase = (fit.phi + math.pi) / _w;
  final acroBase = fit.phi / _w;
  double nearest(double base, double ref) =>
      base + jsRound((ref - base) / _day) * _day;

  var bath = nearest(bathBase, opts.anchorTs ?? now);
  if (bath > now - 3600) bath -= _day;
  final acro = nearest(acroBase, now);

  List<_Pt> inWin(double lo, double hi) =>
      usable.where((p) => p.t >= lo && p.t <= hi).toList();
  final period = _mainSleepPeriod(
      inWin(bath - 8 * 3600, bath + 10 * 3600), bath, fit.mesor);
  final double? onsetTs = period?.onset;
  final double? wakeTs = period?.wake;
  final inBedMin = (onsetTs != null && wakeTs != null)
      ? jsRound((wakeTs - onsetTs) / 60)
      : 0.0;
  final settled = wakeTs != null && wakeTs <= now - settle;

  final rhythm = clamp((fit.amp - 2) / 8, 0, 1);
  final paired = (onsetTs != null && wakeTs != null) ? 1.0 : 0.3;
  final confidence = round(rhythm * paired, 2);

  return CircadianResult(
    mesor: round(fit.mesor, 1),
    amplitude: round(fit.amp, 1),
    acrophase_ts: acro,
    bathyphase_ts: bath,
    onset_ts: onsetTs,
    wake_ts: wakeTs,
    in_bed_min: inBedMin,
    settled: settled,
    confidence: confidence,
    tier: 'HIGH',
    inputs_used: const ['hr'],
  );
}
