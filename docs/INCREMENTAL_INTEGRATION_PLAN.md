# Incremental calculations: integration plan

Hand-off for getting the incremental work into the app (`edge`). Read
[INCREMENTAL_MATH.md](INCREMENTAL_MATH.md) for the derivations and
[INCREMENTAL_USAGE.md](INCREMENTAL_USAGE.md) for the API.

## Where the work is

| Repo | Branch | Location | State |
|---|---|---|---|
| analytics | `feat/minute-energy` | this checkout | `4bd76f7` committed; later changes below uncommitted |
| edge | `feat/incremental-analytics` | `../edge.worktrees/incremental-analytics` (git worktree of `../edge`) | all incremental work uncommitted on top of `687b5bd0` |

`687b5bd0` is a snapshot of the scheduler work that was uncommitted in
`../edge` when this started. That work has since been committed there as
`561f2838` on `ecg-taps-one-clock` (about 100 lines differ), and that branch
has moved on to `f88d230c`. `../edge` itself also has uncommitted perf tests
(`test/perf/p3_*`). Leave that checkout alone.

The edge worktree builds against this checkout through a gitignored
`pubspec_overrides.yaml`. `pubspec.lock` is modified only by that override:
never commit it.

Run everything through the devshell in this repo:

```sh
nix develop /path/to/openstrap-analytics -c flutter test   # in the edge worktree
nix develop -c dart test                                    # here
```

Run edge tests with `TZ=UTC`. The two-device golden fails under any other
offset.

## What is in place

Every incremental result is tested against the existing batch function as
its oracle. In this repo, exact paths must agree within a relative error of
1e-8 (`test/onehz/support/incremental_compare.dart`). In edge, the helper is
`test/support/incremental_compare.dart`: `kExactRelTol = 1e-9` for exact
reuse, and `kApproxRelTol = 0.02` reserved for a future method that is
approximate by design. No such method exists yet.

**Used by the app**

- `CalculationCache`, through `DayCalculationState.evaluate`. It holds the
  finished night's results (about 25 entries) and the completed windows of
  the rolling HRV and breathing-rate curves. These all hit on every periodic
  awake pass.
- `IncrementalMinuteMetrics`: TRIMP, strain, and daily calories, with each
  minute priced once.
- `IncrementalEnmoSeries`: motion minutes. Full passes calibrate the gravity
  reference exactly as `enmoSeries` does. Awake passes keep that reference.
  Every field the app reads is still the batch value; only
  `MotionMinute.enmo` uses the kept reference, and nothing in edge reads it.
- Edge-side running summaries (`lib/compute/day_activity_state.dart`): wake
  active minutes, the activity curve, wear runs, per-minute wake HR, the
  day's HR stats (smoothed max/min, mean), and the day side of HR dip
  (`hrDipFromDayTotals` here). Each one adds in sample order, so it is
  bit-identical to the batch reader it replaces.
- Mode selection: `PeriodicCalculationPolicy` allows reuse only while the
  phone is unplugged and the causal stager reports fresh, confident `wake`.
  Sleep, heavy, forced, charging and missing or stale evidence all run in
  full.

Benchmark (`INCREMENTAL_BENCH=1 flutter test test/incremental_cache_benchmark_test.dart`,
16 h awake day plus an 8 h night, six 5-minute appends): 86.2 s recomputing
everything against 2.2 s with reuse. A full pass is also no slower than
before the work: about 350 ms compute per derive in
`sleep_override_blanks_night_test`, against 445 ms at baseline.

**Implemented here, not used by the app**

| Incremental | Why it is unused | Where it would pay |
|---|---|---|
| `IncrementalLombScargle` | Its callers (`hrvFreq`, `cardiacCoherence`) run on the finished night or on short sessions; the night is cached whole. | A live coherence/breathing session that recomputes its spectrum as beats arrive. |
| `IntHistogram` | No existing incremental state recomputes an HR median per pass. | A rolling or trailing HR median/percentile over a long window (see the caller table in INCREMENTAL_USAGE.md). |
| `RunningMoments` | No caller recomputes a long mean/SD per pass. Night SDNN is cached whole. | Rolling windows over the awake day (daytime HRV, rolling HR variability) or baselines kept as running state. |
| `IncrementalHrvTime` | Removed from the app: the night's beats do not change while awake, so the cached result already covers it. | Daytime HRV (`_daytimeHrv`) if it becomes expensive. |

## Steps

