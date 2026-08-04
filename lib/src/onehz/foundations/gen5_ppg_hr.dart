/// Derive BPM from gen5 v26 PPG waveform bursts (24 Hz int16 samples).
///
/// Pure, isolate-safe. Absent / degenerate input returns null — never a
/// fabricated BPM.
library;

import 'dart:math' as math;

/// Derive BPM from gen5 v26 PPG (24 Hz int16 samples).
/// [samples] may be one or more concatenated 24-sample bursts.
/// Returns null if too short, low variance, or no clear ACF peak in 25–230 bpm.
int? deriveHrFromGen5PpgWaveform(List<int> samples, {double sampleHz = 24.0}) {
  if (samples.length < 24 || sampleHz <= 0) return null;

  final n = samples.length;
  final xs = List<double>.filled(n, 0);
  var sum = 0.0;
  for (var i = 0; i < n; i++) {
    xs[i] = samples[i].toDouble();
    sum += xs[i];
  }
  final mean = sum / n;
  var energy = 0.0;
  for (var i = 0; i < n; i++) {
    xs[i] -= mean;
    energy += xs[i] * xs[i];
  }
  // Population stddev; flatline / near-constant ADC → abstain.
  final std = math.sqrt(energy / n);
  if (std < 1.0 || energy <= 0) return null;

  // Lag ↔ BPM: bpm = 60 * hz / lag. Search 25–230 bpm inclusive.
  final minLag = math.max(1, (60.0 * sampleHz / 230.0).ceil());
  final maxLag = math.min(n - 1, (60.0 * sampleHz / 25.0).floor());
  if (minLag > maxLag) return null;

  // Normalized autocorrelation (lag-0 energy in the denominator).
  final acf = List<double>.filled(maxLag + 1, 0);
  for (var lag = minLag; lag <= maxLag; lag++) {
    var s = 0.0;
    final lim = n - lag;
    for (var i = 0; i < lim; i++) {
      s += xs[i] * xs[i + lag];
    }
    acf[lag] = s / energy;
  }

  // Best local peak with prominence against immediate neighbors.
  var bestLag = -1;
  var bestScore = double.negativeInfinity;
  const minAcf = 0.15;
  for (var lag = minLag; lag <= maxLag; lag++) {
    final c = acf[lag];
    if (c < minAcf) continue;
    final left = lag > minLag ? acf[lag - 1] : double.negativeInfinity;
    final right = lag < maxLag ? acf[lag + 1] : double.negativeInfinity;
    if (c <= left || c <= right) continue;
    final prominence = c - math.max(left.isFinite ? left : c - 1, right.isFinite ? right : c - 1);
    if (prominence <= 0) continue;
    // Prefer higher ACF; break ties toward the physiologically mid-range lag.
    final score = c + 0.01 * prominence;
    if (score > bestScore) {
      bestScore = score;
      bestLag = lag;
    }
  }
  if (bestLag < 0) return null;

  final hr = (60.0 * sampleHz / bestLag).round();
  if (hr < 25 || hr > 230) return null;
  return hr;
}
