// Port of openstrap-analytics/src/restlessness.ts — nocturnal movement fragmentation.
use crate::types::{Driver, MetricRef, Minute, RestlessnessOut};
use crate::util::{percentile, round};

pub fn calc_restlessness(sleep_minutes: &[Minute]) -> RestlessnessOut {
    let mut m: Vec<&Minute> = sleep_minutes.iter().filter(|x| x.wrist_on).collect();
    m.sort_by(|a, b| a.ts.partial_cmp(&b.ts).unwrap());
    let empty = || RestlessnessOut {
        score: None, restless_min: 0, movement_bouts: 0, mobility_pct: None, longest_still_min: 0,
        confidence: 0.0, tier: "ESTIMATE".to_string(), inputs_used: vec![], drivers: None,
    };
    if m.len() < 20 {
        return empty();
    }
    let acts: Vec<f64> = m.iter().map(|x| x.activity).collect();
    let p10 = percentile(&acts, 10.0).unwrap_or(0.0);
    let p90 = percentile(&acts, 90.0).unwrap_or(0.0);
    let thresh = p10 + 0.4 * (p90 - p10);

    let mut restless = 0u32;
    let mut bouts = 0u32;
    let mut longest_still = 0u32;
    let mut cur_still = 0u32;
    let mut moving = false;
    for x in &m {
        let is_move = x.activity > thresh && x.activity > 0.0;
        if is_move {
            restless += 1;
            if !moving {
                bouts += 1;
            }
            moving = true;
            if cur_still > longest_still {
                longest_still = cur_still;
            }
            cur_still = 0;
        } else {
            moving = false;
            cur_still += 1;
        }
    }
    if cur_still > longest_still {
        longest_still = cur_still;
    }

    let total = m.len();
    let mobility = restless as f64 / total as f64;
    let hours = 0.5f64.max(total as f64 / 60.0);
    let bouts_per_hour = bouts as f64 / hours;
    let score = (bouts_per_hour * 6.0 + mobility * 100.0 * 0.5).round().max(0.0).min(100.0);

    let drivers = vec![
        Driver {
            label: "Movement bouts".to_string(),
            contribution: bouts as f64,
            detail: Some(format!("{} shifts ({}/h)", bouts, round(bouts_per_hour, 1))),
            reference: Some(MetricRef { metric: "activity".to_string(), date: None, scale: Some("day".to_string()) }),
        },
        Driver {
            label: "Mobility".to_string(),
            contribution: round(mobility * 100.0, 1),
            detail: Some(format!("{}/{} min moving", restless, total)),
            reference: Some(MetricRef { metric: "activity".to_string(), date: None, scale: Some("day".to_string()) }),
        },
    ];
    RestlessnessOut {
        score: Some(score),
        restless_min: restless,
        movement_bouts: bouts,
        mobility_pct: Some(round(mobility, 4)),
        longest_still_min: longest_still,
        confidence: round(1f64.min(total as f64 / 240.0), 4),
        tier: "ESTIMATE".to_string(),
        inputs_used: vec!["activity".to_string()],
        drivers: Some(drivers),
    }
}
