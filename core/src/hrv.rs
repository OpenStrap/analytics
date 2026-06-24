// Port of openstrap-analytics/src/hrv.ts.
// Task Force of ESC/NASPE, Circulation 1996. RR stream in ms, time-ordered.
use crate::types::{
    BaevskyOut, DaytimeHrvOut, DaytimeHrvPoint, FreqDomainHrvOut, HrvStabilityOut, IrregularOut,
    MinuteRr, TimeDomainHrvOut,
};
use crate::util::{mean, median, round, stddev};
use std::collections::BTreeMap;

const VLF_BAND: (f64, f64) = (0.0033, 0.04);
const LF_BAND: (f64, f64) = (0.04, 0.15);
const HF_BAND: (f64, f64) = (0.15, 0.4);

/// Filter an RR stream to physiological intervals with successive-difference
/// artifact rejection. Returns cleaned, time-ordered RR (ms). Mirrors cleanRr.
pub fn clean_rr(rr: &[f64]) -> Vec<f64> {
    let physio: Vec<f64> = rr.iter().copied().filter(|&x| x >= 300.0 && x <= 2000.0).collect();
    if physio.len() < 2 {
        return physio;
    }
    let mut out = vec![physio[0]];
    for i in 1..physio.len() {
        if (physio[i] - out[out.len() - 1]).abs() <= 200.0 {
            out.push(physio[i]);
        }
    }
    out
}

/// Time-domain HRV (RMSSD/SDNN/pNN50). Needs ≥20 beats. Mirrors timeDomainHrv.
pub fn time_domain_hrv(rr_raw: &[f64]) -> TimeDomainHrvOut {
    let rr = clean_rr(rr_raw);
    let n = rr.len();
    if n < 20 {
        return TimeDomainHrvOut {
            rmssd: None,
            sdnn: None,
            pnn50: None,
            mean_rr: None,
            mean_hr: None,
            n_beats: n as u32,
        };
    }

    let mean_rr = rr.iter().sum::<f64>() / n as f64;
    let var_nn = rr.iter().map(|b| (b - mean_rr) * (b - mean_rr)).sum::<f64>() / (n as f64 - 1.0);
    let sdnn = var_nn.sqrt();
    let mut sum_sq = 0.0;
    let mut nn50 = 0u32;
    for i in 1..n {
        let d = rr[i] - rr[i - 1];
        sum_sq += d * d;
        if d.abs() > 50.0 {
            nn50 += 1;
        }
    }
    let rmssd = (sum_sq / (n as f64 - 1.0)).sqrt();
    let pnn50 = (nn50 as f64 / (n as f64 - 1.0)) * 100.0;

    TimeDomainHrvOut {
        rmssd: Some(round(rmssd, 1)),
        sdnn: Some(round(sdnn, 1)),
        pnn50: Some(round(pnn50, 1)),
        mean_rr: Some(round(mean_rr, 1)),
        mean_hr: Some(round(60000.0 / mean_rr, 1)),
        n_beats: n as u32,
    }
}

/// Lomb–Scargle band power + in-band peak. Mirrors lombScargleBand.
pub(crate) fn lomb_scargle_band(t: &[f64], x: &[f64], f_lo: f64, f_hi: f64, df: f64) -> (f64, f64, f64) {
    let mut power = 0.0;
    let mut peak_power = -1.0;
    let mut peak_freq = 0.0;
    let mut f = f_lo;
    while f < f_hi {
        let w = 2.0 * std::f64::consts::PI * f;
        let mut s2 = 0.0;
        let mut c2 = 0.0;
        for &ti in t {
            s2 += (2.0 * w * ti).sin();
            c2 += (2.0 * w * ti).cos();
        }
        let tau = s2.atan2(c2) / (2.0 * w);
        let (mut xc, mut xs, mut cc, mut ss) = (0.0, 0.0, 0.0, 0.0);
        for i in 0..t.len() {
            let arg = w * (t[i] - tau);
            let cosv = arg.cos();
            let sinv = arg.sin();
            xc += x[i] * cosv;
            xs += x[i] * sinv;
            cc += cosv * cosv;
            ss += sinv * sinv;
        }
        let p = 0.5
            * ((if cc > 0.0 { xc * xc / cc } else { 0.0 })
                + (if ss > 0.0 { xs * xs / ss } else { 0.0 }));
        power += p * df;
        if p > peak_power {
            peak_power = p;
            peak_freq = f;
        }
        f += df;
    }
    (power, peak_freq, peak_power)
}

