// Port of openstrap-analytics/src/har.ts — Mannini 2013 wrist HAR (LIVE high-rate only).
use crate::util::{mean, stddev};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize)]
pub struct HarFeatures {
    pub smv_mean: f64,
    pub smv_std: f64,
    pub smv_min: f64,
    pub smv_max: f64,
    pub total_power: f64,
    pub dom1_freq: f64,
    pub dom1_pow: f64,
    pub dom2_freq: f64,
    pub dom2_pow: f64,
    pub cad_freq: f64,
    pub cad_pow: f64,
    pub dom1_ratio: f64,
    pub freq_ratio_prev: f64,
    pub wav_e5: f64,
    pub wav_e6: f64,
}

pub const DB10_LO: [f64; 20] = [
    2.667005790055555358661744877130858277192498290851289932779975e-02,
    1.881768000776914890208929736790939942702546758640393484348595e-01,
    5.272011889317255864817448279595081924981402680840223445318549e-01,
    6.884590394536035657418717825492358539771364042407339537279681e-01,
    2.811723436605774607487269984455892876243888859026150413831543e-01,
    -2.498464243273153794161018979207791000564669737132073715013121e-01,
    -1.959462743773770435042992543190981318766776476382778474396781e-01,
    1.273693403357932600826772332014009770786177480422245995563097e-01,
    9.305736460357235116035228983545273226942917998946925868063974e-02,
    -7.139414716639708714533609307605064767292611983702150917523756e-02,
    -2.945753682187581285828323760141839199388200516064948779769654e-02,
    3.321267405934100173976365318215912897978337413267096043323351e-02,
    3.606553566956169655423291417133403299517350518618994762730612e-03,
    -1.073317548333057504431811410651364448111548781143923213370333e-02,
    1.395351747052901165789318447957707567660542855688552426721117e-03,
    1.992405295185056117158742242640643211762555365514105280067936e-03,
    -6.858566949597116265613709819265714196625043336786920516211903e-04,
    -1.164668551292854509514809710258991891527461854347597362819235e-04,
    9.358867032006959133405013034222854399688456215297276443521873e-05,
    -1.326420289452124481243667531226683305749240960605829756400674e-05,
];

fn db10_hi() -> Vec<f64> {
    let n = DB10_LO.len();
    (0..n).map(|k| (if k % 2 == 0 { 1.0 } else { -1.0 }) * DB10_LO[n - 1 - k]).collect()
}

fn dwt_step(sig: &[f64], lo: &[f64], hi: &[f64]) -> (Vec<f64>, Vec<f64>) {
    let n = sig.len();
    let l = lo.len();
    let half = n / 2;
    let mut a = vec![0.0; half];
    let mut d = vec![0.0; half];
    for i in 0..half {
        let mut sa = 0.0;
        let mut sd = 0.0;
        for k in 0..l {
            let idx = (2 * i + k) % n;
            sa += lo[k] * sig[idx];
            sd += hi[k] * sig[idx];
        }
        a[i] = sa;
        d[i] = sd;
    }
    (a, d)
}

pub fn dwt_detail_energies(signal: &[f64], levels: usize) -> Vec<f64> {
    let hi = db10_hi();
    let lo = DB10_LO.to_vec();
    let mut a = signal.to_vec();
    let mut out = Vec::new();
    for _ in 1..=levels {
        if a.len() < 2 {
            out.push(0.0);
            continue;
        }
        let (na, d) = dwt_step(&a, &lo, &hi);
        out.push(d.iter().map(|v| v * v).sum());
        a = na;
    }
    out
}

fn biquad_lp(sig: &[f64], fs: f64, fc: f64, q: f64) -> Vec<f64> {
    let w0 = (2.0 * std::f64::consts::PI * fc) / fs;
    let cosw = w0.cos();
    let sinw = w0.sin();
    let alpha = sinw / (2.0 * q);
    let a0 = 1.0 + alpha;
    let b0 = ((1.0 - cosw) / 2.0) / a0;
    let b1 = (1.0 - cosw) / a0;
    let b2 = ((1.0 - cosw) / 2.0) / a0;
    let a1 = (-2.0 * cosw) / a0;
    let a2 = (1.0 - alpha) / a0;
    let mut out = vec![0.0; sig.len()];
    let s0 = if !sig.is_empty() { sig[0] } else { 0.0 };
    let (mut x1, mut x2, mut y1, mut y2) = (s0, s0, s0, s0);
    for i in 0..sig.len() {
        let x0 = sig[i];
        let y0 = b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2;
        x2 = x1;
        x1 = x0;
        y2 = y1;
        y1 = y0;
        out[i] = y0;
    }
    out
}

fn butter_lp4(sig: &[f64], fs: f64, fc: f64) -> Vec<f64> {
    biquad_lp(&biquad_lp(sig, fs, fc, 0.54119610), fs, fc, 1.30656296)
}

