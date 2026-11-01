# Changelog

## Split #99 output changes

Edge must bump `kAlgoVersion` when adopting these changed batch outputs.

### Leave long RR artifact runs as gaps

The 32-beat cap is an internal ESTIMATE rule with low confidence, not a published threshold. Longer runs split the series; each side is corrected independently. The synthetic 33-beat case keeps 200 NN beats and drops 33.

Method: Lipponen & Tarvainen 2019; Peltola 2012. Reproduce with `dart run tool/reproduce_outputs.dart`.

### Reduce spectral error on epoch timestamps

Evaluate trigonometric arguments relative to the first sample. The mathematical spectrum is time-shift invariant; floating-point band powers and threshold decisions can change for all Lomb-Scargle callers.

Method: Lomb 1976; Scargle 1982; Press & Rybicki 1989. Reproduce with `dart run tool/reproduce_outputs.dart`.

