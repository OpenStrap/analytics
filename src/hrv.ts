// §HRV — heart-rate variability from beat-to-beat RR intervals. All published,
// standard algorithms (no heuristics):
//   • time-domain: RMSSD, SDNN, pNN50  — Task Force of ESC/NASPE, Circulation 1996
//   • frequency-domain: LF/HF via the LOMB–SCARGLE periodogram (RR is unevenly
//     sampled, so an FFT is wrong) — Laguna, Moody & Mark, IEEE TBME 1998
//   • Baevsky Stress Index (SI) from the RR histogram — Baevsky & Berseneva 2008
//   • respiratory rate from respiratory sinus arrhythmia (HF peak) — Charlton
//     et al., Physiol Meas 2016
//
// Inputs are a TIME-ORDERED RR-interval stream in milliseconds. We artifact-filter
// inside (physiological 300–2000 ms; successive |Δ| ≤ 200 ms drops ectopics/misses)
// so callers can pass the raw decoded RR.
//
// RR is decoded from type-24 records (parse_r24 rr_intervals_ms) and validated on
// real hardware (99.7% physiological; p50≈860 ms ≈ 70 bpm). This is NOT the parked
// R17/R11 live-optical path — it's the historical RR that ships in every record.
import { round, mean, stddev, median } from './util';
import type { Metric, HrvStabilityValue, IrregularValue } from './types';

/** Standard frequency bands (Hz) per the HRV Task Force (1996). */
export const VLF_BAND: [number, number] = [0.0033, 0.04];
export const LF_BAND: [number, number] = [0.04, 0.15];
export const HF_BAND: [number, number] = [0.15, 0.4];

export interface TimeDomainHrv {
  rmssd: number | null; // ms — short-term parasympathetic index (primary)
  sdnn: number | null;  // ms — overall variability
  pnn50: number | null; // % of successive diffs > 50 ms
  mean_rr: number | null;
  mean_hr: number | null;
  n_beats: number;
}

export interface FreqDomainHrv {
  lf: number | null;    // ms² absolute power in LF band
  hf: number | null;    // ms² absolute power in HF band
  lf_hf: number | null; // sympatho-vagal balance
  total_power: number | null;
  resp_rate: number | null; // breaths/min from the HF peak (RSA)
  resp_conf: number;        // 0..1 — HF peak prominence
}

/** Filter an RR stream to physiological intervals with successive-difference
 *  artifact rejection. Returns the cleaned, still time-ordered RR (ms). */
export function cleanRr(rr: number[]): number[] {
  const physio = rr.filter((x) => x >= 300 && x <= 2000);
  if (physio.length < 2) return physio;
  const out: number[] = [physio[0]];
  for (let i = 1; i < physio.length; i++) {
    // keep a beat only if it's within 200 ms of the previous kept beat (drops
    // ectopics / missed-beat doubles that would corrupt RMSSD).
    if (Math.abs(physio[i] - out[out.length - 1]) <= 200) out.push(physio[i]);
  }
  return out;
}

/** Time-domain HRV (RMSSD/SDNN/pNN50). Needs ≥ ~20 beats to be meaningful. */
export function timeDomainHrv(rrRaw: number[]): TimeDomainHrv {
  const rr = cleanRr(rrRaw);
  const n = rr.length;
  if (n < 20) return { rmssd: null, sdnn: null, pnn50: null, mean_rr: null, mean_hr: null, n_beats: n };

  const meanRr = rr.reduce((a, b) => a + b, 0) / n;
  const varNn = rr.reduce((a, b) => a + (b - meanRr) * (b - meanRr), 0) / (n - 1);
  const sdnn = Math.sqrt(varNn);
  let sumSq = 0, nn50 = 0;
  for (let i = 1; i < n; i++) {
    const d = rr[i] - rr[i - 1];
    sumSq += d * d;
    if (Math.abs(d) > 50) nn50++;
  }
  const rmssd = Math.sqrt(sumSq / (n - 1));
  const pnn50 = (nn50 / (n - 1)) * 100;

  return {
    rmssd: round(rmssd, 1),
    sdnn: round(sdnn, 1),
    pnn50: round(pnn50, 1),
    mean_rr: round(meanRr, 1),
    mean_hr: round(60000 / meanRr, 1),
    n_beats: n,
  };
}

