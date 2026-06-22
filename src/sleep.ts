// §5 Sleep — Cole-Kripke actigraphy + HR-dip fusion. Tier HIGH (duration/eff),
// ESTIMATE (stages). One-minute epochs.
import type {
  Minute, Baseline, Metric, SleepValue, SleepStages,
  SleepPeriod, SleepPeriodsValue,
} from './types';
import { isHrUsable, mean, round } from './util';
import { cleanRr } from './hrv';

// Cole-Kripke weights over window [-4..+2].
const CK_W = [1.06, 0.54, 0.58, 0.76, 2.3, 0.74, 0.67];

/** Per-minute RMSSD (ms) from a raw RR stream; null if too few clean beats. */
function minuteRmssd(rr: number[] | undefined): number | null {
  if (!rr || rr.length < 12) return null;
  const c = cleanRr(rr);
  if (c.length < 10) return null;
  let s = 0;
  for (let i = 1; i < c.length; i++) { const d = c[i] - c[i - 1]; s += d * d; }
  return Math.sqrt(s / (c.length - 1));
}
function medOfNullable(xs: (number | null)[]): number | null {
  const a = xs.filter((x): x is number => x != null && Number.isFinite(x)).sort((p, q) => p - q);
  return a.length ? a[a.length >> 1] : null;
}
const REM_RMSSD_FACTOR = 0.90; // high-HR minute with smoothed RMSSD < 0.90×asleep-median = REM, not wake

/**
 * calcSleep(minutes, baseline)
 *
 * Per 1-min epoch: S = 0.001 * Σ W_i * A_i over window [−4..+2] with
 *   W = [1.06,0.54,0.58,0.76,2.30,0.74,0.67]; asleep = S < 1.
 * HR-dip fusion: hr_avg < 0.95*RHR nudges toward asleep; clearly elevated HR
 *   (> 1.15*RHR) nudges awake. RHR is the 5th-PERCENTILE sleep HR (a floor), and
 *   normal REM HR legitimately runs >10% above that floor, so the awake-override
 *   margin must clear REM — 1.10 would mis-flag REM epochs as awake and fragment
 *   the night.
 * Main sleep = the longest CONSOLIDATED period (asleep epochs joined only across
 *   short interior awake gaps ≤20 min; a longer awake stretch ends the period).
 *   NOT first-asleep→last-asleep across the whole night window — that would let
 *   evening/morning low-activity minutes bridge into a giant span. A 14h
 *   plausibility cap re-segments with a tighter gap if the period is too long.
 *   duration = asleep minutes; efficiency = asleep / in-bed span of that period.
 * Stages (BETA): deep = very low activity + lowest HR; REM = low activity + HR
 *   variability up; else light.
 *
 * Confidence formula: (#inputs present among {hr,activity,temp}/3) × coverage,
 *   where coverage = clamp(in_bed_min/240, 0, 1) so a full ~4h needs to clear >0.5.
 */
