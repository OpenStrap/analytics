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
  /// Phase of the peak (rad), in [-π, π]. Null when the zero-amplitude F-test
  /// does not reject (Nelson 1979): with no resolvable rhythm the angle of
  /// (β, γ) is set by noise or rounding, not by the data, and a caller would
  /// otherwise present it as the user's own peak time.
  final double? acrophaseRad;
  final double? acrophaseHours; // acrophase expressed as clock-hours of [period]

  /// p-value of the zero-amplitude F-test, F(2, n−3).
  final double amplitudeP;
  final double periodHours;
  final double r2; // raw goodness of fit (0..1)

  /// R² adjusted for the 3 fitted parameters (M, β, γ):
  /// R²adj = 1 − (1−R²)·(n−1)/(n−3). This is the honest fit quality — the raw
  /// R² of a 3-parameter fit is upward-biased and approaches 1 as n → 3.
  final double r2Adj;
  const CosinorFit({
    required this.mesor,
    required this.amplitude,
    required this.acrophaseRad,
    required this.acrophaseHours,
    required this.periodHours,
    required this.r2,
    required this.r2Adj,
    required this.amplitudeP,
  });
  Map<String, dynamic> toJson() => {
        'mesor': round6(mesor),
        'amplitude': round6(amplitude),
        'acrophase_rad': acrophaseRad == null ? null : round6(acrophaseRad!),
        'acrophase_hours':
            acrophaseHours == null ? null : round6(acrophaseHours!),
        'period_hours': round6(periodHours),
        'r2': round6(r2),
        'r2_adj': round6(r2Adj),
        'amplitude_p': round6(amplitudeP),
      };
}

/// Significance level of the zero-amplitude test below which the acrophase is
/// reported.
const double cosinorAcrophaseAlpha = 0.05;


/// Minimum samples for a cosinor fit. The model has 3 free parameters
/// (M, β, γ); with n = 4 there is a single residual degree of freedom, so R²
/// is essentially an interpolation score (4 RANDOM points routinely fit at
/// r² 0.76–0.99). Halberg's zero-amplitude test needs real residual dof, so we
/// require ≥8 samples over the period and report the ADJUSTED R².
const int cosinorMinPoints = 8;

/// Single-component cosinor fit.
///
/// [tHours] sample times in hours (any origin). [y] sample values. [periodHours]
/// the rhythm period (default 24). Needs ≥[minPoints] points and a
/// non-degenerate design.
Metric<CosinorFit> cosinor(
  List<double> tHours,
  List<double> y, {
  double periodHours = 24,
  int minPoints = cosinorMinPoints,
}) {
  if (tHours.length != y.length) {
    return const Metric<CosinorFit>.absent(tier: Tier.high,
      inputs_used: ['signal_timeseries'], note: 'too few points for cosinor');
  }
  final state = _CosinorState();
  final w = 2 * math.pi / periodHours;
  for (var i = 0; i < y.length; i++) {
    state.addCentered(math.cos(w * tHours[i]), math.sin(w * tHours[i]), y[i]);
  }
  return _finishCosinor(state, periodHours: periodHours, minPoints: minPoints);
}

// Nelson et al. (1979), Methods for cosinor-rhythmometry.
// Centered least squares changes rounding. Relative 1e-12 gate is a
// numerical identifiability policy, not a physiological cutoff.
class _CosinorState {
  var n = 0;
  var meanC = 0.0;
  var meanS = 0.0;
  var meanY = 0.0;
  var mCC = 0.0;
  var mSS = 0.0;
  var mYY = 0.0;
  var mCS = 0.0;
  var mCY = 0.0;
  var mSY = 0.0;

  void addCentered(double c, double s, double y) {
    final nextN = n + 1;
    final dc = c - meanC;
    final ds = s - meanS;
    final dy = y - meanY;
    final nextMeanC = meanC + dc / nextN;
    final nextMeanS = meanS + ds / nextN;
    final nextMeanY = meanY + dy / nextN;
    mCC += dc * (c - nextMeanC);
    mSS += ds * (s - nextMeanS);
    mYY += dy * (y - nextMeanY);
    mCS += dc * (s - nextMeanS);
    mCY += dc * (y - nextMeanY);
    mSY += ds * (y - nextMeanY);
    meanC = nextMeanC;
    meanS = nextMeanS;
    meanY = nextMeanY;
    n = nextN;
  }

}

Metric<CosinorFit> _finishCosinor(
  _CosinorState state, {
  required double periodHours,
  required int minPoints,
}) {
  const inputs = ['signal_timeseries'];
  final n = state.n;
  if (n < math.max(4, minPoints) || periodHours <= 0) {
    return const Metric<CosinorFit>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'too few points for cosinor',
    );
  }
  final determinant = state.mCC * state.mSS - state.mCS * state.mCS;
  // The determinant is relative to the diagonal co-moments.  A design needs
  // at least 1e-12 of that scale after removing its means to identify both
  // cosine coefficients; below that, numerical noise decides the fit.
  if (determinant <= 1e-12 * state.mCC * state.mSS) {
    return const Metric<CosinorFit>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'singular cosinor design (insufficient phase coverage)',
    );
  }
  final beta =
      (state.mCY * state.mSS - state.mSY * state.mCS) / determinant;
  final gamma =
      (state.mSY * state.mCC - state.mCY * state.mCS) / determinant;
  final mesor = state.meanY - beta * state.meanC - gamma * state.meanS;
  final amplitude = math.sqrt(beta * beta + gamma * gamma);
  final acro = math.atan2(-gamma, beta);
  final w = 2 * math.pi / periodHours;
  var phaseHours = -acro / w;
  phaseHours = phaseHours % periodHours;
  if (phaseHours < 0) phaseHours += periodHours;

  final ssTot = state.mYY;
  final ssRes = state.mYY -
      2 * beta * state.mCY -
      2 * gamma * state.mSY +
      beta * beta * state.mCC +
      gamma * gamma * state.mSS +
      2 * beta * gamma * state.mCS;
  final double r2 = ssTot == 0 ? 0.0 : (1 - ssRes / ssTot).clamp(0, 1);
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
    confidence: r2Adj.clamp(0.1, 0.95),
    tier: Tier.high,
    inputs_used: inputs,
    note: phaseDefined
        ? 'single-component cosinor; anchor circadian phase on the nocturnal '
            'trough, not the daytime peak'
        : 'single-component cosinor; no resolvable rhythm '
            '(zero-amplitude test not rejected), acrophase undefined',
  );
}


/// Upper tail of F(2, d): P(F > f) = (1 + 2f/d)^(−d/2), exact for 2 numerator
/// degrees of freedom.
double _f2Survival(double f, int d) {
  if (f.isNaN) return 1.0;
  if (f.isInfinite) return 0.0;
  if (f <= 0) return 1.0;
  return math.pow(1 + 2 * f / d, -d / 2).toDouble();
}
