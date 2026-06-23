// Port of openstrap-analytics/src/fitness.ts — VO2max, Banister model, Foster monotony.
use crate::types::{DailyStrain, FitnessModelOut, MonotonyOut, Vo2MaxOut};
use crate::util::{mean, round, stddev};

pub fn calc_vo2max(max_hr: Option<f64>, resting_hr: Option<f64>) -> Vo2MaxOut {
    match (max_hr, resting_hr) {
        (Some(mh), Some(rh)) if rh > 0.0 && mh > rh => Vo2MaxOut {
            vo2max: Some(round(15.3 * (mh / rh), 1)),
            method: "Uth–Sørensen".to_string(),
            confidence: 0.5,
            tier: "ESTIMATE".to_string(),
            inputs_used: vec!["baseline.max_hr".to_string(), "baseline.resting_hr".to_string()],
        },
        _ => Vo2MaxOut { vo2max: None, method: "Uth–Sørensen".to_string(), confidence: 0.0, tier: "ESTIMATE".to_string(), inputs_used: vec![] },
    }
}

pub fn calc_fitness_model(daily_strain: &[DailyStrain]) -> FitnessModelOut {
    let mut sorted: Vec<&DailyStrain> = daily_strain.iter().collect();
    sorted.sort_by(|a, b| a.ts.partial_cmp(&b.ts).unwrap());
    let days = sorted.len();
    if days < 7 {
        return FitnessModelOut {
            fitness: None, fatigue: None, form: None,
            confidence: round(1f64.min(days as f64 / 42.0), 4),
            tier: "ESTIMATE".to_string(), inputs_used: vec!["daily_strain".to_string()],
        };
    }
    let a_ctl = 2.0 / (42.0 + 1.0);
    let a_atl = 2.0 / (7.0 + 1.0);
    let mut ctl = sorted[0].strain;
    let mut atl = sorted[0].strain;
    let mut prev_ctl = ctl;
    let mut prev_atl = atl;
    for d in &sorted {
        prev_ctl = ctl;
        prev_atl = atl;
        ctl = ctl + a_ctl * (d.strain - ctl);
        atl = atl + a_atl * (d.strain - atl);
    }
    FitnessModelOut {
        fitness: Some(round(ctl, 2)),
        fatigue: Some(round(atl, 2)),
        form: Some(round(prev_ctl - prev_atl, 2)),
        confidence: round(1f64.min(days as f64 / 42.0), 4),
        tier: "ESTIMATE".to_string(),
        inputs_used: vec!["daily_strain".to_string()],
    }
}

pub fn calc_monotony(daily_strain: &[DailyStrain]) -> MonotonyOut {
    let mut sorted: Vec<&DailyStrain> = daily_strain.iter().collect();
    sorted.sort_by(|a, b| a.ts.partial_cmp(&b.ts).unwrap());
    let last7: Vec<f64> = sorted.iter().rev().take(7).rev().map(|d| d.strain).collect();
    let weekly = round(last7.iter().sum::<f64>(), 1);
    if last7.len() < 4 {
        return MonotonyOut {
            monotony: None, training_strain: None, weekly_load: weekly,
            confidence: round(last7.len() as f64 / 7.0, 4), tier: "HIGH".to_string(),
            inputs_used: vec!["daily_strain".to_string()],
        };
    }
    let m = mean(&last7);
    let sd = stddev(&last7);
    let monotony = if sd > 0.0 { Some(m / sd) } else { None };
    MonotonyOut {
        monotony: monotony.map(|x| round(x, 2)),
        training_strain: monotony.map(|x| round(weekly * x, 1)),
        weekly_load: weekly,
        confidence: round(1f64.min(last7.len() as f64 / 7.0), 4),
        tier: "HIGH".to_string(),
        inputs_used: vec!["daily_strain".to_string()],
    }
}
