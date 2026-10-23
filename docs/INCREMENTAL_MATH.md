# Incremental calculation audit

Audited on 2026-10-03 against analytics `7334289` and the local sibling
`edge` checkout `a613d8d8`. This is a math audit and implementation design.
It does not change calculation code or scheduling.

The best first target is the awake-day pipeline: retain minute summaries,
replace changed minutes, and accumulate their contributions. Most headline
daytime calculations then cost work proportional to new or changed data.
Nighttime processing, heavy passes, and explicit recalculation should keep
running the complete pipeline and rebuild the incremental state afterward.

## What runs today

This package owns deterministic math. The app owns reads, scheduling,
isolate execution, and persistence. These sibling source links assume the
local checkout layout used for this audit.

- [`DeriveScheduler`](../../edge/lib/compute/derive_scheduler.dart) queues light
  work after stored data and heavy work after capture settles. It serializes
  jobs and holds them during capture, workouts, and iOS background execution.
- [`DerivationEngine.run`](../../edge/lib/compute/derivation_engine.dart) selects
  one freshness-critical day for a light pass and the pending span for a heavy
  pass. Both use the same per-day derivation, followed by baseline refresh and
  the cross-day pipeline when a day completes. “Light” currently limits days,
  not calculations within a day.
- [`onehz_pipeline.dart`](../../edge/lib/compute/onehz_pipeline.dart) recomputes
  sleep RR correction, HRV, resting HR, respiration, stress, whole-day rhythm
  screening, readiness, awake-minute TRIMP, calories, curves, and other detail.
  The coordinator's second isolate computes additional day blocks.
- [`crossday_pipeline.dart`](../../edge/lib/compute/crossday_pipeline.dart) builds
  history-dependent results. A daytime update can therefore trigger work on
  unchanged nightly history too.

The current input stream is not append-only. The app stores canonical readings
with replacement by timestamp. History can arrive late, sources can change,
and sleep bounds can be edited. A timestamp cursor alone cannot prove that
cached contributions are still correct.

## Calculation inventory

These tables group computational entry points and their shared math. Data
classes, serialization, and barrel exports are excluded. “Incremental” means
the same mathematical result, subject to floating-point differences and the
same validity gates. It does not promise bit-for-bit identical accumulation.

### Foundations and shared statistics

| Calculation and source | Current math | Incremental design |
|---|---|---|
| Mean, SD, population SD, ordinary z; [`util.dart`](../lib/src/onehz/util.dart) | `mean = sum/n`; sample variance `sum((x-mean)^2)/(n-1)`; population variance divides by `n`; `z=(x-mean)/SD` | Count, mean, centered sum of squares. Append, remove, and merge summaries. Preserve each divisor and null case. |
| Percentiles, median, MAD, robust z; [`util.dart`](../lib/src/onehz/util.dart), [`baseline.dart`](../lib/src/onehz/foundations/baseline.dart) | Sort; interpolate rank `p*(n-1)/100`; scaled MAD `1.4826*median(abs(x-median(x)))`; MDC `1.96*sqrt(2)*typicalError` | Exact ordered values or histograms. MAD changes when the median moves. Recompute small daily baselines only when their membership changes. |
| Sampling cadence; [`util.dart`](../lib/src/onehz/util.dart) | Median positive timestamp gap, maximum supported cadence, and fraction of gaps within a factor of two of the median | Ordered gap counts can update; a changed cadence or eligibility can invalidate all duration-dependent results. |
| OLS slope/fit; [`util.dart`](../lib/src/onehz/util.dart) | `slope=sum((x-mx)*(y-my))/sum((x-mx)^2)`; `intercept=my-slope*mx` | Bivariate centered moments, or additive sums with careful numerical handling. |
| Theil–Sen slope; [`util.dart`](../lib/src/onehz/util.dart) | Median of all valid pairwise slopes | One new point adds up to `n` slopes. Exact storage grows quadratically; keep batch evaluation on small aggregate series. |
| Lomb–Scargle; [`util.dart`](../lib/src/onehz/util.dart) | Mean-subtracted sinusoidal projection at every grid frequency, phase rotation, one-sided PSD normalization, then band integration | Exact additive trigonometric sums per fixed frequency. Detailed derivation below. |
| Average ranks, normal p-values, Benjamini–Hochberg q-values; [`util.dart`](../lib/src/onehz/util.dart) | Tie-averaged ranks; numerical normal-tail approximation; sorted p-values with reverse running minimum | New values can change old ranks; a changed test family can change every q-value. Cache unchanged inputs, then rebuild the affected ranking/test family. |
| `correctRr`; [`rr_correction.dart`](../lib/src/onehz/foundations/rr_correction.dart) | Successive RR differences; centered local medians and quartile thresholds; beat classification; compensatory-pair reconciliation; spline correction of isolated artifacts, dropping artifact runs; cumulative/reanchored beat times | Cache stable cleaned regions only after proving their dependencies. New beats change centered neighborhoods and unresolved spline anchors. Recompute the affected suffix; retain raw beats and clock checkpoints. |
| `Baselines.update/deviation`; [`ewma_baselines.dart`](../lib/src/onehz/foundations/ewma_baselines.dart) | Winsorized EWMA center, EWMA absolute deviation against the old center, early adaptation, outlier/absence/staleness gates; z/delta/ratio | Already has a serializable one-night state update. Save state before the provisional night so reruns replace that night rather than folding it twice. |
| `inverseVarianceFuse`; [`fusion.dart`](../lib/src/onehz/foundations/fusion.dart) | `sum(value/variance)/sum(1/variance)`; fused variance `1/sum(1/variance)` over trusted inputs | Two sums and provenance. Usually only a few channels, so direct reevaluation is already cheap. |

