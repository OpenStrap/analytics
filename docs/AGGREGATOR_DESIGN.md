# Aggregators: mergeable summaries without a rigid monoid

Goal: make it cheap to turn an analytics calculation into something that can
be computed in chunks (checkpoint/resume, segment recompute, parallel work)
and merged, with one generic law check instead of hand-written chunking tests.

## Why not a plain monoid

A textbook monoid on summary values asks for three things that cost speed or
honesty here:

1. Immutable values combined one element at a time. Folding 86,400 samples a
   day through `combine(summary, singleton(x))` allocated per sample: about
   180,000 µs against a 141 µs hand loop
   (edge.research/experiments/dart-monoid/REPORT.md).
2. Structural equality of states. Two states can differ (float rounding
   order, a field `finish` never reads) and still give the same metric.
3. One context-free operation. Several calculations depend on context known
   before any data arrives: session bounds, a bin origin, heart-rate anchors.

## The contract

An `Aggregator<S, B, R>` is a dictionary of four operations over slices of a
column batch `B`:

| op | role |
|---|---|
| `S empty()` | fresh identity state |
| `S addSlice(S s, B batch, int start, int end)` | fold rows `[start, end)`; may mutate `s` and return it |
| `S combine(S left, S right)` | merge two adjacent chunks, `left` first; may mutate and return `left`; consumes both |
| `R finish(S s)` | state to result; must not mutate `s` |

`Batch<B>` is a run of rows stored column-wise (`length`, `copyRange`,
`join`). Missing doubles are NaN, so filtering happens inside tight loops
instead of through per-row closures. `ListBatch<A>` wraps a plain list for
calculations over objects (hypnogram segments); `DoubleColumn` wraps one
`Float64List`. A module defines its own batch when it needs several columns
(`Beats`, `Epochs`, `TimedValues`).

What this relaxes, each one on purpose:

- **Slices, not elements.** The unit of `add` is a slice. Generic dispatch
  then costs once per slice and the per-row work is a plain loop.
- **Mutation and consumption.** `addSlice` and `combine` reuse their inputs.
  The laws are stated on fresh folds, so nothing reuses a consumed state.
- **Equality after `finish`.** Laws compare finished results with a
  caller-supplied equality (exact for integer outputs, a tolerance for
  floats). State layout is free.
- **Order matters.** `combine` joins a chunk with the one that follows it, so
  a state can carry bounded edge context across a seam. No commutativity.
- **Context-indexed instances.** An aggregator may be built from context
  (`HypnogramAggregator(sessionStart, sessionEnd)`,
  `hrvTimeAggregator(originMs: …)`, `banisterTrimpAggregator(restingHr: …)`).
  The laws hold per instance.

## Laws

`checkLaws(agg, cases, equals: …)` (lib/src/aggregate/laws.dart) checks, all
through `finish` and `equals`:

1. left identity: `combine(empty, fold xs) ≈ fold xs`
2. right identity: `combine(fold xs, empty) ≈ fold xs`
3. split: for split points k (every k for short cases),
   `combine(fold [0,k), fold [k,n)) ≈ fold xs`
4. associativity on three adjacent slices
5. singletons: left-combining one-row folds ≈ `fold xs`
6. slicing: one state fed random consecutive sub-slices ≈ `fold xs` (the
   `addSlice`-after-data path, separate from `combine`)
7. finishPure: finishing a state twice gives the same result, and the state
   keeps working afterwards
8. roundTrip (persistable aggregators only): see Checkpoints

Law 3 is what the app needs: any chunking gives the same metric. The harness
tests itself against deliberately broken aggregators
(test/aggregate/laws_harness_test.dart), so a lawful verdict means something.
In tests, `expectLawful(agg, cases, equals: …)` is the one-liner.

## Checkpoints

A state can be stored and resumed. `encodeState` / `decodeState` turn a
state into JSON and back; `persistable` says whether an aggregator supports
it (a composite is persistable when all its children are). Doubles round-trip
exactly; NaN and ±Infinity are written as the strings `"NaN"`, `"Infinity"`,
`"-Infinity"`. Decoders throw `FormatException` on anything malformed.

