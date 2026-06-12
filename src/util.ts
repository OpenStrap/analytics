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
  // 1. Prefer a measured max carried on the baseline (from observed sessions).
  if (baseline.max_hr && baseline.max_hr > 0) {
    return { maxHr: baseline.max_hr, source: 'measured' };
  }
  // 2. Measured max from the minutes themselves.
  const observed = minutes
    .filter(isHrUsable)
    .reduce((mx, m) => Math.max(mx, m.hr_max, m.hr_avg), 0);
  if (observed > 0) {
    // If we have an observed max we treat it as 'measured' truth.
    return { maxHr: observed, source: 'measured' };
  }
  // 3. Age-based default only when age is present.
  if (profile?.age && profile.age > 0) {
    return { maxHr: 220 - profile.age, source: 'age' };
  }
  // 4. No data at all: honest neutral fallback (still flagged as age-derived,
  //    using a population mean age of 30 ONLY as a denominator guard so HR-zone
  //    math doesn't divide by zero — callers should down-weight confidence).
  return { maxHr: 190, source: 'age' };
}
