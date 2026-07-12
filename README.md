# OpenStrap analytics

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

## What's actually in here

Eight families, each its own subdirectory with its own sub-barrel, built on two shared
foundation layers:

- **`foundations/`** — Lipponen-Tarvainen RR artifact correction, Winsorized-EWMA rolling
  baselines, inverse-variance fusion, a PPG signal-quality index.
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
- **`workout/`** — workout detection (both explicit and automatic), heart-rate-reserve
  zones, Keytel/Harris-Benedict calorie estimation.
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

282 tests, nothing mocked — pure functions, fixture in, assertion out.

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
