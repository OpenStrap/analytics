// 1 Hz family — Cyclic Variation of Heart Rate (CVHR) sleep-apnea SCREEN from RR
// alone. Guilleminault 1984 Lancet; Hayano 2011 Circ Arrhythm Electrophysiol 4:64
// (ACAT); Hayano 2020 PLOS One (ACAT on wrist pulse intervals — our signal class).
// Mechanism: apnea→bradycardia (RR↑) then arousal→tachycardia (RR↓), a 25–130 s
// cyclic oscillation; cycles/hour (Fcv) tracks AHI (r≈0.84; Fcv>15 → AHI>15 ~83/88%).
// HONESTY: a multi-night SCREEN for SDB risk, NOT an AHI / diagnosis; huge
// night-to-night variability — never a single-night verdict. Simplified ACAT →
// tier ESTIMATE (full ACAT uses waveform autocorrelation + adaptive threshold).
use crate::hrv::clean_rr;
use crate::util::round;
use serde::Serialize;

#[derive(Debug, Serialize)]
pub struct CvhrOut {
    pub fcv_per_hour: Option<f64>, // cyclic-variation cycles / hour
    pub n_cycles: u32,
    pub high_risk: bool,           // Fcv > 15 (the AHI>15 screening threshold)
    pub hours: f64,
    pub confidence: f64,
    pub tier: String,
    pub label: String,
    pub note: String,
    pub inputs_used: Vec<String>,
}

const DEPTH_MS: f64 = 30.0;    // min bradycardia bump prominence (ms)
const W_MIN: f64 = 10.0;       // bump width seconds
const W_MAX: f64 = 120.0;
const DW_MIN: f64 = 0.7;       // depth/width ms/s
const IBI_MIN: f64 = 25.0;     // inter-cycle seconds
const IBI_MAX: f64 = 130.0;

pub fn cvhr_screen(rr_raw: &[f64]) -> CvhrOut {
    let rr = clean_rr(rr_raw);
    let n = rr.len();
    let none = |hours: f64| CvhrOut {
        fcv_per_hour: None, n_cycles: 0, high_risk: false, hours: round(hours, 3),
        confidence: 0.0, tier: "ESTIMATE".to_string(),
        label: "Cyclic-variation-of-HR apnea screen (PRV)".to_string(),
        note: "a multi-night screen for sleep-disordered-breathing risk, not a diagnosis".to_string(),
        inputs_used: vec!["rr_intervals".to_string()],
    };
    if n < 120 {
        return none(0.0);
    }
    // cumulative seconds + 3-beat moving-average smoothing
    let mut t = vec![0.0; n];
    let mut accs = 0.0;
    for i in 0..n {
        accs += rr[i] / 1000.0;
        t[i] = accs;
    }
    let hours = accs / 3600.0;
    if hours < 0.5 {
        return none(hours);
    }
    let mut sm = vec![0.0; n];
    for i in 0..n {
        let lo = i.saturating_sub(1);
        let hi = (i + 2).min(n);
        sm[i] = rr[lo..hi].iter().sum::<f64>() / (hi - lo) as f64;
    }
    // local extrema indices
    let mut maxima: Vec<usize> = Vec::new();
    let mut minima: Vec<usize> = Vec::new();
    for i in 1..(n - 1) {
        if sm[i] >= sm[i - 1] && sm[i] > sm[i + 1] {
            maxima.push(i);
        } else if sm[i] <= sm[i - 1] && sm[i] < sm[i + 1] {
            minima.push(i);
        }
    }
    // qualifying bradycardia bumps (peaks with a trough each side)
    let mut peak_times: Vec<f64> = Vec::new();
    for &p in &maxima {
        let prev_min = minima.iter().rev().find(|&&m| m < p).copied();
        let next_min = minima.iter().find(|&&m| m > p).copied();
        if let (Some(a), Some(b)) = (prev_min, next_min) {
            let prom = (sm[p] - sm[a]).min(sm[p] - sm[b]);
            let width = t[b] - t[a];
            if prom >= DEPTH_MS && width >= W_MIN && width <= W_MAX && (prom / width) > DW_MIN {
                peak_times.push(t[p]);
            }
        }
    }
    // cyclicity: count inter-peak intervals in [25,130]s that sit in a run of ≥3
    let mut cycles = 0u32;
    if peak_times.len() >= 3 {
        let intervals: Vec<f64> = peak_times.windows(2).map(|w| w[1] - w[0]).collect();
        let ok: Vec<bool> = intervals.iter().map(|&iv| iv >= IBI_MIN && iv <= IBI_MAX).collect();
        // a qualifying interval counts if it's within a run of ≥3 consecutive ok intervals
        let mut i = 0;
        while i < ok.len() {
            if ok[i] {
                let start = i;
                while i < ok.len() && ok[i] {
                    i += 1;
                }
                let run = i - start;
                if run >= 3 {
                    cycles += run as u32;
                }
            } else {
                i += 1;
            }
        }
    }
    let fcv = cycles as f64 / hours;
    CvhrOut {
        fcv_per_hour: Some(round(fcv, 1)),
        n_cycles: cycles,
        high_risk: fcv > 15.0,
        hours: round(hours, 3),
        confidence: round((hours / 6.0).min(1.0), 3),
        tier: "ESTIMATE".to_string(),
        label: "Cyclic-variation-of-HR apnea screen (PRV)".to_string(),
        note: "a multi-night screen for sleep-disordered-breathing risk, not a diagnosis".to_string(),
        inputs_used: vec!["rr_intervals".to_string()],
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Build a beat sequence with a bradycardia bump every `period` s (apnea-like).
    fn cyclic_rr(period: f64, minutes: f64) -> Vec<f64> {
        let mut rr = Vec::new();
        let mut t = 0.0;
        let total = minutes * 60.0;
        while t < total {
            let phase = t % period;
            // a ~10 s bump of +150 ms centred at 5 s into each cycle
            let bump = 150.0 * (-((phase - 5.0).powi(2)) / (2.0 * 9.0)).exp();
            let r = 800.0 + bump;
            rr.push(r);
            t += r / 1000.0;
        }
        rr
    }

    #[test]
    fn cyclic_signal_detected_and_high_risk() {
        let rr = cyclic_rr(45.0, 40.0); // 45 s cycles for 40 min → ~53 cycles
        let out = cvhr_screen(&rr);
        assert!(out.n_cycles >= 20, "expected many cycles, got {}", out.n_cycles);
        assert!(out.high_risk, "Fcv {:?} should exceed 15", out.fcv_per_hour);
    }

    #[test]
    fn flat_rr_no_cycles() {
        let rr = vec![800.0; 4000];
        let out = cvhr_screen(&rr);
        assert_eq!(out.n_cycles, 0);
        assert!(!out.high_risk);
    }
}
