# 1 Hz-Native Algorithm Catalog (non-ML)

Synthesized from 6 independent literature reviews (HRV, cardiac, sleep/circadian, respiration/SpO₂, motion, temp/fusion-anomaly). Every method is **deterministic / statistical / signal-processing / clinical — no ML**. Each is tagged by the signal it needs, whether it runs **24/7** (flash 1 Hz substrate) or **FG** (foreground high-rate only), and a confidence tier.

## The substrate (what feeds these)
**24/7 @ 1 Hz** (always, incl. overnight): HR; **beat-to-beat RR (0–4/s, ms)**; tri-axial accel (one vector/s); PPG green/red/IR ADC; relative SpO₂ red/IR ADC; relative skin-temp ADC; ambient light; skin-contact quality.
**Foreground only** (high rate, app streaming): accel ~100 Hz; gyro ~100 Hz (±2000 dps); optical PPG waveform ~419 Hz.

## The structural edge
**Continuous 24/7 beat-to-beat RR.** Most wearables only get RR in brief spot-checks; we have it all night, every night. This alone unlocks an entire class of Holter-grade methods (24-h SDNN, ULF/VLF spectra, PRSA deceleration capacity, autonomic cosinor) that spot-check devices physically cannot compute.

## The honesty ceilings (carry into UI copy)
1. **PRV, not ECG-HRV** — pulse-rate variability; validate before any clinical claim.
2. **1 Hz timing quantization** biases successive-difference metrics (RMSSD, pNNx) and the HF band most → lead with long-window/averaging metrics.
3. **1 Hz accel can't do steps/cadence/gait/frequency-classification** (Nyquist: gait is 1.4–2.5 Hz > 0.5 Hz limit). Only an amplitude index + static orientation survive 24/7.
4. **Relative signals**: no absolute SpO₂ %, no absolute °C / fever — only deviations, dips, trends vs personal baseline.
5. **Sleep staging** from wrist is at best a 3-class autonomic *estimate*, never PSG 4-stage.
6. **ACWR** is descriptive ("load vs your norm") only — not injury prediction (Lolli 2019 / Impellizzeri 2020).

---

## LAYER 0 — Foundations (everything depends on these; build first)

| Engine | Method + citation | Feeds |
|---|---|---|
| **RR artifact correction** | Lipponen & Tarvainen 2019 dRR detector (Kubios auto). Cubic-spline isolated beats; **flag-and-drop multi-beat runs, never interpolate** (Peltola 2012). | All HRV/RR, CVHR, PRSA, RSA-respiration |
| **PPG signal-quality gate** | Elgendi 2016 skewness-SQI (cheap, 1 Hz-OK) + Orphanidou 2015 physiological-range rules. Template-matching = FG only. | All PPG/SpO₂/resp |
| **Robust personal baseline** | median + MAD (Leys 2013; Iglewicz-Hoaglin mod-z, flag |M|>3.5); clamped, gap-aware **EWMA** (Roberts 1959, λ↔half-life); coverage-gate ≥3/7 valid (Plews 2014); surface change only beyond **SWC & TE** (Hopkins 2000). Guard MAD=0 on quantized data. | Every anomaly/readiness/trend |
| **Honest fusion / uncertainty** | Inverse-variance fusion (Aitken 1935) weighted by the **contact-quality/SNR channel**; GUM uncertainty propagation for confidence bands. **Gate biased PPG motion artifact OUT, don't just down-weight.** | Readiness, any multi-signal index |

---

## LAYER 1 — 24/7 build-first (the always-on core)

