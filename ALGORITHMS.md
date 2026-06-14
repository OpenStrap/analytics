# OpenStrap Analytics — Algorithms

Every metric in this package is a **published, peer-reviewed algorithm** computed by a
**pure deterministic function** (no AI, no I/O, no randomness, no clock). Each returns a
`Metric<T>` envelope:

```ts
{ value…, confidence: 0..1, tier: 'AUTH'|'HIGH'|'ESTIMATE'|'RELATIVE', inputs_used: string[] }
```

**Design rules**
- **Confidence is computed**, not hardcoded — it scales with input coverage (worn minutes,
  beats, days of history) × input completeness. Missing input → `null` + confidence `0`.
- **Tiers:** `AUTH` = directly measured (e.g. wear minutes); `HIGH` = published method on
  authoritative inputs (HR/RR); `ESTIMATE` = published but noisy/derived; `RELATIVE` = only
  meaningful as a deviation from the user's own baseline (raw ADCs — temp/SpO₂).
- **Inputs** are **minute rollups** (`{ts, hr_avg/min/max, hr_n, activity, steps, wrist_on}`)
  for most metrics, or a **time-ordered RR-interval stream (ms)** for the HRV family.
- HRV is decoded from **type-24 RR intervals** (validated on real hardware: 99.7%
  physiological, median ≈ 860 ms ≈ 70 bpm).

---

## Master table

