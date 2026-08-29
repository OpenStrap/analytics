# OpenStrap analytics

[![test](https://github.com/OpenStrap/analytics/actions/workflows/test.yml/badge.svg)](https://github.com/OpenStrap/analytics/actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![stars](https://img.shields.io/github/stars/OpenStrap/analytics?style=flat&color=e2825f)](https://github.com/OpenStrap/analytics/stargazers)
[![Donate](https://img.shields.io/badge/donate-BTC%20%2F%20ETH-f7931a)](https://github.com/OpenStrap/edge/blob/main/DONATE.md)

This is the math. Given the always-on 1 Hz substrate a WHOOP 4.0 actually hands over —
beat-to-beat RR intervals, 1 Hz heart rate, 1 Hz tri-axial accel, and a few relative ADC
channels (skin temp, SpO2, ambient light) — it works out the things you care about: how
hard you went today, how well you slept, whether you're recovered, whether something's
off.

Pure Dart, zero runtime dependencies. No AI, no I/O, no randomness, no clock. Same input,
same output, every time. It runs **on-device**, computed by the app
([edge](https://github.com/OpenStrap/edge)) directly — no cloud, no backend cron, no
server that ever touches your data. (There used to be a minute-resolution family in here,
ported over from an old backend-cron setup. That's gone. This is a 1 Hz-native rewrite,
and the "1 Hz" part isn't decoration — it's what makes a lot of these methods work at
all.)

Every single thing in here is a published, peer-reviewed method — see `ALGORITHMS.md` for
the full table with citations. None of it's invented, none of it's a neural net, none of
it is me guessing what WHOOP does internally. I picked methods that exist in the
literature specifically so you can go read the paper yourself and decide whether you
trust the number.

Is it the same as what WHOOP gives you? No. Not close. They've got years and a research
team behind their recovery/strain scores. I've got a reverse-engineered byte stream and a
pile of textbook equations. What comes out of here is an honest approximation built from
exactly what the band hands over, nothing more. It trends correctly, it'll tell you when
you're under-recovered — it's not their secret sauce, and it never claims to be.

## How a number knows how much to trust itself

Almost everything returns the same shape — `Metric<T>`. (A handful of multi-day/list
outputs return a plain `List<T>` instead, because there's no single confidence/tier that
applies across a whole list — `illnessCusum`, `multivariateAnomaly`,
`journalCorrelations`. Worth knowing so you're not hunting for `.tier` on those.)

```dart
class Metric<T> {
  final T? value;             // null if the inputs weren't there — see below
  final double confidence;    // 0..1
  final String tier;          // Tier.auth | Tier.high | Tier.estimate | Tier.relative
  final List<String> inputs_used;
  final List<Driver>? drivers; // optional: signed contributors, for glass-box narratives
  final String? note;         // e.g. "need_baseline:have=3,need=7"
}
```

The tier tells you what kind of number you're looking at. `AUTH` means it's directly
measured or definitional (raw ADC counts, RR count). `HIGH` means strong literature
support on this exact substrate. `ESTIMATE` means published, but estimate-grade once
you're actually running it on a wrist at 1 Hz instead of in a lab. `RELATIVE` means it
only means anything compared against your own baseline — skin temp and SpO2 are the two
examples here; the absolute value is meaningless, the *change* isn't.

Confidence comes from real coverage — worn minutes, clean beats, nights of baseline
history — never hardcoded to look reassuring.

And the one rule the whole package lives by: if the input isn't there, the answer is
`null` and the confidence is `0`. Nothing gets filled in with a plausible-looking guess. A
metric that needs 7 nights of baseline and only has 3 says so directly (`note:
"need_baseline:have=3,need=7"`) instead of quietly computing something off 3 nights and
hoping you don't notice.

## Quick start

```dart
import 'package:openstrap_analytics/onehz.dart';

// nnMs: cleaned beat-to-beat RR intervals in ms (see foundations/rr_correction.dart
// for turning raw RR into this). nnTimesMs: cumulative beat timestamp in ms
// (time since the first beat, NOT the per-beat RR duration), same length.
final nnMs = <double>[800, 810, 795, 805];
final nnTimesMs = <double>[0, 800, 1610, 2405];
final Metric<HrvTime> hrv = hrvTime(nnMs, nnTimesMs: nnTimesMs, artifactFraction: 0.04);
if (hrv.value != null) {
  print('RMSSD ${hrv.value!.rmssd} ms (confidence ${hrv.confidence}, tier ${hrv.tier})');
}
```

Every metric function in the package follows this shape: plain `List<double>` (or a
small typed input class for the composite ones) in, `Metric<T>` out.

## What's actually in here

Eight families, each its own subdirectory with its own sub-barrel, built on two shared
foundation layers:

- **`foundations/`** — Lipponen-Tarvainen RR artifact correction, Winsorized-EWMA rolling
  baselines, inverse-variance fusion.
- **`clinical/`** (Tier-1) — HRV time/frequency domain (RMSSD/SDNN/pNNx, Lomb-Scargle
  LF/HF), PRSA (deceleration/acceleration capacity), nocturnal RHR/dip, an illness-risk
  CUSUM state machine, Plews ln-RMSSD readiness, Baevsky stress index, Banister/Edwards
  TRIMP + CTL/ATL/TSB training load, a Poincaré irregular-rhythm screen, cosinor circadian
  fitting, and real-time cardiac coherence for guided breathing sessions.
- **`sleep/`** — van Hees z-angle segmentation feeding a cardiac/motion stager (the
  single source of truth for sleep staging), AASM hypnogram metrics, cardiopulmonary
  coupling, fractal sleep-cycle detection, circadian non-parametric indices
  (IS/IV/RA/L5/M10).
- **`respiration/`** — RSA-derived respiratory rate fused with motion-modulated RIIV,
  CVHR-based apnea screening, a relative (never absolute) oxygen-desaturation ratio.
- **`motion/`** — ENMO/MAD activity metrics, a hybrid live/1 Hz step estimator (AN-2554
  100 Hz pedometer preferred, a gated-and-bout-length-checked 1 Hz fallback for whatever
  the live stream missed), energy-expenditure fusion.
- **`workout/`** — automatic workout detection (bout suggestion, never explicit/
  retroactive), heart-rate-reserve zones, Keytel/Harris-Benedict calorie estimation.
- **`wellness/`** — the canonical composite readiness score, multivariate (Mahalanobis)
  anomaly detection, CUSUM changepoint detection, temperature-based illness flagging.
- **`human/`** — sleep regularity index, social jetlag/chronotype, single-night event
  detection (never names a specific cause — more on that below), percentile-of-you/
  personal records, and the deterministic coaching layer.

## The rule that matters most: never name a cause

Alcohol, a late meal, early illness, the luteal phase, a hot bedroom — they all produce
nearly the same nocturnal signature. RHR up, HRV down, HR-dip blunted, skin temp up. So
the honest move is to report the *state* confidently (an autonomically stressful night)
and only ever offer a specific cause as a **tag-confirmable hypothesis** the user opts
into — never an assertion. `human/event_detection.dart`'s doc comment calls this "the
central honesty rule," and it earns the name — guessing a cause outright is a bug here,
not a feature, no matter how tempting the plausible-looking headline is.

## Tests

```bash
dart test   # run from the repo root — some fixtures resolve paths relative to it
```

All pass (a handful skipped), nothing mocked — pure functions, fixture in,
assertion out.

## Validation

`tool/` has four harnesses that score shipped detectors against labelled corpora, not
synthetic fixtures — run one before touching the logic it covers:

- `dart run tool/oxwalk_validate.dart <path-to-OxWalk_Dec2022>` — the pedometer against
  OxWalk (Oxford, CC BY): 39 subjects, camera-annotated heel strikes.
- `dart run tool/stager_harness.dart <fixture.json>` — the sleep-staging decision layer
  against a PSG-labelled corpus (e.g. DREAMT), reporting Cohen's kappa.
- `dart run tool/nap_harness.dart <fixture.json>` — the nap detector against hand-labelled
  days.
- `dart run tool/whoop_proportions.dart <dir-of-night-json>` — sweeps sleep-stage cutoffs
  against normative stage proportions on real device captures.

Each file's header comment has the full usage, flags, and fixture schema.

## If you want to add a metric

Write a function that takes the 1 Hz substrate (or a derived series like an RR stream)
plus whatever history it needs, and return a `Metric<YourThing>`. Keep it pure. Cite the
published method you're implementing in a doc comment, so the next person can actually
check your work — if nothing in the literature fits what you're computing, mark it
`ESTIMATE` and say so, rather than inventing a number that looks more solid than it is.
Derive confidence from real coverage, and return absent (`Metric.absent(...)`, never a
fabricated fallback) when the inputs genuinely aren't there. And if your idea needs a
cause it can't actually tell apart from three other explanations, report the state, not
the cause.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) — which repo a change belongs in, how to run the
tests, and the rules that keep this package honest. Security issues go through
[SECURITY.md](SECURITY.md), not a public issue.

## Support the work

No subscription, no paywall, no company behind this. If OpenStrap gave your band a second
life, a small tip genuinely helps:

- **BTC** — `bc1qvtcch38dcwp967ar764uu6eetw7tf907844wfq`
- **EVM** (Ethereum · Base · Arbitrum · Optimism · Polygon) —
  `0x8310C89393366b7eBCD47ABa82e1dfB5ECeFFbD9`

[What donations actually pay for →](https://github.com/OpenStrap/edge/blob/main/DONATE.md)

Nothing is gated behind paying, and nothing ever will be. Protocol findings and bug
reports are worth more than money, though.

---

Not affiliated with, endorsed by, or connected to WHOOP. "WHOOP" is their trademark, used
only to say which device this talks to.
