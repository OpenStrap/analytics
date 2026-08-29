// CV-06 — THE SHAPE OF YOUR NIGHT. Per-bin RMSSD across the sleep window.
//
// Pure description. No model, no schema, no cause. The edge already bins the
// night's cleaned NN into ~30-min windows for respiration (`_respPerWindow`);
// this is that same binning with RMSSD in place of the spectral estimator.
//
// WHAT IT MAY SAY: "variability was low for the first third and climbed after
// that". WHAT IT MAY NEVER SAY: why. A suppressed first third is consistent
// with alcohol, a late meal, late training, a hot room, illness onset, or
// nothing at all — and this function cannot tell those apart, so no caller may
// attach one.
//
// DROPPED ON PURPOSE (the IDEAS entry's own cut): "time to the first bin within
// 10% of the night's max". It is anchored on the noisiest statistic in the
// series — a single high bin moves the anchor — and it jumps by hours between
// adjacent nights on identical physiology. It is not implemented here and must
// not be added.
//
// TWO HONESTY RULES ARE STRUCTURAL, not styling:
//   * a bin under the beat floor ABSTAINS and stays in the series as a hole,
//     so a curve breaks across a charging gap instead of drawing through it;
//   * every bin ships lo/hi as well as a point, because RMSSD from a few
//     hundred beats has real sampling spread and a single line drawn through
//     the points claims a precision the beats do not carry. Render a BAND.

import 'dart:math' as math;
import '../types.dart';
import '../util.dart';
import '../clinical/hrv_time.dart';

/// One ~30-min bin of the night.
class NightHrvBin {
  /// Bin start, seconds from the first beat of the night.
  final int startSec;

  /// Beats that landed in this bin (published even when the bin abstains —
  /// "we had 40 beats here" is the reason, and it is not a bare dash).
  final int nBeats;

  /// Bin RMSSD (ms), or NULL when the bin is under the beat floor.
  final double? rmssdMs;

  /// Sampling band around [rmssdMs] (ms). Null exactly when [rmssdMs] is.
  final double? loMs;
  final double? hiMs;

  const NightHrvBin({
    required this.startSec,
    required this.nBeats,
    required this.rmssdMs,
    required this.loMs,
    required this.hiMs,
  });

  bool get present => rmssdMs != null;

  Map<String, dynamic> toJson() => {
        't': startSec,
        'n_beats': nBeats,
        'rmssd_ms': rmssdMs == null ? null : round6(rmssdMs!),
        'lo_ms': loMs == null ? null : round6(loMs!),
        'hi_ms': hiMs == null ? null : round6(hiMs!),
      };
}

class NightHrvShape {
  final List<NightHrvBin> bins;

  /// Mean RMSSD over the PRESENT bins of the first / last third of the night.
  /// Both null unless each third holds at least [_minBinsPerThird] present
  /// bins — one bin is not a third.
  final double? firstThirdMs;
  final double? lastThirdMs;

  /// [lastThirdMs] / [firstThirdMs]. Null whenever either side is.
  final double? lastOverFirst;

  const NightHrvShape({
    required this.bins,
    required this.firstThirdMs,
    required this.lastThirdMs,
    required this.lastOverFirst,
  });

  Map<String, dynamic> toJson() => {
        'bins': [for (final b in bins) b.toJson()],
        'first_third_ms': firstThirdMs == null ? null : round6(firstThirdMs!),
        'last_third_ms': lastThirdMs == null ? null : round6(lastThirdMs!),
        'last_over_first':
            lastOverFirst == null ? null : round6(lastOverFirst!),
      };
}

/// A third needs this many PRESENT bins before it gets a mean.
const int _minBinsPerThird = 2;

/// Beats a bin needs before it publishes an RMSSD.
///
/// A CHOICE. A 30-min bin at a nocturnal HR of 50 holds ~900 beats, so 300 is
/// roughly a third of a well-covered bin — enough that the estimate is not
/// dominated by one noisy stretch, low enough that a partly-gapped bin still
/// counts. It travels in the signature so a caller can widen the bins and
/// raise it together.
const int kMinBeatsPerHrvBin = 300;

