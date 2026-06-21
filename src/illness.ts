// §Illness — multivariate under-recovery / illness signal. Combines the signals
// that co-move when the body is fighting something: resting HR ↑, nocturnal HRV
// (RMSSD) ↓, skin temperature ↑, and respiratory rate ↑. We compute the
// MAHALANOBIS distance (Mahalanobis 1936) of today's vector from the user's
// personal baseline mean + covariance — one scalar that accounts for how these
// normally co-vary, rather than independent flags. Validated approach for
// wearable illness detection (Mishra et al., Nat Biomed Eng 2020; Smarr et al.,
// Sci Rep 2020); elevated nocturnal respiratory rate is among the earliest
// infection signals (Mishra 2020; Natarajan, Lancet Digit Health 2020).
// A SIGNAL, NOT A DIAGNOSIS — and only fires when deviations are in the illness
// direction (not just "unusual").
//
// Cycle-aware (honest, no fabrication): for users tracking their menstrual cycle,
// a rise in skin temperature and resting HR through the luteal phase is normal
// physiology (Wilcox 2000), not illness. When the only deviations are those two
// phase-expected signals, we do NOT flag illness — we still fire if HRV or
// respiratory rate also shift (signals not explained by the cycle).
import type { Metric, IllnessValue, Driver } from './types';
import type { CyclePhase } from './cycle';
import { mean, stddev, round } from './util';

export interface IllnessToday {
  resting_hr: number | null;
  rmssd: number | null;      // nocturnal RMSSD (ms)
  skin_temp: number | null;  // RELATIVE temp index
  resp_rate?: number | null; // nocturnal respiratory rate (breaths/min)
}
export interface IllnessHistory {
  resting_hr: number[];
  rmssd: number[];
  skin_temp: number[];
  resp_rate?: number[];
}
export interface IllnessOpts {
  /** Current menstrual-cycle phase, if the user tracks it — gates phase-expected
   *  RHR/temp rises so they don't masquerade as illness. */
  cyclePhase?: CyclePhase | null;
}

/** Invert a symmetric N×N matrix via Gauss-Jordan with partial pivoting; null if
 *  singular. Handles the 2-, 3- and 4-feature cases uniformly. */
function invMatrix(m: number[][]): number[][] | null {
  const n = m.length;
  const a = m.map((row, i) => [...row, ...Array.from({ length: n }, (_, j) => (i === j ? 1 : 0))]);
  for (let col = 0; col < n; col++) {
    let piv = col;
    for (let r = col + 1; r < n; r++) if (Math.abs(a[r][col]) > Math.abs(a[piv][col])) piv = r;
    if (Math.abs(a[piv][col]) < 1e-12) return null;
    [a[col], a[piv]] = [a[piv], a[col]];
    const d = a[col][col];
    for (let j = 0; j < 2 * n; j++) a[col][j] /= d;
    for (let r = 0; r < n; r++) {
      if (r === col) continue;
      const f = a[r][col];
      for (let j = 0; j < 2 * n; j++) a[r][j] -= f * a[col][j];
    }
  }
  return a.map((row) => row.slice(n));
}

// Signals whose elevation is expected through the luteal/menstrual phase — not illness.
const CYCLE_EXPECTED = new Set(['rhr', 'temp']);

/**
 * calcIllness(today, history, opts?). Needs ≥7 days of baseline per feature and
 * ≥2 present features. Distance threshold 2.5 (≈ χ² 95th pct). Tier ESTIMATE;
 * "a signal, not a diagnosis." When opts.cyclePhase is luteal/menstruation and the
 * only deviating signals are RHR/temp, the signal is suppressed (phase-expected).
 */