fn next_pow2(n: usize) -> usize {
    let mut p = 1;
    while p < n {
        p <<= 1;
    }
    p
}

fn power_spectrum(sig: &[f64]) -> Vec<f64> {
    let nn = next_pow2(sig.len());
    let mut re = vec![0.0; nn];
    let mut im = vec![0.0; nn];
    for i in 0..sig.len() {
        re[i] = sig[i];
    }
    // bit-reversal permutation
    let mut j = 0usize;
    for i in 1..nn {
        let mut bit = nn >> 1;
        while j & bit != 0 {
            j ^= bit;
            bit >>= 1;
        }
        j ^= bit;
        if i < j {
            re.swap(i, j);
            im.swap(i, j);
        }
    }
    let mut len = 2;
    while len <= nn {
        let ang = (-2.0 * std::f64::consts::PI) / len as f64;
        let wr = ang.cos();
        let wi = ang.sin();
        let mut i = 0;
        while i < nn {
            let mut cr = 1.0;
            let mut ci = 0.0;
            for k in 0..(len / 2) {
                let ur = re[i + k];
                let ui = im[i + k];
                let vr = re[i + k + len / 2] * cr - im[i + k + len / 2] * ci;
                let vi = re[i + k + len / 2] * ci + im[i + k + len / 2] * cr;
                re[i + k] = ur + vr;
                im[i + k] = ui + vi;
                re[i + k + len / 2] = ur - vr;
                im[i + k + len / 2] = ui - vi;
                let ncr = cr * wr - ci * wi;
                ci = cr * wi + ci * wr;
                cr = ncr;
            }
            i += len;
        }
        len <<= 1;
    }
    let half = nn / 2;
    let mut pow = vec![0.0; half + 1];
    for i in 0..=half {
        pow[i] = (re[i] * re[i] + im[i] * im[i]) / nn as f64;
    }
    pow
}

pub fn extract_har_features_from_smv(smv_raw: &[f64], fs: f64, prev_dom_freq: f64) -> HarFeatures {
    let smv = butter_lp4(smv_raw, fs, 15.0);
    let smv_mean = mean(&smv);
    let smv_std = stddev(&smv);
    let smv_min = smv.iter().cloned().fold(f64::INFINITY, f64::min);
    let smv_max = smv.iter().cloned().fold(f64::NEG_INFINITY, f64::max);

    let ac: Vec<f64> = smv.iter().map(|v| v - smv_mean).collect();
    let pow = power_spectrum(&ac);
    let nn = next_pow2(ac.len());
    let bin_hz = fs / nn as f64;
    let idx_of = |f: f64| (f / bin_hz).round() as usize;
    let lo_bin = idx_of(0.3).max(1);
    let hi_bin = idx_of(15.0).min(pow.len() - 1);
    let mut total = 0.0;
    for i in lo_bin..=hi_bin {
        total += pow[i];
    }
    let mut d1i = lo_bin;
    let mut d2i = lo_bin;
    for i in lo_bin..=hi_bin {
        if pow[i] > pow[d1i] {
            d1i = i;
        }
    }
    for i in lo_bin..=hi_bin {
        if i != d1i && pow[i] > pow[d2i] {
            d2i = i;
        }
    }
    let c_lo = idx_of(0.6).max(1);
    let c_hi = idx_of(2.5).min(pow.len() - 1);
    let mut ci = c_lo;
    for i in c_lo..=c_hi {
        if pow[i] > pow[ci] {
            ci = i;
        }
    }
    let dom1_freq = d1i as f64 * bin_hz;
    let dom1_pow = pow[d1i];
    let wav = dwt_detail_energies(&smv, 6);

    HarFeatures {
        smv_mean,
        smv_std,
        smv_min,
        smv_max,
        total_power: total,
        dom1_freq,
        dom1_pow,
        dom2_freq: d2i as f64 * bin_hz,
        dom2_pow: pow[d2i],
        cad_freq: ci as f64 * bin_hz,
        cad_pow: pow[ci],
        dom1_ratio: if total > 0.0 { dom1_pow / total } else { 0.0 },
        freq_ratio_prev: if prev_dom_freq > 0.0 { dom1_freq / prev_dom_freq } else { 1.0 },
        wav_e5: *wav.get(4).unwrap_or(&0.0),
        wav_e6: *wav.get(5).unwrap_or(&0.0),
    }
}

pub fn extract_har_features(x: &[f64], y: &[f64], z: &[f64], fs: f64, prev_dom_freq: f64) -> HarFeatures {
    let n = x.len().min(y.len()).min(z.len());
    let mut smv_raw = vec![0.0; n];
    for i in 0..n {
        smv_raw[i] = (x[i] * x[i] + y[i] * y[i] + z[i] * z[i]).sqrt();
    }
    extract_har_features_from_smv(&smv_raw, fs, prev_dom_freq)
}

