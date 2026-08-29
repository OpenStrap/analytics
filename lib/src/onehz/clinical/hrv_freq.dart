// CLINICAL TIER-1 — frequency-domain HRV via Lomb-Scargle on NATIVE beat times.
//
// Laguna 1998 / Bigger 1992. We deliberately use Lomb-Scargle on the irregular
// beat-occurrence times rather than FFT on a resampled tachogram — this is the
// correct PSD for unevenly-sampled RR and avoids resampling artifacts. Bands:
//   ULF < 0.003 Hz | VLF 0.003–0.04 | LF 0.04–0.15 | HF 0.15–0.40 | total
// Normalized units: nu_lf = LF/(LF+HF)·100, nu_hf = HF/(LF+HF)·100.
//
// Band powers are WELCH-AVERAGED (Welch 1967): the record is split into
// segments short enough that a modest frequency grid resolves them, each
// segment's Lomb-Scargle PSD is integrated over the band on its own
// resolution-matched grid, and the per-segment powers are averaged. See
// [_welchBandPower] for why a single whole-night grid cannot work.
//
// HONESTY: HF is the band most corrupted by 1 Hz timing quantization and by
// artifacts — we GATE HF (and LF/HF, nu) on the artifact fraction and report
// reduced confidence. Every band is null unless the record is long enough to
// RESOLVE it (ULF genuinely needs 24 h) — never a leakage-filled 0.0.

import '../types.dart';
import '../util.dart';

class HrvFreq {
  final double? ulf;
  final double? vlf;
  final double? lf;
  final double? hf;
  final double? total;

  /// Which bands [total] is the sum of. Null exactly when [total] is null. A
  /// band the record could not resolve is ABSENT from this list, never a 0 in
  /// the sum — so "total" always says what it totalled.
  final List<String>? totalBands;
  final double? lfhf;
  final double? nuLf;
  final double? nuHf;
  final bool hfGated; // true if HF was suppressed due to artifact fraction
  const HrvFreq({
    this.ulf,
    this.vlf,
    this.lf,
    this.hf,
    this.total,
    this.totalBands,
    this.lfhf,
    this.nuLf,
    this.nuHf,
    required this.hfGated,
  });
  Map<String, dynamic> toJson() => {
        if (ulf != null) 'ulf': round6(ulf!),
        if (vlf != null) 'vlf': round6(vlf!),
        if (lf != null) 'lf': round6(lf!),
        if (hf != null) 'hf': round6(hf!),
        if (total != null) 'total': round6(total!),
        if (totalBands != null) 'total_bands': totalBands,
        if (lfhf != null) 'lf_hf': round6(lfhf!),
        if (nuLf != null) 'nu_lf': round6(nuLf!),
        if (nuHf != null) 'nu_hf': round6(nuHf!),
        'hf_gated': hfGated,
      };
}

/// Frequency-domain HRV from cleaned NN.
///
/// [nnMs] cleaned NN intervals (ms). [nnTimesMs] their cumulative beat times
/// (ms). [artifactFraction] from the RR-correction step (0..1) — drives the HF
/// gate and confidence. [hfArtifactGate] threshold above which HF is suppressed.
Metric<HrvFreq> hrvFreq(
  List<double> nnMs,
  List<double> nnTimesMs, {
  required double artifactFraction,
  double hfArtifactGate = 0.15,
  double oversample = 4.0,
}) {
  const inputs = ['rr_cleaned', 'beat_times'];
  if (nnMs.length < 16 || nnTimesMs.length != nnMs.length) {
    return const Metric<HrvFreq>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'too few beats for a spectral estimate',
    );
  }

  // Times in seconds for Hz output; tachogram value = NN (ms).
  final tSec = [for (final t in nnTimesMs) t / 1000.0];
  final spanSec = tSec.last - tSec.first;
  if (spanSec <= 0) {
    return const Metric<HrvFreq>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'degenerate beat times',
    );
  }

  // Each band gets its own segment length and its own resolution-matched grid.
  // A band whose lowest frequency the record is too short to resolve returns
  // null — absent, not a leakage-filled 0.0 (ULF used to be emitted as exactly
  // 0.0 for any session over 333 s, which is not a 24-h record by any reading).
  final ulf =
      _welchBandPower(tSec, nnMs, 0.0003, 0.003, oversample: oversample);
  final vlf = _welchBandPower(tSec, nnMs, 0.003, 0.04, oversample: oversample);
  final lf = _welchBandPower(tSec, nnMs, 0.04, 0.15, oversample: oversample);
  final hfRaw = _welchBandPower(tSec, nnMs, 0.15, 0.40, oversample: oversample);
  if (lf == null && hfRaw == null) {
    return const Metric<HrvFreq>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'record too short to resolve any HRV band',
    );
  }

  final hfGated = artifactFraction > hfArtifactGate;
  final hf = hfGated ? null : hfRaw;

  double? lfhf, nuLf, nuHf;
  if (lf != null && hf != null && (lf + hf) > 0) {
    lfhf = hf == 0 ? null : lf / hf;
    nuLf = 100.0 * lf / (lf + hf);
    nuHf = 100.0 * hf / (lf + hf);
  }
  // TOTAL POWER is by definition the sum over ALL bands (Task Force 1996).
  // When HF is suppressed we do not have a trustworthy HF term, so a "total"
  // is not computable: silently summing the withheld hfRaw back in republished
  // exactly the quantity the gate withheld (the gated and ungated totals came
  // out bit-identical), and dropping HF from the sum would republish a
  // different quantity under the same name. Either way it would be dishonest —
  // so total is WITHHELD alongside HF.
  //
  // A band the record could not RESOLVE is a different case, and it used to be
  // handled with `?? 0` — which is exactly the absence-as-zero this package
  // forbids, and it is not hypothetical: ULF needs 33 333 s of span (10 cycles
  // at 0.0003 Hz) and a night is ~28 700 s, so ULF resolved on precisely no
  // nights and the published total was silently the ULF-less sum. Withholding
  // total instead would delete a rendered number on every night forever. So it
  // is published with its composition NAMED in [totalBands]: the sum is over
  // those bands and no others.
  final bands = <String, double?>{
    'ulf': ulf,
    'vlf': vlf,
    'lf': lf,
    'hf': hfRaw
  };
  final resolved = [
    for (final e in bands.entries)
      if (e.value != null) e.key
  ];
  final total = (hfGated || lf == null || hfRaw == null)
      ? null
      : [for (final b in resolved) bands[b]!].reduce((a, b) => a + b);

  // Confidence: penalize artifacts heavily; low-band-only reads still HIGH-ish.
  final conf = ((1 - artifactFraction) * (hfGated ? 0.6 : 0.9)).clamp(0.2, 0.9);
  return Metric<HrvFreq>(
    value: HrvFreq(
      ulf: ulf,
      vlf: vlf,
      lf: lf,
      hf: hf,
      total: total,
      totalBands: total == null ? null : resolved,
      lfhf: lfhf,
      nuLf: nuLf,
      nuHf: nuHf,
      hfGated: hfGated,
    ),
    confidence: conf,
    tier: Tier.high,
    inputs_used: inputs,
    note: hfGated
        ? 'HF suppressed: artifact fraction ${round6(artifactFraction)} '
            '> gate — LF/VLF reported, HF/LF-HF/nu/total withheld'
        : 'PRV spectrum; HF band quantization-limited at 1 Hz',
  );
}

