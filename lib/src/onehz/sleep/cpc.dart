// SLEEP/CIRCADIAN TIER MED-HIGH — Cardiopulmonary Coupling (CPC).
//
// Thomas et al. 2005 (Sleep) — CPC quantifies sleep stability from the
// cross-spectral COHERENCE × power of two signals derived from the ECG/PPG:
//   (1) heart-rate variability (here: the NN/RR series), and
//   (2) an ECG-derived respiration (EDR) surrogate. We have continuous beat-to-
//       beat RR, so we use an RSA/RIIV-style RESPIRATION SURROGATE built from
//       the RR amplitude itself (the respiratory sinus arrhythmia signature),
//       a published substitute for EDR.
//
// Thomas bands (cycles/beat in the original; we map to Hz on the resampled
// tachogram — see below):
//   - High-Frequency Coupling (HFC, ~0.1–0.4 Hz): STABLE NREM sleep.
//   - Low-Frequency Coupling  (LFC, ~0.01–0.1 Hz): UNSTABLE sleep / CAP /
//     apnea-rich periods.
//   - Very-Low-Frequency (VLFC, <0.01 Hz): wake/REM.
//
// Method here (deterministic, Lomb-Scargle based — no FFT-on-resample needed):
//   * Build the RR tachogram on native beat times.
//   * Derive a respiration surrogate = the band-limited RSA component of RR.
//   * Compute the CROSS-coherence-weighted spectrum: at each frequency, the
//     coupling power = sqrt(P_rr(f) · P_resp(f)) · coherence(f), where we
//     approximate coherence by the normalized cross term. Integrate per band.
//   * Report HFC, LFC, VLFC band powers + the CPC ratio (HFC / LFC) — the
//     stability index. High HFC/LFC ⇒ stable sleep.
//
// This is a SCREEN (sleep-stability spectrogram + apnea-risk hint), not a
// diagnosis — the catalog tier is MED-HIGH.

import 'dart:math' as math;
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
/// [nnMs] cleaned NN intervals (ms). [nnTimesMs] matching cumulative beat times
/// (ms). Both from `correctRr`. The respiration surrogate is built internally.
Metric<CpcResult> cardiopulmonaryCoupling(
  List<double> nnMs,
  List<double> nnTimesMs,
) {
  const inputs = ['rr_corrected', 'rsa_respiration_surrogate'];
  final n = nnMs.length;
  if (n < 60 || nnTimesMs.length != n) {
    return const Metric<CpcResult>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'too few beats for cardiopulmonary coupling',
    );
  }

  // Times in seconds (Lomb-Scargle expects consistent unit → Hz output).
  final tSec = [for (final t in nnTimesMs) t / 1000.0];

  // Respiration surrogate (RSA): the RR series band-limited to the respiratory
  // band is itself the EDR substitute. We use the same native beat times but a
  // high-pass-detrended copy of NN to emphasize the respiratory modulation.
  final nnMean = mean(nnMs)!;
  final resp = _detrend([for (final v in nnMs) v - nnMean]);

  // Frequency grid over the coupling bands (VLF..HF), in Hz.
  final freqs = freqGrid(0.001, 0.45, 200);
  final lsRr = lombScargle(tSec, nnMs, freqs);
  final lsResp = lombScargle(tSec, resp, freqs);
  if (lsRr == null || lsResp == null) {
    return const Metric<CpcResult>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'spectral estimate degenerate (no variance)',
    );
  }

  // Coupling spectrum = geometric-mean coherence: at each f, the coupled power
  // is sqrt(P_rr·P_resp) (high only where BOTH have power — a coherence proxy).
  final coupling = <LsPoint>[];
  var domF = 0.0, domP = double.negativeInfinity;
  for (var i = 0; i < freqs.length; i++) {
    final p = math.sqrt(
        math.max(0, lsRr.spectrum[i].power) *
            math.max(0, lsResp.spectrum[i].power));
    coupling.add(LsPoint(freqs[i], p));
    if (p > domP) {
      domP = p;
      domF = freqs[i];
    }
  }
  final couplingLs = LombScargle(coupling);

  final vlfc = couplingLs.bandPower(0.001, 0.01);
  final lfc = couplingLs.bandPower(0.01, 0.1);
  final hfc = couplingLs.bandPower(0.1, 0.4);

  // A non-finite band power means the input itself was poisoned (a NaN/±inf RR
  // or beat time survives every arithmetic step, and `variance <= 0` does not
  // catch NaN). Nothing measured here is real, so nothing is reported.
  if (!hfc.isFinite || !lfc.isFinite || !vlfc.isFinite) {
    return const Metric<CpcResult>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'coupling spectrum non-finite (NaN/inf in the NN series or beat '
          'times) — no coupling was measured',
    );
  }

  // Thomas et al. 2005 defines the stability index as the RATIO of high- to
  // low-frequency coupling power. With no LFC power at all the ratio is a
  // DIVISION BY ZERO — mathematically undefined, not "infinitely stable" (and
  // 0/0 is not "maximally unstable" either). The published method says nothing
  // about a spectrum with an empty 0.01–0.1 Hz band, so we abstain rather than
  // report a number. (Pre-2026-07 this emitted the sentinel 999.0 inside a live
  // Metric at confidence up to 0.85, which downstream read as a real,
  // extraordinarily stable night.)
  if (lfc <= 0) {
    return const Metric<CpcResult>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'no low-frequency (0.01-0.1 Hz) coupling power — the Thomas 2005 '
          'HFC/LFC stability ratio is undefined here, not "perfectly stable"',
    );
  }
  final ratio = hfc / lfc;
  if (!ratio.isFinite) {
    return const Metric<CpcResult>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'HFC/LFC stability ratio overflowed — not a measurement',
    );
  }

  // Confidence grows with record length; capped (a screen, not a diagnosis).
  final conf = clamp(n / 3600.0, 0.3, 0.85);
  return Metric<CpcResult>(
    value: CpcResult(
      hfc: hfc,
      lfc: lfc,
      vlfc: vlfc,
      cpcRatio: ratio,
      dominantHz: domF,
    ),
    confidence: conf,
    tier: Tier.high,
    inputs_used: inputs,
    note: 'Thomas 2005 CPC via Lomb-Scargle coupling spectrum; '
        'HFC=stable NREM, LFC=unstable/apnea-rich. Screen, not diagnosis',
  );
}

/// Remove a linear trend (OLS) from a series — leaves the oscillatory part.
List<double> _detrend(List<double> y) {
  final fit = olsFit(y);
  if (fit == null) return y;
  return [
    for (var i = 0; i < y.length; i++) y[i] - (fit.slope * i + fit.intercept)
  ];
}
