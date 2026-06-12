// §13 Nocturnal Heart — what your heart does while you sleep. The honest,
// data-grounded counterpart to "respiratory rate" (which needs PPG we usually
// don't have overnight). All from minute HR over the sleep window:
//   • sleeping HR average + nadir (lowest sustained HR) and when it happened
//   • nocturnal dip = how far sleeping HR falls below your waking HR (autonomic
//     recovery; a bigger dip is generally healthier)
//   • elevated-overnight-HR flag vs your own baseline (illness / under-recovery
//     early-warning — a signal, not a diagnosis)
// Tier HIGH for the measured numbers (HR is authoritative); the interpretation is
// labelled. NOT a clinical metric.

import type { Minute, Baseline, Metric } from './types';
import { clamp, mean } from './util';

export interface NocturnalValue {
  sleeping_hr_avg: number | null; // mean HR over worn sleep minutes
  sleeping_hr_min: number | null; // nadir = lowest 5-min rolling mean HR
  nadir_ts: number | null;        // when the nadir occurred
  day_hr_avg: number | null;      // mean waking HR (context for the dip)
  dip_pct: number | null;         // (day - sleep)/day, 0..1 (autonomic recovery)
  vs_baseline_bpm: number | null; // sleeping_hr_avg − baseline.sleeping_hr
  elevated: boolean;              // sleeping HR notably above baseline
}

/**
 * calcNocturnalHeart(sleepMinutes, dayMinutes, baseline)
 *
 * sleepMinutes: worn minutes within the main sleep period (onset..wake).
 * dayMinutes:   worn minutes of the WAKING day (for the dip denominator).
 * baseline.sleeping_hr: rolling baseline sleeping HR (null until established).
 *
 * Elevated = sleeping_hr_avg ≥ baseline + 4 bpm (and ≥ +5%). Confidence = coverage
 * of sleep minutes that carry HR (clamp(n/180)).
 */
export function calcNocturnalHeart(
  sleepMinutes: Minute[],
  dayMinutes: Minute[],
  baseline: Baseline & { sleeping_hr?: number | null },
): Metric<NocturnalValue> {
  const sleepHrs = sleepMinutes
    .filter((m) => m.wrist_on && m.hr_avg > 0)
    .sort((a, b) => a.ts - b.ts);

  const empty = (): Metric<NocturnalValue> => ({
    sleeping_hr_avg: null, sleeping_hr_min: null, nadir_ts: null,
    day_hr_avg: null, dip_pct: null, vs_baseline_bpm: null, elevated: false,
    confidence: 0, tier: 'HIGH', inputs_used: [],
  });
  if (sleepHrs.length === 0) return empty();

  const hrVals = sleepHrs.map((m) => m.hr_avg);
  const sleepingHrAvg = Math.round(mean(hrVals));

  // Nadir = lowest 5-min rolling mean (avoids a single artefactual low beat).
  let nadir: { ts: number; v: number } | null = null;
  const W = 5;
  if (sleepHrs.length >= W) {
    for (let i = 0; i + W <= sleepHrs.length; i++) {
      const win = sleepHrs.slice(i, i + W);
      const m = mean(win.map((x) => x.hr_avg));
      if (!nadir || m < nadir.v) {
        nadir = { ts: sleepHrs[i + Math.floor(W / 2)].ts, v: m };
      }
    }
  } else {
    const lo = sleepHrs.reduce((p, c) => (c.hr_avg < p.hr_avg ? c : p));
    nadir = { ts: lo.ts, v: lo.hr_avg };
  }

  const dayHr = dayMinutes.filter((m) => m.wrist_on && m.hr_avg > 0).map((m) => m.hr_avg);
  const dayHrAvg = dayHr.length ? Math.round(mean(dayHr)) : null;
  const dipPct = (dayHrAvg && dayHrAvg > 0)
    ? Math.round(clamp((dayHrAvg - sleepingHrAvg) / dayHrAvg, 0, 1) * 1000) / 1000
    : null;

  const baseSleepHr = (baseline.sleeping_hr && baseline.sleeping_hr > 0)
    ? baseline.sleeping_hr : null;
  const vsBaseline = baseSleepHr != null ? Math.round((sleepingHrAvg - baseSleepHr) * 10) / 10 : null;
  const elevated = baseSleepHr != null
    && sleepingHrAvg >= baseSleepHr + 4
    && sleepingHrAvg >= baseSleepHr * 1.05;

  const coverage = clamp(sleepHrs.length / 180, 0, 1);

  return {
    sleeping_hr_avg: sleepingHrAvg,
    sleeping_hr_min: nadir ? Math.round(nadir.v) : null,
    nadir_ts: nadir ? nadir.ts : null,
    day_hr_avg: dayHrAvg,
    dip_pct: dipPct,
    vs_baseline_bpm: vsBaseline,
    elevated,
    confidence: Math.round(coverage * 1000) / 1000,
    tier: 'HIGH',
    inputs_used: ['hr_avg', 'sleep.onset_ts', 'sleep.wake_ts',
      ...(baseSleepHr != null ? ['baseline.sleeping_hr'] : [])],
  };
}