### Cardiac, load, and workout calculations

| Calculation and source | Current math | Incremental design |
|---|---|---|
| `hrvTime`, `nnDiffAcf1`; [`hrv_time.dart`](../lib/src/onehz/clinical/hrv_time.dart) | RMSSD `sqrt(sum(dRR^2)/pairs)`; pNN50 `100*count(abs(dRR)>50)/pairs`; SDNN; SDANN as SD of 5-minute means; SDNN-index as mean of 5-minute SDs; pooled difference lag-1 autocorrelation controls jitter refusal | NN moments, difference moments, threshold counts, pair-product summaries, last contiguous beat/difference, and per-bin summaries. Correct seams and mutable bins explicitly. |
| `nocturnalRmssd`, `sleepSessionWindowedRmssd`; same file | First takes median of eligible 5-minute RMSSDs and a pooled jitter gate; second takes mean of locally cleaned, gap-aware 5-minute RMSSDs | Cache per-window outputs under fixed bounds and masks; replace the open/changed window. Preserve median versus mean and each cleaner's seam rule. |
| `hrvFreq`; [`hrv_freq.dart`](../lib/src/onehz/clinical/hrv_freq.dart) | Welch averages of band-integrated Lomb–Scargle spectra, 50% overlap; segment length `10/lowestBandHz`; LF/HF and normalized units; artifact/length gates | Cache completed segments per band, sum powers and count accepted segments. Global quality gates still apply at publication. |
| `decelerationCapacity`, `accelerationCapacity`; [`prsa.dart`](../lib/src/onehz/clinical/prsa.dart) | Select capped RR-change anchors; average their aligned profiles; capacity `[X(0)+X(1)-X(-1)-X(-2)]/4` | Sum profiles and anchor count. Delay finalizing anchors until all required right-hand context and the current loop's eligibility boundary have arrived. |
| `nocturnalRhr`, `hrDip`; [`nocturnal.dart`](../lib/src/onehz/clinical/nocturnal.dart) | Lowest eligible 30-minute rolling HR mean and p1 HR; dip `100*(dayMean-nightMean)/dayMean` | RHR already uses a sliding sum inside a batch call. Retain its queue, counts, best completed window, and percentile structure across calls. Dip needs two sums/counts. Cadence and sleep-bound changes invalidate dependencies. |
| `baevskyStressIndex`; [`stress_si.dart`](../lib/src/onehz/clinical/stress_si.dart) | 50 ms RR histogram; `SI=AMoPct/(2*modeSeconds*rangeSeconds)` in up-to-256-beat windows stepped by 128; median SI and component summaries | Cache stable full windows, recompute the partial tail, maintain histogram/min/max and ordered window outputs. Preserve mode tie ordering. |
| `irregularBeatScreen`; [`irregular_rhythm.dart`](../lib/src/onehz/clinical/irregular_rhythm.dart) | `SD1=SD(dRR)/sqrt(2)`; `SD2=sqrt(2*SDNN^2-SD1^2)`; pNNx; aggregate gates plus fraction of independently positive time windows | Moments and difference counts per valid input run/window, plus scored-window counts. Preserve this function's actual adjacency contract, which differs from `hrvTime`. |
| `cardiacCoherence`; [`cardiac_coherence.dart`](../lib/src/onehz/clinical/cardiac_coherence.dart) | Find spectral peak; power around peak divided by remaining power; score `100*ratio/(1+ratio)` | Cached spectral sums if grid fixed. Current low grid endpoint depends on span, so rebuild when its frequency grid changes. |
| `banisterTrimp`, `StrainScorer`, `trimpStrain`; [`load_trimp.dart`](../lib/src/onehz/clinical/load_trimp.dart) | `sum(duration*x*c*exp(b*x))`, `x=clamp((HR-RHR)/(HRmax-RHR),0,1)`; coefficients differ by sex; legacy 0–100 strain is a log map | Cache raw TRIMP contributions under fixed anchors. Minute-input and timestamp-input paths have different duration semantics. Replace the last sample's provisional duration. |
| `baselineTrimp`, `strainScore/Metric`, `dailyQuietWakingHrr`; same file | Quiet overhead `wakeMinutes*q*c*exp(b*q)`; log-map net TRIMP onto 0–21; quiet level is median HRR subject to coverage/range gates | Accumulate raw TRIMP and wake-minute count, then reevaluate the scalar map. Changing quiet level changes the baseline; changing HR anchors changes every TRIMP contribution. |
| `ctlAtlTsb`; same file | Seed with first `primeDays` mean, then CTL/ATL exponential recurrences; TSB `CTL-ATL` | Persist state and seed count. Replace today's load from yesterday's checkpoint. A history edit requires replay after the edit. |
| `illnessCusum`; [`illness_cusum.dart`](../lib/src/onehz/clinical/illness_cusum.dart) | Prior-calendar-day robust RHR z; `C=max(0,C+z-k)`; persistence/recovery state and gap resets | Save prior-day state and rolling baseline values. Score each new day once; revisions replay forward. |
| `readinessLnRmssd`; [`readiness_lnrmssd.dart`](../lib/src/onehz/clinical/readiness_lnrmssd.dart) | Prior-night lnRMSSD mean/SD standardization and short rolling summaries | Small rolling moments under the exact history convention. Usually cheaper to memoize by history revision. |
| `cosinor`; [`cosinor.dart`](../lib/src/onehz/clinical/cosinor.dart) | OLS on `y=M+beta*cos(w*t)+gamma*sin(w*t)`; amplitude/phase; residual R² and adjusted R² | Additive 3×3 normal matrix, 3-vector, `sum(y^2)`, and count. Refit a constant-size system. |
| Heart-rate zones; [`hr_zones.dart`](../lib/src/onehz/workout/hr_zones.dart) | Threshold bands; timestamp-based time credit capped by measured median cadence | Per-zone durations, last timestamp/label, gap statistics. Reclassify on zone-bound changes; replace tail credit. |
| Observed HR ceiling; [`observed_max_hr.dart`](../lib/src/onehz/workout/observed_max_hr.dart) | Highest sustained window minimum HR, confirmed by a short motion burst; gap and bounded-span guards | Retain bounded candidates and sliding minima/motion summaries. Preserve motion corroboration and tie behavior; a plain maximum is insufficient. |
| `Calories.dailyEnergy/minuteEnergy/hourlyRollup/estimateBoutCalories`; [`calories.dart`](../lib/src/onehz/workout/calories.dart) | Affine Keytel HR energy rate with caps; HRR flex gate; surplus above basal rate; below gate, measured walking cadence gives `(MET-1)*basal`; basal total prorated by caller duration | Cache each minute's bill and provenance; sum active, walking, coverage and hourly contributions. Reprice affected contributions when profile, anchors, cadence spans, or sleep mask change. |
| `Calories.metFromCadenceSpm`; same file | Below 100 spm absent; otherwise `min(6,3+0.1*(spm-100))` | Already constant work. |
| `autoDetectWorkouts`, `AutoWorkoutDetector`; [`auto_detect.dart`](../lib/src/onehz/workout/auto_detect.dart) | Sustained HR elevation, brief-dip/gap rules, merging, motion confirmation, saved-span exclusion; bout mean/max | Keep the active candidate and mergeable tail; finalize only once merge look-ahead is resolved. Saved-session edits invalidate overlap decisions. |
| `hrRecovery`; [`hr_recovery.dart`](../lib/src/onehz/workout/hr_recovery.dart) | Peak near end minus median near +60 s; candidate-tau least-squares fits `a+b*exp(-t/tau)` with residual and boundary gates | Small event window. Cache fixed-tau basis sums if repeated fitting matters; otherwise run once when tail settles. Refit if end time changes. |
| `vo2maxSubmaxEstimate`; [`vo2max.dart`](../lib/src/onehz/clinical/vo2max.dart) | ACSM speed/grade submax VO2; `VO2max=3.5+(VO2submax-3.5)/HRR` with bout gates | Already scalar. Cache/revise upstream bout summaries. |
| Sport classification; [`sport.dart`](../lib/src/onehz/workout/sport.dart) | Injectable classifier; default returns the untyped detected label | Cache by settled bout and classifier-input revision, not by day timestamp. |

