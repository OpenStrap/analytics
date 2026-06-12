# OpenStrap — analytics

The metrics engine. Pure functions, published algorithms, no AI, no magic.

> Not affiliated with or endorsed by WHOOP.

WHOOP's real value is years of proprietary research turning raw sensor data into
recovery, strain, and sleep scores. A hobby project can't reproduce that, and this
doesn't pretend to. What it *can* do is take the substrate the band actually gives
you — minute-by-minute heart rate, motion, wear — and compute honest, well-known
equivalents, each carrying a confidence so you always know how much to trust it.

Everything here is a **pure, deterministic function**: data in, metric out, same
input → same output, fully unit-tested. No network, no clock, no surprises. That's
what lets the [backend](https://github.com/OpenStrap/backend) run it on a schedule
and the numbers stay reproducible.

## What it computes
- **Strain** — Banister TRIMP over heart-rate reserve, log-scaled.
- **Sleep** — Cole-Kripke actigraphy fused with the overnight HR dip; duration,
  efficiency, and a beta stage estimate.
- **Recovery / readiness** — from resting HR, sleep debt, and consistency.
  **Not HRV-based** — the firmware doesn't give us beat-to-beat intervals, and the
  code says so rather than faking it.
- **Load (ACWR), fitness trend, HR zones, active calories, HR recovery.**
- **Coach** — a deterministic rules engine that turns the above into a ranked plan.
- **Stress** — arousal from HR-above-resting while you're still (not HRV).
- **Nocturnal heart** — sleeping-HR dynamics + an elevated-overnight-HR flag.

## The one rule
Never fabricate. A missing input yields a null and a confidence of 0, not a guessed
number. HRV, SpO₂, and clinical skin temperature are deliberately *not* here because
the hardware can't support them honestly.

## Test
```
npx tsx src/__tests__/analytics.test.ts
```
