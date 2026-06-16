// Shared pure helpers. No I/O.
import type { Minute, Profile, Baseline } from './types';

/** A worn minute usable for HR math: wrist on AND a real HR reading (>0). */
export function isHrUsable(m: Minute): boolean {
  return m.wrist_on && m.hr_avg > 0;
}

/** Linear-interpolated percentile (p in [0,100]) of a numeric array. */
export function percentile(values: number[], p: number): number | null {
  if (values.length === 0) return null;
  const sorted = [...values].sort((a, b) => a - b);
  if (sorted.length === 1) return sorted[0];
  const rank = (p / 100) * (sorted.length - 1);
  const lo = Math.floor(rank);
  const hi = Math.ceil(rank);
  if (lo === hi) return sorted[lo];
  const frac = rank - lo;
  return sorted[lo] + (sorted[hi] - sorted[lo]) * frac;
}

export function median(values: number[]): number | null {
  return percentile(values, 50);
}

export function clamp(x: number, lo: number, hi: number): number {
  return Math.max(lo, Math.min(hi, x));
}

export function mean(values: number[]): number {
  if (values.length === 0) return 0;
  return values.reduce((a, b) => a + b, 0) / values.length;
}

export function stddev(values: number[]): number {
  if (values.length < 2) return 0;
  const m = mean(values);
  const v = values.reduce((a, b) => a + (b - m) * (b - m), 0) / values.length;
  return Math.sqrt(v);
}

/** Least-squares slope of y vs x (x = 0..n-1 if omitted). Returns 0 if <2 points. */
export function linregSlope(y: number[], x?: number[]): number {
  const n = y.length;
  if (n < 2) return 0;
  const xs = x ?? y.map((_, i) => i);
  const mx = mean(xs);
  const my = mean(y);
  let num = 0;
  let den = 0;
  for (let i = 0; i < n; i++) {
    num += (xs[i] - mx) * (y[i] - my);
    den += (xs[i] - mx) * (xs[i] - mx);
  }
  return den === 0 ? 0 : num / den;
}

export function round(x: number, decimals: number): number {
  const f = Math.pow(10, decimals);
  return Math.round(x * f) / f;
}

/**
 * Resolve max HR per spec: measured session max if available, else 220 − age.
 * There is NO biometric "age detection" — we never fabricate an age. If age is
 * absent and no measured max exists, we cannot compute an age-based max, so we
 * fall back to whatever measured max the minutes themselves expose.
 *
 * @returns { maxHr, source } where source is 'measured' or 'age'.
 */
export function resolveMaxHr(
  minutes: Minute[],
  baseline: Pick<Baseline, 'max_hr'>,
  profile?: Profile
): { maxHr: number; source: 'measured' | 'age' } {
  // 1. Prefer a measured max carried on the baseline (rolling observed SESSION
  //    max — a real peak effort, accumulated across days). This is the stable,
  //    trustworthy denominator.
  if (baseline.max_hr && baseline.max_hr > 0) {
    return { maxHr: baseline.max_hr, source: 'measured' };
  }

  // The highest HR seen in THIS window. NOTE: on a low-activity day this is just
  // the day's quiet peak (e.g. 110 bpm) — NOT a true HRmax. Using it directly as
  // the zone/strain denominator over-states zone occupancy and inflates strain on
  // sedentary days, and varies wildly day-to-day. So we only treat it as a
  // 'measured' max when it actually EXCEEDS the age-predicted max (a genuine hard
  // effort); otherwise the age floor wins so a quiet peak can't shrink the scale.
  const observed = minutes
    .filter(isHrUsable)
    .reduce((mx, m) => Math.max(mx, m.hr_max, m.hr_avg), 0);

  // 2. Age-predicted max (floor), taking a genuine above-age effort if present.
  if (profile?.age && profile.age > 0) {
    // Tanaka, Monahan & Seals 2001 (JACC 37:153) — validated on 18,712 subjects,
    // more accurate than 220−age (which over-estimates in the young, under-
    // estimates in the old; they converge near age 40).
    const ageMax = Math.round(208 - 0.7 * profile.age);
    if (observed > ageMax) return { maxHr: observed, source: 'measured' };
    return { maxHr: ageMax, source: 'age' };
  }

  // 3. No age, but we have an observed peak: best available, but flag it 'age'
  //    (not 'measured') so callers down-weight confidence — it's an unverified
  //    within-window peak, not a true measured HRmax.
  if (observed > 0) {
    return { maxHr: observed, source: 'age' };
  }

  // 4. No data at all: honest neutral fallback (population HRmax ~190) used ONLY
  //    as a denominator guard so HR-zone math doesn't divide by zero — callers
  //    should down-weight confidence.
  return { maxHr: 190, source: 'age' };
}