### Motion, sleep, and respiration

| Calculation and source | Current math | Incremental design |
|---|---|---|
| `enmoSeries`, `calibrateGRef`; [`enmo.dart`](../lib/src/onehz/motion/enmo.dart) | Magnitude `sqrt(ax²+ay²+az²)`; auto gravity from medians of locally still magnitudes; ENMO mean `max(0,magnitude-gRef)`; minute mean absolute deviation; dynamic magnitude after trailing per-axis mean subtraction | Retain the trailing gravity queue/sums and minute summaries. Closed-minute MAD can run once on its samples. Auto-calibrated `gRef` is a changing dependency; it cannot silently become a fixed constant. |
| `relativeIntensityBands`; same file | Moving-value p50/p75/p90 thresholds or caller-provided frozen cuts, then class counts | Fixed cuts permit incremental labeling/counts. Whole-record cuts can change every old label. |
| `pedometer`, `calcSteps`, `livePedometer`; [`steps.dart`](../lib/src/onehz/motion/steps.dart) | High-rate moving average, local extrema, adaptive thresholds, candidate timing/regulation, calibrated count/cadence and confidence | Reuse existing independent minute/buffer boundaries first. Arbitrary streaming must preserve filter/extremum/regulation state and the whole-input dynamic reference; chunk totals are not freely additive. |
| `calibrateCadence`, floor helpers, `dailyActiveMinutes`; same file | Calibration update; robust dynamic-floor history; count gate-passing covered minutes in clock-consecutive runs of minimum length | Freeze only through existing floor policy. Cache minute gates and current run; credit the whole run when it first qualifies, then one minute per extension. |
| `staticTilt`, `positionSeries`; [`orientation.dart`](../lib/src/onehz/motion/orientation.dart) | Gravity direction gives pitch/roll; mean rotation and magnitude jitter determine stillness/coverage | Cache completed fixed bins and carry the boundary pair. A changed average orientation changes angles, so calculate once per affected bin. |
| `branchedEnergyFusion`; [`energy_fusion.dart`](../lib/src/onehz/motion/energy_fusion.dart) | Normalize acceleration/HR; branch by motion and HR validity/intensity; integrate relative load over time | Cache per-point contributions and boundary duration with fixed anchors and calibration. |
| `immobilityMask`, `vanHeesSleepWindow`; [`van_hees.dart`](../lib/src/onehz/sleep/van_hees.dart) | z-angle `atan2(z,sqrt(x²+y²))`; centered median smoothing; forward sustained angle-change test; bout merging and main-window selection | Intermediate angles and stable windows can cache, but forward windows revise the tail and main-window selection can change. Keep full sleep passes. |
| `segmentSleep`, `AdvancedSleepStager`, `cardioStager`, legacy staging wrappers; [`segment.dart`](../lib/src/onehz/sleep/segment.dart), [`advanced_stager.dart`](../lib/src/onehz/sleep/advanced_stager.dart), [`cardio_stager.dart`](../lib/src/onehz/sleep/cardio_stager.dart), [`stager.dart`](../lib/src/onehz/sleep/stager.dart) | Candidate/window rules; local cardiac/motion features; whole-night robust distributions; weighted stage axes and temporal consolidation; TIB/TST/SOL/WASO/REM-latency accounting | Cache finished-night results when inputs are unchanged. Changing distributions or session bounds can relabel old epochs. Stage counts alone do not make the detector incremental. |
| `hrLedSleepWindow`; [`hr_fallback.dart`](../lib/src/onehz/sleep/hr_fallback.dart) | Sustained nocturnal HR dip against waking/reference HR with confirmation guards | Cache intermediate bins/candidates, but changed baseline or window selection invalidates decisions. Full sleep mode. |
| `CausalStager.observe`; [`causal_stager.dart`](../lib/src/onehz/sleep/causal_stager.dart) | Past-only features, expanding references, quality/age gates, serializable next state | Existing online interface. Keep its separate estimate contract; substituting it for offline staging changes results. |
| `detectNaps`; [`nap.dart`](../lib/src/onehz/sleep/nap.dart) | Immobility bouts outside main sleep, masks and bout chaining, HR dip against awake baseline, independent TST/TIB and quality | Cache primitives, but changed main sleep, awake baseline, or new bout completion can revise older nap candidates. Batch until dependencies are stable. |
| `detectSleepCycles`, `sleepCyclesMetric`; [`cycles.dart`](../lib/src/onehz/sleep/cycles.dart) | Per-minute filtered RMSSD, centered smoothing, whole-record population z-score, prominence peaks with tallest-first distance pruning | Cache minute RMSSD. Whole-record z/prominence and competition between peaks can revise old cycles. Keep complete cycle detection. |
| `nightHrvShape`; [`night_hrv_shape.dart`](../lib/src/onehz/sleep/night_hrv_shape.dart) | Per-bin gap-aware RMSSD and sampling bands; means of first/last third and their ratio | Cache bins, reevaluate thirds when night length changes. |
| `circadianNonparametric`; [`circadian_np.dart`](../lib/src/onehz/sleep/circadian_np.dart) | IS phase-profile variance / total variance; IV successive-difference energy / variance; circular M10/L5 windows; RA `(M10-L5)/(M10+L5)` | Overall moments, adjacency energy, phase sums/counts; recompute the small average-day profile and its circular windows. |
| `phillipsSri`; [`sri.dart`](../lib/src/onehz/sleep/sri.dart) | `200*validEpochAgreement/validCases-100` across adjacent clock-aligned days | Cache each adjacent-day pair's agreement/cases. Revising day `d` changes pairs `d-1,d` and `d,d+1`. Thin pairs still enter the total even if omitted from the displayed breakdown. |
| `rsaRespRate`, `riivRespRate`, `fuseRespRate`; [`resp_rate.dart`](../lib/src/onehz/respiration/resp_rate.dart) | Window spectra/peaks, sampling-ceiling and quality gates, consensus, then trusted estimate fusion | Cache completed window spectra/peaks. RSA adapts segment length on short records and grid to each segment's span/Nyquist; only fixed completed windows have reusable fixed-grid state. |
| `breathingRateVariability`; [`brv_trend.dart`](../lib/src/onehz/respiration/brv_trend.dart) | Mean, sample SD, coefficient of variation, Theil–Sen slope over resolved respiratory windows | Moments update cheaply; exact robust slope adds pairwise work. Small series can stay batch. |
| `cvhrApneaScreen`, `cvhrPersonalDistribution`; [`cvhr_apnea.dart`](../lib/src/onehz/respiration/cvhr_apnea.dart) | Gap-separated resampling, local smoothing/detrending, prominence/width/spacing cycle rules, cycles per analyzed hour; across-night weighted rates/quantiles | Cache stable segments and weighted count/duration sums; prominence references and unfinished cycles still need reevaluation. Keep nightly detection batch initially. |
| `relativeOdi`; [`relative_odi.dart`](../lib/src/onehz/respiration/relative_odi.dart) | Relative red/IR AC-to-DC ratio, rolling baseline and duration-gated drops per analyzed hour | Rolling windows/event state are possible in principle. The audited app permanently refuses this output for its channel data. Do not reactivate it as an optimization. |
| `cardiopulmonaryCoupling`; [`cpc.dart`](../lib/src/onehz/sleep/cpc.dart) | Always absent; withdrawn because no independent respiration channel is supplied | No expensive calculation to optimize. |

