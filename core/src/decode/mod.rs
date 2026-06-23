// Protocol decoder — Rust port of openstrap-protocol/ts {records.ts, live.ts},
// 1:1 with the TS (the parity oracle) and the Dart header decoder. All byte-offset
// knowledge for the WHOOP band lives here; the same crate that does analytics now
// does decode → one core, wasm (cloud ingest) + native (edge live/drain via FFI).
pub mod live;
pub mod records;

/// Parse a hex string to bytes (pairs). None on odd length / bad nibble.
pub fn hex_to_bytes(hex: &str) -> Option<Vec<u8>> {
    let h = hex.trim();
    if h.len() % 2 != 0 {
        return None;
    }
    let mut out = Vec::with_capacity(h.len() / 2);
    let bytes = h.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        let hi = (bytes[i] as char).to_digit(16)?;
        let lo = (bytes[i + 1] as char).to_digit(16)?;
        out.push((hi * 16 + lo) as u8);
        i += 2;
    }
    Some(out)
}
