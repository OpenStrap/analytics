// RESPIRATION TIER-1 — CVHR / ACAT apnea SCREEN (Hayano 2011).
//
// Cyclic Variation of Heart Rate is the cardiac signature of sleep-disordered
// breathing: each apnea/hypopnea episode produces a bradycardia during the
// event followed by a tachycardia at the arousal/resumption of breathing,
// recurring with a ~20–120 s period. Hayano's Autonomic Cardiac Activity
// (ACAT) / ACT algorithm scores these cycles RR-only (r≈0.84 vs AHI), needs
// zero calibration, and runs all night on our continuous beat-to-beat RR — our
// structural edge.
//
// Method (ACAT-style, deterministic):
//   1. Build a 1 Hz HR-equivalent envelope from cleaned NN (instantaneous HR
//      = 60000/NN), smoothed with a 2nd-order (quadratic) Savitzky-Golay-like
//      local polynomial to suppress beat jitter while preserving cycle shape.
//   2. Adaptive 5th / 95th percentile envelopes over a sliding ~130 s window
//      define the "normal band"; a dip = an excursion below the 5th-pct
//      envelope of width 10–120 s.
//   3. Keep a dip as a CVHR cycle only if depth-to-width ratio > 0.7 ms/s
//      (the steep bradycardia-then-tachycardia signature, not slow drift).
//   4. CVHR cycles per hour => an apnea SCREEN index (NOT an AHI, NOT a
//      diagnosis). Report night-to-night variability caveat.
//
// HONESTY: this is a SCREEN. We never output an AHI or a clinical category, and
// we flag that single-night CVHR has substantial night-to-night variability.

import 'dart:math' as math;
import '../types.dart';
import '../util.dart';

class CvhrResult {
  final int cycleCount; // detected CVHR cycles
  final double cvhrPerHour; // cycles / hour (the screen index)
  final double analyzedHours; // night length analyzed
  final double meanDepthMs; // mean dip depth (ms of NN excursion)
  final double meanWidthSec; // mean dip width (s)
  const CvhrResult({
    required this.cycleCount,
    required this.cvhrPerHour,
    required this.analyzedHours,
    required this.meanDepthMs,
    required this.meanWidthSec,
  });
  Map<String, dynamic> toJson() => {
        'cycle_count': cycleCount,
        'cvhr_per_hour': round6(cvhrPerHour),
        'analyzed_hours': round6(analyzedHours),
        'mean_depth_ms': round6(meanDepthMs),
        'mean_width_sec': round6(meanWidthSec),
      };
}

