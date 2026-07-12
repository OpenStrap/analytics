# OpenStrap Analytics — Algorithms

Every metric here is a **published, peer-reviewed method**, computed by a **pure
deterministic function**, running on the 1 Hz substrate a WHOOP 4.0 actually exposes:
beat-to-beat RR (pulse-derived — this is **PRV, not ECG-HRV**, and that distinction
matters more than it sounds like it should), 1 Hz heart rate, 1 Hz tri-axial accel, and
relative-only ADC channels (skin temp, SpO2, ambient light).

This file is the index — what's implemented, where it lives, and who published it. If a
row here doesn't have a real citation next to it, that's a bug in this file, go fix it.

Almost everything returns a `Metric<T>` envelope:

```dart
class Metric<T> {
  final T? value;
  final double confidence;   // 0..1, computed from real input coverage
  final String tier;         // Tier.auth | .high | .estimate | .relative
  final List<String> inputs_used;
  final List<Driver>? drivers;
  final String? note;        // e.g. "need_baseline:have=3,need=7"
}
```

A few multi-day/list outputs (`illnessCusum`, `multivariateAnomaly`,
`journalCorrelations`) return a plain `List<T>` instead — there's no single
confidence/tier that applies across a whole list.

**Tiers**: `AUTH` = directly measured/definitional. `HIGH` = strong literature support on
this substrate. `ESTIMATE` = published, but estimate-grade once run on a wrist 1 Hz
signal instead of a lab setup. `RELATIVE` = meaningful only as a deviation from the
user's own baseline (skin temp, SpO2 — never an absolute unit).

**Absent input → `null` + confidence `0`, always.** A baseline-gated metric that doesn't
have enough history says so explicitly via the `need_baseline:have=H,need=N` note format,
rather than computing something on partial data and hoping nobody notices.

---

## Master table

Grouped by family (subdirectory under `lib/src/onehz/`). File paths are relative to that.

### `foundations/` — shared math every family builds on
| Function | File | Method |
|---|---|---|
| `correctRr` | `foundations/rr_correction.dart` | Lipponen & Tarvainen 2019 RR artifact correction (dRR/mRR/sRR beat classification, Kubios-style) |
| `Baselines` (Winsorized-EWMA) | `foundations/ewma_baselines.dart` | Winsorized exponentially-weighted moving baseline — the rolling personal reference most other metrics compare against |
| PPG signal-quality index | `foundations/ppg_sqi.dart` | Skewness-based SQI |
| inverse-variance fusion | `foundations/fusion.dart` | Standard inverse-variance weighting for combining multiple noisy estimates of the same quantity |

### `clinical/` — Tier-1 cardiac/autonomic metrics
| Function | File | Method | Citation |
|---|---|---|---|
| `hrvTime` | `clinical/hrv_time.dart` | RMSSD/SDNN/pNNx | standard time-domain HRV |
| `nocturnalRmssd` | `clinical/hrv_time.dart` | median-of-5-min-window nightly RMSSD | — |
| `sleepSessionWindowedRmssd` | `clinical/hrv_time.dart` | mean-of-5-min-window RMSSD with Malik ectopic rejection | Malik et al. |
| `hrvFreq` | `clinical/hrv_freq.dart` | LF/HF via Lomb-Scargle periodogram on native (unevenly-sampled) beat times | Laguna, Moody & Mark 1998; Bigger 1992 |
| `decelerationCapacity` / `accelerationCapacity` | `clinical/prsa.dart` | Phase-rectified signal averaging (DC/AC) | Bauer et al. 2006 |
| `nocturnalRhr` / `hrDip` | `clinical/nocturnal.dart` | nocturnal resting HR + dip classification | — |
| `illnessCusum` | `clinical/illness_cusum.dart` | Online CUSUM state machine (green/yellow/red) over RHR — "NightSignal" | Alavi et al. 2022; Mishra et al. 2020 |
| `readinessLnRmssd` | `clinical/readiness_lnrmssd.dart` | ln(RMSSD) z-scored against a rolling prior-nights baseline | Plews et al. 2013 |
| `cosinor` | `clinical/cosinor.dart` | Cosinor rhythmometry (MESOR/amplitude/acrophase) | Halberg & Nelson 1979 |
| `banisterTrimp` / `edwardsTrimp` | `clinical/load_trimp.dart` | Training impulse from HR-reserve | Banister 1991; Edwards 1993 |
| `strainScoreMetric` | `clinical/load_trimp.dart` | log-squash of TRIMP onto a 0-21 scale | — |
| `trimpStrain` | `clinical/load_trimp.dart` | TRIMP → 0-100 strain, honesty-wrapped (absent without real HRmax/RHR anchors) | — |
| `ctlAtlTsb` | `clinical/load_trimp.dart` | Fitness-Fatigue-Form: EWMA CTL (42d) / ATL (7d) / TSB = CTL-ATL | Banister impulse-response model |
| `baevskyStressIndex` | `clinical/stress_si.dart` | Baevsky Stress Index, 5-min sliding RR-histogram | Baevsky & Berseneva 2008 |
| `irregularBeatScreen` | `clinical/irregular_rhythm.dart` | Poincaré SD1/SD2 + pNN70 irregular-rhythm screen | — (screen, not a diagnosis; no ECG) |
| `cardiacCoherence` | `clinical/cardiac_coherence.dart` | peak-band vs. remaining spectral power ratio, live RR during guided breathing | McCraty & Zayas 2014; McCraty et al. 2009 |

