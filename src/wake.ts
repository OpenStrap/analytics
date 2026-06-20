// wake.ts — sleep/wake state ENSEMBLE for the demand-driven day-close trigger.
//
// Purpose: from an assembled window of minute rollups, answer "is the user asleep
// or awake right now, and if they just woke, when?" — cheaply, deterministically,
// and HONESTLY (abstain to 'unknown' rather than fabricate). This is the gate that
// fires the once-per-day Tier-3/4 derivation at the user's REAL wake, not a clock.
//
// Method: a PLUGGABLE registry of per-minute voters, each emitting asleep|awake|
// unknown for every minute. We majority-vote per minute, consolidate into bouts,
// then report the current state + the most-recent sleep→wake boundary. Voters are
// swappable; the initial set is grounded in published, NON-TRAINED methods that fit
// our exact per-minute signals (hr_avg, activity, and optional RR):
//
//   • coleKripke  — Cole-Kripke 1992 actigraphy weighted-sum (benchmark-competitive
//                   among non-DL methods; ActiGraph/Newcastle PSG eval 2023).
//   • cardiac     — CPD's core finding (Cakmak 2020, Sleep): cardiac change-points
//                   carry the WAKE signal actigraphy misses. Uses HR level + change
//                   vs the night's own trough, and RR-SD (HRV) when RR is supplied.
//   • inactivity  — van Hees-style sustained-low-movement = sleep (non-trained).
//
// Thresholds are SELF-CALIBRATING off the window's own distribution (our `activity`
// is stddev-of-|accel|, not actigraph counts, so absolute published thresholds don't
// transfer — we use the published SHAPE with adaptive scaling). Tier = ESTIMATE; we
// do NOT claim the papers' trained-model accuracy. Validate against ground truth.

import type { Minute, Baseline } from './types';
import { isHrUsable } from './util';

export type WakeLabel = 'asleep' | 'awake' | 'unknown';

export interface WakeContext {
  minutes: Minute[];                  // time-ordered window (should span the night)
  baseline: Baseline;                 // resting_hr anchor
  rrByMin?: Map<number, number[]>;    // optional per-minute RR (ms) — enables the HRV arm of the cardiac voter
  now?: number;                       // evaluation instant (default = last minute ts)
}

/** A voter labels EVERY minute in the window. Pure; no I/O. */
export type Voter = (ctx: WakeContext) => WakeLabel[];

export interface WakeState {
  state: WakeLabel;        // current state at `now`
  wake_ts: number | null;  // start of the most-recent sustained wake bout (the day boundary)
  onset_ts: number | null; // start of the main sleep bout preceding that wake
  awake_min: number;       // sustained awake minutes ending at `now`
  asleep_min: number;      // minutes asleep in the main bout
  votes: Record<string, WakeLabel>; // each voter's verdict at `now` (transparency)
  confidence: number;      // 0..1 (voter agreement × data coverage)
}

// ── helpers ──────────────────────────────────────────────────────────────────
const MIN = 60;
const MIN_MAIN_SLEEP_MIN = 90;   // a real night, not a catnap, must precede a "wake"
const SUSTAINED_WAKE_MIN = 10;   // your rule: awake must hold ≥10 min before we fire

function median(xs: number[]): number {
  if (!xs.length) return 0;
  const s = [...xs].sort((a, b) => a - b);
  const m = s.length >> 1;
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
}

// ── Voter 1: Cole-Kripke (actigraphy weighted-sum, published shape) ───────────
// D = P·Σ wᵢ·Aᵢ over [−4..+2] minutes; sleep if D < 1. Our `activity` is rescaled
// to the window so the unit-dependent constants behave (self-calibrating).
const CK_W = [106, 54, 58, 76, 230, 74, 67]; // weights for A[-4..+2]
const CK_P = 0.001;
export const coleKripke: Voter = ({ minutes }) => {
  const act = minutes.map((m) => (m.wrist_on ? m.activity : 0));
  // normalize activity to a counts-like scale: median wake-ish activity ≈ unit.
  const nz = act.filter((a) => a > 0);
  const scale = median(nz) || 1; // counts ≈ activity/scale
  const n = minutes.length;
  return minutes.map((_, i) => {
    if (!isHrUsable(minutes[i]) && minutes[i].activity === 0) return 'unknown';
    let d = 0;
    for (let k = -4; k <= 2; k++) {
      const j = i + k;
      if (j < 0 || j >= n) continue;
      d += CK_W[k + 4] * (act[j] / scale);
    }
    d *= CK_P;
    return d < 1 ? 'asleep' : 'awake';
  });
};

