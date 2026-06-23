// openstrap-core — single Rust analytics implementation. Compiles to:
//   • wasm (Cloudflare Worker / web)  — wasm-bindgen JSON string in/out below
//   • native (Flutter via FFI; cargo test parity harness)
// Slice 1 (seam proof): util, types, resting, strain, time-domain HRV.
mod arousal;
mod baselines;
mod calories;
mod circadian;
mod coach;
mod cycle;
mod cycles;
mod fitness;
mod har;
mod hrv;
mod illness;
mod sessions;
mod sleep;
mod nocturnal;
mod notify;
mod readiness;
mod readiness_index;
mod recovery;
mod regularity;
mod restlessness;
mod resting;
mod spo2;
mod steps;
mod strain;
mod stress;
mod trends;
mod wake;
mod types;
mod util;
mod zones;

use serde::Deserialize;
use types::{
    Baseline, DailyStrain, DayHistory, IllnessHistory, IllnessToday, Minute, MinuteRr, NightSummary,
    Profile, SleepWindow, StageMin,
};
use wasm_bindgen::prelude::*;

// ── wasm boundary: JSON string in → JSON string out. The TS worker / Flutter
//    pass a JSON payload and parse the returned JSON. One contract, every host. ──

#[derive(Deserialize)]
struct StrainReq {
    minutes: Vec<Minute>,
    baseline: Baseline,
    #[serde(default)]
    profile: Option<Profile>,
}

#[wasm_bindgen]
pub fn calc_strain(req_json: &str) -> String {
    match serde_json::from_str::<StrainReq>(req_json) {
        Ok(r) => {
            let out = strain::calc_strain(&r.minutes, &r.baseline, r.profile.as_ref());
            serde_json::to_string(&out).unwrap_or_else(|e| err(&e.to_string()))
        }
        Err(e) => err(&e.to_string()),
    }
}

#[derive(Deserialize)]
struct RestingReq {
    minutes: Vec<Minute>,
    #[serde(default)]
    sleep_window: Option<SleepWindow>,
}

#[wasm_bindgen]
pub fn calc_resting_hr(req_json: &str) -> String {
    match serde_json::from_str::<RestingReq>(req_json) {
        Ok(r) => {
            let out = resting::calc_resting_hr(&r.minutes, r.sleep_window.as_ref());
            serde_json::to_string(&out).unwrap_or_else(|e| err(&e.to_string()))
        }
        Err(e) => err(&e.to_string()),
    }
}

#[derive(Deserialize)]
struct HrvReq {
    rr: Vec<f64>,
}

#[wasm_bindgen]
pub fn time_domain_hrv(req_json: &str) -> String {
    match serde_json::from_str::<HrvReq>(req_json) {
        Ok(r) => {
            let out = hrv::time_domain_hrv(&r.rr);
            serde_json::to_string(&out).unwrap_or_else(|e| err(&e.to_string()))
        }
        Err(e) => err(&e.to_string()),
    }
}

#[derive(Deserialize)]
struct HrvReq2 {
    rr: Vec<f64>,
}

#[wasm_bindgen]
pub fn freq_domain_hrv(req_json: &str) -> String {
    match serde_json::from_str::<HrvReq2>(req_json) {
        Ok(r) => serde_json::to_string(&hrv::freq_domain_hrv(&r.rr)).unwrap_or_else(|e| err(&e.to_string())),
        Err(e) => err(&e.to_string()),
    }
}

#[wasm_bindgen]
pub fn baevsky_stress_index(req_json: &str) -> String {
    match serde_json::from_str::<HrvReq2>(req_json) {
        Ok(r) => serde_json::to_string(&hrv::baevsky_stress_index(&r.rr)).unwrap_or_else(|e| err(&e.to_string())),
        Err(e) => err(&e.to_string()),
    }
}

#[derive(Deserialize)]
struct SeriesReq {
    series: Vec<f64>,
}

#[wasm_bindgen]
pub fn calc_hrv_stability(req_json: &str) -> String {
    match serde_json::from_str::<SeriesReq>(req_json) {
        Ok(r) => serde_json::to_string(&hrv::calc_hrv_stability(&r.series)).unwrap_or_else(|e| err(&e.to_string())),
        Err(e) => err(&e.to_string()),
    }
}

#[wasm_bindgen]
pub fn calc_irregular(req_json: &str) -> String {
    match serde_json::from_str::<HrvReq2>(req_json) {
        Ok(r) => serde_json::to_string(&hrv::calc_irregular(&r.rr)).unwrap_or_else(|e| err(&e.to_string())),
        Err(e) => err(&e.to_string()),
    }
}

