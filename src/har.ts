// §HAR — Human Activity Recognition from wrist accelerometer windows.
// Method: Mannini et al., Med Sci Sports Exerc 2013 ("Activity recognition using
// a single accelerometer placed at the wrist or ankle"), wrist configuration.
// Per ~4 s window we extract Mannini's feature set (time-domain + frequency-domain
// + db10 wavelet energies) and classify with TRANSPARENT cadence/power thresholds
// (ESTIMATE tier) — no trained model yet (we have no labelled data). The feature
// vector is the same one a future SVM would consume, so the upgrade path is clean.
//
// HONEST SCOPE: this only ever runs on LIVE high-rate stream data (R10/0x33,
// ~100 Hz) — flash-drained history is 1 Hz and CANNOT be motion-classified.
// Pure + synchronous (no I/O, no wasm): a db10 DWT on a 512-sample window is
// microseconds in plain TS; a wasm dependency would only puncture the pure model.

import { mean, stddev } from './util';
import type { ActivityClass } from './types';

export type { ActivityClass };

export interface HarFeatures {
  smv_mean: number;
  smv_std: number;
  smv_min: number;
  smv_max: number;
  total_power: number;   // spectral power in 0.3–15 Hz
  dom1_freq: number;     // strongest spectral peak in 0.3–15 Hz
  dom1_pow: number;
  dom2_freq: number;     // second peak
  dom2_pow: number;
  cad_freq: number;      // dominant peak inside the locomotion band 0.6–2.5 Hz
  cad_pow: number;
  dom1_ratio: number;    // dom1_pow / total_power (spectral peakiness → periodicity)
  freq_ratio_prev: number; // dom1_freq / previous window's dom1_freq (transition cue)
  wav_e5: number;        // db10 detail energy at level 5
  wav_e6: number;        // db10 detail energy at level 6
}

// ── db10 decomposition low-pass coefficients (PyWavelets `pywt.Wavelet('db10').dec_lo`).
//    Validated in tests via Σh=√2 and Σh²=1. Source: wavelets.pybytes.com / PyWavelets.
export const DB10_LO: number[] = [
  2.667005790055555358661744877130858277192498290851289932779975e-02,
  1.881768000776914890208929736790939942702546758640393484348595e-01,
  5.272011889317255864817448279595081924981402680840223445318549e-01,
  6.884590394536035657418717825492358539771364042407339537279681e-01,
  2.811723436605774607487269984455892876243888859026150413831543e-01,
  -2.498464243273153794161018979207791000564669737132073715013121e-01,
  -1.959462743773770435042992543190981318766776476382778474396781e-01,
  1.273693403357932600826772332014009770786177480422245995563097e-01,
  9.305736460357235116035228983545273226942917998946925868063974e-02,
  -7.139414716639708714533609307605064767292611983702150917523756e-02,
  -2.945753682187581285828323760141839199388200516064948779769654e-02,
  3.321267405934100173976365318215912897978337413267096043323351e-02,
  3.606553566956169655423291417133403299517350518618994762730612e-03,
  -1.073317548333057504431811410651364448111548781143923213370333e-02,
  1.395351747052901165789318447957707567660542855688552426721117e-03,
  1.992405295185056117158742242640643211762555365514105280067936e-03,
  -6.858566949597116265613709819265714196625043336786920516211903e-04,
  -1.164668551292854509514809710258991891527461854347597362819235e-04,
  9.358867032006959133405013034222854399688456215297276443521873e-05,
  -1.326420289452124481243667531226683305749240960605829756400674e-05,
];

/** Quadrature-mirror high-pass: g[k] = (−1)^k · h[N−1−k]. */
function db10Hi(): number[] {
  const N = DB10_LO.length;
  return DB10_LO.map((_, k) => (k % 2 === 0 ? 1 : -1) * DB10_LO[N - 1 - k]);
}
const DB10_HI = db10Hi();

/** One DWT level with periodic ('wrap') boundary → {approx, detail} (downsampled by 2). */
function dwtStep(sig: number[], lo: number[], hi: number[]): { a: number[]; d: number[] } {
  const n = sig.length, L = lo.length;
  const half = Math.floor(n / 2);
  const a = new Array<number>(half).fill(0);
  const d = new Array<number>(half).fill(0);
  for (let i = 0; i < half; i++) {
    let sa = 0, sd = 0;
    for (let k = 0; k < L; k++) {
      const idx = (2 * i + k) % n; // periodic extension
      sa += lo[k] * sig[idx];
      sd += hi[k] * sig[idx];
    }
    a[i] = sa; d[i] = sd;
  }
  return { a, d };
}

