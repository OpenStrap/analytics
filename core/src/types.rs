// Port of openstrap-analytics/src/types.ts (slice). Field names/JSON shapes are
// 1:1 with the TS so outputs compare byte-for-byte after serde_json serialization.
use serde::{Deserialize, Serialize};

/// One per-minute rollup. serde defaults so partial real-world JSON deserializes.
#[derive(Debug, Clone, Deserialize)]
pub struct Minute {
    pub ts: f64,
    #[serde(default)]
    pub hr_avg: f64,
    #[serde(default)]
    pub hr_min: f64,
    #[serde(default)]
    pub hr_max: f64,
    #[serde(default)]
    pub hr_n: f64,
    #[serde(default)]
    pub activity: f64,
    #[serde(default)]
    pub steps: f64,
    #[serde(default = "default_true")]
    pub wrist_on: bool,
    /// Dominant HAR class for this minute (live-streamed only); drives workout typing.
    #[serde(default)]
    pub act_class: Option<String>,
}

fn default_true() -> bool {
    true
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct Profile {
    #[serde(default)]
    pub age: Option<f64>,
    #[serde(default)]
    pub weight_kg: Option<f64>,
    #[serde(default)]
    pub height_cm: Option<f64>,
    #[serde(default)]
    pub sex: Option<String>, // "m" | "f"
}

#[derive(Debug, Clone, Deserialize)]
pub struct Baseline {
    pub resting_hr: f64,
    pub max_hr: f64,
    #[serde(default)]
    pub sleep_need_min: f64,
    #[serde(default)]
    pub skin_temp: Option<f64>,
    #[serde(default)]
    pub chronic_strain: Option<f64>,
    #[serde(default)]
    pub sleeping_hr: Option<f64>,
}

/// {ts, strain} day for ACWR / fitness model.
#[derive(Debug, Clone, Deserialize)]
pub struct DailyStrain {
    pub ts: f64,
    #[serde(default)]
    pub strain: f64,
}

/// Daily history row (fields the ported metrics read; unknown fields ignored).
#[derive(Debug, Clone, Deserialize)]
pub struct DayHistory {
    #[serde(default)]
    pub resting_hr: Option<f64>,
    #[serde(default)]
    pub hrr60: Option<f64>,
    #[serde(default)]
    pub sleep_duration_min: Option<f64>,
    #[serde(default)]
    pub skin_temp: Option<f64>,
    #[serde(default)]
    pub daily_strain: Option<f64>,
    #[serde(default)]
    pub session_hr_max: Option<f64>,
    #[serde(default)]
    pub zone_min: Option<[f64; 5]>,
}

/// {onset_ts, wake_ts} per night for regularity.
#[derive(Debug, Clone, Deserialize)]
pub struct NightSummary {
    #[serde(default)]
    pub onset_ts: Option<f64>,
    #[serde(default)]
    pub wake_ts: Option<f64>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SleepWindow {
    pub onset_ts: Option<f64>,
    pub wake_ts: Option<f64>,
}

// ── Output value shapes (wrapped Metric<T> is flattened, exactly like the TS) ──

#[derive(Debug, Serialize)]
pub struct StrainOut {
    pub score: f64,
    pub trimp: f64,
    pub max_hr_used: f64,
    pub max_hr_source: String, // "measured" | "age"
    pub confidence: f64,
    pub tier: String,
    pub inputs_used: Vec<String>,
}

#[derive(Debug, Serialize)]
pub struct RestingOut {
    pub resting_hr: Option<f64>,
    pub confidence: f64,
    pub tier: String,
    pub inputs_used: Vec<String>,
}

#[derive(Debug, Serialize)]
pub struct TimeDomainHrvOut {
    pub rmssd: Option<f64>,
    pub sdnn: Option<f64>,
    pub pnn50: Option<f64>,
    pub mean_rr: Option<f64>,
    pub mean_hr: Option<f64>,
    pub n_beats: u32,
}

#[derive(Debug, Serialize)]
pub struct FreqDomainHrvOut {
    pub lf: Option<f64>,
    pub hf: Option<f64>,
    pub lf_hf: Option<f64>,
    pub total_power: Option<f64>,
    pub resp_rate: Option<f64>,
    pub resp_conf: f64,
}

#[derive(Debug, Serialize)]
pub struct BaevskyOut {
    pub si: Option<f64>,
    pub sqrt_si: Option<f64>,
    pub n_beats: u32,
}

#[derive(Debug, Serialize)]
pub struct HrvStabilityOut {
    pub cv: Option<f64>,
    pub mean_rmssd: Option<f64>,
    pub n: u32,
    pub confidence: f64,
    pub tier: String,
    pub inputs_used: Vec<String>,
}

#[derive(Debug, Serialize)]
pub struct IrregularOut {
    pub flag: bool,
    pub sd1: Option<f64>,
    pub sd2: Option<f64>,
    pub ratio: Option<f64>,
    pub pnn50: Option<f64>,
    pub ectopic_frac: Option<f64>,
    pub note: String,
    pub confidence: f64,
    pub tier: String,
    pub inputs_used: Vec<String>,
}

#[derive(Debug, Serialize)]
pub struct DaytimeHrvPoint {
    pub ts: f64,
    pub rmssd: f64,
}

#[derive(Debug, Serialize)]
pub struct DaytimeHrvOut {
    pub rmssd_median: Option<f64>,
    pub series: Vec<DaytimeHrvPoint>,
    pub lowest_ts: Option<f64>,
    pub n_windows: u32,
    pub confidence: f64,
    pub tier: String,
    pub inputs_used: Vec<String>,
}

#[derive(Debug, Serialize)]
pub struct HrZonesOut {
    pub zone1_min: u32,
    pub zone2_min: u32,
    pub zone3_min: u32,
    pub zone4_min: u32,
    pub zone5_min: u32,
    pub max_hr_used: f64,
    pub max_hr_source: String,
    pub confidence: f64,
    pub tier: String,
    pub inputs_used: Vec<String>,
}

#[derive(Debug, Serialize)]
pub struct CaloriesOut {
    pub kcal: f64,
    pub label: String,
    pub confidence: f64,
    pub tier: String,
    pub inputs_used: Vec<String>,
}

/// Per-minute RR bundle for daytime HRV (matches the TS `{ts, rr[]}`).
#[derive(Debug, Clone, Deserialize)]
pub struct MinuteRr {
    pub ts: f64,
    #[serde(default)]
    pub rr: Vec<f64>,
}

// ── Driver graph (matches types.ts Driver / MetricRef; omits absent fields) ──
#[derive(Debug, Serialize)]
pub struct MetricRef {
    pub metric: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub date: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub scale: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct Driver {
    pub label: String,
    pub contribution: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
    #[serde(rename = "ref", skip_serializing_if = "Option::is_none")]
    pub reference: Option<MetricRef>,
}

#[derive(Debug, Serialize)]
pub struct RecoveryOut {
    pub score: Option<f64>,
    pub rmssd: Option<f64>,
    pub baseline_rmssd: Option<f64>,
    pub z: Option<f64>,
    pub note: String,
    pub confidence: f64,
    pub tier: String,
    pub inputs_used: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub drivers: Option<Vec<Driver>>,
}

#[derive(Debug, Serialize)]
pub struct HrRecoveryOut {
    pub hrr60: Option<f64>,
    pub peak_hr: Option<f64>,
    pub confidence: f64,
    pub tier: String,
    pub inputs_used: Vec<String>,
}

#[derive(Debug, Serialize)]
pub struct StressOut {
    pub score: Option<f64>,
    pub si: Option<f64>,
    pub lf_hf: Option<f64>,
    pub rmssd: Option<f64>,
    pub level: Option<String>,
    pub confidence: f64,
    pub tier: String,
    pub inputs_used: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub drivers: Option<Vec<Driver>>,
}

#[derive(Debug, Serialize)]
pub struct NocturnalOut {
    pub sleeping_hr_avg: Option<f64>,
    pub sleeping_hr_min: Option<f64>,
    pub nadir_ts: Option<f64>,
    pub day_hr_avg: Option<f64>,
    pub dip_pct: Option<f64>,
    pub vs_baseline_bpm: Option<f64>,
    pub elevated: bool,
    pub confidence: f64,
    pub tier: String,
    pub inputs_used: Vec<String>,
}

#[derive(Debug, Serialize)]
pub struct SleepRegularityOut {
    pub sri: f64,
    pub onset_std_min: f64,
    pub wake_std_min: f64,
    pub nights_used: u32,
    pub confidence: f64,
    pub tier: String,
    pub inputs_used: Vec<String>,
}

#[derive(Debug, Serialize)]
pub struct ReadinessComponents {
    pub recovery: Option<f64>,
    pub sleep: Option<f64>,
    pub dip: Option<f64>,
    pub arousal: Option<f64>,
}

#[derive(Debug, Serialize)]
pub struct ReadinessIndexOut {
    pub score: Option<f64>,
    pub components: ReadinessComponents,
    pub note: String,
    pub confidence: f64,
    pub tier: String,
    pub inputs_used: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub drivers: Option<Vec<Driver>>,
}

#[derive(Debug, Serialize)]
pub struct Vo2MaxOut {
    pub vo2max: Option<f64>,
    pub method: String,
    pub confidence: f64,
    pub tier: String,
    pub inputs_used: Vec<String>,
}

#[derive(Debug, Serialize)]
pub struct FitnessModelOut {
    pub fitness: Option<f64>,
    pub fatigue: Option<f64>,
    pub form: Option<f64>,
    pub confidence: f64,
    pub tier: String,
    pub inputs_used: Vec<String>,
}

#[derive(Debug, Serialize)]
pub struct MonotonyOut {
    pub monotony: Option<f64>,
    pub training_strain: Option<f64>,
    pub weekly_load: f64,
    pub confidence: f64,
    pub tier: String,
    pub inputs_used: Vec<String>,
}

#[derive(Debug, Serialize)]
pub struct LoadOut {
    pub acwr: Option<f64>,
    pub acute: f64,
    pub chronic: f64,
    pub band: String,
    pub confidence: f64,
    pub tier: String,
    pub inputs_used: Vec<String>,
}

#[derive(Debug, Serialize)]
pub struct FitnessTrendOut {
    pub direction: String,
    pub rhr_slope: f64,
    pub hrr_slope: f64,
    pub days_used: u32,
    pub confidence: f64,
    pub tier: String,
    pub inputs_used: Vec<String>,
}

#[derive(Debug, Serialize)]
pub struct Spo2Out {
    pub index: Option<f64>,
    pub night_ratio: Option<f64>,
    pub confidence: f64,
    pub tier: String,
    pub inputs_used: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub drivers: Option<Vec<Driver>>,
}

#[derive(Debug, Serialize)]
pub struct DesaturationOut {
    pub events: u32,
    pub odi: Option<f64>,
    pub deepest_pct: Option<f64>,
    pub note: String,
    pub confidence: f64,
    pub tier: String,
    pub inputs_used: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub drivers: Option<Vec<Driver>>,
}

#[derive(Debug, Serialize)]
pub struct RestlessnessOut {
    pub score: Option<f64>,
    pub restless_min: u32,
    pub movement_bouts: u32,
    pub mobility_pct: Option<f64>,
    pub longest_still_min: u32,
    pub confidence: f64,
    pub tier: String,
    pub inputs_used: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub drivers: Option<Vec<Driver>>,
}

#[derive(Debug, Serialize)]
pub struct SleepStressEvent {
    pub ts: f64,
    pub kind: String,
}

#[derive(Debug, Serialize)]
pub struct SleepStressOut {
    pub score: Option<f64>,
    pub arousal_events: u32,
    pub restless_min: u32,
    pub mean_sleeping_hr: Option<f64>,
    pub events: Vec<SleepStressEvent>,
    pub confidence: f64,
    pub tier: String,
    pub inputs_used: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub drivers: Option<Vec<Driver>>,
}

#[derive(Debug, Serialize)]
pub struct BaselinesOut {
    pub resting_hr: Option<f64>,
    pub sleep_need_min: Option<f64>,
    pub skin_temp: Option<f64>,
    pub max_hr: Option<f64>,
    pub max_hr_source: String,
    pub chronic_strain: Option<f64>,
    pub zone_min: Option<[f64; 5]>,
    pub days_used: u32,
    pub confidence: f64,
    pub tier: String,
    pub inputs_used: Vec<String>,
}

#[derive(Debug, Serialize)]
pub struct IllnessOut {
    pub signal: bool,
    pub distance: Option<f64>,
    pub triggers: Vec<String>,
    pub note: String,
    pub confidence: f64,
    pub tier: String,
    pub inputs_used: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub drivers: Option<Vec<Driver>>,
}

#[derive(Debug, Serialize)]
pub struct AnomalyOut {
    pub signal: bool,
    pub triggers: Vec<String>,
    pub note: String,
    pub confidence: f64,
    pub tier: String,
    pub inputs_used: Vec<String>,
}

#[derive(Debug, Serialize)]
pub struct CycleOut {
    pub cycle_day: Option<i64>,
    pub phase: String,
    pub mean_length: Option<i64>,
    pub length_history: Vec<i64>,
    pub last_start: Option<String>,
    pub predicted_next: Option<String>,
    pub days_until_next: Option<i64>,
    pub ovulation_est: Option<String>,
    pub fertile_start: Option<String>,
    pub fertile_end: Option<String>,
    pub note: String,
    pub confidence: f64,
    pub tier: String,
    pub inputs_used: Vec<String>,
}

#[derive(Debug, Serialize)]
pub struct SleepCycle {
    pub start_ts: f64,
    pub end_ts: f64,
    pub duration_min: i64,
}

#[derive(Debug, Serialize)]
pub struct ZPoint {
    pub t: f64,
    pub z: f64,
}

#[derive(Debug, Serialize)]
pub struct SleepCyclesOut {
    pub cycles: Vec<SleepCycle>,
    pub mean_duration_min: Option<i64>,
    pub n: u32,
    pub series: Vec<ZPoint>,
}

#[derive(Debug, Serialize)]
pub struct SessionZones {
    pub zone1_min: u32,
    pub zone2_min: u32,
    pub zone3_min: u32,
    pub zone4_min: u32,
    pub zone5_min: u32,
    pub max_hr_used: f64,
    pub max_hr_source: String,
}

#[derive(Debug, Serialize)]
pub struct SessionOut {
    pub start_ts: f64,
    pub end_ts: f64,
    pub duration_min: f64,
    pub avg_hr: f64,
    pub max_hr: f64,
    pub strain: f64,
    pub trimp: f64,
    pub kcal: f64,
    pub zones: SessionZones,
    pub hrr60: Option<f64>,
    pub mean_activity: f64,
    pub peak_activity: f64,
    #[serde(rename = "type")]
    pub ty: String,
    pub type_confidence: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub segments: Option<Vec<crate::har::WorkoutSegment>>,
    pub detected_type: String,
    pub confidence: f64,
    pub tier: String,
    pub inputs_used: Vec<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct SleepStages {
    pub light_min: u32,
    pub deep_min: u32,
    pub rem_min: u32,
}

#[derive(Debug, Serialize)]
pub struct SleepOut {
    pub onset_ts: Option<f64>,
    pub wake_ts: Option<f64>,
    pub duration_min: u32,
    pub in_bed_min: u32,
    pub efficiency: f64,
    pub stages: Option<SleepStages>,
    pub stages_beta: bool,
    pub confidence: f64,
    pub tier: String,
    pub inputs_used: Vec<String>,
}

#[derive(Debug, Serialize)]
pub struct SleepPeriod {
    pub onset_ts: f64,
    pub wake_ts: f64,
    pub duration_min: u32,
    pub in_bed_min: u32,
    pub efficiency: f64,
    pub stages: Option<SleepStages>,
    pub is_main: bool,
    pub confidence: f64,
}

#[derive(Debug, Serialize)]
pub struct SleepPeriodsOut {
    pub periods: Vec<SleepPeriod>,
    pub total_asleep_min: u32,
    pub main_idx: Option<usize>,
    pub stages_beta: bool,
    pub confidence: f64,
    pub tier: String,
    pub inputs_used: Vec<String>,
}

#[derive(Debug, Serialize)]
pub struct HypnoPoint {
    pub t: f64,
    pub stage: String,
}

#[derive(Debug, Serialize)]
pub struct NightHypnogram {
    pub hypnogram: Vec<HypnoPoint>,
    pub light_min: u32,
    pub deep_min: u32,
    pub rem_min: u32,
    pub awake_min: u32,
    pub asleep_min: u32,
}

#[derive(Debug, Serialize)]
pub struct CircadianOut {
    pub mesor: Option<f64>,
    pub amplitude: Option<f64>,
    pub acrophase_ts: Option<f64>,
    pub bathyphase_ts: Option<f64>,
    pub onset_ts: Option<f64>,
    pub wake_ts: Option<f64>,
    pub in_bed_min: i64,
    pub settled: bool,
    pub confidence: f64,
    pub tier: String,
    pub inputs_used: Vec<String>,
}

#[derive(Debug, Serialize)]
pub struct WakeStateOut {
    pub state: String,
    pub wake_ts: Option<f64>,
    pub onset_ts: Option<f64>,
    pub awake_min: i64,
    pub asleep_min: i64,
    pub votes: std::collections::BTreeMap<String, String>,
    pub confidence: f64,
}

#[derive(Debug, Serialize)]
pub struct SleepStagingOut {
    pub in_bed_min: i64,
    pub asleep_min: u32,
    pub efficiency: f64,
    pub awake_min: u32,
    pub light_min: u32,
    pub deep_min: u32,
    pub rem_min: u32,
    pub hypnogram: Vec<HypnoPoint>,
}

/// Minute with HR + RR for the circadian stager.
#[derive(Debug, Clone, Deserialize)]
pub struct StageMin {
    pub ts: f64,
    #[serde(default)]
    pub hr_avg: f64,
    #[serde(default)]
    pub rr: Vec<f64>,
}

/// Illness `today` vector (matches IllnessToday).
#[derive(Debug, Clone, Deserialize)]
pub struct IllnessToday {
    #[serde(default)]
    pub resting_hr: Option<f64>,
    #[serde(default)]
    pub rmssd: Option<f64>,
    #[serde(default)]
    pub skin_temp: Option<f64>,
    #[serde(default)]
    pub resp_rate: Option<f64>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct IllnessHistory {
    #[serde(default)]
    pub resting_hr: Vec<f64>,
    #[serde(default)]
    pub rmssd: Vec<f64>,
    #[serde(default)]
    pub skin_temp: Vec<f64>,
    #[serde(default)]
    pub resp_rate: Vec<f64>,
}