export function calcSleep(minutes: Minute[], baseline: Baseline): Metric<SleepValue> {
  const sorted = [...minutes].sort((a, b) => a.ts - b.ts);
  const n = sorted.length;

  const empty = (): Metric<SleepValue> => ({
    onset_ts: null,
    wake_ts: null,
    duration_min: 0,
    in_bed_min: 0,
    efficiency: 0,
    stages: null,
    stages_beta: true,
    confidence: 0,
    tier: 'HIGH',
    inputs_used: [],
  });
  if (n === 0) return empty();

  const rhr = baseline.resting_hr;
  // Cole–Kripke + HR-dip fusion is anchored on resting HR; without a real
  // baseline (null/0 for a brand-new user) the dip comparisons degrade to
  // garbage (everything reads "awake"). Abstain until we have one.
  if (rhr == null || rhr <= 0) return empty();

  // Per-window sleep-HR reference for the HR-dip awake override.
  //
  // The band's flash record (R24, the entire overnight) carries NO usable
  // actigraphy — its accel is a single 1 Hz gravity sample, so per-minute
  // `activity` reads ~0 and the Cole-Kripke score never clears its count-scaled
  // S<1 threshold. The awake/asleep call is therefore HR-driven in practice.
  // Anchoring "elevated → awake" to `rhr` is WRONG, because `rhr` is the
  // 5th-PERCENTILE sleep HR (a floor): normal/REM sleep HR legitimately runs
  // 20–40% above that floor, so a fixed 1.15*rhr cutoff flags almost every real
  // sleep minute awake (observed: 167/168 worn minutes on a real night, RHR 58 →
  // 67 bpm cutoff vs a 66–94 bpm sleeping band → 1-minute "sleep"). Instead anchor
  // the cutoff to THIS window's own depressed-HR level (a low percentile of worn
  // HR), with `rhr` as a floor so a window that is genuinely all-awake can't
  // manufacture a low reference. Percentiles are robust to the high-HR
  // evening/morning tail that shares the search window.
  const wornHr = sorted
    .filter((m) => m.wrist_on && m.hr_avg > 0)
    .map((m) => m.hr_avg)
    .sort((a, b) => a - b);
  const pctl = (p: number) =>
    wornHr.length ? wornHr[Math.min(wornHr.length - 1, Math.floor(p * wornHr.length))] : rhr;
  const sleepHr = Math.max(rhr, pctl(0.10)); // the quiet sleep-HR level for this window
  const ASLEEP_HI = 1.05; // ≤ this × sleepHr → strong dip, nudge asleep
  const AWAKE_HI = 1.20;  // > this × sleepHr → clearly elevated, nudge awake (clears REM)
  // Absolute backstop: HR at/above this × the RHR floor reads awake REGARDLESS of the
  // window. Without it, a flat + motion-inert window anchors sleepHr to its own level and
  // every minute falls under ASLEEP_HI*sleepHr → a sedentary-awake stretch (TV, desk)
  // would be mis-read as a full night. Real sleep, including REM, rarely SUSTAINS >1.5×
  // the 5th-percentile RHR floor, so this clips the false-positive without clipping sleep.
  // (The proper tie-breaker is actigraphy; R24 carries none today — see decode note.)
  const ABS_WAKE = 1.5;

  // 1. Cole-Kripke score + HR-dip fusion → boolean asleep per epoch.
  const asleep: boolean[] = new Array(n).fill(false);
  for (let i = 0; i < n; i++) {
    let s = 0;
    // window offsets -4..+2 align with weights index 0..6
    for (let k = 0; k < CK_W.length; k++) {
      const off = k - 4; // -4..+2
      const idx = i + off;
      if (idx >= 0 && idx < n) s += CK_W[k] * sorted[idx].activity;
    }
    s *= 0.001;
    const m = sorted[i];
    // Off-wrist epochs carry NO sleep signal (activity reads 0, no HR). They must
    // NOT default to asleep just because Cole-Kripke on activity=0 scores < 1 —
    // otherwise a long daytime off-wrist stretch (band on charger / removed)
    // bridges the gap-tolerant period across hours of non-sleep. Treat unknown as
    // awake so it acts as a period boundary; real interior brief off-wrist blips
    // are still absorbed by the ≤MAX_GAP_MIN bridging in step 2.
    if (!m.wrist_on) { asleep[i] = false; continue; }
    let isAsleep = s < 1;
    // HR-dip fusion (only when we have a usable HR reading).
    if (m.hr_avg > 0) {
      if (m.hr_avg > ABS_WAKE * rhr) isAsleep = false; // absolute backstop → awake regardless
      else if (m.hr_avg <= ASLEEP_HI * sleepHr) isAsleep = true; // at/below the sleep level → asleep
      else if (m.hr_avg > AWAKE_HI * sleepHr) isAsleep = false; // clearly elevated → awake
    }
    asleep[i] = isAsleep;
  }

  // 2. Main consolidated sleep period. We DON'T take first-asleep→last-asleep
  //    across the whole local-night window — that lets evening wind-down and
  //    morning-in-bed minutes (which can read as low-activity) bridge into one
  //    giant block spanning most of the ~18h window. Instead we segment the
  //    night into CONSOLIDATED periods: a period grows over asleep epochs and
  //    over SHORT interior awake gaps (≤ MAX_GAP_MIN, real awakenings are brief),
  //    but a longer contiguous awake stretch ENDS the period (out-of-bed /
  //    separate nap / wind-down). The main sleep = the longest such consolidated
  //    period, trimmed to its first/last asleep epoch so a trailing gap isn't
  //    counted as in-bed. Interior short awakenings stay inside and count
  //    against efficiency.
  const MAX_GAP_MIN = 20; // an awake gap longer than this ends the period

  let bestStart = -1;
  let bestEnd = -1;
  let bestAsleep = 0;
  // current consolidated period, tracked by its first/last ASLEEP epoch.
  let periodFirst = -1; // first asleep epoch of the current period
  let periodLast = -1;  // last asleep epoch seen in the current period
  let periodAsleep = 0; // asleep-epoch count in the current period
  let gap = 0;          // consecutive awake epochs since the last asleep epoch

  const closePeriod = () => {
    // score by asleep-epoch count (the consolidated block's actual sleep).
    if (periodFirst >= 0 && periodAsleep > bestAsleep) {
      bestAsleep = periodAsleep;
      bestStart = periodFirst;
      bestEnd = periodLast;
    }
    periodFirst = -1;
    periodLast = -1;
    periodAsleep = 0;
    gap = 0;
  };

  for (let i = 0; i < n; i++) {
    if (asleep[i]) {
      if (periodFirst < 0) periodFirst = i;
      periodLast = i;
      periodAsleep++;
      gap = 0;
    } else if (periodFirst >= 0) {
      // inside a period — tolerate a short awake gap, else close it.
      if (++gap > MAX_GAP_MIN) closePeriod();
    }
  }
  closePeriod();

  if (bestStart < 0 || bestAsleep === 0) return empty();

  let startIdx = bestStart;
  let endIdx = bestEnd;

  // 2a. Plausibility guard. A single main-sleep period spanning more than
  //     MAX_SLEEP_MIN is implausible — it means low-activity non-sleep time
  //     (daytime sedentary / off-wrist) is being merged in. Tighten the gap
  //     bound and re-segment; the shorter bound severs the spurious bridges so
  //     the true night survives as the longest consolidated period.
  const MAX_SLEEP_MIN = 14 * 60; // 14h hard ceiling on one main-sleep period
  if (endIdx - startIdx + 1 > MAX_SLEEP_MIN) {
    for (const tighter of [10, 5, 2]) {
      let bs = -1, be = -1, ba = 0;
      let pf = -1, pl = -1, pa = 0, g = 0;
      const close = () => {
        if (pf >= 0 && pa > ba) { ba = pa; bs = pf; be = pl; }
        pf = -1; pl = -1; pa = 0; g = 0;
      };
      for (let i = 0; i < n; i++) {
        if (asleep[i]) { if (pf < 0) pf = i; pl = i; pa++; g = 0; }
        else if (pf >= 0) { if (++g > tighter) close(); }
      }
      close();
      if (bs >= 0 && be - bs + 1 <= MAX_SLEEP_MIN) { startIdx = bs; endIdx = be; break; }
      // keep the tightest attempt even if still over, so we never fall back to
      // the giant span.
      if (bs >= 0) { startIdx = bs; endIdx = be; }
    }
    // Last resort: if even the tightest re-segmentation can't get under the
    // ceiling (a genuinely uninterrupted block with no awake epoch to split on —
    // implausible for real sleep), hard-clamp to MAX_SLEEP_MIN from the onset so
    // we never report a >14h "night".
    if (endIdx - startIdx + 1 > MAX_SLEEP_MIN) endIdx = startIdx + MAX_SLEEP_MIN - 1;
  }

  const onset_ts = sorted[startIdx].ts;
  const wake_ts = sorted[endIdx].ts;

  // in-bed span = first-asleep → last-asleep epoch inclusive (epoch count).
  const inBedEpochs = sorted.slice(startIdx, endIdx + 1);
  const in_bed_min = inBedEpochs.length;
  // asleep minutes within the span; interior awake epochs reduce efficiency.
  let duration_min = 0;
  for (let i = startIdx; i <= endIdx; i++) if (asleep[i]) duration_min++;
  const efficiency = in_bed_min > 0 ? duration_min / in_bed_min : 0;

  // 3. Stages (BETA/ESTIMATE) over the asleep epochs within main sleep.
  const sleepEpochs = inBedEpochs.filter((_, i) => asleep[startIdx + i]);
  const stages = estimateStages(sleepEpochs, rhr);

  // 4. Confidence: input completeness × coverage.
  const hasHr = inBedEpochs.some((m) => m.wrist_on && m.hr_avg > 0);
  const hasActivity = inBedEpochs.some((m) => m.activity > 0);
  const hasTemp = baseline.skin_temp != null;
  const present = [hasHr, hasActivity, hasTemp].filter(Boolean).length;
  const inputCompleteness = present / 3;
  const coverage = Math.min(1, in_bed_min / 240);
  const confidence = inputCompleteness * coverage;

  const inputs_used: string[] = ['activity'];
  if (hasHr) inputs_used.push('hr_avg');
  if (hasTemp) inputs_used.push('baseline.skin_temp');

  return {
    onset_ts,
    wake_ts,
    duration_min,
    in_bed_min,
    efficiency: round(efficiency, 4),
    stages,
    stages_beta: true,
    confidence: round(confidence, 4),
    tier: 'HIGH',
    inputs_used,
  };
}