### Cardiac / autonomic (HR + RR)
- **Nocturnal RHR** — lowest-30-min mean + 1st-percentile (Avram 2019; Dial 2025). *Spine for illness/dip/load.* `24/7 · HIGH`
- **lnRMSSD nightly + Plews/Kiviniemi readiness stack** — 7-day rolling mean, CV, SWC, z-score; LnRMSSD:RR saturation guard (Plews 2013/2014). Our whole-night baseline beats the morning-read baseline the literature is stuck with (Nuuttila 2022, ICC 0.91–0.98). `24/7 · HIGH (PRV)`
- **PRSA Deceleration Capacity (+AC)** — Bauer 2006. **Mortality-grade**, noise-robust by averaging thousands of anchors; tiers DC ≤2.5 / 2.6–4.5 / >4.5 ms. Our long all-night RR is exactly its substrate. `24/7 · HIGH`
- **Lomb-Scargle 24-h spectrum** → ULF/VLF/LF/HF/LF-HF/nu (Laguna 1998; Bigger 1992). Use **native beat times, not FFT-on-resampled**. Gate HF on artifact fraction. Nightly cloud/heavy batch. `24/7 · HIGH (low bands), MED (HF)`
- **24-h SDNN + SDANN/SDNN-index** — jitter-immune (operate on 5-min means). `24/7 · HIGH`
- **Nocturnal HR dip %** / night-day ratio (dipper/non-dipper/riser) — CV-risk + acute-strain signal. `24/7 · HIGH`
- **NightSignal FSM + CUSUM/EWMA on RHR** — Alavi 2022 / Mishra 2020 (28-day baseline, designed ARL, yellow→red persistence). Best wearable-validated deterministic illness alarm. `24/7 · HIGH`
- **TRIMP (Edwards + Banister) + CTL/ATL/TSB** — Edwards 1993 / Banister; Morton 1990. Needs measured HRmax + RHR. Guard non-wear gaps. `24/7 · HIGH`

### Sleep & circadian (accel + HR + RR + temp + light)
- **van Hees / GGIR angle sleep-window** — 2015/2018. Count-FREE, gravity-orientation @1 Hz is ample. **THE sleep/wake spine** (sidesteps the Cole-Kripke count-calibration trap). `24/7 · HIGH`
- **True Phillips SRI** — epoch-by-epoch 24-h concordance (Phillips 2017), NOT SD-of-midsleep. `24/7 · HIGH`
- **Cardiopulmonary Coupling (CPC)** — Thomas 2005; RR + RSA/RIIV respiration surrogate (substitute for EDR). Sleep-stability spectrogram + apnea-risk; plays to continuous RR. `24/7 · MED-HIGH`
- **3-class autonomic stager (wake/NREM/REM)** + HR-dip onset, REM gated by 1 Hz immobility. Never claim N1/N2/N3. `24/7 · MED (honesty-bounded)`
- **Sleep accounting** — onset/offset, WASO, TST, efficiency, NREM-REM cycles (~90 min from CPC/autonomic). `24/7 · HIGH`

### Respiration & SpO₂ (PPG + RR)
- **RSA respiratory rate from RR** — Lomb-Scargle HF-peak; Pimentel 2017 AR-order robustness. *Primary 24/7 respiration source.* `24/7 · HIGH`
- **RIIV respiratory rate** — band-pass 0.1–0.5 Hz on 1 Hz green ADC; fuse with RSA via Karlen SD-gate. `24/7 · MED`
- **CVHR / ACAT apnea screen** — Hayano 2011. RR-only, r≈0.84 vs AHI, zero calibration. Screen, not diagnosis; report night-to-night variability. `24/7 (run on RR) · HIGH for screening`
- **Relative-R index + relative ODI** — ratio-of-ratios as rolling AC/DC (TI SLAA655); self-referential dip-count desaturation event rate. **Never display %SpO₂.** `24/7 · MED (relative only)`
- **Breathing-rate variability (BRV)** trend. `24/7 · MED`

### Motion / energy (1 Hz accel + HR)
- **ENMO + MAD per-minute motion index** — van Hees 2013 / Vähä-Ypyä 2015. Foundational 24/7 amplitude index (auto-calibrate the 1 g reference). Intensity **bands** are relative, not absolute METs. `24/7 · HIGH (index), MED (intensity)`
- **Static gravity-tilt orientation → sleep position** — supine/prone/lateral during low-motion epochs. Wrist orientation is a body-position *proxy*. `24/7 · HIGH`
- **Branched HR-accel energy fusion** — Brage 2004 (we have both inputs @1 Hz). Quantitative only with per-user HR calibration, else strong relative EE curve. `24/7 · MED`

