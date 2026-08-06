/// Derive BPM from gen5 v26 PPG waveform bursts (24 Hz int16 samples).
///
/// Pure, isolate-safe. Absent / degenerate input returns null — never a
/// fabricated BPM.
library;

import 'dart:math' as math;

/// Minimum concatenated PPG length for resting-HR ACF (~10 s @ 24 Hz).
/// Four 1 s bursts cannot resolve 40–55 bpm (needs ≥4 beats in-window).
const int kGen5PpgHrMinSamples = 240;

/// Derive BPM from gen5 v26 PPG (24 Hz int16 samples).
/// [samples] may be one or more concatenated 24-sample bursts.
/// Returns null if too short, low variance, or no clear ACF peak in 25–230 bpm.
int? deriveHrFromGen5PpgWaveform(List<int> samples, {double sampleHz = 24.0}) {
  if (samples.length < kGen5PpgHrMinSamples || sampleHz <= 0) return null;

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

  // Best INTERIOR local peak, with prominence against immediate neighbours.
  //
  // The search deliberately starts at minLag + 1 and stops at maxLag - 1. A
  // periodicity claim needs a real turning point — a lag whose ACF is higher
  // than the lag on EITHER side — and the boundaries of the search range
  // cannot supply that evidence, because one of their neighbours lies outside
  // the range and was never computed.
  //
  // Treating a boundary as a peak is not a harmless edge case, it is the whole
  // fabrication mode. With `left = -infinity` at lag == minLag the `c <= left`
  // rejection can never fire, and the prominence fallback substitutes `c - 1`,
  // which makes prominence 1.0 — maximal. So ANY smoothly decaying ACF (a
  // monotonic decay is exactly what you get from baseline wander, a DC drift,
  // or a motion artifact — signals with no cardiac content whatsoever) was
  // accepted at lag == minLag and reported as a confident 206 bpm, the top of
  // the search range. Measured on this implementation before the change:
  //
  //   baseline wander (pure sine drift, no heartbeat) -> 206
  //   linear ramp (pure DC drift)                     -> 206
  //   single step                                     -> 206
  //
  // 206 bpm from a resting wrist is not a plausible reading, and this function
  // documents that it never fabricates a BPM. Requiring an interior peak makes
  // all three abstain, which is the honest answer.
  var bestLag = -1;
  var bestScore = double.negativeInfinity;
  const minAcf = 0.15;
  // Need at least one lag with a computed neighbour on both sides.
  if (maxLag - minLag < 2) return null;
  for (var lag = minLag + 1; lag <= maxLag - 1; lag++) {
    final c = acf[lag];
    if (c < minAcf) continue;
    final left = acf[lag - 1];
    final right = acf[lag + 1];
    // Strict on both sides: a genuine turning point, not a shoulder.
    if (c <= left || c <= right) continue;
    final prominence = c - math.max(left, right);
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
