# Contributing

This package is the math: 1 Hz records in, metrics out. **Pure Dart, zero runtime
dependencies, no I/O, no randomness, no clock.** Same input, same output, every
time. It runs on-device, inside an isolate, on a phone — so it also has to be
cheap.

## What belongs here (and what doesn't)

| Your change | Repo |
|---|---|
| A metric, or how an existing number is computed | **here** |
| A record type, opcode, event, anything byte-level | [protocol](https://github.com/OpenStrap/protocol) |
| Storage, sync, Bluetooth, UI, when things get computed | [edge](https://github.com/OpenStrap/edge) |

## The two rules that matter

**1. Cite the method.** Everything in here implements a published,
peer-reviewed algorithm, with the citation in a comment next to the code and a
row in [`ALGORITHMS.md`](ALGORITHMS.md). The point is that you can go read the
paper and decide for yourself whether to trust the number.

If nothing in the literature fits, that's allowed — mark it `ESTIMATE`, give it
low confidence, and say so plainly. What's not allowed is inventing constants
and presenting them as science, or reverse-engineering WHOOP's scores by
fitting to their output.

**2. Never fabricate a value.** If an input isn't there, return a `Metric` with
a `null` value. Not a default, not a last-known-good, not an interpolation
that'll look plausible on a chart. Cold start returns
`need_baseline:have=H,need=N` and that's the correct behaviour, not a bug to
paper over.

```dart
class Metric<T> {
  final T? value;          // null when the inputs weren't there
  final double confidence; // 0..1
  final String tier;       // AUTH | HIGH | ESTIMATE | RELATIVE
  ...
}
```

## Honest ceilings — please don't "fix" these

These are properties of what a WHOOP 4.0 actually hands over, not defects:

- **HRV is PRV**, derived from 1 Hz beat timing. It is not ECG-grade.
- **Deep sleep is a low-confidence HR-flatness overlay.** The band gives no
  signal that distinguishes NREM stages properly.
- **SpO₂ and skin temperature are relative ADC values.** There is no calibration
  to absolute units and there won't be. `absolute_spo2:false` is deliberate.
- **Cole–Kripke coefficients on 1 Hz data** are a documented bounded exception,
  used for the wake spine only and corrected downstream. Read the comment in
  `cardio_stager.dart` before touching it.

Making any of these *look* more confident than the underlying signal supports is
the one change guaranteed to be rejected.

## Structure

Each family is a subdirectory under `lib/src/onehz/` with its own sub-barrel:
`foundations`, `clinical`, `sleep`, `respiration`, `motion`, `workout`,
`wellness`, `human`. Put new work with its siblings and export it through the
barrel.

There is **one** sleep source (`segmentSleep`) and **one** headline readiness
(`readinessComposite`). Don't add a second of either — extend the existing one.

## Tests

```bash
dart pub get
dart analyze
dart test
```

Everything runs on synthetic and property-based inputs in CI. A handful of tests
replay `whoop_hist.jsonl`, a real band capture kept *beside* the repo rather
than committed to it; those skip automatically when it's absent.

Any change to a metric needs a test that pins the behaviour, and — because
stored results are versioned and immutable — a note in the PR saying so, since
it means `kAlgoVersion` has to be bumped over in edge. If that bump doesn't
happen, devices keep serving the old numbers.

## Pull requests

- Branch off `main`, one logical change per PR.
- Name the paper you implemented, with enough detail to find it.
- Say whether the output of any existing metric changes. This is the single most
  important line in the PR.
- No `Co-Authored-By` trailers.