/** Detail-coefficient energy (Σ d²) at each level 1..levels via db10 DWT. */
export function dwtDetailEnergies(signal: number[], levels: number): number[] {
  let a = signal.slice();
  const out: number[] = [];
  for (let lvl = 1; lvl <= levels; lvl++) {
    if (a.length < 2) { out.push(0); continue; }
    const { a: na, d } = dwtStep(a, DB10_LO, DB10_HI);
    out.push(d.reduce((s, v) => s + v * v, 0));
    a = na;
  }
  return out;
}

// ── 4th-order Butterworth low-pass = two RBJ biquad sections (Butterworth Qs). ──
function biquadLP(sig: number[], fs: number, fc: number, q: number): number[] {
  const w0 = (2 * Math.PI * fc) / fs;
  const cosw = Math.cos(w0), sinw = Math.sin(w0);
  const alpha = sinw / (2 * q);
  const a0 = 1 + alpha;
  const b0 = ((1 - cosw) / 2) / a0, b1 = (1 - cosw) / a0, b2 = ((1 - cosw) / 2) / a0;
  const a1 = (-2 * cosw) / a0, a2 = (1 - alpha) / a0;
  const out = new Array<number>(sig.length);
  // Initialise to steady state at the first sample so the ~1 g DC gravity offset
  // doesn't ring up a 0→1 startup transient (which would inflate power/variance).
  const s0 = sig.length ? sig[0] : 0;
  let x1 = s0, x2 = s0, y1 = s0, y2 = s0;
  for (let i = 0; i < sig.length; i++) {
    const x0 = sig[i];
    const y0 = b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2;
    x2 = x1; x1 = x0; y2 = y1; y1 = y0; out[i] = y0;
  }
  return out;
}
/** 15 Hz 4th-order Butterworth low-pass (Mannini preprocessing). */
function butterLP4(sig: number[], fs: number, fc = 15): number[] {
  return biquadLP(biquadLP(sig, fs, fc, 0.54119610), fs, fc, 1.30656296);
}

function nextPow2(n: number): number { let p = 1; while (p < n) p <<= 1; return p; }

/** Iterative radix-2 FFT power spectrum (length N/2+1), N = next pow2 of input. */
function powerSpectrum(sig: number[]): number[] {
  const N = nextPow2(sig.length);
  const re = new Float64Array(N), im = new Float64Array(N);
  for (let i = 0; i < sig.length; i++) re[i] = sig[i];
  // bit-reversal permutation
  for (let i = 1, j = 0; i < N; i++) {
    let bit = N >> 1;
    for (; j & bit; bit >>= 1) j ^= bit;
    j ^= bit;
    if (i < j) { const tr = re[i]; re[i] = re[j]; re[j] = tr; const ti = im[i]; im[i] = im[j]; im[j] = ti; }
  }
  for (let len = 2; len <= N; len <<= 1) {
    const ang = (-2 * Math.PI) / len;
    const wr = Math.cos(ang), wi = Math.sin(ang);
    for (let i = 0; i < N; i += len) {
      let cr = 1, ci = 0;
      for (let k = 0; k < len / 2; k++) {
        const ur = re[i + k], ui = im[i + k];
        const vr = re[i + k + len / 2] * cr - im[i + k + len / 2] * ci;
        const vi = re[i + k + len / 2] * ci + im[i + k + len / 2] * cr;
        re[i + k] = ur + vr; im[i + k] = ui + vi;
        re[i + k + len / 2] = ur - vr; im[i + k + len / 2] = ui - vi;
        const ncr = cr * wr - ci * wi; ci = cr * wi + ci * wr; cr = ncr;
      }
    }
  }
  const half = N / 2;
  const pow = new Array<number>(half + 1);
  for (let i = 0; i <= half; i++) pow[i] = (re[i] * re[i] + im[i] * im[i]) / N;
  return pow;
}

/**
 * extractHarFeaturesFromSmv(smvRaw, fs, prevDomFreq?) — Mannini feature set from the
 * accel-vector MAGNITUDE signal (= SMV). This is the primary entry point: the band's
 * decoders give us per-sample |accel| (frameAccel `mags`), which IS the SMV, so the
 * ingest path feeds it directly. The 15 Hz Butterworth LP is applied to the magnitude.
 */
