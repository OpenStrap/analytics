// Frontier — Alcohol nocturnal signature (the most reproducible wearable finding; Oura
// 600k-member dataset; Pietilä 2018). Alcohol → elevated sleeping HR + suppressed HRV +
// DELAYED HR-nadir (parasympathetic recovery pushed late into the night). Per-user,
// baseline-relative; a probabilistic SCREEN ("looks like an alcohol night"), opt-in,
// never a moral/medical claim. nadir_fraction = position of HR nadir within sleep (0..1);
// healthy nadir is early (~0.3–0.5), alcohol pushes it late.
use crate::util::{mean, round, stddev};
use serde::Serialize;

#[derive(Debug, Serialize)]
pub struct AlcoholOut {
    pub flag: bool,
    pub hr_elevation_pct: Option<f64>,  // sleeping HR vs baseline (%)
    pub hrv_suppression_pct: Option<f64>, // RMSSD vs baseline (% drop, +ve = suppressed)
    pub nadir_delay: Option<f64>,        // tonight's nadir_fraction − baseline mean
    pub score: Option<f64>,              // 0..100 likelihood
    pub confidence: f64,
    pub tier: String,
    pub label: String,
    pub inputs_used: Vec<String>,
}

/// tonight: (sleeping_hr, rmssd, nadir_fraction). baselines: prior nights' same three.
pub fn alcohol_signature(
    sleeping_hr: f64, rmssd: f64, nadir_fraction: f64,
    base_hr: &[f64], base_rmssd: &[f64], base_nadir: &[f64],
) -> AlcoholOut {
    let label = "possible alcohol night — a screen, not a judgement".to_string();
    let none = AlcoholOut {
        flag: false, hr_elevation_pct: None, hrv_suppression_pct: None, nadir_delay: None,
        score: None, confidence: 0.0, tier: "ESTIMATE".to_string(), label: label.clone(), inputs_used: vec![],
    };
    if base_hr.len() < 5 || base_rmssd.len() < 5 {
        return none;
    }
    let bhr = mean(base_hr);
    let brm = mean(base_rmssd);
    if bhr <= 0.0 || brm <= 0.0 {
        return none;
    }
    let hr_elev = (sleeping_hr - bhr) / bhr * 100.0;
    let hrv_supp = (brm - rmssd) / brm * 100.0;
    let nadir_delay = if base_nadir.len() >= 5 { nadir_fraction - mean(base_nadir) } else { 0.0 };

    // z-scores vs baseline spread for a graded score (robust to person-to-person scale).
    let z = |v: f64, b: &[f64]| { let s = stddev(b); if s > 0.0 { (v - mean(b)) / s } else { 0.0 } };
    let z_hr = z(sleeping_hr, base_hr);          // +ve = elevated
    let z_rm = -z(rmssd, base_rmssd);            // +ve = suppressed
    // Oura thresholds: ~+8% HR / ~−16% HRV at meaningful intake; require BOTH cardinal signs.
    let cardinal = hr_elev >= 5.0 && hrv_supp >= 10.0;
    let composite = (z_hr.max(0.0) + z_rm.max(0.0)) / 2.0 + if nadir_delay > 0.1 { 0.5 } else { 0.0 };
    let score = (composite / 3.0 * 100.0).clamp(0.0, 100.0);
    let flag = cardinal && composite >= 1.0;

    AlcoholOut {
        flag,
        hr_elevation_pct: Some(round(hr_elev, 1)),
        hrv_suppression_pct: Some(round(hrv_supp, 1)),
        nadir_delay: Some(round(nadir_delay, 3)),
        score: Some(round(score, 0)),
        confidence: round((base_hr.len() as f64 / 21.0).min(1.0), 3),
        tier: "ESTIMATE".to_string(),
        label,
        inputs_used: vec!["sleeping_hr".to_string(), "hrv_rmssd".to_string(), "hr_nadir_timing".to_string()],
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn alcohol_night_flags() {
        let base_hr = vec![54.0, 55.0, 53.0, 54.0, 56.0, 55.0, 54.0];
        let base_rm = vec![70.0, 68.0, 72.0, 69.0, 71.0, 70.0, 73.0];
        let base_nd = vec![0.35, 0.40, 0.33, 0.38, 0.36, 0.34, 0.37];
        // +13% HR, −36% HRV, late nadir
        let o = alcohol_signature(61.0, 45.0, 0.72, &base_hr, &base_rm, &base_nd);
        assert!(o.flag, "{:?}", o);
        assert!(o.hr_elevation_pct.unwrap() > 8.0);
        assert!(o.hrv_suppression_pct.unwrap() > 20.0);
        assert!(o.nadir_delay.unwrap() > 0.2);
    }
    #[test]
    fn sober_night_clear() {
        let base_hr = vec![54.0, 55.0, 53.0, 54.0, 56.0, 55.0, 54.0];
        let base_rm = vec![70.0, 68.0, 72.0, 69.0, 71.0, 70.0, 73.0];
        let base_nd = vec![0.35, 0.40, 0.33, 0.38, 0.36, 0.34, 0.37];
        let o = alcohol_signature(54.0, 71.0, 0.37, &base_hr, &base_rm, &base_nd);
        assert!(!o.flag, "{:?}", o);
    }
}
