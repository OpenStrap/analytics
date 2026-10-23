# OpenStrap Analytics — Algorithms

This index includes published methods and internal rules. Unpublished rules are
identified below as ESTIMATE with low confidence. Computations are pure and
deterministic, running on the 1 Hz substrate a WHOOP 4.0 actually exposes:
beat-to-beat RR (pulse-derived — this is **PRV, not ECG-HRV**, and that distinction
matters more than it sounds like it should), 1 Hz heart rate, 1 Hz tri-axial accel, and
relative-only ADC channels (skin temp, SpO2, ambient light).

This file is the index — what's implemented, where it lives, and who published it. If a
row describes an internal rule, its component citations support only those components.

See `docs/ALGORITHM_CATALOG_1HZ.md` for the underlying literature review and what's
deliberately not shipped.

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
this substrate. `ESTIMATE` = estimate-grade on a wrist 1 Hz signal, or an internal rule without
published validation. `RELATIVE` = meaningful only as a deviation from the
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
| `correctRr` | `foundations/rr_correction.dart` | Lipponen & Tarvainen 2019 RR artifact correction (dRR/mRR/sRR classification); Peltola 2012 correction policy; unpublished artifact-run cap is an internal rule, ESTIMATE with low confidence |
| `Baselines` (Winsorized-EWMA) | `foundations/ewma_baselines.dart` | Winsorized exponentially-weighted moving baseline — the rolling personal reference most other metrics compare against |
| inverse-variance fusion | `foundations/fusion.dart` | Standard inverse-variance weighting for combining multiple noisy estimates of the same quantity |

