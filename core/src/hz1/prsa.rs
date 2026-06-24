// 1 Hz family — Deceleration / Acceleration Capacity via Phase-Rectified Signal
// Averaging (PRSA). Bauer et al. 2006 Lancet 367:1674; PRSA: Bauer 2006 Physica A
// 364:423; Kantelhardt 2007 Chaos 17:015112.
//
// Anchors where RR(t) > RR(t-1) (deceleration) or < (acceleration), T=1; align
// 2L-beat windows on anchors; average → PRSA curve X(k); Haar wavelet s=2:
//   DC = ¼·[X(0)+X(1)−X(−1)−X(−2)]  (ms).
// HONESTY: PRV not ECG-HRV; relative per-user trend — NEVER surface the 4.5 ms
// mortality cutoff (does not transfer to PPG/our population). Run after clean_rr.
use crate::hrv::clean_rr;
use crate::util::round;
use serde::Serialize;

#[derive(Debug, Serialize)]
pub struct PrsaOut {
    pub dc: Option<f64>, // deceleration capacity (ms), +ve = vagal
    pub ac: Option<f64>, // acceleration capacity (ms), -ve
    pub n_anchors_dc: u32,
    pub n_anchors_ac: u32,
    pub window: u32,
    pub confidence: f64,
    pub tier: String,
    pub label: String,
    pub inputs_used: Vec<String>,
}

/// PRSA curve value at relative position k over anchors (decel if `decel`). T=1,
/// artifact cap 5% (reject ectopy-mislabelled anchors per catalog).
fn prsa_capacity(rr: &[f64], window: usize, decel: bool) -> (Option<f64>, u32) {
    let n = rr.len();
    let l = window;
    if n < 2 * l + 1 || l < 2 {
        return (None, 0);
    }
    // accumulate X(k) for k in -l..=l-1 (indices 0..2l), centred at l.
    let mut acc = vec![0.0_f64; 2 * l];
    let mut anchors = 0u32;
    for i in l..(n - l) {
        let rel = (rr[i] - rr[i - 1]) / rr[i - 1];
        let is_anchor = if decel { rel > 0.0 && rel <= 0.05 } else { rel < 0.0 && rel >= -0.05 };
        if !is_anchor {
            continue;
        }
        anchors += 1;
        for k in 0..(2 * l) {
            acc[k] += rr[i - l + k];
        }
    }
    if anchors < 20 {
        return (None, anchors);
    }
    let x: Vec<f64> = acc.iter().map(|s| s / anchors as f64).collect();
    // centre index = l → X(0)=x[l], X(1)=x[l+1], X(-1)=x[l-1], X(-2)=x[l-2]
    let cap = (x[l] + x[l + 1] - x[l - 1] - x[l - 2]) / 4.0;
    (Some(round(cap, 2)), anchors)
}

pub fn capacity(rr_raw: &[f64], window: usize) -> PrsaOut {
    let rr = clean_rr(rr_raw);
    let l = if window >= 2 { window } else { 2 };
    let (dc, ndc) = prsa_capacity(&rr, l, true);
    let (ac, nac) = prsa_capacity(&rr, l, false);
    let conf = if dc.is_some() {
        round((ndc.min(nac) as f64 / 200.0).min(1.0), 3)
    } else {
        0.0
    };
    PrsaOut {
        dc,
        ac,
        n_anchors_dc: ndc,
        n_anchors_ac: nac,
        window: l as u32,
        confidence: conf,
        tier: "HIGH".to_string(),
        label: "Deceleration/Acceleration Capacity (PRV, relative — not a clinical cutoff)".to_string(),
        inputs_used: vec!["rr_intervals".to_string()],
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn symmetric_oscillation_dc_positive_ac_negative_and_symmetric() {
        // a clean sinusoidal RR oscillation: decelerations on the rising half,
        // accelerations on the falling half → DC>0, AC<0, |DC|≈|AC| by symmetry.
        let rr: Vec<f64> = (0..2000).map(|i| 800.0 + 30.0 * ((i as f64) / 12.0).sin()).collect();
        let out = capacity(&rr, 4);
        let dc = out.dc.expect("dc");
        let ac = out.ac.expect("ac");
        assert!(dc > 0.0, "dc should be +ve, got {dc}");
        assert!(ac < 0.0, "ac should be -ve, got {ac}");
        assert!((dc + ac).abs() < 0.5 * dc.abs(), "DC/AC should be ~symmetric: dc={dc} ac={ac}");
    }

    #[test]
    fn flat_rr_near_zero_capacity() {
        let rr = vec![800.0; 2000];
        let out = capacity(&rr, 4);
        // no anchors (no rises/falls) → null
        assert!(out.dc.is_none());
        assert_eq!(out.n_anchors_dc, 0);
    }

    #[test]
    fn too_short_is_null() {
        let out = capacity(&[800.0, 820.0, 800.0, 820.0], 4);
        assert!(out.dc.is_none());
        assert_eq!(out.confidence, 0.0);
    }
}
