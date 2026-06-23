// Port of openstrap-analytics/src/wake.ts — sleep/wake ensemble for day-close.
use crate::types::{Baseline, Minute, WakeStateOut};
use crate::util::is_hr_usable;
use std::collections::{BTreeMap, HashMap};

const MIN: f64 = 60.0;
const MIN_MAIN_SLEEP_MIN: i64 = 90;
const SUSTAINED_WAKE_MIN: i64 = 10;
const CK_W: [f64; 7] = [106.0, 54.0, 58.0, 76.0, 230.0, 74.0, 67.0];
const CK_P: f64 = 0.001;

/// Averaged median (even → mean of two middles). Mirrors wake.ts `median`.
fn median(xs: &[f64]) -> f64 {
    if xs.is_empty() {
        return 0.0;
    }
    let mut s = xs.to_vec();
    s.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let m = s.len() >> 1;
    if s.len() % 2 == 1 {
        s[m]
    } else {
        (s[m - 1] + s[m]) / 2.0
    }
}

/// Upper-median (index len>>1) of finite values; NaN if none.
fn smoothed_median(seg: &[f64]) -> f64 {
    let mut v: Vec<f64> = seg.iter().copied().filter(|x| x.is_finite()).collect();
    if v.is_empty() {
        return f64::NAN;
    }
    v.sort_by(|a, b| a.partial_cmp(b).unwrap());
    v[v.len() >> 1]
}

fn cole_kripke(minutes: &[Minute]) -> Vec<String> {
    let act: Vec<f64> = minutes.iter().map(|m| if m.wrist_on { m.activity } else { 0.0 }).collect();
    let nz: Vec<f64> = act.iter().copied().filter(|&a| a > 0.0).collect();
    let scale = {
        let m = median(&nz);
        if m == 0.0 { 1.0 } else { m }
    };
    let n = minutes.len();
    (0..n)
        .map(|i| {
            if !is_hr_usable(&minutes[i]) && minutes[i].activity == 0.0 {
                return "unknown".to_string();
            }
            let mut d = 0.0;
            for k in -4i64..=2 {
                let j = i as i64 + k;
                if j < 0 || j >= n as i64 {
                    continue;
                }
                d += CK_W[(k + 4) as usize] * (act[j as usize] / scale);
            }
            d *= CK_P;
            if d < 1.0 { "asleep".to_string() } else { "awake".to_string() }
        })
        .collect()
}

fn trough_of(minutes: &[Minute], baseline: &Baseline) -> f64 {
    let mut usable: Vec<f64> = minutes.iter().filter(|m| is_hr_usable(m)).map(|m| m.hr_avg).collect();
    usable.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let p10 = if !usable.is_empty() { usable[(usable.len() as f64 * 0.1).floor() as usize] } else { baseline.resting_hr };
    let cand = baseline.resting_hr.max(0.0).max(if p10 > 0.0 { p10 } else { 0.0 });
    if cand != 0.0 {
        cand
    } else {
        *usable.first().unwrap_or(&0.0)
    }
}

fn cardiac(minutes: &[Minute], baseline: &Baseline) -> Vec<String> {
    let trough = trough_of(minutes, baseline);
    let wake_margin = 8.0;
    let hr: Vec<f64> = minutes.iter().map(|m| if is_hr_usable(m) { m.hr_avg } else { f64::NAN }).collect();
    let hs: Vec<f64> = (0..hr.len())
        .map(|i| {
            let lo = if i >= 2 { i - 2 } else { 0 };
            let hi = (i + 3).min(hr.len());
            smoothed_median(&hr[lo..hi])
        })
        .collect();
    (0..minutes.len())
        .map(|i| {
            if !hs[i].is_finite() {
                "unknown".to_string()
            } else if hs[i] > trough + wake_margin {
                "awake".to_string()
            } else {
                "asleep".to_string()
            }
        })
        .collect()
}

