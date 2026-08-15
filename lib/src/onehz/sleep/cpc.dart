// SLEEP/CIRCADIAN — Cardiopulmonary Coupling (CPC). WITHDRAWN.
//
// Thomas et al. 2005 (Sleep) derives CPC from the cross-spectral coherence of
// TWO signals: the RR tachogram, and an ECG-DERIVED RESPIRATION (EDR) surrogate
// taken from the R-wave amplitude — a separate channel that is modulated by
// breathing but is NOT a function of the beat times.
//
// This implementation had no such channel. Its "respiration surrogate" was the
// NN series itself, linearly detrended:
//
//     resp = detrend([v - mean(nnMs) for v in nnMs])
//
// which differs from the tachogram only by a straight line. The coupling
// spectrum sqrt(P_rr . P_resp) therefore collapses to P_rr, and `cpc_ratio`
// came out equal to the plain RR periodogram HF/LF ratio — measured 84.493910
// vs 84.493190 on a 9000-beat synthetic, a ratio of 1.0000085. It was the LF/HF
// of the same tachogram we already publish as `lf_hf`, wearing the name of a
// different, published, sleep-stability measure.
//
// The honest options were "derive a real EDR" or "stop shipping it". We cannot
// derive an EDR here — this function is handed beat intervals and beat times
// and nothing else, and a respiration channel independent of the tachogram is
// by definition not recoverable from them. So the metric is WITHDRAWN: it now
// abstains, with the reason attached, and the UI element it fed should be
// DELETED rather than made to explain a dash.
//
// Wiring it back up means changing the signature to take an actual respiration
// channel (PPG AC amplitude / RIIV, cf. respiration/resp_rate.dart) and
// validating the result against something. Until then there is no number here.

import '../types.dart';
import '../util.dart';

class CpcResult {
  final double hfc; // high-frequency coupling power (stable NREM)
  final double lfc; // low-frequency coupling power (unstable / apnea-rich)
  final double vlfc; // very-low-frequency (wake/REM)
  final double cpcRatio; // HFC / LFC — sleep-stability index
  final double dominantHz; // dominant coupling frequency
  const CpcResult({
    required this.hfc,
    required this.lfc,
    required this.vlfc,
    required this.cpcRatio,
    required this.dominantHz,
  });
  Map<String, dynamic> toJson() => {
        'hfc': round6(hfc),
        'lfc': round6(lfc),
        'vlfc': round6(vlfc),
        'cpc_ratio': round6(cpcRatio),
        'dominant_hz': round6(dominantHz),
      };
}

/// CPC from a cleaned NN series + its beat times.
///
/// ALWAYS ABSENT — see the file header. There is no respiration channel in this
/// signature that is independent of [nnMs], so there is no coupling to measure;
/// the previous implementation republished the RR periodogram's own HF/LF ratio
/// under Thomas 2005's name. The signature is kept so callers keep compiling
/// while the key is removed at their end.
@Deprecated(
  'WITHDRAWN — this never measured cardiopulmonary coupling. Its "respiration '
  'surrogate" was the NN series itself, so cpc_ratio equalled the RR '
  'periodogram HF/LF ratio (measured agreement 1.0000085). Delete the cpc_ratio '
  'surface; reinstate only with a real respiration channel in the signature.',
)
Metric<CpcResult> cardiopulmonaryCoupling(
  List<double> nnMs,
  List<double> nnTimesMs,
) {
  return const Metric<CpcResult>.absent(
    tier: Tier.high,
    inputs_used: ['rr_corrected'],
    note: 'cardiopulmonary coupling needs a respiration channel independent of '
        'the beat times (Thomas 2005 uses an ECG-derived respiration); we have '
        'only the tachogram, so no coupling is measured',
  );
}