/**
 * Lomb–Scargle periodogram power in [fLo,fHi) for an unevenly-sampled series
 * (t in seconds, x detrended). Classic estimator (Lomb 1976 / Scargle 1982):
 *   P(ω) = 1/2 [ (Σ x_i cos ω(t_i−τ))² / Σ cos²ω(t_i−τ)
 *             + (Σ x_i sin ω(t_i−τ))² / Σ sin²ω(t_i−τ) ]
 * with tan(2ωτ) = Σ sin 2ωt_i / Σ cos 2ωt_i. We sum P·Δf over the band to get
 * absolute band power (ms²), and also return the peak (freq, power) in-band.
 */
function lombScargleBand(
  t: number[], x: number[], fLo: number, fHi: number, df: number,
): { power: number; peakFreq: number; peakPower: number } {
  let power = 0, peakPower = -1, peakFreq = 0;
  for (let f = fLo; f < fHi; f += df) {
    const w = 2 * Math.PI * f;
    let s2 = 0, c2 = 0;
    for (const ti of t) { s2 += Math.sin(2 * w * ti); c2 += Math.cos(2 * w * ti); }
    const tau = Math.atan2(s2, c2) / (2 * w);
    let xc = 0, xs = 0, cc = 0, ss = 0;
    for (let i = 0; i < t.length; i++) {
      const arg = w * (t[i] - tau);
      const cosv = Math.cos(arg), sinv = Math.sin(arg);
      xc += x[i] * cosv; xs += x[i] * sinv;
      cc += cosv * cosv; ss += sinv * sinv;
    }
    const p = 0.5 * ((cc > 0 ? (xc * xc) / cc : 0) + (ss > 0 ? (xs * xs) / ss : 0));
    power += p * df;
    if (p > peakPower) { peakPower = p; peakFreq = f; }
  }
  return { power, peakFreq, peakPower };
}

/** Frequency-domain HRV + respiratory rate (RSA) via Lomb–Scargle. */
export function freqDomainHrv(rrRaw: number[]): FreqDomainHrv {
  const rr = cleanRr(rrRaw);
  const none: FreqDomainHrv = { lf: null, hf: null, lf_hf: null, total_power: null, resp_rate: null, resp_conf: 0 };
  if (rr.length < 30) return none;

  // Build the RR tachogram: cumulative beat time (s) vs detrended RR (ms).
  const t: number[] = [];
  let acc = 0;
  for (const r of rr) { acc += r / 1000; t.push(acc); }
  const mean = rr.reduce((a, b) => a + b, 0) / rr.length;
  const x = rr.map((r) => r - mean);
  const span = t[t.length - 1] - t[0];
  // Task Force 1996 rule: a band needs ≥10× the wavelength of its lower bound.
  // HF lower bound 0.15 Hz → ≥~67 s; LF lower bound 0.04 Hz → ≥250 s (~4 min).
  // So HF/resp are valid from ~1 min, but LF (and therefore LF/HF) are NOT
  // trustworthy below ~250 s — report them null rather than ship spectral noise.
  if (span < 60) return none;
  const HF_MIN_SPAN = 60;
  const LF_MIN_SPAN = 250;
  const df = 0.005; // 5 mHz grid

  const hfBand = lombScargleBand(t, x, HF_BAND[0], HF_BAND[1], df);
  const lfValid = span >= LF_MIN_SPAN;
  const lf = lfValid ? lombScargleBand(t, x, LF_BAND[0], LF_BAND[1], df).power : null;
  const vlf = lfValid ? lombScargleBand(t, x, VLF_BAND[0], VLF_BAND[1], df).power : null;
  const total = lf != null && vlf != null ? vlf + lf + hfBand.power : null;

  // Respiratory rate = HF peak frequency × 60 (breaths/min). Confidence = how
  // dominant that peak is vs the mean HF power (prominence). Valid from ~1 min.
  const hfValid = span >= HF_MIN_SPAN;
  const meanHf = hfBand.power / ((HF_BAND[1] - HF_BAND[0]) / df);
  const prominence = meanHf > 0 ? hfBand.peakPower / meanHf : 0;
  const respConf = hfValid ? Math.max(0, Math.min(1, (prominence - 1) / 4)) : 0; // ~1×→0, ~5×→1
  const respRate = hfBand.peakFreq * 60;

  return {
    lf: lf == null ? null : round(lf, 1),
    hf: round(hfBand.power, 1),
    lf_hf: lf != null && hfBand.power > 0 ? round(lf / hfBand.power, 3) : null,
    total_power: total == null ? null : round(total, 1),
    resp_rate: respConf >= 0.3 ? round(respRate, 1) : null,
    resp_conf: round(respConf, 3),
  };
}

