// Port of openstrap-analytics/src/circadian.ts — robust cosinor (CircaCP) + stager.
use crate::hrv::clean_rr;
use crate::types::{CircadianOut, HypnoPoint, Minute, SleepStagingOut, StageMin};
use crate::util::{clamp, is_hr_usable, percentile, round};

const DAY: f64 = 86400.0;
fn w() -> f64 {
    (2.0 * std::f64::consts::PI) / DAY
}

#[derive(Clone, Copy)]
struct Pt {
    t: f64,
    y: f64,
}

struct Cosinor {
    mesor: f64,
    b1: f64,
    b2: f64,
    amp: f64,
    phi: f64,
}

fn solve3(a_in: &[[f64; 3]; 3], b: &[f64; 3]) -> Option<[f64; 3]> {
    let mut m = [[0.0; 4]; 3];
    for i in 0..3 {
        for j in 0..3 {
            m[i][j] = a_in[i][j];
        }
        m[i][3] = b[i];
    }
    for col in 0..3 {
        let mut piv = col;
        for r in (col + 1)..3 {
            if m[r][col].abs() > m[piv][col].abs() {
                piv = r;
            }
        }
        if m[piv][col].abs() < 1e-12 {
            return None;
        }
        m.swap(col, piv);
        let pv = m[col][col];
        for k in col..4 {
            m[col][k] /= pv;
        }
        for r in 0..3 {
            if r == col {
                continue;
            }
            let f = m[r][col];
            for k in col..4 {
                m[r][k] -= f * m[col][k];
            }
        }
    }
    Some([m[0][3], m[1][3], m[2][3]])
}

fn fit_cosinor(pts: &[Pt]) -> Option<Cosinor> {
    let n = pts.len();
    if n < 120 {
        return None;
    }
    let ww = w();
    let rows: Vec<(f64, f64, f64)> = pts.iter().map(|p| ((ww * p.t).cos(), (ww * p.t).sin(), p.y)).collect();
    let mut weights = vec![1.0; n];
    let (mut bm, mut b1, mut b2) = (0.0, 0.0, 0.0);
    for _ in 0..8 {
        let mut a = [[0.0; 3]; 3];
        let mut bv = [0.0; 3];
        for i in 0..n {
            let x = [1.0, rows[i].0, rows[i].1];
            let wi = weights[i];
            for r in 0..3 {
                bv[r] += wi * x[r] * rows[i].2;
                for cc in 0..3 {
                    a[r][cc] += wi * x[r] * x[cc];
                }
            }
        }
        let sol = solve3(&a, &bv)?;
        bm = sol[0];
        b1 = sol[1];
        b2 = sol[2];
        let res: Vec<f64> = rows.iter().map(|r| r.2 - (bm + b1 * r.0 + b2 * r.1)).collect();
        let mut absr: Vec<f64> = res.iter().map(|e| e.abs()).collect();
        absr.sort_by(|p, q| p.partial_cmp(q).unwrap());
        let mad = {
            let v = absr[absr.len() >> 1];
            if v == 0.0 { 1.0 } else { v }
        };
        let cc = 4.685 * 1.4826 * mad;
        weights = res.iter().map(|e| if e.abs() < cc { (1.0 - (e / cc).powi(2)).powi(2) } else { 0.0 }).collect();
    }
    Some(Cosinor { mesor: bm, b1, b2, amp: b1.hypot(b2), phi: b2.atan2(b1) })
}

