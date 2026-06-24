// 1 Hz family — TRUE Sleep Regularity Index. Phillips et al. 2017 Sci Rep 7:3216
// (mortality-linked: UK Biobank eLife 2024). % probability of being in the same
// sleep/wake state at two timepoints 24 h apart.
//   SRI = -100 + (200/(M·(N-1)))·Σ_days Σ_epochs δ(s_{d,e}, s_{d+1,e})
// 30-s epochs, noon-to-noon day boundaries (GGIR convention). SUPERSEDES the
// circular-variance proxy in regularity.rs (kept as a secondary timing metric).
use crate::util::round;
use serde::Deserialize;
use serde::Serialize;
use std::collections::BTreeMap;

const NOON: f64 = 43200.0; // noon-to-noon offset (s)

#[derive(Debug, Clone, Deserialize)]
pub struct SriEpoch {
    pub ts: f64,       // unix seconds at epoch start
    pub asleep: bool,
}

#[derive(Debug, Serialize)]
pub struct SriOut {
    pub sri: Option<f64>,    // -100 (reversed) … 0 (random) … 100 (perfectly regular)
    pub days_used: u32,
    pub epoch_sec: u32,
    pub comparisons: u32,
    pub confidence: f64,
    pub tier: String,
    pub label: String,
    pub inputs_used: Vec<String>,
}

pub fn sleep_regularity_index(epochs: &[SriEpoch], epoch_sec: f64) -> SriOut {
    let es = if epoch_sec > 0.0 { epoch_sec } else { 30.0 };
    let none = |days: u32| SriOut {
        sri: None, days_used: days, epoch_sec: es as u32, comparisons: 0, confidence: 0.0,
        tier: "HIGH".to_string(),
        label: "Sleep Regularity Index (Phillips 2017)".to_string(),
        inputs_used: vec!["sleep_wake_epochs".to_string()],
    };
    // bin to (day, epoch-of-day) on a noon-to-noon grid; last write wins.
    let mut grid: BTreeMap<(i64, i64), bool> = BTreeMap::new();
    let mut days: std::collections::BTreeSet<i64> = std::collections::BTreeSet::new();
    for e in epochs {
        let shifted = e.ts - NOON;
        let day = (shifted / 86400.0).floor() as i64;
        let eod = ((shifted.rem_euclid(86400.0)) / es).floor() as i64;
        grid.insert((day, eod), e.asleep);
        days.insert(day);
    }
    let day_vec: Vec<i64> = days.iter().copied().collect();
    if day_vec.len() < 2 {
        return none(day_vec.len() as u32);
    }
    let mut agreements = 0u32;
    let mut comparisons = 0u32;
    for w in day_vec.windows(2) {
        let (d0, d1) = (w[0], w[1]);
        if d1 != d0 + 1 {
            continue; // only adjacent calendar days are 24 h apart
        }
        let epochs_per_day = (86400.0 / es) as i64;
        for eod in 0..epochs_per_day {
            if let (Some(&a), Some(&b)) = (grid.get(&(d0, eod)), grid.get(&(d1, eod))) {
                comparisons += 1;
                if a == b {
                    agreements += 1;
                }
            }
        }
    }
    if comparisons == 0 {
        return none(day_vec.len() as u32);
    }
    let sri = -100.0 + 200.0 * (agreements as f64 / comparisons as f64);
    SriOut {
        sri: Some(round(sri, 1)),
        days_used: day_vec.len() as u32,
        epoch_sec: es as u32,
        comparisons,
        confidence: round((day_vec.len() as f64 / 7.0).min(1.0), 3),
        tier: "HIGH".to_string(),
        label: "Sleep Regularity Index (Phillips 2017)".to_string(),
        inputs_used: vec!["sleep_wake_epochs".to_string()],
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // epoch-of-day asleep pattern: asleep between 23:00 and 07:00 (in clock seconds).
    fn night_state(clock_sec: f64) -> bool {
        let h = (clock_sec / 3600.0) % 24.0;
        h >= 23.0 || h < 7.0
    }

    fn gen(days: usize, es: f64, flip_by_day: bool) -> Vec<SriEpoch> {
        let mut out = Vec::new();
        let per_day = (86400.0 / es) as i64;
        for d in 0..days {
            for e in 0..per_day {
                // anchor each day's epochs at midnight of day d (so clock-of-day is stable)
                let ts = d as f64 * 86400.0 + e as f64 * es;
                let clock = (ts.rem_euclid(86400.0)) as f64;
                let mut s = night_state(clock);
                if flip_by_day && d % 2 == 1 {
                    s = !s;
                }
                out.push(SriEpoch { ts, asleep: s });
            }
        }
        out
    }

    #[test]
    fn identical_schedule_is_plus_100() {
        let out = sleep_regularity_index(&gen(4, 30.0, false), 30.0);
        assert!((out.sri.unwrap() - 100.0).abs() < 0.01, "SRI {:?}", out.sri);
        assert!(out.days_used >= 3);
    }

    #[test]
    fn fully_reversed_is_minus_100() {
        let out = sleep_regularity_index(&gen(4, 30.0, true), 30.0);
        assert!((out.sri.unwrap() + 100.0).abs() < 0.01, "SRI {:?}", out.sri);
    }

    #[test]
    fn one_day_is_null() {
        let out = sleep_regularity_index(&gen(1, 30.0, false), 30.0);
        assert!(out.sri.is_none());
    }
}