/**
 * Baevsky Stress Index (SI) from the RR histogram (Baevsky & Berseneva 2008):
 *   SI = AMo / (2 · Mo · MxDMn)
 * Mo   = mode (most frequent RR), in SECONDS (50 ms bins)
 * AMo  = amplitude of mode = % of RR in the modal bin
 * MxDMn= variation range (max − min RR), in SECONDS
 * Higher SI ⇒ greater sympathetic activation. We report SI and its square root
 * (the commonly-reported, more linear form). Pure RR; not a heuristic.
 */
export function baevskyStressIndex(rrRaw: number[]): { si: number | null; sqrt_si: number | null; n_beats: number } {
  const rr = cleanRr(rrRaw);
  if (rr.length < 30) return { si: null, sqrt_si: null, n_beats: rr.length };
  const BIN = 50; // ms
  const bins = new Map<number, number>();
  let max = -Infinity, min = Infinity;
  for (const r of rr) {
    const b = Math.round(r / BIN) * BIN;
    bins.set(b, (bins.get(b) ?? 0) + 1);
    if (r > max) max = r;
    if (r < min) min = r;
  }
  let modeBin = 0, modeCount = 0;
  for (const [b, c] of bins) if (c > modeCount) { modeCount = c; modeBin = b; }
  const Mo = modeBin / 1000;                 // s
  const AMo = (modeCount / rr.length) * 100; // %
  const MxDMn = (max - min) / 1000;          // s
  if (Mo <= 0 || MxDMn <= 0) return { si: null, sqrt_si: null, n_beats: rr.length };
  const si = AMo / (2 * Mo * MxDMn);
  return { si: round(si, 1), sqrt_si: round(Math.sqrt(si), 2), n_beats: rr.length };
}

/**
 * calcHrvStability(rmssdSeries) — coefficient of variation of nocturnal RMSSD over
 * a window (SD/mean × 100). A low, stable CV tracks consistent autonomic balance;
 * a rising CV flags instability. Needs ≥5 nights. Tier HIGH.
 */
export function calcHrvStability(rmssdSeries: number[]): Metric<HrvStabilityValue> {
  const xs = rmssdSeries.filter((x) => x != null && x > 0);
  if (xs.length < 5) {
    return { cv: null, mean_rmssd: null, n: xs.length, confidence: round(xs.length / 7, 3), tier: 'HIGH', inputs_used: ['hrv_rmssd'] };
  }
  const m = mean(xs), sd = stddev(xs);
  return {
    cv: m > 0 ? round((sd / m) * 100, 1) : null,
    mean_rmssd: round(m, 1),
    n: xs.length,
    confidence: round(Math.min(1, xs.length / 14), 3),
    tier: 'HIGH',
    inputs_used: ['hrv_rmssd'],
  };
}

/**
 * calcIrregular(rrRaw) — irregular-rhythm SCREEN (NOT a diagnosis). From nocturnal
 * RR we compute the Poincaré descriptors (SD1 = RMSSD/√2, SD2 = √(2·SDNN² − ½·RMSSD²))
 * and the fraction of beats the artifact filter rejects as ectopic/irregular. A
 * sustained high ectopic fraction together with very high short-term variability
 * (pNN50) is the AF-like pattern. Deliberately conservative; surfaced like the
 * illness watch ("a screen, not a diagnosis — see a clinician").
 */
