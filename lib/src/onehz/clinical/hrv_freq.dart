// CLINICAL TIER-1 — frequency-domain HRV via Lomb-Scargle on NATIVE beat times.
//
// Laguna 1998 / Bigger 1992. We deliberately use Lomb-Scargle on the irregular
// beat-occurrence times rather than FFT on a resampled tachogram — this is the
// correct PSD for unevenly-sampled RR and avoids resampling artifacts. Bands:
//   ULF < 0.003 Hz | VLF 0.003–0.04 | LF 0.04–0.15 | HF 0.15–0.40 | total
// Normalized units: nu_lf = LF/(LF+HF)·100, nu_hf = HF/(LF+HF)·100.
//
// HONESTY: HF is the band most corrupted by 1 Hz timing quantization and by
// artifacts — we GATE HF (and LF/HF, nu) on the artifact fraction and report
// reduced confidence. ULF needs a 24-h record; null on short reads.

import '../types.dart';
import '../util.dart';

class HrvFreq {
  final double? ulf;
  final double? vlf;
  final double? lf;
  final double? hf;
  final double? total;
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
  int gridPoints = 600,
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

  // Frequency grid: from ~1/span up to the HF ceiling (0.4 Hz).
  final loHz = (1.0 / spanSec).clamp(0.0005, 0.04);
  final ls = lombScargle(tSec, nnMs, freqGrid(loHz, 0.4, gridPoints));
  if (ls == null) {
    return const Metric<HrvFreq>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'spectrum undefined',
    );
  }

  // Only report ULF/VLF if the record is long enough to resolve them.
  final ulf = spanSec >= 1.0 / 0.003 ? ls.bandPower(0, 0.003) : null;
  final vlf = spanSec >= 1.0 / 0.04 ? ls.bandPower(0.003, 0.04) : null;
  final lf = ls.bandPower(0.04, 0.15);
  final hfRaw = ls.bandPower(0.15, 0.40);

  final hfGated = artifactFraction > hfArtifactGate;
  final hf = hfGated ? null : hfRaw;

  double? lfhf, nuLf, nuHf;
  if (hf != null && (lf + hf) > 0) {
    lfhf = hf == 0 ? null : lf / hf;
    nuLf = 100.0 * lf / (lf + hf);
    nuHf = 100.0 * hf / (lf + hf);
  }
  final total = (ulf ?? 0) + (vlf ?? 0) + lf + hfRaw;

  // Confidence: penalize artifacts heavily; low-band-only reads still HIGH-ish.
  final conf = clamp((1 - artifactFraction) * (hfGated ? 0.6 : 0.9), 0.2, 0.9);
  return Metric<HrvFreq>(
    value: HrvFreq(
      ulf: ulf,
      vlf: vlf,
      lf: lf,
      hf: hf,
      total: total,
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
            '> gate — LF/VLF reported, HF/LF-HF/nu withheld'
        : 'PRV spectrum; HF band quantization-limited at 1 Hz',
  );
}