### Wellness and human-history calculations

| Calculation and source | Current math | Incremental design |
|---|---|---|
| `readinessComposite`; [`readiness_composite.dart`](../lib/src/onehz/wellness/readiness_composite.dart) | Robust z or ordinary-z fallback, quantization/input gates, weighted signed z, `100/(1+exp(-weightedZ/weightSum))` | Cache prior-night baseline summaries by date/membership revision, then recompute the small scalar blend. Never fold today into its own reference. |
| `multivariateAnomaly`; [`anomaly.dart`](../lib/src/onehz/wellness/anomaly.dart) | Robust feature centers/scales, correlation matrix with ridge, Mahalanobis distance `sqrt(zᵀR⁻¹z)`, significance/persistence gates | Reuse unchanged baseline results. Pearson correlation is invariant to the positive affine standardization, so raw complete-row covariance summaries can replace repeated standardized-row work; retain feature eligibility and robust centers/scales. |
| `cusumChangePoints`, `segmentChangePoints`; [`changepoint.dart`](../lib/src/onehz/wellness/changepoint.dart) | Online robust pre-regime z with two accumulators/resets; offline greedy binary segmentation using prefix-sum SSE, global-variance/log-length penalty and effect gates | Online state plus exact robust baseline; replay revisions. Offline prefix sums extend cheaply, but best splits and penalty change globally, so rerun segmentation. |
| `nightlySkinTemp`, `tempCircadian`; [`temp_circadian.dart`](../lib/src/onehz/wellness/temp_circadian.dart) | Settled mean relative to night's median/family band; motion/ambient masking, median centering, cosinor and missing-aware phase variance/adjacent differences | Cache raw bins and masks; changing median can change settled membership. Cosinor sums and centered variance can update algebraically under unchanged masks. Preserve device units and missing epochs. |
| `tempIllnessFlag`, `menstrualCoverline`; [`temp_health.dart`](../lib/src/onehz/wellness/temp_health.dart) | Prior-night robust z and consecutive-night/luteal rules; coverline is prior-six maximum followed by three above-threshold nights | Checkpoints and small queues. Coverline is currently uncalled in the app and needs a defensible sensor-unit threshold before use. |
| `cycleLengthSeries`; [`cycle_lengths.dart`](../lib/src/onehz/wellness/cycle_lengths.dart) | Sort/deduplicate logged onsets, interval lengths, absolute successive length differences and extremes | Append updates last interval and difference. Inserting/editing an old date revises neighboring intervals and extrema. |
| `sleepDebt`; [`sleep_regularity.dart`](../lib/src/onehz/human/sleep_regularity.dart) | `p75(freeNightSleep)-median(recentSleep)`; absent debt without free nights | Ordered short histories. This implementation is a signed comparison, not a cumulative sum of nightly deficits. |
| `socialJetlag`, `chronotype`; [`circadian_lifestyle.dart`](../lib/src/onehz/human/circadian_lifestyle.dart) | Circular medians via resultant-anchored unwrapping; shortest-arc free/work difference; MSF sleep-duration correction | Sin/cos sums update circular mean anchor; median still needs ordered/reunwrapped history when anchor changes. Cache small nightly histories. |
| `alcoholNightFlag`, `roughNight`; [`event_detection.dart`](../lib/src/onehz/human/event_detection.dart) | Robust baseline deltas/MDC comparisons, count directional signs, derive state and optional hypothesis band | Cache reference summaries; constant-size reevaluation when nightly inputs change. |
| `percentileOfYou`, `personalRecord`; [`percentile_of_you.dart`](../lib/src/onehz/human/percentile_of_you.dart) | Rank `100*(below+0.5*equal)/n`; prior extreme plus MDC | Ordered values and extrema; preserve ties and history exclusion. |
| `glassBoxReadiness`; [`readiness_glassbox.dart`](../lib/src/onehz/human/readiness_glassbox.dart) | Deprecated baseline/percentile driver breakdown | Memoize by input revision; do not introduce a second canonical readiness score. |
| `sleepNeed`, `sleepPerformance`, `recommendedBedtime/Wake`, `strainTarget`; [`coaching.dart`](../lib/src/onehz/human/coaching.dart) | Need `clamp(base+debt+45min*strain/21-naps,6h,11h)`; performance ratio; bed/wake arithmetic with efficiency; recovery-band/load-ratio rules | Already constant-size arithmetic. Trigger only on changed upstream values. |
| `journalCorrelations`, `journalNumericCorrelations`; same file | Tag-group mean differences/pooled SD/effect size; numeric rank correlation and robust slopes; deterministic permutation significance and family-wide q-values | Group moments can update; ranks, permutation distributions, and q-values can change globally. Cache the full result under input revision and rerun on relevant log/outcome changes. |
| `scanAssociations`; [`associations.dart`](../lib/src/onehz/human/associations.dart) | Calendar/lag alignment, weekday-median adjustment, ranks, Spearman correlations, block permutations, contrast medians, FDR and redundancy filtering | Keep batch evaluation. New rows change alignment, adjusted old values, ranks and the test family. Reuse unchanged scan inputs/results rather than incrementing a final rho. |
| `weekdayEffect`; [`weekday_effect.dart`](../lib/src/onehz/human/weekday_effect.dart) | Weekday medians, tied-rank Kruskal–Wallis statistic, deterministic permutation tests and peak/trough effect gate | Small daily histories; recompute when the underlying nightly series changes. |
| `sessionMorningEffects`; [`session_cost.dart`](../lib/src/onehz/human/session_cost.dart) | Following morning minus its prior robust baseline, per-session-type median deltas and MDC | Cache paired morning contributions and per-type ordered values; history/session edits invalidate affected pairs. Preserve the current positional lookback. |
| `overreachingConjunction`; [`overreaching_conjunction.dart`](../lib/src/onehz/human/overreaching_conjunction.dart) | Acute/chronic load ratio and count of recent RHR values above baseline plus half-scale gate | Cache short history summaries; reevaluate the conjunction when its inputs change. |
| `alertnessForecast`; [`alertness_forecast.dart`](../lib/src/onehz/human/alertness_forecast.dart) | Exponential sleep/wake process, circadian/ultradian cosines, decaying inertia; normalize forecast by whole-horizon extrema and select lowest 2-hour window | Exact process recurrence exists; the forecast is small and can be cached as a whole by sleep/nap/phase inputs. Horizon changes can rescale every published point. |

