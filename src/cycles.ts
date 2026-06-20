// §Sleep cycles — ultradian NREM↔REM cycle detection, adapted from Rosenblum et al.
// 2024 (eLife 13:RP96784, "Fractal cycles of sleep").
//
// The paper detects sleep cycles as the interval between successive PEAKS of the
// smoothed, z-normalized EEG *aperiodic (fractal) slope* time series — MATLAB
// findpeaks(MinPeakDistance = 20 min, MinPeakProminence = 0.9 z). Peaks coincide with
// REM, troughs with non-REM; ~4–6 cycles/night, ~90 min each. It's a continuous,
// parameter-light definition with NO arbitrary per-night knob — exactly the property
// we want.
//
// We have no EEG. But heart-rate VARIABILITY carries the SAME ultradian rhythm — RMSSD
// is high in deep non-REM and low in REM — so we run the IDENTICAL peak algorithm on
// the smoothed z-normalized per-minute RMSSD series. Cycle boundaries anchor on the
// deep-sleep RMSSD peaks (the paper anchors on REM peaks: a cosmetic half-cycle phase
// shift — the cycle COUNT and DURATION, the actual outputs, are unchanged).
//
// Pure & deterministic. Tier ESTIMATE (it's a wrist-HRV proxy for an EEG method).
import { cleanRr } from './hrv';

export interface SleepCycle { start_ts: number; end_ts: number; duration_min: number }
export interface SleepCyclesValue {
  cycles: SleepCycle[];
  mean_duration_min: number | null;
  n: number;
  series: { t: number; z: number }[]; // smoothed z-RMSSD, for plotting under the hypnogram
}

const SMOOTH_MIN = 10;       // ±10-min moving average → exposes the ~90-min envelope
const MIN_PEAK_DIST = 20;    // min minutes between cycle boundaries (paper: 20 min / 40×30s)
const MIN_PROMINENCE = 0.9;  // z — paper's MinPeakProminence (the |0.9| z descent gate)

/** Per-minute RMSSD (ms) from a raw RR stream; null if too few clean beats. */
function minuteRmssd(rr: number[] | undefined): number | null {
  if (!rr || rr.length < 12) return null;
  const c = cleanRr(rr);
  if (c.length < 10) return null;
  let s = 0;
  for (let i = 1; i < c.length; i++) { const d = c[i] - c[i - 1]; s += d * d; }
  return Math.sqrt(s / (c.length - 1));
}

/** Local maxima with topographic prominence ≥ minProm, then enforce a minimum spacing
 *  (keep the highest in each cluster) — a faithful port of MATLAB findpeaks' two gates. */
function findPeaks(y: (number | null)[], minDist: number, minProm: number): number[] {
  const n = y.length;
  const cand: { i: number; v: number }[] = [];
  for (let i = 1; i < n - 1; i++) {
    const yi = y[i]; if (yi == null) continue;
    const a = y[i - 1] ?? -Infinity, b = y[i + 1] ?? -Infinity;
    if (!(yi >= a && yi > b)) continue;
    // prominence: walk out each side until a higher sample; the higher of the two
    // in-between minima is the reference. prom = peak − that reference.
    let l = i; while (l > 0 && (y[l - 1] ?? -Infinity) < yi) l--;
    let r = i; while (r < n - 1 && (y[r + 1] ?? -Infinity) < yi) r++;
    let lmin = yi, rmin = yi;
    for (let k = l; k <= i; k++) { const v = y[k]; if (v != null && v < lmin) lmin = v; }
    for (let k = i; k <= r; k++) { const v = y[k]; if (v != null && v < rmin) rmin = v; }
    if (yi - Math.max(lmin, rmin) >= minProm) cand.push({ i, v: yi });
  }
  cand.sort((p, q) => q.v - p.v); // tallest first
  const kept: number[] = [];
  for (const c of cand) if (kept.every((k) => Math.abs(c.i - k) >= minDist)) kept.push(c.i);
  return kept.sort((a, b) => a - b);
}

/**
 * detectSleepCycles(minutes, onset, wake)
 * minutes: per-minute records over (at least) the sleep window, each with optional `rr`.
 * Returns the ultradian cycles (peak-to-peak), their mean duration, and the smoothed
 * z-RMSSD series. Abstains (empty) when there isn't enough clean RR to resolve cycles.
 */
export function detectSleepCycles(
  minutes: { ts: number; rr?: number[] }[], onset: number, wake: number,
): SleepCyclesValue {
  const none: SleepCyclesValue = { cycles: [], mean_duration_min: null, n: 0, series: [] };
  const win = minutes.filter((m) => m.ts >= onset && m.ts <= wake).sort((a, b) => a.ts - b.ts);
  if (win.length < 60) return none; // need ~1 h to resolve even one cycle

  const raw = win.map((m) => minuteRmssd(m.rr));
  // ±SMOOTH_MIN moving average (ignoring gaps).
  const sm = raw.map((_, i) => {
    let s = 0, c = 0;
    for (let j = Math.max(0, i - SMOOTH_MIN); j <= Math.min(raw.length - 1, i + SMOOTH_MIN); j++) {
      const v = raw[j]; if (v != null) { s += v; c++; }
    }
    return c ? s / c : null;
  });
  const vals = sm.filter((x): x is number => x != null);
  if (vals.length < 60) return none;
  const mean = vals.reduce((a, b) => a + b, 0) / vals.length;
  const sd = Math.sqrt(vals.reduce((a, b) => a + (b - mean) ** 2, 0) / vals.length) || 1;
  const z = sm.map((x) => (x == null ? null : (x - mean) / sd));

  const peaks = findPeaks(z, MIN_PEAK_DIST, MIN_PROMINENCE);
  const cycles: SleepCycle[] = [];
  for (let i = 0; i + 1 < peaks.length; i++) {
    const start_ts = win[peaks[i]].ts, end_ts = win[peaks[i + 1]].ts;
    cycles.push({ start_ts, end_ts, duration_min: Math.round((end_ts - start_ts) / 60) });
  }
  const mean_duration_min = cycles.length
    ? Math.round(cycles.reduce((s, c) => s + c.duration_min, 0) / cycles.length) : null;
  const series = win
    .map((m, i) => ({ t: m.ts, z: z[i] }))
    .filter((p): p is { t: number; z: number } => p.z != null)
    .map((p) => ({ t: p.t, z: Math.round(p.z * 1000) / 1000 }));

  return { cycles, mean_duration_min, n: cycles.length, series };
}
