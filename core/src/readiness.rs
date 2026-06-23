// Port of openstrap-analytics/src/readiness.ts — calcAnomaly (Radin RHR-elevation rule).
use crate::types::{AnomalyOut, Baseline};
use crate::util::round;

pub struct AnomalyInputs {
    pub recent_rhr: Vec<f64>,
    pub skin_temp: Option<f64>,
    pub sleep_efficiency: Option<f64>,
    pub baseline_sleep_efficiency: Option<f64>,
}

pub fn calc_anomaly(inputs: &AnomalyInputs, baseline: &Baseline, cycle_phase: Option<&str>) -> AnomalyOut {
    let mut note = "signal, not a diagnosis".to_string();
    let mut triggers: Vec<String> = Vec::new();
    let mut used: Vec<String> = Vec::new();

    let rhr_threshold = baseline.resting_hr * 1.07;

    let mut consecutive = 0;
    if !inputs.recent_rhr.is_empty() {
        used.push("recent_rhr".to_string());
        used.push("baseline.resting_hr".to_string());
        for i in (0..inputs.recent_rhr.len()).rev() {
            if inputs.recent_rhr[i] >= rhr_threshold {
                consecutive += 1;
            } else {
                break;
            }
        }
    }
    let rule_a = consecutive >= 2;
    if rule_a {
        triggers.push("rhr_elevated_2d".to_string());
    }

    let latest_rhr = inputs.recent_rhr.last().copied();
    let rhr_up = matches!(latest_rhr, Some(v) if v >= rhr_threshold);
    let mut temp_up = false;
    if let (Some(t), Some(bt)) = (inputs.skin_temp, baseline.skin_temp) {
        used.push("skin_temp".to_string());
        used.push("baseline.skin_temp".to_string());
        temp_up = t - bt > 0.5;
    }
    let mut eff_down = false;
    if let (Some(e), Some(be)) = (inputs.sleep_efficiency, inputs.baseline_sleep_efficiency) {
        used.push("sleep_efficiency".to_string());
        used.push("baseline_sleep_efficiency".to_string());
        eff_down = e < be;
    }
    let rule_b = rhr_up && temp_up && eff_down;
    if rule_b {
        triggers.push("rhr_temp_efficiency".to_string());
    }

    let in_cycle = cycle_phase == Some("luteal") || cycle_phase == Some("menstruation");
    let signal = (rule_a && !in_cycle) || rule_b;
    if rule_a && in_cycle && !rule_b {
        note = "signal, not a diagnosis (an elevated resting HR can be expected in this phase of your cycle)".to_string();
    }

    let evaluable = [
        inputs.recent_rhr.len() >= 2,
        inputs.skin_temp.is_some() && baseline.skin_temp.is_some(),
        inputs.sleep_efficiency.is_some() && inputs.baseline_sleep_efficiency.is_some(),
    ]
    .iter()
    .filter(|&&x| x)
    .count();
    let confidence = 0.5f64.min((evaluable as f64 / 3.0) * 0.5);

    // dedupe `used` preserving first-seen order (matches Array.from(new Set(used))).
    let mut seen = std::collections::HashSet::new();
    let inputs_used: Vec<String> = used.into_iter().filter(|s| seen.insert(s.clone())).collect();

    AnomalyOut {
        signal,
        triggers,
        note,
        confidence: round(confidence, 4),
        tier: "ESTIMATE".to_string(),
        inputs_used,
    }
}
