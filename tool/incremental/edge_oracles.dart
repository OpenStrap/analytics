// VERBATIM PORTS of the app-side (edge) functions that are not in analytics:
//   dayHrvCurve, dayRespCurve, _daytimeHrv, _hrvTimeline, _respPerWindow.
// Source: edge-bgmem @ 26762fb5, lib/compute/derivation_engine.dart (~8532,
// 8641, 8866) and lib/compute/onehz_pipeline.dart (_hrvTimeline ~1926,
// _respPerWindow ~1692). Only change: `Substrate` -> the plain [DaySub] below
// and the CalculationCache plumbing removed (state == null path). They are the
// ORACLES the incremental states are compared with.
import 'dart:math' as math;

import 'package:openstrap_analytics/onehz.dart'
    hide RrCorrector, RrSettled, RrSnapshot, IrregularScreenState;

/// edge `accelPlausible` (substrate.dart:100).
bool accelPlausible(double ax, double ay, double az) {
  final magSq = ax * ax + ay * ay + az * az;
  return magSq > 0 && magSq <= 4.0 * 4.0;
}

const double kQuietCutG = 0.02; // _quietEnmoCutG gen4 / gen5

class DaySub {
  final List<double> rrMs, rrTsMs;
  final List<int> tsSec;
  final List<double> ax, ay, az;
  DaySub(this.rrMs, this.rrTsMs, this.tsSec, this.ax, this.ay, this.az);
  int get length => tsSec.length;
  bool accelPresentAt(int i) => accelPlausible(ax[i], ay[i], az[i]);
}

List<Map<String, num>> oracleDayHrvCurve(DaySub s) {
  final ts = <double>[], rr = <double>[];
  for (var i = 0; i < s.rrMs.length; i++) {
    final v = s.rrMs[i];
    if (v >= 300 && v <= 2000) {
      ts.add(s.rrTsMs[i]);
      rr.add(v);
    }
  }
  if (rr.length < 10) return const [];
  const winMs = 300000.0;
  final out = <Map<String, num>>[];
  var lo = 0;
  var lastEmit = -1e18;
  for (var i = 0; i < rr.length; i++) {
    while (ts[i] - ts[lo] > winMs) {
      lo++;
    }
    if (i - lo >= 10 && ts[i] - lastEmit > 60000) {
      double? calculate() {
        var ssd = 0.0;
        var nd = 0;
        for (var k = lo + 1; k <= i; k++) {
          final d = rr[k] - rr[k - 1];
          if (d.abs() > 0.20 * rr[k - 1] || d.abs() > 200) continue;
          ssd += d * d;
          nd++;
        }
        if (nd < 8) return null;
        final rmssd = math.sqrt(ssd / nd);
        return rmssd <= 220 ? double.parse(rmssd.toStringAsFixed(1)) : null;
      }

      final value = calculate();
      lastEmit = ts[i];
      if (value != null) out.add({'t': (ts[i] / 1000).round(), 'v': value});
    }
  }
  return out;
}

const double kRespQuietFraction = 0.9;

List<Map<String, num>> oracleDayRespCurve(DaySub s,
    {double? cut = kQuietCutG,
    double? Function(List<double> nn, List<double> nnt)? estimator}) {
  if (cut == null) return const [];
  final quietPrefix = List<int>.filled(s.length + 1, 0);
  for (var i = 0; i < s.length; i++) {
    var q = 0;
    if (s.accelPresentAt(i)) {
      final mag = math.sqrt(
        s.ax[i] * s.ax[i] + s.ay[i] * s.ay[i] + s.az[i] * s.az[i],
      );
      if ((mag - 1.0).abs() <= cut) q = 1;
    }
    quietPrefix[i + 1] = quietPrefix[i] + q;
  }
  final ts = <double>[], rr = <double>[];
  for (var i = 0; i < s.rrMs.length; i++) {
    final v = s.rrMs[i];
    if (v >= 300 && v <= 2000) {
      ts.add(s.rrTsMs[i]);
      rr.add(v);
    }
  }
  if (rr.length < 60) return const [];
  const winMs = 180000.0;
  final out = <Map<String, num>>[];
  var lo = 0;
  var lastEmit = -1e18;
  var qLo = 0, qHi = 0;
  for (var i = 0; i < rr.length; i++) {
    while (ts[i] - ts[lo] > winMs) {
      lo++;
    }
    if (i - lo >= 30 && ts[i] - lastEmit > 300000) {
      final loSec = (ts[lo] / 1000).floor();
      final hiSec = (ts[i] / 1000).ceil();
      while (qLo < s.length && s.tsSec[qLo] < loSec) {
        qLo++;
      }
      if (qHi < qLo) qHi = qLo;
      while (qHi < s.length && s.tsSec[qHi] < hiSec) {
        qHi++;
      }
      final spanSec = hiSec - loSec;
      final stillSec = quietPrefix[qHi] - quietPrefix[qLo];
      final nn = rr.sublist(lo, i + 1);
      final t0 = ts[lo];
      final nnt = [for (var k = lo; k <= i; k++) ts[k] - t0];
      double? calculate() {
        if (spanSec <= 0 || stillSec < kRespQuietFraction * spanSec) {
          return null;
        }
        if (estimator != null) return estimator(nn, nnt);
        final est = rsaRespRate(nn, nnt, artifactFraction: 0.15);
        return est.present ? est.value!.brpm : null;
      }

      final brpm = calculate();
      lastEmit = ts[i];
      if (brpm != null) {
        out.add({
          't': (ts[i] / 1000).round(),
          'v': double.parse(brpm.toStringAsFixed(1)),
        });
      }
    }
  }
  return out;
}

