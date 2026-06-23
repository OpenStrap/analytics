// Port of openstrap-analytics/src/baselines.ts — rolling 30-day medians.
use crate::types::{BaselinesOut, DayHistory, Profile};
use crate::util::{mean, median, round};

pub fn calc_baselines(history: &[DayHistory], profile: Option<&Profile>) -> BaselinesOut {
    let window: &[DayHistory] = if history.len() > 30 { &history[history.len() - 30..] } else { history };
    let days = window.len();

    let rhrs: Vec<f64> = window.iter().filter_map(|d| d.resting_hr).collect();
    let sleeps: Vec<f64> = window.iter().filter_map(|d| d.sleep_duration_min).collect();
    let temps: Vec<f64> = window.iter().filter_map(|d| d.skin_temp).collect();
    let strains: Vec<f64> = window.iter().filter_map(|d| d.daily_strain).collect();

    let rhr = median(&rhrs);
    let real_nights: Vec<f64> = sleeps.iter().copied().filter(|&s| s >= 120.0).collect();
    let sleep_need_raw = median(&real_nights);
    let sleep_need = match sleep_need_raw {
        Some(v) if real_nights.len() >= 3 && v >= 240.0 => Some(v),
        _ => None,
    };
    let temp = median(&temps);
    let chronic = if !strains.is_empty() { Some(mean(&strains)) } else { None };

    let mut zone_cols: [Vec<f64>; 5] = Default::default();
    for d in window {
        if let Some(zm) = d.zone_min {
            for z in 0..5 {
                zone_cols[z].push(zm[z]);
            }
        }
    }
    let zone_med: Option<[f64; 5]> = if zone_cols.iter().all(|c| !c.is_empty()) {
        let mut out = [0.0; 5];
        for z in 0..5 {
            out[z] = median(&zone_cols[z]).unwrap_or(0.0);
        }
        Some(out)
    } else {
        None
    };

    let observed_max: Vec<f64> = window.iter().filter_map(|d| d.session_hr_max).collect();
    let observed_peak = observed_max.iter().cloned().fold(0.0_f64, f64::max);
    let age_max = profile.and_then(|p| p.age).filter(|&a| a > 0.0).map(|a| (208.0 - 0.7 * a).round());
    let (max_hr, max_hr_source): (Option<f64>, &str) = match age_max {
        Some(am) => {
            if observed_peak > am {
                (Some(observed_peak), "measured")
            } else {
                (Some(am), "age")
            }
        }
        None => {
            if observed_peak > 0.0 {
                (Some(observed_peak), "age")
            } else {
                (None, "age")
            }
        }
    };

    let confidence = 1f64.min(days as f64 / 30.0);
    let mut inputs_used = vec![];
    if !rhrs.is_empty() {
        inputs_used.push("resting_hr".to_string());
    }
    if !sleeps.is_empty() {
        inputs_used.push("sleep_duration_min".to_string());
    }
    if !temps.is_empty() {
        inputs_used.push("skin_temp".to_string());
    }
    if !strains.is_empty() {
        inputs_used.push("daily_strain".to_string());
    }
    if max_hr_source == "measured" {
        inputs_used.push("session_hr_max".to_string());
    } else if profile.and_then(|p| p.age).is_some() {
        inputs_used.push("profile.age".to_string());
    }

    BaselinesOut {
        resting_hr: rhr.map(|v| round(v, 1)),
        sleep_need_min: sleep_need.map(|v| round(v, 0)),
        skin_temp: temp.map(|v| round(v, 2)),
        max_hr: max_hr.map(|v| round(v, 0)),
        max_hr_source: max_hr_source.to_string(),
        chronic_strain: chronic.map(|v| round(v, 3)),
        zone_min: zone_med,
        days_used: days as u32,
        confidence: round(if days == 0 { 0.0 } else { confidence }, 4),
        tier: "HIGH".to_string(),
        inputs_used,
    }
}
