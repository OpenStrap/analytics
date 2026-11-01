# Changelog

## Split #99 output changes

Edge must bump `kAlgoVersion` when adopting these changed batch outputs.

### Leave long RR artifact runs as gaps

The 32-beat cap is an internal ESTIMATE rule with low confidence, not a published threshold. Longer runs split the series; each side is corrected independently. The synthetic 33-beat case keeps 200 NN beats and drops 33.

Method: Lipponen & Tarvainen 2019; Peltola 2012. Reproduce with `dart run tool/reproduce_outputs.dart`.