#[derive(Deserialize)]
struct DaytimeReq {
    by_minute: Vec<MinuteRr>,
    #[serde(default = "default_bucket")]
    bucket_sec: f64,
}
fn default_bucket() -> f64 {
    300.0
}

#[wasm_bindgen]
pub fn calc_daytime_hrv(req_json: &str) -> String {
    match serde_json::from_str::<DaytimeReq>(req_json) {
        Ok(r) => serde_json::to_string(&hrv::calc_daytime_hrv(&r.by_minute, r.bucket_sec)).unwrap_or_else(|e| err(&e.to_string())),
        Err(e) => err(&e.to_string()),
    }
}

#[derive(Deserialize)]
struct ZonesReq {
    minutes: Vec<Minute>,
    baseline: Baseline,
    #[serde(default)]
    profile: Option<Profile>,
}

#[wasm_bindgen]
pub fn calc_hr_zones(req_json: &str) -> String {
    match serde_json::from_str::<ZonesReq>(req_json) {
        Ok(r) => serde_json::to_string(&zones::calc_hr_zones(&r.minutes, &r.baseline, r.profile.as_ref())).unwrap_or_else(|e| err(&e.to_string())),
        Err(e) => err(&e.to_string()),
    }
}

#[derive(Deserialize)]
struct CaloriesReq {
    minutes: Vec<Minute>,
    profile: Profile,
    #[serde(default)]
    resting_hr: Option<f64>,
    #[serde(default)]
    max_hr: Option<f64>,
}

#[wasm_bindgen]
pub fn calc_calories(req_json: &str) -> String {
    match serde_json::from_str::<CaloriesReq>(req_json) {
        Ok(r) => serde_json::to_string(&calories::calc_calories(&r.minutes, &r.profile, r.resting_hr, r.max_hr)).unwrap_or_else(|e| err(&e.to_string())),
        Err(e) => err(&e.to_string()),
    }
}

#[derive(Deserialize)]
struct RecoveryReq {
    rmssd_today: Option<f64>,
    #[serde(default)]
    baseline_rmssd: Vec<f64>,
    #[serde(default)]
    date: Option<String>,
}

#[wasm_bindgen]
pub fn calc_recovery(req_json: &str) -> String {
    match serde_json::from_str::<RecoveryReq>(req_json) {
        Ok(r) => serde_json::to_string(&recovery::calc_recovery(r.rmssd_today, &r.baseline_rmssd, r.date.as_deref())).unwrap_or_else(|e| err(&e.to_string())),
        Err(e) => err(&e.to_string()),
    }
}

#[derive(Deserialize)]
struct HrRecoveryReq {
    minutes: Vec<Minute>,
    baseline: Baseline,
    #[serde(default)]
    profile: Option<Profile>,
}

#[wasm_bindgen]
pub fn calc_hr_recovery(req_json: &str) -> String {
    match serde_json::from_str::<HrRecoveryReq>(req_json) {
        Ok(r) => serde_json::to_string(&recovery::calc_hr_recovery(&r.minutes, &r.baseline, r.profile.as_ref())).unwrap_or_else(|e| err(&e.to_string())),
        Err(e) => err(&e.to_string()),
    }
}

#[derive(Deserialize)]
struct StressReq {
    rr: Vec<f64>,
    #[serde(default)]
    baseline_si: Vec<f64>,
    #[serde(default)]
    date: Option<String>,
}

#[wasm_bindgen]
pub fn calc_stress(req_json: &str) -> String {
    match serde_json::from_str::<StressReq>(req_json) {
        Ok(r) => serde_json::to_string(&stress::calc_stress(&r.rr, &r.baseline_si, r.date.as_deref())).unwrap_or_else(|e| err(&e.to_string())),
        Err(e) => err(&e.to_string()),
    }
}

#[derive(Deserialize)]
struct NocturnalReq {
    sleep_minutes: Vec<Minute>,
    #[serde(default)]
    day_minutes: Vec<Minute>,
    baseline: Baseline,
}
#[wasm_bindgen]
pub fn calc_nocturnal_heart(req_json: &str) -> String {
    match serde_json::from_str::<NocturnalReq>(req_json) {
        Ok(r) => serde_json::to_string(&nocturnal::calc_nocturnal_heart(&r.sleep_minutes, &r.day_minutes, &r.baseline)).unwrap_or_else(|e| err(&e.to_string())),
        Err(e) => err(&e.to_string()),
    }
}