1. **Land this repo's changes.** Uncommitted:
   - `hrDipFromDayTotals`, which `hrDip` now shares its scoring with
   - `IncrementalMinuteMetrics.sync` taking `int dayMinutes` (as
     `Calories.dailyEnergy` does)
   - day-duration tests
   - `drift_test.dart`
   - `IntHistogram`
   - the first-sample time shift in `lombScargle` and its precision test
   - this plan

   Commit them, open a PR, and note the new commit SHA. The incremental work
   changes no algorithm output, but the `lombScargle` shift does (about 1e-6
   relative, worst case), so edge must bump `kAlgoVersion` when it pins a commit
   that contains it.

2. **Move the edge work onto the current edge branch.** Commit the worktree's
   changes on `feat/incremental-analytics`, then rebase onto
   `ecg-taps-one-clock`, dropping `687b5bd0` (its content is already in
   `561f2838`). Expect conflicts in:
   - `lib/compute/derivation_engine.dart`: `run()` gained
     `calculationMode`, `_derivePreparedDay` now publishes state after
     persistence, and the activity helpers were changed.
   - `lib/state/app_state.dart`: `_deriveRun` asks the policy before each
     light pass. `f88d230c` changed about 230 lines here.
   - `lib/compute/onehz_pipeline.dart`: memoized night components and the HR
     summary.

   Keep both sides' behaviour. Keep `changedOnly` from forcing a full mode:
   the automatic light pass uses `changedOnly`, so mapping it to `forced`
   silently disables all reuse. `test/incremental_engine_run_test.dart`
   covers this path end to end.

3. **Pin the analytics dependency.** Replace the local override with the new
   analytics SHA in `pubspec.yaml`, run `flutter pub get`, and update the SHA
   that `db_serve_version_and_reads_test.dart` checks. That test already
   fails on this branch because the pins and `kAlgoVersion` disagree.

4. **Verify.** In edge, the incremental tests are
   `test/incremental_*_test.dart`, 8 files including the opt-in benchmark.
   Then run the full suite with `TZ=UTC`. Known failures that also fail
   without this work:
   - `db_serve_version_and_reads_test` (pins)
   - three Today-tab tests in `health/health_h2_tabs_test.dart`
   - `setUpAll` of the four proof-view tests
     (`proof/affected_views`, `proof/chart_key_views`, `proof/phase8_views`,
     `sources/proof_views`)
   - the two-device golden comparison

   `sleep_blank_review_test` and `sleep_override_blanks_night_test` can hit
   the 30 s timeout under full-suite load. They pass alone.

5. **Device check.** On a phone, during the day and unplugged, the derive log
   should show light passes with low compute times. Plugged in, or overnight,
   should show full passes. `DerivationEngine.debugCalculationState(day)`
   exposes hits and work counters.

## Follow-ups

- **Medians from compacted histograms (done).** `IntHistogram` is an exact
  `value -> count` summary with `percentile` and `median` bit-identical to
  `percentileSorted` on the expanded list, tested against the real-night HR and
  randomized data. HR has about 45 distinct values in a real night
  (`test/onehz/fixtures/real_night_2026_07_onehz.csv`). No existing incremental
  state recomputed an HR median per pass, so nothing was switched; candidate
  callers are listed in INCREMENTAL_USAGE.md. The largest medians in a day are
  the two inside `calibrateGRef`, over every valid accelerometer magnitude
  (up to 86,400 values, 30,848 distinct of 32,041 in the same capture), so a
  histogram does not help there. Those are off the awake path because the
  reference is kept. If they ever need to be incremental, use an
  order-statistic structure, not a histogram.
- **Observed max HR (pending, edge-side).** The all-time ceiling is already a
  cached comparison: `LocalDb.observedHrCeiling` takes the max over one stored
  value per day. The per-day value comes from `sessionHrCeiling` over each
  session's samples. A finished session's ceiling never changes, so cache it
  per session and sample revision. Only an open session needs its hold-window
  state carried forward.
- **Batch Lomb–Scargle precision (done here; edge must bump `kAlgoVersion`).**
  `lombScargle` now shifts times by the first sample. On raw epoch seconds the
  trig arguments reached about 1e10 radians and the periodogram was off by up
  to 4.6e-6 relative against an 80-bit reference. This changes `hrvFreq`,
  `cardiacCoherence`, the respiration RSA rate and the cardio stager's LF/HF at
  the 1e-6 level worst case, so edge must bump `kAlgoVersion` when it pins this
  commit (and the pin must contain it; see AGENTS.md invariants 4 and 5).
- Remaining batch calculations and their constraints are listed in
  INCREMENTAL_MATH.md. Several (sleep staging, naps, cycles, rank-based
  statistics) cannot be made exactly incremental, because new data revises
  old decisions.
