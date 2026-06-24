// 1 Hz family — circadian HRV rhythm (cosinor over per-bucket RMSSD) + day/night
// RMSSD ratio. Refinetti/Cornélissen/Halberg 2007 Biol Rhythm Res 38:275 (cosinor).
// Our continuous 24/7 RR is the unlock — sleep-only products can't fit a 24-h HRV
// rhythm. HONESTY: PRV not ECG-HRV; relative; acrophase is UTC-clock display-only.
use crate::hrv::clean_rr;
use crate::types::MinuteRr;
use crate::util::round;
use serde::Serialize;
use std::collections::BTreeMap;

const DAY: f64 = 86400.0;

#[derive(Debug, Serialize)]
pub struct CircHrvOut {
    pub mesor: Option<f64>,           // rhythm midline (ms RMSSD)
    pub amplitude: Option<f64>,       // ms (half peak-trough); 0 = no rhythm
    pub acrophase_hour: Option<f64>,  // UTC hour-of-day of the RMSSD peak
    pub day_rmssd: Option<f64>,
    pub night_rmssd: Option<f64>,
    pub day_night_ratio: Option<f64>, // night/day (>1 = healthy nocturnal vagal rise)
    pub n_buckets: u32,
    pub confidence: f64,
    pub tier: String,
    pub label: String,
    pub inputs_used: Vec<String>,
}

/// 3×3 linear solve (Gaussian elimination, partial pivot). None if singular.
fn solve3(mut a: [[f64; 4]; 3]) -> Option<[f64; 3]> {
    for col in 0..3 {
        let mut piv = col;
        for r in (col + 1)..3 {
            if a[r][col].abs() > a[piv][col].abs() {
                piv = r;
            }
        }
        if a[piv][col].abs() < 1e-12 {
            return None;
        }
        a.swap(col, piv);
        let pv = a[col][col];
        for k in col..4 {
            a[col][k] /= pv;
        }
        for r in 0..3 {
            if r == col {
                continue;
            }
            let f = a[r][col];
            for k in col..4 {
                a[r][k] -= f * a[col][k];
            }
        }
    }
    Some([a[0][3], a[1][3], a[2][3]])
}

/// Least-squares cosinor over (t_sec, y): y ≈ M + b1·cos(ωt) + b2·sin(ωt), ω=2π/day.
/// Returns (mesor, amplitude, acrophase_sec_of_day). None if <4 points or singular.
pub(crate) fn fit_cosine(points: &[(f64, f64)]) -> Option<(f64, f64, f64)> {
    if points.len() < 4 {
        return None;
    }
    let w = 2.0 * std::f64::consts::PI / DAY;
    let mut a = [[0.0f64; 4]; 3];
    for &(t, y) in points {
        let c = (w * t).cos();
        let s = (w * t).sin();
        let row = [1.0, c, s];
        for r in 0..3 {
            a[r][3] += row[r] * y;
            for cc in 0..3 {
                a[r][cc] += row[r] * row[cc];
            }
        }
    }
    let sol = solve3(a)?;
    let (m, b1, b2) = (sol[0], sol[1], sol[2]);
    let amp = b1.hypot(b2);
    let phi = b2.atan2(b1); // peak at ωt = phi
    let mut peak = phi / w;
    peak = peak.rem_euclid(DAY);
    Some((m, amp, peak))
}

