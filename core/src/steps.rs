// Port of openstrap-analytics/src/steps.ts — AN-2554 wrist pedometer.
const FS: usize = 100;
const FILTER: usize = 8;
const WINDOW: usize = 33;
const SENS: f64 = 0.10;
const THR_ORDER: usize = 4;
const CONFIRM: u32 = 8;
const MAXMIN_TIMEOUT: i64 = 120;
const GAIN: f64 = 1.11;

#[allow(dead_code)]
pub const STEP_FS: usize = FS;

struct Cand {
    i: usize,
    max: bool,
    v: f64,
}

/// AN-2554 step count over one contiguous accel-magnitude signal (g, ~100 Hz). Raw count.
pub fn pedometer(sig: &[f64]) -> u32 {
    let n = sig.len();
    if n < WINDOW {
        return 0;
    }
    let mut lp = vec![0.0; n];
    let mut acc = 0.0;
    for i in 0..n {
        acc += sig[i];
        if i >= FILTER {
            acc -= sig[i - FILTER];
        }
        lp[i] = acc / (i + 1).min(FILTER) as f64;
    }
    let half = WINDOW >> 1;
    let mut cand: Vec<Cand> = Vec::new();
    for i in half..(n - half) {
        let mut is_max = true;
        let mut is_min = true;
        let v = lp[i];
        for j in (i - half)..=(i + half) {
            if lp[j] > v {
                is_max = false;
            }
            if lp[j] < v {
                is_min = false;
            }
            if !is_max && !is_min {
                break;
            }
        }
        if is_max {
            cand.push(Cand { i, max: true, v });
        } else if is_min {
            cand.push(Cand { i, max: false, v });
        }
    }
    let mut dyn_buf: Vec<f64> = Vec::new();
    let mut dyn_val = sig.iter().sum::<f64>() / n as f64;
    let mut steps = 0u32;
    let mut poss = 0u32;
    let mut regulation = false;
    let mut state_max = true;
    let mut cur_max = 0.0;
    let mut cur_max_idx: i64 = -1;
    for c in &cand {
        if state_max {
            if c.max {
                cur_max = c.v;
                cur_max_idx = c.i as i64;
                state_max = false;
            }
        } else {
            if c.max {
                if c.v > cur_max {
                    cur_max = c.v;
                    cur_max_idx = c.i as i64;
                }
                continue;
            }
            if c.i as i64 - cur_max_idx > MAXMIN_TIMEOUT {
                state_max = true;
                poss = 0;
                regulation = false;
                continue;
            }
            let mx = cur_max;
            let mn = c.v;
            if mx > dyn_val + SENS / 2.0 && mn < dyn_val - SENS / 2.0 {
                if mx - mn > SENS {
                    dyn_buf.push((mx + mn) / 2.0);
                    if dyn_buf.len() > THR_ORDER {
                        dyn_buf.remove(0);
                    }
                    dyn_val = dyn_buf.iter().sum::<f64>() / dyn_buf.len() as f64;
                }
                poss += 1;
                if regulation {
                    steps += 1;
                } else if poss >= CONFIRM {
                    steps += poss;
                    regulation = true;
                }
            } else {
                poss = 0;
                regulation = false;
            }
            state_max = true;
        }
    }
    steps
}

/// Sum the pedometer over per-minute contiguous signals + apply calibration gain.
pub fn calc_steps(minute_signals: &[Vec<f64>]) -> i64 {
    let mut total = 0u32;
    for sig in minute_signals {
        total += pedometer(sig);
    }
    (total as f64 * GAIN).round() as i64
}
