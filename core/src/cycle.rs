// Port of openstrap-analytics/src/cycle.ts — log-anchored menstrual cycle estimate.
use crate::types::CycleOut;
use crate::util::{civil_from_days, median, parse_day};
use std::collections::BTreeSet;

const DEFAULT_LEN: i64 = 28;
const LUTEAL: i64 = 14;
const MENSES: i64 = 5;

pub fn calc_cycle(starts_raw: &[String], today: &str) -> CycleOut {
    let empty = |note: &str| CycleOut {
        cycle_day: None, phase: "unknown".to_string(), mean_length: None, length_history: vec![],
        last_start: None, predicted_next: None, days_until_next: None, ovulation_est: None,
        fertile_start: None, fertile_end: None, note: note.to_string(),
        confidence: 0.0, tier: "ESTIMATE".to_string(), inputs_used: vec!["period_log".to_string()],
    };
    let today_day = match parse_day(today) {
        Some(d) => d,
        None => return empty("Log a period to start tracking your cycle."),
    };

    // dedupe + valid format + <= today, sorted ascending (by day).
    let mut set: BTreeSet<i64> = BTreeSet::new();
    for s in starts_raw {
        if let Some(d) = parse_day(s) {
            if d <= today_day {
                set.insert(d);
            }
        }
    }
    let starts: Vec<i64> = set.into_iter().collect();
    if starts.is_empty() {
        return empty("Log a period to start tracking your cycle.");
    }

    let mut lengths: Vec<i64> = Vec::new();
    for i in 1..starts.len() {
        let len = starts[i] - starts[i - 1];
        if (15..=60).contains(&len) {
            lengths.push(len);
        }
    }
    let med = if !lengths.is_empty() {
        median(&lengths.iter().map(|&x| x as f64).collect::<Vec<_>>())
    } else {
        None
    };
    let mean_len = med.map(|m| m.round() as i64);
    let use_len = mean_len.unwrap_or(DEFAULT_LEN);

    let last = *starts.last().unwrap();
    let cycle_day = (today_day - last) + 1;
    let next_day = last + use_len;
    let ov_day = next_day - LUTEAL;
    let fertile_start_day = ov_day - 5;
    let fertile_end_day = ov_day + 1;
    let days_until = next_day - today_day;

    let mut phase = if cycle_day <= MENSES {
        "menstruation"
    } else if today_day >= fertile_start_day && today_day <= fertile_end_day {
        "ovulation"
    } else if today_day < ov_day {
        "follicular"
    } else {
        "luteal"
    };

    let mut conf = if lengths.is_empty() {
        0.3
    } else {
        0.9f64.min(0.4 + 0.15 * lengths.len() as f64)
    };
    if cycle_day as f64 > use_len as f64 * 1.6 {
        phase = "unknown";
        conf = conf.min(0.2);
    }

    let note = if lengths.is_empty() {
        "Based on one logged period and a 28-day default — accuracy improves as you log more.".to_string()
    } else {
        format!("Based on {} logged periods (median {}-day cycle).", lengths.len() + 1, use_len)
    };

    CycleOut {
        cycle_day: Some(cycle_day),
        phase: phase.to_string(),
        mean_length: mean_len,
        length_history: lengths,
        last_start: Some(civil_from_days(last)),
        predicted_next: Some(civil_from_days(next_day)),
        days_until_next: Some(days_until),
        ovulation_est: Some(civil_from_days(ov_day)),
        fertile_start: Some(civil_from_days(fertile_start_day)),
        fertile_end: Some(civil_from_days(fertile_end_day)),
        note,
        confidence: conf,
        tier: "ESTIMATE".to_string(),
        inputs_used: vec!["period_log".to_string()],
    }
}