#[derive(Deserialize)]
struct NightsReq {
    nights: Vec<NightSummary>,
}
#[wasm_bindgen]
pub fn calc_sleep_regularity(req_json: &str) -> String {
    match serde_json::from_str::<NightsReq>(req_json) {
        Ok(r) => serde_json::to_string(&regularity::calc_sleep_regularity(&r.nights)).unwrap_or_else(|e| err(&e.to_string())),
        Err(e) => err(&e.to_string()),
    }
}

#[derive(Deserialize)]
struct StrainSeriesReq {
    daily_strain: Vec<DailyStrain>,
}
#[wasm_bindgen]
pub fn calc_load(req_json: &str) -> String {
    match serde_json::from_str::<StrainSeriesReq>(req_json) {
        Ok(r) => serde_json::to_string(&trends::calc_load(&r.daily_strain)).unwrap_or_else(|e| err(&e.to_string())),
        Err(e) => err(&e.to_string()),
    }
}
#[wasm_bindgen]
pub fn calc_fitness_model(req_json: &str) -> String {
    match serde_json::from_str::<StrainSeriesReq>(req_json) {
        Ok(r) => serde_json::to_string(&fitness::calc_fitness_model(&r.daily_strain)).unwrap_or_else(|e| err(&e.to_string())),
        Err(e) => err(&e.to_string()),
    }
}
#[wasm_bindgen]
pub fn calc_monotony(req_json: &str) -> String {
    match serde_json::from_str::<StrainSeriesReq>(req_json) {
        Ok(r) => serde_json::to_string(&fitness::calc_monotony(&r.daily_strain)).unwrap_or_else(|e| err(&e.to_string())),
        Err(e) => err(&e.to_string()),
    }
}

#[derive(Deserialize)]
struct DailyHistReq {
    daily: Vec<DayHistory>,
}
#[wasm_bindgen]
pub fn calc_fitness_trend(req_json: &str) -> String {
    match serde_json::from_str::<DailyHistReq>(req_json) {
        Ok(r) => serde_json::to_string(&trends::calc_fitness_trend(&r.daily)).unwrap_or_else(|e| err(&e.to_string())),
        Err(e) => err(&e.to_string()),
    }
}

#[derive(Deserialize)]
struct Vo2Req {
    max_hr: Option<f64>,
    resting_hr: Option<f64>,
}
#[wasm_bindgen]
pub fn calc_vo2max(req_json: &str) -> String {
    match serde_json::from_str::<Vo2Req>(req_json) {
        Ok(r) => serde_json::to_string(&fitness::calc_vo2max(r.max_hr, r.resting_hr)).unwrap_or_else(|e| err(&e.to_string())),
        Err(e) => err(&e.to_string()),
    }
}

#[derive(Deserialize)]
struct ReadinessReq {
    #[serde(default)]
    recovery: Option<f64>,
    #[serde(default)]
    sleep_duration_min: Option<f64>,
    #[serde(default)]
    sleep_need_min: Option<f64>,
    #[serde(default)]
    dip_pct: Option<f64>,
    #[serde(default)]
    sleep_stress: Option<f64>,
}
#[wasm_bindgen]
pub fn calc_readiness_index(req_json: &str) -> String {
    match serde_json::from_str::<ReadinessReq>(req_json) {
        Ok(r) => {
            let inp = readiness_index::ReadinessInputs {
                recovery: r.recovery, sleep_duration_min: r.sleep_duration_min,
                sleep_need_min: r.sleep_need_min, dip_pct: r.dip_pct, sleep_stress: r.sleep_stress,
            };
            serde_json::to_string(&readiness_index::calc_readiness_index(&inp)).unwrap_or_else(|e| err(&e.to_string()))
        }
        Err(e) => err(&e.to_string()),
    }
}

#[derive(Deserialize)]
struct Spo2Req {
    ratios: Vec<f64>,
    #[serde(default)]
    baseline_ratio: Option<f64>,
}
#[wasm_bindgen]
pub fn calc_spo2_index(req_json: &str) -> String {
    match serde_json::from_str::<Spo2Req>(req_json) {
        Ok(r) => serde_json::to_string(&spo2::calc_spo2_index(&r.ratios, r.baseline_ratio)).unwrap_or_else(|e| err(&e.to_string())),
        Err(e) => err(&e.to_string()),
    }
}
#[wasm_bindgen]
pub fn calc_desaturation(req_json: &str) -> String {
    match serde_json::from_str::<Spo2Req>(req_json) {
        Ok(r) => serde_json::to_string(&spo2::calc_desaturation(&r.ratios, r.baseline_ratio)).unwrap_or_else(|e| err(&e.to_string())),
        Err(e) => err(&e.to_string()),
    }
}

