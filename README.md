# OpenStrap analytics

This is the math. Given the always-on 1 Hz substrate a WHOOP 4.0 actually hands over —
beat-to-beat RR intervals, 1 Hz heart rate, 1 Hz tri-axial accel, and a few relative ADC
channels (skin temp, SpO2, ambient light) — it works out the things you care about: how
hard you went today, how well you slept, whether you're recovered, whether something's off.

Pure Dart, zero runtime dependencies. No AI, no I/O, no randomness, no clock. Same input,
same output, every time. It runs **on-device**, computed by the app
([edge](https://github.com/OpenStrap/edge)) directly — there's no cloud, no backend cron,
no server that ever touches your data. (An earlier version of this package had a
minute-resolution, backend-cron-ported family; that's gone. This is a 1 Hz-native rewrite,
and the "1 Hz" part isn't cosmetic — it's what lets a lot of these methods work at all.)

Let me be straight with you about what this is and isn't, because it'd be easy to oversell
it.

Every single thing in here is a published, peer-reviewed method — see `ALGORITHMS.md` for
the full table with citations. None of it is invented, none of it is a neural net, none of
it is me guessing what WHOOP does. I picked methods that exist in the literature so you can
go read the paper and decide for yourself whether you trust the number.

Which brings me to the honest part: **is this the same as what WHOOP gives you? No. Not
close.** WHOOP has years and a research team behind their recovery/strain scores. I have a
reverse-engineered byte stream and a pile of textbook equations. What I compute is an
honest approximation built from exactly what the band hands over, nothing more. It trends
correctly and it'll tell you when you're under-recovered. It's not their secret sauce.

## How a number knows how much to trust itself

Almost everything returns the same shape — `Metric<T>`. (A handful of multi-day/list
outputs return a plain `List<T>` instead because there's no single confidence/tier that
applies across a whole list — `illnessCusum`, `multivariateAnomaly`,
`journalCorrelations`. Worth knowing so you don't go looking for `.tier` on those.)

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

The tier tells you what kind of number it is. `AUTH` means it's directly measured or
definitional (raw ADC counts, RR count). `HIGH` means strong literature support on this
substrate. `ESTIMATE` means published, but estimate-grade once you're actually running it
on a wrist 1 Hz signal instead of a lab setup. `RELATIVE` means it only means anything
compared to your own baseline — skin temp and SpO2 are the examples; the absolute value is
meaningless, the *change* isn't.

Confidence is computed from real coverage — worn minutes, clean beats, nights of baseline
history — never hardcoded to look reassuring.

And the rule the whole package lives by: **if the input isn't there, the answer is `null`
and the confidence is `0`.** Nothing gets filled with a plausible-looking guess. A metric
that needs 7 nights of baseline and only has 3 says so explicitly (`note:
"need_baseline:have=3,need=7"`) instead of quietly computing something on 3 nights and
hoping nobody notices.

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
- **`sleep/`** — van Hees z-angle segmentation feeding a cardiac/motion stager (the single
  source of truth for sleep staging), AASM hypnogram metrics, cardiopulmonary coupling,
  fractal sleep-cycle detection, circadian non-parametric indices (IS/IV/RA/L5/M10).
- **`respiration/`** — RSA-derived respiratory rate fused with motion-modulated RIIV,
  CVHR-based apnea screening, a relative (never absolute) oxygen-desaturation ratio.
- **`motion/`** — ENMO/MAD activity metrics, a hybrid live/1 Hz step estimator (AN-2554
  100 Hz pedometer preferred, a gated-and-bout-length-checked 1 Hz fallback for coverage
  the live stream missed), energy-expenditure fusion.
- **`workout/`** — workout detection (both explicit and automatic), heart-rate-reserve
  zones, Keytel/Harris-Benedict calorie estimation.
- **`wellness/`** — the canonical composite readiness score, multivariate (Mahalanobis)
  anomaly detection, CUSUM changepoint detection, temperature-based illness flagging.
- **`human/`** — sleep regularity index, social jetlag/chronotype, single-night event
  detection (never names a specific cause — see below), percentile-of-you/personal
  records, and the deterministic coaching layer.

## The rule that matters most: never name a cause

Alcohol, a late meal, early illness, the luteal phase, and a hot bedroom all produce a
nearly identical nocturnal signature — RHR up, HRV down, HR-dip blunted, skin temp up.
So the honest move is: report the *state* confidently (an autonomically stressful night),
and only ever offer a specific cause as a **tag-confirmable hypothesis** the user opts
into, never an assertion. `human/event_detection.dart`'s doc comment calls this "the
central honesty rule" for a reason — anything that guesses a cause outright is a bug, not
a feature, however tempting a plausible-looking headline is.

## Tests

```bash
dart test   # run from the repo root — some fixtures resolve paths relative to it
```

282 tests, no mocking anything — pure functions, fixture in, assertion out.

## If you want to add a metric

Write a function that takes the 1 Hz substrate (or a derived series like an RR stream)
plus whatever history it needs, and returns a `Metric<YourThing>`. Keep it pure. Cite the
published method you're implementing in a doc comment so the next person can check your
work — if nothing in the literature fits what you're computing, mark it `ESTIMATE` and say
so honestly rather than inventing a number that looks more solid than it is. Derive
confidence from real coverage, and return absent (`Metric.absent(...)`, never a fabricated
fallback) when the inputs genuinely aren't there. And if your idea needs a cause it can't
actually distinguish from three other explanations, report the state, not the cause.