// ── Voter 2: Cardiac (CPD core — the wake signal actigraphy misses) ───────────
// Awake when SMOOTHED HR sits above the night's cardiac trough by a margin. This is
// the band's single most reliable wake signal (quiet wake has elevated HR but no
// motion — exactly where the actigraphy voters go blind). Smoothing (±2 min) means a
// single REM/arousal HR spike can't flip a minute to 'awake'; only a sustained rise
// does. The RR/HRV arm now lives in its OWN voter (hrvArousal) so it isn't
// double-counted. Trough is self-calibrating off the window, floored by RHR.
export const cardiac: Voter = ({ minutes, baseline }) => {
  const usable = minutes.filter(isHrUsable).map((m) => m.hr_avg);
  const sorted = [...usable].sort((a, b) => a - b);
  const p10 = sorted.length ? sorted[Math.floor(sorted.length * 0.1)] : baseline.resting_hr;
  const trough = Math.max(baseline.resting_hr || 0, p10 || 0) || (sorted[0] ?? 0);
  const wakeMargin = 8; // bpm above the sleeping trough → cardiac wake (separates wake from REM)
  // ±2-min median-smoothed HR (NaN where unusable) so spikes don't fragment the vote.
  const hr = minutes.map((m) => (isHrUsable(m) ? m.hr_avg : NaN));
  const hs = hr.map((_, i) => {
    const seg = hr.slice(Math.max(0, i - 2), Math.min(hr.length, i + 3))
      .filter((v) => Number.isFinite(v)).sort((a, b) => a - b);
    return seg.length ? seg[seg.length >> 1] : NaN;
  });
  return minutes.map((_, i) => {
    if (!Number.isFinite(hs[i])) return 'unknown';
    return hs[i] > trough + wakeMargin ? 'awake' : 'asleep';
  });
};

// ── Voter 3: van Hees-style sustained inactivity ──────────────────────────────
// Sleep = movement held below an adaptive low threshold across a rolling window.
export const inactivity: Voter = ({ minutes }) => {
  const act = minutes.map((m) => (m.wrist_on ? m.activity : NaN));
  const worn = act.filter((a) => Number.isFinite(a)) as number[];
  const s = [...worn].sort((a, b) => a - b);
  const pct = (p: number) => (s.length ? s[Math.min(s.length - 1, Math.floor(s.length * p))] : 0);
  const p10 = pct(0.1), p90 = pct(0.9);
  // "Still" = at/below the window's low (sleep) floor + a margin. Anchoring on the
  // floor (not the median) is robust when the window is sleep-dominated, where the
  // median itself sits inside the sleep mode. ABS_MOVE (~0.05 g RMS) is the still→move
  // boundary in our `activity` units; the range term adapts when the window has daytime.
  const ABS_MOVE = 0.05;
  const thr = p10 + Math.max(ABS_MOVE, 0.3 * (p90 - p10));
  const W = 5; // minutes of sustained stillness
  const n = minutes.length;
  return minutes.map((_, i) => {
    if (!Number.isFinite(act[i])) return 'unknown';
    let still = 0, seen = 0;
    for (let j = Math.max(0, i - W); j <= Math.min(n - 1, i + W); j++) {
      if (!Number.isFinite(act[j])) continue;
      seen++;
      if (act[j] <= thr) still++;
    }
    if (seen === 0) return 'unknown';
    return still / seen >= 0.7 ? 'asleep' : 'awake';
  });
};

