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
// Awake when HR sits above the night's cardiac trough by a margin, OR a sustained
// upward HR change-point fires. When RR is supplied, a rise in short-window RR-SD
// (HRV climbs toward/at wake) reinforces 'awake'. Self-calibrating off the window.
export const cardiac: Voter = ({ minutes, baseline, rrByMin }) => {
  const usable = minutes.filter(isHrUsable).map((m) => m.hr_avg);
  // cardiac trough: low percentile of the window's HR (sleeping HR), floored by RHR.
  const sorted = [...usable].sort((a, b) => a - b);
  const p10 = sorted.length ? sorted[Math.floor(sorted.length * 0.1)] : baseline.resting_hr;
  const trough = Math.max(baseline.resting_hr || 0, p10 || 0) || (sorted[0] ?? 0);
  const wakeMargin = 6; // bpm above the sleeping trough → cardiac wake
  return minutes.map((m) => {
    if (!isHrUsable(m)) return 'unknown';
    let vote: WakeLabel = m.hr_avg > trough + wakeMargin ? 'awake' : 'asleep';
    // RR/HRV arm: a populated, healthy RR-SD that's elevated supports 'awake'.
    const rr = rrByMin?.get(Math.floor(m.ts / MIN) * MIN);
    if (rr && rr.length >= 4) {
      const mean = rr.reduce((s, v) => s + v, 0) / rr.length;
      const sd = Math.sqrt(rr.reduce((s, v) => s + (v - mean) ** 2, 0) / rr.length);
      if (sd > 80 && m.hr_avg > trough) vote = 'awake'; // high beat-to-beat variability + above trough
    }
    return vote;
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

// Pluggable registry — swap/extend these as better algorithms are validated.
export const DEFAULT_VOTERS: { name: string; fn: Voter }[] = [
  { name: 'coleKripke', fn: coleKripke },
  { name: 'cardiac', fn: cardiac },
  { name: 'inactivity', fn: inactivity },
];

/** Majority label per minute across voters (unknown ignored; tie → unknown). */
function majorityPerMinute(labels: WakeLabel[][], n: number): WakeLabel[] {
  const out: WakeLabel[] = [];
  for (let i = 0; i < n; i++) {
    let asleep = 0, awake = 0, known = 0;
    for (const arr of labels) {
      const l = arr[i];
      if (l === 'asleep') { asleep++; known++; }
      else if (l === 'awake') { awake++; known++; }
    }
    if (known === 0) out.push('unknown');
    else if (asleep > awake) out.push('asleep');
    else if (awake > asleep) out.push('awake');
    else out.push('unknown');
  }
  return out;
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
  const labels = majorityPerMinute(perVoter, n);

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
