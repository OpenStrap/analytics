// RESPIRATION TIER-1 — 24/7 respiratory rate from the 1 Hz substrate.
//
// Two independent estimators + an honest fusion gate:
//   * RSA respiratory rate (PRIMARY) — Lomb-Scargle HF-peak on cleaned NN beat
//     times. Respiratory sinus arrhythmia modulates RR at the breathing
//     frequency; the HF (0.15–0.40 Hz) spectral peak => breaths/min.
//     Pimentel 2017-style robustness: estimate over several Lomb-Scargle grid
//     resolutions ("multiple AR-order surrogates") and keep the result only if
//     they agree (low dispersion) — otherwise withhold.
//   * RIIV respiratory rate — band-pass 0.1–0.5 Hz on the 1 Hz green PPG ADC
//     (respiratory-induced intensity variation), peak frequency => breaths/min.
//   * Karlen 2013 SD-gate fusion — discard a window when the two estimates
//     disagree by more than a threshold (Smart Fusion), else inverse-variance
//     fuse them into a single honest rate.
//
// HONESTY CEILINGS:
//   * RIIV rides the 1 Hz green ADC, whose Nyquist caps any rate at 0.5 Hz =
//     30 br/min. We refuse to report a peak at/above that ceiling (aliasing).
//   * RSA rides the TACHOGRAM, which is sampled once per BEAT, not once per
//     second — so its ceiling is the beat-rate Nyquist (0.5/meanNN), ~37 br/min
//     at HR 75 but only ~25 br/min at HR 50. [rsaRespRate] computes that
//     ceiling per window, caps it at [respHiHz], and withholds the whole window
//     when that ceiling falls below the classic HF band (the alias would be
//     indistinguishable from a genuine slower rate). A rate the window cannot
//     resolve is ABSENT, never a spurious in-band peak dressed up as a normal
//     number.
//   * Neither estimator can see a TRUE rate above [respHiHz] (30 br/min). Such
//     a window yields a low peak near the ceiling, not an absence — sustained
//     adult tachypnea is outside what this module claims to measure.
//   * RSA is HIGH tier (continuous 24/7, the structural edge); RIIV is MED
//     (1 Hz green is a coarse intensity proxy, not the 419 Hz waveform).
//   * Absent / insufficient input => null + confidence 0, never a guess.

import 'dart:math' as math;
import '../types.dart';
import '../util.dart';
import '../foundations/fusion.dart';

/// Hard physiological + Nyquist band for adult respiration on a 1 Hz signal.
/// Lower 0.1 Hz = 6 br/min; upper 0.5 Hz = 30 br/min (the 1 Hz Nyquist limit).
const double respLoHz = 0.1;
const double respHiHz = 0.5;

/// RSA uses the classic HRV HF band (0.15–0.40 Hz = 9–24 br/min) where the
/// respiratory peak lives in the RR spectrum.
///
/// [rsaHiHz] is the top of the *classic HF band*, NOT the search ceiling.
/// Searching only to 0.40 Hz was a silent 24 br/min cap: a real 26–29 br/min
/// breather has no peak inside the band, so the search returned the largest
/// spurious in-band structure instead — measured 26.4 → 22.3 and 28.8 → 17.4,
/// both published at confidence 0.90. [rsaRespRate] therefore searches up to
/// the window's own resolvable ceiling (see [rsaCeilingHz]) and withholds a
/// peak that lands there.
const double rsaLoHz = 0.15;
const double rsaHiHz = 0.40;

/// The highest respiratory frequency an RSA window can actually resolve (Hz).
///
/// The tachogram is sampled once per BEAT, so its Nyquist is `0.5 / meanNN`,
/// not 0.5 Hz. At HR 75 (NN 800 ms) that is 0.625 Hz; at HR 50 it is 0.417 Hz.
/// [respHiHz] caps it because nothing downstream of a 1 Hz record should claim
/// more than 30 br/min.
double rsaCeilingHz(double meanNnSec) {
  if (!meanNnSec.isFinite || meanNnSec <= 0) return respHiHz;
  final nyq = 0.5 / meanNnSec;
  return nyq < respHiHz ? nyq : respHiHz;
}

/// One respiratory-rate estimate (breaths/min) plus its provenance.
class RespEstimate {
  final double? brpm; // breaths per minute
  final double? peakHz; // the spectral peak (Hz)
  final double? power; // peak power (normalized)
  final String source; // 'rsa' | 'riiv'
  const RespEstimate(this.brpm, this.peakHz, this.power, this.source);
  Map<String, dynamic> toJson() => {
        'brpm': brpm == null ? null : round6(brpm!),
        if (peakHz != null) 'peak_hz': round6(peakHz!),
        if (power != null) 'power': round6(power!),
        'source': source,
      };
}