### Temperature / multi-signal
- **Wrist circadian-temp: cosinor + IS/IV/RA/L5/M10** — Sarabia/Madrid 2008. Best-matched to our relative single-site sensor; no calibration. **Antiphase to core** — de-mask with activity/ambient. `24/7 · MED-HIGH (phase only)`
- **Skin-temp z-score illness flag** — Smarr 2020 (relative, personal baseline). **Must be cycle-aware** (luteal +0.3 °C ≈ fever). Fuse, don't trust alone. `24/7 · MED`
- **Menstrual 3-over-6 / coverline** on nightly-mean temp — Shilaih 2018 (wrist, ~0.33 °C). Retrospective ovulation *confirmation* only, never forward prediction. `24/7 · MED`
- **Honest readiness composite** — per-metric percentile/z to personal baseline → sign-orient → weighted sum (HRV>RHR>RR>temp) → SWC/TE gate. Reweight on missing inputs, don't zero. `24/7 · MED`
- **Change-point**: PELT-MBIC weekly retro review (Killick 2012, min-seg ≥7 d) + BOCPD online with heavy-tailed predictive (Adams-MacKay 2007). `24/7 · MED`

### Shared cross-cutting engines (implement once, reuse everywhere)
- **Cosinor + nonparametric circadian (IS/IV/RA/L5/M10)** — one engine, applied to HR, ENMO activity, skin-temp, and each HRV index.
- **CUSUM/EWMA SPC** — one anomaly engine, run per-signal (RHR, HRV, temp, RR).
- **Lomb-Scargle PSD** — shared by HRV spectrum and RSA-respiration.
- **PRSA** — shared by autonomic DC and apnea-periodicity.

---

## LAYER 2 — Foreground-only (live spot-check tier, high-rate accel/gyro/PPG)
- **Karlen Smart-Fusion RR** (RIIV+RIAV+RIFV, 419 Hz PPG) — reference-grade spot breathing rate.
- **Autocorrelation cadence + step/stride regularity & symmetry** (Moe-Nilssen 2004) — robust gait.
- **AN-2554 / windowed peak-detection step counter** (100 Hz accel) — gate to ambulation; wrist over/under-count caveats (Tudor-Locke).
- **Madgwick / Mahony quaternion orientation** — limb tracking during workouts.
- **Frequency-domain activity typing** (dominant freq + spectral entropy, Wang 2009) — walk/run/cycle.
- **DFA-α1 aerobic threshold** (Rogers 2020) — needs RR at <3% artifact; best on clean foreground/rest reads.
- **Lázaro pulse-decomposition RR / pulse-width** (419 Hz) — spot breathing-pattern.

---

## DO NOT SHIP (infeasible or refuted on our data)
- Absolute SpO₂ % / absolute °C fever (relative signals).
- 1 Hz step counts / cadence / gait / frequency activity classification (Nyquist).
- Cole-Kripke / Sadeh / Oakley raw coefficients on 1 Hz (count-calibration invalid; ZCM aliased away) — use van Hees + recalibrated ENMO surrogate.
- ACWR/EWMA-ACWR as injury prediction (Lolli/Impellizzeri) — descriptive only.
- Heart-rate turbulence (needs ECG PVCs); ApEn (use SampEn); MSE/TINN/pNNx (data-hungry or jitter-collided); EPOC & Keytel-at-rest (estimate-only); Cole/Lauer absolute HRR cut-points (use personal τ trend); Rosenblum fractal cycles as-published (needs EEG — borrow the segmentation idea); DLMO (not measurable — report phase estimate).

## Tier-1 unified build order (clinical core)
1. Foundations (RR-correction, PPG-SQI, robust baseline, fusion).
2. Nocturnal RHR → NightSignal/CUSUM illness; van Hees sleep window → SRI/WASO.
3. lnRMSSD readiness stack + PRSA-DC + Lomb-Scargle 24-h spectrum (the RR structural edge).
4. ENMO motion index + gravity-tilt sleep position; RSA + RIIV respiration; CVHR apnea screen.
5. Cosinor/IS-IV-RA circadian (HR/activity/temp); relative-ODI; menstrual coverline; readiness composite; TRIMP/CTL-ATL-TSB.

---

# THE HUMAN LAYER (everyday, behavior-changing insights)

The clinical core computes *metrics*; this layer turns them into things a regular person cares about. Mostly recombination of the same primitives into honest narratives, plus a few genuinely-published lifestyle methods. Tag: **[PUB]** = published/validated; **[HEUR]** = grounded deterministic heuristic (not itself validated).