/// Welch-averaged Lomb-Scargle power in [loHz, hiHz), or null when the record
/// is too short to RESOLVE that band.
///
/// Why not one grid over the whole night: an 8 h record's periodogram has peaks
/// ~1/28800 Hz wide, so a rectangular sum over a grid coarser than that is a
/// lucky sample of the peaks, not an integral. The shipped 600-point grid put
/// `lf_hf` at 0.095 on a synthetic whose converged value is 2.243 — a factor of
/// 20+, on the one spectral number that is charted, stored and fed to the coach.
/// The resolution-matched grid for a whole night is ~50k points and measured
/// 18 s per night on this hardware; 600 points measured 1.2 s. Neither is
/// acceptable: one is wrong, the other unshippable.
///
/// So, Welch 1967: split the record into segments SHORT enough that a modest
/// grid resolves them, integrate each segment's PSD over the band on its own
/// resolution-matched grid, and average. Segment length is [cyclesPerSegment]
/// periods of the band's LOWEST frequency, so the band is resolved by
/// construction; grid spacing is the segment's resolution (1/segment) divided
/// by [oversample]. Cost is O(beats x gridPoints) per band and independent of
/// how many segments the record splits into — measured ~1.4 s for a full night,
/// i.e. no worse than the wrong version it replaces, with the periodogram's
/// large variance averaged down as a bonus.
///
/// Averaging per-segment powers means the estimate excludes variance slower
/// than one segment — correct by definition for a band whose lowest frequency
/// sets the segment length, and the reason each band is segmented separately.
double? _welchBandPower(
  List<double> tSec,
  List<double> y,
  double loHz,
  double hiHz, {
  double cyclesPerSegment = 10.0,
  double oversample = 4.0,
  int minPointsPerSegment = 16,
}) {
  if (loHz <= 0 || hiHz <= loHz || tSec.length < minPointsPerSegment)
    return null;
  final span = tSec.last - tSec.first;
  final segSec = cyclesPerSegment / loHz;
  if (span < segSec) return null; // band not resolvable in this record

  final df = 1.0 / segSec / oversample;
  final nGrid = ((hiHz - loHz) / df).ceil() + 1;
  final grid = freqGrid(loHz, hiHz, nGrid);

  var sum = 0.0;
  var k = 0;
  final step = segSec / 2; // 50 % overlap, the Welch default
  for (var start = tSec.first; start + segSec <= tSec.last; start += step) {
    final end = start + segSec;
    final ts = <double>[];
    final ys = <double>[];
    for (var i = 0; i < tSec.length; i++) {
      if (tSec[i] < start) continue;
      if (tSec[i] >= end) break;
      ts.add(tSec[i]);
      ys.add(y[i]);
    }
    if (ts.length < minPointsPerSegment) continue;
    final ls = lombScargle(ts, ys, grid);
    if (ls == null) continue;
    final p = ls.bandPower(loHz, hiHz);
    if (!p.isFinite) continue;
    sum += p;
    k++;
  }
  return k == 0 ? null : sum / k;
}