/// RSA respiratory rate from cleaned NN beat times (PRIMARY 24/7 source).
///
/// [nnMs] cleaned NN intervals (ms), [nnTimesMs] their cumulative beat times
/// (ms). [artifactFraction] from RR-correction drives the confidence gate.
/// Pimentel-style robustness: re-estimate the HF peak across several grid
/// resolutions; accept only if they agree within [agreeBrpm] br/min.
Metric<RespEstimate> rsaRespRate(
  List<double> nnMs,
  List<double> nnTimesMs, {
  required double artifactFraction,
  double agreeBrpm = 3.0,
  double maxArtifact = 0.30,
}) {
  const inputs = ['rr_cleaned', 'beat_times'];
  if (nnMs.length < 20 || nnTimesMs.length != nnMs.length) {
    return const Metric<RespEstimate>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'too few beats for an RSA spectral estimate (need ≥20)',
    );
  }
  if (artifactFraction > maxArtifact) {
    return Metric<RespEstimate>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'artifact fraction ${round6(artifactFraction)} > gate '
          '— RSA peak unreliable',
    );
  }
  final tSec = [for (final t in nnTimesMs) t / 1000.0];
  final spanSec = tSec.last - tSec.first;
  if (spanSec <= 0) {
    return const Metric<RespEstimate>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'degenerate beat times',
    );
  }

  // SEARCH CEILING. The window's own beat-rate Nyquist, capped at [respHiHz].
  // The search used to stop at [rsaHiHz] while the guard below tested against
  // [respHiHz], so the guard was unreachable and the 24 br/min cap was silent.
  final meanNnSec = spanSec / (nnMs.length - 1);
  final hiHz = rsaCeilingHz(meanNnSec);
  // The ceiling must at least cover the classic HF band. Below that, a rate
  // inside the band the literature defines would fold back down into the band
  // as an alias and be indistinguishable from a genuine slower one — measured:
  // 26 br/min at NN 1400 ms folds to 16.9 br/min with a full-height peak. No
  // spectral test can separate the two, so the honest answer is nothing at all.
  if (hiHz < rsaHiHz) {
    return Metric<RespEstimate>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'beat rate ${round6(60 / meanNnSec)} bpm resolves only to '
          '${round6(hiHz * 60)} br/min — below the HF band, any peak could be '
          'an alias; rate withheld',
    );
  }

  // Pimentel 2017 robustness surrogate: vary the spectral resolution (a
  // deterministic analogue of varying the AR model order) and require the HF
  // peak to be stable across them. A respiratory peak is sharp & resolution-
  // invariant; spurious HRV structure or artifact is not.
  final peaks = <double>[]; // br/min
  final peakHz = <double>[]; // the same peaks in Hz, index-aligned
  final peakPwr = <double>[]; // their spectral power, index-aligned
  var atCeiling = false;
  for (final grid in const [300, 450, 700]) {
    final freqs = freqGrid(rsaLoHz, hiHz, grid);
    final ls = lombScargle(tSec, nnMs, freqs);
    if (ls == null) continue;
    final pk = ls.peakFreq(rsaLoHz, hiHz);
    if (pk == null) continue;
    // A peak pinned to the top of the searchable band means the true rate is
    // at or above what this window can resolve. That is an ABSENCE, not a rate:
    // reporting the edge would publish the ceiling as if it were a measurement.
    final step = grid > 1 ? (hiHz - rsaLoHz) / (grid - 1) : hiHz - rsaLoHz;
    if (pk >= hiHz - step) {
      atCeiling = true;
      continue;
    }
    peaks.add(pk * 60.0);
    peakHz.add(pk);
    peakPwr.add(_powerAt(ls, pk));
  }
  if (atCeiling && peaks.length < 2) {
    return Metric<RespEstimate>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'respiratory peak at/above the resolvable ceiling '
          '(${round6(hiHz * 60)} br/min) — rate withheld',
    );
  }
  if (peaks.length < 2) {
    return const Metric<RespEstimate>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'no stable HF respiratory peak resolved',
    );
  }
  // Agreement gate (the robustness check).
  final spread = (peaks.reduce(math.max) - peaks.reduce(math.min));
  if (spread > agreeBrpm) {
    return Metric<RespEstimate>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'HF peak unstable across spectral resolutions '
          '(spread ${round6(spread)} br/min) — withheld',
    );
  }
  // ONE SOURCE for the reported triple. `brpm` used to be median(peaks) while
  // `peakHz`/`power` came from the highest-POWER grid, so `peak_hz * 60` and
  // `brpm` could disagree by up to [agreeBrpm] inside a single RespEstimate.
  // We now pick the MEDOID grid — the grid whose peak is closest to the median
  // across grids — and report its rate, frequency and power together, so
  // `brpm == peakHz * 60` holds exactly and `power` is the power measured AT
  // the reported frequency. (With three grids the medoid IS the median; with
  // two, the nearer of the pair. Robustness still comes from the agreement gate
  // above, which already rejected any disagreeing set.)
  final medBrpm = median(peaks)!;
  var best = 0;
  for (var i = 1; i < peaks.length; i++) {
    if ((peaks[i] - medBrpm).abs() < (peaks[best] - medBrpm).abs()) best = i;
  }
  final brpm = peaks[best];
  final bestPeakHz = peakHz[best];
  final bestPower = peakPwr[best];
  // Confidence: high when clean & resolution-stable; penalize artifacts and
  // wide spread. Cap below 1 (PRV ceiling).
  final conf = clamp(
    (1 - artifactFraction) * (1 - spread / (agreeBrpm * 2)),
    0.2,
    0.9,
  );
  return Metric<RespEstimate>(
    value: RespEstimate(brpm, bestPeakHz, bestPower, 'rsa'),
    confidence: conf,
    tier: Tier.high,
    inputs_used: inputs,
    note: 'RSA HF-peak respiratory rate (Lomb-Scargle on native beat times, '
        'medoid of ${peaks.length} spectral resolutions — brpm, peak_hz and '
        'power all come from that one grid); PRV-derived; this window could '
        'resolve up to ${round6(hiHz * 60)} br/min',
  );
}

