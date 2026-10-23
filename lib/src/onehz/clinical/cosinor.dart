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

import 'dart:typed_data';
import '../../aggregate/aggregator.dart';
import '../types.dart';
import '../util.dart';
import 'cosinor_aggregator.dart';

class CosinorFit {
  final double mesor; // rhythm-adjusted mean
  final double amplitude; // half the peak-to-trough range
  final double acrophaseRad; // phase of the peak (rad), in [-π, π]
  final double acrophaseHours; // acrophase expressed as clock-hours of [period]
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
  });
  Map<String, dynamic> toJson() => {
        'mesor': round6(mesor),
        'amplitude': round6(amplitude),
        'acrophase_rad': round6(acrophaseRad),
        'acrophase_hours': round6(acrophaseHours),
        'period_hours': round6(periodHours),
        'r2': round6(r2),
        'r2_adj': round6(r2Adj),
      };
}

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
  // Runs [cosinorAggregator] over the whole series in one slice. Mismatched
  // lengths cannot be a [TimedValues] batch; they are the same "too few
  // points" refusal as before.
  if (tHours.length != y.length) {
    return const Metric<CosinorFit>.absent(
      tier: Tier.high,
      inputs_used: ['signal_timeseries'],
      note: 'too few points for cosinor',
    );
  }
  return cosinorAggregator(periodHours: periodHours, minPoints: minPoints)
      .run(TimedValues(
          Float64List.fromList(tHours), Float64List.fromList(y)));
}

