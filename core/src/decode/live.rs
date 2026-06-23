// Port of openstrap-protocol/ts/live.ts — live/compact + IMU frame decoders.
use crate::util::round;
use serde::Serialize;

fn u32le(b: &[u8], o: usize) -> u32 {
    u32::from_le_bytes([b[o], b[o + 1], b[o + 2], b[o + 3]])
}
fn u16le(b: &[u8], o: usize) -> u16 {
    u16::from_le_bytes([b[o], b[o + 1]])
}
fn i16le(b: &[u8], o: usize) -> i16 {
    i16::from_le_bytes([b[o], b[o + 1]])
}

#[derive(Debug, Serialize)]
pub struct DecodedSample {
    pub ts: u32,
    pub hr: u8,
    pub activity: f64,
    pub steps_inc: i64,
    pub wrist_on: bool,
    pub rec_type: u8,
}

#[derive(Debug, Serialize)]
pub struct ImuFrame {
    pub ts: u32,
    pub idx: u16,
    pub mags: Vec<f64>,
}

#[derive(Debug, Serialize)]
pub struct RealtimeRr {
    pub ts: u32,
    pub rr_ms: Vec<i16>,
}

/// frameAccel — one IMU frame → ordered |accel|(g) samples. 0x33 (10) or R10 (100).
pub fn frame_accel(b: &[u8]) -> Option<ImuFrame> {
    if b.len() < 32 {
        return None;
    }
    let pkt = b[0];
    let rec = b[1];
    if pkt == 0x33 && b.len() >= 84 {
        let ts = u32le(b, 4);
        let idx = u16le(b, 14);
        let mut mags = Vec::with_capacity(10);
        for i in 0..10 {
            let x = i16le(b, 24 + 2 * i) as f64;
            let y = i16le(b, 24 + 2 * (10 + i)) as f64;
            let z = i16le(b, 24 + 2 * (20 + i)) as f64;
            mags.push((x * x + y * y + z * z).sqrt() / 4096.0);
        }
        return if ts > 0 { Some(ImuFrame { ts, idx, mags }) } else { None };
    }
    if rec == 0x0a && b.len() >= 685 {
        let ts = u32le(b, 7);
        let mut mags = Vec::with_capacity(100);
        for i in 0..100 {
            let x = i16le(b, 85 + 2 * i) as f64;
            let y = i16le(b, 285 + 2 * i) as f64;
            let z = i16le(b, 485 + 2 * i) as f64;
            mags.push((x * x + y * y + z * z).sqrt() / 4096.0);
        }
        return if ts > 0 { Some(ImuFrame { ts, idx: 0, mags }) } else { None };
    }
    None
}

/// realtimeRr — beat-to-beat RR (ms) from 0x28 (count@9) or R10 (count@18). Defensive.
pub fn realtime_rr(b: &[u8]) -> Option<RealtimeRr> {
    if b.len() < 12 {
        return None;
    }
    let pkt = b[0];
    let rec = b[1];
    let (ts_off, cnt_off): (usize, usize) = if pkt == 0x28 {
        (2, 9)
    } else if rec == 10 {
        (7, 18)
    } else {
        return None;
    };
    if cnt_off + 1 >= b.len() {
        return None;
    }
    let ts = u32le(b, ts_off);
    if ts == 0 {
        return None;
    }
    let n = b[cnt_off];
    if n == 0 || n > 8 {
        return None;
    }
    let mut rr_ms: Vec<i16> = Vec::new();
    let first = cnt_off + 1;
    let mut i = 0usize;
    while (i as u8) < n && first + 2 * i + 2 <= b.len() {
        let v = i16le(b, first + 2 * i);
        if v > 0 {
            rr_ms.push(v);
        }
        i += 1;
    }
    if rr_ms.is_empty() {
        None
    } else {
        Some(RealtimeRr { ts, rr_ms })
    }
}