/// CV-06 — per-bin RMSSD across the night.
///
/// [nnMs] cleaned NN intervals (ms) and [nnTimesMs] their beat times (ms), the
/// same pair everything else in this package consumes — run `correctRr` first.
/// [binMin] is the bin width; the IDEAS entry says to widen to 45–60 min if
/// 30-min bins look wobbly on real nights, so it is a parameter, not a
/// constant.
Metric<NightHrvShape> nightHrvShape(
  List<double> nnMs,
  List<double> nnTimesMs, {
  double binMin = 30,
  int minBeatsPerBin = kMinBeatsPerHrvBin,
}) {
  const inputs = ['rr_cleaned', 'beat_times'];
  if (nnMs.length != nnTimesMs.length || nnMs.length < minBeatsPerBin) {
    return Metric<NightHrvShape>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'too few beats for a nightly shape '
          '(${nnMs.length}, need ≥$minBeatsPerBin)',
    );
  }
  final binMs = binMin * 60000.0;
  final t0 = nnTimesMs.first;
  final span = nnTimesMs.last - t0;
  final nBins = math.max(1, (span / binMs).ceil());
  if (nBins < 3) {
    return Metric<NightHrvShape>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note:
          'night spans ${(span / 3600000).toStringAsFixed(1)} h — under three '
          '${binMin.round()}-min bins there is no shape to describe',
    );
  }

  final bins = <NightHrvBin>[];
  var k = 0;
  for (var b = 0; b < nBins; b++) {
    final hi = t0 + (b + 1) * binMs;
    final start = k;
    while (k < nnTimesMs.length && nnTimesMs[k] < hi) {
      k++;
    }
    final n = k - start;
    if (n < minBeatsPerBin) {
      // A HOLE, kept in the series. Dropping it would let a caller draw a
      // straight line across a charging gap and call it flat variability.
      bins.add(NightHrvBin(
        startSec: (b * binMs / 1000).round(),
        nBeats: n,
        rmssdMs: null,
        loMs: null,
        hiMs: null,
      ));
      continue;
    }
    final m = hrvTime(
      nnMs.sublist(start, k),
      nnTimesMs: nnTimesMs.sublist(start, k),
    );
    final rmssd = m.value?.rmssd;
    // Sampling spread of an RMSSD from `n` successive differences. RMSSD is a
    // root-mean-square, so its relative standard error is ~1/sqrt(2n); ±1.96 of
    // those is the band. It is the estimator's own noise, NOT a physiological
    // range and NOT a confidence interval on anything the user did.
    final se = rmssd == null ? null : rmssd / math.sqrt(2 * n);
    bins.add(NightHrvBin(
      startSec: (b * binMs / 1000).round(),
      nBeats: n,
      rmssdMs: rmssd,
      loMs: se == null ? null : math.max(0.0, rmssd! - 1.96 * se),
      hiMs: se == null ? null : rmssd! + 1.96 * se,
    ));
  }

  final third = bins.length ~/ 3;
  double? meanOf(Iterable<NightHrvBin> xs) {
    final v = [
      for (final b in xs)
        if (b.present) b.rmssdMs!
    ];
    return v.length < _minBinsPerThird ? null : mean(v);
  }

  final first = meanOf(bins.take(third));
  final last = meanOf(bins.skip(bins.length - third));
  final ratio =
      (first == null || last == null || first == 0) ? null : last / first;

  return Metric<NightHrvShape>(
    value: NightHrvShape(
      bins: bins,
      firstThirdMs: first,
      lastThirdMs: last,
      lastOverFirst: ratio,
    ),
    // Bounded by how many bins actually carried beats — a night that abstained
    // on half its bins is not a shape you can read.
    confidence: (0.8 * bins.where((b) => b.present).length / bins.length)
        .clamp(0.0, 0.8),
    tier: Tier.high,
    inputs_used: inputs,
    note: 'per-bin RMSSD (${binMin.round()}-min bins, PRV not ECG-HRV) — a '
        'DESCRIPTION of the night, never a cause. A low first third is equally '
        'consistent with alcohol, a late meal, late training, a warm room, '
        'illness onset, or nothing. Render each bin as a band, not a point.',
  );
}
