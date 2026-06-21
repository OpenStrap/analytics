// Shared input/output types for openstrap-analytics.
// These match docs/ANALYTICS_SPEC.md and docs/CONFIDENCE.md exactly.
//
// All analytics consume arrays of MINUTE ROLLUPS (not 1Hz samples). Each fn is a
// pure, deterministic function returning a Metric<T> with a COMPUTED confidence.

/** One minute rollup. `activity` is the actigraphy signal (stddev of |accel(g)|). */
export interface Minute {
  ts: number; // unix seconds at the start of the minute
  hr_avg: number; // mean HR over the minute (0 = off-wrist / no reading)
  hr_min: number;
  hr_max: number;
  hr_n: number; // number of HR samples that contributed
  activity: number; // motion magnitude (actigraphy count)
  steps: number; // detected steps this minute (accel peak-count; ESTIMATE)
  wrist_on: boolean;
  // Dominant HAR activity class for this minute, classified at ingest from the live
  // high-rate accel (see har.ts). Present ONLY for live-streamed minutes (flash is
  // 1 Hz → no motion texture). Drives workout typing + segmentation in detectSessions.
  act_class?: ActivityClass;
}

/** Wrist activity-recognition class (Mannini 2013). Canonical home for the shared type. */
export type ActivityClass = 'sedentary' | 'walk' | 'run' | 'cycle' | 'lift' | 'other';

/** One labelled phase of a workout (graceful activity switches). */
export interface SessionSegment { start_ts: number; end_ts: number; type: string; confidence: number }

/** User profile. Fields are frequently absent — algorithms must degrade honestly. */
export interface Profile {
  age?: number;
  weight_kg?: number;
  height_cm?: number;
  sex?: 'm' | 'f';
}

/** Rolling baselines (see calcBaselines). */
export interface Baseline {
  resting_hr: number;
  max_hr: number;
  sleep_need_min: number;
  skin_temp?: number; // RELATIVE only; deviation, never absolute health truth
  chronic_strain?: number; // 28d mean daily strain (for ACWR)
}

export type Tier = 'AUTH' | 'HIGH' | 'ESTIMATE' | 'RELATIVE';

/** A pointer the UI can navigate to: another metric (optionally at a date/scale).
 *  This is the edge of the cross-metric "driver graph" — every contributor links
 *  to its own deep-dive. */
export interface MetricRef {
  metric: string; // 'hr' | 'hrv' | 'rhr' | 'sleep' | 'activity' | 'strain' | ...
  date?: string;  // YYYY-MM-DD
  scale?: 'day' | 'week' | 'month' | 'quarter';
}

/** One ranked contributor to a metric's value — "what affected this number".
 *  `contribution` is signed (positive = pushed the value up). `ref` makes it
 *  tappable in the UI (deep-dive into the cause). */
export interface Driver {
  label: string;        // human label, e.g. "Elevated heart rate"
  contribution: number; // signed magnitude (units are metric-specific / normalized)
  detail?: string;      // e.g. "82 bpm vs your 61 resting"
  ref?: MetricRef;      // where tapping this driver navigates
}

/** Every metric returns its value plus computed confidence + provenance, and
 *  (optionally) the ranked drivers that explain it. */
export type Metric<T> = T & {
  confidence: number; // 0..1, COMPUTED (coverage × input_completeness)
  tier: Tier;
  inputs_used: string[];
  drivers?: Driver[];
};

// ── HRV-derived value shapes (see hrv.ts / recovery.ts / stress.ts) ──────────

/** Recovery from nocturnal HRV (Plews et al. 2013 — ln RMSSD vs rolling baseline). */
export interface RecoveryValue {
  score: number | null;          // 0..100, null when no usable HRV
  rmssd: number | null;          // tonight's nocturnal RMSSD (ms)
  baseline_rmssd: number | null; // rolling mean RMSSD (ms)
  z: number | null;              // ln-RMSSD z vs baseline (sd units)
  note: string;                  // "HRV-based"
}

/** Stress from HRV (Baevsky Stress Index + LF/HF). Personal-relative when a
 *  baseline SI distribution is available. */
export interface StressValue {
  score: number | null;   // 0..100 (percentile/z vs personal baseline SI)
  si: number | null;      // Baevsky Stress Index
  lf_hf: number | null;   // sympatho-vagal balance
  rmssd: number | null;   // ms (context)
  level: 'low' | 'moderate' | 'elevated' | null;
}

