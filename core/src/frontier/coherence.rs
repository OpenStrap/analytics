// Frontier — Cardiac COHERENCE / resonance meter (HeartMath; Lehrer & Gevirtz 2014
// resonance-frequency breathing). Paced ~0.1 Hz breathing drives a dominant RSA peak
// in the LF band; coherence = how concentrated spectral power is at that single peak.
// Pure physiology, NO health labels. Live spot-check (short RR window) but works on any RR.
use crate::hrv::{clean_rr, lomb_scargle_band};
use crate::util::round;
use serde::Serialize;

#[derive(Debug, Serialize)]
pub struct CoherenceOut {
    pub coherence: Option<f64>,  // peak prominence: peak power / mean band power (≥1)
    pub score: Option<f64>,      // 0..100 ease-of-use score
    pub peak_freq: Option<f64>,  // Hz of the dominant peak (≈ paced breathing rate)
    pub n_beats: u32,
    pub confidence: f64,
    pub tier: String,
    pub label: String,
    pub inputs_used: Vec<String>,
}

pub fn coherence(rr_raw: &[f64]) -> CoherenceOut {
    let rr = clean_rr(rr_raw);
    let n = rr.len();
    let label = "cardiac coherence (resonance) — physiology, not a health score".to_string();
    let none = CoherenceOut {
        coherence: None, score: None, peak_freq: None, n_beats: n as u32,
        confidence: 0.0, tier: "RELATIVE".to_string(), label: label.clone(), inputs_used: vec![],
    };
    if n < 30 {
        return none;
    }
    // tachogram time base (s) + detrended RR (ms)
    let mut t = Vec::with_capacity(n);
    let mut acc = 0.0;
    for &r in &rr {
        acc += r / 1000.0;
        t.push(acc);
    }
    let span = t[n - 1] - t[0];
    if span < 60.0 {
        return none;
    }
    let m = rr.iter().sum::<f64>() / n as f64;
    let x: Vec<f64> = rr.iter().map(|r| r - m).collect();
    // coherence band 0.04–0.40 Hz (covers ~0.1 Hz resonance), 5 mHz grid.
    let (f_lo, f_hi, df) = (0.04, 0.40, 0.005);
    let (band_power, peak_freq, peak_power) = lomb_scargle_band(&t, &x, f_lo, f_hi, df);
    let _ = peak_power;
    // HeartMath-style power CONCENTRATION: fraction of band power inside a narrow
    // ±0.015 Hz window around the peak. Resonance peak → ~0.6–0.9; broadband noise → ~0.08
    // (a noise periodogram's max-bin/mean is spiky, so peak/mean is a poor measure — use mass).
    let win = lomb_scargle_band(&t, &x, (peak_freq - 0.015).max(f_lo), (peak_freq + 0.015).min(f_hi), df).0;
    let concentration = if band_power > 0.0 { (win / band_power).clamp(0.0, 1.0) } else { 0.0 };
    // ~0.08 (noise) → 0; ~0.5+ (tight resonance) → 100.
    let score = (((concentration - 0.10) / 0.40).clamp(0.0, 1.0)) * 100.0;
    CoherenceOut {
        coherence: Some(round(concentration, 3)),
        score: Some(round(score, 0)),
        peak_freq: Some(round(peak_freq, 3)),
        n_beats: n as u32,
        confidence: round((span / 120.0).min(1.0), 3),
        tier: "RELATIVE".to_string(),
        label,
        inputs_used: vec!["rr_intervals".to_string()],
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn paced_breathing_high_coherence() {
        // RR modulated by a clean 0.1 Hz sinusoid → tight resonance peak → high coherence.
        let mut rr = Vec::new();
        let mut t = 0.0;
        while t < 180.0 {
            let r = 900.0 + 120.0 * (2.0 * std::f64::consts::PI * 0.1 * t).sin();
            rr.push(r);
            t += r / 1000.0;
        }
        let o = coherence(&rr);
        assert!(o.coherence.unwrap() > 0.4, "coh {:?}", o.coherence);
        assert!(o.score.unwrap() >= 50.0, "score {:?}", o.score);
        assert!((o.peak_freq.unwrap() - 0.1).abs() < 0.02, "peak {:?}", o.peak_freq);
    }
    #[test]
    fn random_rr_low_coherence() {
        let rr: Vec<f64> = (0..260)
            .map(|i| { let h = ((i as f64) * 12.9898).sin() * 43758.5453; 820.0 + (h - h.floor()) * 60.0 })
            .collect();
        let o = coherence(&rr);
        assert!(o.score.unwrap() < 50.0, "score {:?}", o.score);
    }
}
