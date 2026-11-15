# Incremental calculations

Import `package:openstrap_analytics/onehz.dart`. The batch functions remain
available and are the reference algorithms used by the tests.

| State | Cached math | Rebuild conditions |
|---|---|---|
| `RunningMoments` | Centered count, mean and sum of squared deviations; add, remove and merge | Caller owns membership when removing a value |
| `IntHistogram` | Sorted `value -> count` list of an integer-valued series; add, remove and merge | Caller owns membership when removing a value; whole numbers only |
| `IncrementalLombScargle` | Seven trigonometric sums per frequency, centered moments and time span | Earlier point edits, removals, a changed origin, or `force: true` |
| `IncrementalHrvTime` | NN moments, contiguous differences, lag-one products and five-minute bins | Earlier beat/time edits, removals, timing-mode changes, or force |
| `IncrementalEnmoSeries` | Trailing gravity sums and motion-minute buckets | Earlier sample edits, parameter changes, automatic gravity calibration, or force |
| `IncrementalMinuteMetrics` | TRIMP and energy contributions indexed by minute key | Changed minutes are repriced; changed HR anchors, sex or profile reprice all minutes |
| `CalculationCache` | Results with complete, owned dependency snapshots | Changed dependencies, explicit full evaluation, or eviction |

`IntHistogram.percentile(p)` and `.median` return exactly what
`percentileSorted` returns for the expanded sorted list (same interpolation
between the two neighbouring order statistics, found from cumulative counts),
and null when empty. `add` takes a whole number (`70` or `70.0`; anything else
throws), `remove` throws if the value is absent, and `p` outside 0 to 100
throws. Use it only for integral data: heart rate is whole bpm with about 45
distinct values in a real night, but accelerometer magnitudes are almost all
distinct (30,848 of 32,041), so a histogram there is as long as the data. If
`calibrateGRef` ever needs to be incremental, use an order-statistic structure.

Batch callers that take a median or percentile of heart rate over a long or
sliding window, and what adopting it would need:

| Caller | Window | Notes |
|---|---|---|
| `_rollingMedianValidOnly` (`sleep/hr_fallback.dart`) | Centered, per sample | Best fit: a sliding add/remove. Input is `List<double>`, so adopt only where the source is whole bpm. |
| `StrainScorer.estimateHRmax` (`clinical/load_trimp.dart`) | Trailing HR history | A high percentile of a long history; a running histogram avoids the re-sort per call. |
| `nocturnalRhr` p1 (`clinical/nocturnal.dart`) | The night's on-skin HR | One percentile per call, rebuilt each time. |
| `causal_stager` / `cardio_stager` local gates | ±180 epochs, p25 and p50 | Epoch HR is a mean, not a whole number. Not eligible unless the epoch value is made integral, which would change output. |
| `hrBaseline` (`sleep/advanced_stager.dart`) | Whole record | Median of all HR samples; a single call. |

No existing incremental state recomputes an HR median per pass, so none was
switched; the histogram has no caller in the app yet.

Pass the complete current input to `sync`. Each state checks that retained data
still matches, so replacing an old timestamp or value cannot silently leave a
stale result. Input comparison and output construction still visit retained
data. The work counters count samples whose math was evaluated, not every
array read or allocation.

Minute keys must be unique and aligned with HR and optional cadence. Day duration
must be a finite whole number of minutes, matching `Calories.dailyEnergy`.
Changing day duration or the quiet-waking strain reference changes the summary
without repricing minute contributions.

Use `includeMinuteSeries: false` when a caller needs only TRIMP, strain and
energy totals. It avoids rebuilding the minute output list. Turning that view
back on exposes the same retained contributions without repricing them.

ENMO with an automatic gravity reference uses the full `enmoSeries` algorithm.
That reference comes from the whole record's median and can change earlier
minutes. Pass an explicit measured reference to use the incremental gravity
queue. The RR corrector also remains a full calculation because new beats can
change which earlier beats survive correction.

HRV preserves time gaps, partially filled five-minute bins, the beat-timing
jitter refusal, confidence and notes. Ill-conditioned autocorrelation sums and
values near the refusal threshold fall back to the batch calculation.

State checkpoints use `toJson` / `fromJson`, with version and type checks.
They retain double precision before public metric formatting. An unsupported
or malformed checkpoint throws; discard it and perform a full rebuild.

Cache dependencies should be JSON-compatible maps, lists and scalars. Cached
results should be immutable objects or JSON-compatible collections. The cache
owns copies of collection results and dependencies and evicts the least
recently used entries at its configured limit.

`CalculationMode.periodicAwake` is the only mode that permits reuse. Sleep,
heavy and forced runs must evaluate the full algorithms. The app owns awake
evidence, phone charging state and when a successfully persisted result may
replace its previous cache. These are orchestration decisions, so the math
package has no clock, battery API or database dependency.

Run the deterministic timing comparison with:

```sh
nix develop -c dart run tool/incremental_benchmark.dart
```

The benchmark reports local elapsed times and math-work counts. The parameterized
tests compare values, absent results, confidence, notes and provenance against
the batch algorithms after appends, revisions, deletions and checkpoint restores.
They also read subsets of the checked-in July 2026 overnight capture. Missing
capture files fail these tests rather than skipping them.