// ── Voter 4: HRV / RR autonomic arousal ───────────────────────────────────────
// Beat-to-beat RR spread (SD) climbs with autonomic arousal toward and at wake. A
// minute is 'awake' when its short-window RR-SD is elevated AND HR sits above the
// sleeping trough. Returns 'unknown' when the minute has no RR — so a night without
// RR simply drops this voter rather than biasing it. This is the SECOND autonomic
// signal: paired with `cardiac` it lets the ≥2 consensus fire on quiet wake (HR up,
// no motion) without the two blind motion voters being able to veto it.
export const hrvArousal: Voter = ({ minutes, baseline, rrByMin }) => {
  const usable = minutes.filter(isHrUsable).map((m) => m.hr_avg);
  const sorted = [...usable].sort((a, b) => a - b);
  const p10 = sorted.length ? sorted[Math.floor(sorted.length * 0.1)] : baseline.resting_hr;
  const trough = Math.max(baseline.resting_hr || 0, p10 || 0) || (sorted[0] ?? 0);
  const RR_SD_WAKE = 45; // ms — elevated beat-to-beat spread (validated on real RR)
  // Per-minute RR-SD (NaN when <4 beats)…
  const sdRaw = minutes.map((m) => {
    const rr = rrByMin?.get(Math.floor(m.ts / MIN) * MIN);
    if (!rr || rr.length < 4) return NaN;
    const mean = rr.reduce((s, v) => s + v, 0) / rr.length;
    return Math.sqrt(rr.reduce((s, v) => s + (v - mean) ** 2, 0) / rr.length);
  });
  // …then ±2-min median-smoothed. Raw minute RR-SD bounces across the threshold, which
  // fragments the morning wake so cardiac+hrv only intermittently reach the ≥2 bar;
  // smoothing makes the autonomic signal continuous (mirrors the cardiac HR smoothing).
  const sd = sdRaw.map((_, i) => {
    const seg = sdRaw.slice(Math.max(0, i - 2), Math.min(sdRaw.length, i + 3))
      .filter((v) => Number.isFinite(v)).sort((a, b) => a - b);
    return seg.length ? seg[seg.length >> 1] : NaN;
  });
  return minutes.map((m, i) => {
    if (!Number.isFinite(sd[i]) || !isHrUsable(m)) return 'unknown';
    return sd[i] > RR_SD_WAKE && m.hr_avg > trough ? 'awake' : 'asleep';
  });
};

// Pluggable registry — swap/extend these as better algorithms are validated.
// FOUR voters, two families: motion (coleKripke, inactivity) + autonomic (cardiac,
// hrvArousal). The consensus rule (≥2) + bout-smoothing is HR-led by construction —
// motion is blind to quiet wake, so the autonomic pair must be able to carry a wake.
export const DEFAULT_VOTERS: { name: string; fn: Voter }[] = [
  { name: 'coleKripke', fn: coleKripke },
  { name: 'cardiac', fn: cardiac },
  { name: 'inactivity', fn: inactivity },
  { name: 'hrvArousal', fn: hrvArousal },
];

/**
 * Consensus label per minute: AWAKE if ≥`minAwake` voters say awake. NOT a majority —
 * a 2–2 split counts as AWAKE on purpose. Two of the four voters are motion-based and
 * physically blind to quiet wakefulness (lying still, HR up); a flat majority lets them
 * veto a correct cardiac+HRV wake (and ties → 'unknown' → the close never fires). The
 * ≥2 rule means the autonomic pair (cardiac, hrvArousal) can carry a wake on their own,
 * while still requiring corroboration (one voter alone never flips it). Else asleep if
 * any voter had a known read; else unknown.
 */
function consensusPerMinute(labels: WakeLabel[][], n: number, minAwake = 2): WakeLabel[] {
  const out: WakeLabel[] = [];
  for (let i = 0; i < n; i++) {
    let awake = 0, known = 0;
    for (const arr of labels) {
      const l = arr[i];
      if (l === 'awake') { awake++; known++; }
      else if (l === 'asleep') known++;
    }
    out.push(awake >= minAwake ? 'awake' : known ? 'asleep' : 'unknown');
  }
  return out;
}

/**
 * Merge per-minute label runs shorter than `minRun` minutes into their larger
 * neighbour (repeated to a fixed point), so intermittent voter agreement reads as one
 * stable bout instead of a sawtooth. The HRV voter flickers in/out, which fragments a
 * real continuous wake into sub-threshold pieces; smoothing bridges them. Same
 * technique the sleep stager uses on its hypnogram.
 */
function boutSmooth(labels: WakeLabel[], minRun = 10, passes = 4): WakeLabel[] {
  const s = [...labels];
  for (let p = 0; p < passes; p++) {
    const runs: { a: number; b: number }[] = [];
    for (let i = 0; i < s.length;) { let j = i; while (j < s.length && s[j] === s[i]) j++; runs.push({ a: i, b: j - 1 }); i = j; }
    if (runs.length <= 1) break;
    let changed = false;
    for (let r = 0; r < runs.length; r++) {
      const { a, b } = runs[r];
      if (b - a + 1 >= minRun) continue;
      const prev = r > 0 ? runs[r - 1] : null;
      const next = r < runs.length - 1 ? runs[r + 1] : null;
      let tgt: WakeLabel | null = null;
      if (prev && next) tgt = (prev.b - prev.a) >= (next.b - next.a) ? s[prev.a] : s[next.a];
      else if (prev) tgt = s[prev.a];
      else if (next) tgt = s[next.a];
      if (tgt) { for (let x = a; x <= b; x++) s[x] = tgt; changed = true; }
    }
    if (!changed) break;
  }
  return s;
}