/**
 * calcSleepPeriods(minutes, baseline)  —  Sleep v2 (multi-period)
 *
 * Same epoch scorer + consolidation as calcSleep, but instead of keeping only the
 * single longest period we return EVERY consolidated sleep period in the window.
 * A nap is not a special case — it's just a shorter sleep. Slept once → one
 * period; napped twice → three periods total; the UI renders one card each.
 *
 * Each period carries its own full breakdown (onset/wake/duration/efficiency/
 * stages) and its own confidence. The longest period is flagged `is_main` purely
 * as a UI hint; the data treats all periods identically.
 *
 * Per-period confidence = input_completeness × clamp(in_bed_min/90, 0, 1) — a ~90
 * min block reaches full coverage, so a genuine 40-min nap isn't unfairly crushed
 * the way the 240-min night-coverage of calcSleep would crush it.
 *
 * Periods with fewer than MIN_PERIOD_MIN asleep minutes are discarded (micro-dozes
 * aren't sleep). The top-level Metric.confidence mirrors the main period.
 */
export function calcSleepPeriods(minutes: Minute[], baseline: Baseline): Metric<SleepPeriodsValue> {
  const sorted = [...minutes].sort((a, b) => a.ts - b.ts);
  const n = sorted.length;
  const rhr = baseline.resting_hr;

  const empty = (): Metric<SleepPeriodsValue> => ({
    periods: [],
    total_asleep_min: 0,
    main_idx: null,
    stages_beta: true,
    confidence: 0,
    tier: 'HIGH',
    inputs_used: [],
  });
  if (n === 0) return empty();
  if (rhr == null || rhr <= 0) return empty(); // need a resting-HR baseline (see calcSleep)

  // 1. Per-epoch asleep — identical scorer to calcSleep (duplicated here on
  //    purpose so v1 stays byte-for-byte untouched).
  const asleep: boolean[] = new Array(n).fill(false);
  for (let i = 0; i < n; i++) {
    let s = 0;
    for (let k = 0; k < CK_W.length; k++) {
      const off = k - 4;
      const idx = i + off;
      if (idx >= 0 && idx < n) s += CK_W[k] * sorted[idx].activity;
    }
    s *= 0.001;
    const m = sorted[i];
    if (!m.wrist_on) { asleep[i] = false; continue; }
    let isAsleep = s < 1;
    if (m.hr_avg > 0) {
      if (m.hr_avg < 0.95 * rhr) isAsleep = true;
      else if (m.hr_avg > 1.15 * rhr) isAsleep = false;
    }
    asleep[i] = isAsleep;
  }

  // 2. Collect ALL consolidated periods (same ≤20-min interior-gap rule as the
  //    main-sleep detector). Each is trimmed to its first/last asleep epoch.
  const MAX_GAP_MIN = 20;
  const MAX_SLEEP_MIN = 14 * 60; // same plausibility ceiling, applied per period
  const MIN_PERIOD_MIN = 15;     // shorter than this isn't a sleep period

  const raw: { start: number; end: number; asleepN: number }[] = [];
  let pf = -1, pl = -1, pa = 0, gap = 0;
  const close = () => {
    if (pf >= 0 && pa > 0) raw.push({ start: pf, end: pl, asleepN: pa });
    pf = -1; pl = -1; pa = 0; gap = 0;
  };
  for (let i = 0; i < n; i++) {
    if (asleep[i]) { if (pf < 0) pf = i; pl = i; pa++; gap = 0; }
    else if (pf >= 0) { if (++gap > MAX_GAP_MIN) close(); }
  }
  close();

  const periods: SleepPeriod[] = [];
  for (const p of raw) {
    let startIdx = p.start;
    let endIdx = p.end;
    if (endIdx - startIdx + 1 > MAX_SLEEP_MIN) endIdx = startIdx + MAX_SLEEP_MIN - 1;

    const span = sorted.slice(startIdx, endIdx + 1);
    const in_bed_min = span.length;
    let duration_min = 0;
    for (let i = startIdx; i <= endIdx; i++) if (asleep[i]) duration_min++;
    if (duration_min < MIN_PERIOD_MIN) continue;

    const efficiency = in_bed_min > 0 ? duration_min / in_bed_min : 0;
    const sleepEpochs = span.filter((_, i) => asleep[startIdx + i]);
    const stages = estimateStages(sleepEpochs, rhr);

    const hasHr = span.some((m) => m.wrist_on && m.hr_avg > 0);
    const hasActivity = span.some((m) => m.activity > 0);
    const hasTemp = baseline.skin_temp != null;
    const inputCompleteness = [hasHr, hasActivity, hasTemp].filter(Boolean).length / 3;
    const coverage = Math.min(1, in_bed_min / 90);

    periods.push({
      onset_ts: sorted[startIdx].ts,
      wake_ts: sorted[endIdx].ts,
      duration_min,
      in_bed_min,
      efficiency: round(efficiency, 4),
      stages,
      is_main: false,
      confidence: round(inputCompleteness * coverage, 4),
    });
  }

  if (periods.length === 0) return empty();

  // 3. Flag the longest period as the main one (UI hint only).
  let main_idx = 0;
  for (let i = 1; i < periods.length; i++) {
    if (periods[i].duration_min > periods[main_idx].duration_min) main_idx = i;
  }
  periods[main_idx].is_main = true;

  const total_asleep_min = periods.reduce((a, p) => a + p.duration_min, 0);

  const inputs_used: string[] = ['activity'];
  if (sorted.some((m) => m.wrist_on && m.hr_avg > 0)) inputs_used.push('hr_avg');
  if (baseline.skin_temp != null) inputs_used.push('baseline.skin_temp');

  return {
    periods,
    total_asleep_min,
    main_idx,
    stages_beta: true,
    confidence: periods[main_idx].confidence,
    tier: 'HIGH',
    inputs_used,
  };
}

