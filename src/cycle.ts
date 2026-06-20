// cycle.ts — menstrual cycle estimation.
//
// LOG-ANCHORED + calendar method: the user logs period-start dates; prediction is
// driven by those, never inferred from biometrics alone (we don't claim to detect
// ovulation from temperature — that would be fabrication). The luteal phase is
// physiologically stable at ~14 days (Wilcox 2000), so ovulation ≈ next-period − 14
// and the fertile window is the 5 days before ovulation + ovulation day.
//
// Biometric overlay (skin-temp / RHR / HRV shifts across the cycle) is rendered by
// the caller from stored `daily` values — it ENRICHES the view but is descriptive,
// never the basis of the prediction. Honest: an ESTIMATE, not medical or
// contraceptive guidance.

import type { Metric } from './types'
import { median } from './util'

const DAY_MS = 86400000
const toMs = (d: string) => Date.parse(d + 'T00:00:00Z')
const toDate = (ms: number) => new Date(ms).toISOString().slice(0, 10)
const daysBetween = (a: string, b: string) => Math.round((toMs(b) - toMs(a)) / DAY_MS)

export type CyclePhase = 'menstruation' | 'follicular' | 'ovulation' | 'luteal' | 'unknown'

export interface CycleValue {
  cycle_day: number | null      // 1-based day within the current cycle (day 1 = start)
  phase: CyclePhase
  mean_length: number | null    // median observed cycle length (days); null if <2 starts
  length_history: number[]      // observed consecutive-start gaps (days)
  last_start: string | null     // most recent logged period start (YYYY-MM-DD)
  predicted_next: string | null // predicted next period start
  days_until_next: number | null
  ovulation_est: string | null  // predicted_next − 14d
  fertile_start: string | null  // ovulation − 5d
  fertile_end: string | null    // ovulation + 1d
  note: string
}

const DEFAULT_LEN = 28 // population default until the user has ≥2 logged periods
const LUTEAL = 14      // stable luteal length → ovulation = next_period − LUTEAL
const MENSES = 5       // assumed menses length when no explicit end is logged

/** Estimate the current cycle position + next-period / fertile-window prediction
 *  from a list of logged period-START dates. `today` is supplied (pure, no clock). */
export function calcCycle(startsRaw: string[], today: string): Metric<CycleValue> {
  const empty = (note: string): Metric<CycleValue> => ({
    cycle_day: null, phase: 'unknown', mean_length: null, length_history: [],
    last_start: null, predicted_next: null, days_until_next: null,
    ovulation_est: null, fertile_start: null, fertile_end: null, note,
    confidence: 0, tier: 'ESTIMATE', inputs_used: ['period_log'],
  })

  const starts = Array.from(new Set(startsRaw))
    .filter((d) => /^\d{4}-\d{2}-\d{2}$/.test(d) && toMs(d) <= toMs(today))
    .sort()
  if (starts.length === 0) return empty('Log a period to start tracking your cycle.')

  // Observed cycle lengths between consecutive starts (keep physiological 15–60d).
  const lengths: number[] = []
  for (let i = 1; i < starts.length; i++) {
    const len = daysBetween(starts[i - 1], starts[i])
    if (len >= 15 && len <= 60) lengths.push(len)
  }
  const med = lengths.length ? median(lengths) : null
  const meanLen = med == null ? null : Math.round(med)
  const useLen = meanLen ?? DEFAULT_LEN

  const last = starts[starts.length - 1]
  const cycleDay = daysBetween(last, today) + 1 // day 1 = the start date itself

  const nextMs = toMs(last) + useLen * DAY_MS
  const predictedNext = toDate(nextMs)
  const daysUntil = daysBetween(today, predictedNext)
  const ovMs = nextMs - LUTEAL * DAY_MS
  const ovulation = toDate(ovMs)
  const fertileStart = toDate(ovMs - 5 * DAY_MS)
  const fertileEnd = toDate(ovMs + 1 * DAY_MS)

  // Phase by calendar method.
  const todayMs = toMs(today)
  let phase: CyclePhase
  if (cycleDay <= MENSES) phase = 'menstruation'
  else if (todayMs >= toMs(fertileStart) && todayMs <= toMs(fertileEnd)) phase = 'ovulation'
  else if (todayMs < ovMs) phase = 'follicular'
  else phase = 'luteal'

  // Confidence grows with the number of observed cycles; collapses if very overdue
  // (a missed/late period makes the calendar prediction unreliable — say so).
  let conf = lengths.length === 0 ? 0.3 : Math.min(0.9, 0.4 + 0.15 * lengths.length)
  if (cycleDay > useLen * 1.6) { phase = 'unknown'; conf = Math.min(conf, 0.2) }

  return {
    cycle_day: cycleDay, phase, mean_length: meanLen, length_history: lengths,
    last_start: last, predicted_next: predictedNext, days_until_next: daysUntil,
    ovulation_est: ovulation, fertile_start: fertileStart, fertile_end: fertileEnd,
    note: lengths.length === 0
      ? 'Based on one logged period and a 28-day default — accuracy improves as you log more.'
      : `Based on ${lengths.length + 1} logged periods (median ${useLen}-day cycle).`,
    confidence: conf, tier: 'ESTIMATE', inputs_used: ['period_log'],
  }
}
