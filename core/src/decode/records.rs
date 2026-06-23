// Port of openstrap-protocol/ts/records.ts — parse_r24 (type-24 historical, 96B, 1Hz).
use crate::util::round;
use serde::Serialize;

#[derive(Debug, Serialize)]
pub struct R24 {
    pub ts_epoch: u32,
    pub ts_subsec: u16,
    pub counter: u32,
    pub hr: u8,
    pub rr_count: u8,
    pub rr_intervals_ms: Vec<i16>,
    pub ppg_green: u16,
    pub ppg_red_ir: u16,
    pub accel_g: [f64; 3],
    pub skin_contact: u8,
    pub spo2_red_raw: u16,
    pub spo2_ir_raw: u16,
    pub skin_temp_raw: u16,
    pub ambient_raw: u16,
    pub raw_tail: String,
}

fn u16le(b: &[u8], o: usize) -> u16 {
    u16::from_le_bytes([b[o], b[o + 1]])
}
fn u32le(b: &[u8], o: usize) -> u32 {
    u32::from_le_bytes([b[o], b[o + 1], b[o + 2], b[o + 3]])
}
fn i16le(b: &[u8], o: usize) -> i16 {
    i16::from_le_bytes([b[o], b[o + 1]])
}
fn f32le(b: &[u8], o: usize) -> f32 {
    f32::from_le_bytes([b[o], b[o + 1], b[o + 2], b[o + 3]])
}

/// Decode a Type-24 historical record. None if < 89 bytes. Mirrors parse_r24.
pub fn parse_r24(inner: &[u8]) -> Option<R24> {
    if inner.len() < 89 {
        return None;
    }
    let rr_count = inner[18];
    let mut rr_intervals_ms: Vec<i16> = Vec::new();
    let mut i = 0usize;
    while (i as u8) < rr_count && 19 + 2 * i + 2 <= inner.len() {
        let v = i16le(inner, 19 + 2 * i);
        if v > 0 {
            rr_intervals_ms.push(v);
        }
        i += 1;
    }
    let accel_g = [
        round(f32le(inner, 36) as f64, 4),
        round(f32le(inner, 40) as f64, 4),
        round(f32le(inner, 44) as f64, 4),
    ];
    let raw_tail: String = inner[13..].iter().map(|b| format!("{:02x}", b)).collect();
    Some(R24 {
        ts_epoch: u32le(inner, 7),
        ts_subsec: u16le(inner, 11),
        counter: u32le(inner, 3),
        hr: inner[17],
        rr_count,
        rr_intervals_ms,
        ppg_green: u16le(inner, 29),
        ppg_red_ir: u16le(inner, 31),
        accel_g,
        skin_contact: inner[51],
        spo2_red_raw: u16le(inner, 64),
        spo2_ir_raw: u16le(inner, 66),
        skin_temp_raw: u16le(inner, 68),
        ambient_raw: u16le(inner, 70),
        raw_tail,
    })
}
