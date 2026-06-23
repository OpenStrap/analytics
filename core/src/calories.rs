// Port of openstrap-analytics/src/calories.ts — Keytel active kcal. Tier ESTIMATE.
use crate::types::{CaloriesOut, Minute, Profile};
use crate::util::{is_hr_usable, percentile, round};

pub fn calc_calories(
    minutes: &[Minute],
    profile: &Profile,
    resting_hr: Option<f64>,
    max_hr: Option<f64>,
) -> CaloriesOut {
    let worn: Vec<&Minute> = minutes.iter().filter(|m| is_hr_usable(m)).collect();
    let age = profile.age.unwrap_or(30.0);
    let w = profile.weight_kg.unwrap_or(70.0);
    let sex = profile.sex.as_deref();

    let per_min = |hr: f64| -> f64 {
        let male = (-55.0969 + 0.6309 * hr + 0.1988 * w + 0.2017 * age) / 4.184;
        let female = (-20.4022 + 0.4472 * hr - 0.1263 * w + 0.074 * age) / 4.184;
        match sex {
            Some("m") => male,
            Some("f") => female,
            _ => (male + female) / 2.0,
        }
    };

    let rest_ref = match resting_hr {
        Some(r) if r > 0.0 => r,
        _ => percentile(&worn.iter().map(|m| m.hr_avg).collect::<Vec<_>>(), 5.0).unwrap_or(50.0),
    };
    let rest_per_min = per_min(rest_ref);

    let active_floor = match max_hr {
        Some(mh) if mh > rest_ref => 0.5 * mh,
        _ => rest_ref,
    };

    let mut kcal = 0.0;
    for m in &worn {
        if m.hr_avg < active_floor {
            continue;
        }
        kcal += 0f64.max(per_min(m.hr_avg) - rest_per_min);
    }

    let mut inputs_used = vec!["hr_avg".to_string()];
    if matches!(resting_hr, Some(r) if r > 0.0) {
        inputs_used.push("baseline.resting_hr".to_string());
    }
    if profile.age.is_some() {
        inputs_used.push("profile.age".to_string());
    }
    if profile.weight_kg.is_some() {
        inputs_used.push("profile.weight_kg".to_string());
    }
    if profile.sex.is_some() {
        inputs_used.push("profile.sex".to_string());
    }

    let coverage = 1f64.min(worn.len() as f64 / 30.0);
    let confidence = 0.5 * coverage;

    CaloriesOut {
        kcal: round(kcal, 1),
        label: "≈ active kcal (est.)".to_string(),
        confidence: round(confidence, 4),
        tier: "ESTIMATE".to_string(),
        inputs_used,
    }
}