#[derive(Deserialize)]
struct StepsReq {
    minute_signals: Vec<Vec<f64>>,
}
#[wasm_bindgen]
pub fn calc_steps(req_json: &str) -> String {
    match serde_json::from_str::<StepsReq>(req_json) {
        Ok(r) => serde_json::to_string(&serde_json::json!({ "steps": steps::calc_steps(&r.minute_signals) })).unwrap_or_else(|e| err(&e.to_string())),
        Err(e) => err(&e.to_string()),
    }
}

#[derive(Deserialize)]
struct SleepMinutesReq {
    sleep_minutes: Vec<Minute>,
    #[serde(default)]
    baseline: Option<Baseline>,
}
#[wasm_bindgen]
pub fn calc_restlessness(req_json: &str) -> String {
    match serde_json::from_str::<SleepMinutesReq>(req_json) {
        Ok(r) => serde_json::to_string(&restlessness::calc_restlessness(&r.sleep_minutes)).unwrap_or_else(|e| err(&e.to_string())),
        Err(e) => err(&e.to_string()),
    }
}
#[wasm_bindgen]
pub fn calc_sleep_stress(req_json: &str) -> String {
    match serde_json::from_str::<SleepMinutesReq>(req_json) {
        Ok(r) => {
            let b = r.baseline.unwrap_or(Baseline { resting_hr: 0.0, max_hr: 0.0, sleep_need_min: 0.0, skin_temp: None, chronic_strain: None, sleeping_hr: None });
            serde_json::to_string(&arousal::calc_sleep_stress(&r.sleep_minutes, &b)).unwrap_or_else(|e| err(&e.to_string()))
        }
        Err(e) => err(&e.to_string()),
    }
}

#[derive(Deserialize)]
struct BaselinesReq {
    history: Vec<DayHistory>,
    #[serde(default)]
    profile: Option<Profile>,
}
#[wasm_bindgen]
pub fn calc_baselines(req_json: &str) -> String {
    match serde_json::from_str::<BaselinesReq>(req_json) {
        Ok(r) => serde_json::to_string(&baselines::calc_baselines(&r.history, r.profile.as_ref())).unwrap_or_else(|e| err(&e.to_string())),
        Err(e) => err(&e.to_string()),
    }
}

#[derive(Deserialize)]
struct IllnessReq {
    today: IllnessToday,
    history: IllnessHistory,
    #[serde(default)]
    cycle_phase: Option<String>,
}
#[wasm_bindgen]
pub fn calc_illness(req_json: &str) -> String {
    match serde_json::from_str::<IllnessReq>(req_json) {
        Ok(r) => serde_json::to_string(&illness::calc_illness(&r.today, &r.history, r.cycle_phase.as_deref())).unwrap_or_else(|e| err(&e.to_string())),
        Err(e) => err(&e.to_string()),
    }
}

#[derive(Deserialize)]
struct AnomalyReq {
    #[serde(default)]
    recent_rhr: Vec<f64>,
    #[serde(default)]
    skin_temp: Option<f64>,
    #[serde(default)]
    sleep_efficiency: Option<f64>,
    #[serde(default)]
    baseline_sleep_efficiency: Option<f64>,
    baseline: Baseline,
    #[serde(default)]
    cycle_phase: Option<String>,
}
#[wasm_bindgen]
pub fn calc_anomaly(req_json: &str) -> String {
    match serde_json::from_str::<AnomalyReq>(req_json) {
        Ok(r) => {
            let inp = readiness::AnomalyInputs {
                recent_rhr: r.recent_rhr, skin_temp: r.skin_temp,
                sleep_efficiency: r.sleep_efficiency, baseline_sleep_efficiency: r.baseline_sleep_efficiency,
            };
            serde_json::to_string(&readiness::calc_anomaly(&inp, &r.baseline, r.cycle_phase.as_deref())).unwrap_or_else(|e| err(&e.to_string()))
        }
        Err(e) => err(&e.to_string()),
    }
}

#[derive(Deserialize)]
struct CycleReq {
    #[serde(default)]
    starts: Vec<String>,
    today: String,
}
#[wasm_bindgen]
pub fn calc_cycle(req_json: &str) -> String {
    match serde_json::from_str::<CycleReq>(req_json) {
        Ok(r) => serde_json::to_string(&cycle::calc_cycle(&r.starts, &r.today)).unwrap_or_else(|e| err(&e.to_string())),
        Err(e) => err(&e.to_string()),
    }
}

#[derive(Deserialize)]
struct SleepCyclesReq { minutes: Vec<MinuteRr>, onset: f64, wake: f64 }
#[wasm_bindgen]
pub fn detect_sleep_cycles(req_json: &str) -> String {
    match serde_json::from_str::<SleepCyclesReq>(req_json) {
        Ok(r) => serde_json::to_string(&cycles::detect_sleep_cycles(&r.minutes, r.onset, r.wake)).unwrap_or_else(|e| err(&e.to_string())),
        Err(e) => err(&e.to_string()),
    }
}