/// RIIV respiratory rate from the 1 Hz green PPG ADC.
///
/// Respiratory-Induced Intensity Variation: a 0.1–0.5 Hz band-pass on the green
/// ADC, then the dominant spectral peak in the respiratory band => breaths/min.
/// [adc] the 1 Hz green ADC samples, [tsSec] their times (seconds). Uneven
/// times are fine — we use Lomb-Scargle, no resampling. [validFraction] of the
/// window that passed the contact/SQI gate drives confidence.
Metric<RespEstimate> riivRespRate(
  List<double> adc,
  List<double> tsSec, {
  double validFraction = 1.0,
}) {
  const inputs = ['ppg_green', 'ts'];
  final n = adc.length;
  if (n < 30 || tsSec.length != n) {
    return const Metric<RespEstimate>.absent(
      tier: Tier.relative,
      inputs_used: inputs,
      note: 'too few green-ADC samples for RIIV (need ≥30 s)',
    );
  }
  final spanSec = tsSec.last - tsSec.first;
  if (spanSec <= 0) {
    return const Metric<RespEstimate>.absent(
      tier: Tier.relative,
      inputs_used: inputs,
      note: 'degenerate timestamps',
    );
  }
  // Detrend (remove DC/slow baseline wander) via a robust-ish linear fit; the
  // band-pass character comes from restricting the Lomb-Scargle grid to the
  // respiratory band, which rejects both DC (<0.1 Hz) and HR/cardiac (>0.5 Hz).
  final fit = olsFit(adc, tsSec);
  final detr = <double>[];
  for (var i = 0; i < n; i++) {
    final base = fit == null ? 0.0 : (fit.slope * tsSec[i] + fit.intercept);
    detr.add(adc[i] - base);
  }
  final ls = lombScargle(tsSec, detr, freqGrid(respLoHz, respHiHz, 500));
  if (ls == null) {
    return const Metric<RespEstimate>.absent(
      tier: Tier.relative,
      inputs_used: inputs,
      note: 'RIIV spectrum undefined',
    );
  }
  final pk = ls.peakFreq(respLoHz, respHiHz);
  if (pk == null || pk >= respHiHz) {
    return const Metric<RespEstimate>.absent(
      tier: Tier.relative,
      inputs_used: inputs,
      note: 'no respiratory-band peak (or aliased at Nyquist)',
    );
  }
  final brpm = pk * 60.0;
  final pwr = _powerAt(ls, pk);
  // RIIV from 1 Hz green is MED/relative at best — never high confidence.
  final conf = clamp(0.6 * validFraction, 0.15, 0.6);
  return Metric<RespEstimate>(
    value: RespEstimate(brpm, pk, pwr, 'riiv'),
    confidence: conf,
    tier: Tier.relative,
    inputs_used: inputs,
    note: 'RIIV band-pass (0.1–0.5 Hz) on 1 Hz green ADC; coarse intensity '
        'proxy (not 419 Hz waveform); 1 Hz Nyquist caps rate at 30 br/min',
  );
}

