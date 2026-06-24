// Frontier — Nocturnal autonomic RECOVERY-DEBT (perseverative cognition / "can't let go").
// Brosschot 2006; Ottaviani 2016: rumination/stress produces SUSTAINED overnight elevated HR
// + suppressed HRV that fails to recover — a signature ONLY continuous all-night RR captures
// (lab studies can't). Per-user, baseline-relative; a state descriptor, never a diagnosis.
use crate::util::round;
use serde::Serialize;

#[derive(Debug, Serialize)]
pub struct RecoveryDebtOut {
    pub debt_score: Option<f64>,        // 0..100 (fraction of night non-recovered, sustained-weighted)
    pub nonrecovered_frac: Option<f64>, // raw fraction of minutes non-recovered
    pub longest_run_min: u32,           // longest sustained non-recovered stretch
    pub n_minutes: u32,
    pub confidence: f64,
    pub tier: String,
    pub label: String,
    pub inputs_used: Vec<String>,
}

/// Per-minute nocturnal (hr, rmssd?) over the sleep window; baselines = sleeping-HR & RMSSD.
pub fn recovery_debt(hr: &[f64], rmssd: &[Option<f64>], base_hr: f64, base_rmssd: f64) -> RecoveryDebtOut {
    let label = "nocturnal autonomic recovery — sustained non-recovery, not a diagnosis".to_string();
    let n = hr.len();
    if n < 30 || base_hr <= 0.0 {
        return RecoveryDebtOut {
            debt_score: None, nonrecovered_frac: None, longest_run_min: 0, n_minutes: n as u32,
            confidence: 0.0, tier: "ESTIMATE".to_string(), label, inputs_used: vec![],
        };
    }
    let hr_thr = base_hr * 1.05;          // >5% above sleeping baseline
    let rmssd_thr = base_rmssd * 0.85;    // <85% of baseline HRV
    let mut nonrec = 0u32;
    let mut run = 0u32;
    let mut longest = 0u32;
    for i in 0..n {
        let hr_bad = hr[i] > hr_thr;
        let hrv_bad = match rmssd.get(i).copied().flatten() {
            Some(v) if base_rmssd > 0.0 => v < rmssd_thr,
            _ => false,
        };
        if hr_bad || hrv_bad {
            nonrec += 1;
            run += 1;
            longest = longest.max(run);
        } else {
            run = 0;
        }
    }
    let frac = nonrec as f64 / n as f64;
    // sustained-weighted: blend overall fraction with the longest contiguous stretch.
    let sustained = longest as f64 / n as f64;
    let score = ((0.6 * frac + 0.4 * sustained) * 100.0).clamp(0.0, 100.0);
    RecoveryDebtOut {
        debt_score: Some(round(score, 0)),
        nonrecovered_frac: Some(round(frac, 3)),
        longest_run_min: longest,
        n_minutes: n as u32,
        confidence: round((n as f64 / 240.0).min(1.0), 3),
        tier: "ESTIMATE".to_string(),
        label,
        inputs_used: vec!["hr_avg".to_string(), "hrv_rmssd".to_string()],
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn elevated_all_night_high_debt() {
        let hr = vec![62.0; 240];                 // base 54 → all >1.05×
        let rm: Vec<Option<f64>> = vec![None; 240];
        let o = recovery_debt(&hr, &rm, 54.0, 70.0);
        assert!(o.debt_score.unwrap() > 90.0, "{:?}", o.debt_score);
        assert!(o.longest_run_min > 230);
    }
    #[test]
    fn recovers_second_half_low_debt() {
        let mut hr = vec![62.0; 80];              // elevated early
        hr.extend(vec![52.0; 160]);               // recovers (below base)
        let rm: Vec<Option<f64>> = vec![None; 240];
        let o = recovery_debt(&hr, &rm, 54.0, 70.0);
        assert!(o.debt_score.unwrap() < 45.0, "{:?}", o.debt_score);
    }
    #[test]
    fn calm_night_zero() {
        let hr = vec![52.0; 240];
        let rm: Vec<Option<f64>> = (0..240).map(|_| Some(72.0)).collect();
        let o = recovery_debt(&hr, &rm, 54.0, 70.0);
        assert!(o.debt_score.unwrap() < 5.0, "{:?}", o.debt_score);
    }
}