/**
 * sleepAwakeMask(minutes, baseline, rrByMin?) → Map<ts, asleep:boolean> per minute.
 * Cole-Kripke actigraphy + HR-dip — the authoritative asleep/awake boundary — PLUS an
 * RR tiebreaker for the override's blind spot:
 *
 * The HR-dip rule "HR > 1.15·rhr ⇒ awake" is right for genuine wake but it ALSO catches
 * REM (REM HR legitimately runs ~15% above the sleeping floor) — and on a calm wrist with
 * a near-dead activity signal there's no movement to tell them apart, so REM gets called
 * "awake". Fix: for those high-HR minutes, look at beat-to-beat RR. REM = parasympathetic
 * withdrawal ⇒ LOW RMSSD; so a high-HR minute whose smoothed RMSSD is below 0.90× the
 * night's asleep-RMSSD median is REM → stays ASLEEP, not awake. (rrByMin optional; without
 * it the legacy HR-only override stands.)
 *
 * The day-detail uses this to drive the hypnogram + breakdown from one source. Empty map
 * when there's no resting-HR baseline. calcSleep/calcSleepPeriods scorers stay untouched.
 */
export function sleepAwakeMask(
  minutes: Minute[], baseline: Baseline, rrByMin?: Map<number, number[]>,
): Map<number, boolean> {
  const out = new Map<number, boolean>();
  const rhr = baseline.resting_hr;
  if (rhr == null || rhr <= 0) return out;
  const sorted = [...minutes].sort((a, b) => a.ts - b.ts);
  const n = sorted.length;

  // Per-minute smoothed RMSSD + the asleep-RMSSD median → the REM cut for the tiebreaker.
  let rms: (number | null)[] = [];
  let remCut: number | null = null;
  if (rrByMin && rrByMin.size) {
    const raw = sorted.map((m) => minuteRmssd(rrByMin.get(m.ts)));
    rms = raw.map((_, i) => medOfNullable(raw.slice(Math.max(0, i - 2), Math.min(n, i + 3))));
    const asleepRms = sorted.map((m, i) => (m.hr_avg > 0 ? rms[i] : null));
    const med = medOfNullable(asleepRms);
    if (med != null) remCut = REM_RMSSD_FACTOR * med;
  }

  for (let i = 0; i < n; i++) {
    let s = 0;
    for (let k = 0; k < CK_W.length; k++) {
      const idx = i + (k - 4);
      if (idx >= 0 && idx < n) s += CK_W[k] * sorted[idx].activity;
    }
    s *= 0.001;
    const m = sorted[i];
    if (!m.wrist_on) { out.set(m.ts, false); continue; } // off-wrist = not asleep (boundary)
    let isAsleep = s < 1;
    if (m.hr_avg > 0) {
      if (m.hr_avg < 0.95 * rhr) isAsleep = true;
      else if (m.hr_avg > 1.15 * rhr) {
        // RR tiebreaker: high HR + low RMSSD = REM (asleep); else genuine wake.
        const remLike = remCut != null && rms[i] != null && rms[i]! < remCut;
        isAsleep = remLike;
      }
    }
    out.set(m.ts, isAsleep);
  }
  return out;
}

