// openstrap-analytics — public surface.
// Pure, deterministic, spec-aligned. Every metric is a published algorithm.
// HRV is derived from real type-24 RR intervals (validated on hardware).

export * from './types';

// utilities (handy for callers building their own pipelines)
export { resolveMaxHr, percentile, median, clamp, mean, stddev, linregSlope } from './util';

// §1 Resting HR
export { calcRestingHR } from './resting';
export type { SleepWindow } from './resting';

// §2 Strain
export { calcStrain } from './strain';

// §3 HR zones
export { calcHrZones } from './zones';

// §4 Calories
export { calcCalories } from './calories';

// §5 Sleep
export { calcSleep } from './sleep';
// §5b Sleep v2 — multi-period (naps = shorter sleeps). Additive; calcSleep unchanged.
export { calcSleepPeriods } from './sleep';
// Per-minute asleep/awake mask (calcSleep's boundary) — reconciles the hypnogram's awake.
export { sleepAwakeMask } from './sleep';
// v1-method per-minute hypnogram (Cole-Kripke + HR-percentile bands) — single source.
export { stageHypnogram } from './sleep';
export type { NightHypnogram } from './sleep';
// §Sleep cycles — ultradian NREM↔REM cycles (Rosenblum 2024 fractal-cycle method, HRV-adapted).
export { detectSleepCycles } from './cycles';
export type { SleepCycle, SleepCyclesValue } from './cycles';

// §Menstrual cycle — log-anchored calendar method + fertile window (Wilcox 2000).
export { calcCycle } from './cycle';
export type { CycleValue, CyclePhase } from './cycle';

// §6 Sleep regularity (SRI)
export { calcSleepRegularity } from './regularity';

// §7 Auto-workout detection
export { detectSessions } from './sessions';

// §8 HR recovery (HRR60) + HRV-based recovery (Plews lnRMSSD z-score)
export { calcHrRecovery, calcRecovery } from './recovery';

// §HRV — RMSSD/SDNN/pNN50, Lomb–Scargle LF/HF, Baevsky SI, RSA respiratory rate
export {
  timeDomainHrv, freqDomainHrv, baevskyStressIndex, cleanRr,
  calcHrvStability, calcIrregular, calcDaytimeHrv,
  VLF_BAND, LF_BAND, HF_BAND,
} from './hrv';
export type { TimeDomainHrv, FreqDomainHrv, DaytimeHrvValue } from './hrv';

// §9 Training load / fitness trend
export { calcLoad, calcFitnessTrend } from './trends';

// §Fitness — VO₂max (Uth–Sørensen), Banister fitness/fatigue/form, Foster monotony
export { calcVo2Max, calcFitnessModel, calcMonotony } from './fitness';

// §Steps — AN-2554 wrist pedometer (pure math; backend re-decodes the IMU + runs it)
export { calcSteps, pedometer, STEP_PARAMS } from './steps';

// §HAR — wrist activity recognition (Mannini 2013): per-window features + classifier
//        + workout segmentation. LIVE high-rate stream only (flash is 1 Hz).
export {
  extractHarFeatures, extractHarFeaturesFromSmv, classifyActivityWindow, segmentWorkout,
  dwtDetailEnergies, DB10_LO,
} from './har';
export type {
  HarFeatures, ClassVote, WorkoutSegment, SegmentResult,
} from './har';

// §Circadian — CircaCP cosinor + bounded change-point (physiological-day anchor)
export { calcCircadian, stageSleep } from './circadian';
export type { CircadianOpts, SleepStaging } from './circadian';

// §Sleep/wake ENSEMBLE — pluggable voters (Cole-Kripke + cardiac/CPD + van Hees);
// drives the demand-driven day-close trigger. detectWakeState + cheap peekRecentState.
export { detectWakeState, peekRecentState, coleKripke, cardiac, inactivity, DEFAULT_VOTERS } from './wake';
export type { WakeContext, WakeState, WakeLabel, Voter } from './wake';

// §Composite Readiness — weighted HRV + sleep blend (abstains without HRV)
export { calcReadinessIndex } from './readiness_index';
export type { ReadinessInputs } from './readiness_index';

// §10 Anomaly + illness (Mahalanobis). calcReadiness REMOVED (heuristic) — use
//     calcRecovery (HRV) instead.
export { calcAnomaly } from './readiness';
export type { AnomalyInputs, AnomalyOpts } from './readiness';
export { calcIllness } from './illness';
export type { IllnessToday, IllnessHistory, IllnessOpts } from './illness';

// §11 Baselines
export { calcBaselines } from './baselines';

// Activity metric (steps / active-sedentary) REMOVED in v0 — see activity.ts.

// Coaching engine (deterministic, no AI) — signals → ranked plan + strain target.
export { buildCoach } from './coach';
export type {
  CoachInputs, CoachOutput, Suggestion, Contributor, Why,
} from './coach';

// §12 Stress — HRV-based (Baevsky Stress Index + LF/HF, personal-relative).
export { calcStress } from './stress';

// §SpO₂ — RELATIVE blood-oxygen index + overnight desaturation screen.
export { calcSpo2Index, calcDesaturation } from './spo2';
export type { Spo2Value, DesaturationValue } from './spo2';

// §Sleep stress / nocturnal arousal (HR surge + motion during sleep).
export { calcSleepStress } from './arousal';

// §Restlessness — nocturnal movement fragmentation from per-minute actigraphy.
export { calcRestlessness } from './restlessness';
export type { RestlessnessValue } from './restlessness';

// §13 Nocturnal Heart (sleeping-HR dynamics + dip + elevated-overnight flag).
export { calcNocturnalHeart } from './nocturnal';
export type { NocturnalValue } from './nocturnal';

// §14 Notification engine (deterministic per-user nudges from existing signals).
export { buildNotifications } from './notify';
export type {
  NotifyInputs, AppNotification, NotifyCategory, NotifyWindow,
} from './notify';
