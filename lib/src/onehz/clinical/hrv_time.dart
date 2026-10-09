// CLINICAL TIER-1 — time-domain HRV (PRV).
//
// Task Force 1996 conventions: RMSSD, SDNN, SDANN, pNN50, computed on the
// CLEANED NN series (run correctRr first). Window conventions:
//   ultra-short  : < 5 min   (RMSSD only, with caution)
//   short        : 5 min
//   24-h         : SDANN / SDNN-index use 5-min segment means / SDs.
//
// HONESTY: this is PRV (pulse-rate variability), not ECG HRV. RMSSD and pNNx
// are the metrics most biased by the 1 Hz beat-time quantization (successive-
// difference inflation) — flagged in `note`. Lead with SDNN / SDANN.
//
// That warning used to be advice only: every RMSSD in this file shipped, at
// confidence 0.95, however much of it was beat-timing jitter. [kNnDiffAcf1Floor]
// makes it behaviour — see that constant for the measurement and the threshold.

import 'dart:math' as math;
import '../types.dart';
import '../util.dart';

/// Lag-1 ACF floor for the NN successive-difference series, below which RMSSD
/// and pNN50 are REFUSED (SDNN / SDANN survive it and are the honest lead).
///
/// Differencing a smooth tachogram leaves ACF1 near 0; differencing white noise
/// leaves exactly −0.5. So ACF1 measures, per night and from the series already
/// in hand, how much of the "variability" is beat-timing jitter rather than
/// physiology. It is deliberately the gate INSTEAD of a per-family constant
/// (`device.dart`): the sensor difference is real and large, but it reaches us
/// as something measurable, not as a label — a strap that starts reporting
/// cleaner beats is believed the night it does so, and an unknown strap is
/// judged on its own signal rather than refused for its badge.
///
/// MEASURED over the 13-night audit corpus: gen4 −0.057..−0.324,
/// MG −0.426..−0.456, WHOOP 5 −0.428..−0.517. −0.35 keeps every gen4 night and
/// refuses every gen5/MG night. OURS, not a published threshold — there is no
/// literature constant for this, and it is calibration, so it is a knob.
const double kNnDiffAcf1Floor = -0.35;

/// Fewest successive differences [nnDiffAcf1] will judge a series on. Below it
/// the ACF1 estimate is noisier than what it is meant to screen out, so it
/// returns null and NOTHING is gated — thin windows are already handled by the
/// beat-count term in confidence.
const int _acf1MinDiffs = 30;

/// Lag-1 autocorrelation of the successive-difference series, pooled over
/// CONTIGUOUS runs.
///
/// Each entry of [diffRuns] must be differences between beats that are adjacent
/// in time; a dropped run / sensor hole ends one run and starts the next, so no
/// lag-1 pair is ever formed across a seam. Null when there is too little to
/// judge or the series is constant.
double? nnDiffAcf1(List<List<double>> diffRuns) {
  var n = 0;
  var sum = 0.0;
  for (final r in diffRuns) {
    for (final d in r) {
      sum += d;
      n++;
    }
  }
  if (n < _acf1MinDiffs) return null;
  final m = sum / n;
  var cov = 0.0;
  var varSum = 0.0;
  for (final r in diffRuns) {
    for (var i = 0; i < r.length; i++) {
      final a = r[i] - m;
      varSum += a * a;
      if (i > 0) cov += (r[i - 1] - m) * a;
    }
  }
  return varSum > 0 ? cov / varSum : null;
}

/// White-noise share of the mean squared successive difference above which a
/// night that failed [kNnDiffAcf1Floor] stays refused. Same line as the floor:
/// with acf-neutral physiology, ACF1 ≈ −0.5 × share, so −0.35 ↔ 0.7.
const double kNnDiffNoiseShareCeiling = 0.7;