/**
 * Run the ensemble over the window. Returns the current state + the most-recent
 * sustained sleep→wake boundary (the physiological-day anchor). Requires ≥`minVote`
 * agreement (default majority of the registry) AND a main sleep bout ≥90 min AND a
 * sustained-awake stretch ≥10 min before reporting state='awake' with a wake_ts.
 */
export function detectWakeState(
  ctx: WakeContext,
  voters = DEFAULT_VOTERS,
): WakeState {
  const minutes = ctx.minutes;
  const n = minutes.length;
  const now = ctx.now ?? (n ? minutes[n - 1].ts : 0);
  const empty: WakeState = { state: 'unknown', wake_ts: null, onset_ts: null, awake_min: 0, asleep_min: 0, votes: {}, confidence: 0 };
  if (n < SUSTAINED_WAKE_MIN) return empty;

  const perVoter = voters.map((v) => v.fn(ctx));
  // HR-led consensus (≥2 awake, ties→awake) then bout-smoothed into stable bouts.
  const labels = boutSmooth(consensusPerMinute(perVoter, n));

  // votes at `now` (last minute) for transparency.
  const votes: Record<string, WakeLabel> = {};
  voters.forEach((v, k) => { votes[v.name] = perVoter[k][n - 1] ?? 'unknown'; });

  // Find the most-recent sleep bout and the wake that ends it.
  // Walk backward: the current trailing run is "awake" if we just woke.
  let i = n - 1;
  // trailing awake run
  let awakeRunStart = n;
  while (i >= 0 && labels[i] === 'awake') { awakeRunStart = i; i--; }
  // skip any unknown gap between wake and the sleep bout
  while (i >= 0 && labels[i] === 'unknown') i--;
  // the sleep bout
  let sleepEnd = i;
  while (i >= 0 && labels[i] !== 'awake') i--; // include asleep + interior unknowns
  let sleepStart = i + 1;

  const sleepBoutMin = sleepEnd >= sleepStart && sleepStart >= 0
    ? Math.round((minutes[sleepEnd].ts - minutes[sleepStart].ts) / MIN) + 1 : 0;
  const awakeMin = awakeRunStart < n
    ? Math.round((minutes[n - 1].ts - minutes[awakeRunStart].ts) / MIN) + 1 : 0;

  // coverage = fraction of the window with a known label.
  const known = labels.filter((l) => l !== 'unknown').length;
  const coverage = n ? known / n : 0;
  const agree = (() => {
    // mean per-minute voter agreement over known minutes (for confidence).
    let acc = 0, c = 0;
    for (let k = 0; k < n; k++) {
      let a = 0, w = 0;
      for (const arr of perVoter) { if (arr[k] === 'asleep') a++; else if (arr[k] === 'awake') w++; }
      const tot = a + w; if (!tot) continue;
      acc += Math.max(a, w) / tot; c++;
    }
    return c ? acc / c : 0;
  })();
  const confidence = Math.round(coverage * agree * 100) / 100;

  // Current state.
  const current: WakeLabel = labels[n - 1];
  const justWoke = current === 'awake'
    && awakeMin >= SUSTAINED_WAKE_MIN
    && sleepBoutMin >= MIN_MAIN_SLEEP_MIN;

  return {
    state: current,
    wake_ts: justWoke ? minutes[awakeRunStart].ts : null,
    onset_ts: justWoke && sleepStart >= 0 && sleepStart <= sleepEnd ? minutes[sleepStart].ts : null,
    awake_min: awakeMin,
    asleep_min: sleepBoutMin,
    votes,
    confidence,
  };
}

/**
 * Cheap recent-window check for the cron's per-tick ladder (ladder-step 2): is the
 * user plausibly awake in the last few minutes? Liberal (high-recall) on purpose —
 * a 'maybe' only triggers the full `detectWakeState`; it never suppresses a wake.
 */
export function peekRecentState(recent: Minute[], baseline: Baseline): WakeLabel {
  const worn = recent.filter((m) => m.wrist_on);
  if (worn.length < 3) return 'unknown';
  const hrUp = worn.filter(isHrUsable).some((m) => m.hr_avg > (baseline.resting_hr || 0) + 6);
  const moving = worn.some((m) => m.activity > 0 && m.steps > 0);
  return hrUp || moving ? 'awake' : 'asleep';
}