Map<String, dynamic> oracleDaytimeHrv(DaySub s, int onsetSec, int offsetSec,
    {double? cut = kQuietCutG}) {
  const binSec = 300;
  if (cut == null) {
    return {
      'timeline': const <Map<String, dynamic>>[],
      'mean_rmssd': null,
      'n_buckets': 0,
    };
  }
  final quiet = <int>{};
  for (var i = 0; i < s.length; i++) {
    if (!s.accelPresentAt(i)) continue;
    final mag =
        math.sqrt(s.ax[i] * s.ax[i] + s.ay[i] * s.ay[i] + s.az[i] * s.az[i]);
    if ((mag - 1.0).abs() <= cut) quiet.add(s.tsSec[i]);
  }
  final bins = <int, List<double>>{};
  double? prev;
  for (var k = 0; k < s.rrMs.length; k++) {
    final tSec = s.rrTsMs[k] ~/ 1000;
    if (offsetSec > onsetSec && tSec >= onsetSec && tSec < offsetSec) {
      prev = null;
      continue;
    }
    if (!quiet.contains(tSec)) {
      prev = null;
      continue;
    }
    final v = s.rrMs[k];
    if (v < 300 || v > 2000) {
      prev = null;
      continue;
    }
    if (prev != null) {
      final d = v - prev;
      if (d.abs() <= 200) (bins[tSec ~/ binSec] ??= <double>[]).add(d * d);
    }
    prev = v;
  }
  final timeline = <Map<String, dynamic>>[];
  final means = <double>[];
  final keys = bins.keys.toList()..sort();
  for (final b in keys) {
    final sq = bins[b]!;
    if (sq.length < 5) continue;
    final rmssd = math.sqrt(sq.reduce((a, c) => a + c) / sq.length);
    timeline.add({
      't': b * binSec,
      'rmssd': (rmssd * 10).round() / 10.0,
      'n': sq.length,
    });
    means.add(rmssd);
  }
  final mean = means.isEmpty ? null : means.reduce((a, c) => a + c) / means.length;
  return {
    'timeline': timeline,
    'mean_rmssd': mean == null ? null : (mean * 10).round() / 10.0,
    'n_buckets': timeline.length,
  };
}

double _round(double v, int dp) {
  final p = math.pow(10, dp);
  return (v * p).round() / p;
}

List<Map<String, num>> oracleHrvTimeline(
    List<double> nn, List<double> nnTimes, double? originMs) {
  if (nn.length < 10 || nnTimes.length != nn.length || originMs == null) {
    return const [];
  }
  const winMs = 300000.0;
  final out = <Map<String, num>>[];
  var lo = 0;
  for (var i = 0; i < nn.length; i++) {
    while (nnTimes[i] - nnTimes[lo] > winMs) {
      lo++;
    }
    if (nnTimes[i] - nnTimes[0] < winMs) continue;
    if (i - lo >= 10) {
      var ssd = 0.0;
      for (var k = lo + 1; k <= i; k++) {
        final diff = nn[k] - nn[k - 1];
        ssd += diff * diff;
      }
      final rmssd = math.sqrt(ssd / (i - lo));
      final tSec = ((originMs + nnTimes[i]) / 1000).round();
      if (out.isEmpty || tSec - out.last['t']! > 60) {
        out.add({'t': tSec, 'v': _round(rmssd, 1)});
      }
    }
  }
  return out;
}

List<double> oracleRespPerWindow(List<double> nn, List<double> nnTimes,
    {double windowMs = 1800000.0, int minBeats = 60}) {
  if (nn.isEmpty || nn.length != nnTimes.length) return const [];
  final t0 = nnTimes.first;
  final binsNn = <int, List<double>>{};
  final binsTs = <int, List<double>>{};
  for (var i = 0; i < nn.length; i++) {
    final idx = ((nnTimes[i] - t0) / windowMs).floor();
    (binsNn[idx] ??= <double>[]).add(nn[i]);
    (binsTs[idx] ??= <double>[]).add(nnTimes[i]);
  }
  final out = <double>[];
  final idxs = binsNn.keys.toList()..sort();
  for (final idx in idxs) {
    final segNn = binsNn[idx]!;
    if (segNn.length < minBeats) continue;
    final r = rsaRespRate(segNn, binsTs[idx]!, artifactFraction: 0.0);
    final b = r.present ? r.value!.brpm : null;
    if (b != null) out.add(b);
  }
  return out;
}