fn bucket_rmssd(rr: &[f64]) -> Option<f64> {
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

pub fn circadian_hrv(by_minute: &[MinuteRr], bucket_sec: f64, night_from: Option<f64>, night_to: Option<f64>) -> CircHrvOut {
    let none = CircHrvOut {
        mesor: None, amplitude: None, acrophase_hour: None, day_rmssd: None, night_rmssd: None,
        day_night_ratio: None, n_buckets: 0, confidence: 0.0, tier: "HIGH".to_string(),
        label: "Circadian HRV rhythm (PRV, relative)".to_string(),
        inputs_used: vec!["rr_intervals".to_string()],
    };
    let bsec = if bucket_sec > 0.0 { bucket_sec } else { 3600.0 };
    // pool RR by bucket
    let mut buckets: BTreeMap<i64, (f64, Vec<f64>)> = BTreeMap::new();
    let mut night_rr: Vec<f64> = Vec::new();
    let mut day_rr: Vec<f64> = Vec::new();
    for m in by_minute {
        if m.rr.is_empty() {
            continue;
        }
        let key = (m.ts / bsec).floor() as i64;
        let e = buckets.entry(key).or_insert_with(|| (key as f64 * bsec + bsec / 2.0, Vec::new()));
        e.1.extend(m.rr.iter().copied());
        if let (Some(nf), Some(nt)) = (night_from, night_to) {
            if m.ts >= nf && m.ts <= nt {
                night_rr.extend(m.rr.iter().copied());
            } else {
                day_rr.extend(m.rr.iter().copied());
            }
        }
    }
    let series: Vec<(f64, f64)> = buckets
        .values()
        .filter_map(|(ts, rr)| bucket_rmssd(rr).map(|r| (*ts, r)))
        .collect();
    let n = series.len();
    if n < 6 {
        return CircHrvOut { n_buckets: n as u32, ..none };
    }
    let fit = fit_cosine(&series);
    let (mesor, amp, acro_hour) = match fit {
        Some((m, a, peak)) => (Some(round(m, 1)), Some(round(a, 1)), Some(round(peak / 3600.0, 2))),
        None => (None, None, None),
    };
    let day_rmssd = bucket_rmssd(&day_rr).map(|r| round(r, 1));
    let night_rmssd = bucket_rmssd(&night_rr).map(|r| round(r, 1));
    let ratio = match (night_rmssd, day_rmssd) {
        (Some(nr), Some(dr)) if dr > 0.0 => Some(round(nr / dr, 3)),
        _ => None,
    };
    CircHrvOut {
        mesor,
        amplitude: amp,
        acrophase_hour: acro_hour,
        day_rmssd,
        night_rmssd,
        day_night_ratio: ratio,
        n_buckets: n as u32,
        confidence: round((n as f64 / 24.0).min(1.0), 3),
        tier: "HIGH".to_string(),
        label: "Circadian HRV rhythm (PRV, relative)".to_string(),
        inputs_used: vec!["rr_intervals".to_string()],
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cosine_kernel_recovers_planted_rhythm() {
        // y = 50 + 20·cos(ω(t − t_peak)), t_peak = 3 h, sampled hourly over 24 h.
        let w = 2.0 * std::f64::consts::PI / DAY;
        let t_peak = 3.0 * 3600.0;
        let pts: Vec<(f64, f64)> = (0..24)
            .map(|h| {
                let t = h as f64 * 3600.0;
                (t, 50.0 + 20.0 * (w * (t - t_peak)).cos())
            })
            .collect();
        let (m, a, peak) = fit_cosine(&pts).expect("fit");
        assert!((m - 50.0).abs() < 1e-6, "mesor {m}");
        assert!((a - 20.0).abs() < 1e-6, "amp {a}");
        assert!((peak / 3600.0 - 3.0).abs() < 0.05, "acrophase hour {}", peak / 3600.0);
    }

    #[test]
    fn wrapper_runs_and_ratio_sign() {
        // night buckets (ts 0..6h) high-variability RR, day buckets low → ratio>1.
        let mut mins: Vec<MinuteRr> = Vec::new();
        for m in 0..(24 * 60) {
            let ts = m as f64 * 60.0;
            let hour = (ts / 3600.0) as i64;
            let amp = if hour < 6 { 40.0 } else { 8.0 }; // night more variable
            let rr: Vec<f64> = (0..10).map(|k| 850.0 + if k % 2 == 0 { amp } else { -amp }).collect();
            mins.push(MinuteRr { ts, rr });
        }
        let out = circadian_hrv(&mins, 3600.0, Some(0.0), Some(6.0 * 3600.0));
        assert!(out.n_buckets >= 20);
        assert!(out.amplitude.unwrap() > 0.0);
        assert!(out.day_night_ratio.unwrap() > 1.0, "night should be more variable: {:?}", out.day_night_ratio);
    }
}
