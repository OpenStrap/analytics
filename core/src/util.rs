// Port of openstrap-analytics/src/util.ts (slice). Pure, no I/O.
use crate::types::{Baseline, Minute, Profile};

/// A worn minute usable for HR math: wrist on AND a real HR reading (>0).
pub fn is_hr_usable(m: &Minute) -> bool {
    m.wrist_on && m.hr_avg > 0.0
}

/// Linear-interpolated percentile (p in [0,100]). None if empty.
pub fn percentile(values: &[f64], p: f64) -> Option<f64> {
    if values.is_empty() {
        return None;
    }
    let mut sorted: Vec<f64> = values.to_vec();
    sorted.sort_by(|a, b| a.partial_cmp(b).unwrap());
    if sorted.len() == 1 {
        return Some(sorted[0]);
    }
    let rank = (p / 100.0) * (sorted.len() as f64 - 1.0);
    let lo = rank.floor() as usize;
    let hi = rank.ceil() as usize;
    if lo == hi {
        return Some(sorted[lo]);
    }
    let frac = rank - lo as f64;
    Some(sorted[lo] + (sorted[hi] - sorted[lo]) * frac)
}

pub fn median(values: &[f64]) -> Option<f64> {
    percentile(values, 50.0)
}

pub fn clamp(x: f64, lo: f64, hi: f64) -> f64 {
    lo.max(hi.min(x))
}

pub fn mean(values: &[f64]) -> f64 {
    if values.is_empty() {
        return 0.0;
    }
    values.iter().sum::<f64>() / values.len() as f64
}

pub fn stddev(values: &[f64]) -> f64 {
    if values.len() < 2 {
        return 0.0;
    }
    let m = mean(values);
    let v = values.iter().map(|b| (b - m) * (b - m)).sum::<f64>() / values.len() as f64;
    v.sqrt()
}

/// Least-squares slope of y vs x (x = 0..n-1 if None). 0 if <2 points. Mirrors linregSlope.
pub fn linreg_slope(y: &[f64]) -> f64 {
    let n = y.len();
    if n < 2 {
        return 0.0;
    }
    let xs: Vec<f64> = (0..n).map(|i| i as f64).collect();
    let mx = mean(&xs);
    let my = mean(y);
    let mut num = 0.0;
    let mut den = 0.0;
    for i in 0..n {
        num += (xs[i] - mx) * (y[i] - my);
        den += (xs[i] - mx) * (xs[i] - mx);
    }
    if den == 0.0 {
        0.0
    } else {
        num / den
    }
}

/// JS Math.round-compatible rounding to `decimals` places. JS rounds half-up;
/// for the non-negative values these metrics produce, f64::round (half-away)
/// matches. Kept identical to TS `round()`.
pub fn round(x: f64, decimals: i32) -> f64 {
    let f = 10f64.powi(decimals);
    (x * f).round() / f
}

// ── Civil-date helpers (Howard Hinnant's algorithm) — no chrono dependency. ──
/// Days since 1970-01-01 for a proleptic-Gregorian (y, m, d). Mirrors Date.parse(YYYY-MM-DD UTC)/86400000.
pub fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = (y - era * 400) as i64; // [0, 399]
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + d - 1; // [0, 365]
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy; // [0, 146096]
    era * 146097 + doe - 719468
}

/// Inverse of days_from_civil → "YYYY-MM-DD".
pub fn civil_from_days(z: i64) -> String {
    let z = z + 719468;
    let era = if z >= 0 { z } else { z - 146096 } / 146097;
    let doe = z - era * 146097; // [0, 146096]
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365; // [0, 399]
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // [0, 365]
    let mp = (5 * doy + 2) / 153; // [0, 11]
    let d = doy - (153 * mp + 2) / 5 + 1; // [1, 31]
    let m = if mp < 10 { mp + 3 } else { mp - 9 }; // [1, 12]
    let y = if m <= 2 { y + 1 } else { y };
    format!("{:04}-{:02}-{:02}", y, m, d)
}

/// Parse "YYYY-MM-DD" → days since epoch. None if malformed.
pub fn parse_day(s: &str) -> Option<i64> {
    let b = s.as_bytes();
    if b.len() != 10 || b[4] != b'-' || b[7] != b'-' {
        return None;
    }
    let y: i64 = s.get(0..4)?.parse().ok()?;
    let m: i64 = s.get(5..7)?.parse().ok()?;
    let d: i64 = s.get(8..10)?.parse().ok()?;
    if m < 1 || m > 12 || d < 1 || d > 31 {
        return None;
    }
    Some(days_from_civil(y, m, d))
}

/// Resolve max HR: measured session max if present, else Tanaka age max, with the
/// same fall-throughs as util.ts. Returns (max_hr, source) where source is
/// "measured" | "age".
pub fn resolve_max_hr(
    minutes: &[Minute],
    baseline_max_hr: f64,
    profile: Option<&Profile>,
) -> (f64, &'static str) {
    if baseline_max_hr > 0.0 {
        return (baseline_max_hr, "measured");
    }
    let observed = minutes
        .iter()
        .filter(|m| is_hr_usable(m))
        .fold(0.0_f64, |mx, m| mx.max(m.hr_max).max(m.hr_avg));

    if let Some(p) = profile {
        if let Some(age) = p.age {
            if age > 0.0 {
                let age_max = (208.0 - 0.7 * age).round();
                if observed > age_max {
                    return (observed, "measured");
                }
                return (age_max, "age");
            }
        }
    }
    if observed > 0.0 {
        return (observed, "age");
    }
    (190.0, "age")
}