/** Merge per-minute stage runs shorter than the floor into the larger neighbour
 *  (awake keeps a higher floor) — consolidates the per-minute classifier's flicker
 *  into stable bouts so the hypnogram doesn't sawtooth. */
function boutSmoothStage(labels: string[], minRun = 5, minAwakeRun = 7, passes = 6): string[] {
  const s = [...labels];
  for (let p = 0; p < passes; p++) {
    const runs: { a: number; b: number }[] = [];
    for (let i = 0; i < s.length;) { let j = i; while (j < s.length && s[j] === s[i]) j++; runs.push({ a: i, b: j - 1 }); i = j; }
    if (runs.length <= 1) break;
    let changed = false;
    for (let r = 0; r < runs.length; r++) {
      const { a, b } = runs[r];
      const floor = s[a] === 'awake' ? minAwakeRun : minRun;
      if (b - a + 1 >= floor) continue;
      const prev = r > 0 ? runs[r - 1] : null;
      const next = r < runs.length - 1 ? runs[r + 1] : null;
      let tgt: string | null = null;
      if (prev && next) tgt = (prev.b - prev.a) >= (next.b - next.a) ? s[prev.a] : s[next.a];
      else if (prev) tgt = s[prev.a];
      else if (next) tgt = s[next.a];
      if (tgt) { for (let x = a; x <= b; x++) s[x] = tgt; changed = true; }
    }
    if (!changed) break;
  }
  return s;
}

