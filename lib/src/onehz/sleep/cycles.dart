// SLEEP — ultradian sleep-cycle detection (Rosenblum et al. 2024, eLife 96784:
// "Fractal cycles of sleep"), HRV-ADAPTED.
//
// The paper defines a sleep cycle from a CONTINUOUS real-valued neurophysiologic
// signal — the EEG fractal (aperiodic, 1/f) slope — NOT from categorical REM
// episodes in a hypnogram (which it explicitly criticizes as arbitrary +
// subjective, ~80% inter-rater). A cycle is a trough→peak excursion of that
// smoothed signal (troughs ≈ NREM, peaks ≈ REM).
//
// We have no EEG, but we DO have 24/7 beat-to-beat RR. The per-minute RMSSD time
// series is the cardiac analog of the fractal slope: vagal tone (RMSSD) RISES in
// REM and the lightening toward REM, FALLS in deep NREM — so its peaks coincide
// with REM and troughs with NREM, exactly mirroring the fractal-slope dynamics.
// We therefore build the per-minute RMSSD series over the sleep window, smooth
// it, z-score it, and detect cycles as PEAK-TO-PEAK intervals via prominence-
// gated peak finding (one peak-to-peak span = one NREM→REM cycle).
//
// Honesty: an HRV-derived ESTIMATE of the classical cycle, not PSG; needs decent
// RR coverage across the night (returns absent otherwise).

import 'dart:math' as math;
import '../types.dart';

/// One detected sleep cycle, in minutes ELAPSED from sleep onset.
class SleepCycle {
  final int startMin;
  final int endMin;
  final int lenMin;
  const SleepCycle(this.startMin, this.endMin, this.lenMin);
  Map<String, dynamic> toJson() =>
      {'start_min': startMin, 'end_min': endMin, 'len_min': lenMin};
}

class SleepCyclesResult {
  final List<SleepCycle> cycles;
  final double? meanDurationMin;
  final int n;

  /// The smoothed, z-scored per-minute RMSSD wave the cycles were detected from
  /// — `[{t: epochSec, z}]`, one point per present minute. This is what the
  /// overnight-HRV cycle GRAPH plots (peaks ≈ REM, troughs ≈ NREM). Without it
  /// the screen reads "not enough overnight HRV" even when cycles were counted.
  final List<Map<String, dynamic>> series;

  const SleepCyclesResult(this.cycles, this.meanDurationMin, this.n,
      [this.series = const []]);
  Map<String, dynamic> toJson() => {
        'cycles': [for (final c in cycles) c.toJson()],
        'cycle_count': n,
        'cycles_mean_min': meanDurationMin,
        'series': series,
      };
}

// Rosenblum-equivalent tuning (minutes / z-units), as the validated port used.
const int _smoothMin = 10; // ± window of the moving average
const int _minPeakDist = 20; // min minutes between cycle peaks
const double _minProminence = 0.9; // z-score prominence to qualify a peak

/// Physiologic RR gate (ms): keep 300–2000, drop |Δ|>200 (ectopy/artifact).
const double _rrMin = 300, _rrMax = 2000, _rrStep = 200;

