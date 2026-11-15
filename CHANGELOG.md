# Changelog

## Unreleased

### Added
- `stageMinuteRanges`: a [lo, hi] range of minutes per sleep stage (wake,
  light, deep, REM, and NREM = light + deep). `lo` counts epochs that can only
  be that stage: HR-covered, labelled so, and every deciding score at least
  `kStageScoreMargin` (0.1) from its cutoff. `hi` adds epochs that could still
  be that stage: uncovered or unlabelled epochs (any stage), and epochs with a
  score inside the margin (REM score: REM and its NREM substage; deep score:
  light and deep). An honest bound, not a confidence interval: the stager has
  no per-epoch probabilities. Null for no epochs.
- `CardioStagerResult.epochEvidence` (with `StageEpochEvidence`): per final
  epoch, the label, deep flag, HR coverage and the REM/deep scores the classify
  loop computed. `CardioStagerResult` carries `remScores`, `deepScores` and
  `hrCovered` for it. Stage labels are unchanged.
- `irregularBeatScreenDetailed` and `IrregularScreenState.evaluateDetailed`: the
  irregular-rhythm screen's verdict plus its evidence (`IrregularDiagnostics`) —
  beats in / kept after the [300, 2000] ms filter, the corrector's raw /
  corrected / dropped counts (passed in as `RrCleaningCounts`), artifact
  fraction, window counts (total, voting, flagged, the final OPEN window and
  what became of it, sustained share seen vs required) and the thresholds — for
  a screen that ran and for one that abstained (with the reason). Detailed
  diagnostics preserve the wrapper's result for the same screen calculation.
  `IrregularScreenState` checkpoints are version 3, carrying diagnostic counters
  and the previous kept beat's time. Versions 1 and 2, and incomplete version 3
  states, are refused. A NaN beat no longer makes the checkpoint unencodable.
  `IrregularDiagnostics.artifactFraction` is null (absent) when the corrector was
  handed no beats: a share of nothing has no value, and the `1 - cleanFraction`
  of an empty series (1.0) must not read as "every beat is an artifact".
  Output change: timestamp-gap pairs no longer contribute successive differences,
  so Poincaré statistics, pNNx, window votes and screen verdicts can change.
- Incremental states for centered moments, fixed-grid Lomb–Scargle, time-domain
  HRV, motion with a measured gravity reference, and keyed minute TRIMP/energy.
  Appends reuse retained contributions; edits, removals and changed dependencies
  update or rebuild them. Batch APIs remain available. `phillipsSri` uses
  `sriAggregator` for normal inputs, retaining the legacy short-validity-mask
  path; `AdvancedSleepStager.computeMetrics` uses `HypnogramAggregator`.
  The batch functions listed under Changed also run their aggregators. Other
  batch implementations remain separate, sometimes sharing kernels/scoring
  helpers with incremental forms.
- Bounded dependency-aware `CalculationCache` and explicit `CalculationMode`.
  Only `periodicAwake` permits reuse. Sleep, heavy and forced runs use full math.
- Minute summary mode avoids constructing per-minute energy records when only
  totals are needed. See `docs/INCREMENTAL_USAGE.md` for contracts and limitations.
- Parameterized incremental parity tests, checked-in capture fixtures, checkpoint
  tests, work counters and a deterministic timing comparison tool.
- `hrDipFromDayTotals`: `hrDip` from the day side's running count and sum, for
  callers that keep the waking day as totals. `hrDip` shares its scoring, so
  both give the same result for the same samples.
- `IncrementalMinuteMetrics.sync` takes `dayMinutes` as an `int`, as
  `Calories.dailyEnergy` does; a fractional day can no longer be passed.
- Long-run drift tests: 30 000 Lomb–Scargle appends and 100 000-step sliding
  moments stay within 1e-9 of the batch results.
- `IntHistogram`: exact, mergeable order statistics for integer-valued series
  (heart rate), kept as a sorted `value -> count` list. `percentile` and `median`
  return the same doubles as `percentileSorted` on the expanded sorted list,
  and null when empty. Not wired into any caller yet; see
  `docs/INCREMENTAL_USAGE.md` for which batch callers could adopt it.
- Pinned Nix devshell with Flutter 3.41.6 / Dart 3.11.4 and native build tooling.
- `Calories.minuteEnergy` — per-minute energy (basal, active, walking, total,
  and an abstention reason) from the same computation `Calories.dailyEnergy`
  does. A minute with no usable HR and no billable cadence abstains: all values
  null, `abstained: MinuteEnergyAbstain.noHr`. Nothing is filled or interpolated.
  `MinuteEnergySeries.active` / `.walking` are `==` `dailyEnergy`'s, and
  `basalKcalPerMin * dayMinutes` is its `basal`.
- `Calories.hourlyRollup` — hourly sums of covered minutes with per-hour
  coverage; an hour with no covered minute is null, not zero.

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
RSA and CVHR use the same regressing-clock refusal. Frequency HRV leaves out
beats behind a re-anchored clock when they are at most 5% of the record and at
least 16 beats remain; larger regressions still abstain. Time HRV
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
### Changed
- `IncrementalHrvTime` applies the batch refusal for regressing or mismatched
  supplied clocks before updating its retained summary.
- CTL/ATL aggregator checkpoints retain total and finite day counts. Older
  checkpoints without validity evidence are refused so unknown load cannot be
  silently restored as observed history.
