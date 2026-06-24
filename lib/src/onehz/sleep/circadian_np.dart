// SLEEP/CIRCADIAN TIER-1 — nonparametric circadian rhythm metrics.
//
// Witting 1990 / van Someren 1999 (the standard actigraphy circadian battery),
// computed over an activity (ENMO surrogate) or HR series binned to a fixed
// epoch (default 60 min). Companion to the parametric cosinor engine.
//
//   IS (Interdaily Stability)  — strength of coupling to the 24-h zeitgeber:
//       IS = (n · Σ_h (x̄_h − x̄)²) / (p · Σ_i (x_i − x̄)²),  0..1, →1 = stable.
//   IV (Intradaily Variability) — fragmentation (transitions hour-to-hour):
//       IV = (n · Σ_i (x_i − x_{i−1})²) / ((n−1) · Σ_i (x_i − x̄)²), →0 = smooth.
//   M10 — mean of the most-active 10 contiguous hours (and its start hour).
//   L5  — mean of the least-active 5 contiguous hours (and its start hour).
//   RA (Relative Amplitude) = (M10 − L5) / (M10 + L5),  0..1, →1 = robust rhythm.
//
// where n = total epochs, p = epochs per day, x̄_h = mean of epoch-of-day h.
//
// HONESTY: anchor circadian phase on the nocturnal trough (L5), never the
// daytime peak — L5 is the trough-anchored marker the catalog requires.

import 'dart:math' as math;
import '../types.dart';
import '../util.dart';

class CircadianNp {
  final double interdailyStability; // IS
  final double intradailyVariability; // IV
  final double m10; // most-active 10 h mean
  final double l5; // least-active 5 h mean
  final double relativeAmplitude; // RA
  final int m10StartEpoch; // start epoch index (within a day)
  final int l5StartEpoch;
  const CircadianNp({
    required this.interdailyStability,
    required this.intradailyVariability,
    required this.m10,
    required this.l5,
    required this.relativeAmplitude,
    required this.m10StartEpoch,
    required this.l5StartEpoch,
  });
  Map<String, dynamic> toJson() => {
        'IS': round6(interdailyStability),
        'IV': round6(intradailyVariability),
        'M10': round6(m10),
        'L5': round6(l5),
        'RA': round6(relativeAmplitude),
        'm10_start_epoch': m10StartEpoch,
        'l5_start_epoch': l5StartEpoch,
      };
}

/// Nonparametric circadian metrics over an epoch-binned activity/HR series.
///
/// [x] activity (or HR) per epoch, laid out as consecutive days of exactly
/// [epochsPerDay] epochs. Needs ≥1 full day for IS/IV; M10/L5 need ≥`m10Epochs`
/// epochs. [epochMin] is informational only (epochs are pre-binned).
Metric<CircadianNp> circadianNonparametric(
  List<double> x,
  int epochsPerDay, {
  int? m10Epochs,
  int? l5Epochs,
}) {
  const inputs = ['activity_or_hr_epochs'];
  final n = x.length;
  if (epochsPerDay <= 0 || n < epochsPerDay) {
    return const Metric<CircadianNp>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'need ≥1 full day of epochs for circadian metrics',
    );
  }
  // M10 = 10 h, L5 = 5 h scaled to the epoch resolution.
  final mEp = m10Epochs ?? (epochsPerDay * 10 ~/ 24);
  final lEp = l5Epochs ?? (epochsPerDay * 5 ~/ 24);

  final grand = mean(x)!;
  var ssTot = 0.0;
  for (final v in x) {
    final d = v - grand;
    ssTot += d * d;
  }
  if (ssTot == 0) {
    return const Metric<CircadianNp>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'no variance in activity series',
    );
  }

  // IS: between-epoch-of-day variance vs total variance.
  final p = epochsPerDay;
  final hourMeans = List<double>.filled(p, 0);
  final hourCounts = List<int>.filled(p, 0);
  for (var i = 0; i < n; i++) {
    final h = i % p;
    hourMeans[h] += x[i];
    hourCounts[h]++;
  }
  for (var h = 0; h < p; h++) {
    if (hourCounts[h] > 0) hourMeans[h] /= hourCounts[h];
  }
  var ssHour = 0.0;
  for (var h = 0; h < p; h++) {
    final d = hourMeans[h] - grand;
    ssHour += d * d;
  }
  final is_ = (n * ssHour) / (p * ssTot);

  // IV: mean-squared successive difference vs variance.
  var ssDiff = 0.0;
  for (var i = 1; i < n; i++) {
    final d = x[i] - x[i - 1];
    ssDiff += d * d;
  }
  final iv = (n * ssDiff) / ((n - 1) * ssTot);

  // M10 / L5: best contiguous window over the AVERAGE day profile (hourMeans),
  // circularly, so a window straddling midnight is allowed.
  final m10 = _bestWindow(hourMeans, mEp, maximize: true);
  final l5 = _bestWindow(hourMeans, lEp, maximize: false);
  final ra = (m10.value + l5.value) > 0
      ? (m10.value - l5.value) / (m10.value + l5.value)
      : 0.0;

  final days = n / epochsPerDay;
  final conf = clamp(days / 7.0, 0.3, 0.95);
  return Metric<CircadianNp>(
    value: CircadianNp(
      interdailyStability: clamp(is_, 0, 1),
      intradailyVariability: math.max(0, iv),
      m10: m10.value,
      l5: l5.value,
      relativeAmplitude: clamp(ra, 0, 1),
      m10StartEpoch: m10.start,
      l5StartEpoch: l5.start,
    ),
    confidence: conf,
    tier: Tier.high,
    inputs_used: inputs,
    note: 'IS/IV/RA/L5/M10 (van Someren 1999); circadian phase anchored on the '
        'L5 nocturnal trough, not the daytime peak',
  );
}

class _Window {
  final double value;
  final int start;
  const _Window(this.value, this.start);
}

/// Best (max or min) mean over a contiguous circular window of length [w].
_Window _bestWindow(List<double> profile, int w, {required bool maximize}) {
  final p = profile.length;
  if (w >= p) {
    return _Window(mean(profile) ?? 0, 0);
  }
  double? best;
  var bestStart = 0;
  for (var s = 0; s < p; s++) {
    var sum = 0.0;
    for (var k = 0; k < w; k++) {
      sum += profile[(s + k) % p];
    }
    final m = sum / w;
    if (best == null ||
        (maximize ? m > best : m < best)) {
      best = m;
      bestStart = s;
    }
  }
  return _Window(best ?? 0, bestStart);
}
