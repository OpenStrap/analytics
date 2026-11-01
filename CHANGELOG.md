# Changelog

## Split #99 output changes

Edge must bump `kAlgoVersion` when adopting these changed batch outputs.

### Leave long RR artifact runs as gaps

The 32-beat cap is an internal ESTIMATE rule with low confidence, not a published threshold. Longer runs split the series; each side is corrected independently. The synthetic 33-beat case keeps 200 NN beats and drops 33.

Method: Lipponen & Tarvainen 2019; Peltola 2012. Reproduce with `dart run tool/reproduce_outputs.dart`.

### Reduce spectral error on epoch timestamps

Evaluate trigonometric arguments relative to the first sample. The mathematical spectrum is time-shift invariant; floating-point band powers and threshold decisions can change for all Lomb-Scargle callers.

Method: Lomb 1976; Scargle 1982; Press & Rybicki 1989. Reproduce with `dart run tool/reproduce_outputs.dart`.

### Abstain when a beat has no finite time

HRV frequency/time, nocturnal and session RMSSD, RSA and CVHR return absent metrics for non-finite beat times. This prevents endless segment walks and invalid integer conversions. Finite-input formulas are unchanged.

Method: Task Force 1996 HRV; Welch 1967 spectra; input-validity guard is an implementation rule. Reproduce with `dart run tool/reproduce_outputs.dart`.

### Refuse unidentifiable cosinor fits

Use centered least squares and a relative determinant gate of 1e-12 of the diagonal product. This is a numerical policy. Nearly collinear phase columns abstain, and ordinary fit parameters can move in their last digits. Upstream zero-amplitude significance gating is retained.

Method: Nelson et al. 1979, Methods for cosinor-rhythmometry; Welford 1962 centered co-moments. Reproduce with `dart run tool/reproduce_outputs.dart`.

### Retain small TRIMP contributions in the total

Compensate the per-minute sum. The reserve and sex-specific weighting are unchanged; the synthetic total moves in its last digits.

Method: Morton, Fitz-Clarke & Banister 1990; Neumaier 1974 compensated summation. Reproduce with `dart run tool/reproduce_outputs.dart`.