/// CVHR / ACAT apnea screen on a cleaned NN series.
///
/// [nnMs] cleaned NN intervals (ms), [nnTimesMs] their cumulative beat times
/// (ms). [artifactFraction] from RR-correction. Tunables follow Hayano:
/// dip width 10–120 s, depth/width ratio > 0.7 ms/s, ~130 s percentile window.
Metric<CvhrResult> cvhrApneaScreen(
  List<double> nnMs,
  List<double> nnTimesMs, {
  required double artifactFraction,
  double minWidthSec = 10,
  double maxWidthSec = 120,
  double depthWidthRatioMin = 0.7, // ms per second
  double envWindowSec = 130,
  double maxArtifact = 0.30,
}) {
  const inputs = ['rr_cleaned', 'beat_times'];
  if (nnMs.length < 60 || nnTimesMs.length != nnMs.length) {
    return const Metric<CvhrResult>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'too few beats for a CVHR screen (need ≥60)',
    );
  }
  if (artifactFraction > maxArtifact) {
    return Metric<CvhrResult>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'artifact fraction ${round6(artifactFraction)} > gate '
          '— CVHR dip detection unreliable',
    );
  }

  // Resample NN onto a uniform 1 Hz grid by piecewise-linear interpolation of
  // the tachogram (NN vs beat time). This gives evenly-spaced points for the
  // sliding-window percentile envelopes and the polynomial smoother. (Times in
  // seconds.)
  final tSec = [for (final t in nnTimesMs) t / 1000.0];
  final t0 = tSec.first;
  final t1 = tSec.last;
  final analyzedHours = (t1 - t0) / 3600.0;
  if (analyzedHours <= 0) {
    return const Metric<CvhrResult>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'degenerate beat times',
    );
  }
  final nGrid = (t1 - t0).floor() + 1;
  if (nGrid < 60) {
    return const Metric<CvhrResult>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'span too short for a CVHR screen (<60 s)',
    );
  }
  final grid = List<double>.generate(nGrid, (i) => t0 + i);
  final nnGrid = _resampleLinear(tSec, nnMs, grid);

  // 2nd-order local-polynomial smoothing (Savitzky-Golay quadratic, ~7 s half
  // window) to suppress beat jitter while keeping the cyclic shape.
  final smooth = _savgolQuadratic(nnGrid, halfWin: 7);

  // Adaptive baseline over a ~130 s sliding median (spans ≥2 apnea cycles, so
  // it tracks the eupneic level without being pulled into individual dips).
  // The CVHR bradycardia shows up as a local NN MAXIMUM (NN ↑ ⇔ HR ↓) standing
  // proud of this baseline; the following tachycardia is the recovery valley.
  final halfEnv = (envWindowSec / 2).round();
  final base = List<double>.filled(nGrid, 0);
  for (var j = 0; j < nGrid; j++) {
    final lo = math.max(0, j - halfEnv);
    final hi = math.min(nGrid - 1, j + halfEnv);
    base[j] = median(smooth.sublist(lo, hi + 1)) ?? smooth[j];
  }
  // Baseline-subtracted bradycardic excursion (clip negatives — we only score
  // the NN-up bradycardia, not the tachycardia trough).
  final exc = [for (var j = 0; j < nGrid; j++) math.max(0.0, smooth[j] - base[j])];

  // Prominence threshold: a dip must clear a robust noise floor AND a fraction
  // of the typical excursion amplitude. We anchor it BELOW the median positive
  // excursion (Hayano's adaptive amplitude criterion is permissive enough to
  // capture the whole bradycardia run, not just its tip) — a threshold at the
  // peak would clip the run width to a few seconds and miss the cycle.
  final posExc = [for (final e in exc) if (e > 0) e];
  final excP75 = (posExc.isNotEmpty ? percentile(posExc, 75) : null) ?? 0;
  // half of the upper-quartile excursion: well inside each genuine dip's run.
  final prom = math.max(0.5 * excP75, 5.0); // ms

  // Find peaks of `exc`: local maxima exceeding `prom`, each isolated to one
  // contiguous super-threshold run (so one bradycardia = one cycle). Measure
  // the run width and the peak depth; apply the width + depth/width gates.
  var cycleCount = 0;
  final depths = <double>[]; // ms
  final widths = <double>[]; // s
  var i = 0;
  while (i < nGrid) {
    if (exc[i] <= prom) {
      i++;
      continue;
    }
    final start = i;
    var peakDepth = 0.0;
    while (i < nGrid && exc[i] > prom) {
      if (exc[i] > peakDepth) peakDepth = exc[i];
      i++;
    }
    final widthSec = (i - start).toDouble(); // 1 Hz grid => samples == seconds
    if (widthSec < minWidthSec || widthSec > maxWidthSec) continue;
    // Depth-to-width steepness gate (ms per second): the bradycardia-tachycardia
    // swing is steep; slow baseline drift is shallow per second.
    final ratio = peakDepth / widthSec;
    if (ratio < depthWidthRatioMin) continue;
    cycleCount++;
    depths.add(peakDepth);
    widths.add(widthSec);
  }

  final perHour = analyzedHours > 0 ? cycleCount / analyzedHours : 0.0;
  final conf = clamp((1 - artifactFraction) * 0.85, 0.2, 0.85);
  return Metric<CvhrResult>(
    value: CvhrResult(
      cycleCount: cycleCount,
      cvhrPerHour: perHour,
      analyzedHours: analyzedHours,
      meanDepthMs: depths.isEmpty ? 0 : mean(depths)!,
      meanWidthSec: widths.isEmpty ? 0 : mean(widths)!,
    ),
    confidence: conf,
    tier: Tier.high,
    inputs_used: inputs,
    note: 'CVHR/ACAT (Hayano) apnea SCREEN — NOT a diagnosis, NOT an AHI; '
        'single-night CVHR has substantial night-to-night variability, '
        'interpret as a trend over multiple nights',
  );
}