/** Multivariate illness / under-recovery signal (Mahalanobis distance). */
export interface IllnessValue {
  signal: boolean;
  distance: number | null; // Mahalanobis distance from personal baseline
  triggers: string[];      // which features deviated (rhr/rmssd/temp)
  note: string;            // "a signal, not a diagnosis"
}

/** Nocturnal arousal / sleep-stress (HR surges + RMSSD dips + motion in sleep). */
export interface SleepStressValue {
  score: number | null;       // 0..100 nocturnal arousal load
  arousal_events: number;     // count of HR-surge + motion events
  restless_min: number;       // minutes with elevated motion during sleep
  mean_sleeping_hr: number | null;
  events: { ts: number; kind: 'arousal' | 'restless' }[]; // for the hypnogram overlay
}

// ── value shapes (wrapped by Metric<>) ──────────────────────────────────────

export interface RestingHrValue {
  resting_hr: number | null; // bpm, null when no usable data
}

export interface StrainValue {
  score: number; // 0..21
  trimp: number;
  max_hr_used: number;
  max_hr_source: 'measured' | 'age';
}

export interface HrZonesValue {
  zone1_min: number; // 50-60% HRmax
  zone2_min: number; // 60-70%
  zone3_min: number; // 70-80%
  zone4_min: number; // 80-90%
  zone5_min: number; // 90-100%
  max_hr_used: number;
  max_hr_source: 'measured' | 'age';
}

export interface CaloriesValue {
  kcal: number;
  label: string; // always carries "(est.)"
}

export interface SleepStages {
  light_min: number;
  deep_min: number;
  rem_min: number;
}

export interface SleepValue {
  onset_ts: number | null;
  wake_ts: number | null;
  duration_min: number; // asleep minutes
  in_bed_min: number;
  efficiency: number; // 0..1
  stages: SleepStages | null; // BETA/ESTIMATE
  stages_beta: boolean;
}

// ── Sleep v2 (multi-period) — naps are just shorter sleeps ───────────────────
/** One consolidated sleep period. Same breakdown as SleepValue, per-period. */
export interface SleepPeriod {
  onset_ts: number;
  wake_ts: number;
  duration_min: number; // asleep minutes
  in_bed_min: number;
  efficiency: number;   // 0..1
  stages: SleepStages | null; // BETA/ESTIMATE
  is_main: boolean;     // longest period of the day (UI hint only; data is uniform)
  confidence: number;   // per-period detection confidence (0..1)
}

/** All sleep periods detected in a window (one card each in the UI). */
export interface SleepPeriodsValue {
  periods: SleepPeriod[];     // chronological
  total_asleep_min: number;   // sum across periods
  main_idx: number | null;    // index of the main (longest) period, or null
  stages_beta: boolean;
}

export interface SleepRegularityValue {
  sri: number; // 0..100
  onset_std_min: number;
  wake_std_min: number;
  nights_used: number;
}

export interface SessionValue {
  start_ts: number;
  end_ts: number;
  duration_min: number;
  avg_hr: number;
  max_hr: number;
  strain: number;
  trimp: number;
  kcal: number;
  zones: HrZonesValue;
  hrr60: number | null;
  mean_activity: number;
  peak_activity: number;
  type: string; // ActivityClass when motion-classified, else legacy 'walk'|'run/cardio'|'strength/other'
  type_confidence: number; // ESTIMATE
  segments?: SessionSegment[]; // labelled phases (multi-activity workouts)
  detected_type?: string;      // the model's call at detection (for the calibration ledger)
}

export interface HrRecoveryValue {
  hrr60: number | null; // bpm dropped ~60s after peak
  peak_hr: number | null;
}

export interface LoadValue {
  acwr: number | null;
  acute: number; // mean daily strain last 7d
  chronic: number; // mean daily strain last 28d
  band: 'detraining' | 'optimal' | 'caution' | 'high-risk' | 'unknown';
}

export interface FitnessTrendValue {
  direction: 'improving' | 'flat' | 'declining' | 'unknown';
  rhr_slope: number; // per-day slope of rolling 7d RHR
  hrr_slope: number; // per-day slope of session HRR60
  days_used: number;
}