The old algorithm index contains stale entries: `sleepAccounting` is gone,
`accounting.dart` supplies the shared enum, CPC is withdrawn, and the implemented
sleep-debt calculation is the percentile-minus-median comparison above.

## Exact update rules

### 1. Cache contributions before nonlinear output transforms

For `A = sum(f(x_i; theta))`, where `theta` is unchanged:

```text
A_new = A_old + sum(f(new inputs; theta))
A_replaced = A_old - f(old input; theta) + f(replacement; theta)
```

Cache raw contributions, counts, and quality evidence. Reevaluate logarithms,
ratios, clamps and publication gates from those summaries. Adding rounded or
clamped scores loses information.

If input is a minute's mean HR, calculate the minute mean first:
`f(mean(HR samples))` generally differs from `mean(f(HR samples))`.
A partially filled minute therefore replaces one contribution as it grows.

### 2. Stable means and variance

Retain `n`, mean `mu`, and `M2 = sum((x-mu)^2)`. On adding `x`:

```text
n'  = n + 1
d   = x - mu
mu' = mu + d/n'
M2' = M2 + d*(x-mu')
```

On removing `x`, for `n > 1`:

```text
n'  = n - 1
mu' = mu + (mu-x)/n'
M2' = M2 - (x-mu)*(x-mu')
```