## Governing honesty rules (apply to every item)
- **Report STATE confidently, CAUSE only as a tag-confirmable hypothesis.** Alcohol / late meal / illness / luteal phase / hot room produce a near-identical nocturnal signature (RHR↑, RMSSD↓, dip blunted, temp↑). Disambiguate by **persistence, periodicity, and the temp+resp-rate pair** — not HR shape. When ambiguous, fall back to a neutral "rough night" description or stay silent.
- **MDC-gate everything** — surface a change only when |Δ| > the metric's minimal detectable change (HRV day-noise ≈ 10–25%+). The willingness to say nothing is the credibility signal.
- **Within-user, not population** — percentile-of-you, robust baselines (median+MAD); no leaderboards for sensitive metrics.
- **Never print numbers the sensor can't support** — no melanopic lux, no absolute SpO₂%/°C, no emotional valence, no absolute MSFsc minutes. Direction/ranges/percentiles only.
- **Anchor all circadian phase on the nocturnal HR/temp trough**, never the daytime peak (exercise confounds it).
- **PRV not ECG-HRV**; **"—" when data absent**, never imputed; every score carries its "why."

## A. Behavioral / circadian lifestyle (24/7)
- **Social jetlag / weekend drift** [PUB, Wittmann/Roenneberg 2006] — `SJL=|MSF−MSW|`; "your weekend runs 2 h later — like flying 2 zones west." *Strongest, lowest-risk, purely behavioral. Ship first.*
- **Sleep Regularity Index + forgiving streaks** [PUB, Phillips 2017; beat duration for mortality, Windred 2023] — `SRI=200·(agreement/cases)−100`. Show vs personal history, grace days.
- **Chronotype label** [PUB MSFsc; HEUR HR-acrophase] — "moderate evening type"; gate ≥14 days w/ ≥2 free days; percentile-of-you for stability.
- **Sleep debt vs personal need** [PUB, Kitamura 2016] — OSD from rebound on unconstrained nights; replaces the "8 hours" trope; honest when no free night yet.
- **Nap detection + quality** [HEUR detect; PUB length guidance] — HR-floor + sustained immobility *together* (kill false positives — stillness ≠ sleep); 10–26 min good, >30 min inertia, late/long erodes tonight.
- **"Your best hours"** [PUB two-process structure; HEUR personalization] — peak ≈ wake+4–7 h, dip ≈ wake+8–9 h; present as ranges, don't over-claim cognition.
- **"You went to bed too late" / wind-down** [PUB Kräuchi DPG→onset; HEUR single-site wrist temp] — body-ready time (HR drop + HRV rise + distal-temp rise) vs actual onset. *Preachiness landmine — frame as "runway left," suppress after social nights.*
- **Jet-lag tracker** [PUB re-entrainment rates ~1 h/day E, ~1.5 h/day W; HEUR acrophase-drift meter] — progress bar + soft ETA; noisy first 2 days.
- **Light hygiene** [PUB targets Brown 2022; HEUR wrist] — **timing/direction only** ("got morning light? evening much brighter than baseline?"), never absolute lux (photopic wrist ≠ melanopic eye).

## B. Acute-event / substance detection (24/7) — state confident, cause soft
- **Alcohol-night flag** [PUB, Pietilä 2018 dose-graded: HR +1.4/+4.0/+8.7 bpm, RMSSD −2/−5.7/−12.9 ms, recovery −9/−24/−39 pts] — *strongest detector.* Single-night signature; report state confidently, "alcohol" as tag-confirmable. *Ship.*
- **Illness onset / "take it easy"** [PUB, Mishra/Snyder 2020 RHRAD+CUSUM, 63% pre-symptom] — gate behind **multi-night persistence + ≥2 of {RHR↑,temp↑,resp↑} + cycle-awareness.** Dangerous if ungated.
- **Daytime stress load via aHR** [PUB, aHR = HR − accel-predicted HR, adj R²=0.76] — ship the **daily aggregate/longest-stretch trend**, never pinpoint minutes (episode precision ~0.31). Valence (stress vs excitement) NOT recoverable — never assert.
- **Sauna / cold-plunge** [PUB physiology; HEUR detect] — HR↑ + temp↑ + motion≈0 (sauna) / abrupt temp↓ (plunge); sharp edges separate from fever. Label "thermal exposure," relative temp.
- **Orthostatic stand-ΔHR trend** [PUB POTS ≥30 bpm as outlier flag] — stand transition from accel; ship as personal trend nudge (hydration/recovery), never diagnosis.
- **Caffeine / late-meal** [PUB mechanism; HEUR detect] — **tag-only / low-confidence** (confound with everything; weak objective wearable effect).
- **"Rough night" descriptor** [HEUR] — the safe fallback whenever attribution fails; describes, never diagnoses.
- **Intimate activity** — **do NOT detect or surface, by default, ever** (privacy; frequently wrong).

