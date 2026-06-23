// Port of openstrap-analytics/src/cycles.ts — ultradian sleep-cycle detection (Rosenblum 2024).
use crate::hrv::clean_rr;
use crate::types::{MinuteRr, SleepCycle, SleepCyclesOut, ZPoint};

const SMOOTH_MIN: i64 = 10;
const MIN_PEAK_DIST: i64 = 20;
const MIN_PROMINENCE: f64 = 0.9;

fn minute_rmssd(rr: &[f64]) -> Option<f64> {
    if rr.len() < 12 {
        return None;
    }
    let c = clean_rr(rr);
    if c.len() < 10 {
        return None;
    }
    let mut s = 0.0;
    for i in 1..c.len() {
        let d = c[i] - c[i - 1];
        s += d * d;
    }
    Some((s / (c.len() as f64 - 1.0)).sqrt())
}

/// Local maxima w/ topographic prominence ≥ min_prom, then min spacing (keep highest in cluster).
fn find_peaks(y: &[Option<f64>], min_dist: i64, min_prom: f64) -> Vec<usize> {
    let n = y.len();
    let mut cand: Vec<(usize, f64)> = Vec::new();
    if n < 2 {
        return vec![];
    }
    for i in 1..(n - 1) {
        let yi = match y[i] {
            Some(v) => v,
            None => continue,
        };
        let a = y[i - 1].unwrap_or(f64::NEG_INFINITY);
        let b = y[i + 1].unwrap_or(f64::NEG_INFINITY);
        if !(yi >= a && yi > b) {
            continue;
        }
        let mut l = i;
        while l > 0 && y[l - 1].unwrap_or(f64::NEG_INFINITY) < yi {
            l -= 1;
        }
        let mut r = i;
        while r < n - 1 && y[r + 1].unwrap_or(f64::NEG_INFINITY) < yi {
            r += 1;
        }
        let mut lmin = yi;
        let mut rmin = yi;
        for k in l..=i {
            if let Some(v) = y[k] {
                if v < lmin {
                    lmin = v;
                }
            }
        }
        for k in i..=r {
            if let Some(v) = y[k] {
                if v < rmin {
                    rmin = v;
                }
            }
        }
        if yi - lmin.max(rmin) >= min_prom {
            cand.push((i, yi));
        }
    }
    cand.sort_by(|p, q| q.1.partial_cmp(&p.1).unwrap());
    let mut kept: Vec<usize> = Vec::new();
    for (i, _) in cand {
        if kept.iter().all(|&k| (i as i64 - k as i64).abs() >= min_dist) {
            kept.push(i);
        }
    }
    kept.sort();
    kept
}

pub fn detect_sleep_cycles(minutes: &[MinuteRr], onset: f64, wake: f64) -> SleepCyclesOut {
    let none = || SleepCyclesOut { cycles: vec![], mean_duration_min: None, n: 0, series: vec![] };
    let mut win: Vec<&MinuteRr> = minutes.iter().filter(|m| m.ts >= onset && m.ts <= wake).collect();
    win.sort_by(|a, b| a.ts.partial_cmp(&b.ts).unwrap());
    if win.len() < 60 {
        return none();
    }
    let raw: Vec<Option<f64>> = win.iter().map(|m| minute_rmssd(&m.rr)).collect();
    let sm: Vec<Option<f64>> = (0..raw.len())
        .map(|i| {
            let lo = (i as i64 - SMOOTH_MIN).max(0) as usize;
            let hi = ((i as i64 + SMOOTH_MIN) as usize).min(raw.len() - 1);
            let mut s = 0.0;
            let mut c = 0;
            for j in lo..=hi {
                if let Some(v) = raw[j] {
                    s += v;
                    c += 1;
                }
            }
            if c > 0 {
                Some(s / c as f64)
            } else {
                None
            }
        })
        .collect();
    let vals: Vec<f64> = sm.iter().filter_map(|x| *x).collect();
    if vals.len() < 60 {
        return none();
    }
    let mean = vals.iter().sum::<f64>() / vals.len() as f64;
    let sd = {
        let v = vals.iter().map(|b| (b - mean) * (b - mean)).sum::<f64>() / vals.len() as f64;
        let s = v.sqrt();
        if s == 0.0 {
            1.0
        } else {
            s
        }
    };
    let z: Vec<Option<f64>> = sm.iter().map(|x| x.map(|v| (v - mean) / sd)).collect();

    let peaks = find_peaks(&z, MIN_PEAK_DIST, MIN_PROMINENCE);
    let mut cycles: Vec<SleepCycle> = Vec::new();
    for i in 0..peaks.len().saturating_sub(1) {
        let start_ts = win[peaks[i]].ts;
        let end_ts = win[peaks[i + 1]].ts;
        cycles.push(SleepCycle { start_ts, end_ts, duration_min: ((end_ts - start_ts) / 60.0).round() as i64 });
    }
    let mean_duration_min = if !cycles.is_empty() {
        Some((cycles.iter().map(|c| c.duration_min).sum::<i64>() as f64 / cycles.len() as f64).round() as i64)
    } else {
        None
    };
    let series: Vec<ZPoint> = win
        .iter()
        .enumerate()
        .filter_map(|(i, m)| z[i].map(|zv| ZPoint { t: m.ts, z: (zv * 1000.0).round() / 1000.0 }))
        .collect();
    let n = cycles.len() as u32;
    SleepCyclesOut { cycles, mean_duration_min, n, series }
}
