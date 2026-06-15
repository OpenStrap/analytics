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

// §6 Sleep regularity (SRI)
export { calcSleepRegularity } from './regularity';

// §7 Auto-workout detection
export { detectSessions } from './sessions';

// §8 HR recovery (HRR60) + HRV-based recovery (Plews lnRMSSD z-score)
export { calcHrRecovery, calcRecovery } from './recovery';

// §HRV — RMSSD/SDNN/pNN50, Lomb–Scargle LF/HF, Baevsky SI, RSA respiratory rate
export {
  timeDomainHrv, freqDomainHrv, baevskyStressIndex, cleanRr,
  calcHrvStability, calcIrregular,
  VLF_BAND, LF_BAND, HF_BAND,
} from './hrv';
export type { TimeDomainHrv, FreqDomainHrv } from './hrv';

// §9 Training load / fitness trend
export { calcLoad, calcFitnessTrend } from './trends';

// §Fitness — VO₂max (Uth–Sørensen), Banister fitness/fatigue/form, Foster monotony
export { calcVo2Max, calcFitnessModel, calcMonotony } from './fitness';

// §Steps — AN-2554 wrist pedometer (pure math; backend re-decodes the IMU + runs it)
export { calcSteps, pedometer, STEP_PARAMS } from './steps';

// §Composite Readiness — weighted HRV + sleep blend (abstains without HRV)
export { calcReadinessIndex } from './readiness_index';
export type { ReadinessInputs } from './readiness_index';

// §10 Anomaly + illness (Mahalanobis). calcReadiness REMOVED (heuristic) — use
//     calcRecovery (HRV) instead.
export { calcAnomaly } from './readiness';
export type { AnomalyInputs } from './readiness';
export { calcIllness } from './illness';
export type { IllnessToday, IllnessHistory } from './illness';

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

// §Sleep stress / nocturnal arousal (HR surge + motion during sleep).
export { calcSleepStress } from './arousal';

// §13 Nocturnal Heart (sleeping-HR dynamics + dip + elevated-overnight flag).
export { calcNocturnalHeart } from './nocturnal';
export type { NocturnalValue } from './nocturnal';

// §14 Notification engine (deterministic per-user nudges from existing signals).
export { buildNotifications } from './notify';
export type {
  NotifyInputs, AppNotification, NotifyCategory, NotifyWindow,
} from './notify';
