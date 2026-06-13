// §Stress — HRV-based, replacing the old "HR-above-rest while sedentary" heuristic.
// Stress = sympathetic activation read from beat-to-beat RR: the Baevsky Stress
// Index (SI) and LF/HF balance (Task Force 1996). Scored PERSONAL-RELATIVE: today's
// ln(SI) as a z against the user's own rolling baseline SI distribution — so a
// "stress level" means "high for you", not vs a population constant we'd have to
// invent. No baseline yet → report the raw indices, no score (honest, not guessed).
import type { Metric, StressValue, Driver, MetricRef } from './types';
import { mean, stddev, round } from './util';
import { timeDomainHrv, freqDomainHrv, baevskyStressIndex } from './hrv';

/**
 * calcStress(rr, baselineSI[], opts?)
 *
 * rr: time-ordered RR-interval stream (ms) over the window (a day, or a sleep
 *     window for nocturnal stress). baselineSI: prior windows' SI for the z-score.
 * Tier ESTIMATE (HRV stress is a validated index, but absolute interpretation is
 * personal and noisy — so ESTIMATE with computed confidence).
 */
export function calcStress(
  rr: number[],
  baselineSI: number[],
  opts: { date?: string } = {},
): Metric<StressValue> {
  const si = baevskyStressIndex(rr);
  const td = timeDomainHrv(rr);
  const fd = freqDomainHrv(rr);

  const none = (): Metric<StressValue> => ({
    score: null, si: si.si, lf_hf: fd.lf_hf, rmssd: td.rmssd, level: null,
    confidence: 0, tier: 'ESTIMATE', inputs_used: [],
  });
  if (si.si == null) return none();

  const usableBase = baselineSI.filter((x) => x > 0);
  const ref: MetricRef = { metric: 'hrv', date: opts.date, scale: 'day' };
  const drivers: Driver[] = [
    { label: 'Baevsky Stress Index', contribution: round(si.si, 1), detail: `SI ${si.si}`, ref },
  ];
  if (fd.lf_hf != null) drivers.push({ label: 'Sympatho-vagal balance (LF/HF)', contribution: round(fd.lf_hf, 2), detail: `LF/HF ${fd.lf_hf}`, ref });
  if (td.rmssd != null) drivers.push({ label: 'HRV (RMSSD)', contribution: round(-(td.rmssd), 1), detail: `${td.rmssd} ms`, ref });

  // No personal baseline yet → indices only, no fabricated score.
  if (usableBase.length < 5) {
    return {
      score: null, si: si.si, lf_hf: fd.lf_hf, rmssd: td.rmssd, level: null,
      confidence: round(Math.min(0.4, si.n_beats / 300), 4), tier: 'ESTIMATE',
      inputs_used: ['hrv_si', 'hrv_lf_hf'], drivers,
    };
  }

  const lnBase = usableBase.map((x) => Math.log(x));
  const m = mean(lnBase);
  const sd = stddev(lnBase);
  let score: number | null = null;
  let z: number | null = null;
  if (sd > 0) {
    z = (Math.log(si.si) - m) / sd;       // higher SI ⇒ more stress
    score = Math.max(0, Math.min(100, Math.round(50 + 25 * z)));
  }
  const level: StressValue['level'] =
    score == null ? null : score < 40 ? 'low' : score <= 70 ? 'moderate' : 'elevated';
  const confidence = Math.min(1, usableBase.length / 21) * Math.min(1, si.n_beats / 300);

  return {
    score, si: si.si, lf_hf: fd.lf_hf, rmssd: td.rmssd, level,
    confidence: round(confidence, 4), tier: 'ESTIMATE',
    inputs_used: ['hrv_si', 'hrv_lf_hf', 'baseline.hrv_si'], drivers,
  };
}
