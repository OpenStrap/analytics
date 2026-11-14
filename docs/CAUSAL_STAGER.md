# Causal sleep stager

`CausalStager.observe` in `lib/src/onehz/sleep/causal_stager.dart`, exported
from `package:openstrap_analytics/onehz.dart`.

It answers one question: **right now, using only what the band has reported so
far, is the sleeper awake, in NREM, or in REM — and if it cannot tell, why not?**

## What it is

A live, past-only version of `cardioStager`. It uses the same per-epoch
features, the same REM axis weights, the same REM cutoff and the same wake,
atonia and HR-floor rules. Where `cardioStager` looks at both sides of an epoch,
this looks only backwards.

It is built for decisions that cannot wait for the night to end, such as waking
someone during estimated REM.

## What it is not

- **Not polysomnography.** It is a wrist autonomic estimate (tier `ESTIMATE`).
  It never labels N1/N2/N3 and never diagnoses anything.
- **Not more accurate than `cardioStager`.** It has fewer smoothing passes. The
  retrospective stager itself scores kappa 0.13 against PSG on the held-out
  DREAMT split. Agreement with the offline hypnogram below is a consistency
  check, not an accuracy figure.
- **Not a sleep-onset detector.** Start it at in-bed time (`prior == null`). If
  you feed it the waking afternoon, its baselines come from waking physiology.
- **Not a probability.** `confidence` measures how much evidence there was (HR
  and RR coverage, capped at 0.6). It does not say how likely the stage is to be
  right.

## API

```dart
import 'package:openstrap_analytics/onehz.dart';

final obs = CausalStager.observe(window, priorState); // priorState == null at night start
obs.stage;             // CausalStage.wake | nrem | rem | absent
obs.confidence;        // 0 when absent, else 0.15 .. 0.6
obs.evidenceAgeMs;     // now minus the end of the newest second with valid HR + accel
obs.abstentionReason;  // CausalAbstention?, non-null exactly when stage == absent
obs.runSec;            // how long this stage has held (0 when absent)
obs.epochStartMs;      // the 30 s epoch the stage describes
obs.note;              // 'warmup:have=H,need=N' while warming up
obs.trace;             // plain-data decision trace (features, thresholds, counters)
obs.nextState;         // pass this to the next call
```

`CausalSampleWindow({required double nowMs, List<HrSample> hr, List<AccelSample> accel, RrSeries? rr})`
uses the package's existing sample types. `nowMs` is the decision time, supplied
by the caller (the package has no clock). `hr == 0` means off-skin.

### Rules the contract enforces

- **No look-ahead.** Samples stamped at or after `nowMs` are ignored and counted
  in `trace['ignoredFuture']`. An epoch is staged only once it has closed.
- **Deterministic.** The same sequence of windows gives byte-identical
  observations and states. Chunking does not matter (30 s windows and one big
  catch-up window give the same answer) as long as a single catch-up window
  spans no more than `historyEpochs`.
- **Replacement-tolerant.** A window is authoritative for the time span it
  covers, per channel. Re-sent, overlapping and corrected windows converge on the
  state a clean feed would have produced. Samples more than 600 s behind the
  newest stored sample are ignored (`trace['ignoredStale']`); their features are
  frozen. Send whole seconds.
- **Never carries a stage across an abstention.** An epoch that cannot be staged
  is `absent`; the next answer comes from the next good epoch.

### Latency

A stage describes the newest *closed* 30 s epoch, and the RR features use
trailing 3 to 5 minute windows whose centres sit 1.5 to 2.5 minutes behind the
epoch. That is the cost of not looking ahead. Measured against the offline
hypnogram, agreement peaks at a lag of only 30 s and falls off slowly after that,
so one night cannot pin the lag down more precisely than "about a minute or two".

## State

`CausalStagerState` is plain data: `toJson()` and `CausalStagerState.fromJson()`
(returns `null` for anything it did not write, so the caller restarts and pays a
warm-up instead of getting a guessed state). It holds:

| field | contents |
|---|---|
| `config` | `warmupEpochs` (40 = 20 min), `maxEvidenceAgeSec` (120), `historyEpochs` (360 = 3 h), `remScoreCut` (the shipped 0.5) |
| `lastNowMs` | latest decision time; an earlier `nowMs` is a clock regression |
| `lastUsableSec` | newest second with valid on-skin HR and valid accel |
| `hrTail`, `accelTail`, `rrTail` | the last 15 minutes of raw samples (`[sec,bpm]`, `[sec,x,y,z]`, `[ts_ms,rr_ms]`) |
| `rows` | one feature row per closed 30 s epoch (up to `historyEpochs`): motion, HR, HR SD, SDNN, R(k), LF/HF, coverage counts, and the raw stage decided when the epoch closed |

