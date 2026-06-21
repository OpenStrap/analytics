// §Restlessness — nocturnal MOVEMENT fragmentation from per-minute actigraphy.
//
// Distinct from calcSleepStress (which detects sympathetic HR-surge arousals): this
// is purely about physical movement during the sleep window — how often you shifted,
// how fragmented the night was, your longest still stretch. Built ONLY from the
// per-minute `activity` aggregate we already store (works on 1 Hz flash R24 — no
// high-rate stream, no new storage). Tier ESTIMATE.
//
// "Movement" is defined relative to the night's own dynamic range (a robust floor +
// a fraction of the spread), so it adapts per-user and per-night rather than using a
// fabricated absolute threshold.
import type { Minute, Metric, Driver } from './types';
import { percentile, round } from './util';

export interface RestlessnessValue {
  score: number | null;        // 0..100 (higher = more restless)
  restless_min: number;        // minutes with movement above the night floor
  movement_bouts: number;      // transitions still→moving (tosses/turns)
  mobility_pct: number | null; // fraction of the window spent moving (0..1)
  longest_still_min: number;   // longest contiguous still stretch (sleep continuity)
}

/**
 * calcRestlessness(sleepMinutes) — sleepMinutes are the worn minutes within the main
 * sleep period (onset..wake). A minute is "movement" when its activity exceeds a
 * per-night threshold = p10 + 0.4·(p90 − p10). Bouts = still→move transitions.
 */
export function calcRestlessness(sleepMinutes: Minute[]): Metric<RestlessnessValue> {
  const m = sleepMinutes
    .filter((x) => x.wrist_on !== false && x.activity != null)
    .sort((a, b) => a.ts - b.ts);
  const empty = (): Metric<RestlessnessValue> => ({
    score: null, restless_min: 0, movement_bouts: 0, mobility_pct: null, longest_still_min: 0,
    confidence: 0, tier: 'ESTIMATE', inputs_used: [],
  });
  if (m.length < 20) return empty();

  const acts = m.map((x) => x.activity);
  const p10 = percentile(acts, 10) ?? 0, p90 = percentile(acts, 90) ?? 0;
  const thresh = p10 + 0.4 * (p90 - p10);

  let restless = 0, bouts = 0, longestStill = 0, curStill = 0;
  let moving = false;
  for (const x of m) {
    const isMove = x.activity > thresh && x.activity > 0;
    if (isMove) {
      restless++;
      if (!moving) bouts++; // entering a movement bout (a toss/turn)
      moving = true;
      if (curStill > longestStill) longestStill = curStill;
      curStill = 0;
    } else {
      moving = false;
      curStill++;
    }
  }
  if (curStill > longestStill) longestStill = curStill;

  const total = m.length;
  const mobility = restless / total;
  const hours = Math.max(0.5, total / 60);
  const boutsPerHour = bouts / hours;
  // Score: movement-bout density + mobility fraction, mapped to 0..100.
  const score = Math.max(0, Math.min(100, Math.round(boutsPerHour * 6 + mobility * 100 * 0.5)));

  const drivers: Driver[] = [
    { label: 'Movement bouts', contribution: bouts, detail: `${bouts} shifts (${round(boutsPerHour, 1)}/h)`, ref: { metric: 'activity', scale: 'day' } },
    { label: 'Mobility', contribution: round(mobility * 100, 1), detail: `${restless}/${total} min moving`, ref: { metric: 'activity', scale: 'day' } },
  ];
  return {
    score, restless_min: restless, movement_bouts: bouts,
    mobility_pct: round(mobility, 4), longest_still_min: longestStill,
    confidence: round(Math.min(1, total / 240), 4), tier: 'ESTIMATE',
    inputs_used: ['activity'], drivers,
  };
}
