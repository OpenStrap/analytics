// Frontier — AF/ectopy BURDEN screen from 24/7 beat-to-beat RR. Lorenz/Poincaré
// dispersion (Sarkar 2008 IEEE TBME 55:1219) + successive-ΔRR map (Lian 2011).
// Regular sinus → tight cloud; AF/ectopy → dispersed cloud + high irregularity.
// SCREEN, not a diagnosis (no ECG morphology). Per-user; relative burden over window.
use crate::hrv::clean_rr;
use crate::util::round;
use serde::Serialize;
use std::collections::HashSet;

#[derive(Debug, Serialize)]
pub struct AfBurdenOut {
    pub irregularity: Option<f64>,     // fraction of beats with |ΔRR| > 50 ms
    pub lorenz_occupancy: Option<f64>, // occupied 25 ms grid cells / candidate points (cloud spread)
    pub drr_sd: Option<f64>,           // SD of successive ΔRR (ms)
    pub flag: bool,
    pub n_beats: u32,
    pub confidence: f64,
    pub tier: String,
    pub label: String,
    pub inputs_used: Vec<String>,
}

pub fn af_burden(rr_raw: &[f64]) -> AfBurdenOut {
    let rr = clean_rr(rr_raw);
    let n = rr.len();
    let label = "AF/ectopy screen — not a diagnosis".to_string();
    if n < 60 {
        return AfBurdenOut {
            irregularity: None, lorenz_occupancy: None, drr_sd: None, flag: false,
            n_beats: n as u32, confidence: 0.0, tier: "ESTIMATE".to_string(), label, inputs_used: vec![],
        };
    }
    let drr: Vec<f64> = (1..n).map(|i| rr[i] - rr[i - 1]).collect();
    let m = drr.iter().sum::<f64>() / drr.len() as f64;
    let sd = (drr.iter().map(|d| (d - m) * (d - m)).sum::<f64>() / drr.len() as f64).sqrt();
    let irr = drr.iter().filter(|d| d.abs() > 50.0).count() as f64 / drr.len() as f64;

    // Lorenz cloud occupancy: bin (ΔRR[i], ΔRR[i+1]) into 25 ms cells over ±300 ms.
    let bin = |v: f64| -> i64 { (v.clamp(-300.0, 300.0) / 25.0).round() as i64 };
    let mut cells: HashSet<(i64, i64)> = HashSet::new();
    let pts = drr.len().saturating_sub(1);
    for i in 0..pts {
        cells.insert((bin(drr[i]), bin(drr[i + 1])));
    }
    let occ = if pts > 0 { cells.len() as f64 / pts as f64 } else { 0.0 };

    // Conservative: AF = irregularly-irregular → BOTH a dispersed cloud and high beat-to-beat irregularity.
    let flag = occ > 0.32 && irr > 0.30; // occ calibrated to the 25 ms Lorenz grid (irregular 0.33-0.6 vs regular ~0.1)
    AfBurdenOut {
        irregularity: Some(round(irr, 3)),
        lorenz_occupancy: Some(round(occ, 3)),
        drr_sd: Some(round(sd, 1)),
        flag,
        n_beats: n as u32,
        confidence: round((n as f64 / 3600.0).min(1.0), 3),
        tier: "ESTIMATE".to_string(),
        label,
        inputs_used: vec!["rr_intervals".to_string()],
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn regular_sinus_tight_no_flag() {
        let rr: Vec<f64> = (0..400).map(|i| 850.0 + 8.0 * ((i as f64) / 6.0).sin()).collect();
        let o = af_burden(&rr);
        assert!(o.lorenz_occupancy.unwrap() < 0.40, "occ {:?}", o.lorenz_occupancy);
        assert!(!o.flag);
    }
    #[test]
    fn irregular_dispersed_flag() {
        let mut s: u64 = 99;
        let mut cur = 850.0_f64;
        let mut rr = Vec::new();
        for _ in 0..400 {
            s = s.wrapping_mul(6364136223846793005).wrapping_add(1);
            let step = ((s >> 40) as f64 % 300.0) - 150.0; // +-150 ms, survives clean_rr
            cur = (cur + step).clamp(650.0, 1050.0);
            rr.push(cur);
        }
        let o = af_burden(&rr);
        assert!(o.irregularity.unwrap() > 0.5, "irr {:?}", o.irregularity);
        assert!(o.lorenz_occupancy.unwrap() > 0.30, "occ {:?}", o.lorenz_occupancy);
        assert!(o.flag);
    }
}
