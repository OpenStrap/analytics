// Port of openstrap-analytics/src/resting.ts — 5th-pctile sleep-window HR.
use crate::types::{Minute, RestingOut, SleepWindow};
use crate::util::{clamp, is_hr_usable, percentile, round};

pub fn calc_resting_hr(minutes: &[Minute], sleep_window: Option<&SleepWindow>) -> RestingOut {
    let has_window = matches!(
        sleep_window,
        Some(SleepWindow { onset_ts: Some(_), wake_ts: Some(_) })
    );

    if has_window {
        let sw = sleep_window.unwrap();
        let onset = sw.onset_ts.unwrap();
        let wake = sw.wake_ts.unwrap();
        let in_window: Vec<&Minute> = minutes
            .iter()
            .filter(|m| m.ts >= onset && m.ts <= wake && is_hr_usable(m))
            .collect();
        let hrs: Vec<f64> = in_window.iter().map(|m| m.hr_avg).collect();
        let rhr = percentile(&hrs, 5.0);
        let confidence = clamp(in_window.len() as f64 / 240.0, 0.0, 1.0);
        return RestingOut {
            resting_hr: rhr.map(|v| round(v, 1)),
            confidence: round(if rhr.is_none() { 0.0 } else { confidence }, 4),
            tier: "HIGH".to_string(),
            inputs_used: vec!["hr_avg".to_string(), "sleep_window".to_string()],
        };
    }

    // Fallback: lowest contiguous 30-min worn stretch of the day.
    match lowest_contiguous_stretch(minutes, 30) {
        None => RestingOut {
            resting_hr: None,
            confidence: 0.0,
            tier: "HIGH".to_string(),
            inputs_used: vec!["hr_avg".to_string()],
        },
        Some(hrs) => {
            let rhr = percentile(&hrs, 5.0);
            let confidence = 0.5_f64.min(clamp(hrs.len() as f64 / 30.0, 0.0, 1.0) * 0.5);
            RestingOut {
                resting_hr: rhr.map(|v| round(v, 1)),
                confidence: round(if rhr.is_none() { 0.0 } else { confidence }, 4),
                tier: "HIGH".to_string(),
                inputs_used: vec!["hr_avg".to_string(), "fallback_30min".to_string()],
            }
        }
    }
}

/// Lowest-mean stretch of `window_min` worn minutes that are adjacent in time
/// (≤90s apart). Mirrors lowestContiguousStretch in resting.ts.
fn lowest_contiguous_stretch(minutes: &[Minute], window_min: usize) -> Option<Vec<f64>> {
    let mut worn: Vec<&Minute> = minutes.iter().filter(|m| is_hr_usable(m)).collect();
    if worn.is_empty() {
        return None;
    }
    worn.sort_by(|a, b| a.ts.partial_cmp(&b.ts).unwrap());

    const MAX_GAP: f64 = 90.0;
    let mut best_mean = f64::INFINITY;
    let mut best_hrs: Option<Vec<f64>> = None;

    let mut run_start = 0usize;
    for i in 1..=worn.len() {
        let broken = i == worn.len() || worn[i].ts - worn[i - 1].ts > MAX_GAP;
        if !broken {
            continue;
        }
        let run = &worn[run_start..i];
        run_start = i;
        if run.len() < window_min {
            continue;
        }
        let mut window_sum: f64 = run[0..window_min].iter().map(|m| m.hr_avg).sum();
        let mut j = 0usize;
        while j + window_min <= run.len() {
            if j > 0 {
                window_sum += run[j + window_min - 1].hr_avg - run[j - 1].hr_avg;
            }
            let m = window_sum / window_min as f64;
            if m < best_mean {
                best_mean = m;
                best_hrs = Some(run[j..j + window_min].iter().map(|s| s.hr_avg).collect());
            }
            j += 1;
        }
    }

    if best_hrs.is_none() {
        let mut lowest: Vec<f64> = worn.iter().map(|m| m.hr_avg).collect();
        lowest.sort_by(|a, b| a.partial_cmp(b).unwrap());
        lowest.truncate(window_min.min(worn.len()));
        return Some(lowest);
    }
    best_hrs
}
