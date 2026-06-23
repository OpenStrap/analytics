// Port of openstrap-analytics/src/arousal.ts — nocturnal sleep-stress / arousal.
use crate::types::{Baseline, Driver, MetricRef, Minute, SleepStressEvent, SleepStressOut};
use crate::util::{is_hr_usable, mean, round, stddev};

pub fn calc_sleep_stress(sleep_minutes: &[Minute], _baseline: &Baseline) -> SleepStressOut {
    let mut worn: Vec<&Minute> = sleep_minutes.iter().filter(|m| is_hr_usable(m)).collect();
    worn.sort_by(|a, b| a.ts.partial_cmp(&b.ts).unwrap());
    let empty = || SleepStressOut {
        score: None, arousal_events: 0, restless_min: 0, mean_sleeping_hr: None, events: vec![],
        confidence: 0.0, tier: "ESTIMATE".to_string(), inputs_used: vec![], drivers: None,
    };
    if worn.len() < 20 {
        return empty();
    }
    let hrs: Vec<f64> = worn.iter().map(|m| m.hr_avg).collect();
    let mean_hr = mean(&hrs);
    let sd_hr = stddev(&hrs);
    let acts: Vec<f64> = worn.iter().map(|m| m.activity).collect();
    let mean_act = mean(&acts);
    let surge_thresh = mean_hr + 8f64.max(1.5 * sd_hr);

    let mut arousal_events = 0u32;
    let mut restless = 0u32;
    let mut events: Vec<SleepStressEvent> = Vec::new();
    let mut in_surge = false;
    for m in &worn {
        let moving = m.activity > mean_act && m.activity > 0.0;
        if moving {
            restless += 1;
        }
        let surge = m.hr_avg >= surge_thresh && moving;
        if surge && !in_surge {
            arousal_events += 1;
            events.push(SleepStressEvent { ts: m.ts, kind: "arousal".to_string() });
            in_surge = true;
        } else if !surge {
            in_surge = false;
            if moving && m.activity > mean_act * 2.0 && events.len() < 60 {
                events.push(SleepStressEvent { ts: m.ts, kind: "restless".to_string() });
            }
        }
    }

    let hours = 0.5f64.max(worn.len() as f64 / 60.0);
    let events_per_hour = arousal_events as f64 / hours;
    let restless_frac = restless as f64 / worn.len() as f64;
    let score = (events_per_hour * 12.0 + restless_frac * 100.0 * 0.5).round().max(0.0).min(100.0);

    let drivers = vec![
        Driver {
            label: "Arousal events".to_string(),
            contribution: arousal_events as f64,
            detail: Some(format!("{} HR-surge+motion events", arousal_events)),
            reference: Some(MetricRef { metric: "hr".to_string(), date: None, scale: Some("day".to_string()) }),
        },
        Driver {
            label: "Restlessness".to_string(),
            contribution: round(restless_frac * 100.0, 1),
            detail: Some(format!("{} restless min", restless)),
            reference: Some(MetricRef { metric: "activity".to_string(), date: None, scale: Some("day".to_string()) }),
        },
    ];
    let confidence = 1f64.min(worn.len() as f64 / 240.0);
    SleepStressOut {
        score: Some(score),
        arousal_events,
        restless_min: restless,
        mean_sleeping_hr: Some(round(mean_hr, 0)),
        events,
        confidence: round(confidence, 4),
        tier: "ESTIMATE".to_string(),
        inputs_used: vec!["hr_avg".to_string(), "activity".to_string()],
        drivers: Some(drivers),
    }
}