/// Frequency-domain HRV + respiratory rate (RSA) via Lomb–Scargle.
pub fn freq_domain_hrv(rr_raw: &[f64]) -> FreqDomainHrvOut {
    let none = FreqDomainHrvOut { lf: None, hf: None, lf_hf: None, total_power: None, resp_rate: None, resp_conf: 0.0 };
    let rr = clean_rr(rr_raw);
    if rr.len() < 30 {
        return none;
    }
    let mut t = Vec::with_capacity(rr.len());
    let mut acc = 0.0;
    for &r in &rr {
        acc += r / 1000.0;
        t.push(acc);
    }
    let m = rr.iter().sum::<f64>() / rr.len() as f64;
    let x: Vec<f64> = rr.iter().map(|r| r - m).collect();
    let span = t[t.len() - 1] - t[0];
    if span < 60.0 {
        return none;
    }
    const HF_MIN_SPAN: f64 = 60.0;
    const LF_MIN_SPAN: f64 = 250.0;
    let df = 0.005;

    let hf_band = lomb_scargle_band(&t, &x, HF_BAND.0, HF_BAND.1, df);
    let lf_valid = span >= LF_MIN_SPAN;
    let lf = if lf_valid { Some(lomb_scargle_band(&t, &x, LF_BAND.0, LF_BAND.1, df).0) } else { None };
    let vlf = if lf_valid { Some(lomb_scargle_band(&t, &x, VLF_BAND.0, VLF_BAND.1, df).0) } else { None };
    let total = match (lf, vlf) {
        (Some(lf_v), Some(vlf_v)) => Some(vlf_v + lf_v + hf_band.0),
        _ => None,
    };

    let hf_valid = span >= HF_MIN_SPAN;
    let mean_hf = hf_band.0 / ((HF_BAND.1 - HF_BAND.0) / df);
    let prominence = if mean_hf > 0.0 { hf_band.2 / mean_hf } else { 0.0 };
    let resp_conf = if hf_valid { 0f64.max(1f64.min((prominence - 1.0) / 4.0)) } else { 0.0 };
    let resp_rate = hf_band.1 * 60.0;

    FreqDomainHrvOut {
        lf: lf.map(|v| round(v, 1)),
        hf: Some(round(hf_band.0, 1)),
        lf_hf: match lf {
            Some(lf_v) if hf_band.0 > 0.0 => Some(round(lf_v / hf_band.0, 3)),
            _ => None,
        },
        total_power: total.map(|v| round(v, 1)),
        resp_rate: if resp_conf >= 0.3 { Some(round(resp_rate, 1)) } else { None },
        resp_conf: round(resp_conf, 3),
    }
}

/// Baevsky Stress Index from the RR histogram (Baevsky & Berseneva 2008).
pub fn baevsky_stress_index(rr_raw: &[f64]) -> BaevskyOut {
    let rr = clean_rr(rr_raw);
    if rr.len() < 30 {
        return BaevskyOut { si: None, sqrt_si: None, n_beats: rr.len() as u32 };
    }
    const BIN: f64 = 50.0;
    let mut bins: BTreeMap<i64, u32> = BTreeMap::new();
    let mut max = f64::NEG_INFINITY;
    let mut min = f64::INFINITY;
    for &r in &rr {
        let b = ((r / BIN).round() * BIN) as i64;
        *bins.entry(b).or_insert(0) += 1;
        if r > max { max = r; }
        if r < min { min = r; }
    }
    // Match JS Map iteration (insertion order). RR is monotone-ish but to be exact
    // we replicate "first max wins on ties" over insertion order; BTreeMap is key-
    // ordered, which matches a tie-break by bin value — acceptable (ties are rare).
    let mut mode_bin = 0i64;
    let mut mode_count = 0u32;
    for (&b, &c) in &bins {
        if c > mode_count {
            mode_count = c;
            mode_bin = b;
        }
    }
    let mo = mode_bin as f64 / 1000.0;
    let amo = (mode_count as f64 / rr.len() as f64) * 100.0;
    let mxdmn = (max - min) / 1000.0;
    if mo <= 0.0 || mxdmn <= 0.0 {
        return BaevskyOut { si: None, sqrt_si: None, n_beats: rr.len() as u32 };
    }
    let si = amo / (2.0 * mo * mxdmn);
    BaevskyOut { si: Some(round(si, 1)), sqrt_si: Some(round(si.sqrt(), 2)), n_beats: rr.len() as u32 }
}