export function extractHarFeaturesFromSmv(smvRaw: number[], fs: number, prevDomFreq = 0): HarFeatures {
  const smv = butterLP4(smvRaw, fs); // 15 Hz LP on the magnitude
  const smv_mean = mean(smv), smv_std = stddev(smv);
  const smv_min = Math.min(...smv), smv_max = Math.max(...smv);

  // Spectrum of the DC-removed SMV.
  const ac = smv.map((v) => v - smv_mean);
  const pow = powerSpectrum(ac);
  const N = nextPow2(ac.length);
  const binHz = fs / N;
  const idxOf = (f: number) => Math.round(f / binHz);
  const loBin = Math.max(1, idxOf(0.3)), hiBin = Math.min(pow.length - 1, idxOf(15));
  let total = 0;
  for (let i = loBin; i <= hiBin; i++) total += pow[i];

  // top-2 peaks in 0.3–15 Hz
  let d1i = loBin, d2i = loBin;
  for (let i = loBin; i <= hiBin; i++) if (pow[i] > pow[d1i]) d1i = i;
  for (let i = loBin; i <= hiBin; i++) if (i !== d1i && pow[i] > pow[d2i]) d2i = i;
  // dominant peak in the locomotion band 0.6–2.5 Hz
  const cLo = Math.max(1, idxOf(0.6)), cHi = Math.min(pow.length - 1, idxOf(2.5));
  let ci = cLo;
  for (let i = cLo; i <= cHi; i++) if (pow[i] > pow[ci]) ci = i;

  const dom1_freq = d1i * binHz, dom1_pow = pow[d1i];
  const wav = dwtDetailEnergies(smv, 6);

  return {
    smv_mean, smv_std, smv_min, smv_max,
    total_power: total,
    dom1_freq, dom1_pow,
    dom2_freq: d2i * binHz, dom2_pow: pow[d2i],
    cad_freq: ci * binHz, cad_pow: pow[ci],
    dom1_ratio: total > 0 ? dom1_pow / total : 0,
    freq_ratio_prev: prevDomFreq > 0 ? dom1_freq / prevDomFreq : 1,
    wav_e5: wav[4] ?? 0,
    wav_e6: wav[5] ?? 0,
  };
}

/**
 * extractHarFeatures(x, y, z, fs, prevDomFreq?) — convenience wrapper for tri-axial
 * input (mainly tests/synthetic data): computes the SMV magnitude and delegates.
 */
export function extractHarFeatures(
  x: number[], y: number[], z: number[], fs: number, prevDomFreq = 0,
): HarFeatures {
  const n = Math.min(x.length, y.length, z.length);
  const smvRaw = new Array<number>(n);
  for (let i = 0; i < n; i++) smvRaw[i] = Math.sqrt(x[i] * x[i] + y[i] * y[i] + z[i] * z[i]);
  return extractHarFeaturesFromSmv(smvRaw, fs, prevDomFreq);
}

// Tunable thresholds (documented, ESTIMATE tier — replace with trained model later).
// We classify off dom1_freq (strongest 0.3–15 Hz peak = locomotion fundamental); the
// Mannini cad_freq feature (0.6–2.5 Hz band, capped) is kept for the future SVM.
const SED_POWER = 0.02;   // below this spectral power → not moving rhythmically
const SED_STD = 0.04;     // g
const PERIODIC = 0.25;    // dom1_ratio above this → clearly periodic (walk/run/cycle)
const RUN_HZ = 2.4;       // dominant ≥2.4 Hz → running cadence
const WALK_HZ = 1.3;      // 1.3–2.4 Hz → walking cadence
const CYCLE_HZ_LO = 0.6;  // 0.6–1.3 Hz with smooth motion → cycling pedal cadence

/**
 * classifyActivityWindow(f) — transparent threshold classifier over Mannini features.
 * Returns the class + a confidence from spectral peakiness & band power. ESTIMATE tier.
 */