### `clinical/` — Tier-1 cardiac/autonomic metrics
| Function | File | Method | Citation |
|---|---|---|---|
| `hrvTime` | `clinical/hrv_time.dart` | RMSSD/SDNN/pNNx | Task Force 1996 |
| `nocturnalRmssd` | `clinical/hrv_time.dart` | median-of-5-min-window nightly RMSSD | — |
| `sleepSessionWindowedRmssd` / `sleepSessionRmssdDetail` | `clinical/hrv_time.dart` | mean-of-5-min-window RMSSD; windows need ≥ 20 clean successive differences (ultra-short RMSSD literature); Malik 20 % ectopic rejection | Malik et al.; Munoz et al. 2015; Baek et al. 2015 |
| `rrCoverage` | `clinical/hrv_time.dart` | Σ plausible RR ÷ wall-clock span; > 1.10 means duplicated or interleaved beats, and `hrvTime` / `nocturnalRmssd` / `nightHrvShape` / the sleep-session headline refuse RMSSD; the headline also drops any 5-min window holding more beat-time than its length | — (integrity check; contiguous runs measure 0.963–1.001) |
| `hrvFreq` | `clinical/hrv_freq.dart` | LF/HF via Lomb-Scargle periodogram on native (unevenly-sampled) beat times | Laguna, Moody & Mark 1998; Bigger 1992 |
| `decelerationCapacity` / `accelerationCapacity` | `clinical/prsa.dart` | Phase-rectified signal averaging (DC/AC) | Bauer et al. 2006 |
| `nocturnalRhr` / `hrDip` | `clinical/nocturnal.dart` | nocturnal resting HR + internal HR-dip classification rule, ESTIMATE with low confidence | Avram 2019; Dial 2025 support nocturnal RHR only; HR-dip bands are unvalidated |
| `illnessCusum` | `clinical/illness_cusum.dart` | Online CUSUM state machine (green/yellow/red) over RHR — "NightSignal" | Alavi et al. 2022; Mishra et al. 2020 |
| `readinessLnRmssd` | `clinical/readiness_lnrmssd.dart` | ln(RMSSD) z-scored against a rolling prior-nights baseline | Plews et al. 2013 |
| `cosinor` | `clinical/cosinor.dart` | Cosinor rhythmometry (MESOR/amplitude/acrophase) | Halberg & Nelson 1979 |
| `banisterTrimp` | `clinical/load_trimp.dart` | Training impulse from HR-reserve | Morton, Fitz-Clarke & Banister 1990; sex-specific coefficients retained from Banister 1991 |
| `dailyQuietWakingHrr` | `clinical/load_trimp.dart` | one day's quiet-waking level: median per-minute %HRR over waking minutes; null above 40 % HRR | Karvonen 1957; ACSM moderate-intensity floor |
| `personalQuietWakingHrr` | `clinical/load_trimp.dart` | THIS user's quiet-waking level: median of the trailing 28 prior days' `dailyQuietWakingHrr`; abstains (need_baseline) below 3 days, "calibrating" below 7 | — |
| `netTrimpAboveQuiet` | `clinical/load_trimp.dart` | Banister TRIMP above the quiet level, split at 40 % HRR so quiet minutes never offset exercise minutes (living block floored at 0) | Banister 1991; Morton 1990; ACSM 40 % HRR |
| `strainScoreFromSeries` | `clinical/load_trimp.dart` | **the headline 0-21 strain** from per-minute wake HR: `netTrimpAboveQuiet` log-mapped onto 0-21 | — |
| `strainCurveFromSeries` | `clinical/load_trimp.dart` | cumulative 0-21 strain per minute, same arithmetic; last point == headline | — |
| `strainScoreMetric` | `clinical/load_trimp.dart` | LUMP form (TRIMP minus wake-minutes × quiet cost) log-squashed onto 0-21; can debit exercise, kept only for rescaling a stored TRIMP with no per-minute series | — |
| `trimpStrain` | `clinical/load_trimp.dart` | TRIMP → 0-100 strain, honesty-wrapped (absent without real HRmax/RHR anchors) | — |
| `ctlAtlTsb` | `clinical/load_trimp.dart` | Fitness-Fatigue-Form: EWMA CTL (42d) / ATL (7d) / TSB = CTL-ATL | Banister et al. 1975; Morton et al. 1990; 42/7-day defaults and priming are implementation choices |
| `baevskyStressIndex` | `clinical/stress_si.dart` | Baevsky Stress Index, 5-min sliding RR-histogram | Baevsky & Berseneva 2008 |
| `irregularBeatScreen` | `clinical/irregular_rhythm.dart` | Poincaré SD1/SD2 + pNN70 irregular-rhythm screen | Internal rule, ESTIMATE with low confidence; Task Force 1996 supports successive-difference components only; SD1/SD2 thresholds and sustained-window voting are unvalidated |
| `cardiacCoherence` | `clinical/cardiac_coherence.dart` | peak-band vs. remaining spectral power ratio, live RR during guided breathing | McCraty & Zayas 2014; McCraty et al. 2009 |

