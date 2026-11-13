# Reproducing the #99 batch output changes

This branch replaces the batch-output portion of #99. The aggregator branch stacks
on this branch. Edge must bump `kAlgoVersion` when adopting these changed outputs.

Run `dart pub get` with network access on a fresh clone, then
`dart run tool/reproduce_outputs.dart`. Once dependencies are cached,
`dart pub get --offline` also works.
`--json` prints unrounded machine-readable results. The script calls batch APIs
only. Its input recipes are in `test/fixtures/output_changes.json`, a small
synthetic fixture. It contains no personal measurements. Formula parameters
expand to beat sequences in memory, including 20,000 nearly collinear cosinor
samples. The fixture's `old` and `new` values are recorded observations, not
values substituted into library results.

Old values were measured on `3a7ca34`, new values on `f8e7d3c` with #98 merged.
The output branch reproduces the new values. Each output commit pins its own
unrounded result. Tests contain no NaN list-equality expectations.

| Calculation | up/main `3a7ca34` | Split output branch |
|---|---|---|
| RR kept / dropped / corrected | `[199, 34, 0]` | `[200, 33, 0]` |
| Lomb-Scargle PSD at 0.137 Hz | `32627.260306094682` | `32627.260527635714` |
| Cosinor mesor / amplitude / R² / p | `[60.20591440999805, 1.9937577719142656, 0.9902626829318173, 2.900200339561918e-94]` | `[60.205914409998044, 1.9937577719142632, 0.9902626829318162, 2.9002003395774255e-94]` |
| Near-singular cosinor present | `True` | `False` |
| HRV RMSSD / SDNN / SDANN / SDNN index / ACF1 | `[3.615265234174367, 21.52663924532639, 1.067383333873884, 21.55214616158443, 0.9849552962327551]` | `[3.615265234174367, 21.52663924532641, 1.0673833338741983, 21.55214616158443, 0.984955296232754]` |
| HRV with infinite final timestamp present | `throws` | `False` |
| Banister TRIMP | `32.71197112260296` | `32.711971122602975` |
| CTL / ATL / TSB | `[98.49620732954641, 103.12182624417179, -4.625618914625377]` | `[98.49620732954642, 103.12182624417177, -4.625618914625349]` |
| Zone seconds, zones 1 through 5 | `[0.0, 120.01199999999982, 0.0, 0.0, 0.0]` | `[0.0, 120.01199999999977, 0.0, 0.0, 0.0]` |
| Circadian IS / IV / M10 / L5 / start epochs | `[1.0, 0.331267605633807, 3.505000000000011, 1.3600000000000079, 14, 0]` | `[1.0, 0.3312676056338072, 3.505000000000011, 1.3600000000000079, 14, 0]` |
| Gap-aware batch irregular SD1 / pNN70 | `[22.360679774997894, 83.33333333333333]` | `[22.360679774997894, 83.33333333333333]` |

The synthetic RR run contains 100 normal 900 ms beats, 33 artifacts at 250 ms,
and 100 normal beats. The over-cap run becomes a gap. At 32 artifacts or fewer,
the capped and uncapped results agree. The cap is an internal ESTIMATE policy,
not a published physiological threshold.

The cosinor phase columns in the near-singular case cover only about 20
microhours around hour 3. Main accepts this numerically unidentifiable design;
the relative determinant gate abstains. The threshold is a numerical policy.
Nelson's significance test and nullable acrophase from #101 remain intact.

The invalid-timestamp table uses HRV because main throws promptly. The focused
guard test also calls frequency HRV, RSA, CVHR, nocturnal RMSSD and session
RMSSD with NaN and both infinities. Running old frequency HRV/RSA with an infinite
last time is unsafe because its segment walk may never terminate. The script
does not call those old endless paths.

Main already excludes timestamp gaps in the batch irregular-rhythm screen.
The unchanged row above is a control. #99 adds the corresponding stream policy,
previous-beat timestamp checkpointing and old-checkpoint refusal in the
aggregator branch. Diagnostics and their tests also stay there.

Main and the rebased #99 head use the same circular profile sums and strict
first-winner comparisons for batch L5/M10. Their starts agree here and on the
near-tie controls. Centered variance changes IS/IV last digits. Chunked merges
can reorder profile sums, so near-tie starts may move in the aggregator branch.
The original #99 description's broad near-tie warning should be read in that
context. These checked fixtures and tolerances are not universal error bounds.

To independently recompute the old column, create a detached worktree at
`3a7ca34`, copy `tool/reproduce_outputs.dart` and
`test/fixtures/output_changes.json` into the same paths there, run
`dart pub get --offline`, then run the tool with `--json`. The table printer
labels its recorded baseline separately from the currently computed result.

Methods and limits are beside the code and in `ALGORITHMS.md`: Lipponen &
Tarvainen 2019 and Peltola 2012 for RR correction; Lomb 1976, Scargle 1982 and
Press & Rybicki 1989 for spectra; Nelson et al. 1979 for cosinor; Task Force
1996 and Welford 1962 for HRV moments; Morton, Fitz-Clarke & Banister 1990 and
Banister et al. 1975 for training load; Neumaier 1974 for compensated sums;
Witting 1990 and van Someren 1999 for circadian indices. Karvonen 1957 supports
reserve zones only. Gap credit, tail credit and the RR cap remain internal rules.

`--corpus-json` expands twelve deterministic cases, varying RR run lengths,
spectral origins and frequencies, jitter frequencies, timestamp gaps and record
lengths. `test/fixtures/output_batch_parity.json` freezes the output branch's
unrounded public results before the aggregator conversion. Both branches run
`batch_parity_test.dart` against these fixed results. All twelve cases also
matched the rebased #99 head exactly in the split audit. This supplements the
existing law tests and frozen pre-#99 references; it does not establish parity
for every possible input. Both reproduction fixtures together are about 10 KB.
