// Frontier — all-day passive ORTHOSTATIC / POTS battery. The 1 Hz gravity vector
// disambiguates a posture change (lie/sit→stand) from walking, so we can auto-detect
// supine→upright transitions 24/7 and read the HR response — hundreds of passive
// "active-stand tests" vs one clinic tilt. POTS screen = ΔHR ≥ 30 within 10 min upright
// (Plash 2013; active-stand is MORE specific than tilt). SCREEN only — we cannot measure
// BP, so we never assess orthostatic HYPOTENSION; wrist gravity = forearm orientation
// (context, not trunk-grade). ESTIMATE; diurnal (catalog: morning often the only positive).
use crate::util::round;
use serde::Serialize;

#[derive(Debug, Serialize)]
pub struct OrthoEvent {
    pub ts: f64,
    pub delta_hr: f64,    // sustained upright HR − pre-stand resting HR (bpm)
    pub pots_flag: bool,  // ΔHR ≥ 30 AND a stable (still) stand
}

#[derive(Debug, Serialize)]
pub struct OrthostaticOut {
    pub events: Vec<OrthoEvent>,
    pub n_stands: u32,
    pub n_pots_positive: u32,
    pub max_delta_hr: Option<f64>,
    pub confidence: f64,
    pub tier: String,
    pub label: String,
    pub inputs_used: Vec<String>,
}

fn angle_deg(a: (f64, f64, f64), b: (f64, f64, f64)) -> f64 {
    let na = (a.0 * a.0 + a.1 * a.1 + a.2 * a.2).sqrt();
    let nb = (b.0 * b.0 + b.1 * b.1 + b.2 * b.2).sqrt();
    if na <= 0.0 || nb <= 0.0 {
        return 0.0;
    }
    let c = ((a.0 * b.0 + a.1 * b.1 + a.2 * b.2) / (na * nb)).clamp(-1.0, 1.0);
    c.acos().to_degrees()
}

/// samples = (ts, gx, gy, gz, hr), ~1 Hz, time-ordered.
pub fn orthostatic(samples: &[(f64, f64, f64, f64, f64)]) -> OrthostaticOut {
    let label = "orthostatic/POTS screen (active-stand ΔHR) — not a diagnosis; no BP".to_string();
    let n = samples.len();
    let g = |i: usize| (samples[i].1, samples[i].2, samples[i].3);
    let ts = |i: usize| samples[i].0;
    let hr = |i: usize| samples[i].4;
    let mean_hr = |lo: f64, hi: f64| -> Option<f64> {
        let v: Vec<f64> = samples.iter().filter(|s| s.0 >= lo && s.0 < hi && s.4 > 0.0).map(|s| s.4).collect();
        if v.is_empty() { None } else { Some(v.iter().sum::<f64>() / v.len() as f64) }
    };
    if n < 120 {
        return OrthostaticOut {
            events: vec![], n_stands: 0, n_pots_positive: 0, max_delta_hr: None,
            confidence: 0.0, tier: "ESTIMATE".to_string(), label, inputs_used: vec![],
        };
    }
    let mut events: Vec<OrthoEvent> = Vec::new();
    let mut last_event_ts = f64::NEG_INFINITY;
    for i in 0..n {
        if ts(i) - last_event_ts < 120.0 {
            continue; // debounce: ≥2 min between stands
        }
        // gravity ~25 s earlier
        let mut j = i;
        while j > 0 && ts(i) - ts(j) < 25.0 {
            j -= 1;
        }
        if j == i || angle_deg(g(i), g(j)) < 40.0 {
            continue; // not a posture change
        }
        let pre = match mean_hr(ts(i) - 60.0, ts(i)) {
            Some(v) => v,
            None => continue,
        };
        // sustained upright HR = highest 30 s-rolling mean within 10 min after the change.
        let mut post_best: f64 = 0.0;
        let mut t = ts(i);
        while t < ts(i) + 600.0 {
            if let Some(m) = mean_hr(t, t + 30.0) {
                post_best = post_best.max(m);
            }
            t += 15.0;
        }
        // stand stability: gravity direction stays put after the change (still, not walking).
        let post_dirs: Vec<(f64, f64, f64)> = samples.iter().filter(|s| s.0 >= ts(i) && s.0 < ts(i) + 120.0).map(|s| (s.1, s.2, s.3)).collect();
        let stable = post_dirs.len() >= 2 && post_dirs.iter().all(|&d| angle_deg(d, g(i)) < 25.0);
        let delta = post_best - pre;
        if post_best <= 0.0 {
            continue;
        }
        let pots = delta >= 30.0 && stable;
        events.push(OrthoEvent { ts: ts(i), delta_hr: round(delta, 1), pots_flag: pots });
        last_event_ts = ts(i);
    }
    let n_pos = events.iter().filter(|e| e.pots_flag).count() as u32;
    let max_d = events.iter().map(|e| e.delta_hr).fold(f64::NEG_INFINITY, f64::max);
    let n_stands = events.len() as u32;
    OrthostaticOut {
        events,
        n_stands,
        n_pots_positive: n_pos,
        max_delta_hr: if n_stands > 0 { Some(round(max_d, 1)) } else { None },
        confidence: round((n_stands as f64 / 5.0).min(1.0), 3),
        tier: "ESTIMATE".to_string(),
        label,
        inputs_used: vec!["accel_gravity".to_string(), "hr_avg".to_string()],
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    // build 1 Hz samples: supine (g=(0,0,1)) then upright (g=(0,1,0)) with an HR ramp.
    fn build(stand_hr: f64) -> Vec<(f64, f64, f64, f64, f64)> {
        let mut v = Vec::new();
        for s in 0..120 { v.push((s as f64, 0.0, 0.0, 1.0, 66.0)); }       // 2 min supine, HR 66
        for s in 120..720 {                                                 // 10 min upright
            let t = s as f64;
            let ramp = ((t - 120.0) / 30.0).min(1.0);                       // 30 s ramp to target
            v.push((t, 0.0, 1.0, 0.0, 66.0 + (stand_hr - 66.0) * ramp));
        }
        v
    }
    #[test]
    fn pots_positive_on_big_delta() {
        let o = orthostatic(&build(100.0)); // ΔHR ≈ 34
        assert_eq!(o.n_stands, 1, "{:?}", o.events);
        assert!(o.events[0].delta_hr >= 30.0, "{:?}", o.events[0]);
        assert_eq!(o.n_pots_positive, 1);
    }
    #[test]
    fn normal_stand_not_flagged() {
        let o = orthostatic(&build(78.0)); // ΔHR ≈ 12
        assert_eq!(o.n_stands, 1);
        assert_eq!(o.n_pots_positive, 0, "{:?}", o.events);
    }
}