/// Fused respiratory rate result with the Karlen SD-gate decision.
class FusedResp {
  final double? brpm; // fused breaths/min (null if gated out / nothing)
  final double? rsaBrpm;
  final double? riivBrpm;
  final bool agreed; // passed the Karlen SD-gate
  final String decision; // 'fused' | 'rsa_only' | 'riiv_only' | 'disagree' | 'none'
  const FusedResp({
    required this.brpm,
    required this.rsaBrpm,
    required this.riivBrpm,
    required this.agreed,
    required this.decision,
  });
  Map<String, dynamic> toJson() => {
        'brpm': brpm == null ? null : round6(brpm!),
        if (rsaBrpm != null) 'rsa_brpm': round6(rsaBrpm!),
        if (riivBrpm != null) 'riiv_brpm': round6(riivBrpm!),
        'agreed': agreed,
        'decision': decision,
      };
}

/// Karlen 2013 Smart-Fusion SD-gate on RSA + RIIV.
///
/// If both estimates are present, fuse only when they agree within [sdGateBrpm]
/// br/min (Karlen discards the window otherwise — we down-rank to RSA-only since
/// RSA is the validated primary). With only one present, pass it through at its
/// own confidence. Inverse-variance weighting uses each estimate's confidence
/// (higher confidence => lower variance).
Metric<FusedResp> fuseRespRate(
  Metric<RespEstimate> rsa,
  Metric<RespEstimate> riiv, {
  double sdGateBrpm = 5.0,
}) {
  final inputs = <String>[...rsa.inputs_used, ...riiv.inputs_used];
  final rsaV = rsa.value?.brpm;
  final riivV = riiv.value?.brpm;

  if (rsaV == null && riivV == null) {
    return Metric<FusedResp>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'neither RSA nor RIIV resolved a respiratory rate',
    );
  }
  if (rsaV != null && riivV == null) {
    return Metric<FusedResp>(
      value: FusedResp(
        brpm: rsaV,
        rsaBrpm: rsaV,
        riivBrpm: null,
        agreed: false,
        decision: 'rsa_only',
      ),
      confidence: rsa.confidence,
      tier: Tier.high,
      inputs_used: inputs,
      note: 'RSA-only (RIIV absent)',
    );
  }
  if (rsaV == null && riivV != null) {
    return Metric<FusedResp>(
      value: FusedResp(
        brpm: riivV,
        rsaBrpm: null,
        riivBrpm: riivV,
        agreed: false,
        decision: 'riiv_only',
      ),
      confidence: riiv.confidence,
      tier: Tier.relative,
      inputs_used: inputs,
      note: 'RIIV-only (RSA absent) — relative/MED tier',
    );
  }

  // Both present: Karlen SD-gate.
  final disagree = (rsaV! - riivV!).abs();
  if (disagree > sdGateBrpm) {
    // Karlen discards the window. We keep the validated primary (RSA) but flag
    // the disagreement and lower confidence rather than emit a fused number we
    // don't trust.
    return Metric<FusedResp>(
      value: FusedResp(
        brpm: rsaV,
        rsaBrpm: rsaV,
        riivBrpm: riivV,
        agreed: false,
        decision: 'disagree',
      ),
      confidence: rsa.confidence * 0.6,
      tier: Tier.high,
      inputs_used: inputs,
      note: 'Karlen SD-gate: RSA/RIIV disagree by ${round6(disagree)} br/min '
          '> ${sdGateBrpm}; fell back to RSA, lowered confidence',
    );
  }
  // Agree => inverse-variance fuse (confidence -> variance).
  final fused = inverseVarianceFuse([
    FusionInput(rsaV, _confToVar(rsa.confidence), label: 'rsa'),
    FusionInput(riivV, _confToVar(riiv.confidence), label: 'riiv'),
  ]);
  final brpm = fused.value ?? rsaV;
  // Agreement boosts confidence above either alone (independent corroboration).
  final conf = clamp(
    math.max(rsa.confidence, riiv.confidence) + 0.1,
    0.2,
    0.95,
  );
  return Metric<FusedResp>(
    value: FusedResp(
      brpm: brpm,
      rsaBrpm: rsaV,
      riivBrpm: riivV,
      agreed: true,
      decision: 'fused',
    ),
    confidence: conf,
    tier: Tier.high,
    inputs_used: inputs,
    note: 'Karlen SD-gate passed (Δ ${round6(disagree)} br/min); '
        'inverse-variance fused RSA+RIIV',
  );
}

/// Map a 0..1 confidence to a positive variance for inverse-variance fusion.
/// Higher confidence => lower variance. Floored so confidence 0 stays finite.
double _confToVar(double conf) {
  final c = clamp(conf, 0.05, 1.0);
  return 1.0 / (c * c);
}

/// Power at (or nearest to) a given frequency in a Lomb-Scargle spectrum.
double _powerAt(LombScargle ls, double fHz) {
  double best = 0;
  double bestDist = double.infinity;
  for (final pt in ls.spectrum) {
    final d = (pt.freqHz - fHz).abs();
    if (d < bestDist) {
      bestDist = d;
      best = pt.psd;
    }
  }
  return best;
}
