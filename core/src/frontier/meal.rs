// Frontier — 24/7 postprandial MEAL detection from the autonomic response to eating
// (HR↑ / HRV↓ transient, 30–90 min; Lu 2016; eating raises sympathetic tone). MOTION-GATED:
// only counts during low movement, else it just re-detects exercise (the catalog's #1 rule).
// A 24/7 meal-event detector no major wearable surfaces. ESTIMATE; per-user, no diet claims.
use crate::types::Minute;
use crate::util::{median, percentile, round};
use serde::Serialize;

#[derive(Debug, Serialize)]
pub struct MealEvent {
    pub ts: f64,
    pub hr_rise: f64,    // peak HR over the response minus the local resting baseline (bpm)
    pub duration_min: u32,
}

#[derive(Debug, Serialize)]
pub struct MealOut {
    pub events: Vec<MealEvent>,
    pub n_events: u32,
    pub confidence: f64,
    pub tier: String,
    pub label: String,
    pub inputs_used: Vec<String>,
}

pub fn detect_meals(minutes: &[Minute]) -> MealOut {
    let label = "meal/eating-response detection — autonomic, motion-gated".to_string();
    let mut worn: Vec<&Minute> = minutes.iter().filter(|m| m.wrist_on && m.hr_avg > 0.0).collect();
    worn.sort_by(|a, b| a.ts.partial_cmp(&b.ts).unwrap());
    if worn.len() < 30 {
        return MealOut { events: vec![], n_events: 0, confidence: 0.0, tier: "ESTIMATE".to_string(), label, inputs_used: vec![] };
    }
    // motion gate: a minute is "rest" only if its activity is in the low half of the day.
    let acts: Vec<f64> = worn.iter().map(|m| m.activity).collect();
    let rest_thr = percentile(&acts, 50.0).unwrap_or(0.0).max(0.05);
    let rest: Vec<bool> = worn.iter().map(|m| m.activity <= rest_thr).collect();

    const WIN: usize = 30;      // trailing-baseline window (min)
    const RISE_BPM: f64 = 7.0;  // sustained HR elevation over baseline
    const MIN_RUN: u32 = 10;    // ≥10 min sustained
    const MAX_RUN: u32 = 120;   // a single meal response, not a multi-hour drift

    let mut events: Vec<MealEvent> = Vec::new();
    let mut i = 0usize;
    while i < worn.len() {
        if !rest[i] {
            i += 1;
            continue;
        }
        // local resting baseline = median HR of the prior WIN rest-minutes.
        let lo = i.saturating_sub(WIN);
        let prior: Vec<f64> = (lo..i).filter(|&j| rest[j]).map(|j| worn[j].hr_avg).collect();
        let base = match median(&prior) {
            Some(b) if prior.len() >= 5 => b,
            _ => { i += 1; continue; }
        };
        if worn[i].hr_avg < base + RISE_BPM {
            i += 1;
            continue;
        }
        // grow the elevated, still-resting run.
        let mut j = i;
        let mut peak = worn[i].hr_avg;
        while j < worn.len() && rest[j] && worn[j].hr_avg >= base + RISE_BPM {
            peak = peak.max(worn[j].hr_avg);
            j += 1;
        }
        let run = (j - i) as u32;
        if (MIN_RUN..=MAX_RUN).contains(&run) {
            events.push(MealEvent { ts: worn[i].ts, hr_rise: round(peak - base, 1), duration_min: run });
        }
        i = j.max(i + 1);
    }

    let n = events.len() as u32;
    MealOut {
        events,
        n_events: n,
        confidence: round((worn.len() as f64 / 720.0).min(1.0), 3), // ~12 h of worn rest → full
        tier: "ESTIMATE".to_string(),
        label,
        inputs_used: vec!["hr_avg".to_string(), "activity".to_string()],
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn mk(ts: f64, hr: f64, act: f64) -> Minute {
        Minute { ts, hr_avg: hr, hr_min: hr, hr_max: hr, hr_n: 60.0, activity: act, steps: 0.0, wrist_on: true, act_class: None }
    }
    #[test]
    fn meal_bump_low_motion_detected() {
        let mut v = Vec::new();
        for i in 0..60 { v.push(mk(i as f64 * 60.0, 60.0, 0.01)); }      // resting baseline
        for i in 60..100 { v.push(mk(i as f64 * 60.0, 75.0, 0.01)); }    // 40-min meal response, flat motion
        let o = detect_meals(&v);
        assert_eq!(o.n_events, 1, "{:?}", o.events);
        assert!(o.events[0].hr_rise > 10.0);
    }
    #[test]
    fn same_bump_high_motion_gated_out() {
        let mut v = Vec::new();
        for i in 0..60 { v.push(mk(i as f64 * 60.0, 60.0, 0.01)); }
        for i in 60..100 { v.push(mk(i as f64 * 60.0, 75.0, 0.9)); }     // identical HR but MOVING → exercise
        let o = detect_meals(&v);
        assert_eq!(o.n_events, 0, "motion gate failed: {:?}", o.events);
    }
}