| # | Metric | Function | Algorithm | Published basis | Inputs → Output |
|---|--------|----------|-----------|-----------------|-----------------|
| 1 | Resting HR | `calcRestingHR` | 5th percentile of HR in the sleep window | Sleeping/early-morning minimum convention | HR over sleep window → bpm (HIGH) |
| 2 | Strain | `calcStrain` | Banister **TRIMP** over HR-reserve, log-scaled to 0–21 | Banister 1991; Morton, Fitz-Clarke & Banister, *J Appl Physiol* 1990 | per-min HR, RHR, HRmax → 0–21 (HIGH) |
| 3 | HR zones | `calcHrZones` | Minutes in 5 bands of %HRmax (50/60/70/80/90%) | ACSM zone model; HRmax = 220−age (Fox 1971) | per-min HR, HRmax → z1..z5 min (HIGH) |
| 4 | Active calories | `calcCalories` | **Keytel** HR→kcal/min, above-resting, zone-gated | Keytel et al., *J Sports Sci* 2005 | per-min HR, age/weight/sex → kcal (ESTIMATE) |
| 5 | Sleep | `calcSleep` | **Cole–Kripke** actigraphy + HR-dip fusion; HR-percentile stages | Cole, Kripke et al., *Sleep* 1992 | per-min activity+HR → onset/wake/eff/stages (HIGH; stages ESTIMATE) |
| 6 | Sleep regularity | `calcSleepRegularity` | **SRI** via **circular** statistics of onset/wake | Phillips et al., *Sci Rep* 2017 | onset/wake times → 0–100 (HIGH) |
| 7 | Workouts | `detectSessions` | Sustained ≥40% HR-reserve + above-median motion | HR-reserve threshold method (Karvonen reserve) | per-min HR+activity → session list (HIGH event / ESTIMATE type) |
| 8 | HR recovery | `calcHrRecovery` | **HRR60** — HR drop ~60 s after a session peak | Cole, Lauer et al., *NEJM* 1999 | session HR → bpm dropped (HIGH) |
| 9 | Training load | `calcLoad` | **ACWR** = acute(7d)/chronic(28d) mean strain | Gabbett, *BJSM* 2016; Hulin et al. 2016 | daily strain → ratio + band (HIGH) |
| 10 | Fitness trend | `calcFitnessTrend` | Sign of rolling RHR slope (↓) + HRR60 slope (↑) | RHR/HRR fitness markers (no VO₂max claim) | daily RHR+HRR60 → direction (ESTIMATE) |
| 11 | Baselines | `calcBaselines` | Rolling 30-day medians (RHR/sleep-need/temp/zones); chronic strain = mean | Robust rolling baseline | 30-day history → baseline set (HIGH) |
| 12 | HRV (time) | `timeDomainHrv` | **RMSSD, SDNN, pNN50** with artifact rejection | Task Force ESC/NASPE, *Circulation* 1996 | RR stream → ms / % (HIGH) |
| 13 | HRV (frequency) | `freqDomainHrv` | **LF/HF** via **Lomb–Scargle** periodogram (uneven RR) | Laguna, Moody & Mark, *IEEE TBME* 1998 | RR stream → ms², ratio (HIGH) |
| 14 | Respiratory rate | `freqDomainHrv` | **RSA** — HF (0.15–0.4 Hz) spectral peak × 60 | Charlton et al., *Physiol Meas* 2016 | RR stream → breaths/min (ESTIMATE, gated) |
| 15 | Recovery | `calcRecovery` | **Plews** ln-RMSSD z-score vs rolling baseline | Plews et al., *Sports Med* 2013 | tonight RMSSD + baseline → 0–100 (HIGH) |
| 16 | Stress | `calcStress` | **Baevsky Stress Index** + LF/HF, personal-relative | Baevsky & Berseneva 2008; Task Force 1996 | RR stream + baseline SI → 0–100 (ESTIMATE) |
| 17 | Illness signal | `calcIllness` | **Mahalanobis** distance of {RHR↑, RMSSD↓, temp↑} | Mahalanobis 1936; Mishra et al., *Nat Biomed Eng* 2020; Smarr et al., *Sci Rep* 2020 | today vs baseline cov → signal (ESTIMATE) |
| 18 | Nocturnal heart | `calcNocturnalHeart` | Sleeping-HR mean/nadir + autonomic dip % | Nocturnal HR-dipping literature | sleep HR vs waking HR → dip %, flag (HIGH) |
| 19 | Sleep stress | `calcSleepStress` | Nocturnal arousal: HR-surge + motion events | Cardiac-activation arousal proxy | sleep HR+activity → arousal count/score (ESTIMATE) |
| 20 | RHR anomaly | `calcAnomaly` | RHR ≥ baseline+7% for ≥2 consecutive days | Radin et al., *Lancet Digit Health* 2020 | recent RHR → boolean signal (ESTIMATE) |
| 21 | VO₂max | `calcVo2Max` | **Uth–Sørensen** `15.3 · HRmax/HRrest` | Uth et al., *Eur J Appl Physiol* 2004 | HRmax + RHR → ml·kg⁻¹·min⁻¹ (ESTIMATE) |
| 22 | Fitness / Fatigue / Form | `calcFitnessModel` | **Banister** impulse-response: Fitness=EWMA(τ42), Fatigue=EWMA(τ7), Form=Fitness−Fatigue | Banister 1975/1991; Coggan CTL/ATL/TSB | daily strain → fitness/fatigue/form (ESTIMATE) |
| 23 | Training monotony | `calcMonotony` | **Foster** monotony = mean/SD of 7-day strain; strain = load×monotony | Foster, *Med Sci Sports Exerc* 1998 | daily strain → monotony + training strain (HIGH) |
| 24 | HRV stability | `calcHrvStability` | **CV** = SD/mean of nightly RMSSD over a window | HRV reliability/CV (Plews/Flatt) | RMSSD series → CV % (HIGH) |
| 25 | Irregular-beat screen | `calcIrregular` | **Poincaré** SD1/SD2 + ectopic-rejection fraction + pNN50 | Brennan et al., *IEEE TBME* 2001; AF-screening literature | RR stream → flag + SD1/SD2 (ESTIMATE) |
| 26 | Readiness (composite) | `calcReadinessIndex` | Transparent weighted blend: recovery·0.5 + sleep·0.2 + dip·0.15 + calm·0.15 | Composite (documented weights; abstains w/o HRV) | recovery/sleep/dip/arousal → 0–100 (ESTIMATE) |
| 27 | Steps | `calcSteps` / `pedometer` (`steps.ts`); runner `runStepsImu` (backend) | **AN-2554** wrist pedometer: dynamic-threshold peak pairs + 8-step confirm, ×gain | Analog Devices AN-2554 (2023); Zhao, *Analog Dialogue* 2010 | wrist IMU accel (R10+0x33, ~100 Hz) → steps (ESTIMATE) |
| – | Max HR helper | `resolveMaxHr` | measured session max → 220−age → observed → 190 | Fox 1971 (age fallback) | minutes/baseline/age → HRmax + source |

> `buildCoach` (deterministic plan) and `buildNotifications` (nudges) are rule engines over
> the metrics above, not statistical algorithms — they don't derive new physiology.

---

## Per-metric detail