/// R10 IMU arrays → (activity, steps). Mirrors r10Motion exactly.
fn r10_motion(b: &[u8]) -> (f64, i64) {
    let len = b.len();
    if len < 685 {
        return (0.0, 0);
    }
    const ACC: f64 = 1.0 / 4096.0;
    let arr = |off: usize| -> Vec<f64> {
        let mut out = Vec::with_capacity(100);
        for i in 0..100 {
            let o = off + 2 * i;
            if o + 2 <= len {
                out.push(i16le(b, o) as f64);
            }
        }
        out
    };
    let ax = arr(85);
    let ay = arr(285);
    let az = arr(485);
    let n = ax.len().min(ay.len()).min(az.len());
    if n == 0 {
        return (0.0, 0);
    }
    let mut mags = Vec::with_capacity(n);
    for i in 0..n {
        let a = ax[i] * ACC;
        let c = ay[i] * ACC;
        let d = az[i] * ACC;
        mags.push((a * a + c * c + d * d).sqrt());
    }
    let mean = mags.iter().sum::<f64>() / n as f64;
    let variance = mags.iter().map(|v| (v - mean).powi(2)).sum::<f64>() / n as f64;
    let std = variance.sqrt();
    let activity = round(std, 3);

    const ACTIVITY_FLOOR: f64 = 0.05;
    if std < ACTIVITY_FLOOR || n < 24 {
        return (activity, 0);
    }
    let w = 9i64;
    let mut x = vec![0.0; n];
    for i in 0..n {
        let lo = (i as i64 - w).max(0) as usize;
        let hi = ((i as i64 + w) as usize).min(n - 1);
        let mut s = 0.0;
        let mut cnt = 0;
        for j in lo..=hi {
            s += mags[j];
            cnt += 1;
        }
        x[i] = mags[i] - s / cnt as f64;
    }
    let x0 = x.iter().sum::<f64>() / n as f64;
    let mut denom = 0.0;
    for i in 0..n {
        denom += (x[i] - x0).powi(2);
    }
    if denom <= 1e-9 {
        return (activity, 0);
    }
    const MIN_LAG: usize = 7;
    const MAX_LAG: usize = 40;
    let mut best_lag = 0usize;
    let mut best_r = 0.0;
    let upper = MAX_LAG.min(n - 1);
    let mut lag = MIN_LAG;
    while lag <= upper {
        let mut num = 0.0;
        for i in 0..(n - lag) {
            num += (x[i] - x0) * (x[i + lag] - x0);
        }
        let r = num / denom;
        if r > best_r {
            best_r = r;
            best_lag = lag;
        }
        lag += 1;
    }
    const RHYTHM_THRESH: f64 = 0.45;
    if best_lag == 0 || best_r < RHYTHM_THRESH {
        return (activity, 0);
    }
    let steps = (n as f64 / best_lag as f64).round() as i64;
    (activity, steps)
}

/// decodeRecord — one inner hex record → DecodedSample, or None.
pub fn decode_record(b: &[u8]) -> Option<DecodedSample> {
    if b.len() < 4 {
        return None;
    }
    let pkt_type = b[0];
    let rec_type = b[1];

    if pkt_type == 0x28 {
        if b.len() < 9 {
            return None;
        }
        let ts = u32le(b, 2);
        let hr = b[8];
        return Some(DecodedSample { ts, hr, activity: 0.0, steps_inc: 0, wrist_on: hr > 0, rec_type: 28 });
    }
    if pkt_type == 0x33 {
        return None;
    }
    if b.len() < 18 {
        return None;
    }
    if rec_type == 24 {
        let d = super::records::parse_r24(b)?;
        return Some(DecodedSample { ts: d.ts_epoch, hr: d.hr, activity: 0.0, steps_inc: 0, wrist_on: d.hr > 0, rec_type: 24 });
    }
    if rec_type == 10 {
        let ts = u32le(b, 7);
        let hr = b[17];
        let (activity, steps) = r10_motion(b);
        return Some(DecodedSample { ts, hr, activity, steps_inc: steps, wrist_on: hr > 0, rec_type: 10 });
    }
    None
}
