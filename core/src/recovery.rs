// Port of openstrap-analytics/src/recovery.ts — Plews lnRMSSD recovery + HRR60.
use crate::types::{Baseline, Driver, HrRecoveryOut, MetricRef, Minute, Profile, RecoveryOut};
use crate::util::{is_hr_usable, mean, resolve_max_hr, round, stddev};

/// Plews et al. 2013 — lnRMSSD z vs rolling baseline. Tier HIGH.
pub fn calc_recovery(rmssd_today: Option<f64>, baseline_rmssd: &[f64], date: Option<&str>) -> RecoveryOut {
    let note = "HRV-based".to_string();
    let usable: Vec<f64> = baseline_rmssd.iter().copied().filter(|&x| x > 0.0).collect();

    let none = |rt: Option<f64>| RecoveryOut {
        score: None, rmssd: rt, baseline_rmssd: None, z: None, note: note.clone(),
        confidence: 0.0, tier: "HIGH".to_string(), inputs_used: vec!["hrv_rmssd".to_string()], drivers: None,
    };
    let rt = match rmssd_today {
        Some(v) if v > 0.0 => v,
        _ => return none(rmssd_today),
    };
    if usable.len() < 5 {
        return none(rmssd_today);
    }

    let ln_base: Vec<f64> = usable.iter().map(|x| x.ln()).collect();
    let m = mean(&ln_base);
    let sd = stddev(&ln_base);
    let base_rmssd = m.exp();
    if sd <= 0.0 {
        return RecoveryOut {
            score: None, rmssd: Some(round(rt, 1)), baseline_rmssd: Some(round(base_rmssd, 1)),
            z: None, note, confidence: 0.2, tier: "HIGH".to_string(),
            inputs_used: vec!["hrv_rmssd".to_string()], drivers: None,
        };
    }
    let z = (rt.ln() - m) / sd;
    let score = (50.0 + 25.0 * z).round().max(0.0).min(100.0);
    let reference = MetricRef { metric: "hrv".to_string(), date: date.map(|s| s.to_string()), scale: Some("day".to_string()) };
    let drivers = vec![Driver {
        label: "Nocturnal HRV (RMSSD)".to_string(),
        contribution: round(25.0 * z, 1),
        detail: Some(format!("{} ms vs baseline {} ms", round(rt, 0), round(base_rmssd, 0))),
        reference: Some(reference),
    }];
    let confidence = 1f64.min(usable.len() as f64 / 21.0);
    RecoveryOut {
        score: Some(score),
        rmssd: Some(round(rt, 1)),
        baseline_rmssd: Some(round(base_rmssd, 1)),
        z: Some(round(z, 2)),
        note,
        confidence: round(confidence, 4),
        tier: "HIGH".to_string(),
        inputs_used: vec!["hrv_rmssd".to_string(), "baseline.hrv_rmssd".to_string()],
        drivers: Some(drivers),
    }
}

/// HRR60 = peak − HR ~1 min after peak (Cole/Lauer). Tier HIGH.
pub fn calc_hr_recovery(session_minutes: &[Minute], baseline: &Baseline, profile: Option<&Profile>) -> HrRecoveryOut {
    let mut sorted: Vec<&Minute> = session_minutes.iter().collect();
    sorted.sort_by(|a, b| a.ts.partial_cmp(&b.ts).unwrap());
    let worn_count = sorted.iter().filter(|m| is_hr_usable(m)).count();

    let none = || HrRecoveryOut {
        hrr60: None, peak_hr: None, confidence: 0.0, tier: "HIGH".to_string(),
        inputs_used: vec!["hr_max".to_string(), "hr_avg".to_string()],
    };
    if worn_count == 0 {
        return none();
    }
    let sorted_minutes: Vec<Minute> = sorted.iter().map(|m| (*m).clone()).collect();
    let (max_hr, _) = resolve_max_hr(&sorted_minutes, baseline.max_hr, profile);
    let rhr = baseline.resting_hr;
    let threshold = rhr + 0.4 * (max_hr - rhr);

    let mut peak_idx: i64 = -1;
    let mut peak_val = f64::NEG_INFINITY;
    for (i, m) in sorted.iter().enumerate() {
        if !is_hr_usable(m) {
            continue;
        }
        if m.hr_max > peak_val {
            peak_val = m.hr_max;
            peak_idx = i as i64;
        }
    }
    if peak_idx < 0 || peak_val < threshold {
        return none();
    }
    let peak_ts = sorted[peak_idx as usize].ts;
    let mut after: Option<&Minute> = None;
    for i in (peak_idx as usize + 1)..sorted.len() {
        if !is_hr_usable(sorted[i]) {
            continue;
        }
        let dt = sorted[i].ts - peak_ts;
        if dt >= 45.0 && dt <= 90.0 {
            after = Some(sorted[i]);
            break;
        }
        if dt > 90.0 {
            break;
        }
    }
    let after = match after {
        Some(a) => a,
        None => return none(),
    };
    let hrr60 = peak_val - after.hr_avg;
    HrRecoveryOut {
        hrr60: Some(round(hrr60, 1)),
        peak_hr: Some(round(peak_val, 1)),
        confidence: 0.7,
        tier: "HIGH".to_string(),
        inputs_used: vec!["hr_max".to_string(), "hr_avg".to_string(), "baseline.resting_hr".to_string()],
    }
}
