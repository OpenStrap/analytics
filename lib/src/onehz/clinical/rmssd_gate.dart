// Rejection and breathing-line exemption thresholds are an internal rule.
// Welch 1967 spectral estimation; Hirsch & Bishop 1981 provides the
// breathing/RSA basis. This is hrvTime()'s existing internal jitter policy,
// ESTIMATE with low confidence, not a published classifier. Shared formulas
// preserve the calculation; reordered sums can change decisions within rounding
// of a threshold.
// CLINICAL — the spectral half of the RMSSD jitter gate, as pieces.
//
// `hrvTime`, `nocturnalRmssd` and `sleepSessionWindowedRmssd` (hrv_time.dart)
// read the successive-difference runs themselves when the lag-1 ACF is under
// [kNnDiffAcf1Floor]: a respiratory line on a low white floor exempts the night
// ([nnDiffNoiseShare]), and a refused night may still publish from the 5-min
// windows on a breathing line steady in Hz. Both reduce to sums over Welch
// segments, so this file holds them as SUMS plus the decisions over those
// sums, written once: the batch fills the sums from the runs in hand, and
// `hrvTimeAggregator` fills the same sums from mergeable per-chunk state.
//
// Not exported from `onehz.dart`.

import 'dart:math' as math;

import '../util.dart';
import 'hrv_time.dart' show kNnDiffNoiseShareCeiling;

/// Welch segment length (beats) of the noise-share spectrum, the first and last
/// bins of its 0.15–0.5 cycles/beat band.
const int kNoiseSegment = 64, kNoiseLoBin = 10, kNoiseHiBin = kNoiseSegment ~/ 2;

/// The segment's Hann window (symmetric, n − 1 in the denominator).
final List<double> noiseHann = [
  for (var i = 0; i < kNoiseSegment; i++)
    0.5 - 0.5 * math.cos(2 * math.pi * i / (kNoiseSegment - 1))
];

final double _noiseHannSq = () {
  var w2 = 0.0;
  for (final x in noiseHann) {
    w2 += x * x;
  }
  return w2;
}();

final List<List<double>> _cosT = [
  for (var k = kNoiseLoBin; k <= kNoiseHiBin; k++)
    [for (var i = 0; i < kNoiseSegment; i++) math.cos(2 * math.pi * k * i / kNoiseSegment)]
];
final List<List<double>> _sinT = [
  for (var k = kNoiseLoBin; k <= kNoiseHiBin; k++)
    [for (var i = 0; i < kNoiseSegment; i++) math.sin(2 * math.pi * k * i / kNoiseSegment)]
];

/// Adds the Welch segment `x[s .. s + 63]` (RR levels integrated from the
/// differences) to [psd] (bins [kNoiseLoBin]..[kNoiseHiBin]) and returns its
/// band power.
double addNoiseSegment(List<double> x, int s, List<double> psd) {
  const n = kNoiseSegment;
  var m = 0.0;
  for (var i = 0; i < n; i++) {
    m += x[s + i];
  }
  m /= n;
  final v = [for (var i = 0; i < n; i++) (x[s + i] - m) * noiseHann[i]];
  var p = 0.0;
  for (var k = kNoiseLoBin; k <= kNoiseHiBin; k++) {
    final c = _cosT[k - kNoiseLoBin], sn = _sinT[k - kNoiseLoBin];
    var re = 0.0, im = 0.0;
    for (var i = 0; i < n; i++) {
      re += v[i] * c[i];
      im -= v[i] * sn[i];
    }
    psd[k] += re * re + im * im;
    p += re * re + im * im;
  }
  return p;
}

/// The sums [nnDiffNoiseShare] decides on.
class NoiseShareSums {
  final List<double> psd = List<double>.filled(kNoiseHiBin + 1, 0.0);
  int segs = 0, nd = 0;
  double ssd = 0.0, wsd = 0.0, wsum = 0.0, pSum = 0.0, p2Sum = 0.0;

  /// One contiguous run of differences, in the batch's own order.
  void addRun(List<double> r) {
    const n = kNoiseSegment;
    for (final d in r) {
      ssd += d * d;
      nd++;
    }
    // Integrate the run back to RR levels (up to a constant the mean removes).
    final x = List<double>.filled(r.length + 1, 0.0);
    for (var i = 0; i < r.length; i++) {
      x[i + 1] = x[i] + r[i];
    }
    final cov = List<double>.filled(x.length, 0.0); // Σ w² per sample
    for (var s = 0; s + n <= x.length; s += n ~/ 2) {
      for (var i = 0; i < n; i++) {
        cov[s + i] += noiseHann[i] * noiseHann[i];
      }
      final p = addNoiseSegment(x, s, psd);
      pSum += p;
      p2Sum += p * p;
      segs++;
    }
    for (var i = 0; i < r.length; i++) {
      final c = (cov[i] + cov[i + 1]) / 2;
      wsd += c * r[i] * r[i];
      wsum += c;
    }
  }
}

