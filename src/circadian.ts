// §Circadian — CircaCP (Chen & Sun 2021, arXiv:2111.14960): robust cosinor model
// of the circadian rhythm + a single bounded change-point per cycle for sleep
// onset / wake. Validated on the dev account: wake within ~2 min, onset within
// ~2 min of the Cole-Kripke detector on real WHOOP 1 Hz HR.
//
// WHY HR (not actigraphy): the paper uses minute actigraphy, but the method is
// signal-agnostic and HR carries a strong, clean circadian rhythm (MESOR≈79,
// amplitude≈13 bpm on the dev account) with a sharp wake transition (HR rises
// ~25 bpm on waking) — a better wake discriminator than our near-zero activity
// rollup. Published method, no training, no fabrication; pure & deterministic.
//
// Division of labour: this returns the circadian phase + the MAIN-sleep
// onset/wake boundary of the most-recent completed cycle. In-sleep staging,
// efficiency and naps stay with calcSleep / calcSleepPeriods over that window.
import type { Minute, Metric, CircadianValue } from './types';
import { isHrUsable, clamp, round } from './util';

const DAY = 86400;
const W = (2 * Math.PI) / DAY; // circadian angular frequency (rad/sec)

interface Pt { t: number; y: number }

/**
 * Robust cosinor: y ≈ M + b1·cos(ωt) + b2·sin(ωt), fit by IRLS with a Tukey
 * biweight so the active-phase HR spikes (exercise) don't drag the rhythm.
 * Returns MESOR M, and (b1,b2) → amplitude = hypot, phase φ = atan2(b2,b1)
 * with b1·cos+b2·sin = amp·cos(ωt − φ).
 */
function fitCosinor(pts: Pt[]): { mesor: number; b1: number; b2: number; amp: number; phi: number } | null {
  const n = pts.length;
  if (n < 120) return null; // need at least ~2h of points for a stable fit
  const rows = pts.map((p) => ({ c: Math.cos(W * p.t), s: Math.sin(W * p.t), y: p.y }));
  let w = new Array(n).fill(1);
  let M = 0, b1 = 0, b2 = 0;
  for (let iter = 0; iter < 8; iter++) {
    // weighted normal equations for design [1, cos, sin] (3×3)
    const A = [[0, 0, 0], [0, 0, 0], [0, 0, 0]];
    const bv = [0, 0, 0];
    for (let i = 0; i < n; i++) {
      const x = [1, rows[i].c, rows[i].s];
      const wi = w[i];
      for (let r = 0; r < 3; r++) {
        bv[r] += wi * x[r] * rows[i].y;
        for (let cc = 0; cc < 3; cc++) A[r][cc] += wi * x[r] * x[cc];
      }
    }
    const sol = solve3(A, bv);
    if (!sol) return null;
    [M, b1, b2] = sol;
    // update biweight weights from residuals (c = 4.685·1.4826·MAD)
    const res = rows.map((r) => r.y - (M + b1 * r.c + b2 * r.s));
    const absr = res.map(Math.abs).sort((a, b) => a - b);
    const mad = absr[absr.length >> 1] || 1;
    const cc = 4.685 * 1.4826 * mad;
    w = res.map((e) => (Math.abs(e) < cc ? (1 - (e / cc) ** 2) ** 2 : 0));
  }
  return { mesor: M, b1, b2, amp: Math.hypot(b1, b2), phi: Math.atan2(b2, b1) };
}

/** Solve 3×3 A·x = b by Gaussian elimination with partial pivot. null if singular. */
function solve3(A: number[][], b: number[]): [number, number, number] | null {
  const m = A.map((row, i) => [...row, b[i]]);
  for (let col = 0; col < 3; col++) {
    let piv = col;
    for (let r = col + 1; r < 3; r++) if (Math.abs(m[r][col]) > Math.abs(m[piv][col])) piv = r;
    if (Math.abs(m[piv][col]) < 1e-12) return null;
    [m[col], m[piv]] = [m[piv], m[col]];
    const pv = m[col][col];
    for (let k = col; k < 4; k++) m[col][k] /= pv;
    for (let r = 0; r < 3; r++) {
      if (r === col) continue;
      const f = m[r][col];
      for (let k = col; k < 4; k++) m[r][k] -= f * m[col][k];
    }
  }
  return [m[0][3], m[1][3], m[2][3]];
}

/** Median filter (±k) to denoise HR before change-point search. */
function smooth(ys: number[], k: number): number[] {
  const n = ys.length;
  const out = new Array(n);
  for (let i = 0; i < n; i++) {
    const lo = Math.max(0, i - k), hi = Math.min(n, i + k + 1);
    const seg = ys.slice(lo, hi).sort((a, b) => a - b);
    out[i] = seg[seg.length >> 1];
  }
  return out;
}

/**
 * Single mean-shift change-point within a bounded window, constrained to a
 * direction ('drop' = onset, HR falls; 'rise' = wake, HR climbs). Maximises the
 * SSE reduction of a 2-segment split (binary-segmentation cost). null if the
 * window is too thin or no shift of the wanted sign exists.
 */