### 1. Resting HR — `calcRestingHR`
**Why:** true RHR is the lowest sustained HR during sleep, not a single raw byte. The 5th
percentile is a robust "low" that ignores the noisy absolute minimum.
**How:** restrict HR to the night's sleep window (worn, `hr>0`); `RHR = percentile(hr_avg, 5)`.
Fallback (no sleep window): the lowest-mean **time-contiguous** 30-min worn stretch (≤90 s
gaps), confidence capped at 0.5. Coverage = `worn_sleep_min / 240`.

### 2. Strain — `calcStrain`
**Why:** Banister TRIMP is the standard exercise-load model; a log scale compresses it to a
familiar 0–21.
**How:** per worn minute, `r = clamp((hr−RHR)/(HRmax−RHR), 0, 1)`, then
`TRIMP += r · k · e^(b·r)` with sex-specific weights — **men (k=0.64, b=1.92)**, **women
(0.86, 1.67)**; unknown → men's. `score = min(21, ln(TRIMP+1)/ln(1.5))`. Coverage = `worn/30`.

### 3. HR zones — `calcHrZones`
**How:** per worn minute, `pct = hr/HRmax·100`; bucket into Z1 50–60, Z2 60–70, Z3 70–80,
Z4 80–90, Z5 ≥90. Confidence base 0.85 if HRmax measured else 0.6, × coverage.

### 4. Active calories — `calcCalories`
**Why:** Keytel's HR→energy regression is validated for **exercise**; applied to all-day
low HR it over-counts, so we (a) subtract the **resting** burn and (b) **gate** on HR ≥ 50%
HRmax (Zone-1 onset). Result is *active* energy, never total/BMR.
**How:** `kcal/min(hr)` (sex-specific or M/F mean) in kcal:
`male = (−55.0969 + 0.6309·hr + 0.1988·w + 0.2017·age)/4.184`,
`female = (−20.4022 + 0.4472·hr − 0.1263·w + 0.0740·age)/4.184`.
Sum `max(0, perMin(hr) − perMin(restRef))` over minutes with `hr ≥ 0.5·HRmax`. ESTIMATE.