fn inactivity(minutes: &[Minute]) -> Vec<String> {
    let act: Vec<f64> = minutes.iter().map(|m| if m.wrist_on { m.activity } else { f64::NAN }).collect();
    let mut worn: Vec<f64> = act.iter().copied().filter(|a| a.is_finite()).collect();
    worn.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let pct = |p: f64| if !worn.is_empty() { worn[((worn.len() as f64 * p).floor() as usize).min(worn.len() - 1)] } else { 0.0 };
    let p10 = pct(0.1);
    let p90 = pct(0.9);
    const ABS_MOVE: f64 = 0.05;
    let thr = p10 + ABS_MOVE.max(0.3 * (p90 - p10));
    let ww = 5i64;
    let n = minutes.len() as i64;
    (0..minutes.len())
        .map(|i| {
            if !act[i].is_finite() {
                return "unknown".to_string();
            }
            let mut still = 0;
            let mut seen = 0;
            let lo = (i as i64 - ww).max(0);
            let hi = (i as i64 + ww).min(n - 1);
            for j in lo..=hi {
                if !act[j as usize].is_finite() {
                    continue;
                }
                seen += 1;
                if act[j as usize] <= thr {
                    still += 1;
                }
            }
            if seen == 0 {
                "unknown".to_string()
            } else if still as f64 / seen as f64 >= 0.7 {
                "asleep".to_string()
            } else {
                "awake".to_string()
            }
        })
        .collect()
}

fn hrv_arousal(minutes: &[Minute], baseline: &Baseline, rr_by_min: Option<&HashMap<i64, Vec<f64>>>) -> Vec<String> {
    let trough = trough_of(minutes, baseline);
    const RR_SD_WAKE: f64 = 45.0;
    let sd_raw: Vec<f64> = minutes
        .iter()
        .map(|m| {
            let key = (m.ts / MIN).floor() as i64 * MIN as i64;
            let rr = rr_by_min.and_then(|map| map.get(&key));
            match rr {
                Some(rr) if rr.len() >= 4 => {
                    let mean = rr.iter().sum::<f64>() / rr.len() as f64;
                    (rr.iter().map(|v| (v - mean).powi(2)).sum::<f64>() / rr.len() as f64).sqrt()
                }
                _ => f64::NAN,
            }
        })
        .collect();
    let sd: Vec<f64> = (0..sd_raw.len())
        .map(|i| {
            let lo = if i >= 2 { i - 2 } else { 0 };
            let hi = (i + 3).min(sd_raw.len());
            smoothed_median(&sd_raw[lo..hi])
        })
        .collect();
    (0..minutes.len())
        .map(|i| {
            let m = &minutes[i];
            if !sd[i].is_finite() || !is_hr_usable(m) {
                "unknown".to_string()
            } else if sd[i] > RR_SD_WAKE && m.hr_avg > trough {
                "awake".to_string()
            } else {
                "asleep".to_string()
            }
        })
        .collect()
}

fn consensus_per_minute(labels: &[Vec<String>], n: usize, min_awake: u32) -> Vec<String> {
    (0..n)
        .map(|i| {
            let mut awake = 0;
            let mut known = 0;
            for arr in labels {
                match arr[i].as_str() {
                    "awake" => {
                        awake += 1;
                        known += 1;
                    }
                    "asleep" => known += 1,
                    _ => {}
                }
            }
            if awake >= min_awake {
                "awake".to_string()
            } else if known > 0 {
                "asleep".to_string()
            } else {
                "unknown".to_string()
            }
        })
        .collect()
}

fn bout_smooth(labels: &[String], min_run: usize, passes: usize) -> Vec<String> {
    let mut s = labels.to_vec();
    for _ in 0..passes {
        let mut runs: Vec<(usize, usize)> = Vec::new();
        let mut i = 0;
        while i < s.len() {
            let mut j = i;
            while j < s.len() && s[j] == s[i] {
                j += 1;
            }
            runs.push((i, j - 1));
            i = j;
        }
        if runs.len() <= 1 {
            break;
        }
        let mut changed = false;
        for r in 0..runs.len() {
            let (a, b) = runs[r];
            if b - a + 1 >= min_run {
                continue;
            }
            let prev = if r > 0 { Some(runs[r - 1]) } else { None };
            let next = if r < runs.len() - 1 { Some(runs[r + 1]) } else { None };
            let tgt: Option<String> = match (prev, next) {
                (Some(p), Some(nx)) => Some(if (p.1 - p.0) >= (nx.1 - nx.0) { s[p.0].clone() } else { s[nx.0].clone() }),
                (Some(p), None) => Some(s[p.0].clone()),
                (None, Some(nx)) => Some(s[nx.0].clone()),
                (None, None) => None,
            };
            if let Some(t) = tgt {
                for x in a..=b {
                    s[x] = t.clone();
                }
                changed = true;
            }
        }
        if !changed {
            break;
        }
    }
    s
}