export function calcIrregular(rrRaw: number[]): Metric<IrregularValue> {
  const NOTE = 'a screen, not a diagnosis';
  const physio = rrRaw.filter((x) => x >= 300 && x <= 2000);
  const cleaned = cleanRr(rrRaw);
  const td = timeDomainHrv(rrRaw);
  if (physio.length < 100 || td.rmssd == null || td.sdnn == null || td.pnn50 == null) {
    return { flag: false, sd1: null, sd2: null, ratio: null, pnn50: td.pnn50, ectopic_frac: null, note: NOTE, confidence: 0, tier: 'ESTIMATE', inputs_used: [] };
  }
  const sd1 = td.rmssd / Math.SQRT2;
  const sd2 = Math.sqrt(Math.max(0, 2 * td.sdnn * td.sdnn - 0.5 * td.rmssd * td.rmssd));
  const ratio = sd2 > 0 ? sd1 / sd2 : null;
  const ectopicFrac = physio.length > 0 ? 1 - cleaned.length / physio.length : 0;
  // Conservative AF-like pattern: a fifth+ of beats irregular AND very high pNN50.
  const flag = ectopicFrac > 0.20 && td.pnn50 > 30 && sd1 > 60;
  return {
    flag,
    sd1: round(sd1, 1), sd2: round(sd2, 1),
    ratio: ratio == null ? null : round(ratio, 2),
    pnn50: td.pnn50,
    ectopic_frac: round(ectopicFrac, 3),
    note: NOTE,
    confidence: round(Math.min(1, physio.length / 300), 3),
    tier: 'ESTIMATE',
    inputs_used: ['rr_intervals'],
  };
}

/** §Daytime HRV — waking-hours RMSSD timeline (ultradian autonomic rhythm). */
export interface DaytimeHrvValue {
  rmssd_median: number | null;          // median of per-window RMSSD across the day
  series: { ts: number; rmssd: number }[]; // per-window RMSSD (ultradian rhythm / stress timeline)
  lowest_ts: number | null;             // window with the lowest RMSSD (most-stressed point)
  n_windows: number;
}

/**
 * calcDaytimeHrv(byMinute, bucketSec=300) — HRV across the WAKING day (not just sleep).
 * `byMinute` is per-minute RR arrays (ms) over the daytime window. We bucket RR into
 * fixed windows (default 5 min) and run the standard time-domain RMSSD per window with
 * enough beats → an ultradian HRV / daytime-stress timeline. Tier HIGH (published
 * RMSSD); abstains (null) when too few windows have usable RR — no fabrication.
 */
export function calcDaytimeHrv(
  byMinute: { ts: number; rr: number[] }[],
  bucketSec = 300,
): Metric<DaytimeHrvValue> {
  const buckets = new Map<number, { ts: number; rr: number[] }>();
  for (const m of byMinute) {
    if (!m.rr || m.rr.length === 0) continue;
    const key = Math.floor(m.ts / bucketSec);
    const b = buckets.get(key) ?? { ts: key * bucketSec, rr: [] };
    for (const v of m.rr) b.rr.push(v);
    buckets.set(key, b);
  }
  const series: { ts: number; rmssd: number }[] = [];
  for (const b of [...buckets.values()].sort((a, c) => a.ts - c.ts)) {
    const td = timeDomainHrv(b.rr);
    if (td.rmssd != null) series.push({ ts: b.ts, rmssd: td.rmssd });
  }
  if (series.length < 3) {
    return { rmssd_median: null, series, lowest_ts: null, n_windows: series.length, confidence: 0, tier: 'HIGH', inputs_used: ['rr_intervals'] };
  }
  const vals = series.map((s) => s.rmssd);
  let lowest = series[0];
  for (const s of series) if (s.rmssd < lowest.rmssd) lowest = s;
  return {
    rmssd_median: round(median(vals) ?? 0, 1),
    series,
    lowest_ts: lowest.ts,
    n_windows: series.length,
    confidence: round(Math.min(1, series.length / 24), 3), // ~2 h of windows → full
    tier: 'HIGH',
    inputs_used: ['rr_intervals'],
  };
}