### `sleep/` — staging, structure, circadian
| Function | File | Method | Citation |
|---|---|---|---|
| `vanHeesSleepWindow` | `sleep/van_hees.dart` | z-angle sleep/wake window detection | van Hees et al. |
| `segmentSleep` (`SleepSegmentation`) | `sleep/segment.dart` | **single source of truth** for sleep windowing; delegates staging to `cardioStager` |
| `cardioStager` | `sleep/cardio_stager.dart` | Webster/Cole-Kripke actigraphy + HRV fusion — explicitly replaces Walch 2019 (documented WAKE over-call bias) |
| `AdvancedSleepStager` | `sleep/advanced_stager.dart` | AASM-style 4-class staging + hypnogram metrics (TIB/TST/SOL/WASO/REM-latency); `StagingMethod.cardio` is the wired production default, v1/v2 kept for regression coverage only |
| `sleepAccounting` | `sleep/accounting.dart` | TIB/TST/WASO/efficiency accounting | — |
| `cardiopulmonaryCoupling` | `sleep/cpc.dart` | cardiopulmonary coupling | — |
| `sleepCyclesMetric` | `sleep/cycles.dart` | fractal ultradian sleep-cycle detection | Rosenblum et al. 2024 |
| `circadianNonparametric` | `sleep/circadian_np.dart` | IS/IV/RA/L5/M10 nonparametric circadian indices | — |
| `phillipsSri` | `sleep/sri.dart` | true Phillips epoch-agreement Sleep Regularity Index | Phillips et al. 2017 |

### `respiration/`
| Function | File | Method | Citation |
|---|---|---|---|
| `rsaRespRate` | `respiration/resp_rate.dart` | respiratory sinus arrhythmia — HF spectral peak of the RR series | — |
| `riivRespRate` / `fuseRespRate` | `respiration/resp_rate.dart` | respiration-induced intensity variation, fused with the RSA estimate | Pimentel et al. (multi-grid RIIV fusion) |
| `cvhrApnea` / `cvhrApneaScreen` | `respiration/cvhr_apnea.dart` | cyclic-variation-in-HR apnea screening | — |
| `relativeOdi` | `respiration/relative_odi.dart` | ratio-of-ratios relative desaturation index — **never an absolute SpO2 claim** | — |
| `breathingRateVariability` | `respiration/brv_trend.dart` | within-user breathing-rate variability trend | — |

### `motion/`
| Function | File | Method | Citation |
|---|---|---|---|
| `relativeIntensityBands` | `motion/enmo.dart` | ENMO/MAD activity intensity bands | — |
| `staticTilt` | `motion/orientation.dart` | orientation/posture from gravity vector | — |
| `branchedEnergyFusion` | `motion/energy_fusion.dart` | HR-anchored-when-possible energy expenditure fusion | Brage et al. 2004 |
| `dailyStepEstimate` | `motion/steps.dart` | 1 Hz fallback step estimate — ENMO+HR gated, bout-length gated (contiguous-run requirement), only for minutes the live 100 Hz pedometer didn't cover | AN-2554-adjacent (see `livePedometer` for the real 100 Hz method) |