`encodeCheckpoint(agg, state, kind:, version:)` wraps a state with a kind and
version. `decodeCheckpoint` returns null, and never guesses, when the kind or
version differs or the payload is damaged; the caller then recomputes from
raw data. Bump the version whenever a module's state layout or arithmetic
changes.

When an aggregator is persistable, `checkLaws` adds the law `roundTrip`: a state that went through JSON combines and continues exactly
like the original. So every `expectConversion` call also checks persistence.

## Building blocks

All lawful, so anything assembled from them is lawful too:

- counts and sums: `Count`, `CountFinite`, `CountWhere`, `Sum`
  (Neumaier-compensated), `SumSq`, `SumOf(col, f)` (sum of `f(x)`, NaN skips)
- extremes and edges: `Min`, `Max`, `First`, `Last`
- moments: `Moments` (wraps `RunningMoments`)
- composition: `both(a, b)` (mutable pair state, no per-row allocation),
  `.map(f)` on the result
- grouping: `GroupBy(key, inner)` (consecutive equal keys reach `inner` as one
  slice; per-key order kept)
- suffixes: `LastRows(k)` (the last k rows of the whole input, kept
  verbatim)
- prefixes: `Prefix(k, head, tail)` (the first k rows of the whole input go
  to `head`, kept verbatim, at most k rows; every later row goes to `tail`)
- recurrences: `Ewma(col, λ)` finishes as an `Affine` map (see below)
- neighbour context: `Lookback(k, inner)`. `inner` processes every length-k
  window inside each slice it is given. `Lookback` keeps the first and last
  k−1 rows and hands `inner` the seam rows on `combine` and on
  `addSlice`-after-data, so each window is counted exactly once under any
  chunking. `Lookback(2)` gives successive differences, `Lookback(3)` lag
  pairs, and `Lookback(epochsPerDay + 1)` the SRI day-to-day comparison.

Where no block fits, a small hand-written inner (an `Aggregator` with a tight
loop) is fine. It is still checked by the same laws.

## Two ways to make an "unmergeable" calculation mergeable

Earlier experiments filed some calculations as not mergeable. Two
techniques moved them across:

- **Summarise a function, not a value.** An EWMA step
  `c ← (1 − λ)c + λx` is an affine map of the running value. Affine maps
  compose associatively, so a chunk's summary is the composed map
  `(scale, offset)`, and `finish` applies it to the seed. CTL/ATL/TSB is
  `both(Count, Prefix(prime, mean, both(Ewma, Ewma)))`.
- **Summarise a distribution exactly when its support is small.**
  Time-in-zone credits each sample with `min(gap, m)`, where `m` is the
  median gap of the whole stream. The state keeps exact histograms of gap
  values, which are bounded by the number of distinct gaps (a handful on a
  1 Hz stream), and the median and crediting move to `finish`. The median is
  bit-identical to the batch code.

## Converting a module: recipe

1. Pick the batch: an existing one, or a small `Batch` subclass with one typed
   column per input.
2. List the sufficient statistics `finish` needs. If they're sums, counts,
   extremes or moments, use the blocks; if they need neighbours, wrap them in
   `Lookback(k)`; if they're per bin or per day, wrap them in `GroupBy`.
3. Write `finish` (`.map`) from the old function's formulas, including its
   absent cases and notes.
4. Tests: one `expectConversion(build, cases, reference)` call checks parity
   with the old function on every evaluation path (whole, chunked,
   right-nested, copies, sliced, singletons) and every law, including
   `roundTrip` once the aggregator is persistable. Add hand-worked value and
   absent-case tests as usual.
5. Integer outputs: rewire the old function in place to run the aggregator,
   and keep a frozen copy of the old body in the test. Float outputs: keep
   the aggregator additive beside the old function, so no published value
   moves and no kAlgoVersion bump is needed.

## Results so far