Reset when removing the only point. Sample SD is `sqrt(M2/(n-1))`;
population SD is `sqrt(M2/n)`. Preserve absence for insufficient counts.
These centered updates avoid cancellation in `sum(x²)-sum(x)²/n`.

For exact medians/percentiles, an ordered multiset with subtree counts supports
insertion/removal and rank selection without sorting the whole history. The
baseline median absolute deviation still needs distances from the *current*
median; storing only yesterday's median and MAD loses that information.
Small 14–28-night histories are cheap enough to rebuild when changed.

For disjoint summaries A and B, let `d=muB-muA`, `n=nA+nB`:

```text
mu = muA + d*nB/n
M2 = M2A + M2B + d²*nA*nB/n
```

This permits merging fixed bins. Pair-dependent metrics additionally need
boundary state; merging variance summaries alone does not recover RMSSD.

### 3. RMSSD, pNNx, and the autocorrelation gate

For each eligible successive difference `d`, cache difference count `p`,
`D1=sum(d)`, `D2=sum(d²)`, and threshold-exceedance counts.

```text
RMSSD = sqrt(D2/p)
pNNx  = 100*over/p
RMSSD' = sqrt((p*RMSSD²+d²)/(p+1))
```

Across chunk boundaries, add a difference only when the two beats satisfy
the caller's actual adjacency/gap rule. Across 5-minute bins, apply the
function's bin policy; do not add a cross-bin pair to an estimator that
currently excludes it.

The lag-1 difference autocorrelation can also avoid rescanning old differences.
For adjacent differences within the same run retain:

```text
K = number of adjacent-difference pairs
P = sum(d_previous*d_current)
E = sum(d_previous+d_current)
m = D1/p
ACF1 = (P-m*E+K*m²) / (D2-D1²/p)
```

This algebra matches `nnDiffAcf1`, including its use of a global mean across
runs and a numerator that omits seam pairs. Retain the 30-difference minimum
and constant-series null result. Use centered/compensated accumulation or
rebuilding where cancellation matters. Reevaluate refusal and confidence
after updates; an old accepted RMSSD can become refused.

### 4. TRIMP and strain

With fixed resting HR `R`, maximum `H`, coefficients `c,b`, and time weight `dt`:

```text
x = clamp((HR-R)/(H-R), 0, 1)
f(x) = c*x*exp(b*x)
TRIMP = sum(dt*f(x))
baseline = wakeMinutes*f(q)
net = TRIMP-baseline
u = clamp(net/400, 0, 1)
strain = 21*log(1+14*u)/log(15)
```

For net at or below zero, current strain is zero. Awake minute count is part
of the state because additional quiet time changes the subtraction too.
The separate legacy 0–100 map remains a separate API.

For timestamp-weighted scoring, the last sample provisionally gets median
cadence. Arrival of the next sample replaces that duration with the capped
actual gap, then gives the new tail its provisional credit. Updating the tail
can require subtraction. A changed median cadence can affect all durations.
The minute-input TRIMP path used by the audited day pipeline treats each
supplied minute as one minute and has no such timestamp-tail correction.

Calculus identifies why anchor changes require reevaluation. Inside the
unclamped HRR interval:

```text
f'(x) = c*exp(b*x)*(1+b*x)
dx/dR = (HR-H)/(H-R)²
dx/dH = -(HR-R)/(H-R)²
```

An anchor change affects old samples, and clamp crossings change which
derivative applies. A first-order Taylor update is an approximation. Keep
exact recalculation for changed anchors. A discrete HR or minute-mean
histogram can reprice contributions exactly by unique value when weights
and masks are also retained.

Likewise, inside the strain map's unclamped interval, for `a=14/400`:

```text
ds/dnet = 21*a / (log(15)*(1+a*net))
```

Use this to understand sensitivity, not to accumulate score increments.
Reevaluating one logarithm is already constant work.

### 5. Calories and zones

For fixed profile and anchors:

```text
flexHR = RHR + 0.40*(HRmax-RHR)
B = max(0, 10*kg + 6.25*cm - 5*age + sexConstant)/1440
K(HR) = 60*max(0, cHR*min(HR,HRmax)+cWeight*kg+cAge*age+c0)/251.04
```

`B` is basal kcal/minute. A minute at/above flex bills `max(0,K-B)`.
Otherwise, eligible measured cadence bills `(MET-1)*B`; otherwise it adds
no active surplus, with the existing per-minute abstention/provenance.
Walking is included in active total, so do not add it a second time.
Daily total is caller-prorated basal plus active.

Retain per-minute contributions, hourly sums, and coverage counts. Zones
similarly sum time by the assigned zone. The final display is cheap;
profile/gate/zone/source changes require repricing affected minutes.

### 6. Motion without rescanning a day

The trailing gravity remover already updates per-axis sums inside one call:
`axisSum += incoming - expired`. Retain its queue between calls. Its output
depends on real timestamps and excludes samples at/older than the window
boundary; preserve that boundary exactly.

For fixed gravity reference `g`, ENMO sum is additive. With an ordered set
of minute magnitudes, reference changes can also be handled exactly:

```text
sum(max(0,m-g)) = sum(m where m>g) - g*count(m>g)
```

The minute MAD here means *mean* absolute deviation, unlike the baseline
MAD that means *median* absolute deviation. Because its center moves on
every append, absolute deviations cannot simply be added. If `mu=sum(m)/n`,
`k=count(m<=mu)` and `L=sum(m where m<=mu)`:

```text
meanAbsoluteDeviation = 2*(k*mu-L)/n
```

An ordered structure with prefix counts/sums supports this query. For roughly
60 samples per minute, retaining the minute's magnitudes and recomputing only
that minute is simpler and likely preferable to a new tree.

For movement bouts of minimum length `L`, retain current run length `r`.
Credit nothing below `L`, credit all `L` minutes when the run reaches `L`,
then one minute per extension. Missing/uncovered/nonpassing minutes break
the run. Replacing a past minute may split/merge a run, so recompute the
connected affected region rather than adjusting one boolean count.

### 7. Lomb–Scargle can update exactly on a fixed grid

This is the largest algebraic opportunity beyond simple sums. For each fixed
frequency `f`, set `w=2*pi*f`. Retain:

```text
C  = sum(cos(w*t))          S  = sum(sin(w*t))
CC = sum(cos(w*t)²)         SS = sum(sin(w*t)²)
CS = sum(cos(w*t)*sin(w*t))
YC = sum(y*cos(w*t))        YS = sum(y*sin(w*t))
```

Also retain global count, `sum(y)`, variance state, and time extrema. Every
new point adds to these sums. The current implementation's changing mean
and phase can be recovered without visiting old samples:

```text
mu  = sum(y)/n
phi = 0.5*atan2(2*CS, CC-SS)     # phi = w*tau
a   = cos(phi)
b   = sin(phi)
Uc  = YC-mu*C
Us  = YS-mu*S

cNum = a*Uc+b*Us
sNum = a*Us-b*Uc
cDen = a²*CC+b²*SS+2*a*b*CS
sDen = a²*SS+b²*CC-2*a*b*CS

PSD(f) = span/(n-1) * (cNum²/cDen+sNum²/sDen)
```

Preserve the source's zero-frequency, zero-denominator, too-few-points,
zero-variance and zero-span cases. PSD still has the source's physical units.
Band integration remains the same rectangular sum over its exact grid.

For `F` frequencies, adding `deltaN` samples costs `O(deltaN*F)` and rendering
the spectrum costs `O(F)`, instead of `O(N*F)` each pass. Cached state costs
`O(F)` per active spectral window. A sliding window also needs outgoing
contributions or the raw samples to subtract them.

`hrvFreq` already uses fixed-size, overlapping Welch segments per band.
Compute completed segments once, retain accepted power sums/counts, and
process only newly complete segments. This can save most repeated nightly
spectral work even without implementing streaming spectral sums.

RSA and cardiac coherence have adaptive grids. Preserve each existing grid
choice: rebuild when it changes, or cache completed-window outputs. Choosing
a new universal fixed grid would change the estimator and needs separate
accuracy evaluation. Use a stable time origin; reanchoring times requires
rotating/rebuilding the trigonometric summaries, not relabeling timestamps.

### 8. Linear fits and exponential processes

Cosinor is linear in its three fitted coefficients. With design vector
`v=[1,cos(w*t),sin(w*t)]`, retain:

```text
A = sum(v*vᵀ)
b = sum(v*y)
Q = sum(y²)
beta = solve(A,b)
SSE = Q-2*betaᵀ*b+betaᵀ*A*beta
SST = Q-sum(y)²/n
```

At the exact least-squares solution, SSE simplifies to `Q-betaᵀ*b`.
The matrix has fixed size. Amplitude, phase, R², adjusted R² and their gates
are then scalar calculations. Use centered sums or incremental QR if
conditioning/cancellation warrants it; compare to the current residual pass.