#[derive(Deserialize)]
struct HarSmvReq {
    smv: Vec<f64>,
    fs: f64,
    #[serde(default)]
    prev_dom_freq: f64,
}
#[wasm_bindgen]
pub fn extract_har_features(req_json: &str) -> String {
    match serde_json::from_str::<HarSmvReq>(req_json) {
        Ok(r) => serde_json::to_string(&har::extract_har_features_from_smv(&r.smv, r.fs, r.prev_dom_freq)).unwrap_or_else(|e| err(&e.to_string())),
        Err(e) => err(&e.to_string()),
    }
}
#[wasm_bindgen]
pub fn classify_activity(req_json: &str) -> String {
    match serde_json::from_str::<HarSmvReq>(req_json) {
        Ok(r) => {
            let f = har::extract_har_features_from_smv(&r.smv, r.fs, r.prev_dom_freq);
            let (cls, confidence) = har::classify_activity_window(&f);
            serde_json::to_string(&serde_json::json!({ "cls": cls, "confidence": confidence })).unwrap_or_else(|e| err(&e.to_string()))
        }
        Err(e) => err(&e.to_string()),
    }
}

#[derive(Deserialize)]
struct SegmentReq {
    votes: Vec<har::ClassVote>,
    #[serde(default = "default_smooth")]
    smooth_win: usize,
    #[serde(default = "default_min_phase")]
    min_phase_sec: f64,
}
fn default_smooth() -> usize {
    7
}
fn default_min_phase() -> f64 {
    180.0
}
#[wasm_bindgen]
pub fn segment_workout(req_json: &str) -> String {
    match serde_json::from_str::<SegmentReq>(req_json) {
        Ok(r) => serde_json::to_string(&har::segment_workout(&r.votes, r.smooth_win, r.min_phase_sec)).unwrap_or_else(|e| err(&e.to_string())),
        Err(e) => err(&e.to_string()),
    }
}

#[derive(Deserialize)]
struct SessionsReq {
    minutes: Vec<Minute>,
    baseline: Baseline,
    #[serde(default)]
    profile: Option<Profile>,
}
#[wasm_bindgen]
pub fn detect_sessions(req_json: &str) -> String {
    match serde_json::from_str::<SessionsReq>(req_json) {
        Ok(r) => serde_json::to_string(&sessions::detect_sessions(&r.minutes, &r.baseline, r.profile.as_ref())).unwrap_or_else(|e| err(&e.to_string())),
        Err(e) => err(&e.to_string()),
    }
}

#[derive(Deserialize)]
struct SleepReq { minutes: Vec<Minute>, baseline: Baseline }
#[wasm_bindgen]
pub fn calc_sleep(req_json: &str) -> String {
    match serde_json::from_str::<SleepReq>(req_json) {
        Ok(r) => serde_json::to_string(&sleep::calc_sleep(&r.minutes, &r.baseline)).unwrap_or_else(|e| err(&e.to_string())),
        Err(e) => err(&e.to_string()),
    }
}
#[wasm_bindgen]
pub fn calc_sleep_periods(req_json: &str) -> String {
    match serde_json::from_str::<SleepReq>(req_json) {
        Ok(r) => serde_json::to_string(&sleep::calc_sleep_periods(&r.minutes, &r.baseline)).unwrap_or_else(|e| err(&e.to_string())),
        Err(e) => err(&e.to_string()),
    }
}

#[derive(Deserialize)]
struct HypnoReq { minutes: Vec<Minute>, onset: f64, wake: f64, baseline: Baseline, #[serde(default)] rr_by_min: Vec<MinuteRr> }
#[wasm_bindgen]
pub fn stage_hypnogram(req_json: &str) -> String {
    match serde_json::from_str::<HypnoReq>(req_json) {
        Ok(r) => {
            let map: std::collections::HashMap<u64, Vec<f64>> = r.rr_by_min.iter().map(|m| (m.ts.to_bits(), m.rr.clone())).collect();
            let opt = if map.is_empty() { None } else { Some(&map) };
            match sleep::stage_hypnogram(&r.minutes, r.onset, r.wake, &r.baseline, opt) {
                Some(h) => serde_json::to_string(&h).unwrap_or_else(|e| err(&e.to_string())),
                None => "null".to_string(),
            }
        }
        Err(e) => err(&e.to_string()),
    }
}

fn err(msg: &str) -> String {
    format!("{{\"error\":{}}}", serde_json::to_string(msg).unwrap())
}

// ── Native parity tests: deterministic oracles lifted from analytics.test.ts ──
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hrv_alternating_800_820_rmssd_20() {
        // analytics.test.ts:564 — alternating 800/820 → RMSSD = 20, SDNN = 10.
        let rr: Vec<f64> = (0..40).map(|i| if i % 2 == 0 { 800.0 } else { 820.0 }).collect();
        let td = hrv::time_domain_hrv(&rr);
        assert!((td.rmssd.unwrap() - 20.0).abs() < 0.01, "rmssd {:?}", td.rmssd);
        // SDNN uses the (n-1) sample variance exactly like the TS: sqrt(40*100/39)=10.1.
        assert!((td.sdnn.unwrap() - 10.1).abs() < 0.01, "sdnn {:?}", td.sdnn);
        assert_eq!(td.pnn50.unwrap(), 0.0);
        assert_eq!(td.n_beats, 40);
        assert!((td.mean_rr.unwrap() - 810.0).abs() < 0.01);
    }