| module | how | parity | shape |
|---|---|---|---|
| hypnogram metrics | rewired in place | exact | hand inner over `ListBatch<StageSegment>`; wake spans kept as a list (clipped at finish) |
| HRV time domain | additive | 1e-9 | `Lookback(2)`, `Lookback(3)`, `Moments`, `GroupBy` over `Beats` |
| Phillips SRI | rewired in place | exact | `Lookback(epochsPerDay + 1)` + `GroupBy` per day pair over `Epochs` |
| Banister TRIMP | additive | 1e-12 | `both(Count, SumOf)` |
| cosinor | additive | 1e-9 (R² 1e-7) | one inner computing cos/sin once per row; centred co-moments |
| time in zone | additive | 1e-12 | `Lookback(2)` + exact gap histograms; median at finish |
| CTL/ATL/TSB | additive | 1e-9 | `Count`, `Prefix`, `Sum`, two `Ewma` maps |
| readiness lnRMSSD | rewired in place | exact | `Count` + `LastRows(windowDays + 1)` |
| PRSA DC/AC | additive | 1e-9 | `Count` + `Lookback(2l + 1)` with a profile-sum inner |
| circadian IS/IV/M10/L5/RA | additive | 1e-12 int data, 1e-9 real | `Moments`, `GroupBy`, `Lookback(2)` + one 15-line inner |

Every module above is persistable and resumes from a mid-stream checkpoint.
The circadian conversion, done by following the recipe, took a subagent
about nine tool calls: a 134-line aggregator and a 166-line test.

Speed, AOT, Dart 3.11.4 on this box (`tool/bench_aggregate.dart`):

| 30,000 beats, HRV time domain | µs |
|---|---:|
| `hrvTime()` (current batch code) | 4,956 |
| hand loop, same statistics | 639 |
| composed, one slice | 1,281 |
| composed, 24 slices + combine | 1,209 |
| composed, one-row slices | 10,106 |
| per-element composed (earlier API) | ~24,800 |

The composed version is about 2× a hand loop and about 4× faster than the
current batch function. Chunking costs nothing extra. (It was 1.7× before the
review fixes switched the lag-1 ACF to centred co-moments, which cost one
division per row and removed a cancellation bug.)

## Proposed next step: corrected HRV end to end

Every HRV aggregator here starts from already-corrected NN intervals. RR
artifact correction is the upstream blocker the earlier experiments named.
The package already has a streaming `RrCorrector`
(lib/src/onehz/foundations/rr_correction_stream.dart): a left-to-right fold
whose output for a beat is final about 2H beats (H = windowBeats ~/ 2) plus
the current artifact run plus two normal beats behind the newest beat, and
whose checkpoint holds that window, not the series.

That suggests a mergeable "sandwich" summary for raw RR:

- raw head: the first beats of a chunk whose correction still depends on the
  chunk before it (window, carried class, left normal pair);
- settled middle: corrected beats, folded straight into a downstream
  aggregator (HRV time, PRSA, …);
- raw tail: the last beats whose correction still depends on the chunk after.

`combine` re-runs correction on `left.tail ++ right.head` only, feeds the
newly settled beats to the downstream aggregator, and keeps the remainder as
the new head/tail. That is `Lookback` with a transducer in front of the
inner aggregator, and it is bounded only if artifact runs are bounded. So it
needs a cap on run length (a longer run becomes a gap: honest absence), which
changes output and needs a kAlgoVersion bump. Owner decision.

## Known limits

- `Lookback` copies k−1 rows per seam. With large k and tiny slices this
  dominates: SRI over 7 days at 1,440 epochs/day takes 0.2 ms as one slice,
  0.5 ms in hourly slices, 17.7 ms in one-epoch slices. Feed slices of at
  least k rows, or give `Lookback` an appendable edge buffer if a caller
  can't.
- Still batch-only: exact medians and quantiles over floats, pairwise
  statistics (sample entropy), Viterbi backtrack, and anything whose context
  is unbounded (current RR artifact correction). These need a bounded variant
  behind a kAlgoVersion bump, or stay batch.
- Still hard: `nocturnalRhr` slides a TIME window whose qualifying rule
  depends on the stream-wide median cadence. A mergeable version would keep,
  per possible valid-sample count, the lowest window mean (bounded by the
  window length) plus a time-based lookback block, which doesn't exist yet.
- Float results are equal within a tolerance, not bit-identical, across
  chunkings. That is why float modules stay additive.