/// The white-noise share from [s] (see [nnDiffNoiseShare] in hrv_time.dart for
/// what it measures and every refusal). [lattice] says whether the differences
/// sit on a coarse beat-time grid ([coarseLattice]); it is only asked when
/// the counts allow a verdict.
double? noiseShareFrom(NoiseShareSums s,
    {required bool Function() lattice, int minSegments = 20}) {
  final segs = s.segs;
  if (segs < minSegments || s.ssd == 0 || s.wsd == 0) return null;
  if (lattice()) return null;
  // One loud stretch dominates the average: count segments by power, not number.
  if (s.pSum * s.pSum / s.p2Sum < 0.75 * minSegments) return null;
  final band = s.psd.sublist(kNoiseLoBin);
  var peak = 0;
  for (var k = 1; k < band.length; k++) {
    if (band[k] > band[peak]) peak = k;
  }
  if (peak + kNoiseLoBin >= kNoiseHiBin - 1) return null; // ~0.477–0.5 band
  if (band.last > 0.2 * band[peak]) return null; // hump on Nyquist
  final med = median(band)!;
  if (band[peak] < 4.5 * med) return null; // no line, no exemption
  final floor = med / segs / _noiseHannSq;
  final vetted = s.wsd / s.wsum, all = s.ssd / s.nd;
  // 1 − (structured share of RMSSD²); equals 2σ²/mean(d²) when stationary.
  return 1 - (vetted - 2 * floor) / math.max(vetted, all);
}

/// True when every successive difference is a whole multiple of one step q
/// (the smallest |d| over 1e-6) and the mean squared difference [msd] is under
/// 2q². [magnitudes] are the |d| values (repeats change nothing), in any
/// order. See hrv_time.dart `_onCoarseLattice` for why.
bool coarseLattice(Iterable<double> magnitudes, double msd) {
  var q = double.infinity;
  for (final a in magnitudes) {
    if (a > 1e-6 && a < q) q = a;
  }
  if (q.isInfinite || msd >= 2 * q * q) return false;
  for (final a in magnitudes) {
    final k = a / q;
    if ((k - k.roundToDouble()).abs() > 1e-3) return false;
  }
  return true;
}

/// The breathing-line test's Hann window (128 beats).
final List<double> hann128 = [
  for (var i = 0; i < 128; i++) 0.5 - 0.5 * math.cos(2 * math.pi * i / 127)
];
final double _hann128Sq = hann128.fold(0.0, (a, w) => a + w * w);

/// The cycles-per-beat axis the breathing-line test pools on: 0.15–0.5
/// cycles/beat at the night's median beat.
final List<double> breathingAxis = [for (var j = 38; j <= 128; j++) j / 256];

/// Welch power (128-beat Hann, 50 % overlap, averaged over segments) of one
/// window's RR, rebuilt from its difference runs, at cycles-per-beat
/// frequencies [f]. Null when no run holds a full segment.
List<double>? windowPsd(List<List<double>> diffRuns, List<double> f) {
  const n = 128;
  final p = List<double>.filled(f.length, 0.0);
  var segs = 0;
  for (final r in diffRuns) {
    final x = List<double>.filled(r.length + 1, 0.0);
    for (var i = 0; i < r.length; i++) {
      x[i + 1] = x[i] + r[i];
    }
    for (var s = 0; s + n <= x.length; s += n ~/ 2) {
      var m = 0.0;
      for (var i = 0; i < n; i++) {
        m += x[s + i];
      }
      m /= n;
      for (var j = 0; j < f.length; j++) {
        final c = math.cos(2 * math.pi * f[j]), sn = math.sin(2 * math.pi * f[j]);
        var cr = 1.0, ci = 0.0, re = 0.0, im = 0.0;
        for (var i = 0; i < n; i++) {
          final v = (x[s + i] - m) * hann128[i];
          re += v * cr;
          im += v * ci;
          final t = cr * c - ci * sn;
          ci = cr * sn + ci * c;
          cr = t;
        }
        p[j] += re * re + im * im;
      }
      segs++;
    }
  }
  return segs == 0 ? null : [for (final v in p) v / segs];
}

