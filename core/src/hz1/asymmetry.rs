// 1 Hz family — Heart-Rate Asymmetry + sympatho-vagal Poincaré indices.
// HRA: Guzik 2006 Biomed Tech 51:272; Piskorski & Guzik 2007 Physiol Meas 28:287.
// CSI/CVI: Toichi 1997 J Auton Nerv Syst 62:79.  S/ratio: Brennan 2001 IEEE TBME 48:1342.
// HONESTY: PRV not ECG-HRV; per-user relative; run AFTER clean_rr/AF correction
// (ectopy fabricates asymmetry). No clinical cutoffs.
use crate::hrv::clean_rr;
use crate::util::{round, stddev};
use serde::Serialize;

#[derive(Debug, Serialize)]
pub struct AsymmetryOut {
    pub gi: Option<f64>,   // Guzik Index (% of short-term variance from decelerations); >50 = decel-dominated
    pub pi: Option<f64>,   // Porta Index (% of points that are accelerations)
    pub si: Option<f64>,   // Slope Index (% of angular deviation from decelerations)
    pub sd1: Option<f64>,
    pub sd1d: Option<f64>, // deceleration contribution to SD1
    pub sd1a: Option<f64>, // acceleration contribution to SD1
    pub sd2: Option<f64>,
    pub csi: Option<f64>,  // SD2/SD1 (sympathetic proxy)
    pub cvi: Option<f64>,  // log10(16·SD1·SD2) (vagal)
    pub s_area: Option<f64>, // π·SD1·SD2
    pub sd_ratio: Option<f64>, // SD1/SD2
    pub asymmetric: bool,
    pub n: u32,
    pub confidence: f64,
    pub tier: String,
    pub label: String,
    pub inputs_used: Vec<String>,
}

pub fn heart_rate_asymmetry(rr_raw: &[f64]) -> AsymmetryOut {
    let rr = clean_rr(rr_raw);
    let n = rr.len();
    let none = AsymmetryOut {
        gi: None, pi: None, si: None, sd1: None, sd1d: None, sd1a: None, sd2: None,
        csi: None, cvi: None, s_area: None, sd_ratio: None, asymmetric: false, n: n as u32,
        confidence: 0.0, tier: "HIGH".to_string(),
        label: "Heart-rate asymmetry / sympatho-vagal (PRV, relative)".to_string(),
        inputs_used: vec!["rr_intervals".to_string()],
    };
    if n < 20 {
        return none;
    }
    let np = n - 1; // Poincaré points
    let inv_sqrt2 = 1.0 / std::f64::consts::SQRT_2;

    let mut sum_dd2 = 0.0;
    let mut sum_dd2_dec = 0.0;
    let mut sum_dd2_acc = 0.0;
    let mut count_acc = 0u32;
    let mut count_nz = 0u32;
    let mut sum_ang = 0.0;
    let mut sum_ang_dec = 0.0;
    for i in 0..np {
        let diff = rr[i + 1] - rr[i];
        let dd = diff * inv_sqrt2;
        let dd2 = dd * dd;
        sum_dd2 += dd2;
        let dev = (rr[i + 1]).atan2(rr[i]) - std::f64::consts::FRAC_PI_4; // +ve = decel
        sum_ang += dev.abs();
        if diff > 0.0 {
            sum_dd2_dec += dd2;
            sum_ang_dec += dev.abs();
        } else if diff < 0.0 {
            sum_dd2_acc += dd2;
            count_acc += 1;
        }
        if diff != 0.0 {
            count_nz += 1;
        }
    }
    let sd1d = (sum_dd2_dec / np as f64).sqrt();
    let sd1a = (sum_dd2_acc / np as f64).sqrt();
    let sd1 = (sum_dd2 / np as f64).sqrt();
    let sdnn = stddev(&rr);
    let sd2 = (2.0 * sdnn * sdnn - sd1 * sd1).max(0.0).sqrt();

    let gi = if sum_dd2 > 0.0 { sum_dd2_dec / sum_dd2 * 100.0 } else { 0.0 };
    let pi = if count_nz > 0 { count_acc as f64 / count_nz as f64 * 100.0 } else { 0.0 };
    let si = if sum_ang > 0.0 { sum_ang_dec / sum_ang * 100.0 } else { 0.0 };
    let csi = if sd1 > 0.0 { sd2 / sd1 } else { 0.0 };
    let cvi = if sd1 > 0.0 && sd2 > 0.0 { (16.0 * sd1 * sd2).log10() } else { 0.0 };
    let s_area = std::f64::consts::PI * sd1 * sd2;
    let sd_ratio = if sd2 > 0.0 { sd1 / sd2 } else { 0.0 };

    AsymmetryOut {
        gi: Some(round(gi, 1)),
        pi: Some(round(pi, 1)),
        si: Some(round(si, 1)),
        sd1: Some(round(sd1, 1)),
        sd1d: Some(round(sd1d, 1)),
        sd1a: Some(round(sd1a, 1)),
        sd2: Some(round(sd2, 1)),
        csi: Some(round(csi, 3)),
        cvi: Some(round(cvi, 3)),
        s_area: Some(round(s_area, 1)),
        sd_ratio: Some(round(sd_ratio, 3)),
        asymmetric: gi > 50.0,
        n: np as u32,
        confidence: round((np as f64 / 300.0).min(1.0), 3),
        tier: "HIGH".to_string(),
        label: "Heart-rate asymmetry / sympatho-vagal (PRV, relative)".to_string(),
        inputs_used: vec!["rr_intervals".to_string()],
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rr_from_diffs(block: &[f64], reps: usize) -> Vec<f64> {
        let mut rr = vec![800.0];
        for _ in 0..reps {
            for &d in block {
                let last = *rr.last().unwrap();
                rr.push(last + d);
            }
        }
        rr
    }

    #[test]
    fn known_decel_dominated_block_gives_gi25_pi25() {
        // diffs [+10,+10,+10,-30]: dd² = 50,50,50,450 → decel Σ=150, total=600 → GI=25;
        // accel count 1/4 → PI=25. (block sums to 0 so RR stays in-range.)
        let rr = rr_from_diffs(&[10.0, 10.0, 10.0, -30.0], 40);
        let out = heart_rate_asymmetry(&rr);
        assert!((out.gi.unwrap() - 25.0).abs() < 0.5, "GI {:?}", out.gi);
        assert!((out.pi.unwrap() - 25.0).abs() < 0.5, "PI {:?}", out.pi);
        assert!(!out.asymmetric); // GI<50
        assert!(out.csi.unwrap() > 0.0 && out.cvi.unwrap().is_finite());
    }

    #[test]
    fn symmetric_block_gives_gi50_pi50() {
        let rr = rr_from_diffs(&[10.0, -10.0], 60);
        let out = heart_rate_asymmetry(&rr);
        assert!((out.gi.unwrap() - 50.0).abs() < 0.5, "GI {:?}", out.gi);
        assert!((out.pi.unwrap() - 50.0).abs() < 0.5, "PI {:?}", out.pi);
        // SD1²=SD1d²+SD1a² identity
        let sd1 = out.sd1.unwrap();
        let sd1d = out.sd1d.unwrap();
        let sd1a = out.sd1a.unwrap();
        assert!((sd1 * sd1 - (sd1d * sd1d + sd1a * sd1a)).abs() < 1.0, "SD1 decomposition");
    }
}