    #[test]
    fn hrv_too_few_beats_null() {
        let td = hrv::time_domain_hrv(&[800.0, 820.0, 800.0]);
        assert!(td.rmssd.is_none());
        assert_eq!(td.n_beats, 3);
    }

    #[test]
    fn strain_bounded_at_21() {
        // analytics.test.ts:92 — insane HR can't exceed 21.
        let mins: Vec<Minute> = (0..600)
            .map(|i| Minute {
                ts: i as f64 * 60.0,
                hr_avg: 250.0,
                hr_min: 250.0,
                hr_max: 250.0,
                hr_n: 60.0,
                activity: 0.0,
                steps: 0.0,
                wrist_on: true,
                act_class: None,
            })
            .collect();
        let b = Baseline { resting_hr: 50.0, max_hr: 190.0, sleep_need_min: 480.0, skin_temp: None, chronic_strain: None, sleeping_hr: None };
        let s = strain::calc_strain(&mins, &b, None);
        assert!(s.score <= 21.0, "score {}", s.score);
    }

    #[test]
    fn strain_rest_is_low() {
        let mins: Vec<Minute> = (0..60)
            .map(|i| Minute { ts: i as f64 * 60.0, hr_avg: 52.0, hr_min: 50.0, hr_max: 54.0, hr_n: 60.0, activity: 0.0, steps: 0.0, wrist_on: true, act_class: None })
            .collect();
        let b = Baseline { resting_hr: 50.0, max_hr: 190.0, sleep_need_min: 480.0, skin_temp: None, chronic_strain: None, sleeping_hr: None };
        let s = strain::calc_strain(&mins, &b, None);
        assert!(s.score < 3.0, "rest strain should be low, got {}", s.score);
        assert_eq!(s.max_hr_source, "measured"); // baseline.max_hr > 0
    }

    #[test]
    fn resting_window_5th_pctile() {
        // 5 worn minutes 60..64 bpm in window → 5th pctile ≈ 60.2.
        let mins: Vec<Minute> = (0..5)
            .map(|i| Minute { ts: i as f64 * 60.0, hr_avg: 60.0 + i as f64, hr_min: 60.0, hr_max: 64.0, hr_n: 60.0, activity: 0.0, steps: 0.0, wrist_on: true, act_class: None })
            .collect();
        let sw = SleepWindow { onset_ts: Some(0.0), wake_ts: Some(5.0 * 60.0) };
        let r = resting::calc_resting_hr(&mins, Some(&sw));
        let rhr = r.resting_hr.unwrap();
        assert!(rhr >= 60.0 && rhr <= 61.0, "rhr {}", rhr);
    }

    #[test]
    fn parity_real_data_vs_ts() {
        // Reads the decoded-from-whoop_hist inputs + TS outputs produced by
        // scripts/oracle.ts and asserts the Rust core reproduces them exactly.
        let input = std::fs::read_to_string("parity_input.json")
            .expect("run `npx tsx scripts/oracle.ts` first");
        let ts = std::fs::read_to_string("parity_ts.json").unwrap();
        let inp: serde_json::Value = serde_json::from_str(&input).unwrap();
        let exp: serde_json::Value = serde_json::from_str(&ts).unwrap();

        let hrv_req: HrvReq = serde_json::from_value(inp["rr"].clone()).unwrap();
        let strain_req: StrainReq = serde_json::from_value(inp["strain"].clone()).unwrap();
        let rest_req: RestingReq = serde_json::from_value(inp["resting"].clone()).unwrap();

        let got_hrv = serde_json::to_value(hrv::time_domain_hrv(&hrv_req.rr)).unwrap();
        let got_strain =
            serde_json::to_value(strain::calc_strain(&strain_req.minutes, &strain_req.baseline, strain_req.profile.as_ref())).unwrap();
        let got_rest = serde_json::to_value(resting::calc_resting_hr(&rest_req.minutes, rest_req.sleep_window.as_ref())).unwrap();

        assert!(json_num_eq(&got_hrv, &exp["hrv"]), "HRV mismatch\n got {}\n exp {}", got_hrv, exp["hrv"]);
        assert!(json_num_eq(&got_strain, &exp["strain"]), "strain mismatch\n got {}\n exp {}", got_strain, exp["strain"]);
        assert!(json_num_eq(&got_rest, &exp["resting"]), "resting mismatch\n got {}\n exp {}", got_rest, exp["resting"]);
    }