pub fn detect_wake_state(minutes: &[Minute], baseline: &Baseline, rr_by_min: Option<&HashMap<i64, Vec<f64>>>, now_opt: Option<f64>) -> WakeStateOut {
    let n = minutes.len();
    let _now = now_opt.unwrap_or(if n > 0 { minutes[n - 1].ts } else { 0.0 });
    let empty = || WakeStateOut {
        state: "unknown".to_string(), wake_ts: None, onset_ts: None, awake_min: 0, asleep_min: 0,
        votes: BTreeMap::new(), confidence: 0.0,
    };
    if (n as i64) < SUSTAINED_WAKE_MIN {
        return empty();
    }

    let voters: [(&str, Vec<String>); 4] = [
        ("coleKripke", cole_kripke(minutes)),
        ("cardiac", cardiac(minutes, baseline)),
        ("inactivity", inactivity(minutes)),
        ("hrvArousal", hrv_arousal(minutes, baseline, rr_by_min)),
    ];
    let per_voter: Vec<Vec<String>> = voters.iter().map(|(_, v)| v.clone()).collect();
    let labels = bout_smooth(&consensus_per_minute(&per_voter, n, 2), 10, 4);

    let mut votes: BTreeMap<String, String> = BTreeMap::new();
    for (k, (name, _)) in voters.iter().enumerate() {
        votes.insert(name.to_string(), per_voter[k].get(n - 1).cloned().unwrap_or_else(|| "unknown".to_string()));
    }

    let mut i: i64 = n as i64 - 1;
    let mut awake_run_start = n as i64;
    while i >= 0 && labels[i as usize] == "awake" {
        awake_run_start = i;
        i -= 1;
    }
    while i >= 0 && labels[i as usize] == "unknown" {
        i -= 1;
    }
    let sleep_end = i;
    while i >= 0 && labels[i as usize] != "awake" {
        i -= 1;
    }
    let sleep_start = i + 1;

    let sleep_bout_min = if sleep_end >= sleep_start && sleep_start >= 0 {
        ((minutes[sleep_end as usize].ts - minutes[sleep_start as usize].ts) / MIN).round() as i64 + 1
    } else {
        0
    };
    let awake_min = if awake_run_start < n as i64 {
        ((minutes[n - 1].ts - minutes[awake_run_start as usize].ts) / MIN).round() as i64 + 1
    } else {
        0
    };

    let known = labels.iter().filter(|l| l.as_str() != "unknown").count();
    let coverage = if n > 0 { known as f64 / n as f64 } else { 0.0 };
    let agree = {
        let mut acc = 0.0;
        let mut c = 0;
        for k in 0..n {
            let mut a = 0;
            let mut w = 0;
            for arr in &per_voter {
                match arr[k].as_str() {
                    "asleep" => a += 1,
                    "awake" => w += 1,
                    _ => {}
                }
            }
            let tot = a + w;
            if tot == 0 {
                continue;
            }
            acc += a.max(w) as f64 / tot as f64;
            c += 1;
        }
        if c > 0 { acc / c as f64 } else { 0.0 }
    };
    let confidence = (coverage * agree * 100.0).round() / 100.0;

    let current = labels[n - 1].clone();
    let just_woke = current == "awake" && awake_min >= SUSTAINED_WAKE_MIN && sleep_bout_min >= MIN_MAIN_SLEEP_MIN;

    WakeStateOut {
        state: current,
        wake_ts: if just_woke { Some(minutes[awake_run_start as usize].ts) } else { None },
        onset_ts: if just_woke && sleep_start >= 0 && sleep_start <= sleep_end { Some(minutes[sleep_start as usize].ts) } else { None },
        awake_min,
        asleep_min: sleep_bout_min,
        votes,
        confidence,
    }
}

pub fn peek_recent_state(recent: &[Minute], baseline: &Baseline) -> String {
    let worn: Vec<&Minute> = recent.iter().filter(|m| m.wrist_on).collect();
    if worn.len() < 3 {
        return "unknown".to_string();
    }
    let hr_up = worn.iter().filter(|m| is_hr_usable(m)).any(|m| m.hr_avg > baseline.resting_hr.max(0.0) + 6.0);
    let moving = worn.iter().any(|m| m.activity > 0.0 && m.steps > 0.0);
    if hr_up || moving { "awake".to_string() } else { "asleep".to_string() }
}