const SED_POWER: f64 = 0.02;
const SED_STD: f64 = 0.04;
const PERIODIC: f64 = 0.25;
const RUN_HZ: f64 = 2.4;
const WALK_HZ: f64 = 1.3;
const CYCLE_HZ_LO: f64 = 0.6;

pub fn classify_activity_window(f: &HarFeatures) -> (String, f64) {
    if f.total_power < SED_POWER && f.smv_std < SED_STD {
        return ("sedentary".to_string(), 0.6);
    }
    let periodic = f.dom1_ratio >= PERIODIC;
    let peak_conf = 0.9f64.min(0.4 + f.dom1_ratio);
    let cad = f.dom1_freq;
    if periodic {
        if cad >= RUN_HZ {
            return ("run".to_string(), peak_conf);
        }
        if cad >= WALK_HZ {
            return ("walk".to_string(), peak_conf);
        }
        if cad >= CYCLE_HZ_LO && f.smv_std < SED_STD * 4.0 {
            return ("cycle".to_string(), peak_conf * 0.9);
        }
    }
    if f.smv_std >= SED_STD && !periodic {
        return ("lift".to_string(), 0.45);
    }
    ("other".to_string(), 0.4)
}

#[derive(Debug, Clone, Deserialize)]
pub struct ClassVote {
    pub ts: f64,
    pub cls: String,
    pub conf: f64,
}

#[derive(Debug, Clone, Serialize)]
pub struct WorkoutSegment {
    pub start_ts: f64,
    pub end_ts: f64,
    #[serde(rename = "type")]
    pub ty: String,
    pub confidence: f64,
}

#[derive(Debug, Serialize)]
pub struct SegmentResult {
    pub primary: String,
    pub segments: Vec<WorkoutSegment>,
    pub type_confidence: f64,
}

fn mode_class(window: &[&ClassVote]) -> String {
    // insertion-ordered counts → first class reaching the max wins (matches JS object keys).
    let mut order: Vec<String> = Vec::new();
    let mut counts: Vec<u32> = Vec::new();
    for v in window {
        if let Some(pos) = order.iter().position(|c| c == &v.cls) {
            counts[pos] += 1;
        } else {
            order.push(v.cls.clone());
            counts.push(1);
        }
    }
    let mut best = window[0].cls.clone();
    let mut best_n: i64 = -1;
    for i in 0..order.len() {
        if counts[i] as i64 > best_n {
            best_n = counts[i] as i64;
            best = order[i].clone();
        }
    }
    best
}

pub fn segment_workout(votes: &[ClassVote], smooth_win: usize, min_phase_sec: f64) -> SegmentResult {
    if votes.is_empty() {
        return SegmentResult { primary: "other".to_string(), segments: vec![], type_confidence: 0.0 };
    }
    let mut sorted: Vec<&ClassVote> = votes.iter().collect();
    sorted.sort_by(|a, b| a.ts.partial_cmp(&b.ts).unwrap());

    let half = smooth_win / 2;
    let smoothed: Vec<ClassVote> = (0..sorted.len())
        .map(|i| {
            let lo = if i >= half { i - half } else { 0 };
            let hi = (i + half + 1).min(sorted.len());
            ClassVote { ts: sorted[i].ts, cls: mode_class(&sorted[lo..hi]), conf: sorted[i].conf }
        })
        .collect();

    let mut raw: Vec<WorkoutSegment> = Vec::new();
    for v in &smoothed {
        if let Some(last) = raw.last_mut() {
            if last.ty == v.cls {
                last.end_ts = v.ts;
                last.confidence = (last.confidence + v.conf) / 2.0;
                continue;
            }
        }
        raw.push(WorkoutSegment { start_ts: v.ts, end_ts: v.ts, ty: v.cls.clone(), confidence: v.conf });
    }

    let mut phases: Vec<WorkoutSegment> = Vec::new();
    for seg in &raw {
        let dur = seg.end_ts - seg.start_ts;
        if dur < min_phase_sec && !phases.is_empty() {
            phases.last_mut().unwrap().end_ts = seg.end_ts;
        } else if dur < min_phase_sec && phases.is_empty() {
            phases.push(seg.clone());
        } else if let Some(last) = phases.last_mut() {
            if last.ty == seg.ty {
                last.end_ts = seg.end_ts;
            } else {
                phases.push(seg.clone());
            }
        } else {
            phases.push(seg.clone());
        }
    }

    let total_dur = {
        let s: f64 = phases.iter().map(|p| p.end_ts - p.start_ts).sum();
        if s == 0.0 { 1.0 } else { s }
    };
    let mut top = &phases[0];
    for p in &phases {
        if (p.end_ts - p.start_ts) > (top.end_ts - top.start_ts) {
            top = p;
        }
    }
    let top_share = (top.end_ts - top.start_ts) / total_dur;
    let primary = if top_share >= 0.5 { top.ty.clone() } else { "other".to_string() };
    let type_confidence = (top.confidence * top_share * 100.0).round() / 100.0;

    SegmentResult { primary, segments: phases, type_confidence }
}