## C. Real-time interactive (foreground) — motion-gated, within-user only
- **Resonance-frequency breathing biofeedback** [PUB, Lehrer/Vaschillo 2000] — RF assessment (4.5–6.5 br/min) + live peak-valley RSA bar. *Grade A, daily-habit hook. Ship first of this group.*
- **Morning spot-HRV / readiness check** [PUB ultra-short RMSSD, Munoz 2015] — deliberate 60–180 s seated 419 Hz read; the device's *best* HRV (beats passive overnight); within-device trend only.
- **Honest "coherence" game** [PUB signal] — reframe HeartMath as resonance RSA ("your heart is following your breath"); strip the heart-brain-coherence mysticism (Billman 2013).
- **Meditation effectiveness delta** [PUB physiology; HEUR composite] — paired pre/post RMSSD/HR on matched windows.
- **Live workout: cadence + zones + HRR** [PUB autocorr cadence RRACE; ACSM zones; HRR] — motion-based → PPG-robust; flag PPG-HR unreliability under hard motion.
- **Active stand test** [PUB 30:15 ratio ≥1.04] — gyro-anchored transition; trend (PPG jitter degrades absolute).
- **Breath-hold game** [PUB diving reflex] — relative SpO₂ droop + bradycardia; **never absolute %**.
- Defer (over-claimable): flow/focus timer, Valsalva ratio.

## D. Self-quantification / narrative (24/7) — glass-box only
- **Percentile-of-you + records + streaks** [PUB order-statistics] — n-of-1, no validity exposure, instantly motivating. Gate records by MDC; prefer aggregates over single-night bests. *Ship first of this group.*
- **MDC-gated nudging** [PUB reliability] — the credibility backbone; silence budget; suppress during illness/travel.
- **Glass-box Readiness 0–100** [PUB HRV centrality; HEUR weighting] — personal-percentile inputs (HRV>RHR>RR>temp) → always show the per-input breakdown + "why."
- **Deterministic narrative (NOT LLM)** [HEUR, standard decomposition] — rank drivers by standardized deviation `|w_i·z_i|`; "why" is *definitional within the formula you control* (correct for the score, not an inferred cause). Only name a driver past its MDC.
- **Trend + change-point** [PUB Theil-Sen + Mann-Kendall + CUSUM/PELT] — on smoothed aggregates only; require significance (don't celebrate regression-to-mean).
- **Fitness age** [PUB norms: VO₂max Uth/Tanaka, HRV Nunan 2010] — **VO₂max-based only, ± band, name the driver**; never a clinical vascular-age claim (no lipids/BP).
- **Energy / body-battery** [PUB TRIMP; HEUR construct] — drain (TRIMP) vs recharge (sleep/HRV); honest that it's a relative budget (TRIMP over-drains long low-intensity → cap), not EPOC/joules.
- **Smart-alarm wake window** [PUB sleep-inertia rationale] — wake in light sleep (rising HR/movement) within a 20–30 min window; "wakes you in light sleep," not clinical staging.
- **Stress-resilience (recovery slope)** [HEUR] — τ of HRV return to baseline after a stressor; novel n-of-1, honest (a measured slope).
- **Year-in-review retrospective** [HEUR aggregation] — "Wrapped for your body": your own curves + change-points.

## Human-layer ship-first (delight ÷ effort, honesty-weighted)
1. **Social jetlag** + **SRI/streaks** — validated, behavioral, instantly relatable, low risk.
2. **Percentile-of-you + MDC-gated nudging** — credibility backbone; trivial compute.
3. **Alcohol-night flag** + **illness "take it easy"** (gated) — highest-value event detection.
4. **Resonance breathing** + **morning spot-HRV** — the daily-habit interactive hooks.
5. **Glass-box Readiness + deterministic narrative** — turns the clinical core into a trusted daily story.
6. **Chronotype, "best hours", nap detection** — high delight; gate on data sufficiency; kill nap false positives.
7. Careful/last: wind-down nudge (preachy), light hygiene (timing-only), fitness age (± band).