// VO₂max — Uth–Sørensen (2004), HR-ratio estimate. Tier ESTIMATE.
export interface Vo2MaxValue {
  vo2max: number | null; // ml/kg/min
  method: string;
}

// Banister impulse-response: Fitness (CTL, slow EWMA of strain), Fatigue (ATL,
// fast EWMA), Form/TSB = Fitness − Fatigue. Tier ESTIMATE.
export interface FitnessModelValue {
  fitness: number | null; // chronic training load (slow)
  fatigue: number | null; // acute training load (fast)
  form: number | null;    // fitness − fatigue (freshness)
}

// Foster training monotony + strain (7-day mean/SD of daily strain).
export interface MonotonyValue {
  monotony: number | null;       // mean/SD of last-7-day strain
  training_strain: number | null; // weekly_load × monotony
  weekly_load: number;
}

// HRV stability — coefficient of variation of nocturnal RMSSD over a window.
export interface HrvStabilityValue {
  cv: number | null;        // % (SD/mean × 100)
  mean_rmssd: number | null;
  n: number;
}

// Irregular-rhythm SCREEN (not a diagnosis): Poincaré SD1/SD2 + high ectopic/
// successive-difference fraction from nocturnal RR.
export interface IrregularValue {
  flag: boolean;
  sd1: number | null;
  sd2: number | null;
  ratio: number | null;     // sd1/sd2
  pnn50: number | null;
  ectopic_frac: number | null; // share of beats rejected as ectopic/irregular
  note: string;
}

// Composite Readiness — transparent weighted blend (recovery + sleep + dip +
// arousal). Abstains (null) until HRV-recovery exists. Tier ESTIMATE.
export interface ReadinessIndexValue {
  score: number | null; // 0..100
  components: {
    recovery: number | null;
    sleep: number | null;
    dip: number | null;
    arousal: number | null;
  };
  note: string;
}

export interface ReadinessComponents {
  rhr: number; // 0..1
  sleep_debt: number; // 0..1
  sleep_quality: number; // 0..1
  temp_adjust: number; // multiplicative factor applied (1 if none)
}

export interface ReadinessValue {
  score: number; // 0..100
  components: ReadinessComponents;
  note: string; // ALWAYS "(est.) — not HRV-based"
}

export interface AnomalyValue {
  signal: boolean;
  triggers: string[]; // which inputs fired
  note: string; // "signal, not a diagnosis"
}

export interface BaselinesValue {
  resting_hr: number | null;
  sleep_need_min: number | null;
  skin_temp: number | null; // RELATIVE
  max_hr: number | null;
  max_hr_source: 'measured' | 'age';
  chronic_strain: number | null;
  zone_min: [number, number, number, number, number] | null; // median per-zone minutes
  days_used: number;
}

// CircaCP circadian rhythm + main-sleep boundary (see circadian.ts). Cosinor
// phase is timezone-free (the physiological day anchor); onset/wake are the
// main-sleep boundary of the most-recent completed cycle.
export interface CircadianValue {
  mesor: number | null;         // bpm, rhythm-adjusted mean HR
  amplitude: number | null;     // bpm, cosinor amplitude (half peak-to-trough)
  acrophase_ts: number | null;  // unix s, HR peak (active-phase center) near window end
  bathyphase_ts: number | null; // unix s, HR trough (rest-phase center) of the detected cycle
  onset_ts: number | null;      // main-sleep onset (HR drop), or null
  wake_ts: number | null;       // main-sleep wake (HR rise), or null
  in_bed_min: number;           // wake − onset, minutes
  settled: boolean;             // wake older than the settle window → night complete
}

// ── history shapes for trend/baseline fns ───────────────────────────────────

/** One night's sleep summary (for SRI). */
export interface NightSummary {
  onset_ts: number | null;
  wake_ts: number | null;
}

/** One day of aggregate history (for baselines / load / fitness). */
export interface DayHistory {
  resting_hr?: number;
  sleep_duration_min?: number;
  skin_temp?: number;
  daily_strain?: number;
  session_hr_max?: number; // max session peak that day (for measured maxHR)
  hrr60?: number; // representative session HRR60 that day
  zone_min?: [number, number, number, number, number];
}

/** Per-day strain entry for ACWR / fitness. */
export interface DailyStrain {
  ts: number; // unix seconds (day)
  strain: number;
}