### `workout/`
| Function | File | Method | Citation |
|---|---|---|---|
| `detectWorkouts` | `workout/workout_detect.dart` | explicit workout detection + zones | — |
| `autoDetectWorkouts` | `workout/auto_detect.dart` | automatic workout detection | — |
| `hrRecovery` | `workout/hr_recovery.dart` | HRR — HR drop N seconds post-peak | Cole/Lauer 1999-style HRR |
| `Calories.dailyEnergy` / `estimateBoutCalories` | `workout/calories.dart` | Keytel HR→kcal regression + Harris-Benedict/Mifflin BMR | Keytel et al. 2005 |

### `wellness/`
| Function | File | Method | Citation |
|---|---|---|---|
| `readinessComposite` | `wellness/readiness_composite.dart` | **canonical headline readiness** — transparent weighted blend (HRV > RHR > RR > temp), Hopkins SWC gate | Hopkins 2004 (smallest worthwhile change) |
| `multivariateAnomaly` | `wellness/anomaly.dart` | Mahalanobis distance + chi-square significance across RHR/HRV/temp/resp | Mahalanobis 1936 |
| `segmentChangePoints` | `wellness/changepoint.dart` | CUSUM changepoint detection | Killick et al. 2012 |
| `tempCircadian` | `wellness/temp_circadian.dart` | temperature + circadian composite | — |
| `tempIllnessFlag` (see `temp_health.dart`) / `menstrualCoverline` | `wellness/temp_health.dart` | temperature-based illness flag; cycle-aware ovulation coverline | — |

### `human/`
| Function | File | Method | Citation |
|---|---|---|---|
| `sleepRegularityIndex` | `human/sleep_regularity.dart` | SRI (see also `phillipsSri` above) | Phillips et al. 2017 |
| `sleepDebt` | `human/sleep_regularity.dart` | accumulated sleep debt vs. need | — |
| `socialJetlag` / `chronotype` | `human/circadian_lifestyle.dart` | MSFsc-based social jetlag + chronotype | Wittmann & Roenneberg 2006; MCTQ |
| `alcoholNightFlag` | `human/event_detection.dart` | dose-graded autonomic-stress signature — **reports state, never asserts a cause** | Pietilä et al. 2018 |
| `roughNight` | `human/event_detection.dart` | neutral fallback descriptor when the signature is ambiguous | — |
| `percentileOfYou` / `personalRecord` | `human/percentile_of_you.dart` | percentile-vs-your-own-history, miss-tolerant personal-record streaks | — |
| `glassBoxReadiness` | `human/readiness_glassbox.dart` | **deprecated** — kept only for its percentile-of-you breakdown + narrative and edge back-compat; `readinessComposite` is canonical | — |
| `vo2maxEstimate` / `physiologicalAge` / `sleepNeed` / `strainTarget` / `recommendedBedtime` / `recommendedWake` / `sleepPerformance` / `detectNaps` | `human/coaching.dart` | deterministic coaching layer over the metrics above | Uth-Sørensen-style HR-ratio VO2max estimate (still `ESTIMATE`, never a lab claim) |
| `journalCorrelations` | `human/coaching.dart` | per-tag mean-difference correlation vs. logged outcomes, on-device, personal | — |

---

## What this deliberately doesn't do
- No absolute SpO2/skin-temp — raw relative ADC counts only, ever (`RELATIVE` tier).
- No cause-naming — a signature ambiguous between alcohol/late meal/illness/luteal
  phase/hot room reports the *state*, never asserts which one it is.
- Irregular-rhythm is a screen, not a diagnosis — no ECG here, conservative thresholds,
  explicit non-medical framing.
- VO2max/physiological-age stay `ESTIMATE` — HR-ratio-style approximations, never
  presented as something a lab measured.
- No fabricated values. Ever. A metric without enough real data returns `null` +
  confidence `0`, with a machine-readable note saying exactly what's missing.

## References (non-exhaustive — see each file's own doc comment for the specific citation)
Lipponen & Tarvainen 2019 · Laguna, Moody & Mark 1998 · Bigger 1992 · Bauer et al. 2006 ·
Alavi et al. 2022 · Mishra et al. 2020 · Plews et al. 2013 · Halberg & Nelson 1979 ·
Banister 1991 · Edwards 1993 · Baevsky & Berseneva 2008 · McCraty & Zayas 2014 · McCraty,
Atkinson, Tomasino & Bradley 2009 · van Hees et al. · Rosenblum et al. 2024 · Phillips et
al. 2017 · Pimentel et al. · Brage et al. 2004 · Keytel et al. 2005 · Hopkins 2004 ·
Mahalanobis 1936 · Killick et al. 2012 · Wittmann & Roenneberg 2006 · Pietilä et al. 2018 ·
Malik et al.