    /// Deep JSON equality that compares numbers by f64 value (so 190 == 190.0;
    /// serde tags ints/floats differently but the metric values are identical).
    fn json_num_eq(a: &serde_json::Value, b: &serde_json::Value) -> bool {
        use serde_json::Value::*;
        match (a, b) {
            (Number(x), Number(y)) => (x.as_f64().unwrap() - y.as_f64().unwrap()).abs() < 1e-9,
            (Array(x), Array(y)) => x.len() == y.len() && x.iter().zip(y).all(|(i, j)| json_num_eq(i, j)),
            (Object(x), Object(y)) => {
                x.len() == y.len() && x.iter().all(|(k, v)| y.get(k).map_or(false, |w| json_num_eq(v, w)))
            }
            _ => a == b,
        }
    }

    fn dispatch(name: &str, j: &str) -> Option<String> {
        Some(match name {
            "calc_strain" => super::calc_strain(j),
            "calc_resting_hr" => super::calc_resting_hr(j),
            "time_domain_hrv" => super::time_domain_hrv(j),
            "freq_domain_hrv" => super::freq_domain_hrv(j),
            "baevsky_stress_index" => super::baevsky_stress_index(j),
            "calc_hrv_stability" => super::calc_hrv_stability(j),
            "calc_irregular" => super::calc_irregular(j),
            "calc_daytime_hrv" => super::calc_daytime_hrv(j),
            "calc_hr_zones" => super::calc_hr_zones(j),
            "calc_calories" => super::calc_calories(j),
            "calc_recovery" => super::calc_recovery(j),
            "calc_hr_recovery" => super::calc_hr_recovery(j),
            "calc_stress" => super::calc_stress(j),
            "calc_nocturnal_heart" => super::calc_nocturnal_heart(j),
            "calc_sleep_regularity" => super::calc_sleep_regularity(j),
            "calc_load" => super::calc_load(j),
            "calc_fitness_model" => super::calc_fitness_model(j),
            "calc_monotony" => super::calc_monotony(j),
            "calc_fitness_trend" => super::calc_fitness_trend(j),
            "calc_vo2max" => super::calc_vo2max(j),
            "calc_readiness_index" => super::calc_readiness_index(j),
            "calc_spo2_index" => super::calc_spo2_index(j),
            "calc_desaturation" => super::calc_desaturation(j),
            "calc_steps" => super::calc_steps(j),
            "calc_restlessness" => super::calc_restlessness(j),
            "calc_sleep_stress" => super::calc_sleep_stress(j),
            "calc_baselines" => super::calc_baselines(j),
            "calc_illness" => super::calc_illness(j),
            "calc_anomaly" => super::calc_anomaly(j),
            "calc_cycle" => super::calc_cycle(j),
            "detect_sleep_cycles" => super::detect_sleep_cycles(j),
            "calc_sleep" => super::calc_sleep(j),
            "calc_sleep_periods" => super::calc_sleep_periods(j),
            "extract_har_features" => super::extract_har_features(j),
            "classify_activity" => super::classify_activity(j),
            "segment_workout" => super::segment_workout(j),
            "detect_sessions" => super::detect_sessions(j),
            "calc_circadian" => super::calc_circadian(j),
            "stage_sleep" => super::stage_sleep(j),
            "detect_wake_state" => super::detect_wake_state(j),
            "peek_recent_state" => super::peek_recent_state(j),
            "build_coach" => super::build_coach(j),
            "build_notifications" => super::build_notifications(j),
            _ => return None,
        })
    }