/// Share of the mean squared successive difference that a FLAT (white) RR noise
/// floor accounts for: 2σ² / mean(d²), with σ² read as the median of the
/// beat-indexed Welch spectrum (64-beat Hann, 50 % overlap, Welch 1967) over
/// 0.15–0.5 cycles/beat. ~1 for white or differenced-white timing jitter; well
/// below 1 when the high band is a respiratory line on a low floor.
///
/// Why ACF1 alone is not enough: RSA is a line at (breaths/min ÷ HR) cycles per
/// beat, and differencing a line at f gives ACF1 = cos 2πf. At a resting HR
/// in the 40s and 18–20 breaths/min that is ~0.4 cycles/beat, ACF1 ≈ −0.8 —
/// below the floor on a clean night, so the floor locked out slow hearts.
/// Ceiling: a line at Nyquist (breathing at half the heart rate) is an
/// alternation, indistinguishable from detector alternation, and stays refused.
/// The guard is deliberately the top two bins, so a peak anywhere in
/// ~0.477–0.5 cycles/beat is refused too (HR ~40 at 20 br/min lands there):
/// at 64 beats a Hann line that close puts its main lobe on the Nyquist bin.
/// Alternation that slips phase now and then is not a line but a hump centred
/// on Nyquist, a few bins wide, and Welch scatter can put its peak lower. A
/// real line at <= ~0.47 cycles/beat leaves the Nyquist bin on the Hann null,
/// holding only the floor, so a Nyquist bin above 0.2x the peak is refused too.
///
/// Diffs are weighted by the same Hann² coverage the spectrum gives them: a
/// diff in the first or last few beats of a segment barely reaches the PSD, so
/// counting it at full weight against the floor hid run-edge artifacts (sensor
/// holes, dropped runs, window seams are exactly where re-lock residuals sit).
/// Energy the spectrum never vets (edges, tails, too-short runs) above what the
/// weighted mean carries counts as noise, so it can only push toward refusal.
///
/// A respiratory line has to stand out: the peak bin must reach 4.5x the band
/// median. With only ~20-30 segments the median is noisy enough that pure
/// beat-time jitter sometimes reads under the ceiling; its peak stays near
/// 3.4x the median at worst, while an RSA line that clears the ceiling sits at
/// 5x or more.
///
/// A short loud burst can carry most of the band power, leaving the average
/// effectively one or two segments wide, and the median of that undershoots
/// the floor. So the segment count that matters is the power-weighted one,
/// (Σ P_s)² / Σ P_s², which must reach 15.
///
/// Null (no verdict) on fewer than [minSegments] segments (or 3/4 of that
/// effective; 20/15 for a night, see [_windowClears] for one window), a peak in
/// that top band, a Nyquist bin that rivals the peak, or no peak standing
/// clear of the floor, or diffs on a beat-time grid coarse against their size
/// (see [_onCoarseLattice]).
double? nnDiffNoiseShare(List<List<double>> diffRuns, {int minSegments = 20}) {
  const n = 64, kLo = 10, kHi = n ~/ 2; // kLo/n ≈ 0.15 cycles/beat
  final w = [
    for (var i = 0; i < n; i++) 0.5 - 0.5 * math.cos(2 * math.pi * i / (n - 1))
  ];
  var w2 = 0.0;
  for (final x in w) {
    w2 += x * x;
  }
  final cosT = [
    for (var k = kLo; k <= kHi; k++)
      [for (var i = 0; i < n; i++) math.cos(2 * math.pi * k * i / n)]
  ];
  final sinT = [
    for (var k = kLo; k <= kHi; k++)
      [for (var i = 0; i < n; i++) math.sin(2 * math.pi * k * i / n)]
  ];
  final psd = List<double>.filled(kHi + 1, 0.0);
  var segs = 0, nd = 0;
  var ssd = 0.0, wsd = 0.0, wsum = 0.0, pSum = 0.0, p2Sum = 0.0;
  for (final r in diffRuns) {
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
      var m = 0.0;
      for (var i = 0; i < n; i++) {
        m += x[s + i];
        cov[s + i] += w[i] * w[i];
      }
      m /= n;
      final v = [for (var i = 0; i < n; i++) (x[s + i] - m) * w[i]];
      var p = 0.0;
      for (var k = kLo; k <= kHi; k++) {
        final c = cosT[k - kLo], sn = sinT[k - kLo];
        var re = 0.0, im = 0.0;
        for (var i = 0; i < n; i++) {
          re += v[i] * c[i];
          im -= v[i] * sn[i];
        }
        psd[k] += re * re + im * im;
        p += re * re + im * im;
      }
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
  if (segs < minSegments || ssd == 0 || wsd == 0) return null;
  if (_onCoarseLattice(diffRuns, ssd / nd)) return null;
  // One loud stretch dominates the average: count segments by power, not number.
  if (pSum * pSum / p2Sum < 0.75 * minSegments) return null;
  final band = psd.sublist(kLo);
  var peak = 0;
  for (var k = 1; k < band.length; k++) {
    if (band[k] > band[peak]) peak = k;
  }
  if (peak + kLo >= kHi - 1) return null; // ~0.477–0.5 band, see above
  if (band.last > 0.2 * band[peak]) return null; // hump on Nyquist, see above
  final med = median(band)!;
  if (band[peak] < 4.5 * med) return null; // no line, no exemption
  final floor = med / segs / w2;
  final vetted = wsd / wsum, all = ssd / nd;
  // 1 − (structured share of RMSSD²); equals 2σ²/mean(d²) when stationary.
  return 1 - (vetted - 2 * floor) / math.max(vetted, all);
}

/// True when every successive difference is a whole multiple of one step q and
/// the mean squared difference is under 2q². Beat times rounded to a grid q
/// make RR a two-level sequence on a near-constant heart: its differences are
/// 0 or ±q, a deterministic sawtooth at frac(RR/q) cycles/beat, so it reads as
/// one clean line and the white-floor test cannot see it. Rounding alone puts
/// mean(d²) at 2·min(f, 1−f)·q² ≤ q², so under 2q² the grid, not the heart,
/// sets RMSSD.
// ponytail: exact lattice only; a grid re-rounded to whole ms (7.8 ms → 7/8)
// breaks the common step and is not caught.
bool _onCoarseLattice(List<List<double>> diffRuns, double msd) {
  var q = double.infinity;
  for (final r in diffRuns) {
    for (final d in r) {
      if (d.abs() > 1e-6 && d.abs() < q) q = d.abs();
    }
  }
  if (q.isInfinite || msd >= 2 * q * q) return false;
  for (final r in diffRuns) {
    for (final d in r) {
      final k = d.abs() / q;
      if ((k - k.roundToDouble()).abs() > 1e-3) return false;
    }
  }
  return true;
}

/// The one RMSSD jitter verdict every path shares: ACF1 below the floor AND
/// the spectrum does not show a respiratory line on a low white floor.
bool _jitterRefused(double? acf1, List<List<double>> runs,
    {int minSegments = 20}) {
  if (acf1 == null || acf1 >= kNnDiffAcf1Floor) return false;
  final share = nnDiffNoiseShare(runs, minSegments: minSegments);
  return share == null || share >= kNnDiffNoiseShareCeiling;
}

/// One 5-min window judged on its own: a measured ACF1 at or above the floor,
/// or its own spectral line (4 segments is what a window at HR ~40 holds).
bool _windowClears(List<List<double>> runs) {
  final a = nnDiffAcf1(runs);
  return a != null && !_jitterRefused(a, runs, minSegments: 4);
}

/// The window RMSSDs a headline may use. A night that cleared the floor
/// outright keeps them all. One that only passed through the spectral
/// exemption proved a line somewhere in the pooled power, not in every window:
/// quiet jitter-only windows can win the median or dilute the mean while a few
/// loud breathing windows carry the pooled share. There every window has to
/// clear the gate itself.
List<double> _clearedWindows(double? nightAcf1, List<double> rmssds,
    List<List<List<double>>> winRuns) {
  if (nightAcf1 == null || nightAcf1 >= kNnDiffAcf1Floor) return rmssds;
  return [
    for (var i = 0; i < rmssds.length; i++)
      if (_windowClears(winRuns[i])) rmssds[i]
  ];
}

final _hann128 = [
  for (var i = 0; i < 128; i++) 0.5 - 0.5 * math.cos(2 * math.pi * i / 127)
];
final _hann128Sq = _hann128.fold(0.0, (a, w) => a + w * w);

/// Welch power (128-beat Hann, 50 % overlap, averaged over segments) of one
/// window's RR, rebuilt from its difference runs, at cycles-per-beat
/// frequencies [f]. Null when no run holds a full segment.
List<double>? _windowPsd(List<List<double>> diffRuns, List<double> f) {
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
          final v = (x[s + i] - m) * _hann128[i];
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

/// Last resort for a night the jitter gate refused: the windows whose
/// breathing line holds still in Hz while the heart rate moves.
///
/// RSA follows breathing (Hirsch & Bishop 1981), a rate in breaths per
/// minute, so its line sits at a fixed frequency in Hz; a heart rate that
/// drifts across the night slides it in cycles per beat. Beat-timing jitter,
/// alternation and grid artifacts are tied to the beat, not the clock. So each
/// 5-min window's spectrum is pooled twice, once on a cycles-per-beat axis and
/// once rescaled by its own mean RR onto a Hz axis, and the night passes only
/// when the Hz pooling shows a line in 8–30 br/min that is sharper than the
/// beat pooling. If the heart rate barely moves the two poolings coincide and
/// the night stays refused: stability in Hz says nothing there.
///
/// Ceiling: needs >= 12 windows and a heart rate that wanders; breathing at
/// half the heart rate is still an alternation and still refused.
/// Returns the indices of the windows whose own peak sits on the line.
List<int>? _steadyBreathingWindows(
    List<List<List<double>>> winRuns, List<double> meanRrMs) {
  var ssd = 0.0, nd = 0;
  final all = [for (final w in winRuns) ...w];
  for (final r in all) {
    for (final d in r) {
      ssd += d * d;
      nd++;
    }
  }
  if (nd == 0 || _onCoarseLattice(all, ssd / nd)) return null;
  final ref = median([for (final m in meanRrMs) if (m > 0) m]);
  if (ref == null) return null;
  // 0.15–0.5 cycles/beat at the night's median beat.
  final fc = [for (var j = 38; j <= 128; j++) j / 256];
  final byBeat = List<double>.filled(fc.length, 0.0);
  final byHz = List<double>.filled(fc.length, 0.0);
  final cover = List<int>.filled(fc.length, 0);
  final peakHz = <int, double>{}; // window -> its own peak, cycles per ms
  final psd = <int, List<double>>{}; // window -> its cycles-per-beat PSD
  for (var w = 0; w < winRuns.length; w++) {
    if (meanRrMs[w] <= 0) continue;
    final pb = _windowPsd(winRuns[w], fc);
    if (pb == null) continue;
    final norm = median(pb)!;
    if (norm <= 0) continue;
    final k = meanRrMs[w] / ref;
    final fh = [for (final f in fc) f * k];
    final ph = _windowPsd(winRuns[w], fh)!;
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
  // The line proves breathing is there, not that it carries RMSSD: beat-time
  // jitter loud enough to fail the gate would still be most of the number.
  // Same ceiling as [nnDiffNoiseShare], over the kept windows. Jitter σ² has
  // an RR spectrum σ²·(2 − 2cos ω), flat once divided by that shape, and its
  // differences carry 6σ²; physiology only adds power on top. Breathing
  // wanders across the night and its line spreads with it, so each window
  // drops the bins of every rate the kept windows peaked at (plus a Hann
  // main lobe), mapped onto its own beats. σ² is the floor of what is left,
  // pooled over windows and smoothed over four resolution cells.
  var lo = double.infinity, hi = 0.0;
  for (final w in keep) {
    lo = math.min(lo, peakHz[w]!);
    hi = math.max(hi, peakHz[w]!);
  }
  var sq = 0.0, nAll = 0;
  final acc = List<double>.filled(fc.length, 0.0);
  final wt = List<double>.filled(fc.length, 0.0);
  for (final w in keep) {
    var n = 0;
    for (final r in winRuns[w]) {
      for (final d in r) {
        sq += d * d;
        n++;
      }
    }
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

/// The window RMSSDs a windowed headline publishes, or null for none: the
/// usual gate first, and only when it leaves nothing, the windows on a
/// breathing line that holds still in Hz ([_steadyBreathingWindows]), which
/// publish at the confidence floor.
({List<double> rmssds, bool byBreathing, String note})? _keptWindows(
    double? acf1,
    bool refused,
    List<double> rmssds,
    List<List<List<double>>> winRuns,
    List<double> meanRrMs) {
  final kept = refused ? const <double>[] : _clearedWindows(acf1, rmssds, winRuns);
  if (kept.isNotEmpty) return (rmssds: kept, byBreathing: false, note: '');
  if (acf1 == null || acf1 >= kNnDiffAcf1Floor) return null;
  final idx = _steadyBreathingWindows(winRuns, meanRrMs);
  if (idx == null) return null;
  return (
    rmssds: [for (final i in idx) rmssds[i]],
    byBreathing: true,
    note: ' Jitter gate failed; kept the ${idx.length} windows on a breathing '
        'line steady in Hz while heart rate drifted, at floor confidence.',
  );
}

/// Confidence multiplier for a measured [acf1]: 1.0 on a smooth tachogram,
/// falling linearly to 0 at [kNnDiffAcf1Floor] so confidence bottoms out
/// exactly where RMSSD is refused. 1.0 when ACF1 could not be measured.
double _acf1Quality(double? acf1) =>
    acf1 == null ? 1.0 : (1 - acf1 / kNnDiffAcf1Floor).clamp(0.0, 1.0);

String _jitterNote(double acf1) =>
    'rmssd_refused:acf1=${acf1.toStringAsFixed(3)} — the NN successive '
    'differences are essentially differenced white noise (−0.5 = pure, floor '
    '$kNnDiffAcf1Floor), so RMSSD/pNN50 would measure beat-timing jitter, not '
    'vagal tone';

/// Σ reported RR ÷ elapsed wall time above which the stream cannot be one
/// heart's beats (it banks more beat-time than time passed): a double ingest or
/// two interleaved streams. Contiguous runs measure 0.963 (gen4), 0.999 (W5),
/// 1.001 (MG) — see rr_correction.dart `_beatTimes` — so 1.10 has margin.
/// Duplicated beats add zero differences and DEFLATE RMSSD by ~1/√2;
/// interleaved streams inflate it. Every other gate here passes both.
const double kRrCoverageCeiling = 1.10;

/// Shortest wall span [rrCoverage] will judge: whole-second stamps make a
/// shorter one meaningless.
const double kRrCoverageMinSpanSec = 600;

/// Intervals [rrCoverage] counts as beat-time, ms. Wider than the cleaners'
/// 2000 ms on purpose: a 2000–2400 ms beat is a slow heart (25–30 bpm), still
/// real elapsed time; only a glitch (e.g. a 65 535 ms sentinel) must not be
/// summed, or it would fake an over-count on a short span.
const double _rrCoverageMinMs = 300;
const double _rrCoverageMaxMs = 2400;

bool _rrCoverageCounts(double rrMs) =>
    rrMs >= _rrCoverageMinMs && rrMs <= _rrCoverageMaxMs;

/// How much beat-time an RR stream banks against the wall clock it spans.
class RrCoverage {
  /// Σ plausible RR ÷ wall span. Below 1 on any gap; above 1 is impossible
  /// for one heart.
  final double coverage;
  final double sumRrSec;
  final double spanSec;
  final int beats;

  /// Intervals outside 300–2400 ms: counted, never summed.
  final int implausibleBeats;

  /// Exact (ts, rr) repeats of an earlier beat, wherever they sit in the
  /// input. A DIAGNOSTIC only: on whole-second stamps two equal beats in one
  /// record repeat legitimately.
  final int duplicateBeats;
  const RrCoverage({
    required this.coverage,
    required this.sumRrSec,
    required this.spanSec,
    required this.beats,
    required this.implausibleBeats,
    required this.duplicateBeats,
  });
  bool get overCounted => coverage > kRrCoverageCeiling;
  Map<String, dynamic> toJson() => {
        'rr_coverage': round6(coverage),
        'sum_rr_sec': round6(sumRrSec),
        'span_sec': round6(spanSec),
        'beats': beats,
        'implausible_beats': implausibleBeats,
        'duplicate_beats': duplicateBeats,
      };
}

/// [RrCoverage] of raw RR [rrMs] against their beat-END epoch times [rrTsMs]
/// (same length; order does not matter). The span is `latest − earliest` beat
/// end plus the earliest beat's own interval (it began before its end stamp) —
/// but only when that interval is itself plausible. An implausible one is
/// never summed, so it must not stretch the denominator either (a 65 535 ms
/// glitch there hid a 12.5 % over-count). Null when fewer than 2 beats, the
/// lengths differ, or the span is under [kRrCoverageMinSpanSec].
RrCoverage? rrCoverage(List<double> rrMs, List<double> rrTsMs) {
  if (rrMs.length < 2 || rrMs.length != rrTsMs.length) return null;
  var lo = 0, hi = 0;
  for (var i = 1; i < rrTsMs.length; i++) {
    if (rrTsMs[i] < rrTsMs[lo]) lo = i;
    if (rrTsMs[i] > rrTsMs[hi]) hi = i;
  }
  final first = rrMs[lo];
  final spanSec = (rrTsMs[hi] - rrTsMs[lo] +
          (_rrCoverageCounts(first) ? first : 0)) /
      1000.0;
  if (!spanSec.isFinite || spanSec < kRrCoverageMinSpanSec) return null;
  var sum = 0.0;
  var implausible = 0;
  var dup = 0;
  final seen = <(double, double)>{};
  for (var i = 0; i < rrMs.length; i++) {
    final v = rrMs[i];
    if (_rrCoverageCounts(v)) {
      sum += v;
    } else {
      implausible++;
    }
    if (!seen.add((rrTsMs[i], v))) dup++;
  }
  final sumSec = sum / 1000.0;
  return RrCoverage(
    coverage: sumSec / spanSec,
    sumRrSec: sumSec,
    spanSec: spanSec,
    beats: rrMs.length,
    implausibleBeats: implausible,
    duplicateBeats: dup,
  );
}

/// The refusal note every RMSSD-family estimator gives an over-counted stream.
String rrOvercountNote(RrCoverage c) => _overcountNote(c);

String _overcountNote(RrCoverage c) =>
    'rr_overcount:coverage=${round6(c.coverage)} — more beat-time than '
    'elapsed time; the RR stream holds duplicated or interleaved beats';

class HrvTime {
  final double? rmssd; // ms
  final double? sdnn; // ms
  final double? sdann; // ms (24-h: SD of 5-min means)
  final double? sdnnIndex; // ms (24-h: mean of 5-min SDs)
  final double? pnn50; // %
  final int nBeats;
  final double? diffAcf1; // lag-1 ACF of the NN successive differences
  const HrvTime({
    this.rmssd,
    this.sdnn,
    this.sdann,
    this.sdnnIndex,
    this.pnn50,
    required this.nBeats,
    this.diffAcf1,
  });
  Map<String, dynamic> toJson() => {
        if (rmssd != null) 'rmssd_ms': round6(rmssd!),
        if (sdnn != null) 'sdnn_ms': round6(sdnn!),
        if (sdann != null) 'sdann_ms': round6(sdann!),
        if (sdnnIndex != null) 'sdnn_index_ms': round6(sdnnIndex!),
        if (pnn50 != null) 'pnn50_pct': round6(pnn50!),
        'n_beats': nBeats,
        if (diffAcf1 != null) 'diff_acf1': round6(diffAcf1!),
      };
}

/// Short-window time-domain HRV on a cleaned NN series (ms).
///
/// [nnMs] cleaned NN intervals. [nnTimesMs] beat times, used both for
/// SDANN/SDNN-index segmentation and to skip successive-difference pairs that
/// straddle a dropped run (optional; without it SDANN/SDNN-index are null and
/// RMSSD/pNN50 include the seams). [artifactFraction] is the fraction of beats
/// the upstream corrector rejected (0..1), folded into confidence exactly as
/// `hrvFreq` and `irregularBeatScreen` already do. Returns an absent Metric when
/// there are too few beats; RMSSD/pNN50 alone go null when the successive
/// differences fail [kNnDiffAcf1Floor], or when [coverage] (of the raw RR this
/// NN was cleaned from) is [RrCoverage.overCounted] — then the breathing-line
/// fallback does not run either. Without [coverage] that check is skipped.
Metric<HrvTime> hrvTime(
  List<double> nnMs, {
  List<double>? nnTimesMs,
  double artifactFraction = 0.0,
  RrCoverage? coverage,
}) {
  const inputs = ['rr_cleaned'];
  if (nnMs.length < 2) {
    return const Metric<HrvTime>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'too few NN intervals',
    );
  }

  // RMSSD / pNN50: root mean square of SUCCESSIVE differences — successive in
  // TIME, not merely adjacent in the compacted list. correctRr drops multi-beat
  // artifact runs while advancing its clock across them, so nn[i-1] and nn[i]
  // can sit either side of a seconds-long hole; differencing straight down the
  // list manufactured one large difference per dropped run. Same `keep`-mask
  // treatment irregular_rhythm.dart already applies. A pair is contiguous iff
  // the elapsed time between the two beat times is the interval itself.
  //
  // The differences are kept as contiguous RUNS (a seam ends a run) so the same
  // pass feeds [nnDiffAcf1] without ever forming a lag-1 pair across a hole.
  final gapAware = nnTimesMs != null && nnTimesMs.length == nnMs.length;
  final runs = <List<double>>[];
  var run = <double>[];
  for (var i = 1; i < nnMs.length; i++) {
    if (gapAware && nnTimesMs[i] - nnTimesMs[i - 1] > nnMs[i] + 0.5) {
      if (run.isNotEmpty) {
        runs.add(run);
        run = <double>[];
      }
      continue;
    }
    run.add(nnMs[i] - nnMs[i - 1]);
  }
  if (run.isNotEmpty) runs.add(run);

  var ssd = 0.0;
  var nn50 = 0;
  var pairs = 0;
  for (final r in runs) {
    for (final d in r) {
      ssd += d * d;
      if (d.abs() > 50) nn50++;
      pairs++;
    }
  }
  // RMSSD and pNN50 are the two outputs made of successive differences, so they
  // are the two the jitter floor refuses. SDNN/SDANN are made of the levels and
  // are far less contaminated (jitter share 1–27 % against RMSSD's 11–100 % on
  // the audit corpus) — they keep publishing, which is what the header has
  // always advised.
  final acf1 = nnDiffAcf1(runs);
  final jittery = _jitterRefused(acf1, runs);
  // More beat-time than elapsed: the stream itself is wrong, so neither the
  // differences nor any breathing line in them describe one heart.
  final overCounted = coverage?.overCounted == true;
  final usable = pairs > 0 && !jittery && !overCounted;
  var rmssd = usable ? math.sqrt(ssd / pairs) : null;
  final pnn50 = usable ? 100.0 * nn50 / pairs : null;
  // Refused: a long record may still show a breathing line steady in Hz
  // ([_steadyBreathingWindows]); then RMSSD alone comes from those 5-min windows.
  if (jittery && gapAware && !overCounted) {
    rmssd = _breathingRmssd(nnMs, nnTimesMs);
  }
  final byBreathing = jittery && rmssd != null;
  final sdnn = stddev(nnMs);

  double? sdann, sdnnIndex;
  if (gapAware) {
    final seg = _fiveMinSegments(nnMs, nnTimesMs);
    if (seg.length >= 2) {
      final means = [for (final s in seg) mean(s)!];
      sdann = stddev(means);
      final sds = [for (final s in seg) stddev(s)].whereType<double>().toList();
      sdnnIndex = sds.isEmpty ? null : mean(sds);
    }
  }

  // Confidence scales with beat count (ultra-short reads are less reliable),
  // with the artifact fraction we were handed, and with the measured jitter
  // level. It used to be beat count alone, which published 0.95 on all 13 nights
  // of the audit corpus — including a 15.3 %-artifact night whose differences
  // were ~pure noise. The beat-count term is capped BEFORE the quality terms
  // multiply it; multiplying first let an all-night beat count (n/250 ≈ 100)
  // swallow any penalty and re-clamp to 0.95 regardless.
  final conf = byBreathing || overCounted
      ? 0.3
      : ((nnMs.length / 250.0).clamp(0.0, 1.0) // ~250 beats ≈ 5 min
              *
              _acf1Quality(acf1) *
              (1 - artifactFraction))
          .clamp(0.3, 0.95);
  return Metric<HrvTime>(
    value: HrvTime(
      rmssd: rmssd,
      sdnn: sdnn,
      sdann: sdann,
      sdnnIndex: sdnnIndex,
      pnn50: pnn50,
      nBeats: nnMs.length,
      diffAcf1: acf1,
    ),
    confidence: conf,
    tier: Tier.high,
    inputs_used: inputs,
    note: overCounted
        ? '${_overcountNote(coverage!)}. SDNN/SDANN survive it and are the '
            'lead here. PRV not ECG-HRV.'
        : jittery
        ? '${_jitterNote(acf1!)}. SDNN/SDANN survive it and are the lead here. '
            '${byBreathing ? 'RMSSD only from 5-min windows on a breathing '
                'line steady in Hz, at floor confidence. ' : ''}PRV not ECG-HRV.'
        : 'PRV not ECG-HRV; RMSSD/pNN50 are quantization-sensitive at 1 Hz '
            '— lead with SDNN/SDANN',
  );
}

/// RMSSD pooled over the 5-min windows of [nn] that sit on a breathing line
/// steady in Hz, or null. Same seam rule as [hrvTime].
double? _breathingRmssd(List<double> nn, List<double> times) {
  final wins = <int, List<List<double>>>{};
  final rrSum = <int, double>{}, rrN = <int, int>{};
  var prevWin = -1;
  for (var i = 0; i < nn.length; i++) {
    final w = ((times[i] - times.first) / 300000.0).floor();
    rrSum[w] = (rrSum[w] ?? 0) + nn[i];
    rrN[w] = (rrN[w] ?? 0) + 1;
    final runs = wins[w] ??= <List<double>>[];
    if (i > 0 && w == prevWin && times[i] - times[i - 1] <= nn[i] + 0.5) {
      runs.last.add(nn[i] - nn[i - 1]);
    } else {
      runs.add(<double>[]);
    }
    prevWin = w;
  }
  final keys = wins.keys.toList()..sort();
  final idx = _steadyBreathingWindows(
      [for (final k in keys) wins[k]!], [for (final k in keys) rrSum[k]! / rrN[k]!]);
  if (idx == null) return null;
  var ss = 0.0, n = 0;
  for (final i in idx) {
    for (final r in wins[keys[i]]!) {
      for (final d in r) {
        ss += d * d;
        n++;
      }
    }
  }
  return n == 0 ? null : math.sqrt(ss / n);
}

/// Robust NOCTURNAL RMSSD (ms).
///
/// A single whole-night RMSSD is dominated by the few high-Δ segments produced
/// by REM bursts, arousals and stage transitions, inflating it well above the
/// resting parasympathetic level (~tens of ms). Instead we compute RMSSD WITHIN
/// each consecutive ~5-min window of the NN series and take the MEDIAN across
/// windows — a robust estimator far less sensitive to a handful of high-variance
/// windows. Optionally restrict to NREM / low-motion windows via [stageMaskPerSec].
///
/// [nnMs] cleaned NN intervals. [nnTimesMs] beat times (ms, same length) used to
/// window into 5-min bins; required (returns absent without it). [windowMs] bin
/// width (default 300 000 = 5 min). [minBeatsPerWindow] min NN diffs a window
/// needs to contribute (default 5). [stageMaskPerSec] OPTIONAL per-second mask
/// (true = keep, e.g. NREM & immobile); a window is kept only when the mask is
/// true at the window's MIDPOINT second.
///
/// Returns a Metric whose value is the median-of-windows RMSSD (ms). Keeps the
/// PRV-not-ECG honesty note. Absent when there are too few usable windows, when
/// the night's successive differences fail [kNnDiffAcf1Floor], or when
/// [coverage] (of the raw RR) is [RrCoverage.overCounted]. A window
/// contributes only if it holds [minBeatsPerWindow] differences between beats
/// that are ADJACENT IN TIME, not merely adjacent in the compacted NN list.
Metric<double> nocturnalRmssd(
  List<double> nnMs,
  List<double> nnTimesMs, {
  double windowMs = 300000.0,
  int minBeatsPerWindow = 5,
  List<bool>? stageMaskPerSec,
  RrCoverage? coverage,
}) {
  const inputs = ['rr_cleaned', 'beat_times'];
  if (coverage != null && coverage.overCounted) {
    return Metric<double>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: _overcountNote(coverage),
    );
  }
  if (nnMs.length != nnTimesMs.length || nnMs.length < minBeatsPerWindow + 1) {
    return const Metric<double>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'too few NN intervals for windowed nocturnal RMSSD',
    );
  }
  final t0 = nnTimesMs.first;
  // Bucket beat INDICES by window index, so each window keeps its beat times and
  // the successive differences below can skip the ones that straddle a dropped
  // run — the same seam rule `hrvTime` applies.
  final buckets = <int, List<int>>{};
  for (var i = 0; i < nnMs.length; i++) {
    final idx = ((nnTimesMs[i] - t0) / windowMs).floor();
    (buckets[idx] ??= <int>[]).add(i);
  }
  // Compute per-window RMSSD over the windows we keep. Each window's difference
  // series is also kept as one contiguous run for the jitter floor below.
  final rmssds = <double>[];
  // The jitter floor is judged over the WHOLE night, pooled across windows, not
  // per window: at 5 min a window holds a few hundred differences and its ACF1
  // is noisy enough that dropping only the windows that fail keeps the ones that
  // passed by luck — measured, that let WHOOP 5 publish 109-116 ms from its
  // calmest-looking windows while the night pooled to −0.43/−0.51.
  final runs = <List<double>>[];
  final perWindow = <List<List<double>>>[];
  final meanRr = <double>[];
  final indices = buckets.keys.toList()..sort();
  for (final idx in indices) {
    if (stageMaskPerSec != null) {
      final midSec = ((idx + 0.5) * windowMs / 1000.0).floor();
      final keep = midSec >= 0 &&
          midSec < stageMaskPerSec.length &&
          stageMaskPerSec[midSec];
      if (!keep) continue;
    }
    final seg = buckets[idx]!;
    if (seg.length < minBeatsPerWindow + 1) continue;
    // Contiguous runs inside the window: a pair whose beat times are further
    // apart than the interval itself sits either side of a dropped run, and
    // differencing across it manufactures one large difference per hole.
    final winRuns = <List<double>>[];
    var run = <double>[];
    for (var k = 1; k < seg.length; k++) {
      final i = seg[k], p = seg[k - 1];
      if (nnTimesMs[i] - nnTimesMs[p] > nnMs[i] + 0.5) {
        if (run.isNotEmpty) {
          winRuns.add(run);
          run = <double>[];
        }
        continue;
      }
      run.add(nnMs[i] - nnMs[p]);
    }
    if (run.isNotEmpty) winRuns.add(run);
    var ssd = 0.0;
    var nd = 0;
    for (final r in winRuns) {
      for (final d in r) {
        ssd += d * d;
        nd++;
      }
    }
    if (nd < minBeatsPerWindow) continue;
    runs.addAll(winRuns);
    perWindow.add(winRuns);
    meanRr.add(mean([for (final i in seg) nnMs[i]])!);
    rmssds.add(math.sqrt(ssd / nd));
  }
  final acf1 = nnDiffAcf1(runs);
  final refused = _jitterRefused(acf1, runs);
  if (rmssds.isEmpty && !refused) {
    return const Metric<double>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'no usable 5-min windows for nocturnal RMSSD',
    );
  }
  final kept = _keptWindows(acf1, refused, rmssds, perWindow, meanRr);
  if (kept == null) {
    return Metric<double>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: refused
          ? _jitterNote(acf1!)
          : '${_jitterNote(acf1!)}; no 5-min window clears it on its own',
    );
  }
  final robust = median(kept.rmssds)!;
  // Confidence scales with how many windows we could median over, and with the
  // measured jitter level (see [kNnDiffAcf1Floor]).
  final conf = kept.byBreathing
      ? 0.3
      : ((kept.rmssds.length / 12.0).clamp(0.0, 1.0) * _acf1Quality(acf1))
          .clamp(
              // 12 ≈ 1 h
              0.3,
              0.95);
  return Metric<double>(
    value: robust,
    confidence: conf,
    tier: Tier.high,
    inputs_used: inputs,
    note: 'robust nocturnal RMSSD = MEDIAN of ${kept.rmssds.length} consecutive '
        '5-min-window RMSSDs (REM/arousal-robust). PRV not ECG-HRV; '
        'RMSSD is quantization-sensitive at 1 Hz.${kept.note}',
  );
}