Each recovery-fit tau candidate similarly uses fixed basis `e=exp(-t/tau)`.
Retain `n,sum(e),sum(e²),sum(y),sum(e*y),sum(y²)` and solve the two-parameter
fit. Its complete residual sum follows from those sums. Keep the current
candidate grid, tie selection, amplitude, boundary and residual gates.

The alertness process solves `dS/dt=-(S-target)/tau`:

```text
S(t+dt) = target + (S(t)-target)*exp(-dt/tau)
```

This is an exact recurrence over a constant-target interval, not an Euler
approximation. Follow the current time-step/nap membership policy to preserve
results. Normalizing the final forecast by its whole-horizon extrema remains
a global dependency, so caching the small complete forecast is preferable.

CTL/ATL and EWMA baselines are already recurrences. Persist their checkpoint
states instead of replaying unchanged history. Winsor/outlier logic is
state-dependent, so revised historical values require forward replay.

## Cache validity and full-pass policy

The app should pass an explicit calculation mode. Only an awake periodic
update with proven unchanged dependencies qualifies for incremental execution.
During sleep, on heavy/finalization passes, and on forced recalculation, use
the complete current pipeline, then replace the cache with rebuilt state.
If sleep eligibility is uncertain, the safe initial policy is a complete pass.
The audited light/heavy job kind alone does not encode this distinction.

Cache keys need calculation/state version, device family, profile/anchors,
source-selection revision, sleep bounds/masks, bin origin, timezone/day bounds,
baseline membership, and relevant manual edits. Include all parameters that
the function actually reads. Finalized results and provisional tail state
must have different lifetimes.

Store sufficient statistics at full precision. Store per-bin contributions
so edits can remove old values before adding replacements. Do not reconstruct
state from rounded `Metric.toJson` scalars.

The existing app fingerprint includes profile and previous-day inputs, but its
raw day component is `MAX(rec_ts):COUNT(*)`. That detects many insertions; it
does not detect replacement of a value at an existing timestamp with unchanged
count/max. An incremental cache requires a mutation revision/change log or
another proof that covers replacements, RR changes, and source/mask changes.
`MAX:COUNT` alone is insufficient.

Publish cache state and derived output for the same captured input revision.
Commit together, or associate them with an identical validated revision and
discard mismatches. A failed/cancelled calculation must not advance the
checkpoint. Retrying an identical revision must be idempotent. Missing or
incompatible state falls back to a complete calculation.

Late data invalidates its affected bins and downstream dependencies. A changed
NN beat also affects neighbor differences and downstream clock state where
times are accumulated. Centered filters compose their support widths; the RR
corrector's spline-anchor search and run reconciliation can extend dependency
reach. A fixed “last 91 beats” replay rule is not established by this audit.
Start with complete RR correction until stable-prefix equivalence is proved.

Preserve absence, quality gates, coverage denominators, confidence, notes,
drivers and provenance. Updates are allowed to lower confidence or withdraw
a previously present metric. Valid data in a gap must never be inferred from
an accumulator's previous state.

## Implementation order and validation

1. Add mode/dependency revisions in `edge` and plain explicit accumulator states
   in analytics. Keep existing batch entry points as the comparison reference.
2. Cache minute HR/motion summaries and their nonlinear TRIMP, energy and zone
   contributions. Replace open/changed minutes. Reuse unchanged completed-night
   results; keep every sleep-time calculation complete.
3. Cache baseline summaries and whole cross-day results by the inputs they read.
   Daytime HR changes should not rerun unchanged nightly association analyses.
   Advance daily recurrent states from a prior-day checkpoint, replacing today.
4. Cache completed Welch windows and shared cleaned RR/intermediate features.
   The app currently invokes `detectSleepCycles` directly and again through
   `sleepCyclesMetric`; share that result while preserving the envelope.
5. Add fixed-grid spectral accumulators if measurements justify their state
   size and complexity. Prove RR stable-prefix boundaries before incremental
   correction; keep global sleep-stage and retrospective scans complete.

Compare incremental results against the current batch functions at every
prefix and varied chunk boundary, including one sample at a time. Exercise
duplicates, out-of-order insertion, value replacement, gaps, off-wrist data,
mutable partial minutes, changed anchors, cadence-mode changes, source edits,
sleep edits, midnight/DST, baseline expiration, interruption and restart.
Match publication gates and discrete decisions exactly; measure numerical
differences before selecting tolerances. Near a decision threshold, floating
differences can change absence or labels and need explicit handling.

Real-capture comparisons should cover every device family with fixtures and
the existing sleep/causal/pedometer validation paths when those paths change.
Instrument reads, decoded rows, processed samples/windows, CPU time, isolate
payload/heap and serialized cache size. Accumulator improvements will not
remove full-day DB reads, decoding, or bundle serialization on their own.

No performance speedup was measured in this audit. As a work-count example,
a 5-minute update at the end of 12 hours has 300 new seconds versus 43,200
old-plus-new seconds: about 144× less scanning in an eligible append-only
component. That is not an app-level speedup estimate.

The scratch algebra check ran 3,031 comparisons of append/remove variance,
pooled multi-run ACF1, direct versus cached Lomb–Scargle PSD, minute mean
absolute deviation, changed-reference ENMO, and nonlinear contribution
replacement. All passed at relative tolerance `2e-9` / absolute tolerance
`2e-7`; maximum absolute spectral difference was about `1.02e-10` on those
synthetic inputs. This checks the derivations, not a Dart implementation or
real-world speed. The scratch script was not added to the runtime library.
It is available in this session at `/tmp/openstrap_incremental_math_check.py`.
