// FOUNDATION — honest fusion / uncertainty propagation.
//
// Inverse-variance fusion (Aitken 1935): the minimum-variance unbiased linear
// combination of independent estimates weights each by 1/σ²; the fused
// variance is 1/Σ(1/σ²). Simple GUM (JCGM 100:2008) uncertainty propagation for
// a weighted sum gives the combined standard uncertainty.
//
// Biased motion-artifact inputs are gated OUT, not down-weighted: a caller
// passes `trusted=false` for any channel the SQI gate rejected, and those are
// excluded entirely from the fusion.

import 'dart:math' as math;

/// One estimate to fuse: a value, its variance (σ²>0), and a trust flag from
/// the SQI/contact gate. An untrusted input is DROPPED, not down-weighted.
class FusionInput {
  final double value;
  final double variance; // σ²
  final bool trusted;
  final String label;
  const FusionInput(this.value, this.variance,
      {this.trusted = true, this.label = ''});
}

class FusionResult {
  final double? value; // fused estimate (null if nothing trusted)
  final double? variance; // fused variance
  final double? stdUncertainty; // √variance
  final List<String> used; // labels actually fused
  final List<String> dropped; // labels gated out
  const FusionResult({
    required this.value,
    required this.variance,
    required this.stdUncertainty,
    required this.used,
    required this.dropped,
  });
}

/// Inverse-variance (precision-weighted) fusion. Drops untrusted or
/// non-positive-variance inputs. Returns an absent result if nothing survives.
FusionResult inverseVarianceFuse(List<FusionInput> inputs) {
  final used = <String>[];
  final dropped = <String>[];
  var wsum = 0.0; // Σ 1/σ²
  var vwsum = 0.0; // Σ value/σ²
  for (final inp in inputs) {
    if (!inp.trusted || inp.variance <= 0 || inp.value.isNaN) {
      dropped.add(inp.label);
      continue;
    }
    final w = 1 / inp.variance;
    wsum += w;
    vwsum += inp.value * w;
    used.add(inp.label);
  }
  if (wsum == 0) {
    return FusionResult(
        value: null,
        variance: null,
        stdUncertainty: null,
        used: const [],
        dropped: dropped);
  }
  final fusedVar = 1 / wsum;
  final fused = vwsum / wsum;
  return FusionResult(
    value: fused,
    variance: fusedVar,
    stdUncertainty: math.sqrt(fusedVar),
    used: used,
    dropped: dropped,
  );
}

/// Map a per-input SNR (or contact-quality 0..1) to a variance, so the SQI
/// channel directly drives fusion weight. Higher quality => lower variance.
/// variance = baseVariance / max(quality, floor).
double varianceFromQuality(double quality, double baseVariance,
    {double floor = 0.05}) {
  final q = quality < floor ? floor : (quality > 1 ? 1 : quality);
  return baseVariance / q;
}

/// GUM combined standard uncertainty for a weighted sum y = Σ wᵢ·xᵢ with
/// independent inputs: u_c = √(Σ (wᵢ·uᵢ)²). Returns null on length mismatch.
double? gumWeightedSumUncertainty(
    List<double> weights, List<double> stdUncertainties) {
  if (weights.length != stdUncertainties.length || weights.isEmpty) return null;
  var s = 0.0;
  for (var i = 0; i < weights.length; i++) {
    final term = weights[i] * stdUncertainties[i];
    s += term * term;
  }
  return math.sqrt(s);
}