/// Piecewise-linear resample of (t,y) onto a sorted [grid] of times (same unit).
/// Out-of-range grid points clamp to the nearest endpoint value.
List<double> _resampleLinear(
    List<double> t, List<double> y, List<double> grid) {
  final out = List<double>.filled(grid.length, 0);
  var j = 0;
  for (var k = 0; k < grid.length; k++) {
    final g = grid[k];
    if (g <= t.first) {
      out[k] = y.first;
      continue;
    }
    if (g >= t.last) {
      out[k] = y.last;
      continue;
    }
    while (j < t.length - 1 && t[j + 1] < g) {
      j++;
    }
    final t0 = t[j], t1 = t[j + 1];
    final span = t1 - t0;
    final frac = span == 0 ? 0.0 : (g - t0) / span;
    out[k] = y[j] + (y[j + 1] - y[j]) * frac;
  }
  return out;
}

/// 2nd-order Savitzky-Golay smoothing via a local quadratic least-squares fit
/// over a symmetric window of half-width [halfWin]. Evaluated at the centre.
List<double> _savgolQuadratic(List<double> x, {int halfWin = 7}) {
  final n = x.length;
  final out = List<double>.filled(n, 0);
  for (var i = 0; i < n; i++) {
    final lo = math.max(0, i - halfWin);
    final hi = math.min(n - 1, i + halfWin);
    final m = hi - lo + 1;
    if (m < 3) {
      out[i] = x[i];
      continue;
    }
    // Fit y = a + b·u + c·u² with u centred at i; return a (value at u=0).
    var s0 = 0.0, s1 = 0.0, s2 = 0.0, s3 = 0.0, s4 = 0.0;
    var sy = 0.0, suy = 0.0, su2y = 0.0;
    for (var k = lo; k <= hi; k++) {
      final u = (k - i).toDouble();
      final u2 = u * u;
      s0 += 1;
      s1 += u;
      s2 += u2;
      s3 += u2 * u;
      s4 += u2 * u2;
      sy += x[k];
      suy += u * x[k];
      su2y += u2 * x[k];
    }
    // Solve the 3x3 normal equations for [a,b,c]; we only need a.
    final a = _solve3(
      [s0, s1, s2, s1, s2, s3, s2, s3, s4],
      [sy, suy, su2y],
    );
    out[i] = a == null ? x[i] : a[0];
  }
  return out;
}

/// Solve a 3x3 linear system (row-major A, rhs b) via Cramer's rule. Null if
/// singular.
List<double>? _solve3(List<double> a, List<double> b) {
  double det3(double a0, double a1, double a2, double a3, double a4, double a5,
          double a6, double a7, double a8) =>
      a0 * (a4 * a8 - a5 * a7) -
      a1 * (a3 * a8 - a5 * a6) +
      a2 * (a3 * a7 - a4 * a6);
  final d = det3(a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8]);
  if (d == 0) return null;
  final dx = det3(b[0], a[1], a[2], b[1], a[4], a[5], b[2], a[7], a[8]);
  final dy = det3(a[0], b[0], a[2], a[3], b[1], a[5], a[6], b[2], a[8]);
  final dz = det3(a[0], a[1], b[0], a[3], a[4], b[1], a[6], a[7], b[2]);
  return [dx / d, dy / d, dz / d];
}