/// Fewest successive differences a 5-min window needs before its RMSSD joins
/// the nightly mean. RMSSD's relative sampling error is ~1/√(2n): 71 % at n = 1,
/// 32 % at n = 5, 16 % at n = 20 (cf. night_hrv_shape.dart). The
/// ultra-short-RMSSD literature (Munoz et al. 2015; Baek et al. 2015) puts the
/// shortest usable recording at roughly 10–30 s — 20 differences is 20–25 s at
/// a sleeping 48–60 bpm. The windows this drops sit where the signal is
/// disturbed (session edges, dropouts, ectopy), and those of ≤ 2 beats are the
/// ones `_cleanWindowRuns` cannot Malik-filter. `nocturnalRmssd`, a secondary
/// median estimator published under its own key, keeps its own floor of 5.
/// A floor, not a weight: weighting by n would weight by HEART RATE, letting
/// high-HR, low-RMSSD REM/arousal windows pull the mean down.
const int kMinDiffsPerRmssdWindow = 20;

/// The nightly headline RMSSD plus the diagnostics a `Metric<double>` cannot
/// carry. Present only when the headline is.
class SessionRmssd {
  final double rmssd; // ms — the headline
  final int windows; // 5-min windows that contributed
  final int overCountedWindows; // windows dropped for more beat-time than time
  final int thinWindows; // windows dropped for 0..floor−1 differences
  final int minDiffsPerWindow; // the floor, which travels with the number
  final double? diffAcf1; // pooled over the session's windows
  final double? rrCoverage; // [RrCoverage.coverage] of the session's beats
  const SessionRmssd({
    required this.rmssd,
    required this.windows,
    this.overCountedWindows = 0,
    this.thinWindows = 0,
    this.minDiffsPerWindow = kMinDiffsPerRmssdWindow,
    this.diffAcf1,
    this.rrCoverage,
  });
  Map<String, dynamic> toJson() => {
        'rmssd_ms': round6(rmssd),
        'windows': windows,
        'overcounted_windows': overCountedWindows,
        'thin_windows': thinWindows,
        'min_diffs_per_window': minDiffsPerWindow,
        if (diffAcf1 != null) 'diff_acf1': round6(diffAcf1!),
        if (rrCoverage != null) 'rr_coverage': round6(rrCoverage!),
      };
}

