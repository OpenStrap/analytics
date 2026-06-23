// Port of openstrap-analytics/src/zones.ts — minutes per %HRmax band. Tier HIGH.
use crate::types::{Baseline, HrZonesOut, Minute, Profile};
use crate::util::{is_hr_usable, resolve_max_hr, round};

pub fn calc_hr_zones(minutes: &[Minute], baseline: &Baseline, profile: Option<&Profile>) -> HrZonesOut {
    let (max_hr, source) = resolve_max_hr(minutes, baseline.max_hr, profile);
    let worn: Vec<&Minute> = minutes.iter().filter(|m| is_hr_usable(m)).collect();

    let mut z = [0u32; 5];
    for m in &worn {
        let pct = (m.hr_avg / max_hr) * 100.0;
        if pct >= 50.0 && pct < 60.0 {
            z[0] += 1;
        } else if pct >= 60.0 && pct < 70.0 {
            z[1] += 1;
        } else if pct >= 70.0 && pct < 80.0 {
            z[2] += 1;
        } else if pct >= 80.0 && pct < 90.0 {
            z[3] += 1;
        } else if pct >= 90.0 {
            z[4] += 1;
        }
    }

    let base = if source == "measured" { 0.85 } else { 0.6 };
    let coverage = 1f64.min(worn.len() as f64 / 30.0);
    let confidence = base * coverage;

    HrZonesOut {
        zone1_min: z[0],
        zone2_min: z[1],
        zone3_min: z[2],
        zone4_min: z[3],
        zone5_min: z[4],
        max_hr_used: max_hr,
        max_hr_source: source.to_string(),
        confidence: round(confidence, 4),
        tier: "HIGH".to_string(),
        inputs_used: if source == "measured" {
            vec!["hr_avg".to_string(), "baseline.max_hr".to_string()]
        } else {
            vec!["hr_avg".to_string(), "profile.age".to_string()]
        },
    }
}
