// Port of openstrap-analytics/src/spo2.ts — RELATIVE SpO₂ index + desaturation screen.
use crate::types::{DesaturationOut, Driver, MetricRef, Spo2Out};
use crate::util::{clamp, mean, median, round, stddev};

const MIN_MINUTES: usize = 30;
fn plausible(r: f64) -> bool {
    r > 0.4 && r < 1.5
}
const CV_FLOOR: f64 = 0.08;
const DESAT_REL: f64 = 0.04;
const DESAT_MINUTES: u32 = 1;

pub fn calc_spo2_index(ratios: &[f64], baseline_ratio: Option<f64>) -> Spo2Out {
    let r: Vec<f64> = ratios.iter().copied().filter(|&x| plausible(x)).collect();
    let none = |conf: f64| Spo2Out {
        index: None, night_ratio: None, confidence: conf, tier: "RELATIVE".to_string(), inputs_used: vec![], drivers: None,
    };
    if r.len() < MIN_MINUTES {
        return none(0.0);
    }
    let med = match median(&r) {
        Some(m) => m,
        None => return none(0.0),
    };
    let night_r = round(med, 4);
    let m = mean(&r);
    let cv = if m > 0.0 { stddev(&r) / m } else { 1.0 };
    let conf = round(clamp((r.len() as f64 / 180.0).min(1.0) * 0f64.max(1.0 - cv / CV_FLOOR), 0.0, 1.0), 3);
    let inputs_used = vec!["spo2_red_raw".to_string(), "spo2_ir_raw".to_string()];

    match baseline_ratio {
        Some(b) if b > 0.0 => {
            let index = round(((b - night_r) / b) * 100.0, 2);
            let drivers = vec![Driver {
                label: "Blood-oxygen vs baseline".to_string(),
                contribution: index,
                detail: Some(format!("R {} vs baseline {}", night_r, round(b, 4))),
                reference: Some(MetricRef { metric: "spo2".to_string(), date: None, scale: Some("day".to_string()) }),
            }];
            Spo2Out { index: Some(index), night_ratio: Some(night_r), confidence: conf, tier: "RELATIVE".to_string(), inputs_used, drivers: Some(drivers) }
        }
        _ => Spo2Out { index: None, night_ratio: Some(night_r), confidence: round(conf * 0.5, 3), tier: "RELATIVE".to_string(), inputs_used, drivers: None },
    }
}

pub fn calc_desaturation(ratios: &[f64], baseline_ratio: Option<f64>) -> DesaturationOut {
    let note = "a screen, not a diagnosis".to_string();
    let r: Vec<f64> = ratios.iter().copied().filter(|&x| plausible(x)).collect();
    let none = || DesaturationOut {
        events: 0, odi: None, deepest_pct: None, note: note.clone(), confidence: 0.0,
        tier: "RELATIVE".to_string(), inputs_used: vec![], drivers: None,
    };
    let b = match baseline_ratio {
        Some(b) if b > 0.0 => b,
        _ => return none(),
    };
    if r.len() < MIN_MINUTES {
        return none();
    }
    let thresh = b * (1.0 + DESAT_REL);
    let mut events = 0u32;
    let mut run = 0u32;
    let mut deepest = 0.0;
    for &v in &r {
        if v >= thresh {
            run += 1;
            let dip_pct = ((v - b) / b) * 100.0;
            if dip_pct > deepest {
                deepest = dip_pct;
            }
            if run == DESAT_MINUTES {
                events += 1;
            }
        } else {
            run = 0;
        }
    }
    let hours = 0.5f64.max(r.len() as f64 / 60.0);
    let m = mean(&r);
    let cv = if m > 0.0 { stddev(&r) / m } else { 1.0 };
    let conf = round(clamp((r.len() as f64 / 180.0).min(1.0) * 0f64.max(1.0 - cv / CV_FLOOR), 0.0, 1.0), 3);
    let drivers = vec![Driver {
        label: "Desaturation dips".to_string(),
        contribution: events as f64,
        detail: Some(format!("{} dips ({}/h)", events, round(events as f64 / hours, 1))),
        reference: Some(MetricRef { metric: "spo2".to_string(), date: None, scale: Some("day".to_string()) }),
    }];
    DesaturationOut {
        events,
        odi: Some(round(events as f64 / hours, 1)),
        deepest_pct: Some(round(deepest, 1)),
        note,
        confidence: conf,
        tier: "RELATIVE".to_string(),
        inputs_used: vec!["spo2_red_raw".to_string(), "spo2_ir_raw".to_string()],
        drivers: Some(drivers),
    }
}