### `sleep/` — staging, structure, circadian
| Function | File | Method | Citation |
|---|---|---|---|
| `vanHeesSleepWindow` | `sleep/van_hees.dart` | z-angle sleep/wake window detection | van Hees et al. |
| `immobilityMask` | `sleep/van_hees.dart` | the shared per-second z-angle immobility primitive (steps 1–3, no window selection) — used by both the nocturnal spine and naps | van Hees et al. |
| `detectNaps` | `sleep/nap.dart` | **the only nap source.** z-angle immobility bouts on the complement of the main sleep window, corroborated by an HR dip vs the user's *awake daytime* baseline. Reports TST and TIB separately; makes **no stage claim**. Deliberately NOT `AdvancedSleepStager`, whose `minSleepMin=60` + 90-min daytime guard exist to reject naps | van Hees et al. |
| `segmentSleep` (`SleepSegmentation`) | `sleep/segment.dart` | **single source of truth** for sleep windowing; delegates staging to `cardioStager` |
| `cardioStager` | `sleep/cardio_stager.dart` | Webster/Cole-Kripke actigraphy + HRV fusion — explicitly replaces Walch 2019 (documented WAKE over-call bias) |
| `CausalStager.observe` | `sleep/causal_stager.dart` | **online** wake/NREM/REM for live decisions: `cardioStager`'s features, REM weights and cutoffs on past-only (trailing) windows and expanding baselines; returns stage + confidence + evidence age + a serialisable next state, and **abstains with a reason** (stale/off-wrist/missing HR or accel/thin coverage/warm-up) rather than guess. No look-ahead, deterministic, replacement-tolerant. Not PSG, not a replacement for `cardioStager` — see `docs/CAUSAL_STAGER.md` | `cardioStager`'s basis (linear-discriminant cardiorespiratory staging: Long 2016; Fonseca 2015/2018; weights measured on DREAMT); the causal adaptation is an unpublished internal rule, ESTIMATE with low confidence |
| `stageMinuteRanges` | `sleep/stage_ranges.dart` | per-stage [lo, hi] minutes from `cardioStager`'s `epochEvidence`: uncovered epochs could be any stage, scores within `kStageScoreMargin` of a cutoff count toward both neighbours. A bound, not a confidence interval | Internal margin/bound calibration rule, ESTIMATE with low confidence; underlying staging: Long 2016; Fonseca 2015/2018 |
| `AdvancedSleepStager` | `sleep/advanced_stager.dart` | AASM-style 4-class staging + hypnogram metrics (TIB/TST/SOL/WASO/REM-latency); `StagingMethod.cardio` is the wired production default, v1/v2 kept for regression coverage only |
| `sleepAccounting` | `sleep/accounting.dart` | TIB/TST/WASO/efficiency accounting | — |
| `cardiopulmonaryCoupling` | `sleep/cpc.dart` | cardiopulmonary coupling | — |
| `sleepCyclesMetric` | `sleep/cycles.dart` | fractal ultradian sleep-cycle detection | Rosenblum et al. 2024 |
| `circadianNonparametric` | `sleep/circadian_np.dart` | IS/IV/RA/L5/M10 nonparametric circadian indices | Witting 1990; van Someren 1999 |
| `phillipsSri` | `sleep/sri.dart` | true Phillips epoch-agreement Sleep Regularity Index | Phillips et al. 2017 |

### `respiration/`
| Function | File | Method | Citation |
|---|---|---|---|
| `rsaRespRate` | `respiration/resp_rate.dart` | respiratory sinus arrhythmia — HF spectral peak of the RR series: Lomb–Scargle on native beat times in 300 s Welch sub-windows (≥ 80 % covered by clean beats), median across them with an agreement gate; beat-rate Nyquist from the median NN | Welch 1967; Lomb 1976; Scargle 1982; Press & Rybicki 1989; DeBoer, Karemaker & Strackee 1984 |
| `riivRespRate` / `fuseRespRate` | `respiration/resp_rate.dart` | respiration-induced intensity variation, fused with the RSA estimate | Pimentel et al. (multi-grid RIIV fusion) |
| `cvhrApnea` / `cvhrApneaScreen` | `respiration/cvhr_apnea.dart` | cyclic-variation-in-HR apnea screening | Hayano 2011 |
| `relativeOdi` | `respiration/relative_odi.dart` | ratio-of-ratios relative desaturation index — **never an absolute SpO2 claim** | — |
| `breathingRateVariability` | `respiration/brv_trend.dart` | within-user breathing-rate variability trend | — |

### `motion/`
| Function | File | Method | Citation |
|---|---|---|---|
| `relativeIntensityBands` | `motion/enmo.dart` | ENMO/MAD activity intensity bands | — |
| `staticTilt` | `motion/orientation.dart` | orientation/posture from gravity vector | — |
| `branchedEnergyFusion` | `motion/energy_fusion.dart` | HR-anchored-when-possible energy expenditure fusion | Brage et al. 2004 |
| `dailyActiveMinutes` | `motion/steps.dart` | minutes of sustained wrist movement from the 1 Hz substrate, no step count — true per-step counting is impossible below gait Nyquist | internal ESTIMATE (personal dynamic-floor movement threshold, no published method; unrelated to AN-2554 — see `livePedometer` for the real AN-2554-derived 100 Hz method) |

