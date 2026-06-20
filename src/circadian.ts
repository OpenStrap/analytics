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
import { isHrUsable, clamp, round, percentile } from './util';
import { cleanRr } from './hrv';

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

/** Per-minute RMSSD (ms) from a (raw) RR stream; null if too few beats to be
 *  meaningful. Cleans physiological + ectopic artifacts first (shared `cleanRr`). */
function minuteRmssd(rr: number[] | undefined): number | null {
  if (!rr || rr.length < 12) return null;
  const c = cleanRr(rr);
  if (c.length < 10) return null;
  let s = 0;
  for (let i = 1; i < c.length; i++) { const d = c[i] - c[i - 1]; s += d * d; }
  return Math.sqrt(s / (c.length - 1));
}

/** Median of finite values; null if none. */
function medOf(xs: (number | null)[]): number | null {
  const a = xs.filter((x): x is number => x != null && Number.isFinite(x)).sort((p, q) => p - q);
  return a.length ? a[a.length >> 1] : null;
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
 * Single mean-shift change-point in a window, constrained to a direction ('drop' =
 * onset, HR falls). Maximises the SSE reduction of a 2-segment split — i.e. the
 * STRONGEST drop, which for the pre-bathyphase window is the evening→sleep onset
 * (bigger than any quiet-evening dip). null if the window is too thin.
 */
function changePoint(pts: Pt[], want: 'drop' | 'rise'): number | null {
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
  let best: { gain: number; tau: number } | null = null;
  for (let tau = MIN; tau < n - MIN; tau++) {
    const d = (pre[n] - pre[tau]) / (n - tau) - pre[tau] / tau; // +ve = rise
    if (want === 'rise' && d <= 0) continue;
    if (want === 'drop' && d >= 0) continue;
    const gain = total - (sse(0, tau) + sse(tau, n));
    if (!best || gain > best.gain) best = { gain, tau };
  }
  return best ? pts[best.tau].t : null;
}

/**
 * Main sleep period. ONSET = the strongest HR drop in [bath−8h, bath] (the
 * evening→sleep fall; robust to quiet sedentary evenings that a below-mesor run
 * would wrongly absorb). WAKE = the end of the consolidated below-MESOR run
 * extending forward from the bathyphase, bridging interior >mesor bumps ≤ BRIDGE
 * min (REM/arousal) and ending at the morning rise that persists (daytime). Mesor
 * is the cosinor midline — sleep below, wake above — so it doesn't cut through
 * high-sleeping-HR users' light sleep. Returns onset/wake, or null.
 */
function mainSleepPeriod(pts: Pt[], bath: number, mesor: number): { onset: number; wake: number } | null {
  const n = pts.length;
  if (n < 30) return null;
  const ys = smooth(pts.map((p) => p.y), 5);
  const asleep = ys.map((v) => v < mesor);
  // anchor = index nearest the bathyphase
  let a = 0;
  for (let i = 1; i < n; i++) if (Math.abs(pts[i].t - bath) < Math.abs(pts[a].t - bath)) a = i;
  const BRIDGE = 60 * 60;
  // wake: walk forward from anchor, bridging >mesor gaps ≤ BRIDGE; stop at a long one.
  let end = a;
  for (let i = a + 1; i < n;) {
    if (asleep[i]) { end = i; i++; continue; }
    let k = i; while (k < n && !asleep[k]) k++;
    if (pts[(k < n ? k : n) - 1].t - pts[i].t > BRIDGE) break;
    i = k;
  }
  // onset: strongest evening→sleep drop; fall back to the below-mesor run start.
  let start = a;
  for (let i = a - 1; i >= 0;) {
    if (asleep[i]) { start = i; i--; continue; }
    let k = i; while (k >= 0 && !asleep[k]) k--;
    if (pts[i].t - pts[k + 1].t > BRIDGE) break;
    i = k;
  }
  const onsetCp = changePoint(pts.filter((p) => p.t >= bath - 8 * 3600 && p.t <= bath), 'drop');
  const onset = onsetCp != null && onsetCp >= pts[start].t ? onsetCp : pts[start].t;
  return { onset, wake: pts[end].t };
}

export interface SleepStaging {
  in_bed_min: number; asleep_min: number; efficiency: number;
  awake_min: number; light_min: number; deep_min: number; rem_min: number;
  hypnogram: { t: number; stage: 'awake' | 'light' | 'deep' | 'rem' }[];
}

/**
 * The ONE sleep stager (ESTIMATE/beta). Classifies every minute in [onset, wake]
 * into awake / light / deep / rem, then returns BOTH the per-minute hypnogram AND the
 * reconciled totals — so the graph and the stage breakdown can never disagree (the
 * previous bug: two different classifiers).
 *
 * TWO AXES:
 *   • HR LEVEL — sets WAKE (sustained ≥20 min elevation, or off-wrist) and the
 *     overall depth ordering.
 *   • RR/HRV AUTONOMIC (when per-minute `rr` is present) — separates DEEP from REM,
 *     which HR level CANNOT do on calm nights (REM-HR ≈ light-HR). Deep/SWS = high
 *     parasympathetic tone → HIGH beat-to-beat variability (RMSSD) + lowest HR; REM =
 *     parasympathetic withdrawal → REDUCED RMSSD + mildly elevated HR (verified on real
 *     nights: corr(HR,RMSSD) ≈ −0.4, and a pure-HR stager read REM ≈ 0%). Thresholds are
 *     RATIOS to the night's asleep-RMSSD median, so they self-calibrate per user:
 *        deep = RMSSD ≥ 1.15·median  AND  HR ≤ asleep-HR-median
 *        rem  = RMSSD ≤ 0.88·median  (asleep, below wake)
 *        light = everything else (the broad majority).
 *   • Without usable RR we fall back to the legacy HR-only bands (graceful, honest —
 *     such nights just can't resolve REM, rather than fabricate it).
 * asleep = light+deep+rem; efficiency = asleep / in-bed.
 */
export function stageSleep(
  minutes: { ts: number; hr_avg: number; rr?: number[] }[], onset: number, wake: number, mesor: number,
): SleepStaging {
  const inBed = Math.max(1, Math.round((wake - onset) / 60));
  const win = minutes.filter((m) => m.ts >= onset && m.ts <= wake).sort((a, b) => a.ts - b.ts);
  const empty: SleepStaging = {
    in_bed_min: inBed, asleep_min: 0, efficiency: 0, awake_min: inBed,
    light_min: 0, deep_min: 0, rem_min: 0, hypnogram: [],
  };
  const worn = win.filter((m) => m.hr_avg > 0);
  if (worn.length < 5) return empty;
  const hrs = worn.map((m) => m.hr_avg);
  const floor = percentile(hrs, 10) ?? Math.min(...hrs);
  const span = Math.max(1, mesor - floor);
  // Light-dominant bands (HR-only stages_beta): deep = only the lowest HR, rem = a
  // narrow elevated band just below wake, light = the broad middle (most of sleep).
  const tAwake = Math.max(floor + 10, floor + 0.70 * span);
  // REM = the broad "elevated-but-asleep" band below wake. Anchored at 0.40·span (was
  // 0.60, which sat just under tAwake → a 2-3 bpm sliver that almost never triggered,
  // so REM read ~0 on calm nights). REM's HR is only modestly above light, not 60% of
  // the way to the daytime mesor — 0.40 puts the band where REM actually lives.
  const tRem = floor + 0.40 * span;
  const tDeep = floor + 0.12 * span;

  // smoothed HR aligned to `win` (off-wrist minutes carry hr 0 → forced awake)
  const ys = smooth(win.map((m) => (m.hr_avg > 0 ? m.hr_avg : tAwake + 50)), 5);

  // ── Autonomic axis: per-minute RMSSD (smoothed ±2), and the night's asleep
  // RMSSD/HR medians as self-calibrating references. Only used if a real fraction of
  // the asleep minutes carry enough RR — else deep/rem stay on the HR-only fallback. ──
  const rmRaw = win.map((m) => minuteRmssd(m.rr));
  const rmS = rmRaw.map((_, i) => {
    const seg: (number | null)[] = [];
    for (let j = Math.max(0, i - 2); j < Math.min(win.length, i + 3); j++) seg.push(rmRaw[j]);
    return medOf(seg);
  });
  const asleepI = win.map((_, i) => i).filter((i) => win[i].hr_avg > 0 && ys[i] < tAwake);
  const rmRef = medOf(asleepI.map((i) => rmS[i]));
  const hrRef = medOf(asleepI.map((i) => ys[i]));
  const rrUsable = rmRef != null && hrRef != null
    && asleepI.filter((i) => rmS[i] != null).length >= Math.max(20, Math.floor(asleepI.length * 0.4));
  const DEEP_R = 1.15, REM_R = 0.88; // RMSSD ratios vs asleep median (tuned on real RR: REM≈21%, deep≈13%)

  const stage: ('awake' | 'light' | 'deep' | 'rem')[] = new Array(win.length).fill('light');
  // pass 1: provisional per-minute classes
  for (let k = 0; k < win.length; k++) {
    if (win[k].hr_avg <= 0) { stage[k] = 'awake'; continue; }
    const v = ys[k];
    if (v >= tAwake) { stage[k] = 'awake'; continue; }
    if (rrUsable && rmS[k] != null) {
      // RR present → autonomic deep/rem split (the REM-detecting path).
      const rm = rmS[k]!;
      stage[k] = (rm >= DEEP_R * rmRef! && v <= hrRef!) ? 'deep'
        : (rm <= REM_R * rmRef!) ? 'rem'
        : 'light';
    } else {
      // No usable RR this minute/night → legacy HR-level bands.
      stage[k] = v < tDeep ? 'deep' : v >= tRem ? 'rem' : 'light';
    }
  }
  // pass 2: an "awake" minute only counts as awake if part of a SUSTAINED (≥20 min)
  // run; otherwise it's a brief REM/arousal bump → reclassify as rem.
  let k = 0;
  while (k < win.length) {
    if (stage[k] === 'awake' && win[k].hr_avg > 0) {
      let j = k; while (j < win.length && stage[j] === 'awake' && win[j].hr_avg > 0) j++;
      if ((win[j - 1].ts - win[k].ts) / 60 < 20) for (let x = k; x < j; x++) stage[x] = 'rem';
      k = j;
    } else k++;
  }
  // pass 3: BOUT-SMOOTHING — the per-minute classes flicker when HR hovers near a
  // threshold (sawtooth hypnogram). Merge any run shorter than MIN_BOUT minutes into
  // its longer neighbour, repeatedly, so the hypnogram reads as stable sleep bouts
  // (real stages last many minutes). Awake keeps a higher floor so a genuine short
  // awakening survives; sub-floor awakes are noise → absorbed into surrounding sleep.
  const MIN_BOUT = 6, MIN_AWAKE_BOUT = 10;
  for (let iter = 0; iter < 4; iter++) {
    const runs: { s: number; e: number }[] = [];
    for (let i = 0; i < win.length;) { let j = i; while (j < win.length && stage[j] === stage[i]) j++; runs.push({ s: i, e: j - 1 }); i = j; }
    if (runs.length <= 1) break;
    let changed = false;
    for (let r = 0; r < runs.length; r++) {
      const { s, e } = runs[r];
      const lenMin = e - s + 1;
      const floorMin = stage[s] === 'awake' ? MIN_AWAKE_BOUT : MIN_BOUT;
      if (lenMin >= floorMin) continue;
      const prev = r > 0 ? runs[r - 1] : null;
      const next = r < runs.length - 1 ? runs[r + 1] : null;
      let target: typeof stage[number] | null = null;
      if (prev && next) target = (prev.e - prev.s) >= (next.e - next.s) ? stage[prev.s] : stage[next.s];
      else if (prev) target = stage[prev.s];
      else if (next) target = stage[next.s];
      if (target) { for (let x = s; x <= e; x++) stage[x] = target; changed = true; }
    }
    if (!changed) break;
  }
  let light = 0, deep = 0, rem = 0, awake = 0;
  for (const s of stage) { if (s === 'awake') awake++; else if (s === 'deep') deep++; else if (s === 'rem') rem++; else light++; }
  const asleep = light + deep + rem;
  return {
    in_bed_min: inBed, asleep_min: asleep, efficiency: clamp(asleep / inBed, 0, 1),
    awake_min: awake, light_min: light, deep_min: deep, rem_min: rem,
    hypnogram: win.map((m, idx) => ({ t: m.ts, stage: stage[idx] })),
  };
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
  // No detectable circadian rhythm (flat HR) → abstain, never fabricate a boundary.
  if (fit.amp < 3) return empty();

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
  // Consolidated main-sleep period around the bathyphase (handles REM bumps + daytime).
  const period = mainSleepPeriod(inWin(bath - 8 * 3600, bath + 10 * 3600), bath, fit.mesor);
  const onset_ts = period ? period.onset : null;
  const wake_ts = period ? period.wake : null;
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