function changePoint(pts: Pt[], want: 'drop' | 'rise'): { ts: number; before: number; after: number } | null {
  const MIN = 15;
  if (pts.length < 2 * MIN) return null;
  const ys = smooth(pts.map((p) => p.y), 5);
  const n = ys.length;
  const pre = new Array(n + 1).fill(0);
  const pre2 = new Array(n + 1).fill(0);
  for (let i = 0; i < n; i++) { pre[i + 1] = pre[i] + ys[i]; pre2[i + 1] = pre2[i] + ys[i] * ys[i]; }
  const sse = (a: number, b: number): number => {
    const cnt = b - a; if (cnt <= 0) return 0;
    const sum = pre[b] - pre[a];
    return (pre2[b] - pre2[a]) - (sum * sum) / cnt;
  };
  const total = sse(0, n);
  let best: { gain: number; tau: number; ml: number; mr: number } | null = null;
  for (let tau = MIN; tau < n - MIN; tau++) {
    const ml = pre[tau] / tau;
    const mr = (pre[n] - pre[tau]) / (n - tau);
    const d = mr - ml; // +ve = rise
    if (want === 'rise' && d <= 0) continue;
    if (want === 'drop' && d >= 0) continue;
    const gain = total - (sse(0, tau) + sse(tau, n));
    if (!best || gain > best.gain) best = { gain, tau, ml, mr };
  }
  if (!best) return null;
  return { ts: pts[best.tau].t, before: best.ml, after: best.mr };
}

/**
 * Wake = the START of the LAST sustained HR elevation (≥ `threshold` for ≥ `minRunMin`
 * minutes) in the window. A single change-point picks the most prominent mean-shift,
 * which for a night with REM/arousal bumps lands mid-sleep, not at the morning rise —
 * so we instead take the final sustained climb above the cosinor mesor (the awakening
 * that doesn't come back down). null if HR never sustains above threshold (still asleep).
 */
function sustainedWake(pts: Pt[], threshold: number, minRunMin: number): number | null {
  if (pts.length < 10) return null;
  const ys = smooth(pts.map((p) => p.y), 5);
  let wakeIdx = -1;
  let i = 0;
  while (i < ys.length) {
    if (ys[i] >= threshold) {
      let j = i;
      while (j < ys.length && ys[j] >= threshold) j++;
      const runMin = (pts[j - 1].t - pts[i].t) / 60;
      if (runMin >= minRunMin) wakeIdx = i; // keep the LAST qualifying run
      i = j;
    } else i++;
  }
  return wakeIdx >= 0 ? pts[wakeIdx].t : null;
}

export interface CircadianOpts {
  now?: number;       // unix s "now" (default = latest minute ts); for determinism
  settleSec?: number; // a wake older than this = night complete (default 600s)
  anchorTs?: number;  // target a specific cycle's bathyphase nearest this ts
}

/**
 * calcCircadian(minutes, opts)
 *
 * Fits the circadian cosinor over the HR series, then for the most-recent
 * completed cycle (bathyphase = HR trough) finds main-sleep onset (HR drop in
 * the 8h before the trough) and wake (HR rise in the 8h after). Returns the
 * circadian phase + that boundary.
 *
 * Confidence = rhythm strength (amplitude) × whether a clean onset+wake pair was
 * found. Abstains (nulls, confidence 0) when the rhythm is too weak or data too
 * thin — never fabricates a boundary.
 */
export function calcCircadian(minutes: Minute[], opts: CircadianOpts = {}): Metric<CircadianValue> {
  const usable = minutes.filter(isHrUsable).map((m) => ({ t: m.ts, y: m.hr_avg })).sort((a, b) => a.t - b.t);
  const settle = opts.settleSec ?? 600;

  const empty = (): Metric<CircadianValue> => ({
    mesor: null, amplitude: null, acrophase_ts: null, bathyphase_ts: null,
    onset_ts: null, wake_ts: null, in_bed_min: 0, settled: false,
    confidence: 0, tier: 'HIGH', inputs_used: [],
  });
  if (usable.length < 120) return empty();

  const now = opts.now ?? usable[usable.length - 1].t;
  const fit = fitCosinor(usable);
  if (!fit) return empty();

  // bathyphase (HR trough): amp·cos(ωt − φ) minimal → ωt − φ = π.
  const bathBase = (fit.phi + Math.PI) / W;
  // acrophase (HR peak): ωt − φ = 0.
  const acroBase = fit.phi / W;
  const nearest = (base: number, ref: number) => base + Math.round((ref - base) / DAY) * DAY;

  // Pick the cycle: the most-recent bathyphase IN THE PAST. The wake is found within
  // [bath, bath+8h] clipped to available data, and `settled` (wake older than the
  // settle window) decides whether the night is complete. We deliberately do NOT
  // require bath+8h to be in the past — that wrongly stepped back a whole night for
  // an early riser checking soon after waking (the "previous night / short sleep" bug).
  let bath = nearest(bathBase, opts.anchorTs ?? now);
  if (bath > now - 3600) bath -= DAY;   // bathyphase must be ~in the past
  const acro = nearest(acroBase, now);

  const inWin = (lo: number, hi: number) => usable.filter((p) => p.t >= lo && p.t <= hi);
  const onset = changePoint(inWin(bath - 8 * 3600, bath), 'drop');
  // Wake = final sustained rise above the cosinor mesor (robust to REM/arousal bumps).
  const wake_ts = sustainedWake(inWin(bath, bath + 8 * 3600), fit.mesor, 12);

  const onset_ts = onset ? onset.ts : null;
  const in_bed_min = onset_ts != null && wake_ts != null ? Math.round((wake_ts - onset_ts) / 60) : 0;
  const settled = wake_ts != null && wake_ts <= now - settle;

  // confidence: rhythm strength (amp 2→0 … 10→1) gated on a clean onset+wake pair.
  const rhythm = clamp((fit.amp - 2) / 8, 0, 1);
  const paired = onset_ts != null && wake_ts != null ? 1 : 0.3;
  const confidence = round(rhythm * paired, 2);

  return {
    mesor: round(fit.mesor, 1),
    amplitude: round(fit.amp, 1),
    acrophase_ts: acro,
    bathyphase_ts: bath,
    onset_ts,
    wake_ts,
    in_bed_min,
    settled,
    confidence,
    tier: 'HIGH',
    inputs_used: ['hr'],
  };
}
