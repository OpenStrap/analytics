// Frontier — Altitude / Heat ACCLIMATIZATION tracker. The textbook adaptation signature
// is a trajectory: on exposure the body deviates from sea-level/pre-heat baseline (altitude:
// relative-SpO2↓, RHR↑, HRV↓; heat: RHR↓ over days, skin-temp↓, HRV↑), then RECOVERS toward
// baseline over ~3–10 days. We track the magnitude-of-deviation trajectory (sign-agnostic),
// so one engine serves both. Relative SpO2/temp is SUFFICIENT — acclimatization is
// trajectory-vs-personal-baseline, not absolute. Karinen 2012; Périard 2015. ESTIMATE.
use crate::util::round;
use serde::Serialize;

#[derive(Debug, Serialize)]
pub struct AcclimatizationOut {
    pub mode: String,
    pub progress_pct: Option<f64>,  // 0 = fully perturbed (day-1 level), 100 = back to baseline
    pub current_deviation: Option<f64>, // today's composite |z| from baseline
    pub initial_deviation: Option<f64>,
    pub direction: String,          // "adapting" | "stable" | "worsening"
    pub days: u32,
    pub confidence: f64,
    pub tier: String,
    pub label: String,
    pub inputs_used: Vec<String>,
}

/// days = per-day (spo2_rel, rhr, hrv); base = (mean, mean, mean); sd = (sd, sd, sd).
pub fn acclimatization(
    days: &[(f64, f64, f64)], base: (f64, f64, f64), sd: (f64, f64, f64), mode: &str,
) -> AcclimatizationOut {
    let label = format!("{} acclimatization — relative trajectory vs your baseline", mode);
    let none = AcclimatizationOut {
        mode: mode.to_string(), progress_pct: None, current_deviation: None, initial_deviation: None,
        direction: "unknown".to_string(), days: days.len() as u32, confidence: 0.0,
        tier: "ESTIMATE".to_string(), label: label.clone(), inputs_used: vec![],
    };
    if days.len() < 2 {
        return none;
    }
    let sdz = |s: f64| if s > 0.0 { s } else { 1.0 };
    // composite |z| deviation magnitude per day (sign-agnostic → works for altitude & heat).
    let dev: Vec<f64> = days
        .iter()
        .map(|&(a, b, c)| {
            (((a - base.0) / sdz(sd.0)).abs() + ((b - base.1) / sdz(sd.1)).abs() + ((c - base.2) / sdz(sd.2)).abs()) / 3.0
        })
        .collect();
    // initial perturbation = max of the first two days (exposure peak).
    let initial = dev[0].max(dev[1]);
    let current = *dev.last().unwrap();
    let progress = if initial > 1e-6 { (1.0 - current / initial).clamp(0.0, 1.0) * 100.0 } else { 100.0 };
    // direction from the slope of the last few days' deviation.
    let tail = &dev[dev.len().saturating_sub(3)..];
    let slope = if tail.len() >= 2 { tail[tail.len() - 1] - tail[0] } else { 0.0 };
    let direction = if slope < -0.15 { "adapting" } else if slope > 0.15 { "worsening" } else { "stable" };

    AcclimatizationOut {
        mode: mode.to_string(),
        progress_pct: Some(round(progress, 0)),
        current_deviation: Some(round(current, 2)),
        initial_deviation: Some(round(initial, 2)),
        direction: direction.to_string(),
        days: days.len() as u32,
        confidence: round((days.len() as f64 / 7.0).min(1.0), 3),
        tier: "ESTIMATE".to_string(),
        label,
        inputs_used: vec!["spo2_idx".to_string(), "resting_hr".to_string(), "hrv_rmssd".to_string()],
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn converging_trajectory_high_progress() {
        // baseline spo2_rel 1.0, rhr 54, hrv 70; sd 0.02/3/8.
        // altitude exposure: spo2 dips & recovers, rhr spikes & recovers, hrv drops & recovers.
        let days = vec![
            (0.92, 66.0, 45.0), // day1 big perturbation
            (0.94, 63.0, 50.0),
            (0.97, 59.0, 60.0),
            (0.99, 55.0, 68.0), // nearly back to baseline
        ];
        let o = acclimatization(&days, (1.0, 54.0, 70.0), (0.02, 3.0, 8.0), "altitude");
        assert!(o.progress_pct.unwrap() > 70.0, "progress {:?}", o.progress_pct);
        assert_eq!(o.direction, "adapting");
    }
    #[test]
    fn flat_high_deviation_low_progress() {
        let days = vec![(0.90, 67.0, 44.0), (0.90, 67.0, 44.0), (0.90, 67.0, 44.0)];
        let o = acclimatization(&days, (1.0, 54.0, 70.0), (0.02, 3.0, 8.0), "altitude");
        assert!(o.progress_pct.unwrap() < 20.0, "progress {:?}", o.progress_pct);
        assert_eq!(o.direction, "stable");
    }
}
