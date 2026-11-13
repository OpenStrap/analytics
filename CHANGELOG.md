# Changelog

## Split #99 output changes

Edge must bump `kAlgoVersion` when adopting these changed batch outputs.

### Review input and gap validity

HRV time, nocturnal and session RMSSD abstain on non-finite NN intervals before
segmentation. Cosinor rejects non-finite or non-positive periods before computing
its design. CTL/ATL abstains on unknown/non-finite daily load; explicit observed
zero-load rest days still decay. These are input-validity policies, not new
physiological models. Capped RR runs now report `BeatClass.gap`, appended after
existing enum values, rather than claiming every omitted beat is long/short.
HRV also abstains when retained beat times regress, including when RR
accumulation disagrees with the recorded time at a capped-gap reset. Recorded
segment anchors are preserved; timestamps are never shifted to hide the conflict.
Frequency HRV, RSA and CVHR use the same regressing-clock refusal. Time HRV
also refuses supplied clock vectors whose length does not match the NN vector;
NN-only calls remain supported. Cosinor refuses non-finite design/response
moments, including overflow from a positive subnormal period or finite responses.
Other finite-input formulas, corrected NN and cap accounting are unchanged.


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

### Evaluate training-load decay with affine arithmetic

Evaluate the same EWMA recurrence as scale times seed plus offset. This matches the arithmetic used by the later incremental implementation. Last digits change; 42/7-day defaults and bounded-prefix priming remain implementation choices.

Method: Banister et al. 1975; Morton et al. 1990; Neumaier 1974 prefix summation. Reproduce with `dart run tool/reproduce_outputs.dart`.

### Count repeated zone intervals before summing

Group equal duration credits by zone. Cadence validation, median capping and tail credit are retained. Grouped multiplication changes the last digits of zone seconds.

Method: Karvonen 1957 supports reserve zones only; interval credit is an internal ESTIMATE rule. Reproduce with `dart run tool/reproduce_outputs.dart`.

### Compute circadian variance with centered moments

IS and IV may move in their last digits. Batch circular profile sums and first-winner tie selection are unchanged on the rebased head. Chunked merges can reorder profile sums and move near-tie L5/M10 start epochs; that stream-specific behavior belongs with the aggregators.

Method: Witting 1990; van Someren 1999; Welford 1962 centered variance. Reproduce with `dart run tool/reproduce_outputs.dart`.

### Compute HRV moments without subtracting a large mean

Use origin-shifted moments for NN levels and five-minute bins, and centered lag co-moments for ACF. Last digits and decisions within rounding of jitter gates can change. Existing respiratory-line exemptions, coverage gates and absent-value rules remain.

Method: Task Force 1996; Welford 1962 centered sums and products. Reproduce with `dart run tool/reproduce_outputs.dart`.