    #[test]
    fn parity_all_synthetic_vs_ts() {
        let input = std::fs::read_to_string("parity_all_input.json").expect("run `npx tsx scripts/parity_all.ts`");
        let ts = std::fs::read_to_string("parity_all_ts.json").unwrap();
        let inputs: serde_json::Map<String, serde_json::Value> = serde_json::from_str(&input).unwrap();
        let expected: serde_json::Map<String, serde_json::Value> = serde_json::from_str(&ts).unwrap();
        let mut fails: Vec<String> = Vec::new();
        let mut ran = 0;
        for (name, payload) in &inputs {
            let got_str = match dispatch(name, &serde_json::to_string(payload).unwrap()) {
                Some(s) => s,
                None => { fails.push(format!("{}: NO DISPATCH", name)); continue; }
            };
            ran += 1;
            let got: serde_json::Value = serde_json::from_str(&got_str).unwrap_or(serde_json::Value::Null);
            if !json_num_eq(&got, &expected[name]) {
                fails.push(format!("{} MISMATCH\n   got: {}\n   exp: {}", name, got, expected[name]));
            }
        }
        assert!(fails.is_empty(), "{}/{} metrics diverged:\n{}", fails.len(), ran, fails.join("\n"));
        assert!(ran >= 40, "expected >=40 metrics, ran {}", ran);
    }

    #[test]
    fn json_boundary_roundtrips() {
        let out = time_domain_hrv(r#"{"rr":[800,820,800,820,800,820,800,820,800,820,800,820,800,820,800,820,800,820,800,820,800,820]}"#);
        assert!(out.contains("\"rmssd\":20"), "json out: {}", out);
    }
}

#[derive(Deserialize)]
struct CircadianReq { minutes: Vec<Minute>, #[serde(default)] now: Option<f64>, #[serde(default)] settle_sec: Option<f64>, #[serde(default)] anchor_ts: Option<f64> }
#[wasm_bindgen]
pub fn calc_circadian(req_json: &str) -> String {
    match serde_json::from_str::<CircadianReq>(req_json) {
        Ok(r) => serde_json::to_string(&circadian::calc_circadian(&r.minutes, r.now, r.settle_sec, r.anchor_ts)).unwrap_or_else(|e| err(&e.to_string())),
        Err(e) => err(&e.to_string()),
    }
}
#[derive(Deserialize)]
struct StageSleepReq { minutes: Vec<StageMin>, onset: f64, wake: f64, mesor: f64 }
#[wasm_bindgen]
pub fn stage_sleep(req_json: &str) -> String {
    match serde_json::from_str::<StageSleepReq>(req_json) {
        Ok(r) => serde_json::to_string(&circadian::stage_sleep(&r.minutes, r.onset, r.wake, r.mesor)).unwrap_or_else(|e| err(&e.to_string())),
        Err(e) => err(&e.to_string()),
    }
}
#[derive(Deserialize)]
struct WakeReq { minutes: Vec<Minute>, baseline: Baseline, #[serde(default)] rr_by_min: Vec<MinuteRr>, #[serde(default)] now: Option<f64> }
#[wasm_bindgen]
pub fn detect_wake_state(req_json: &str) -> String {
    match serde_json::from_str::<WakeReq>(req_json) {
        Ok(r) => {
            let map: std::collections::HashMap<i64, Vec<f64>> = r.rr_by_min.iter().map(|m| ((m.ts / 60.0).floor() as i64 * 60, m.rr.clone())).collect();
            let opt = if map.is_empty() { None } else { Some(&map) };
            serde_json::to_string(&wake::detect_wake_state(&r.minutes, &r.baseline, opt, r.now)).unwrap_or_else(|e| err(&e.to_string()))
        }
        Err(e) => err(&e.to_string()),
    }
}
#[derive(Deserialize)]
struct PeekReq { recent: Vec<Minute>, baseline: Baseline }
#[wasm_bindgen]
pub fn peek_recent_state(req_json: &str) -> String {
    match serde_json::from_str::<PeekReq>(req_json) {
        Ok(r) => serde_json::to_string(&serde_json::json!({ "state": wake::peek_recent_state(&r.recent, &r.baseline) })).unwrap_or_else(|e| err(&e.to_string())),
        Err(e) => err(&e.to_string()),
    }
}

#[wasm_bindgen]
pub fn build_coach(req_json: &str) -> String {
    match serde_json::from_str::<coach::CoachInputs>(req_json) {
        Ok(r) => serde_json::to_string(&coach::build_coach(&r)).unwrap_or_else(|e| err(&e.to_string())),
        Err(e) => err(&e.to_string()),
    }
}
#[wasm_bindgen]
pub fn build_notifications(req_json: &str) -> String {
    match serde_json::from_str::<notify::NotifyInputs>(req_json) {
        Ok(r) => serde_json::to_string(&notify::build_notifications(&r)).unwrap_or_else(|e| err(&e.to_string())),
        Err(e) => err(&e.to_string()),
    }
}
