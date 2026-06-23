// Port of openstrap-analytics/src/stress.ts — HRV-based stress (Baevsky SI + LF/HF).
use crate::hrv::{baevsky_stress_index, freq_domain_hrv, time_domain_hrv};
use crate::types::{Driver, MetricRef, StressOut};
use crate::util::{mean, round, stddev};

pub fn calc_stress(rr: &[f64], baseline_si: &[f64], date: Option<&str>) -> StressOut {
    let si = baevsky_stress_index(rr);
    let td = time_domain_hrv(rr);
    let fd = freq_domain_hrv(rr);

    if si.si.is_none() {
        return StressOut {
            score: None, si: si.si, lf_hf: fd.lf_hf, rmssd: td.rmssd, level: None,
            confidence: 0.0, tier: "ESTIMATE".to_string(), inputs_used: vec![], drivers: None,
        };
    }
    let si_v = si.si.unwrap();
    let usable: Vec<f64> = baseline_si.iter().copied().filter(|&x| x > 0.0).collect();
    let mk_ref = || MetricRef { metric: "hrv".to_string(), date: date.map(|s| s.to_string()), scale: Some("day".to_string()) };

    let mut drivers = vec![Driver {
        label: "Baevsky Stress Index".to_string(),
        contribution: round(si_v, 1),
        detail: Some(format!("SI {}", si_v)),
        reference: Some(mk_ref()),
    }];
    if let Some(lfhf) = fd.lf_hf {
        drivers.push(Driver {
            label: "Sympatho-vagal balance (LF/HF)".to_string(),
            contribution: round(lfhf, 2),
            detail: Some(format!("LF/HF {}", lfhf)),
            reference: Some(mk_ref()),
        });
    }
    if let Some(rmssd) = td.rmssd {
        drivers.push(Driver {
            label: "HRV (RMSSD)".to_string(),
            contribution: round(-rmssd, 1),
            detail: Some(format!("{} ms", rmssd)),
            reference: Some(mk_ref()),
        });
    }

    if usable.len() < 5 {
        return StressOut {
            score: None, si: si.si, lf_hf: fd.lf_hf, rmssd: td.rmssd, level: None,
            confidence: round(0.4f64.min(si.n_beats as f64 / 300.0), 4),
            tier: "ESTIMATE".to_string(),
            inputs_used: vec!["hrv_si".to_string(), "hrv_lf_hf".to_string()],
            drivers: Some(drivers),
        };
    }

    let ln_base: Vec<f64> = usable.iter().map(|x| x.ln()).collect();
    let m = mean(&ln_base);
    let sd = stddev(&ln_base);
    let (mut score, _z): (Option<f64>, Option<f64>) = (None, None);
    if sd > 0.0 {
        let z = (si_v.ln() - m) / sd;
        score = Some((50.0 + 25.0 * z).round().max(0.0).min(100.0));
    }
    let level = score.map(|s| {
        if s < 40.0 { "low" } else if s <= 70.0 { "moderate" } else { "elevated" }.to_string()
    });
    let confidence = 1f64.min(usable.len() as f64 / 21.0) * 1f64.min(si.n_beats as f64 / 300.0);
    StressOut {
        score, si: si.si, lf_hf: fd.lf_hf, rmssd: td.rmssd, level,
        confidence: round(confidence, 4),
        tier: "ESTIMATE".to_string(),
        inputs_used: vec!["hrv_si".to_string(), "hrv_lf_hf".to_string(), "baseline.hrv_si".to_string()],
        drivers: Some(drivers),
    }
}