### `workout/`
| Function | File | Method | Citation |
|---|---|---|---|
| `autoDetectWorkouts` | `workout/auto_detect.dart` | automatic workout detection | — |
| `hrRecovery` | `workout/hr_recovery.dart` | HRR — HR drop N seconds post-peak | Cole/Lauer 1999-style HRR |
| `Calories.dailyEnergy` / `estimateBoutCalories` | `workout/calories.dart` | Keytel HR→kcal regression + Harris-Benedict/Mifflin BMR | Keytel et al. 2005 |
| `Calories.metFromCadenceSpm` | `workout/calories.dart` | walking METs from measured cadence, for sub-flex-gate minutes (100/110/120/130 spm ↔ 3/4/5/6 METs, linear between, clamped) | Tudor-Locke et al. 2019 (CADENCE-Adults) |
| `Calories.minuteEnergy` / `hourlyRollup` | `workout/calories.dart` | the `dailyEnergy` computation exposed per minute (same gate, same billing; folds back to the daily `active`/`walking` bit-for-bit) plus an hourly rollup with per-hour coverage. A minute with no usable HR and no billable cadence abstains (null + reason); nothing is filled or interpolated | Keytel et al. 2005; Tudor-Locke et al. 2019 |

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
| `sleepDebt` | `human/sleep_regularity.dart` | accumulated sleep debt vs. need | — |
| `socialJetlag` / `chronotype` | `human/circadian_lifestyle.dart` | MSFsc-based social jetlag + chronotype | Wittmann & Roenneberg 2006; MCTQ |
| `alcoholNightFlag` | `human/event_detection.dart` | dose-graded autonomic-stress signature — **reports state, never asserts a cause** | Pietilä et al. 2018 |
| `roughNight` | `human/event_detection.dart` | neutral fallback descriptor when the signature is ambiguous | — |
| `percentileOfYou` / `personalRecord` | `human/percentile_of_you.dart` | percentile-vs-your-own-history, miss-tolerant personal-record streaks | — |
| `glassBoxReadiness` | `human/readiness_glassbox.dart` | **deprecated** — kept only for its percentile-of-you breakdown + narrative and edge back-compat; `readinessComposite` is canonical | — |
| `sleepNeed` / `strainTarget` / `recommendedBedtime` / `recommendedWake` / `sleepPerformance` | `human/coaching.dart` | deterministic coaching layer over the metrics above (naps come from `sleep/nap.dart`, not here) | — |
| `journalCorrelations` | `human/coaching.dart` | per-tag mean-difference correlation vs. logged outcomes, on-device, personal | — |

### Mergeable and incremental forms

Paths below are relative to `lib/src/onehz/`. Structural combinators, codecs,
checkpoints and caches add no physiological estimator. Tolerances in the adjacent
code comments describe parity tests, not universal numerical guarantees.

