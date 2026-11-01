// Frozen upstream main 9db83ce batch cosinor, independent of the aggregator.
// Only the entry-point name and imports change.
import 'dart:math' as math;
import 'package:openstrap_analytics/onehz.dart';

Metric<CosinorFit> upstreamCosinor(
  List<double> tHours,
  List<double> y, {
  double periodHours = 24,
  int minPoints = cosinorMinPoints,
}) {
  const inputs = ['signal_timeseries'];
  final n = y.length;
  if (n < math.max(4, minPoints) || tHours.length != n || periodHours <= 0) {
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
  final double r2 = ssTot == 0 ? 0.0 : (1 - ssRes / ssTot).clamp(0, 1);
  // Adjusted for the 3 fitted parameters (M, β, γ). Confidence MUST come from
  // the adjusted value: the raw R² of a 3-parameter fit is upward-biased
  // (E[R²] = 2/(n−1) under the null), so a handful of noise points used to
  // score confidence 0.95 at tier HIGH.
  final double r2Adj = (1 - (1 - r2) * (n - 1) / (n - 3)).clamp(0, 1);

  // Zero-amplitude F-test (Nelson 1979): the acrophase is only defined once
  // the test rejects. A flat or rhythm-free series still yields some
  // atan2(−γ, β) from residual noise or float rounding.
  final dof = n - 3;
  final double ampP;
  if (ssTot <= 0) {
    ampP = 1.0;
  } else if (ssRes <= 0) {
    ampP = 0.0;
  } else {
    final f = ((ssTot - ssRes) / 2) / (ssRes / dof);
    ampP = _f2Survival(f, dof);
  }
  final phaseDefined = ampP < cosinorAcrophaseAlpha;

  final conf = r2Adj.clamp(0.1, 0.95);
  return Metric<CosinorFit>(
    value: CosinorFit(
      mesor: mesor,
      amplitude: amplitude,
      acrophaseRad: phaseDefined ? acro : null,
      acrophaseHours: phaseDefined ? phaseHours : null,
      periodHours: periodHours,
      r2: r2,
      r2Adj: r2Adj,
      amplitudeP: ampP,
    ),
    confidence: conf,
    tier: Tier.high,
    inputs_used: inputs,
    note: phaseDefined
        ? 'single-component cosinor; anchor circadian phase on the nocturnal '
            'trough, not the daytime peak'
        : 'single-component cosinor; no resolvable rhythm '
            '(zero-amplitude test not rejected), acrophase undefined',
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

double _f2Survival(double f, int d) {
  if (f.isNaN) return 1.0;
  if (f.isInfinite) return 0.0;
  if (f <= 0) return 1.0;
  return math.pow(1 + 2 * f / d, -d / 2).toDouble();
}
