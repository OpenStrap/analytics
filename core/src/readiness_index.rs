// Port of openstrap-analytics/src/readiness_index.ts — transparent weighted composite.
use crate::types::{Driver, MetricRef, ReadinessComponents, ReadinessIndexOut};
use crate::util::{clamp, round};

pub struct ReadinessInputs {
    pub recovery: Option<f64>,
    pub sleep_duration_min: Option<f64>,
    pub sleep_need_min: Option<f64>,
    pub dip_pct: Option<f64>,
    pub sleep_stress: Option<f64>,
}

// Weights (sum 1): recovery 0.5, sleep 0.2, dip 0.15, arousal 0.15.
pub fn calc_readiness_index(inp: &ReadinessInputs) -> ReadinessIndexOut {
    let comp_sleep = match (inp.sleep_duration_min, inp.sleep_need_min) {
        (Some(dur), Some(need)) if need > 0.0 => Some(round(clamp((dur / need) * 100.0, 0.0, 100.0), 0)),
        _ => None,
    };
    let comp_dip = inp.dip_pct.map(|d| round(clamp((d / 0.10) * 100.0, 0.0, 100.0), 0));
    let comp_arousal = inp.sleep_stress.map(|s| round(clamp(100.0 - s, 0.0, 100.0), 0));
    let components = ReadinessComponents {
        recovery: inp.recovery,
        sleep: comp_sleep,
        dip: comp_dip,
        arousal: comp_arousal,
    };

    if components.recovery.is_none() {
        return ReadinessIndexOut {
            score: None,
            components,
            note: "Building baseline — needs nocturnal HRV".to_string(),
            confidence: 0.0,
            tier: "ESTIMATE".to_string(),
            inputs_used: vec![],
            drivers: None,
        };
    }

    let mut wsum = 0.0;
    let mut acc = 0.0;
    let mut used: Vec<String> = vec![];
    let mut drivers: Vec<Driver> = vec![];
    let mut add = |key: &str, w: f64, label: &str, v: Option<f64>| {
        if let Some(v) = v {
            wsum += w;
            acc += w * v;
            used.push(key.to_string());
            let metric = if key == "recovery" { "recovery" } else if key == "sleep" { "sleep" } else { "hrv" };
            drivers.push(Driver {
                label: label.to_string(),
                contribution: round((w * (v - 50.0)) / 50.0, 3),
                detail: Some(format!("{}/100", v)),
                reference: Some(MetricRef { metric: metric.to_string(), date: None, scale: Some("day".to_string()) }),
            });
        }
    };
    add("recovery", 0.5, "HRV recovery", components.recovery);
    add("sleep", 0.2, "Sleep vs need", components.sleep);
    add("dip", 0.15, "Nocturnal HR dip", components.dip);
    add("arousal", 0.15, "Sleep calmness", components.arousal);

    let score = if wsum > 0.0 { Some((acc / wsum).round()) } else { None };
    drivers.sort_by(|a, b| b.contribution.abs().partial_cmp(&a.contribution.abs()).unwrap());

    ReadinessIndexOut {
        score,
        components,
        note: "Composite (HRV + sleep) — a guide, not a diagnosis".to_string(),
        confidence: round(clamp(wsum, 0.0, 1.0), 3),
        tier: "ESTIMATE".to_string(),
        inputs_used: used,
        drivers: Some(drivers),
    }
}