/// Sleep-session nightly RMSSD (ms) as the arithmetic mean of cleaned
/// consecutive 5-minute window RMSSDs.
///
/// Split the detected sleep session into consecutive 5-minute windows, apply a
/// simple RR cleaner (range-filter [300, 2000] ms + Malik-style ectopic
/// rejection against a local median), compute RMSSD inside each valid window,
/// then return the ARITHMETIC MEAN across windows. A window joins the mean only
/// with at least [minDiffsPerWindow] clean successive differences
/// ([kMinDiffsPerRmssdWindow]): an unweighted mean let a window of a handful of
/// differences across an arousal or a dropout edge count as much as a full
/// window of ~300, and those thin windows cluster where the signal is
/// disturbed, so the bias was upward. Thin windows — 0 to
/// [minDiffsPerWindow] − 1 differences, including one the cleaner left with
/// none — are counted ([SessionRmssd.thinWindows]), not silently lost, and
/// contribute nothing to the jitter verdict either. This is intentionally
/// distinct from [nocturnalRmssd], which uses cleaned NN +
/// median-of-windows robustness.
///
/// This is the nightly HEADLINE (→ `ln_rmssd` → readiness), so it refuses
/// rather than approximates: absent when the successive differences fail
/// [kNnDiffAcf1Floor], and absent when the session's beats bank more time than
/// elapsed ([kRrCoverageCeiling]).
///
/// [rrMs]/[rrTsMs] are the raw RR intervals and their beat-end epoch times in
/// milliseconds. [startSec]/[endSec] bound the chosen sleep session in epoch
/// seconds. The implementation is one-pass over the time-sorted RR stream:
/// beats are bucketed once by `(tsSec - startSec) ~/ windowSec`.
Metric<double> sleepSessionWindowedRmssd(
  List<double> rrMs,
  List<double> rrTsMs, {
  required int startSec,
  required int endSec,
  int windowSec = 300,
  int minDiffsPerWindow = kMinDiffsPerRmssdWindow,
}) {
  final m = sleepSessionRmssdDetail(rrMs, rrTsMs,
      startSec: startSec,
      endSec: endSec,
      windowSec: windowSec,
      minDiffsPerWindow: minDiffsPerWindow);
  return m.present
      ? Metric<double>(
          value: m.value!.rmssd,
          confidence: m.confidence,
          tier: m.tier,
          inputs_used: m.inputs_used,
          note: m.note,
        )
      : Metric<double>.absent(
          tier: m.tier, inputs_used: m.inputs_used, note: m.note);
}

