// §Sleep cycles — ultradian NREM↔REM cycle detection (Rosenblum 2024, HRV-adapted).
import 'dart:math' as math;
import 'hrv.dart';

class SleepCycle {
  final double start_ts;
  final double end_ts;
  final double duration_min;
  const SleepCycle(this.start_ts, this.end_ts, this.duration_min);
  Map<String, dynamic> toJson() => {
        'start_ts': start_ts,
        'end_ts': end_ts,
        'duration_min': duration_min,
      };
}

class SleepCyclesResult {
  final List<SleepCycle> cycles;
  final double? mean_duration_min;
  final int n;
  final List<Map<String, dynamic>> series;
  const SleepCyclesResult({
    required this.cycles,
    required this.mean_duration_min,
    required this.n,
    required this.series,
  });
  Map<String, dynamic> toJson() => {
        'cycles': cycles.map((c) => c.toJson()).toList(),
        'mean_duration_min': mean_duration_min,
        'n': n,
        'series': series,
      };
}

const _smoothMin = 10;
const _minPeakDist = 20;
const _minProminence = 0.9;

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

List<int> _findPeaks(List<double?> y, int minDist, double minProm) {
  final n = y.length;
  final cand = <_Cand>[];
  for (var i = 1; i < n - 1; i++) {
    final yi = y[i];
    if (yi == null) continue;
    final a = y[i - 1] ?? double.negativeInfinity;
    final b = y[i + 1] ?? double.negativeInfinity;
    if (!(yi >= a && yi > b)) continue;
    var l = i;
    while (l > 0 && (y[l - 1] ?? double.negativeInfinity) < yi) {
      l--;
    }
    var r = i;
    while (r < n - 1 && (y[r + 1] ?? double.negativeInfinity) < yi) {
      r++;
    }
    double lmin = yi, rmin = yi;
    for (var k = l; k <= i; k++) {
      final v = y[k];
      if (v != null && v < lmin) lmin = v;
    }
    for (var k = i; k <= r; k++) {
      final v = y[k];
      if (v != null && v < rmin) rmin = v;
    }
    if (yi - math.max(lmin, rmin) >= minProm) cand.add(_Cand(i, yi));
  }
  cand.sort((p, q) => q.v.compareTo(p.v));
  final kept = <int>[];
  for (final c in cand) {
    if (kept.every((k) => (c.i - k).abs() >= minDist)) kept.add(c.i);
  }
  kept.sort();
  return kept;
}

SleepCyclesResult detectSleepCycles(
    List<RrMinute> minutes, double onset, double wake) {
  const none = SleepCyclesResult(
      cycles: [], mean_duration_min: null, n: 0, series: []);
  final win = minutes
      .where((m) => m.ts >= onset && m.ts <= wake)
      .toList()
    ..sort((a, b) => a.ts.compareTo(b.ts));
  if (win.length < 60) return none;

  final raw = win.map((m) => _minuteRmssd(m.rr)).toList();
  final sm = List<double?>.generate(raw.length, (i) {
    double s = 0;
    int c = 0;
    for (var j = math.max(0, i - _smoothMin);
        j <= math.min(raw.length - 1, i + _smoothMin);
        j++) {
      final v = raw[j];
      if (v != null) {
        s += v;
        c++;
      }
    }
    return c != 0 ? s / c : null;
  });
  final vals = sm.whereType<double>().toList();
  if (vals.length < 60) return none;
  final meanV = vals.fold<double>(0, (a, b) => a + b) / vals.length;
  final sdRaw = math.sqrt(
      vals.fold<double>(0, (a, b) => a + math.pow(b - meanV, 2)) / vals.length);
  final sd = sdRaw == 0 ? 1.0 : sdRaw;
  final z = sm.map((x) => x == null ? null : (x - meanV) / sd).toList();

  final peaks = _findPeaks(z, _minPeakDist, _minProminence);
  final cycles = <SleepCycle>[];
  for (var i = 0; i + 1 < peaks.length; i++) {
    final startTs = win[peaks[i]].ts, endTs = win[peaks[i + 1]].ts;
    cycles.add(SleepCycle(
        startTs, endTs, jsRoundLocal((endTs - startTs) / 60)));
  }
  final double? meanDuration = cycles.isNotEmpty
      ? jsRoundLocal(
          cycles.fold<double>(0, (s, c) => s + c.duration_min) / cycles.length)
      : null;
  final series = <Map<String, dynamic>>[];
  for (var i = 0; i < win.length; i++) {
    final zv = z[i];
    if (zv != null) {
      series.add({'t': win[i].ts, 'z': jsRoundLocal(zv * 1000) / 1000});
    }
  }

  return SleepCyclesResult(
    cycles: cycles,
    mean_duration_min: meanDuration,
    n: cycles.length,
    series: series,
  );
}

double jsRoundLocal(double x) => (x + 0.5).floorToDouble();

class RrMinute {
  final double ts;
  final List<double>? rr;
  const RrMinute(this.ts, [this.rr]);
}

class _Cand {
  final int i;
  final double v;
  _Cand(this.i, this.v);
}
