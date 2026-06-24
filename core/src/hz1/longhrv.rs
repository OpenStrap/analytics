// 1 Hz family — long-window HRV: 24-h SDNN (the prognostic one), SDANN, SDNN-index,
// and ULF/VLF spectral power. Shaffer & Ginsberg 2017 Front Public Health 5:258.
// Bands: ULF ≤0.0033 Hz (needs ≥24 h — our structural edge), VLF 0.0033–0.04 Hz.
// HONESTY: PRV not ECG-HRV; per-user relative trend; NO clinical SDNN cutoffs. ULF
// is slow + motion-contaminated → gated on sufficient continuous span.
use crate::hrv::{clean_rr, lomb_scargle_band};
use crate::util::{mean, round, stddev};
use serde::Serialize;

#[derive(Debug, Serialize)]
pub struct LongHrvOut {
    pub sdnn: Option<f64>,        // ms over the whole window
    pub sdann: Option<f64>,       // ms — SD of 5-min mean NN
    pub sdnn_index: Option<f64>,  // ms — mean of 5-min SDNN
    pub ulf_power: Option<f64>,   // ms² (≤0.0033 Hz; needs ≥6 h)
    pub vlf_power: Option<f64>,   // ms²
    pub span_hours: f64,
    pub n_beats: u32,
    pub confidence: f64,
    pub tier: String,
    pub label: String,
    pub inputs_used: Vec<String>,
}

const SEG: f64 = 300.0; // 5-min segments for SDANN / SDNN-index

pub fn long_term_hrv(rr_raw: &[f64]) -> LongHrvOut {
    let rr = clean_rr(rr_raw);
    let n = rr.len();
    let none = |span: f64| LongHrvOut {
        sdnn: None, sdann: None, sdnn_index: None, ulf_power: None, vlf_power: None,
        span_hours: round(span, 3), n_beats: n as u32, confidence: 0.0,
        tier: "HIGH".to_string(),
        label: "24-h HRV (PRV; SDNN is the prognostic measure — relative, no clinical cutoff)".to_string(),
        inputs_used: vec!["rr_intervals".to_string()],
    };
    if n < 60 {
        return none(0.0);
    }
    // cumulative seconds tachogram
    let mut t = Vec::with_capacity(n);
    let mut accs = 0.0;
    for &r in &rr {
        accs += r / 1000.0;
        t.push(accs);
    }
    let span = t[n - 1];
    let span_h = span / 3600.0;

    let sdnn = stddev(&rr);

    // 5-min segments → SDANN (SD of segment means) + SDNN-index (mean of segment SDs)
    let mut seg_means: Vec<f64> = Vec::new();
    let mut seg_sds: Vec<f64> = Vec::new();
    let mut cur: Vec<f64> = Vec::new();
    let mut seg_end = SEG;
    for i in 0..n {
        if t[i] > seg_end && !cur.is_empty() {
            if cur.len() >= 5 {
                seg_means.push(mean(&cur));
                seg_sds.push(stddev(&cur));
            }
            cur.clear();
            while t[i] > seg_end {
                seg_end += SEG;
            }
        }
        cur.push(rr[i]);
    }
    if cur.len() >= 5 {
        seg_means.push(mean(&cur));
        seg_sds.push(stddev(&cur));
    }
    let sdann = if seg_means.len() >= 2 { Some(round(stddev(&seg_means), 1)) } else { None };
    let sdnn_index = if !seg_sds.is_empty() { Some(round(mean(&seg_sds), 1)) } else { None };

    // ULF / VLF spectral power via Lomb-Scargle (needs a long span to resolve ULF)
    let m = mean(&rr);
    let x: Vec<f64> = rr.iter().map(|r| r - m).collect();
    let (ulf_power, vlf_power) = if span >= 6.0 * 3600.0 {
        let ulf = lomb_scargle_band(&t, &x, 1.0e-5, 0.0033, 5.0e-5).0;
        let vlf = lomb_scargle_band(&t, &x, 0.0033, 0.04, 5.0e-4).0;
        (Some(round(ulf, 1)), Some(round(vlf, 1)))
    } else {
        (None, None)
    };

    let confidence = round((span_h / 24.0).min(1.0), 3);
    LongHrvOut {
        sdnn: Some(round(sdnn, 1)),
        sdann,
        sdnn_index,
        ulf_power,
        vlf_power,
        span_hours: round(span_h, 3),
        n_beats: n as u32,
        confidence,
        tier: "HIGH".to_string(),
        label: "24-h HRV (PRV; SDNN is the prognostic measure — relative, no clinical cutoff)".to_string(),
        inputs_used: vec!["rr_intervals".to_string()],
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sdnn_matches_stddev_and_ulf_gated_by_span() {
        // ~2 h of RR (span < 6 h) → SDNN present, ULF gated to None.
        let rr: Vec<f64> = (0..8000).map(|i| 800.0 + 40.0 * ((i as f64) / 50.0).sin()).collect();
        let out = long_term_hrv(&rr);
        let sdnn = out.sdnn.unwrap();
        assert!((sdnn - stddev(&crate::hrv::clean_rr(&rr))).abs() < 0.05, "sdnn≈stddev");
        assert!(out.span_hours > 1.0 && out.span_hours < 3.0, "span {}", out.span_hours);
        assert!(out.ulf_power.is_none(), "ULF must be gated under 6h");
        assert!(out.sdann.is_some() && out.sdnn_index.is_some());
    }

    #[test]
    fn ulf_present_and_nonneg_over_long_span() {
        // ~8 h span (mean RR 800 ms → ~36000 beats) with a slow ULF oscillation.
        let n = 36000;
        let rr: Vec<f64> = (0..n).map(|i| {
            let s = (i as f64) * 0.8; // ~seconds
            800.0 + 60.0 * (2.0 * std::f64::consts::PI * 0.0008 * s).sin()
        }).collect();
        let out = long_term_hrv(&rr);
        assert!(out.span_hours >= 6.0, "span {}", out.span_hours);
        let ulf = out.ulf_power.expect("ulf present over long span");
        assert!(ulf >= 0.0 && ulf.is_finite(), "ulf {ulf}");
    }
}
