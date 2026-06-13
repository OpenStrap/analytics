// §Illness — multivariate under-recovery / illness signal. Combines the three
// signals that co-move when the body is fighting something: resting HR ↑,
// nocturnal HRV (RMSSD) ↓, skin temperature ↑. We compute the MAHALANOBIS distance
// (Mahalanobis 1936) of today's 3-vector from the user's personal baseline mean +
// covariance — one scalar that accounts for how these normally co-vary, rather
// than three independent flags. Validated approach for wearable illness detection
// (Mishra et al., Nat Biomed Eng 2020; Smarr et al., Sci Rep 2020).
// A SIGNAL, NOT A DIAGNOSIS — and only fires when deviations are in the illness
// direction (not just "unusual").
import type { Metric, IllnessValue, Driver, MetricRef } from './types';
import { mean, stddev, round } from './util';

export interface IllnessToday {
  resting_hr: number | null;
  rmssd: number | null;      // nocturnal RMSSD (ms)
  skin_temp: number | null;  // RELATIVE temp index
}
export interface IllnessHistory {
  resting_hr: number[];
  rmssd: number[];
  skin_temp: number[];
}

/** Invert a symmetric 3×3 matrix; null if singular. */
function inv3(m: number[][]): number[][] | null {
  const [a, b, c] = m[0], [d, e, f] = m[1], [g, h, i] = m[2];
  const A = e * i - f * h, B = -(d * i - f * g), C = d * h - e * g;
  const det = a * A + b * B + c * C;
  if (Math.abs(det) < 1e-12) return null;
  const id = 1 / det;
  return [
    [A * id, (c * h - b * i) * id, (b * f - c * e) * id],
    [B * id, (a * i - c * g) * id, (c * d - a * f) * id],
    [C * id, (b * g - a * h) * id, (a * e - b * d) * id],
  ];
}

/**
 * calcIllness(today, history). Needs ≥7 days of baseline per feature. Distance
 * threshold 2.5 (≈ χ²₃ 95th pct √7.8 ≈ 2.79; we use 2.5 to be a touch sensitive).
 * Tier ESTIMATE; "a signal, not a diagnosis."
 */
export function calcIllness(today: IllnessToday, history: IllnessHistory): Metric<IllnessValue> {
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

  // Covariance of the (illness-oriented) baseline features for Mahalanobis.
  const n = cand[0].hist.length;
  const lens = cand.map((f) => f.hist.length);
  const minLen = Math.min(...lens);
  let distance: number;
  const drivers: Driver[] = [];
  const dim = cand.length;
  // Standardized deviation vector.
  const dvec = z;
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
    let inv = dim === 3 ? inv3(corr) : null;
    if (dim === 2) {
      const det = corr[0][0] * corr[1][1] - corr[0][1] * corr[1][0];
      inv = Math.abs(det) < 1e-12 ? null : [[corr[1][1] / det, -corr[0][1] / det], [-corr[1][0] / det, corr[0][0] / det]];
    }
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

  const metricFor = (key: string): string => key === 'rmssd' ? 'hrv' : key === 'rhr' ? 'rhr' : 'temp';
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
  const signal = distance > 2.5 && triggers.length >= 2;
  const confidence = Math.min(0.6, (minLen / 30) * (cand.length / 3));

  return {
    signal, distance: round(distance, 2), triggers, note: NOTE,
    confidence: round(confidence, 4), tier: 'ESTIMATE',
    inputs_used: cand.map((f) => f.key === 'rmssd' ? 'hrv_rmssd' : f.key === 'rhr' ? 'resting_hr' : 'skin_temp'),
    drivers,
  };
}