export interface NightHypnogram {
  hypnogram: { t: number; stage: 'awake' | 'light' | 'deep' | 'rem' }[];
  light_min: number; deep_min: number; rem_min: number; awake_min: number; asleep_min: number;
}

/**
 * stageHypnogram(minutes, onset, wake, baseline) — the v1 staging method, made
 * per-minute and consistent. ONE source for the whole hypnogram + breakdown:
 *   • asleep/awake from calcSleep's Cole-Kripke + HR-dip mask (the proven detector),
 *   • deep/light/rem within the asleep minutes from the SAME HR-percentile bands as
 *     estimateStages (deep = bottom ~22% of sleeping HR, REM = top ~21%, else light),
 *   • bout-smoothed so it reads as stable bouts, not minute flicker.
 * No RR, no circadian, no second stager — exactly what worked in v1, now driving both
 * the graph and the totals (so they can never disagree). null if no resting-HR baseline.
 */
export function stageHypnogram(
  minutes: Minute[], onset: number, wake: number, baseline: Baseline, rrByMin?: Map<number, number[]>,
): NightHypnogram | null {
  const rhr = baseline.resting_hr;
  if (rhr == null || rhr <= 0) return null;
  const mask = sleepAwakeMask(minutes, baseline, rrByMin); // ts → asleep (REM tiebreaker via RR)
  const win = minutes.filter((m) => m.ts >= onset && m.ts <= wake).sort((a, b) => a.ts - b.ts);
  if (win.length < 5) return null;

  // HR-percentile bands over the night's OWN sleeping HR (same as estimateStages).
  const sleepHr = win.filter((m) => mask.get(m.ts) !== false && m.hr_avg > 0).map((m) => m.hr_avg);
  const hrs = sleepHr.length ? sleepHr : win.filter((m) => m.hr_avg > 0).map((m) => m.hr_avg);
  const sortedHr = [...hrs].sort((a, b) => a - b);
  const meanHr = hrs.length ? hrs.reduce((a, b) => a + b, 0) / hrs.length : rhr;
  const q = (p: number): number => sortedHr.length ? sortedHr[Math.min(sortedHr.length - 1, Math.floor(p * sortedHr.length))] : meanHr;
  const deepEdge = q(0.22), remEdge = q(0.79);
  const bigJump = Math.max(6, (hrs.length ? Math.max(1, q(0.9) - q(0.1)) : 1) * 0.6);
  const acts = win.map((m) => m.activity);
  const meanAct = acts.reduce((a, b) => a + b, 0) / (acts.length || 1);

  const raw: string[] = win.map((m, i) => {
    if (mask.get(m.ts) === false || m.hr_avg <= 0) return 'awake';
    const hr = m.hr_avg;
    const prev = i > 0 && win[i - 1].hr_avg > 0 ? win[i - 1].hr_avg : hr;
    const next = i + 1 < win.length && win[i + 1].hr_avg > 0 ? win[i + 1].hr_avg : hr;
    const hrJump = Math.max(Math.abs(hr - prev), Math.abs(hr - next));
    const lowAct = m.activity <= meanAct;
    if (lowAct && hr <= deepEdge) return 'deep';
    if (lowAct && hr >= remEdge) return 'rem';
    if (lowAct && hrJump > bigJump) return 'rem';
    return 'light';
  });
  const sm = boutSmoothStage(raw);
  let light = 0, deep = 0, rem = 0, awake = 0;
  for (const s of sm) { if (s === 'awake') awake++; else if (s === 'deep') deep++; else if (s === 'rem') rem++; else light++; }
  return {
    hypnogram: win.map((m, i) => ({ t: m.ts, stage: sm[i] as 'awake' | 'light' | 'deep' | 'rem' })),
    light_min: light, deep_min: deep, rem_min: rem, awake_min: awake, asleep_min: light + deep + rem,
  };
}

