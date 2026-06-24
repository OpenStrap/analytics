// CLINICAL TIER-1 / SHARED — single-component cosinor (Halberg / Nelson 1979).
//
// Fits y(t) = MESOR + amplitude·cos(2π·t/period + acrophase) by ORDINARY LEAST
// SQUARES on the linearized model y = M + β·cos(ωt) + γ·sin(ωt), with
//   amplitude = √(β²+γ²),  acrophase = atan2(−γ, β).
// Reports R² (goodness of fit). One engine, reused for HR / activity / temp /
// each HRV index (catalog: "implement once, reuse everywhere").
//
// HONESTY: circadian phase should be anchored on the nocturnal trough, never
// the daytime peak — callers choose the period and supply trough-anchored
// times; this engine just fits. R² is reported so a poor fit is visible.

import 'dart:math' as math;
import '../types.dart';
import '../util.dart';

class CosinorFit {
  final double mesor; // rhythm-adjusted mean
  final double amplitude; // half the peak-to-trough range
  final double acrophaseRad; // phase of the peak (rad), in [-π, π]
  final double acrophaseHours; // acrophase expressed as clock-hours of [period]
  final double periodHours;
  final double r2; // goodness of fit (0..1)
  const CosinorFit({
    required this.mesor,
    required this.amplitude,
    required this.acrophaseRad,
    required this.acrophaseHours,
    required this.periodHours,
    required this.r2,
  });
  Map<String, dynamic> toJson() => {
        'mesor': round6(mesor),
        'amplitude': round6(amplitude),
        'acrophase_rad': round6(acrophaseRad),
        'acrophase_hours': round6(acrophaseHours),
        'period_hours': round6(periodHours),
        'r2': round6(r2),
      };
}

/// Single-component cosinor fit.
///
/// [tHours] sample times in hours (any origin). [y] sample values. [periodHours]
/// the rhythm period (default 24). Needs ≥4 points and non-degenerate design.
Metric<CosinorFit> cosinor(
  List<double> tHours,
  List<double> y, {
  double periodHours = 24,
}) {
  const inputs = ['signal_timeseries'];
  final n = y.length;
  if (n < 4 || tHours.length != n || periodHours <= 0) {
    return const Metric<CosinorFit>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'too few points for cosinor',
    );
  }
  final w = 2 * math.pi / periodHours;
  final c = [for (final t in tHours) math.cos(w * t)];
  final s = [for (final t in tHours) math.sin(w * t)];

  // Normal equations for [M, β, γ] of y = M + β·c + γ·s.
  // Build 3×3 symmetric system.
  var sC = 0.0, sS = 0.0, sCC = 0.0, sSS = 0.0, sCS = 0.0;
  var sY = 0.0, sYC = 0.0, sYS = 0.0;
  for (var i = 0; i < n; i++) {
    sC += c[i];
    sS += s[i];
    sCC += c[i] * c[i];
    sSS += s[i] * s[i];
    sCS += c[i] * s[i];
    sY += y[i];
    sYC += y[i] * c[i];
    sYS += y[i] * s[i];
  }
  // Matrix A = [[n, sC, sS],[sC, sCC, sCS],[sS, sCS, sSS]], b=[sY,sYC,sYS].
  final a = [
    [n.toDouble(), sC, sS],
    [sC, sCC, sCS],
    [sS, sCS, sSS],
  ];
  final b = [sY, sYC, sYS];
  final sol = _solve3(a, b);
  if (sol == null) {
    return const Metric<CosinorFit>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'singular cosinor design (insufficient phase coverage)',
    );
  }
  final mesor = sol[0];
  final beta = sol[1];
  final gamma = sol[2];
  final amplitude = math.sqrt(beta * beta + gamma * gamma);
  final acro = math.atan2(-gamma, beta); // peak phase
  // Convert acrophase to clock-hours within the period (0..period).
  var phaseHours = -acro / w; // time of peak relative to origin
  phaseHours = phaseHours % periodHours;
  if (phaseHours < 0) phaseHours += periodHours;

  // R².
  final yMean = sY / n;
  var ssTot = 0.0, ssRes = 0.0;
  for (var i = 0; i < n; i++) {
    final fit = mesor + beta * c[i] + gamma * s[i];
    ssTot += (y[i] - yMean) * (y[i] - yMean);
    ssRes += (y[i] - fit) * (y[i] - fit);
  }
  final r2 = ssTot == 0 ? 0.0 : clamp(1 - ssRes / ssTot, 0, 1);

  final conf = clamp(r2, 0.1, 0.95);
  return Metric<CosinorFit>(
    value: CosinorFit(
      mesor: mesor,
      amplitude: amplitude,
      acrophaseRad: acro,
      acrophaseHours: phaseHours,
      periodHours: periodHours,
      r2: r2,
    ),
    confidence: conf,
    tier: Tier.high,
    inputs_used: inputs,
    note: 'single-component cosinor; anchor circadian phase on the nocturnal '
        'trough, not the daytime peak',
  );
}

/// Solve a 3×3 linear system by Gaussian elimination with partial pivoting.
/// Returns null if singular.
List<double>? _solve3(List<List<double>> a, List<double> b) {
  final m = [
    [a[0][0], a[0][1], a[0][2], b[0]],
    [a[1][0], a[1][1], a[1][2], b[1]],
    [a[2][0], a[2][1], a[2][2], b[2]],
  ];
  for (var col = 0; col < 3; col++) {
    var piv = col;
    for (var r = col + 1; r < 3; r++) {
      if (m[r][col].abs() > m[piv][col].abs()) piv = r;
    }
    if (m[piv][col].abs() < 1e-12) return null;
    final tmp = m[col];
    m[col] = m[piv];
    m[piv] = tmp;
    final d = m[col][col];
    for (var j = col; j < 4; j++) {
      m[col][j] /= d;
    }
    for (var r = 0; r < 3; r++) {
      if (r == col) continue;
      final f = m[r][col];
      for (var j = col; j < 4; j++) {
        m[r][j] -= f * m[col][j];
      }
    }
  }
  return [m[0][3], m[1][3], m[2][3]];
}