fn minute_rmssd(rr: &[f64]) -> Option<f64> {
    if rr.len() < 12 {
        return None;
    }
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

fn med_of(xs: &[Option<f64>]) -> Option<f64> {
    let mut a: Vec<f64> = xs.iter().filter_map(|x| x.filter(|v| v.is_finite())).collect();
    if a.is_empty() {
        return None;
    }
    a.sort_by(|p, q| p.partial_cmp(q).unwrap());
    Some(a[a.len() >> 1])
}

fn smooth(ys: &[f64], k: usize) -> Vec<f64> {
    let n = ys.len();
    let mut out = vec![0.0; n];
    for i in 0..n {
        let lo = if i >= k { i - k } else { 0 };
        let hi = (i + k + 1).min(n);
        let mut seg: Vec<f64> = ys[lo..hi].to_vec();
        seg.sort_by(|a, b| a.partial_cmp(b).unwrap());
        out[i] = seg[seg.len() >> 1];
    }
    out
}

fn change_point(pts: &[Pt], want_drop: bool) -> Option<f64> {
    const MIN: usize = 15;
    if pts.len() < 2 * MIN {
        return None;
    }
    let ys = smooth(&pts.iter().map(|p| p.y).collect::<Vec<_>>(), 5);
    let n = ys.len();
    let mut pre = vec![0.0; n + 1];
    let mut pre2 = vec![0.0; n + 1];
    for i in 0..n {
        pre[i + 1] = pre[i] + ys[i];
        pre2[i + 1] = pre2[i] + ys[i] * ys[i];
    }
    let sse = |a: usize, b: usize| -> f64 {
        let cnt = b as f64 - a as f64;
        if cnt <= 0.0 {
            return 0.0;
        }
        let sum = pre[b] - pre[a];
        (pre2[b] - pre2[a]) - (sum * sum) / cnt
    };
    let total = sse(0, n);
    let mut best: Option<(f64, usize)> = None;
    for tau in MIN..(n - MIN) {
        let d = (pre[n] - pre[tau]) / (n as f64 - tau as f64) - pre[tau] / tau as f64;
        if want_drop && d >= 0.0 {
            continue;
        }
        if !want_drop && d <= 0.0 {
            continue;
        }
        let gain = total - (sse(0, tau) + sse(tau, n));
        if best.is_none() || gain > best.unwrap().0 {
            best = Some((gain, tau));
        }
    }
    best.map(|(_, tau)| pts[tau].t)
}

fn main_sleep_period(pts: &[Pt], bath: f64, mesor: f64) -> Option<(f64, f64)> {
    let n = pts.len();
    if n < 30 {
        return None;
    }
    let ys = smooth(&pts.iter().map(|p| p.y).collect::<Vec<_>>(), 5);
    let asleep: Vec<bool> = ys.iter().map(|v| *v < mesor).collect();
    let mut a = 0usize;
    for i in 1..n {
        if (pts[i].t - bath).abs() < (pts[a].t - bath).abs() {
            a = i;
        }
    }
    let bridge = 60.0 * 60.0;
    let mut end = a;
    let mut i = a + 1;
    while i < n {
        if asleep[i] {
            end = i;
            i += 1;
            continue;
        }
        let mut k = i;
        while k < n && !asleep[k] {
            k += 1;
        }
        let last_idx = if k < n { k } else { n } - 1;
        if pts[last_idx].t - pts[i].t > bridge {
            break;
        }
        i = k;
    }
    let mut start = a;
    let mut i: i64 = a as i64 - 1;
    while i >= 0 {
        let iu = i as usize;
        if asleep[iu] {
            start = iu;
            i -= 1;
            continue;
        }
        let mut k: i64 = i;
        while k >= 0 && !asleep[k as usize] {
            k -= 1;
        }
        if pts[iu].t - pts[(k + 1) as usize].t > bridge {
            break;
        }
        i = k;
    }
    let evening: Vec<Pt> = pts.iter().copied().filter(|p| p.t >= bath - 8.0 * 3600.0 && p.t <= bath).collect();
    let onset_cp = change_point(&evening, true);
    let onset = match onset_cp {
        Some(cp) if cp >= pts[start].t => cp,
        _ => pts[start].t,
    };
    Some((onset, pts[end].t))
}

pub fn calc_circadian(minutes: &[Minute], now_opt: Option<f64>, settle_sec: Option<f64>, anchor_ts: Option<f64>) -> CircadianOut {
    let mut usable: Vec<Pt> = minutes.iter().filter(|m| is_hr_usable(m)).map(|m| Pt { t: m.ts, y: m.hr_avg }).collect();
    usable.sort_by(|a, b| a.t.partial_cmp(&b.t).unwrap());
    let settle = settle_sec.unwrap_or(600.0);

    let empty = || CircadianOut {
        mesor: None, amplitude: None, acrophase_ts: None, bathyphase_ts: None, onset_ts: None, wake_ts: None,
        in_bed_min: 0, settled: false, confidence: 0.0, tier: "HIGH".to_string(), inputs_used: vec![],
    };
    if usable.len() < 120 {
        return empty();
    }
    let now = now_opt.unwrap_or(usable[usable.len() - 1].t);
    let fit = match fit_cosinor(&usable) {
        Some(f) => f,
        None => return empty(),
    };
    if fit.amp < 3.0 {
        return empty();
    }
    let ww = w();
    let bath_base = (fit.phi + std::f64::consts::PI) / ww;
    let acro_base = fit.phi / ww;
    let nearest = |base: f64, r: f64| base + ((r - base) / DAY).round() * DAY;

    let mut bath = nearest(bath_base, anchor_ts.unwrap_or(now));
    if bath > now - 3600.0 {
        bath -= DAY;
    }
    let acro = nearest(acro_base, now);

    let in_win = |lo: f64, hi: f64| usable.iter().copied().filter(|p| p.t >= lo && p.t <= hi).collect::<Vec<Pt>>();
    let period = main_sleep_period(&in_win(bath - 8.0 * 3600.0, bath + 10.0 * 3600.0), bath, fit.mesor);
    let onset_ts = period.map(|p| p.0);
    let wake_ts = period.map(|p| p.1);
    let in_bed_min = match (onset_ts, wake_ts) {
        (Some(o), Some(wk)) => ((wk - o) / 60.0).round() as i64,
        _ => 0,
    };
    let settled = matches!(wake_ts, Some(wk) if wk <= now - settle);

    let rhythm = clamp((fit.amp - 2.0) / 8.0, 0.0, 1.0);
    let paired = if onset_ts.is_some() && wake_ts.is_some() { 1.0 } else { 0.3 };
    let confidence = round(rhythm * paired, 2);

    CircadianOut {
        mesor: Some(round(fit.mesor, 1)),
        amplitude: Some(round(fit.amp, 1)),
        acrophase_ts: Some(acro),
        bathyphase_ts: Some(bath),
        onset_ts,
        wake_ts,
        in_bed_min,
        settled,
        confidence,
        tier: "HIGH".to_string(),
        inputs_used: vec!["hr".to_string()],
    }
}

pub fn stage_sleep(minutes: &[StageMin], onset: f64, wake: f64, mesor: f64) -> SleepStagingOut {
    let in_bed = 1i64.max(((wake - onset) / 60.0).round() as i64);
    let mut win: Vec<&StageMin> = minutes.iter().filter(|m| m.ts >= onset && m.ts <= wake).collect();
    win.sort_by(|a, b| a.ts.partial_cmp(&b.ts).unwrap());
    let empty = SleepStagingOut {
        in_bed_min: in_bed, asleep_min: 0, efficiency: 0.0, awake_min: in_bed as u32,
        light_min: 0, deep_min: 0, rem_min: 0, hypnogram: vec![],
    };
    let worn: Vec<&&StageMin> = win.iter().filter(|m| m.hr_avg > 0.0).collect();
    if worn.len() < 5 {
        return empty;
    }
    let hrs: Vec<f64> = worn.iter().map(|m| m.hr_avg).collect();
    let floor = percentile(&hrs, 10.0).unwrap_or_else(|| hrs.iter().cloned().fold(f64::INFINITY, f64::min));
    let span = 1f64.max(mesor - floor);
    let t_awake = (floor + 10.0).max(floor + 0.70 * span);
    let t_rem = floor + 0.40 * span;
    let t_deep = floor + 0.12 * span;

    let ys = smooth(&win.iter().map(|m| if m.hr_avg > 0.0 { m.hr_avg } else { t_awake + 50.0 }).collect::<Vec<_>>(), 5);

    let rm_raw: Vec<Option<f64>> = win.iter().map(|m| minute_rmssd(&m.rr)).collect();
    let rm_s: Vec<Option<f64>> = (0..win.len())
        .map(|i| {
            let lo = if i >= 2 { i - 2 } else { 0 };
            let hi = (i + 3).min(win.len());
            med_of(&rm_raw[lo..hi])
        })
        .collect();
    let asleep_i: Vec<usize> = (0..win.len()).filter(|&i| win[i].hr_avg > 0.0 && ys[i] < t_awake).collect();
    let rm_ref = med_of(&asleep_i.iter().map(|&i| rm_s[i]).collect::<Vec<_>>());
    let hr_ref = med_of(&asleep_i.iter().map(|&i| Some(ys[i])).collect::<Vec<_>>());
    let rr_usable = rm_ref.is_some()
        && hr_ref.is_some()
        && asleep_i.iter().filter(|&&i| rm_s[i].is_some()).count() >= 20.max((asleep_i.len() as f64 * 0.4).floor() as usize);
    const DEEP_R: f64 = 1.15;
    const REM_R: f64 = 0.88;

    let mut stage: Vec<String> = vec!["light".to_string(); win.len()];
    for k in 0..win.len() {
        if win[k].hr_avg <= 0.0 {
            stage[k] = "awake".to_string();
            continue;
        }
        let v = ys[k];
        if v >= t_awake {
            stage[k] = "awake".to_string();
            continue;
        }
        if rr_usable && rm_s[k].is_some() {
            let rm = rm_s[k].unwrap();
            stage[k] = if rm >= DEEP_R * rm_ref.unwrap() && v <= hr_ref.unwrap() {
                "deep".to_string()
            } else if rm <= REM_R * rm_ref.unwrap() {
                "rem".to_string()
            } else {
                "light".to_string()
            };
        } else {
            stage[k] = if v < t_deep { "deep".to_string() } else if v >= t_rem { "rem".to_string() } else { "light".to_string() };
        }
    }
    // pass 2: short awake runs (<20 min) → rem
    let mut k = 0;
    while k < win.len() {
        if stage[k] == "awake" && win[k].hr_avg > 0.0 {
            let mut j = k;
            while j < win.len() && stage[j] == "awake" && win[j].hr_avg > 0.0 {
                j += 1;
            }
            if (win[j - 1].ts - win[k].ts) / 60.0 < 20.0 {
                for x in k..j {
                    stage[x] = "rem".to_string();
                }
            }
            k = j;
        } else {
            k += 1;
        }
    }
    // pass 3: bout smoothing
    const MIN_BOUT: usize = 6;
    const MIN_AWAKE_BOUT: usize = 10;
    for _ in 0..4 {
        let mut runs: Vec<(usize, usize)> = Vec::new();
        let mut i = 0;
        while i < win.len() {
            let mut j = i;
            while j < win.len() && stage[j] == stage[i] {
                j += 1;
            }
            runs.push((i, j - 1));
            i = j;
        }
        if runs.len() <= 1 {
            break;
        }
        let mut changed = false;
        for r in 0..runs.len() {
            let (s, e) = runs[r];
            let len_min = e - s + 1;
            let floor_min = if stage[s] == "awake" { MIN_AWAKE_BOUT } else { MIN_BOUT };
            if len_min >= floor_min {
                continue;
            }
            let prev = if r > 0 { Some(runs[r - 1]) } else { None };
            let next = if r < runs.len() - 1 { Some(runs[r + 1]) } else { None };
            let target: Option<String> = match (prev, next) {
                (Some(p), Some(nx)) => Some(if (p.1 - p.0) >= (nx.1 - nx.0) { stage[p.0].clone() } else { stage[nx.0].clone() }),
                (Some(p), None) => Some(stage[p.0].clone()),
                (None, Some(nx)) => Some(stage[nx.0].clone()),
                (None, None) => None,
            };
            if let Some(t) = target {
                for x in s..=e {
                    stage[x] = t.clone();
                }
                changed = true;
            }
        }
        if !changed {
            break;
        }
    }
    let (mut light, mut deep, mut rem, mut awake) = (0u32, 0u32, 0u32, 0u32);
    for s in &stage {
        match s.as_str() {
            "awake" => awake += 1,
            "deep" => deep += 1,
            "rem" => rem += 1,
            _ => light += 1,
        }
    }
    let asleep = light + deep + rem;
    SleepStagingOut {
        in_bed_min: in_bed,
        asleep_min: asleep,
        efficiency: clamp(asleep as f64 / in_bed as f64, 0.0, 1.0),
        awake_min: awake,
        light_min: light,
        deep_min: deep,
        rem_min: rem,
        hypnogram: win.iter().enumerate().map(|(idx, m)| HypnoPoint { t: m.ts, stage: stage[idx].clone() }).collect(),
    }
}