/**
 * BETA stage estimator. Splits asleep epochs into deep/REM/light using activity
 * + HR relative to that night's own distribution. Honest heuristic, not clinical.
 */
function estimateStages(sleepEpochs: Minute[], rhr: number): SleepStages | null {
  if (sleepEpochs.length === 0) return null;
  const hrs = sleepEpochs.filter((m) => m.hr_avg > 0).map((m) => m.hr_avg);
  const meanHr = hrs.length ? mean(hrs) : rhr;
  const acts = sleepEpochs.map((m) => m.activity);
  const meanAct = mean(acts);

  // Band the night's OWN asleep-HR distribution (robust, scale-free). Physiology:
  // sleeping HR is LOWEST in deep/slow-wave sleep and HIGHER + more variable in
  // REM and light. With no EEG/PPG this relative-HR-depth proxy is the honest
  // signal — so we band by HR percentile to land a PHYSIOLOGICALLY plausible split
  // (deep ~20%, REM ~25%, light ~55%):
  //   • bottom ~22% of sleeping HR + quiet → deep
  //   • top   ~26% of sleeping HR + quiet → REM
  //   • everything else → light
  // We deliberately DON'T gate on minute-to-minute HR variability: the earlier
  // estimator did (REM = high-band OR jump>2 bpm), and on minute-AVERAGED HR that
  // mis-fired catastrophically — almost every minute jumps >2 bpm, so 60–70% of
  // the night read as REM. Variability is too noisy at minute resolution to be a
  // reliable REM cue, so HR depth alone drives the split. A small variability
  // NUDGE only rescues a mid-band epoch that is unusually erratic → REM-leaning.
  const sortedHr = [...hrs].sort((a, b) => a - b);
  const q = (p: number): number =>
    sortedHr.length ? sortedHr[Math.min(sortedHr.length - 1, Math.floor(p * sortedHr.length))] : meanHr;
  const deepEdge = q(0.22);  // bottom ~22% of sleeping HR → deep
  const remEdge = q(0.79);   // top ~21% of sleeping HR → REM
  const hrSpread = hrs.length ? Math.max(1, q(0.9) - q(0.1)) : 1;
  const bigJump = Math.max(6, hrSpread * 0.6); // a clearly erratic minute

  let light = 0;
  let deep = 0;
  let rem = 0;
  for (let i = 0; i < sleepEpochs.length; i++) {
    const m = sleepEpochs[i];
    // Activity at or below the night's own mean = "quiet"; deep/REM need quiet
    // epochs (sustained movement → light/arousal).
    const lowAct = m.activity <= meanAct;
    const hr = m.hr_avg > 0 ? m.hr_avg : meanHr;
    const prev = i > 0 && sleepEpochs[i - 1].hr_avg > 0 ? sleepEpochs[i - 1].hr_avg : hr;
    const next = i + 1 < sleepEpochs.length && sleepEpochs[i + 1].hr_avg > 0
      ? sleepEpochs[i + 1].hr_avg : hr;
    const hrJump = Math.max(Math.abs(hr - prev), Math.abs(hr - next));
    if (lowAct && hr <= deepEdge) {
      deep++; // quietest + HR in the night's lowest band → deep
    } else if (lowAct && hr >= remEdge) {
      rem++; // quiet + HR in the night's upper band → REM
    } else if (lowAct && hrJump > bigJump) {
      rem++; // mid-band but a clearly erratic minute → REM-leaning
    } else {
      light++;
    }
  }
  return { light_min: light, deep_min: deep, rem_min: rem };
}