- **Output change (combined bump; edge must bump kAlgoVersion when pinning
  this): capped RR artifact runs become gaps; downstream metrics may change.**
  `correctRr(maxArtifactRun:)` and `RrCorrector(maxArtifactRun:)` (default
  `kMaxArtifactRun` = 32; null = uncapped) split over-cap runs and re-correct
  each side. Without a cap split the result equals uncapped correction.
  Staging retains upstream main's session-onset 30 s grid, shared night
  baselines across usable runs, per-run HR coverage gate and gap-bounded
  continuity, except for separately documented RR or spectral changes.
  `AdvancedSleepStager` keeps that batch path, with dependency-checked row
  caching; it does not stage through `EpochRows`.
  RSA streams and research accumulators retain upstream's lower-band floor
  guard and include floor-pinned votes in consensus. `RsaRespStream`
  checkpoints are version 3; versions 1 and 2 are refused because settled
  peaks in those versions had no floor guard. After an accelerometer gap
  exceeding the 60 s carry-forward limit, the next usable run re-anchors at
  its first sample, as before. `EpochRows` accumulates these feature rows;
  `EpochRowsMemo` caches rows by grid phase and recomputes an unavailable phase.
  `RrSandwich` / `RawRr` / `NnColumn` feed capped corrected NN into aggregators,
  retaining source-beat absolute timestamps via `nnSourceIndex`.
  Registry counters `found.rr_correction` and `sleep.stage` remain at 2.
- **Output change: aggregator adoption (7483030).** `hrvTime`, `banisterTrimp`,
  `ctlAtlTsb`, `cosinor`, `HeartRateZones.timeInZone` and
  `circadianNonparametric` now return their aggregators' one-slice run.
  Ordinary finite-input outputs move only in the last digits within tested
  tolerances: HRV fields 1e-9 absolute plus 1e-9 relative; TRIMP 1e-12 relative;
  CTL/ATL/TSB 1e-9 absolute and relative; zone seconds 1e-9 absolute / 1e-12
  relative; circadian indices 1e-12 relative on integer fixtures and 1e-9 on
  real fixtures. Circadian near-ties can select different L5/M10 start epochs.
  Cosinor mesor/amplitude use 1e-9 relative, with a near-zero amplitude floor
  of 1e-12 * max(1, |mesor|); near-zero mesor has a 1e-12 data-scale floor.
  Circular phase error uses 1e-9 * max(1, |phaseRad|) in radians and
  1e-9 * periodHours in hours; phase is not compared for rounding-noise
  amplitudes. The aggregator also preserves upstream's zero-amplitude F-test,
  null acrophase when p ≥ 0.05, and confidence from adjusted R².
  R², adjusted R² and confidence use 1e-7 absolute. These are checked
  parity tolerances, not universal bounds.
  SDANN/SDNN-index pins moved to 1e-9 relative.
- **Output change: near-singular cosinor designs.** The relative determinant
  test replaces the old batch solver's absolute 1e-12 pivot test. Insufficient
  phase coverage returns a null-valued `Metric` with the singular-design note;
  the two tests can disagree about whether a fit is identifiable.
- Registry counters `found.core`, `hrv.freq`, `night.rhythm` and `activity.load`
  go to 2 for the spectral origin, HRV, rhythm and load changes. Dependent
  groups re-derive through `deps`; see `docs/COMBINED_BUMP_STATUS.md`.
- `IrregularScreenState` checkpoints are version 3: they carry the previous kept
  beat's time, because a pair across a time hole is no longer successive.
  Versions 1 and 2, and a version 3 checkpoint without `prevT`, are refused.
- `IncrementalHrvTime` follows `hrvTime`'s jitter gate under the ACF floor
  (respiratory-line exemption, breathing-line fallback): when either could
  apply it hands the night to the batch, so the incremental output equals
  `hrvTime` where it used to refuse RMSSD. Checkpoint format unchanged.
- `hrvTimeAggregator` follows `hrvTime`'s jitter gate under the ACF floor
  (respiratory-line exemption, breathing-line fallback) from mergeable
  evidence (O(5-min windows), never the beats). Its checkpoint state is now
  `[core, evidence]`; a checkpoint without the evidence is refused whole.
- Output change for invalid timestamps: `hrvTime`, `nocturnalRmssd`,
  `sleepSessionRmssdDetail`, `rsaRespRate` and `cvhrApneaScreen` return absent
  metrics for non-finite beat times. Streaming folds refuse invalid times
  before mutation; snapshots with invalid provisional times abstain.
  Finite-input formulas are unchanged by these guards.
- **Output change: all `lombScargle` callers can move; edge must bump
  kAlgoVersion when pinning this.** Time is now measured from the first sample.
  The old error reached approximately 5e-6 relative per frequency; integrated
  metric changes depend on the input and were approximately 1e-14 on the
  checked night. Threshold decisions can therefore change. Callers include
  `hrvFreq`, `cardiacCoherence`, respiration RSA/peak rate and the cardio
  stager's LF/HF. `IncrementalLombScargle` already used first-sample time and
  is unchanged; it now agrees with batch on epoch seconds within 1e-9 in the
  precision test, which saw 9e-6 before the change.

### Unchanged
- `Calories.dailyEnergy` outputs are bit-for-bit identical. Its loop body moved
  into a helper shared with `minuteEnergy`; golden tests in
  `test/onehz/minute_energy_test.dart` pin the pre-change values with `==`.
  No `kAlgoVersion` bump is needed for this change.