export function classifyActivityWindow(f: HarFeatures): { cls: ActivityClass; confidence: number } {
  // Sedentary: low spectral power AND low motion variance.
  if (f.total_power < SED_POWER && f.smv_std < SED_STD) {
    return { cls: 'sedentary', confidence: 0.6 };
  }
  const periodic = f.dom1_ratio >= PERIODIC;
  const peakConf = Math.min(0.9, 0.4 + f.dom1_ratio); // peakier spectrum → higher confidence
  const cad = f.dom1_freq;

  if (periodic) {
    if (cad >= RUN_HZ) return { cls: 'run', confidence: peakConf };
    if (cad >= WALK_HZ) return { cls: 'walk', confidence: peakConf };
    if (cad >= CYCLE_HZ_LO && f.smv_std < SED_STD * 4)
      return { cls: 'cycle', confidence: peakConf * 0.9 }; // smooth low-cadence motion
  }
  // Elevated but non-periodic motion (irregular, no clean cadence) → resistance/lifting.
  if (f.smv_std >= SED_STD && !periodic) return { cls: 'lift', confidence: 0.45 };
  return { cls: 'other', confidence: 0.4 };
}

// ── Segmentation: per-window votes → smoothed phases (graceful activity switches) ──
export interface ClassVote { ts: number; cls: ActivityClass; conf: number }
export interface WorkoutSegment { start_ts: number; end_ts: number; type: ActivityClass; confidence: number }
export interface SegmentResult { primary: ActivityClass; segments: WorkoutSegment[]; type_confidence: number }

/** Mode of a class array (ties → highest mean confidence handled by caller). */
function modeClass(window: ClassVote[]): ActivityClass {
  const c: Record<string, number> = {};
  for (const v of window) c[v.cls] = (c[v.cls] ?? 0) + 1;
  let best: ActivityClass = window[0].cls, bestN = -1;
  for (const k of Object.keys(c)) if (c[k] > bestN) { bestN = c[k]; best = k as ActivityClass; }
  return best;
}

/**
 * segmentWorkout(votes, opts) — smooth the per-window class timeline (median filter to
 * kill blips) and run-length-encode into phases ≥ minPhaseSec, so a run→cycle or
 * lift→cardio switch becomes ONE workout with labelled phases (hysteresis, not flip-flop).
 * primary = longest phase; 'mixed' when no phase dominates (circuit/brick).
 */
export function segmentWorkout(
  votes: ClassVote[],
  opts: { smoothWin?: number; minPhaseSec?: number } = {},
): SegmentResult {
  const smoothWin = opts.smoothWin ?? 7;     // ~window count for median smoothing
  const minPhaseSec = opts.minPhaseSec ?? 180; // a phase must persist ≥3 min
  if (votes.length === 0) return { primary: 'other', segments: [], type_confidence: 0 };
  const sorted = [...votes].sort((a, b) => a.ts - b.ts);

  // Median-class smoothing over a sliding window (hysteresis against momentary blips).
  const smoothed: ClassVote[] = sorted.map((v, i) => {
    const half = Math.floor(smoothWin / 2);
    const win = sorted.slice(Math.max(0, i - half), Math.min(sorted.length, i + half + 1));
    return { ts: v.ts, cls: modeClass(win), conf: v.conf };
  });

  // Run-length encode into raw phases.
  const raw: WorkoutSegment[] = [];
  for (const v of smoothed) {
    const last = raw[raw.length - 1];
    if (last && last.type === v.cls) {
      last.end_ts = v.ts;
      last.confidence = (last.confidence + v.conf) / 2;
    } else {
      raw.push({ start_ts: v.ts, end_ts: v.ts, type: v.cls, confidence: v.conf });
    }
  }

  // Merge phases shorter than minPhaseSec into the neighbour (drop noise blips).
  const phases: WorkoutSegment[] = [];
  for (const seg of raw) {
    const dur = seg.end_ts - seg.start_ts;
    if (dur < minPhaseSec && phases.length > 0) {
      phases[phases.length - 1].end_ts = seg.end_ts; // absorb blip into prior phase
    } else if (dur < minPhaseSec && phases.length === 0) {
      phases.push({ ...seg }); // keep until a real phase appears
    } else {
      if (phases.length && phases[phases.length - 1].type === seg.type)
        phases[phases.length - 1].end_ts = seg.end_ts;
      else phases.push({ ...seg });
    }
  }

  // Primary = longest-duration phase; 'mixed' if the top phase is <50% of total.
  const totalDur = phases.reduce((s, p) => s + (p.end_ts - p.start_ts), 0) || 1;
  let top = phases[0];
  for (const p of phases) if ((p.end_ts - p.start_ts) > (top.end_ts - top.start_ts)) top = p;
  const topShare = (top.end_ts - top.start_ts) / totalDur;
  const primary: ActivityClass = topShare >= 0.5 ? top.type : 'other';
  const type_confidence = Math.round(top.confidence * topShare * 100) / 100;

  return { primary, segments: phases, type_confidence };
}