### 5. Sleep — `calcSleep`
**Why:** Cole–Kripke is the classic wrist-actigraphy sleep/wake scorer; we fuse it with the
overnight HR dip for robustness when activity is flat.
**How:** per 1-min epoch `S = 0.001·Σ Wᵢ·Aᵢ` over window [−4..+2],
`W=[1.06,0.54,0.58,0.76,2.30,0.74,0.67]`; **asleep if S < 1**. HR-dip fusion: `hr<0.95·RHR`
→ asleep, `hr>1.15·RHR` → awake (margin clears REM's HR). Main sleep = the longest
**consolidated** period (interior awake gaps ≤20 min bridged; 14 h cap). Efficiency =
asleep / in-bed span.
**Stages (ESTIMATE/beta):** banded by the night's own sleeping-HR percentiles — deep =
bottom ~22% + quiet, REM = top ~21% (or an erratic minute), else light. (Targets a
plausible deep ~20% / REM ~20–25% / light ~55% split; minute-resolution HR can't do clinical
staging.)

### 6. Sleep regularity (SRI) — `calcSleepRegularity`
**Why:** the SRI rewards consistent timing. **Clock time is circular** (23:50 and 00:10 are
20 min apart, not ~1430) — a linear std floors the score for anyone sleeping near midnight,
so we use **circular statistics**.
**How:** map each onset/wake minute-of-day to an angle, take the mean resultant length `R`,
circular std `σ = √(−2·ln R)` (Mardia) in minutes;
`SRI = max(0, 100 − (avg(σ_onset, σ_wake)/120)·100)`. Needs ≥3 nights (else conf 0).

### 7. Workouts — `detectSessions`
**How:** a session starts when `hr ≥ RHR + 0.4·(HRmax−RHR)` (≈40% reserve) is sustained
≥3 min **and** mean activity > daily median; ends after ≥3 min below threshold. Merge
sessions <5 min apart; discard <5 min. Per session: strain/zones/calories/HRR60 + a crude
walk/run/strength type (type_confidence 0.4).

### 8. HR recovery (HRR60) — `calcHrRecovery`
**Why:** the 1-minute post-exercise HR drop is a validated mortality/fitness marker.
**How:** find the session HR peak (must exceed RHR + 40% reserve); `HRR60 = peak − hr` of the
worn minute 45–90 s later.

### 9. Training load (ACWR) — `calcLoad`
**How:** `ACWR = mean(last 7d strain) / mean(last 28d strain)`. Bands: `<0.8` detraining,
`0.8–1.3` optimal, `1.3–1.5` caution, `>1.5` high-risk. Confidence = `days/28`.

### 10. Fitness trend — `calcFitnessTrend`
**Why:** falling resting HR and rising HRR60 over weeks indicate improving cardiovascular
fitness — directional only; we **never emit a VO₂max number** (not measurable here).
**How:** least-squares slope of rolling-7d RHR and rolling-7d HRR60; improving if
`RHR slope < 0 AND HRR slope > 0`. ESTIMATE.

### 11. Baselines — `calcBaselines`
**How:** rolling 30-day **medians** of RHR, sleep duration (→ sleep need; real nights ≥2 h,
≥3 samples, ≥4 h plausibility), skin-temp (relative), per-zone minutes; chronic strain =
28-day mean; HRmax = max observed session peak else 220−age. Confidence = `days/30`.

### 12–14. HRV family — `timeDomainHrv`, `freqDomainHrv`
RR is cleaned first: keep 300–2000 ms, drop successive |Δ| > 200 ms (ectopics/misses).
- **RMSSD** = √(mean of squared successive RR differences) — short-term parasympathetic tone.
- **SDNN** = std of RR — overall variability. **pNN50** = % successive |Δ| > 50 ms.
- **LF (0.04–0.15 Hz) / HF (0.15–0.4 Hz)** band power via the **Lomb–Scargle** periodogram —
  the correct spectral estimator for the **unevenly sampled** RR tachogram (an FFT would
  require resampling). `LF/HF` ≈ sympatho-vagal balance.
- **Respiratory rate** = the HF spectral **peak frequency × 60** (respiratory sinus
  arrhythmia). Gated on peak prominence (conf ≥ 0.3) — breathing modulates RR, so the HF
  peak *is* the breathing rate, with **no PPG required**. Real-data check: 14–16 brpm.

### 15. Recovery — `calcRecovery`
**Why:** absolute HRV varies hugely between people; what matters is **your** HRV vs your norm
(Plews/HRV4Training method).
**How:** `z = (ln RMSSD_today − mean(ln RMSSD_baseline)) / sd`;
`score = clamp(50 + 25·z, 0, 100)` (each baseline SD ≈ 25 pts). Needs ≥5 baseline nights,
else `null` (no heuristic fallback). HIGH.

### 16. Stress — `calcStress`
**Why:** the Baevsky Stress Index quantifies sympathetic activation from the RR histogram;
scored **personal-relative** so "high" means high *for you*.
**How:** `SI = AMo / (2·Mo·MxDMn)` — Mo = modal RR (s, 50 ms bins), AMo = % of RR in the
modal bin, MxDMn = (max−min RR) in s. Score = `clamp(50 + 25·z, 0, 100)` on `ln(SI)` vs the
baseline SI distribution (≥5 windows); also reports LF/HF + RMSSD. ESTIMATE.

### 17. Illness signal — `calcIllness`
**Why:** illness/under-recovery moves three signals together (RHR↑, HRV↓, skin-temp↑);
the Mahalanobis distance accounts for how they normally co-vary — one honest scalar, not
three independent flags. **A signal, not a diagnosis.**
**How:** orient each feature toward illness (`dir·(x−μ)/σ`), build the baseline correlation
matrix, `D = √(zᵀ·C⁻¹·z)` (diagonal fallback if singular). Fires when `D > 2.5` **and** ≥2
features deviate in the illness direction. Needs ≥7 baseline days per feature. ESTIMATE.

### 18. Nocturnal heart — `calcNocturnalHeart`
**How:** sleeping-HR mean + nadir (lowest 5-min rolling mean); **dip % = (waking−sleeping)/
waking** (autonomic recovery — bigger is better); `elevated` when sleeping HR ≥ baseline+4 bpm
and ≥+5% (early under-recovery cue). HIGH for the measured numbers.

### 19. Sleep stress / arousal — `calcSleepStress`
**Why:** sympathetic activation during sleep (HR surges + movement) is the honest,
hardware-available proxy for restless/anxious nights — labelled "possible arousal", never
"nightmare".
**How:** an arousal event = a minute with `hr ≥ mean + max(8 bpm, 1.5·sd)` **and** movement;
consecutive surges collapse to one event. Score scales with events/hour + restless fraction.

### 20. RHR anomaly — `calcAnomaly`
**How:** fires when RHR ≥ baseline×1.07 for ≥2 consecutive trailing days, or (RHR↑ AND
temp Δ>+0.5 AND sleep-efficiency↓). Confidence ≤0.5. "Signal, not a diagnosis."

### 21. VO₂max — `calcVo2Max`
**Why:** a single, glanceable cardiorespiratory-fitness number. The Uth–Sørensen ratio is a
whole-population estimate from the simplest robust inputs we already have.
**How:** `VO₂max ≈ 15.3 · (HRmax / HRrest)` ml·kg⁻¹·min⁻¹, using the **measured** HRmax
(baseline) and resting HR. Abstains (`null`) unless a real HRmax exists and HRmax > HRrest —
the age-predicted 220−age would just re-encode age, so we don't fake it. ESTIMATE (conf 0.5).

### 22. Fitness / Fatigue / Form — `calcFitnessModel`
**Why:** the Banister impulse-response model is the standard "fitness vs fatigue" framing
(CTL/ATL/TSB in TrainingPeaks terms) — it turns the daily strain stream into where your form is.
**How:** two exponentially-weighted moving averages of daily strain — **Fitness (CTL)** with
time-constant τ≈42 d (`α=2/43`), **Fatigue (ATL)** with τ≈7 d (`α=2/8`); **Form = Fitness −
Fatigue** measured *before* today's strain (freshness coming into the day). Needs ≥7 days;
confidence ramps to full at ~42 days. ESTIMATE.

### 23. Training monotony — `calcMonotony`
**Why:** Foster showed that *sameness* of daily load (not just total) predicts overtraining/
illness — a companion to ACWR.
**How:** over the last 7 days, `monotony = mean(strain) / SD(strain)`; `training_strain =
weekly_load × monotony`. Needs ≥4 of 7 days. HIGH (deterministic from strain).

### 24. HRV stability — `calcHrvStability`
**Why:** a steady night-to-night RMSSD is itself a recovery signal; a rising spread flags
instability even when the mean looks fine.
**How:** coefficient of variation `CV = SD/mean × 100` of the recent nightly RMSSD series
(up to ~14 nights). Needs ≥5 nights. HIGH.

### 25. Irregular-beat screen — `calcIrregular`
**Why:** atrial-fibrillation-like irregularity shows up as very high beat-to-beat scatter and
a flood of ectopic/large successive differences. **A screen, not a diagnosis** — there's no
ECG here, so it's deliberately conservative and heavily caveated.
**How:** from the nocturnal RR, the **Poincaré** descriptors `SD1 = RMSSD/√2` and
`SD2 = √(2·SDNN² − ½·RMSSD²)`, plus the fraction of beats the artifact filter rejects as
ectopic/irregular. Flags only when that ectopic fraction > 0.20 **and** pNN50 > 30% **and**
SD1 > 60 ms, with ≥100 beats. ESTIMATE.

### 26. Readiness (composite) — `calcReadinessIndex`
**Why:** one morning number, but **transparent** — not a black box and not claiming to be
WHOOP's score. It blends the autonomic + sleep signals we already compute and ships its
component breakdown as drivers so the user sees exactly what moved it.
**How:** weighted mean (renormalized over present components) of **HRV recovery (0.5)** +
**sleep vs need (0.2)** + **nocturnal-dip→0..100 (0.15)** + **sleep-calmness = 100−arousal
(0.15)**. **Abstains (`null`) if HRV recovery is absent** — without the autonomic anchor the
rest is just sleep accounting. ESTIMATE. (Stored in the repurposed `daily.readiness` column;
the old heuristic readiness was retired.)

> **Workout breakdown extras** (HR drift, time-to-peak, the HR-recovery curve, cadence,
> wrist coverage, per-zone bpm bands) are derived on read in the **backend** (`workouts.ts`)
> from the session's minute window, not in this package — they're descriptive aggregates of
> the same inputs, not new physiology.

### 27. Steps — `calcSteps` / `pedometer` (`steps.ts`); runner `runStepsImu` (backend)
**Where:** the pure AN-2554 math (`pedometer`, `calcSteps`, calibration gain) lives here in the
analytics package like every other metric; the backend `steps_imu.ts` is a thin **runner** that
re-decodes the IMU frames from R2 (`frameAccel` in `decode.ts`), dedups + groups them per minute,
and feeds the signals to `calcSteps` — mirroring the HRV/resp runners.
**Why:** the WHOOP 4.0 exposes **no step counter** over Bluetooth (the official app computes
steps in the cloud from raw accelerometer + ML; even the most complete community client falls
back to phone steps on 4.0). So we derive them ourselves from the wrist accelerometer with
Analog Devices' **AN-2554** time-domain pedometer — ~97% accurate on steady wrist gait.
**How:** the high-rate IMU (~100 Hz) arrives on two live channels — **R10** (pkt 0x2B, 100
accel samples/axis) and the **0x33 IMU stream** (10 accel + 10 gyro samples/frame: X/Y/Z
contiguous from byte 24, frame-index @14, scale 1/4096 g) — re-decoded from the raw frames in
R2, **deduped by (ts, frame-index)** (upload windows overlap), assembled into a contiguous
per-minute signal. Per minute: `sum(|x|+|y|+|z|)` → 4-tap low-pass → centered **33-sample
window** max/min peak detection → a **dynamic threshold** (running mean of recent max/min
midpoints) with a **0.1 g sensitivity** dead-zone — a `max > thr+s/2` paired with a
`min < thr−s/2` is a *possible step*, and only after **8 consecutive** possible steps does it
start counting (the regularity gate that rejects waving/typing/handling — verified to read 0
at rest; lowering it re-introduces false positives). A per-device **calibration gain (×1.11)**
corrects the typical ~10 % wrist undercount, locked against a 100-step ground-truth walk (raw
90 → 100). ESTIMATE. **Steps only accrue while the strap is connected** (the IMU is live-only;
the historical 1 Hz record carries no usable IMU). Owned by the cron (hourly: today+yesterday;
nightly: 2 days), written to `daily.steps` *after* analytics so the IMU value is authoritative.
*(Implemented in the backend, not this package, but documented here as the algorithm of record.)*

---

## What we deliberately do **not** do
- **VO₂max is an ESTIMATE, clearly labelled** — the Uth–Sørensen HR-ratio (`calcVo2Max`),
  not a measured lab value, and it abstains without a real measured HRmax. We still never
  emit a *measured/lab* VO₂max claim.
- **No absolute skin-temp / SpO₂** — the band sends raw ADCs; we only ever show a deviation
  from the user's own baseline (`RELATIVE` tier).
- **Irregular-beat is a SCREEN, not a diagnosis** — no ECG; conservative thresholds, no
  medical claim.
- **Readiness is a transparent composite, not a black box** — documented weights, ships its
  drivers, and abstains without nocturnal HRV.
- **No fabricated values** — any metric without enough real data returns `null` + confidence
  `0`. Recovery/stress stay `null` until ≥5 nights of RR; Readiness/HRV-CV until HRV exists;
  fitness model until ≥7 days of strain; SRI until ≥3 nights.

## References
Banister 1991 · Morton/Fitz-Clarke/Banister, *J Appl Physiol* 1990 · Cole & Kripke, *Sleep*
1992 · Keytel et al., *J Sports Sci* 2005 · Phillips et al., *Sci Rep* 2017 · Cole/Lauer,
*NEJM* 1999 · Gabbett, *BJSM* 2016 · Hulin et al. 2016 · Task Force ESC/NASPE, *Circulation*
1996 · Laguna/Moody/Mark, *IEEE TBME* 1998 · Charlton et al., *Physiol Meas* 2016 · Plews
et al., *Sports Med* 2013 · Baevsky & Berseneva 2008 · Mahalanobis 1936 · Mishra et al.,
*Nat Biomed Eng* 2020 · Smarr et al., *Sci Rep* 2020 · Radin et al., *Lancet Digit Health*
2020 · Fox 1971 · Uth, Sørensen, Overgaard & Pedersen, *Eur J Appl Physiol* 2004 · Foster,
*Med Sci Sports Exerc* 1998 · Brennan, Palaniswami & Kamen (Poincaré HRV), *IEEE TBME* 2001 ·
Analog Devices, *AN-2554: Step Counting Using the ADXL367* 2023 · Zhao, "Full-Featured
Pedometer Design Realized with 3-Axis Digital Accelerometer," *Analog Dialogue* 2010.
