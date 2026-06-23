// Port of openstrap-analytics/src/sleep.ts — Cole-Kripke + HR-dip fusion.
use crate::hrv::clean_rr;
use crate::types::{Baseline, Minute, NightHypnogram, HypnoPoint, SleepOut, SleepPeriod, SleepPeriodsOut, SleepStages};
use crate::util::{is_hr_usable, mean, round};
use std::collections::HashMap;

const CK_W: [f64; 7] = [1.06, 0.54, 0.58, 0.76, 2.3, 0.74, 0.67];
const REM_RMSSD_FACTOR: f64 = 0.90;

fn minute_rmssd(rr: Option<&Vec<f64>>) -> Option<f64> {
    let rr = rr?;
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

/// Upper-median of nullable values (sorted asc → index len>>1). Mirrors medOfNullable.
fn med_of_nullable(xs: &[Option<f64>]) -> Option<f64> {
    let mut a: Vec<f64> = xs.iter().filter_map(|x| x.filter(|v| v.is_finite())).collect();
    if a.is_empty() {
        return None;
    }
    a.sort_by(|p, q| p.partial_cmp(q).unwrap());
    Some(a[a.len() >> 1])
}

/// Index-based percentile (NOT linear-interp): sorted[min(len-1, floor(p*len))].
fn idx_pctl(sorted: &[f64], p: f64, fallback: f64) -> f64 {
    if sorted.is_empty() {
        return fallback;
    }
    let i = ((p * sorted.len() as f64).floor() as usize).min(sorted.len() - 1);
    sorted[i]
}

pub fn calc_sleep(minutes: &[Minute], baseline: &Baseline) -> SleepOut {
    let mut sorted: Vec<Minute> = minutes.to_vec();
    sorted.sort_by(|a, b| a.ts.partial_cmp(&b.ts).unwrap());
    let n = sorted.len();

    let empty = || SleepOut {
        onset_ts: None, wake_ts: None, duration_min: 0, in_bed_min: 0, efficiency: 0.0,
        stages: None, stages_beta: true, confidence: 0.0, tier: "HIGH".to_string(), inputs_used: vec![],
    };
    if n == 0 {
        return empty();
    }
    let rhr = baseline.resting_hr;
    if rhr <= 0.0 {
        return empty();
    }

    let mut worn_hr: Vec<f64> = sorted.iter().filter(|m| m.wrist_on && m.hr_avg > 0.0).map(|m| m.hr_avg).collect();
    worn_hr.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let sleep_hr = rhr.max(idx_pctl(&worn_hr, 0.10, rhr));
    const ASLEEP_HI: f64 = 1.05;
    const AWAKE_HI: f64 = 1.20;
    const ABS_WAKE: f64 = 1.5;

    let mut asleep = vec![false; n];
    for i in 0..n {
        let mut s = 0.0;
        for k in 0..CK_W.len() {
            let off = k as i64 - 4;
            let idx = i as i64 + off;
            if idx >= 0 && (idx as usize) < n {
                s += CK_W[k] * sorted[idx as usize].activity;
            }
        }
        s *= 0.001;
        let m = &sorted[i];
        if !m.wrist_on {
            asleep[i] = false;
            continue;
        }
        let mut is_asleep = s < 1.0;
        if m.hr_avg > 0.0 {
            if m.hr_avg > ABS_WAKE * rhr {
                is_asleep = false;
            } else if m.hr_avg <= ASLEEP_HI * sleep_hr {
                is_asleep = true;
            } else if m.hr_avg > AWAKE_HI * sleep_hr {
                is_asleep = false;
            }
        }
        asleep[i] = is_asleep;
    }

    let (mut start_idx, mut end_idx) = segment_main(&asleep, n, 20);
    if start_idx < 0 {
        return empty();
    }
    const MAX_SLEEP_MIN: i64 = 14 * 60;
    if end_idx - start_idx + 1 > MAX_SLEEP_MIN {
        for tighter in [10, 5, 2] {
            let (bs, be) = segment_main(&asleep, n, tighter);
            if bs >= 0 && be - bs + 1 <= MAX_SLEEP_MIN {
                start_idx = bs;
                end_idx = be;
                break;
            }
            if bs >= 0 {
                start_idx = bs;
                end_idx = be;
            }
        }
        if end_idx - start_idx + 1 > MAX_SLEEP_MIN {
            end_idx = start_idx + MAX_SLEEP_MIN - 1;
        }
    }

    let su = start_idx as usize;
    let eu = end_idx as usize;
    let onset_ts = sorted[su].ts;
    let wake_ts = sorted[eu].ts;
    let in_bed_min = (eu - su + 1) as u32;
    let mut duration_min = 0u32;
    for i in su..=eu {
        if asleep[i] {
            duration_min += 1;
        }
    }
    let efficiency = if in_bed_min > 0 { duration_min as f64 / in_bed_min as f64 } else { 0.0 };

    let sleep_epochs: Vec<Minute> = (su..=eu).filter(|&i| asleep[i]).map(|i| sorted[i].clone()).collect();
    let stages = estimate_stages(&sleep_epochs, rhr);

    let in_bed: &[Minute] = &sorted[su..=eu];
    let has_hr = in_bed.iter().any(|m| m.wrist_on && m.hr_avg > 0.0);
    let has_activity = in_bed.iter().any(|m| m.activity > 0.0);
    let has_temp = baseline.skin_temp.is_some();
    let present = [has_hr, has_activity, has_temp].iter().filter(|&&x| x).count();
    let input_completeness = present as f64 / 3.0;
    let coverage = 1f64.min(in_bed_min as f64 / 240.0);
    let confidence = input_completeness * coverage;

    let mut inputs_used = vec!["activity".to_string()];
    if has_hr {
        inputs_used.push("hr_avg".to_string());
    }
    if has_temp {
        inputs_used.push("baseline.skin_temp".to_string());
    }

    SleepOut {
        onset_ts: Some(onset_ts),
        wake_ts: Some(wake_ts),
        duration_min,
        in_bed_min,
        efficiency: round(efficiency, 4),
        stages,
        stages_beta: true,
        confidence: round(confidence, 4),
        tier: "HIGH".to_string(),
        inputs_used,
    }
}

/// Longest consolidated period (≤max_gap interior awake). Returns (start,end) idx or (-1,-1).
fn segment_main(asleep: &[bool], n: usize, max_gap: i64) -> (i64, i64) {
    let mut best_start = -1i64;
    let mut best_end = -1i64;
    let mut best_asleep = 0i64;
    let mut pf = -1i64;
    let mut pl = -1i64;
    let mut pa = 0i64;
    let mut gap = 0i64;
    let mut close = |pf: &mut i64, pl: &mut i64, pa: &mut i64, gap: &mut i64, bs: &mut i64, be: &mut i64, ba: &mut i64| {
        if *pf >= 0 && *pa > *ba {
            *ba = *pa;
            *bs = *pf;
            *be = *pl;
        }
        *pf = -1;
        *pl = -1;
        *pa = 0;
        *gap = 0;
    };
    for i in 0..n {
        if asleep[i] {
            if pf < 0 {
                pf = i as i64;
            }
            pl = i as i64;
            pa += 1;
            gap = 0;
        } else if pf >= 0 {
            gap += 1;
            if gap > max_gap {
                close(&mut pf, &mut pl, &mut pa, &mut gap, &mut best_start, &mut best_end, &mut best_asleep);
            }
        }
    }
    close(&mut pf, &mut pl, &mut pa, &mut gap, &mut best_start, &mut best_end, &mut best_asleep);
    if best_start < 0 || best_asleep == 0 {
        (-1, -1)
    } else {
        (best_start, best_end)
    }
}

pub fn calc_sleep_periods(minutes: &[Minute], baseline: &Baseline) -> SleepPeriodsOut {
    let mut sorted: Vec<Minute> = minutes.to_vec();
    sorted.sort_by(|a, b| a.ts.partial_cmp(&b.ts).unwrap());
    let n = sorted.len();
    let rhr = baseline.resting_hr;
    let empty = || SleepPeriodsOut {
        periods: vec![], total_asleep_min: 0, main_idx: None, stages_beta: true,
        confidence: 0.0, tier: "HIGH".to_string(), inputs_used: vec![],
    };
    if n == 0 || rhr <= 0.0 {
        return empty();
    }

    let mut asleep = vec![false; n];
    for i in 0..n {
        let mut s = 0.0;
        for k in 0..CK_W.len() {
            let idx = i as i64 + (k as i64 - 4);
            if idx >= 0 && (idx as usize) < n {
                s += CK_W[k] * sorted[idx as usize].activity;
            }
        }
        s *= 0.001;
        let m = &sorted[i];
        if !m.wrist_on {
            asleep[i] = false;
            continue;
        }
        let mut is_asleep = s < 1.0;
        if m.hr_avg > 0.0 {
            if m.hr_avg < 0.95 * rhr {
                is_asleep = true;
            } else if m.hr_avg > 1.15 * rhr {
                is_asleep = false;
            }
        }
        asleep[i] = is_asleep;
    }

    const MAX_GAP_MIN: i64 = 20;
    const MAX_SLEEP_MIN: i64 = 14 * 60;
    const MIN_PERIOD_MIN: u32 = 15;

    // collect ALL consolidated periods.
    let mut raw: Vec<(usize, usize)> = Vec::new();
    let mut pf = -1i64;
    let mut pl = -1i64;
    let mut pa = 0i64;
    let mut gap = 0i64;
    let mut close = |pf: &mut i64, pl: &mut i64, pa: &mut i64, gap: &mut i64, raw: &mut Vec<(usize, usize)>| {
        if *pf >= 0 && *pa > 0 {
            raw.push((*pf as usize, *pl as usize));
        }
        *pf = -1;
        *pl = -1;
        *pa = 0;
        *gap = 0;
    };
    for i in 0..n {
        if asleep[i] {
            if pf < 0 {
                pf = i as i64;
            }
            pl = i as i64;
            pa += 1;
            gap = 0;
        } else if pf >= 0 {
            gap += 1;
            if gap > MAX_GAP_MIN {
                close(&mut pf, &mut pl, &mut pa, &mut gap, &mut raw);
            }
        }
    }
    close(&mut pf, &mut pl, &mut pa, &mut gap, &mut raw);

    let mut periods: Vec<SleepPeriod> = Vec::new();
    for (start, end0) in raw {
        let start_idx = start;
        let mut end_idx = end0;
        if (end_idx as i64) - (start_idx as i64) + 1 > MAX_SLEEP_MIN {
            end_idx = start_idx + MAX_SLEEP_MIN as usize - 1;
        }
        let span = &sorted[start_idx..=end_idx];
        let in_bed_min = span.len() as u32;
        let mut duration_min = 0u32;
        for i in start_idx..=end_idx {
            if asleep[i] {
                duration_min += 1;
            }
        }
        if duration_min < MIN_PERIOD_MIN {
            continue;
        }
        let efficiency = if in_bed_min > 0 { duration_min as f64 / in_bed_min as f64 } else { 0.0 };
        let sleep_epochs: Vec<Minute> = (start_idx..=end_idx).filter(|&i| asleep[i]).map(|i| sorted[i].clone()).collect();
        let stages = estimate_stages(&sleep_epochs, rhr);
        let has_hr = span.iter().any(|m| m.wrist_on && m.hr_avg > 0.0);
        let has_activity = span.iter().any(|m| m.activity > 0.0);
        let has_temp = baseline.skin_temp.is_some();
        let input_completeness = [has_hr, has_activity, has_temp].iter().filter(|&&x| x).count() as f64 / 3.0;
        let coverage = 1f64.min(in_bed_min as f64 / 90.0);
        periods.push(SleepPeriod {
            onset_ts: sorted[start_idx].ts,
            wake_ts: sorted[end_idx].ts,
            duration_min,
            in_bed_min,
            efficiency: round(efficiency, 4),
            stages,
            is_main: false,
            confidence: round(input_completeness * coverage, 4),
        });
    }
    if periods.is_empty() {
        return empty();
    }
    let mut main_idx = 0usize;
    for i in 1..periods.len() {
        if periods[i].duration_min > periods[main_idx].duration_min {
            main_idx = i;
        }
    }
    periods[main_idx].is_main = true;
    let total_asleep_min: u32 = periods.iter().map(|p| p.duration_min).sum();
    let mut inputs_used = vec!["activity".to_string()];
    if sorted.iter().any(|m| m.wrist_on && m.hr_avg > 0.0) {
        inputs_used.push("hr_avg".to_string());
    }
    if baseline.skin_temp.is_some() {
        inputs_used.push("baseline.skin_temp".to_string());
    }
    let conf = periods[main_idx].confidence;
    SleepPeriodsOut {
        periods,
        total_asleep_min,
        main_idx: Some(main_idx),
        stages_beta: true,
        confidence: conf,
        tier: "HIGH".to_string(),
        inputs_used,
    }
}

/// ts → asleep map (Cole-Kripke + HR-dip + optional RR REM tiebreaker).
pub fn sleep_awake_mask(minutes: &[Minute], baseline: &Baseline, rr_by_min: Option<&HashMap<u64, Vec<f64>>>) -> Vec<(f64, bool)> {
    let rhr = baseline.resting_hr;
    let mut out: Vec<(f64, bool)> = Vec::new();
    if rhr <= 0.0 {
        return out;
    }
    let mut sorted: Vec<Minute> = minutes.to_vec();
    sorted.sort_by(|a, b| a.ts.partial_cmp(&b.ts).unwrap());
    let n = sorted.len();

    let mut rms: Vec<Option<f64>> = Vec::new();
    let mut rem_cut: Option<f64> = None;
    if let Some(map) = rr_by_min {
        if !map.is_empty() {
            let raw: Vec<Option<f64>> = sorted.iter().map(|m| minute_rmssd(map.get(&m.ts.to_bits()))).collect();
            rms = (0..n)
                .map(|i| {
                    let lo = if i >= 2 { i - 2 } else { 0 };
                    let hi = (i + 3).min(n);
                    med_of_nullable(&raw[lo..hi])
                })
                .collect();
            let asleep_rms: Vec<Option<f64>> = sorted.iter().enumerate().map(|(i, m)| if m.hr_avg > 0.0 { rms[i] } else { None }).collect();
            if let Some(med) = med_of_nullable(&asleep_rms) {
                rem_cut = Some(REM_RMSSD_FACTOR * med);
            }
        }
    }

    for i in 0..n {
        let mut s = 0.0;
        for k in 0..CK_W.len() {
            let idx = i as i64 + (k as i64 - 4);
            if idx >= 0 && (idx as usize) < n {
                s += CK_W[k] * sorted[idx as usize].activity;
            }
        }
        s *= 0.001;
        let m = &sorted[i];
        if !m.wrist_on {
            out.push((m.ts, false));
            continue;
        }
        let mut is_asleep = s < 1.0;
        if m.hr_avg > 0.0 {
            if m.hr_avg < 0.95 * rhr {
                is_asleep = true;
            } else if m.hr_avg > 1.15 * rhr {
                let rem_like = match (rem_cut, rms.get(i).copied().flatten()) {
                    (Some(cut), Some(v)) => v < cut,
                    _ => false,
                };
                is_asleep = rem_like;
            }
        }
        out.push((m.ts, is_asleep));
    }
    out
}

fn bout_smooth_stage(labels: &[String], min_run: usize, min_awake_run: usize, passes: usize) -> Vec<String> {
    let mut s: Vec<String> = labels.to_vec();
    for _ in 0..passes {
        let mut runs: Vec<(usize, usize)> = Vec::new();
        let mut i = 0;
        while i < s.len() {
            let mut j = i;
            while j < s.len() && s[j] == s[i] {
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
            let (a, b) = runs[r];
            let floor = if s[a] == "awake" { min_awake_run } else { min_run };
            if b - a + 1 >= floor {
                continue;
            }
            let prev = if r > 0 { Some(runs[r - 1]) } else { None };
            let next = if r < runs.len() - 1 { Some(runs[r + 1]) } else { None };
            let tgt: Option<String> = match (prev, next) {
                (Some(p), Some(nx)) => Some(if (p.1 - p.0) >= (nx.1 - nx.0) { s[p.0].clone() } else { s[nx.0].clone() }),
                (Some(p), None) => Some(s[p.0].clone()),
                (None, Some(nx)) => Some(s[nx.0].clone()),
                (None, None) => None,
            };
            if let Some(t) = tgt {
                for x in a..=b {
                    s[x] = t.clone();
                }
                changed = true;
            }
        }
        if !changed {
            break;
        }
    }
    s
}

pub fn stage_hypnogram(minutes: &[Minute], onset: f64, wake: f64, baseline: &Baseline, rr_by_min: Option<&HashMap<u64, Vec<f64>>>) -> Option<NightHypnogram> {
    let rhr = baseline.resting_hr;
    if rhr <= 0.0 {
        return None;
    }
    let mask_vec = sleep_awake_mask(minutes, baseline, rr_by_min);
    let mask: HashMap<u64, bool> = mask_vec.iter().map(|(ts, a)| (ts.to_bits(), *a)).collect();
    let mut win: Vec<Minute> = minutes.iter().filter(|m| m.ts >= onset && m.ts <= wake).cloned().collect();
    win.sort_by(|a, b| a.ts.partial_cmp(&b.ts).unwrap());
    if win.len() < 5 {
        return None;
    }
    let get_mask = |ts: f64| mask.get(&ts.to_bits()).copied();

    let sleep_hr: Vec<f64> = win.iter().filter(|m| get_mask(m.ts) != Some(false) && m.hr_avg > 0.0).map(|m| m.hr_avg).collect();
    let hrs: Vec<f64> = if !sleep_hr.is_empty() { sleep_hr } else { win.iter().filter(|m| m.hr_avg > 0.0).map(|m| m.hr_avg).collect() };
    let mut sorted_hr = hrs.clone();
    sorted_hr.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let mean_hr = if !hrs.is_empty() { hrs.iter().sum::<f64>() / hrs.len() as f64 } else { rhr };
    let q = |p: f64| idx_pctl(&sorted_hr, p, mean_hr);
    let deep_edge = q(0.22);
    let rem_edge = q(0.79);
    let big_jump = 6f64.max(if !hrs.is_empty() { 1f64.max(q(0.9) - q(0.1)) } else { 1.0 } * 0.6);
    let mean_act = { let acts: Vec<f64> = win.iter().map(|m| m.activity).collect(); acts.iter().sum::<f64>() / acts.len().max(1) as f64 };

    let raw: Vec<String> = win
        .iter()
        .enumerate()
        .map(|(i, m)| {
            if get_mask(m.ts) == Some(false) || m.hr_avg <= 0.0 {
                return "awake".to_string();
            }
            let hr = m.hr_avg;
            let prev = if i > 0 && win[i - 1].hr_avg > 0.0 { win[i - 1].hr_avg } else { hr };
            let next = if i + 1 < win.len() && win[i + 1].hr_avg > 0.0 { win[i + 1].hr_avg } else { hr };
            let hr_jump = (hr - prev).abs().max((hr - next).abs());
            let low_act = m.activity <= mean_act;
            if low_act && hr <= deep_edge {
                "deep".to_string()
            } else if low_act && hr >= rem_edge {
                "rem".to_string()
            } else if low_act && hr_jump > big_jump {
                "rem".to_string()
            } else {
                "light".to_string()
            }
        })
        .collect();
    let sm = bout_smooth_stage(&raw, 5, 7, 6);
    let (mut light, mut deep, mut rem, mut awake) = (0u32, 0u32, 0u32, 0u32);
    for st in &sm {
        match st.as_str() {
            "awake" => awake += 1,
            "deep" => deep += 1,
            "rem" => rem += 1,
            _ => light += 1,
        }
    }
    Some(NightHypnogram {
        hypnogram: win.iter().enumerate().map(|(i, m)| HypnoPoint { t: m.ts, stage: sm[i].clone() }).collect(),
        light_min: light,
        deep_min: deep,
        rem_min: rem,
        awake_min: awake,
        asleep_min: light + deep + rem,
    })
}

fn estimate_stages(sleep_epochs: &[Minute], rhr: f64) -> Option<SleepStages> {
    if sleep_epochs.is_empty() {
        return None;
    }
    let hrs: Vec<f64> = sleep_epochs.iter().filter(|m| m.hr_avg > 0.0).map(|m| m.hr_avg).collect();
    let mean_hr = if !hrs.is_empty() { mean(&hrs) } else { rhr };
    let acts: Vec<f64> = sleep_epochs.iter().map(|m| m.activity).collect();
    let mean_act = mean(&acts);

    let mut sorted_hr = hrs.clone();
    sorted_hr.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let q = |p: f64| idx_pctl(&sorted_hr, p, mean_hr);
    let deep_edge = q(0.22);
    let rem_edge = q(0.79);
    let hr_spread = if !hrs.is_empty() { 1f64.max(q(0.9) - q(0.1)) } else { 1.0 };
    let big_jump = 6f64.max(hr_spread * 0.6);

    let (mut light, mut deep, mut rem) = (0u32, 0u32, 0u32);
    for i in 0..sleep_epochs.len() {
        let m = &sleep_epochs[i];
        let low_act = m.activity <= mean_act;
        let hr = if m.hr_avg > 0.0 { m.hr_avg } else { mean_hr };
        let prev = if i > 0 && sleep_epochs[i - 1].hr_avg > 0.0 { sleep_epochs[i - 1].hr_avg } else { hr };
        let next = if i + 1 < sleep_epochs.len() && sleep_epochs[i + 1].hr_avg > 0.0 { sleep_epochs[i + 1].hr_avg } else { hr };
        let hr_jump = (hr - prev).abs().max((hr - next).abs());
        if low_act && hr <= deep_edge {
            deep += 1;
        } else if low_act && hr >= rem_edge {
            rem += 1;
        } else if low_act && hr_jump > big_jump {
            rem += 1;
        } else {
            light += 1;
        }
    }
    Some(SleepStages { light_min: light, deep_min: deep, rem_min: rem })
}