/// [sleepSessionWindowedRmssd] with its diagnostics ([SessionRmssd]). The two
/// are one computation; this is the one that does it.
Metric<SessionRmssd> sleepSessionRmssdDetail(
  List<double> rrMs,
  List<double> rrTsMs, {
  required int startSec,
  required int endSec,
  int windowSec = 300,
  int minDiffsPerWindow = kMinDiffsPerRmssdWindow,
}) {
  const inputs = ['rr_sleep_window'];
  if (startSec <= 0 ||
      endSec <= startSec ||
      rrMs.isEmpty ||
      rrTsMs.isEmpty ||
      rrMs.length != rrTsMs.length) {
    return const Metric<SessionRmssd>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'invalid or empty RR session window',
    );
  }

  final buckets = <int, List<double>>{};
  final bucketsTs = <int, List<double>>{};
  final inRr = <double>[];
  final inTs = <double>[];
  for (var i = 0; i < rrMs.length; i++) {
    final tsSec = (rrTsMs[i] / 1000.0).round();
    if (tsSec < startSec || tsSec >= endSec) continue;
    final idx = ((tsSec - startSec) ~/ windowSec);
    (buckets[idx] ??= <double>[]).add(rrMs[i]);
    (bucketsTs[idx] ??= <double>[]).add(rrTsMs[i]);
    inRr.add(rrMs[i]);
    inTs.add(rrTsMs[i]);
  }

  if (buckets.isEmpty) {
    return const Metric<SessionRmssd>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'no RR beats inside the session window',
    );
  }
  final cov = rrCoverage(inRr, inTs);
  if (cov != null && cov.overCounted) {
    return Metric<SessionRmssd>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: _overcountNote(cov),
    );
  }

  final rmssds = <double>[];
  final runs = <List<double>>[]; // pooled jitter floor — see [nocturnalRmssd]
  final perWindow = <List<List<double>>>[];
  final meanRr = <double>[];
  var overCountedWindows = 0;
  var thinWindows = 0;
  final indices = buckets.keys.toList()..sort();
  for (final idx in indices) {
    // The session-wide ratio above can be diluted below the ceiling by a gap
    // elsewhere in the night while one stretch holds every beat twice. Each
    // window is judged on its own too: its beats cannot bank more beat-time
    // than the window has seconds — the session's last window may be cut
    // short by [endSec] — plus its earliest beat's own interval, which began
    // before its end stamp (as in [rrCoverage]). Dropped, not averaged in.
    final winRr = buckets[idx]!, winTs = bucketsTs[idx]!;
    final winStart = startSec + idx * windowSec;
    final winSec = math.min(winStart + windowSec, endSec) - winStart;
    var bankedMs = 0.0;
    var lo = 0;
    for (var i = 0; i < winRr.length; i++) {
      if (winTs[i] < winTs[lo]) lo = i;
      if (_rrCoverageCounts(winRr[i])) bankedMs += winRr[i];
    }
    final overhangMs = _rrCoverageCounts(winRr[lo]) ? winRr[lo] : 0.0;
    if (bankedMs > kRrCoverageCeiling * (winSec * 1000 + overhangMs)) {
      overCountedWindows++;
      continue;
    }
    final rrRuns = [
      for (final r in _cleanWindowRuns(buckets[idx]!, bucketsTs[idx]!))
        if (r.length >= 2) r
    ];
    final diffRuns = [
      for (final r in rrRuns) [for (var i = 1; i < r.length; i++) r[i] - r[i - 1]]
    ];
    var ssd = 0.0;
    var nd = 0;
    for (final r in diffRuns) {
      for (final d in r) {
        ssd += d * d;
        nd++;
      }
    }
    // A window with a handful of differences would otherwise weigh as much as
    // a full one in the mean. Counted, not silently lost — the detail and the
    // note both say how many. A window whose beats the cleaner reduced to no
    // difference at all is the thinnest of them, and counts too.
    if (nd < minDiffsPerWindow) {
      thinWindows++;
      continue;
    }
    runs.addAll(diffRuns);
    perWindow.add(diffRuns);
    meanRr.add(mean([for (final r in rrRuns) ...r])!);
    rmssds.add(math.sqrt(ssd / nd));
  }

  // Every note says what was dropped before the estimate, so a blank or a
  // thin headline can be told apart from a jitter refusal.
  final droppedWhy = [
    if (thinWindows > 0)
      '$thinWindows window(s) had fewer than $minDiffsPerWindow clean '
          'successive differences',
    if (overCountedWindows > 0)
      '$overCountedWindows window(s) held more beat-time than elapsed time',
  ];
  final dropped = droppedWhy.isEmpty ? '' : ' (${droppedWhy.join('; ')})';

  // THE HEADLINE nightly RMSSD (→ ln_rmssd → readiness). When the differences
  // are noise, the honest output is no headline, not a plausible one — the
  // readiness composite already treats a null HRV driver as absent.
  final acf1 = nnDiffAcf1(runs);
  final refused = _jitterRefused(acf1, runs);
  if (rmssds.isEmpty && !refused) {
    return Metric<SessionRmssd>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'no valid 5-min windows for sleep-session RMSSD$dropped',
    );
  }
  final kept = _keptWindows(acf1, refused, rmssds, perWindow, meanRr);
  if (kept == null) {
    return Metric<SessionRmssd>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: refused
          ? '${_jitterNote(acf1!)}$dropped'
          : '${_jitterNote(acf1!)}; no 5-min window clears it on its own'
              '$dropped',
    );
  }

  final meanRmssd = mean(kept.rmssds)!;
  final conf = kept.byBreathing
      ? 0.3
      : ((kept.rmssds.length / 12.0).clamp(0.0, 1.0) * _acf1Quality(acf1))
          .clamp(0.3, 0.95);
  return Metric<SessionRmssd>(
    value: SessionRmssd(
      rmssd: meanRmssd,
      windows: kept.rmssds.length,
      overCountedWindows: overCountedWindows,
      thinWindows: thinWindows,
      minDiffsPerWindow: minDiffsPerWindow,
      diffAcf1: acf1,
      rrCoverage: cov?.coverage,
    ),
    confidence: conf,
    tier: Tier.high,
    inputs_used: inputs,
    note: 'sleep-session HRV: mean RMSSD over cleaned 5-min windows'
        '$dropped.${kept.note}',
  );
}