It is about 160 KB of JSON for a long night, and it crosses an isolate boundary
as is. A call costs about 5 ms on the VM; a 3 hour catch-up in one window takes
about 1 s. Run it in an isolate, not on the UI thread.

## Abstention reasons

`absent` always carries one of these. They are checked roughly in this order.

| reason | meaning |
|---|---|
| `clockRegressed` | `nowMs` is earlier than a time already seen, or not finite. State is returned untouched. |
| `noEvidence` | no sample of any kind has ever arrived |
| `staleEvidence` | nothing at all arrived within `maxEvidenceAgeSec` of `nowMs` (disconnect, out of range) |
| `offWrist` | the newest closed epoch is mostly `hr == 0` |
| `missingHr` | no valid HR in the newest closed epoch (absent, NaN, negative) |
| `missingAccel` | no valid accel in it. HR is checked first, so an epoch with neither says `missingHr`. |
| `lowCoverage` | HR or accel covers under half the epoch (`minHrCoverage`), or recent history is mostly unusable |
| `warmup` | fewer than `warmupEpochs` usable epochs so far; `note` says `warmup:have=H,need=N` |

The 20-minute warm-up is an engineering floor (enough epochs for the robust-z
baselines and the local HR gates to exist), not a physiological claim. Epochs
that were off-skin or too thin never count toward it. For a Natural Wake window
of `N` minutes, start collecting at least `N` plus the warm-up before the window
opens, plus margin for the lag above.

## How it differs from `cardioStager`

| | `cardioStager` | `CausalStager` |
|---|---|---|
| RR windows (SDNN, R(k), LF/HF) | centred, ±150 s and ±90 s | trailing, the same total lengths (300 s, 180 s) |
| 1 g reference for motion | centred 330 s median | **trailing 120 s median** (see below) |
| local HR gates | ±90 min | past 90 min |
| baselines (motion MAD, robust z) | whole night | expanding, up to 3 h |
| Webster rescore, bout consolidation | yes | **no**, they need the future side of a bout |
| mode filter | centred 3-epoch | trailing 2-of-3 vote |
| deep overlay, personal profile | yes | no |

Same on purpose: motion/HR/SDNN/R(k)/LF-HF definitions, the physiologic RR gate,
`kRemWeight*` (the measured DREAMT effect sizes), `kDefaultRemScoreCut`, the wake
gate (`hr` above local median plus max(6, SD), or big movement with an HR lift
or a big-move predecessor), the atonia and local-p25 HR-floor REM preconditions,
`minHrCoverage`, and the 0.6 confidence ceiling. The shared pieces were lifted
out of `cardio_stager.dart` (`weightedAxisScore`, `cleanRrBeatsBetween`,
`remFeaturesFromBeats`, `kRemWeight*`) so there is one copy, and that refactor is
bit-identical: `cardioStager` output on the real night (stages, deep flags,
confidence, at two cutoffs and with no RR) is unchanged.

**The 120 s motion reference is the one number chosen on data.** A trailing
window the same length as the centred one must wait for more than half of itself
to be the new posture, so 150 s after every static posture change reads as
movement and the wake gate fires. I tried 300, 180, 120 and 90 s on the one
in-tree night: wake over-call against the offline stager fell 104, 83, 62, 52 min
and kappa rose 0.305, 0.335, 0.369, 0.372. 120 s is the middle of the plateau.
It was selected on the same night it is validated on, so the validation below is
a little optimistic by exactly that much.

## Validation

`dart run tool/causal_stager_validate.dart` replays the in-tree real night
(`test/onehz/fixtures/real_night_2026_07_*.csv`, 8 h 54 min) through both stagers.

**What exists to validate against.** There is no PSG-labelled set in this repo
(DREAMT, used by `tool/stager_harness.dart`, lives outside it). The one real night
has only Apple Watch whole-night minutes, no epoch labels. So everything below is
agreement with the offline stager, on one night from one person.

