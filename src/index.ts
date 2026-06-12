// openstrap-analytics — public surface.
// Pure, deterministic, spec-aligned (docs/ANALYTICS_SPEC.md + docs/CONFIDENCE.md).
// NOTE: HRV / rMSSD / stress are BANNED and are NOT exported.

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

// §6 Sleep regularity (SRI)
export { calcSleepRegularity } from './regularity';

// §7 Auto-workout detection
export { detectSessions } from './sessions';

// §8 HR recovery (HRR60)
export { calcHrRecovery } from './recovery';

// §9 Training load / fitness trend
export { calcLoad, calcFitnessTrend } from './trends';

// §10 Readiness + anomaly signals
export { calcReadiness, calcAnomaly } from './readiness';
export type { ReadinessInputs, AnomalyInputs } from './readiness';

// §11 Baselines
export { calcBaselines } from './baselines';

// Activity metric (steps / active-sedentary) REMOVED in v0 — see activity.ts.

// Coaching engine (deterministic, no AI) — signals → ranked plan + strain target.
export { buildCoach } from './coach';
export type {
  CoachInputs, CoachOutput, Suggestion, Contributor, Why,
} from './coach';

// §12 Stress / arousal monitor (HR-above-resting while sedentary; NOT HRV).
export { calcStress, classifyArousal, STRESS_ACT_FLOOR } from './stress';
export type { StressValue, ArousalPoint, ArousalBucket } from './stress';

// §13 Nocturnal Heart (sleeping-HR dynamics + dip + elevated-overnight flag).
export { calcNocturnalHeart } from './nocturnal';
export type { NocturnalValue } from './nocturnal';

// §14 Notification engine (deterministic per-user nudges from existing signals).
export { buildNotifications } from './notify';
export type {
  NotifyInputs, AppNotification, NotifyCategory, NotifyWindow,
} from './notify';
