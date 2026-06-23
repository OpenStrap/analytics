// Port of openstrap-analytics/src/strain.ts — Banister TRIMP, log-scaled 0..21.
use crate::types::{Baseline, Minute, Profile, StrainOut};
use crate::util::{clamp, is_hr_usable, resolve_max_hr, round};

pub fn calc_strain(minutes: &[Minute], baseline: &Baseline, profile: Option<&Profile>) -> StrainOut {
    let (max_hr, source) = resolve_max_hr(minutes, baseline.max_hr, profile);
    let rhr = baseline.resting_hr;
    let worn: Vec<&Minute> = minutes.iter().filter(|m| is_hr_usable(m)).collect();

    // women (0.86, 1.67), men / unknown (0.64, 1.92)
    let (k, b) = match profile.and_then(|p| p.sex.as_deref()) {
        Some("f") => (0.86, 1.67),
        _ => (0.64, 1.92),
    };

    let denom = max_hr - rhr;
    let mut trimp = 0.0;
    for m in &worn {
        if denom <= 0.0 {
            continue;
        }
        let ratio = clamp((m.hr_avg - rhr) / denom, 0.0, 1.0);
        trimp += ratio * k * (b * ratio).exp();
    }

    let score = 21.0_f64.min((trimp + 1.0).ln() / 1.5_f64.ln());
    let confidence = clamp(worn.len() as f64 / 30.0, 0.0, 1.0);

    let mut inputs_used = vec!["hr_avg".to_string(), "baseline.resting_hr".to_string()];
    inputs_used.push(
        if source == "measured" { "baseline.max_hr" } else { "profile.age" }.to_string(),
    );

    StrainOut {
        score: round(score, 2),
        trimp: round(trimp, 4),
        max_hr_used: max_hr,
        max_hr_source: source.to_string(),
        confidence: round(confidence, 4),
        tier: "HIGH".to_string(),
        inputs_used,
    }
}