Stage minutes: offline wake 26 / NREM 358 / REM 150; causal (staged epochs)
wake 62.5 / NREM 374 / REM 78; Apple Watch summary wake 3 / REM 162 / light 330
/ deep 38. The causal stager staged 1029 of 1068 epochs; the 39 it declined were
all `warmup`. Replay was deterministic.

Per-epoch agreement with the offline hypnogram (3 classes):

| causal(k) against offline(k-d) | agreement | kappa |
|---|---|---|
| d = 0 | 70.3 % | 0.369 |
| d = 1 (best) | 71.3 % | 0.391 |
| d = 4 (2 min) | 69.2 % | 0.343 |
| d = 8 (4 min) | 67.6 % | 0.307 |

Against the offline stage at the same epoch: wake recall 54 %, precision 22 %;
NREM recall 87 %, precision 79 %; REM recall 36 %, precision 69 %. The wake
precision is low because the causal stager does not bridge short arousals the way
Webster rescoring does after the fact. A short wake run is not yet known to be
short. Read `runSec` before acting on a wake.

Warm-up length barely moves agreement (kappa 0.369 at 10 and 20 min, 0.365 at
30, 0.350 at 60) and costs staged coverage (98 %, 96 %, 95 %, 89 %).

### False and late triggers for "wake during REM"

A trigger is `stage == rem && runSec >= X`. The reference is the 16 REM bouts the
offline stager emits (several are under 5 minutes). Chance level for a trigger
landing on offline REM is 29 %, and within 5 minutes of it 47 %, so the "no false
trigger" test is only as strict as that.

| X | trigger epochs | on offline REM | within 5 min of it | far from REM | bouts caught (of 16) | median lateness | tail epochs after a bout |
|---|---|---|---|---|---|---|---|
| 60 s | 116 | 70.7 % | 92.2 % | 9 | 14 | 1.0 min | 25 |
| 120 s | 69 | 71.0 % | 100 % | 0 | 11 | 1.5 min | 20 |
| 180 s | 46 | 67.4 % | 100 % | 0 | 7 | 2.5 min | 15 |
| 300 s | 26 | 57.7 % | 100 % | 0 | 3 | 0.5 min | 11 |

What this says:

- **False triggers are rare but not absent at short persistence.** At X = 60 s,
  8 % of trigger epochs sit more than 5 minutes from any offline REM. At 120 s and
  above there were none.
- **Late triggers are real.** Trailing windows keep the tail of a REM bout in
  view, so between a fifth (X = 60 s) and two fifths (X = 300 s) of trigger epochs
  fall in the five minutes after a bout ended. For X up to 180 s the first trigger
  inside a bout arrives a median 1 to 2.5 minutes after the bout starts.
- **It misses REM, and X = 300 s misses most of it.** REM recall per epoch is
  36 %. The five-minute rule catches 3 of 16 bouts. Two minutes catches 11 of 16.
  The cause is mostly a flickery causal REM label (no bout consolidation) plus
  the lag. If Natural Wake needs the five-minute rule it will abstain in most
  windows on a night like this one.
- **Window simulation** (fire once, at the first trigger in `[T-N, T)`, over every
  must-be-up time with a fully observable window): at X = 120 s the trigger fires
  in 38 % of 15-minute windows, 56 % of 30-minute, 80 % of 60-minute and every
  120-minute window. All fires landed within 5 minutes of offline REM; 77 to 87 % landed exactly
  on it. At X = 300 s: 14 %, 27 %, 43 % and 77 %. The remaining windows contained
  offline REM and did not fire (missed), or contained none.

These are one night. The offline stager is itself an estimate. Do not turn them
into a promise to users.

## Open caveats

- One recorded night, no epoch labels, no PSG. The agreement figures are a
  consistency check against another estimate.
- The 120 s motion reference was picked on the validation night.
- Wake is over-called relative to the offline stager (62 vs 26 min on the real
  night) because Webster bridging is retrospective.
- REM recall is low and arrives late; the persistence threshold is a direct trade
  between false triggers and missed ones.
- Baselines assume the stream starts at in-bed time. There is no sleep-onset
  detector inside.
- A single catch-up window longer than `historyEpochs` (3 h) gives run lengths
  that differ slightly from a live feed of the same data. The final stage and
  state agree.
- The decision rules are re-implemented (the offline ones are inline in
  `classifyCardioEpochs`). They are covered by the real-night agreement test, not
  by a line-for-line equivalence test.
