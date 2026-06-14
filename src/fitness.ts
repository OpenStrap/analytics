// §Fitness — cardiorespiratory + training-load modeling. All from inputs we
// already have (max HR, resting HR, daily strain history). Published methods.
import type {
  Metric, Vo2MaxValue, FitnessModelValue, MonotonyValue, DailyStrain,
} from './types';
import { mean, stddev, round } from './util';

/**
 * calcVo2Max(maxHr, restingHr) — Uth–Sørensen (2004):
 *   VO2max ≈ 15.3 × (HRmax / HRrest)   [ml·kg⁻¹·min⁻¹]
 * A whole-population HR-ratio estimate; ESTIMATE tier. Needs a measured maxHR and
 * a resting HR with maxHR > restingHR, else abstains.
 */
export function calcVo2Max(maxHr: number | null, restingHr: number | null): Metric<Vo2MaxValue> {
  if (maxHr == null || restingHr == null || restingHr <= 0 || maxHr <= restingHr) {
    return { vo2max: null, method: 'Uth–Sørensen', confidence: 0, tier: 'ESTIMATE', inputs_used: [] };
  }
  return {
    vo2max: round(15.3 * (maxHr / restingHr), 1),
    method: 'Uth–Sørensen',
    confidence: 0.5,
    tier: 'ESTIMATE',
    inputs_used: ['baseline.max_hr', 'baseline.resting_hr'],
  };
}

/**
 * calcFitnessModel(dailyStrain[]) — Banister impulse-response (1975/1991):
 *   Fitness (CTL)  = EWMA of daily strain, τ ≈ 42 d  (slow, "fitness")
 *   Fatigue (ATL)  = EWMA of daily strain, τ ≈ 7 d   (fast, "fatigue")
 *   Form (TSB)     = Fitness − Fatigue measured BEFORE today's strain (freshness)
 * Confidence ramps with days available (full at ~42 d). ESTIMATE tier.
 */
export function calcFitnessModel(dailyStrain: DailyStrain[]): Metric<FitnessModelValue> {
  const sorted = [...dailyStrain].sort((a, b) => a.ts - b.ts);
  const days = sorted.length;
  if (days < 7) {
    return {
      fitness: null, fatigue: null, form: null,
      confidence: round(Math.min(1, days / 42), 4), tier: 'ESTIMATE', inputs_used: ['daily_strain'],
    };
  }
  const aCtl = 2 / (42 + 1), aAtl = 2 / (7 + 1);
  let ctl = sorted[0].strain, atl = sorted[0].strain;
  let prevCtl = ctl, prevAtl = atl;
  for (const d of sorted) {
    prevCtl = ctl; prevAtl = atl;
    ctl = ctl + aCtl * (d.strain - ctl);
    atl = atl + aAtl * (d.strain - atl);
  }
  return {
    fitness: round(ctl, 2),
    fatigue: round(atl, 2),
    form: round(prevCtl - prevAtl, 2), // freshness coming INTO today
    confidence: round(Math.min(1, days / 42), 4),
    tier: 'ESTIMATE',
    inputs_used: ['daily_strain'],
  };
}

/**
 * calcMonotony(dailyStrain[]) — Foster (1998) training monotony & strain:
 *   monotony       = mean(7d strain) / SD(7d strain)   (>2 = risky sameness)
 *   training_strain = weekly_load × monotony
 * HIGH tier (deterministic from strain). Needs ≥4 of the last 7 days.
 */
export function calcMonotony(dailyStrain: DailyStrain[]): Metric<MonotonyValue> {
  const last7 = [...dailyStrain].sort((a, b) => a.ts - b.ts).slice(-7).map((d) => d.strain);
  const weekly = round(last7.reduce((a, b) => a + b, 0), 1);
  if (last7.length < 4) {
    return {
      monotony: null, training_strain: null, weekly_load: weekly,
      confidence: round(last7.length / 7, 4), tier: 'HIGH', inputs_used: ['daily_strain'],
    };
  }
  const m = mean(last7), sd = stddev(last7);
  const monotony = sd > 0 ? m / sd : null;
  return {
    monotony: monotony == null ? null : round(monotony, 2),
    training_strain: monotony == null ? null : round(weekly * monotony, 1),
    weekly_load: weekly,
    confidence: round(Math.min(1, last7.length / 7), 4),
    tier: 'HIGH',
    inputs_used: ['daily_strain'],
  };
}