| Function | File | Method | Citation |
|---|---|---|---|
| `cosinor / cosinorAggregator` | `clinical/cosinor_aggregator.dart` | Centered least-squares sufficient statistics; relative singularity gate | Halberg & Nelson 1979 |
| `hrvTimeAggregator` | `clinical/hrv_time_aggregator.dart` | Mergeable time-domain statistics; timestamp behavior requires gapAware:true | Task Force 1996; internal jitter rule is ESTIMATE with low confidence; Welch 1967; Hirsch & Bishop 1981 |
| `RMSSD jitter gate / JitterEvidenceAggregator` | `clinical/rmssd_gate.dart; clinical/hrv_jitter_evidence.dart` | Shared spectral evidence; internal rejection/exemption threshold rule, ESTIMATE with low confidence | Welch 1967; Hirsch & Bishop 1981 |
| `banisterTrimpAggregator` | `clinical/load_trimp_aggregator.dart` | Mergeable per-minute Banister TRIMP sum | Morton, Fitz-Clarke & Banister 1990; sex-specific coefficients retained from Banister 1991 |
| `ctlAtlTsbAggregator` | `clinical/load_trimp_aggregator.dart` | Bounded-prefix priming and affine EWMA composition | Banister et al. 1975; Morton et al. 1990; 42/7-day defaults and priming are implementation choices |
| `prsaAggregator` | `clinical/prsa_aggregator.dart` | Mergeable PRSA anchor/profile sums | Bauer et al. 2006 |
| `readinessLnRmssdFromSuffix / readinessLnRmssdAggregator` | `clinical/readiness_lnrmssd.dart; clinical/readiness_lnrmssd_aggregator.dart` | Shared readiness arithmetic over the required suffix; positional aggregator history | Plews et al. 2013 |
| `circadianNpAggregator` | `sleep/circadian_np_aggregator.dart` | Mergeable IS/IV/RA/L5/M10; near-tie start epochs can differ | Witting 1990; van Someren 1999 |
| `bestCircularWindow` | `sleep/circadian_window.dart` | Shared circular L5/M10 search | Witting 1990; van Someren 1999 |
| `sriAggregator` | `sleep/sri_aggregator.dart` | Integer adjacent-day epoch agreement counts | Phillips et al. 2017 |
| `HypnogramAggregator / AdvancedSleepStager.hypnogramMetrics` | `sleep/hypnogram_aggregator.dart` | TST sums sleep stages; SOL from session start; efficiency = TST/session duration, capped at 1. Session bounds substitute for lights-off/on; inferred stages, explicit wake only between first and final sleep, no gap imputation or segment clipping | Berry et al., AASM Manual; application boundary conventions differ as stated |
| `correctRr / RrCapWindow / RrCorrector` | `foundations/rr_correction.dart; foundations/rr_correction_kernel.dart; foundations/rr_correction_stream.dart` | Shared capped batch/stream correction; internal artifact-run cap rule is ESTIMATE with low confidence | Lipponen & Tarvainen 2019; Peltola 2012 |
| `RrSandwich / NnColumn` | `foundations/rr_sandwich.dart` | Re-corrects raw seams, preserves source timestamps; uncapped long-run limitation | Lipponen & Tarvainen 2019; Peltola 2012; inner method attribution applies |
| `EpochRows / EpochRowsMemo / CardioRowCache / cardioEpochFeatures / classifyCardioEpochs` | `sleep/epoch_rows.dart; sleep/cardio_row_cache.dart; sleep/cardio_stager.dart` | Session-anchored feature rows and dependency-checked reuse; internal fitted weights and calibration rules are ESTIMATE with low confidence | van Hees 2013; Long 2016; Fonseca 2015/2018 |
| `HrvFreqStream` | `clinical/hrv_freq_stream.dart` | Append-only batch-equivalent Welch band processing | Laguna, Moody & Mark 1998; Bigger 1992; Welch 1967 |
| `RsaRespStream` | `respiration/resp_rate.dart` | Append-only RSA windows and exact median-NN ceiling | Welch 1967; Lomb 1976; Scargle 1982; Press & Rybicki 1989; DeBoer, Karemaker & Strackee 1984 |
| `CvhrStream` | `respiration/cvhr_apnea.dart` | Shared batch/stream CVHR screening | Hayano 2011 |
| `irregularBeatScreenDetailed / irregularWindowVerdict / IrregularScreenState` | `clinical/irregular_rhythm.dart; clinical/irregular_window.dart; clinical/irregular_rhythm_state.dart; clinical/irregular_diagnostics.dart` | Internal SD1/SD2, pNNx and sustained-window rule, ESTIMATE with low confidence | Task Force 1996 supports successive-difference HRV components only, not classifier calibration |
| `RunningMoments` | `incremental_core.dart` | Welford updates and algebraic removal with nonnegative M2 clamp; partition merge | Welford 1962; Chan, Golub & LeVeque 1983 |
| `IntHistogram` | `incremental_core.dart` | Exact expanded-list percentileSorted order statistics, Hyndman-Fan type 7 | Hyndman & Fan 1996 |
| `IncrementalLombScargle` | `incremental_core.dart` | Fixed-grid sufficient sums for Lomb-Scargle | Press & Rybicki 1989 |
| `IncrementalHrvTime` | `incremental_hrv.dart` | Incremental HRV with batch jitter fallback | Task Force 1996; internal jitter rule is ESTIMATE with low confidence; Welch 1967; Hirsch & Bishop 1981 |
| `IncrementalEnmoSeries` | `incremental_enmo.dart` | Explicit-reference motion updates; automatic calibration uses batch | van Hees 2013; Vähä-Ypyä 2015; internal dynAmp adaptation |
| `IncrementalMinuteMetrics` | `incremental_minutes.dart` | Keyed batch TRIMP and energy contributions | Banister 1991; Morton 1990; Keytel 2005; Mifflin-St Jeor 1990; Tudor-Locke 2019 |
| `HeartRateZones.timeInZone / timeInZoneAggregator` | `workout/time_in_zone_aggregator.dart` | Internal cadence-validation, median-capped interval and tail-credit rule, ESTIMATE with low confidence; exact gap histograms preserve it | Karvonen 1957 supports the HR-reserve zone option only |
| `hrDipFromDayTotals` | `clinical/nocturnal.dart` | Internal HR-dip band and minimum-sample rule, ESTIMATE with low confidence; sample-order day totals and all-valid-sample night mean | Avram 2019; Dial 2025 support nocturnal RHR only, not HR-dip classification |
| `Calories.minuteEnergyPricer / assembleMinuteEnergySeries` | `workout/calories.dart` | Shared dailyEnergy minute billing and ordered assembly | Keytel et al. 2005; Mifflin-St Jeor 1990; Tudor-Locke et al. 2019 |
| `slidingMedians` | `util.dart` | Same clipped-window median via maintained sorted values; percentileSorted uses type 7, zero-based rank (n - 1) * p / 100 | Hyndman & Fan 1996 |
| `lombScargle` | `util.dart` | First-sample time origin reduces argument error; mathematically time-shift invariant | Press & Rybicki 1989 |
| `Sum / SumOf / SumSq / Moments / Ewma` | `../aggregate/primitives.dart` | Compensated Sum/SumOf and ordinary SumSq; centered moments; affine EWMA composition, algebraically equal to the recurrence: f_y(f_x(c)) = a*a*c + a*lambda*x + lambda*y, a = 1-lambda | Welford 1962 and Chan, Golub & LeVeque 1983 for Moments only; sums are arithmetic, EWMA composition follows algebra |

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
al. 2017 · Pimentel et al. · Brage et al. 2004 · Keytel et al. 2005 · Tudor-Locke et al.
2019 · Hopkins 2004 ·
Mahalanobis 1936 · Killick et al. 2012 · Wittmann & Roenneberg 2006 · Pietilä et al. 2018 ·
Malik et al.


References added for the methods above:

- Welford, B. P. (1962). Note on a method for calculating corrected sums of squares and products. Technometrics 4(3):419-420.
- Chan, T. F., Golub, G. H., LeVeque, R. J. (1983). Algorithms for computing the sample variance: analysis and recommendations. The American Statistician 37(3):242-247.
- Hyndman, R. J., Fan, Y. (1996). Sample quantiles in statistical packages. The American Statistician 50(4):361-365.
- Banister, E. W., Calvert, T. W., Savage, M. V., Bach, T. (1975). A systems model of training for athletic performance. Australian Journal of Sports Medicine 7:57-61.
- Morton, R. H., Fitz-Clarke, J. R., Banister, E. W. (1990). Modeling human performance in running. Journal of Applied Physiology 69(3):1171-1177.
- Berry, R. B., et al. The AASM Manual for the Scoring of Sleep and Associated Events: Rules, Terminology and Technical Specifications. American Academy of Sleep Medicine. Used for duration terminology; application conventions are listed in the hypnogram row.