export function calcIllness(
  today: IllnessToday,
  history: IllnessHistory,
  opts?: IllnessOpts,
): Metric<IllnessValue> {
  const NOTE = 'a signal, not a diagnosis';
  // Build aligned feature set from whatever is present today + has ≥7 baseline.
  type Feat = { key: string; label: string; today: number; hist: number[]; dir: 1 | -1 };
  const cand: Feat[] = [];
  if (today.resting_hr != null && history.resting_hr.length >= 7)
    cand.push({ key: 'rhr', label: 'Resting HR', today: today.resting_hr, hist: history.resting_hr, dir: 1 });
  if (today.rmssd != null && history.rmssd.length >= 7)
    cand.push({ key: 'rmssd', label: 'HRV (RMSSD)', today: today.rmssd, hist: history.rmssd, dir: -1 });
  if (today.skin_temp != null && history.skin_temp.length >= 7)
    cand.push({ key: 'temp', label: 'Skin temperature', today: today.skin_temp, hist: history.skin_temp, dir: 1 });
  if (today.resp_rate != null && (history.resp_rate?.length ?? 0) >= 7)
    cand.push({ key: 'resp', label: 'Respiratory rate', today: today.resp_rate, hist: history.resp_rate!, dir: 1 });

  const none = (): Metric<IllnessValue> => ({
    signal: false, distance: null, triggers: [], note: NOTE,
    confidence: 0, tier: 'ESTIMATE', inputs_used: [],
  });
  if (cand.length < 2) return none();

  // Per-feature z (in the illness direction: dir·(x−μ)/σ; positive = toward illness).
  const z = cand.map((f) => {
    const mu = mean(f.hist), sd = stddev(f.hist);
    return sd > 0 ? f.dir * (f.today - mu) / sd : 0;
  });

  const lens = cand.map((f) => f.hist.length);
  const minLen = Math.min(...lens);
  let distance: number;
  const drivers: Driver[] = [];
  const dim = cand.length;
  const dvec = z; // standardized deviation vector
  if (dim >= 2 && minLen >= 7) {
    // Correlation matrix over the overlapping tail (standardized → correlation).
    const tail = cand.map((f) => f.hist.slice(-minLen));
    const stds = tail.map((h) => ({ mu: mean(h), sd: stddev(h) || 1 }));
    const Z = tail.map((h, k) => h.map((v) => (v - stds[k].mu) / stds[k].sd));
    const corr: number[][] = [];
    for (let a = 0; a < dim; a++) {
      corr[a] = [];
      for (let b = 0; b < dim; b++) {
        let s = 0; for (let t = 0; t < minLen; t++) s += Z[a][t] * Z[b][t];
        corr[a][b] = s / (minLen - 1);
      }
    }
    // Mahalanobis² = dvecᵀ · C⁻¹ · dvec (using correlation since dvec is already z).
    const inv = invMatrix(corr);
    if (inv) {
      let d2 = 0;
      for (let a = 0; a < dim; a++) for (let b = 0; b < dim; b++) d2 += dvec[a] * inv[a][b] * dvec[b];
      distance = Math.sqrt(Math.max(0, d2));
    } else {
      distance = Math.sqrt(dvec.reduce((s, v) => s + v * v, 0)); // diag fallback
    }
  } else {
    distance = Math.sqrt(dvec.reduce((s, v) => s + v * v, 0));
  }

  const metricFor = (key: string): string =>
    key === 'rmssd' ? 'hrv' : key === 'rhr' ? 'rhr' : key === 'resp' ? 'resp' : 'temp';
  const inputName = (key: string): string =>
    key === 'rmssd' ? 'hrv_rmssd' : key === 'rhr' ? 'resting_hr' : key === 'resp' ? 'resp_rate' : 'skin_temp';
  const triggers: string[] = [];
  cand.forEach((f, k) => {
    if (z[k] > 0.75) {
      triggers.push(f.key);
      drivers.push({
        label: f.label, contribution: round(z[k], 2), detail: `${round(z[k], 1)}σ toward illness`,
        ref: { metric: metricFor(f.key), scale: 'day' },
      });
    }
  });

  // Signal: distance past threshold AND ≥2 features deviating toward illness.
  let signal = distance > 2.5 && triggers.length >= 2;
  let note = NOTE;
  // Cycle-aware gate: through the luteal/menstrual phase, a temp & RHR rise is
  // expected. If those are the ONLY deviations, don't flag illness — but still
  // fire when HRV or respiration also shift (not explained by the cycle).
  const inCyclePhase = opts?.cyclePhase === 'luteal' || opts?.cyclePhase === 'menstruation';
  if (signal && inCyclePhase) {
    const corroborating = triggers.filter((t) => !CYCLE_EXPECTED.has(t));
    if (corroborating.length === 0) {
      signal = false;
      note = `${NOTE} (a rise in temperature & resting HR can be expected in this phase of your cycle)`;
    }
  }
  const confidence = Math.min(0.6, (minLen / 30) * (cand.length / 4));

  return {
    signal, distance: round(distance, 2), triggers, note,
    confidence: round(confidence, 4), tier: 'ESTIMATE',
    inputs_used: cand.map((f) => inputName(f.key)),
    drivers,
  };
}