/// Group NN intervals into consecutive 5-minute (300 000 ms) segments by beat
/// time. Segments with <2 beats are dropped.
List<List<double>> _fiveMinSegments(List<double> nn, List<double> times) {
  const segMs = 300000.0;
  final out = <List<double>>[];
  if (nn.isEmpty) return out;
  final t0 = times.first;
  var curIdx = 0;
  var cur = <double>[];
  for (var i = 0; i < nn.length; i++) {
    final idx = ((times[i] - t0) / segMs).floor();
    if (idx != curIdx) {
      if (cur.length >= 2) out.add(cur);
      cur = <double>[];
      curIdx = idx;
    }
    cur.add(nn[i]);
  }
  if (cur.length >= 2) out.add(cur);
  return out;
}

/// Range-filter [300, 2000] ms + Malik-style ectopic rejection against a local
/// median, returned as CONTIGUOUS RUNS of kept intervals.
///
/// Runs, not one compacted list: differencing straight down a compacted list
/// manufactures exactly one difference per rejected beat, spanning it — the same
/// defect `hrvTime` refuses at dropped runs and `irregularBeatScreen` refuses
/// with its keep-mask. MEASURED over the 13-night audit corpus: it inflated
/// the headline by 2–13 % on gen4 (57.2 → 52.3 ms at worst) and by 51–102 % on
/// MG (87.7 → 58.2, 82.9 → 40.9, 76.9 → 40.2 ms) — i.e. most of the "gen5
/// reads 2× gen4" gap was this, not physiology.
///
/// [ts] are [rr]'s beat-end epoch times (ms), same length/order as [rr]. Also
/// breaks a run across a real sensor gap between two beats that BOTH survive
/// the range/median filter — the same seam check `nocturnalRmssd` applies via
/// `nnTimesMs`, needed here too since two beats either side of a dropout can
/// individually pass and land adjacent in the compacted survivor list.
///
/// The real caller (`_sessionAvgHRV`) quantizes [ts] to whole seconds
/// (`RrTs.ts` is `(rrTsMs / 1000.0).round()`), so two independent roundings
/// can disagree with the true interval by up to ~1000 ms with no dropout at
/// all — the tolerance is `nn[i] + 1000.0`, not `nocturnalRmssd`'s `+ 0.5`
/// (which assumes sub-second beat times), so quantization alone never trips
/// it while an actual multi-second-or-longer dropout still does.
List<List<double>> _cleanWindowRuns(List<double> rr, List<double> ts) {
  const radius = 2;
  const threshold = 0.20;
  // Range filter first, keeping each survivor's position in [rr] — BOTH filters
  // break a run, so neither one's compaction can manufacture a difference.
  final nn = <double>[];
  final at = <int>[];
  final nnTs = <double>[];
  for (var i = 0; i < rr.length; i++) {
    if (rr[i] >= 300 && rr[i] <= 2000) {
      nn.add(rr[i]);
      at.add(i);
      nnTs.add(ts[i]);
    }
  }
  final runs = <List<double>>[];
  var run = <double>[];
  var lastKept = -2;
  var lastTs = 0.0;
  for (var i = 0; i < nn.length; i++) {
    var keep = true;
    if (nn.length > radius) {
      final lo = math.max(0, i - radius);
      final hi = math.min(nn.length - 1, i + radius);
      final neighbors = <double>[];
      for (var j = lo; j <= hi; j++) {
        if (j != i) neighbors.add(nn[j]);
      }
      final med = neighbors.length < 2 ? null : median(neighbors);
      if (med != null && med > 0) keep = (nn[i] - med).abs() / med <= threshold;
    }
    if (!keep) {
      if (run.isNotEmpty) {
        runs.add(run);
        run = <double>[];
      }
      continue;
    }
    if (run.isNotEmpty &&
        (at[i] != lastKept + 1 || nnTs[i] - lastTs > nn[i] + 1000.0)) {
      runs.add(run);
      run = <double>[];
    }
    run.add(nn[i]);
    lastKept = at[i];
    lastTs = nnTs[i];
  }
  if (run.isNotEmpty) runs.add(run);
  return runs;
}