/// The breathing-line test over [windows] 5-min windows, each read through
/// callbacks so a caller can hold its windows as runs or as sums:
/// [psdAt] is the window's [windowPsd] at the given frequencies (null without
/// a full segment), [diffs] its difference count, [addSquares] adds its
/// squared differences to a running total (in the caller's order), [meanRrMs]
/// its mean RR. [allSsd] / [allNd] are the squared differences and their count
/// over every window, and [lattice] is [coarseLattice] over every window's
/// differences at the mean square it is given. Returns the indices of the
/// windows whose own peak sits on the line, or null. See hrv_time.dart
/// `_steadyBreathingWindows` for the method.
List<int>? steadyBreathingFrom({
  required int windows,
  required List<double> meanRrMs,
  required List<double>? Function(int w, List<double> f) psdAt,
  required int Function(int w) diffs,
  required double Function(int w, double acc) addSquares,
  required double allSsd,
  required int allNd,
  required bool Function(double msd) lattice,
}) {
  if (allNd == 0 || lattice(allSsd / allNd)) return null;
  final ref = median([for (final m in meanRrMs) if (m > 0) m]);
  if (ref == null) return null;
  final fc = breathingAxis;
  final byBeat = List<double>.filled(fc.length, 0.0);
  final byHz = List<double>.filled(fc.length, 0.0);
  final cover = List<int>.filled(fc.length, 0);
  final peakHz = <int, double>{}; // window -> its own peak, cycles per ms
  final psd = <int, List<double>>{}; // window -> its cycles-per-beat PSD
  for (var w = 0; w < windows; w++) {
    if (meanRrMs[w] <= 0) continue;
    final pb = psdAt(w, fc);
    if (pb == null) continue;
    final norm = median(pb)!;
    if (norm <= 0) continue;
    final k = meanRrMs[w] / ref;
    final fh = [for (final f in fc) f * k];
    final ph = psdAt(w, fh)!;
    var best = -1;
    for (var j = 0; j < fc.length; j++) {
      byBeat[j] += pb[j] / norm;
      if (fh[j] > 0.5) continue;
      byHz[j] += ph[j] / norm;
      cover[j]++;
      if (best < 0 || ph[j] > ph[best]) best = j;
    }
    if (best >= 0) peakHz[w] = fc[best] / ref;
    psd[w] = pb;
  }
  final nw = peakHz.length;
  if (nw < 12) return null;
  final bins = [for (var j = 0; j < fc.length; j++) if (cover[j] == nw) j];
  if (bins.length < 20) return null;
  final hz = [for (final j in bins) byHz[j]];
  final bt = [for (final j in bins) byBeat[j]];
  var pk = 0;
  for (var i = 1; i < hz.length; i++) {
    if (hz[i] > hz[pk]) pk = i;
  }
  if (pk == 0 || pk == hz.length - 1) return null;
  final f0 = fc[bins[pk]] / ref;
  final brpm = f0 * 60000;
  if (brpm < 8 || brpm > 30) return null;
  // Same bins, same normalisation: the line must stand taller aligned in Hz
  // than the beat pooling stands anywhere within ±12 bins of it.
  var near = 0.0;
  for (var i = math.max(0, pk - 12); i <= math.min(bt.length - 1, pk + 12); i++) {
    near = math.max(near, bt[i]);
  }
  // The pooled noise ripple shrinks as 1/√windows, so the bar does too.
  final promHz = hz[pk] / median(hz)!;
  if (promHz < math.max(2.5, 1.5 + 7 / math.sqrt(nw))) return null;
  if (promHz < 1.1 * near / median(bt)!) return null;
  // Alternation lives at Nyquist on the beat axis, outside these bins.
  if (byBeat.last / median(bt)! >= 0.5 * promHz) return null;
  final keep = [
    for (final e in peakHz.entries)
      if (math.log(e.value / f0).abs() <= 0.15) e.key
  ];
  if (keep.length < 6) return null;
  // Jitter that fails the gate would still be most of the number: same
  // ceiling as the noise share, over the kept windows (see hrv_time.dart).
  var lo = double.infinity, hi = 0.0;
  for (final w in keep) {
    lo = math.min(lo, peakHz[w]!);
    hi = math.max(hi, peakHz[w]!);
  }
  var sq = 0.0, nAll = 0;
  final acc = List<double>.filled(fc.length, 0.0);
  final wt = List<double>.filled(fc.length, 0.0);
  for (final w in keep) {
    sq = addSquares(w, sq);
    final n = diffs(w);
    nAll += n;
    final a = lo * meanRrMs[w] - 3 / 128, b = hi * meanRrMs[w] + 3 / 128;
    for (var j = 0; j < fc.length; j++) {
      if (fc[j] > a && fc[j] < b) continue;
      acc[j] += n * psd[w]![j] / (2 - 2 * math.cos(2 * math.pi * fc[j]));
      wt[j] += n;
    }
  }
  var floor = double.infinity;
  for (var j = 8; j < fc.length - 8; j++) {
    var s = 0.0, m = 0;
    for (var i = j - 8; i <= j + 8; i++) {
      if (wt[i] < nAll / 2) break;
      s += acc[i] / wt[i];
      m++;
    }
    if (m == 17) floor = math.min(floor, s / 17);
  }
  if (floor == double.infinity) return null;
  // The lowest stretch of a noisy curve reads below its mean; 1.1 puts the
  // floor back at these pooled sizes, so jitter alone is not undercounted.
  final noise = 1.1 * 6 * floor / _hann128Sq * nAll;
  return noise < kNnDiffNoiseShareCeiling * sq ? keep : null;
}
