// §12 Stress / arousal monitor — sympathetic arousal estimated from HR elevation
// above resting WHILE MOTION IS LOW. Pure HR + actigraphy; NOT HRV-based (the HRV
// ban stands — this is a different, honest signal). The logic mirrors what makes a
// "stress monitor" work on any wrist wearable: high HR + low motion = arousal;
// high HR + high motion = exercise (excluded from stress). Tier ESTIMATE.
//
// It can't tell stress from caffeine from excitement — it's an AROUSAL estimate,
// and the UI says so. Confidence = worn coverage.

import type { Minute, Baseline, Profile, Metric } from './types';
import { clamp, resolveMaxHr } from './util';

/** Below this actigraphy level a minute is "sedentary" (arousal is meaningful). */
export const STRESS_ACT_FLOOR = 0.05;
/** HR-reserve fraction band edges (sedentary minutes only). */
const CALM_EDGE = 0.10;
const STRESSED_EDGE = 0.22;
/** Reserve fraction that maps to a 100/100 stress score. */
const SCORE_FULL_SCALE = 0.35;

export type ArousalBucket = 'calm' | 'balanced' | 'stressed' | 'active' | 'none';

export interface ArousalPoint {
  bucket: ArousalBucket;
  reserve: number; // 0..1 HR-reserve fraction (null-ish → 0)
  score: number;   // 0..100 (sedentary arousal); 0 for active/none
}

/**
 * Classify one minute's arousal from HR + motion. Shared by the daily summary
 * and the per-minute /day/stress endpoint so both agree exactly.
 */
export function classifyArousal(
  hr: number,
  activity: number,
  worn: boolean,
  rhr: number,
  maxHr: number,
): ArousalPoint {
  if (!worn || hr <= 0) return { bucket: 'none', reserve: 0, score: 0 };
  const denom = Math.max(1, maxHr - rhr);
  const reserve = clamp((hr - rhr) / denom, 0, 1);
  // Moving → exertion, not stress.
  if (activity >= STRESS_ACT_FLOOR) {
    return { bucket: 'active', reserve, score: 0 };
  }
  const score = Math.round(clamp(reserve / SCORE_FULL_SCALE, 0, 1) * 100);
  const bucket: ArousalBucket =
    reserve < CALM_EDGE ? 'calm' : reserve < STRESSED_EDGE ? 'balanced' : 'stressed';
  return { bucket, reserve, score };
}

export interface StressValue {
  score: number | null;   // 0..100 day stress = mean sedentary arousal, scaled
  avg_reserve: number;     // mean HR-reserve fraction while sedentary
  calm_min: number;
  balanced_min: number;
  stressed_min: number;
  active_min: number;      // elevated + moving (exertion; excluded from stress)
  worn_min: number;
  peak: { ts: number; score: number } | null; // worst sustained stressed window
}

/**
 * calcStress(minutes, baseline, profile)
 *
 * Per worn minute: classify arousal (see classifyArousal). Daily score = mean
 * sedentary arousal scaled to 0..100. Buckets are minute tallies. Peak = the
 * 5-min rolling window with the highest mean sedentary arousal.
 *
 * Confidence = clamp(worn_min / 600, 0, 1) (≈10h worn → full), down-weighted to
 * 0.8 when max-HR is age-derived (the reserve denominator is then estimated).
 */
export function calcStress(
  minutes: Minute[],
  baseline: Baseline,
  profile?: Profile,
): Metric<StressValue> {
  const rhr = baseline.resting_hr > 0 ? baseline.resting_hr : 60;
  const { maxHr, source } = resolveMaxHr(minutes, baseline, profile);

  const empty = (): Metric<StressValue> => ({
    score: null, avg_reserve: 0,
    calm_min: 0, balanced_min: 0, stressed_min: 0, active_min: 0, worn_min: 0,
    peak: null, confidence: 0, tier: 'ESTIMATE', inputs_used: [],
  });
  if (minutes.length === 0) return empty();

  const sorted = [...minutes].sort((a, b) => a.ts - b.ts);
  let calm = 0, balanced = 0, stressed = 0, active = 0, worn = 0;
  let reserveSum = 0, sedentaryN = 0;
  // per-minute sedentary score for the peak window (0 for non-sedentary).
  const sedScore: { ts: number; s: number; sed: boolean }[] = [];

  for (const m of sorted) {
    const p = classifyArousal(m.hr_avg, m.activity, m.wrist_on, rhr, maxHr);
    if (p.bucket === 'none') { sedScore.push({ ts: m.ts, s: 0, sed: false }); continue; }
    worn++;
    if (p.bucket === 'active') {
      active++;
      sedScore.push({ ts: m.ts, s: 0, sed: false });
      continue;
    }
    reserveSum += p.reserve; sedentaryN++;
    if (p.bucket === 'calm') calm++;
    else if (p.bucket === 'balanced') balanced++;
    else stressed++;
    sedScore.push({ ts: m.ts, s: p.score, sed: true });
  }

  if (sedentaryN === 0) {
    const m = empty();
    m.active_min = active; m.worn_min = worn;
    m.confidence = 0; // no sedentary minutes → no arousal signal
    return m;
  }

  const avgReserve = reserveSum / sedentaryN;
  const score = Math.round(clamp(avgReserve / SCORE_FULL_SCALE, 0, 1) * 100);

  // Peak = highest 5-min rolling mean over sedentary minutes (need ≥3 sedentary
  // minutes in the window to count, so a single blip isn't the day's "peak").
  let peak: { ts: number; score: number } | null = null;
  const W = 5;
  for (let i = 0; i + W <= sedScore.length; i++) {
    const win = sedScore.slice(i, i + W).filter((x) => x.sed);
    if (win.length < 3) continue;
    const mean = win.reduce((s, x) => s + x.s, 0) / win.length;
    if (!peak || mean > peak.score) {
      peak = { ts: sedScore[i + Math.floor(W / 2)].ts, score: Math.round(mean) };
    }
  }

  const coverage = clamp(worn / 600, 0, 1);
  const confidence = Math.round(coverage * (source === 'age' ? 0.8 : 1) * 1000) / 1000;

  return {
    score,
    avg_reserve: Math.round(avgReserve * 1000) / 1000,
    calm_min: calm, balanced_min: balanced, stressed_min: stressed,
    active_min: active, worn_min: worn,
    peak,
    confidence, tier: 'ESTIMATE',
    inputs_used: ['hr_avg', 'activity', 'baseline.resting_hr',
      source === 'measured' ? 'baseline.max_hr' : 'profile.age'],
  };
}