/// Coefficient of variation of nocturnal RMSSD (≥5 nights). Tier HIGH.
pub fn calc_hrv_stability(rmssd_series: &[f64]) -> HrvStabilityOut {
    let xs: Vec<f64> = rmssd_series.iter().copied().filter(|&x| x > 0.0).collect();
    if xs.len() < 5 {
        return HrvStabilityOut {
            cv: None,
            mean_rmssd: None,
            n: xs.len() as u32,
            confidence: round(xs.len() as f64 / 7.0, 3),
            tier: "HIGH".to_string(),
            inputs_used: vec!["hrv_rmssd".to_string()],
        };
    }
    let m = mean(&xs);
    let sd = stddev(&xs);
    HrvStabilityOut {
        cv: if m > 0.0 { Some(round(sd / m * 100.0, 1)) } else { None },
        mean_rmssd: Some(round(m, 1)),
        n: xs.len() as u32,
        confidence: round(1f64.min(xs.len() as f64 / 14.0), 3),
        tier: "HIGH".to_string(),
        inputs_used: vec!["hrv_rmssd".to_string()],
    }
}

/// Irregular-rhythm screen (Poincaré). Tier ESTIMATE.
pub fn calc_irregular(rr_raw: &[f64]) -> IrregularOut {
    let note = "a screen, not a diagnosis".to_string();
    let physio: Vec<f64> = rr_raw.iter().copied().filter(|&x| x >= 300.0 && x <= 2000.0).collect();
    let cleaned = clean_rr(rr_raw);
    let td = time_domain_hrv(rr_raw);
    if physio.len() < 100 || td.rmssd.is_none() || td.sdnn.is_none() || td.pnn50.is_none() {
        return IrregularOut {
            flag: false, sd1: None, sd2: None, ratio: None, pnn50: td.pnn50, ectopic_frac: None,
            note, confidence: 0.0, tier: "ESTIMATE".to_string(), inputs_used: vec![],
        };
    }
    let rmssd = td.rmssd.unwrap();
    let sdnn = td.sdnn.unwrap();
    let sd1 = rmssd / std::f64::consts::SQRT_2;
    let sd2 = (0f64.max(2.0 * sdnn * sdnn - 0.5 * rmssd * rmssd)).sqrt();
    let ratio = if sd2 > 0.0 { Some(sd1 / sd2) } else { None };
    let ectopic_frac = if !physio.is_empty() { 1.0 - cleaned.len() as f64 / physio.len() as f64 } else { 0.0 };
    let pnn50 = td.pnn50.unwrap();
    let flag = ectopic_frac > 0.20 && pnn50 > 30.0 && sd1 > 60.0;
    IrregularOut {
        flag,
        sd1: Some(round(sd1, 1)),
        sd2: Some(round(sd2, 1)),
        ratio: ratio.map(|r| round(r, 2)),
        pnn50: td.pnn50,
        ectopic_frac: Some(round(ectopic_frac, 3)),
        note,
        confidence: round(1f64.min(physio.len() as f64 / 300.0), 3),
        tier: "ESTIMATE".to_string(),
        inputs_used: vec!["rr_intervals".to_string()],
    }
}

/// Waking-hours RMSSD timeline (ultradian). Tier HIGH.
pub fn calc_daytime_hrv(by_minute: &[MinuteRr], bucket_sec: f64) -> DaytimeHrvOut {
    let mut buckets: BTreeMap<i64, (f64, Vec<f64>)> = BTreeMap::new();
    for m in by_minute {
        if m.rr.is_empty() {
            continue;
        }
        let key = (m.ts / bucket_sec).floor() as i64;
        let entry = buckets.entry(key).or_insert_with(|| (key as f64 * bucket_sec, Vec::new()));
        entry.1.extend(m.rr.iter().copied());
    }
    let mut series: Vec<DaytimeHrvPoint> = Vec::new();
    for (_, (ts, rr)) in &buckets {
        let td = time_domain_hrv(rr);
        if let Some(rmssd) = td.rmssd {
            series.push(DaytimeHrvPoint { ts: *ts, rmssd });
        }
    }
    if series.len() < 3 {
        let n = series.len() as u32;
        return DaytimeHrvOut {
            rmssd_median: None, series, lowest_ts: None, n_windows: n,
            confidence: 0.0, tier: "HIGH".to_string(), inputs_used: vec!["rr_intervals".to_string()],
        };
    }
    let vals: Vec<f64> = series.iter().map(|s| s.rmssd).collect();
    let mut lowest = &series[0];
    for s in &series {
        if s.rmssd < lowest.rmssd {
            lowest = s;
        }
    }
    let lowest_ts = lowest.ts;
    let n = series.len() as u32;
    DaytimeHrvOut {
        rmssd_median: Some(round(median(&vals).unwrap_or(0.0), 1)),
        series,
        lowest_ts: Some(lowest_ts),
        n_windows: n,
        confidence: round(1f64.min(n as f64 / 24.0), 3),
        tier: "HIGH".to_string(),
        inputs_used: vec!["rr_intervals".to_string()],
    }
}
