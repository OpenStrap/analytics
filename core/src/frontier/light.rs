// Frontier — Ambient-LIGHT hygiene (our unique sensor — WHOOP has none). Nature Mental
// Health 2023 (n=86,772 UK Biobank): bright NIGHT light ↑ risk of depression/anxiety/etc.,
// daytime light ↓ risk, independently. Relative lux is sufficient (they used relative/quantile
// light). Objective light-hygiene only — NEVER a personal psychiatric prediction. ADC = RELATIVE.
use crate::util::round;
use serde::Serialize;

#[derive(Debug, Serialize)]
pub struct LightOut {
    pub night_light_burden: Option<f64>, // mean relative lux during the sleep window
    pub day_light_dose: Option<f64>,     // mean relative lux during the waking day
    pub pre_bed_light: Option<f64>,      // mean relative lux in the hour before sleep onset
    pub day_night_ratio: Option<f64>,    // higher = healthier (bright days, dark nights)
    pub n_minutes: u32,
    pub confidence: f64,
    pub tier: String,
    pub label: String,
    pub inputs_used: Vec<String>,
}

/// samples = per-minute (ts, relative_lux); sleep window [onset_ts, wake_ts].
pub fn light_hygiene(samples: &[(f64, f64)], onset_ts: f64, wake_ts: f64) -> LightOut {
    let label = "light hygiene (relative) — objective exposure, not a prediction".to_string();
    let n = samples.len();
    if n < 30 || wake_ts <= onset_ts {
        return LightOut {
            night_light_burden: None, day_light_dose: None, pre_bed_light: None, day_night_ratio: None,
            n_minutes: n as u32, confidence: 0.0, tier: "RELATIVE".to_string(), label, inputs_used: vec![],
        };
    }
    let mean_of = |f: &dyn Fn(f64) -> bool| -> Option<f64> {
        let v: Vec<f64> = samples.iter().filter(|(t, _)| f(*t)).map(|(_, l)| *l).collect();
        if v.is_empty() { None } else { Some(v.iter().sum::<f64>() / v.len() as f64) }
    };
    let night = mean_of(&|t| t >= onset_ts && t <= wake_ts);
    let day = mean_of(&|t| t < onset_ts || t > wake_ts);
    let pre_bed = mean_of(&|t| t >= onset_ts - 3600.0 && t < onset_ts);
    let ratio = match (day, night) {
        (Some(d), Some(nv)) if nv > 0.0 => Some(round(d / nv, 2)),
        (Some(_), Some(_)) => Some(999.0), // dark night (night≈0) → effectively ideal
        _ => None,
    };
    LightOut {
        night_light_burden: night.map(|v| round(v, 1)),
        day_light_dose: day.map(|v| round(v, 1)),
        pre_bed_light: pre_bed.map(|v| round(v, 1)),
        day_night_ratio: ratio,
        n_minutes: n as u32,
        confidence: round((n as f64 / 1440.0).min(1.0), 3),
        tier: "RELATIVE".to_string(),
        label,
        inputs_used: vec!["ambient_raw".to_string()],
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn bright_night_high_burden() {
        // night window [0, 28800] bright (500), day dim-ish (300) → low day/night ratio.
        let mut v = Vec::new();
        for i in 0..480 { v.push((i as f64 * 60.0, 500.0)); }            // night, bright
        for i in 480..960 { v.push((i as f64 * 60.0, 300.0)); }          // day
        let o = light_hygiene(&v, 0.0, 28740.0);
        assert!(o.night_light_burden.unwrap() > 400.0, "{:?}", o.night_light_burden);
        assert!(o.day_night_ratio.unwrap() < 1.0, "{:?}", o.day_night_ratio);
    }
    #[test]
    fn dark_night_bright_day_healthy() {
        let mut v = Vec::new();
        for i in 0..480 { v.push((i as f64 * 60.0, 2.0)); }              // night, dark
        for i in 480..960 { v.push((i as f64 * 60.0, 800.0)); }          // day, bright
        let o = light_hygiene(&v, 0.0, 28740.0);
        assert!(o.day_night_ratio.unwrap() > 5.0, "{:?}", o.day_night_ratio);
    }
}
