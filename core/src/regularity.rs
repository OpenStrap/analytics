// Port of openstrap-analytics/src/regularity.ts — circular variability of sleep timing.
use crate::types::{NightSummary, SleepRegularityOut};
use crate::util::round;

const DAY_MIN: f64 = 24.0 * 60.0;

fn minute_of_day(ts: f64) -> f64 {
    let total_min = (ts / 60.0).floor();
    ((total_min % DAY_MIN) + DAY_MIN) % DAY_MIN
}

fn circular_std_min(minutes_of_day: &[f64]) -> f64 {
    if minutes_of_day.len() < 2 {
        return 0.0;
    }
    let mut sum_cos = 0.0;
    let mut sum_sin = 0.0;
    for &m in minutes_of_day {
        let theta = (2.0 * std::f64::consts::PI * m) / DAY_MIN;
        sum_cos += theta.cos();
        sum_sin += theta.sin();
    }
    let n = minutes_of_day.len() as f64;
    let r = (sum_cos * sum_cos + sum_sin * sum_sin).sqrt() / n;
    let r_clamped = 1e-9_f64.max(1f64.min(r));
    let sigma_rad = (-2.0 * r_clamped.ln()).sqrt();
    sigma_rad * (DAY_MIN / (2.0 * std::f64::consts::PI))
}

pub fn calc_sleep_regularity(nights: &[NightSummary]) -> SleepRegularityOut {
    let valid: Vec<&NightSummary> = nights.iter().filter(|n| n.onset_ts.is_some() && n.wake_ts.is_some()).collect();
    let onsets: Vec<f64> = valid.iter().map(|n| minute_of_day(n.onset_ts.unwrap())).collect();
    let wakes: Vec<f64> = valid.iter().map(|n| minute_of_day(n.wake_ts.unwrap())).collect();

    if valid.len() < 3 {
        return SleepRegularityOut {
            sri: 0.0, onset_std_min: 0.0, wake_std_min: 0.0, nights_used: valid.len() as u32,
            confidence: 0.0, tier: "HIGH".to_string(),
            inputs_used: vec!["nights.onset_ts".to_string(), "nights.wake_ts".to_string()],
        };
    }

    let onset_std = circular_std_min(&onsets);
    let wake_std = circular_std_min(&wakes);
    let avg_std = (onset_std + wake_std) / 2.0;
    let sri = 0f64.max(100.0 - (avg_std / 120.0) * 100.0);

    SleepRegularityOut {
        sri: round(sri, 2),
        onset_std_min: round(onset_std, 2),
        wake_std_min: round(wake_std, 2),
        nights_used: valid.len() as u32,
        confidence: 0.7,
        tier: "HIGH".to_string(),
        inputs_used: vec!["nights.onset_ts".to_string(), "nights.wake_ts".to_string()],
    }
}
