// Port of openstrap-analytics/src/illness.ts — Mahalanobis multivariate illness signal.
use crate::types::{Driver, IllnessHistory, IllnessOut, IllnessToday, MetricRef};
use crate::util::{mean, round, stddev};

/// Invert symmetric NxN via Gauss-Jordan w/ partial pivoting; None if singular.
fn inv_matrix(m: &[Vec<f64>]) -> Option<Vec<Vec<f64>>> {
    let n = m.len();
    let mut a: Vec<Vec<f64>> = m
        .iter()
        .enumerate()
        .map(|(i, row)| {
            let mut r = row.clone();
            for j in 0..n {
                r.push(if i == j { 1.0 } else { 0.0 });
            }
            r
        })
        .collect();
    for col in 0..n {
        let mut piv = col;
        for r in (col + 1)..n {
            if a[r][col].abs() > a[piv][col].abs() {
                piv = r;
            }
        }
        if a[piv][col].abs() < 1e-12 {
            return None;
        }
        a.swap(col, piv);
        let d = a[col][col];
        for j in 0..(2 * n) {
            a[col][j] /= d;
        }
        for r in 0..n {
            if r == col {
                continue;
            }
            let f = a[r][col];
            for j in 0..(2 * n) {
                a[r][j] -= f * a[col][j];
            }
        }
    }
    Some(a.iter().map(|row| row[n..].to_vec()).collect())
}

struct Feat {
    key: &'static str,
    label: &'static str,
    today: f64,
    hist: Vec<f64>,
    dir: f64,
}

pub fn calc_illness(today: &IllnessToday, history: &IllnessHistory, cycle_phase: Option<&str>) -> IllnessOut {
    let note = "a signal, not a diagnosis".to_string();
    let mut cand: Vec<Feat> = Vec::new();
    if let Some(v) = today.resting_hr {
        if history.resting_hr.len() >= 7 {
            cand.push(Feat { key: "rhr", label: "Resting HR", today: v, hist: history.resting_hr.clone(), dir: 1.0 });
        }
    }
    if let Some(v) = today.rmssd {
        if history.rmssd.len() >= 7 {
            cand.push(Feat { key: "rmssd", label: "HRV (RMSSD)", today: v, hist: history.rmssd.clone(), dir: -1.0 });
        }
    }
    if let Some(v) = today.skin_temp {
        if history.skin_temp.len() >= 7 {
            cand.push(Feat { key: "temp", label: "Skin temperature", today: v, hist: history.skin_temp.clone(), dir: 1.0 });
        }
    }
    if let Some(v) = today.resp_rate {
        if history.resp_rate.len() >= 7 {
            cand.push(Feat { key: "resp", label: "Respiratory rate", today: v, hist: history.resp_rate.clone(), dir: 1.0 });
        }
    }

    let none = || IllnessOut {
        signal: false, distance: None, triggers: vec![], note: note.clone(),
        confidence: 0.0, tier: "ESTIMATE".to_string(), inputs_used: vec![], drivers: None,
    };
    if cand.len() < 2 {
        return none();
    }

    let z: Vec<f64> = cand
        .iter()
        .map(|f| {
            let mu = mean(&f.hist);
            let sd = stddev(&f.hist);
            if sd > 0.0 {
                f.dir * (f.today - mu) / sd
            } else {
                0.0
            }
        })
        .collect();

    let min_len = cand.iter().map(|f| f.hist.len()).min().unwrap();
    let dim = cand.len();
    let dvec = &z;
    let distance: f64;
    if dim >= 2 && min_len >= 7 {
        let tail: Vec<Vec<f64>> = cand.iter().map(|f| f.hist[f.hist.len() - min_len..].to_vec()).collect();
        let stds: Vec<(f64, f64)> = tail.iter().map(|h| (mean(h), { let s = stddev(h); if s == 0.0 { 1.0 } else { s } })).collect();
        let zmat: Vec<Vec<f64>> = tail.iter().enumerate().map(|(k, h)| h.iter().map(|v| (v - stds[k].0) / stds[k].1).collect()).collect();
        let mut corr = vec![vec![0.0; dim]; dim];
        for a in 0..dim {
            for b in 0..dim {
                let mut s = 0.0;
                for t in 0..min_len {
                    s += zmat[a][t] * zmat[b][t];
                }
                corr[a][b] = s / (min_len as f64 - 1.0);
            }
        }
        match inv_matrix(&corr) {
            Some(inv) => {
                let mut d2 = 0.0;
                for a in 0..dim {
                    for b in 0..dim {
                        d2 += dvec[a] * inv[a][b] * dvec[b];
                    }
                }
                distance = 0f64.max(d2).sqrt();
            }
            None => {
                distance = dvec.iter().map(|v| v * v).sum::<f64>().sqrt();
            }
        }
    } else {
        distance = dvec.iter().map(|v| v * v).sum::<f64>().sqrt();
    }

    let metric_for = |key: &str| match key {
        "rmssd" => "hrv",
        "rhr" => "rhr",
        "resp" => "resp",
        _ => "temp",
    };
    let input_name = |key: &str| match key {
        "rmssd" => "hrv_rmssd",
        "rhr" => "resting_hr",
        "resp" => "resp_rate",
        _ => "skin_temp",
    };
    let mut triggers: Vec<String> = Vec::new();
    let mut drivers: Vec<Driver> = Vec::new();
    for (k, f) in cand.iter().enumerate() {
        if z[k] > 0.75 {
            triggers.push(f.key.to_string());
            drivers.push(Driver {
                label: f.label.to_string(),
                contribution: round(z[k], 2),
                detail: Some(format!("{}σ toward illness", round(z[k], 1))),
                reference: Some(MetricRef { metric: metric_for(f.key).to_string(), date: None, scale: Some("day".to_string()) }),
            });
        }
    }

    let mut signal = distance > 2.5 && triggers.len() >= 2;
    let mut note_out = note.clone();
    let in_cycle = cycle_phase == Some("luteal") || cycle_phase == Some("menstruation");
    if signal && in_cycle {
        let corroborating: Vec<&String> = triggers.iter().filter(|t| t.as_str() != "rhr" && t.as_str() != "temp").collect();
        if corroborating.is_empty() {
            signal = false;
            note_out = format!("{} (a rise in temperature & resting HR can be expected in this phase of your cycle)", note);
        }
    }
    let confidence = 0.6f64.min((min_len as f64 / 30.0) * (cand.len() as f64 / 4.0));

    IllnessOut {
        signal,
        distance: Some(round(distance, 2)),
        triggers,
        note: note_out,
        confidence: round(confidence, 4),
        tier: "ESTIMATE".to_string(),
        inputs_used: cand.iter().map(|f| input_name(f.key).to_string()).collect(),
        drivers: Some(drivers),
    }
}