/// Detect sleep cycles from beat-to-beat RR over the sleep window.
///
/// [rrMs]/[rrTsMs]: RR intervals (ms) and their ABSOLUTE times (ms). [onsetSec]/
/// [offsetSec]: sleep window bounds (epoch seconds). Builds a per-minute RMSSD
/// series, smooths + z-scores it, and returns peak-to-peak cycles. Absent when
/// the night is too short / RR too sparse for a stable series.
SleepCyclesResult detectSleepCycles(
  List<double> rrMs,
  List<double> rrTsMs,
  int onsetSec,
  int offsetSec,
) {
  const absent = SleepCyclesResult(<SleepCycle>[], null, 0);
  if (rrMs.isEmpty || rrTsMs.length != rrMs.length || offsetSec <= onsetSec) {
    return absent;
  }
  final nMin = (offsetSec - onsetSec) ~/ 60;
  if (nMin < 60) return absent; // < 1 h of window → no meaningful cycles

  // ── per-minute RMSSD over the window ───────────────────────────────────────
  final perMin = List<double?>.filled(nMin, null);
  final bins = List<List<double>>.generate(nMin, (_) => <double>[]);
  for (var k = 0; k < rrMs.length; k++) {
    final m = (rrTsMs[k] ~/ 1000 - onsetSec) ~/ 60;
    if (m < 0 || m >= nMin) continue;
    final v = rrMs[k];
    if (v >= _rrMin && v <= _rrMax) bins[m].add(v);
  }
  for (var m = 0; m < nMin; m++) {
    perMin[m] = _rmssd(bins[m]);
  }

  // ── smooth (±_smoothMin moving average over present minutes) ───────────────
  final sm = List<double?>.generate(nMin, (i) {
    var s = 0.0, c = 0;
    for (var j = math.max(0, i - _smoothMin);
        j <= math.min(nMin - 1, i + _smoothMin);
        j++) {
      final v = perMin[j];
      if (v != null) {
        s += v;
        c++;
      }
    }
    return c != 0 ? s / c : null;
  });
  final vals = sm.whereType<double>().toList();
  if (vals.length < 60) return absent;

  // ── z-score ────────────────────────────────────────────────────────────────
  final mean = vals.reduce((a, b) => a + b) / vals.length;
  final sd0 = math.sqrt(
      vals.fold<double>(0, (a, b) => a + (b - mean) * (b - mean)) / vals.length);
  final sd = sd0 == 0 ? 1.0 : sd0;
  final z = [for (final x in sm) x == null ? null : (x - mean) / sd];

  // ── prominence-gated peaks → peak-to-peak cycles ───────────────────────────
  final peaks = _findPeaks(z, _minPeakDist, _minProminence);
  final cycles = <SleepCycle>[];
  for (var i = 0; i + 1 < peaks.length; i++) {
    final a = peaks[i], b = peaks[i + 1];
    cycles.add(SleepCycle(a, b, b - a));
  }
  final meanDur = cycles.isEmpty
      ? null
      : cycles.fold<double>(0, (s, c) => s + c.lenMin) / cycles.length;

  // The continuous z-RMSSD wave the graph plots: one point per present minute,
  // t = absolute epoch seconds (onset + minute), z rounded to 3 dp.
  final series = <Map<String, dynamic>>[];
  for (var m = 0; m < nMin; m++) {
    final zv = z[m];
    if (zv != null) {
      series.add({'t': onsetSec + m * 60, 'z': (zv * 1000).round() / 1000.0});
    }
  }
  return SleepCyclesResult(cycles, meanDur, cycles.length, series);
}

double? _rmssd(List<double> rr) {
  if (rr.length < 10) return null;
  var s = 0.0, n = 0;
  for (var i = 1; i < rr.length; i++) {
    final d = rr[i] - rr[i - 1];
    if (d.abs() > _rrStep) continue; // drop ectopic jumps
    s += d * d;
    n++;
  }
  return n >= 1 ? math.sqrt(s / n) : null;
}

/// Local maxima with z-prominence ≥ [minProm], pruned to ≥ [minDist] apart
/// (tallest-first). Returns peak minute-indices, ascending.
List<int> _findPeaks(List<double?> y, int minDist, double minProm) {
  final n = y.length;
  final cand = <List<double>>[]; // [index, value]
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
    var lmin = yi, rmin = yi;
    for (var k = l; k <= i; k++) {
      final v = y[k];
      if (v != null && v < lmin) lmin = v;
    }
    for (var k = i; k <= r; k++) {
      final v = y[k];
      if (v != null && v < rmin) rmin = v;
    }
    if (yi - math.max(lmin, rmin) >= minProm) cand.add([i.toDouble(), yi]);
  }
  cand.sort((p, q) => q[1].compareTo(p[1])); // tallest first
  final kept = <int>[];
  for (final c in cand) {
    final idx = c[0].toInt();
    if (kept.every((k) => (idx - k).abs() >= minDist)) kept.add(idx);
  }
  kept.sort();
  return kept;
}

/// Metric envelope wrapper (HRV-derived ESTIMATE).
Metric<SleepCyclesResult> sleepCyclesMetric(
  List<double> rrMs,
  List<double> rrTsMs,
  int onsetSec,
  int offsetSec,
) {
  final r = detectSleepCycles(rrMs, rrTsMs, onsetSec, offsetSec);
  if (r.n == 0) {
    return const Metric<SleepCyclesResult>.absent(
      tier: Tier.estimate,
      inputs_used: ['rr_cleaned'],
      note: 'need ≥1 h sleep window with sufficient RR for cycle detection',
    );
  }
  return Metric<SleepCyclesResult>(
    value: r,
    confidence: 0.5,
    tier: Tier.estimate,
    inputs_used: const ['rr_cleaned'],
    note: 'fractal-cycle method (Rosenblum 2024) on per-minute RMSSD; '
        'peak-to-peak ultradian cycles, HRV-derived ESTIMATE (not PSG)',
  );
}
