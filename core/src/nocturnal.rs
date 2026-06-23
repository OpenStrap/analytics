// Port of openstrap-analytics/src/nocturnal.ts — sleeping HR / nadir / dip / elevated.
use crate::types::{Baseline, Minute, NocturnalOut};
use crate::util::{clamp, mean, round};

pub fn calc_nocturnal_heart(sleep_minutes: &[Minute], day_minutes: &[Minute], baseline: &Baseline) -> NocturnalOut {
    let mut sleep_hrs: Vec<&Minute> = sleep_minutes.iter().filter(|m| m.wrist_on && m.hr_avg > 0.0).collect();
    sleep_hrs.sort_by(|a, b| a.ts.partial_cmp(&b.ts).unwrap());

    let empty = || NocturnalOut {
        sleeping_hr_avg: None, sleeping_hr_min: None, nadir_ts: None, day_hr_avg: None,
        dip_pct: None, vs_baseline_bpm: None, elevated: false, confidence: 0.0,
        tier: "HIGH".to_string(), inputs_used: vec![],
    };
    if sleep_hrs.is_empty() {
        return empty();
    }

    let hr_vals: Vec<f64> = sleep_hrs.iter().map(|m| m.hr_avg).collect();
    let sleeping_hr_avg = mean(&hr_vals).round();

    // Nadir = lowest 5-min rolling mean.
    let w = 5usize;
    let mut nadir: Option<(f64, f64)> = None; // (ts, v)
    if sleep_hrs.len() >= w {
        let mut i = 0;
        while i + w <= sleep_hrs.len() {
            let m = mean(&sleep_hrs[i..i + w].iter().map(|x| x.hr_avg).collect::<Vec<_>>());
            if nadir.is_none() || m < nadir.unwrap().1 {
                nadir = Some((sleep_hrs[i + w / 2].ts, m));
            }
            i += 1;
        }
    } else {
        let lo = sleep_hrs.iter().fold(sleep_hrs[0], |p, c| if c.hr_avg < p.hr_avg { c } else { p });
        nadir = Some((lo.ts, lo.hr_avg));
    }

    let day_hr: Vec<f64> = day_minutes.iter().filter(|m| m.wrist_on && m.hr_avg > 0.0).map(|m| m.hr_avg).collect();
    let day_hr_avg = if !day_hr.is_empty() { Some(mean(&day_hr).round()) } else { None };
    let dip_pct = match day_hr_avg {
        Some(d) if d > 0.0 => Some(round(clamp((d - sleeping_hr_avg) / d, 0.0, 1.0), 3)),
        _ => None,
    };

    let base_sleep_hr = match baseline.sleeping_hr {
        Some(b) if b > 0.0 => Some(b),
        _ => None,
    };
    let vs_baseline = base_sleep_hr.map(|b| round(sleeping_hr_avg - b, 1));
    let elevated = match base_sleep_hr {
        Some(b) => sleeping_hr_avg >= b + 4.0 && sleeping_hr_avg >= b * 1.05,
        None => false,
    };
    let coverage = clamp(sleep_hrs.len() as f64 / 180.0, 0.0, 1.0);

    let mut inputs_used = vec!["hr_avg".to_string(), "sleep.onset_ts".to_string(), "sleep.wake_ts".to_string()];
    if base_sleep_hr.is_some() {
        inputs_used.push("baseline.sleeping_hr".to_string());
    }

    NocturnalOut {
        sleeping_hr_avg: Some(sleeping_hr_avg),
        sleeping_hr_min: nadir.map(|n| n.1.round()),
        nadir_ts: nadir.map(|n| n.0),
        day_hr_avg,
        dip_pct,
        vs_baseline_bpm: vs_baseline,
        elevated,
        confidence: round(coverage, 3),
        tier: "HIGH".to_string(),
        inputs_used,
    }
}
