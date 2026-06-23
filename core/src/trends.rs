// Port of openstrap-analytics/src/trends.ts — EWMA ACWR + directional fitness trend.
use crate::types::{DailyStrain, DayHistory, FitnessTrendOut, LoadOut};
use crate::util::{linreg_slope, mean, round};

pub fn calc_load(daily_strain: &[DailyStrain]) -> LoadOut {
    let mut sorted: Vec<&DailyStrain> = daily_strain.iter().collect();
    sorted.sort_by(|a, b| a.ts.partial_cmp(&b.ts).unwrap());
    let days = sorted.len();

    if days < 7 {
        return LoadOut {
            acwr: None, acute: 0.0, chronic: 0.0, band: "unknown".to_string(),
            confidence: round(1f64.min(days as f64 / 28.0), 4), tier: "HIGH".to_string(),
            inputs_used: vec!["daily_strain".to_string()],
        };
    }
    let lambda_acute = 2.0 / (7.0 + 1.0);
    let lambda_chronic = 2.0 / (28.0 + 1.0);
    let mut acute = sorted[0].strain;
    let mut chronic = sorted[0].strain;
    for i in 1..sorted.len() {
        acute = sorted[i].strain * lambda_acute + acute * (1.0 - lambda_acute);
        chronic = sorted[i].strain * lambda_chronic + chronic * (1.0 - lambda_chronic);
    }
    let acwr = if chronic > 0.0 { Some(acute / chronic) } else { None };
    let band = match acwr {
        None => "unknown",
        Some(a) if a < 0.8 => "detraining",
        Some(a) if a <= 1.3 => "optimal",
        Some(a) if a <= 1.5 => "caution",
        Some(_) => "high-risk",
    };
    LoadOut {
        acwr: acwr.map(|a| round(a, 3)),
        acute: round(acute, 3),
        chronic: round(chronic, 3),
        band: band.to_string(),
        confidence: round(1f64.min(days as f64 / 28.0), 4),
        tier: "HIGH".to_string(),
        inputs_used: vec!["daily_strain".to_string()],
    }
}

fn rolling_mean(values: &[f64], w: usize) -> Vec<f64> {
    let mut out = Vec::with_capacity(values.len());
    for i in 0..values.len() {
        let start = if i + 1 >= w { i + 1 - w } else { 0 };
        out.push(mean(&values[start..=i]));
    }
    out
}

pub fn calc_fitness_trend(daily: &[DayHistory]) -> FitnessTrendOut {
    let mut rhr_series = Vec::new();
    let mut hrr_series = Vec::new();
    for d in daily {
        if let Some(r) = d.resting_hr {
            rhr_series.push(r);
        }
        if let Some(h) = d.hrr60 {
            hrr_series.push(h);
        }
    }
    let days = daily.len();
    if days < 7 || rhr_series.len() < 3 {
        return FitnessTrendOut {
            direction: "unknown".to_string(), rhr_slope: 0.0, hrr_slope: 0.0, days_used: days as u32,
            confidence: round(0.8f64.min((days as f64 / 21.0) * 0.8), 4), tier: "ESTIMATE".to_string(),
            inputs_used: vec!["resting_hr".to_string(), "hrr60".to_string()],
        };
    }
    let rhr_roll = rolling_mean(&rhr_series, 7);
    let hrr_roll = if hrr_series.len() >= 3 { rolling_mean(&hrr_series, 7) } else { vec![] };
    let rhr_slope = linreg_slope(&rhr_roll);
    let hrr_slope = if hrr_roll.len() >= 2 { linreg_slope(&hrr_roll) } else { 0.0 };

    let direction = if rhr_slope < 0.0 && hrr_slope > 0.0 {
        "improving"
    } else if rhr_slope > 0.0 && (hrr_slope < 0.0 || hrr_roll.len() < 2) {
        "declining"
    } else {
        "flat"
    };
    let confidence = 0.8f64.min((days as f64 / 21.0) * 0.8);
    FitnessTrendOut {
        direction: direction.to_string(),
        rhr_slope: round(rhr_slope, 5),
        hrr_slope: round(hrr_slope, 5),
        days_used: days as u32,
        confidence: round(confidence, 4),
        tier: "ESTIMATE".to_string(),
        inputs_used: vec!["resting_hr".to_string(), "hrr60".to_string()],
    }
}
