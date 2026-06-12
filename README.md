# OpenStrap analytics

This is the math. Given a stretch of per-minute heart rate, motion, and wear, it works
out the things you care about: how hard you went today, how well you slept, whether you're
recovered, how your training load is trending. The [backend](https://github.com/OpenStrap/backend)
imports it and runs it on a cron. On its own it's just a pile of functions.

Let me be straight with you about what this is and isn't, because it'd be easy to oversell
it.

Every single thing in here is a published, peer-reviewed method. Banister's TRIMP for
strain. Cole-Kripke actigraphy for sleep. Keytel's equation for calories. The Sleep
Regularity Index. ACWR for load. None of it is invented, none of it is a neural net, none
of it is me guessing what WHOOP does. I picked methods that exist in the literature so you
can go read the paper and decide for yourself whether you trust the number.

Which brings me to the honest part: **is this the same as what WHOOP gives you? No. Not
close.** WHOOP has spent years and a lot of money turning their sensor data into recovery
and strain scores, with a cloud and a research team behind it. I have a heart rate per
minute and some textbook equations. What I compute is an honest approximation built from
what the band actually hands over. It's useful, it trends correctly, it'll tell you when
you're under-recovered. It is not their secret sauce and I'm not going to pretend it is.

## How a number knows how much to trust itself

Everything returns the same shape:

```ts
type Metric<T> = T & {
  confidence: number;        // 0 to 1
  tier: 'AUTH' | 'HIGH' | 'ESTIMATE' | 'RELATIVE';
  inputs_used: string[];     // which inputs actually fed this
}
```

The tier tells you what kind of number it is. `AUTH` means it came straight off the
device. `HIGH` means it's measured and run through a solid published method. `ESTIMATE`
means it's modelled and you should treat it as a ballpark. `RELATIVE` means it only means
anything compared to your own baseline, skin temperature is the example, the absolute
value is meaningless but the change isn't.

The confidence is calculated. Mostly it comes from coverage (did I have
enough worn minutes?) and completeness (were the inputs I needed actually present?). If
you wore the band four hours instead of overnight, confidence drops. If a metric needs
three inputs and got two, it drops.

And the rule the whole package lives by: **if the input isn't there, the answer is `null`
and the confidence is `0`.** I never fill a gap with a plausible-looking guess. A missing
number stays missing. The moment it starts fabricating, none of the rest is trustworthy,
so it just doesn't.

## What each file computes

| Function | File | What it does |
|----------|------|--------------|
| `calcRestingHR` | `resting.ts` | 5th percentile of heart rate across your sleep window. Falls back to your quietest 30 minutes if there's no sleep yet. |
| `calcStrain` | `strain.ts` | Banister TRIMP over heart-rate reserve, `ratio·0.64·e^(1.92·ratio)` summed per minute, squashed onto a 0–21 scale. |
| `calcHrZones` | `zones.ts` | Minutes spent in five zones by percent of max HR. |
| `calcCalories` | `calories.ts` | Keytel (2005), the active-kcal-per-minute equation, summed. Different formula for men and women; averages the two if it doesn't know. |
| `calcSleep` | `sleep.ts` | Cole-Kripke scores each epoch awake or asleep from motion, then I nudge it with the overnight HR dip. Gives onset, wake, efficiency, and a beta stage estimate. |
| `calcSleepRegularity` | `regularity.ts` | The Sleep Regularity Index, 0–100, from how much your bed and wake times wander night to night. |
| `detectSessions` | `sessions.ts` | Finds workouts: sustained stretches above 40% heart-rate reserve, then classifies them roughly as cardio, strength, or a walk. |
| `calcHrRecovery` | `recovery.ts` | HRR60, how many beats your heart drops in the minute after a peak. A real fitness signal. |
| `calcLoad`, `calcFitnessTrend` | `trends.ts` | ACWR (last 7 days over last 28) for load, and regression slopes on resting HR and HRR for whether you're getting fitter. |
| `calcReadiness`, `calcAnomaly` | `readiness.ts` | Readiness from resting-HR deviation, sleep debt, and sleep quality. Plus a flag for "your resting HR has been up two days, are you getting sick?" |
| `calcBaselines` | `baselines.ts` | Rolling 30-day medians, the anchors everything else compares against. |
| `calcStress`, `classifyArousal` | `stress.ts` | Arousal from heart rate sitting above resting while you're not moving. If you're moving it's exercise, not stress, so it's gated out. |
| `calcNocturnalHeart` | `nocturnal.ts` | Your sleeping HR, its low point, how far it dipped from daytime, and a flag if it's running high. |
| `buildCoach` | `coach.ts` | A plain rules engine. Reads recovery and load, sets a strain target, ranks a handful of suggestions. No AI, just if-this-then-that with the thresholds written down. |
| `buildNotifications` | `notify.ts` | Decides what's worth pinging you about. Capped at six, ranked by priority, each with a stable id so you don't get the same nudge twice. |

A couple of things worth calling out so you don't go looking for them:

**There's no HRV in here, and there won't be.** WHOOP builds recovery on heart-rate
variability, the beat-to-beat timing. The band doesn't hand that to us over the wire, at
least not in any form I've been able to recover. So readiness here is built from resting
HR, sleep debt, and sleep quality instead, and it says so right on the label. The
`hrv.ts` file is empty on purpose, as a reminder of what we don't have.

**Max heart rate** falls back gracefully: a real measured peak from your workouts if I've
seen one, otherwise the highest I've observed, otherwise `220 − age`, otherwise 190. The
worse the source, the lower the confidence on anything that depends on it.

## Tests

It's all pure functions. No clock, no randomness, no network, no database. Same input,
same output, every time. Which means the tests are just fixtures in and assertions out,
no mocking anything.

```bash
npm test          # runs every module's test block
npm run typecheck
```

## If you want to add a metric

Write a function that takes minutes (or history) plus the baseline and profile, and
returns a `Metric<YourThing>`. Keep it pure, no side effects. Derive the confidence from
coverage and completeness like the others do, and return `null` with `0` confidence when
you don't have the inputs. Put the name of the method you used in a comment so the next
person can check your work. And if your idea needs HRV or some signal the band doesn't
expose, it doesn't belong here, that's the line.
