// §Steps — wrist pedometer (AN-2554, Analog Devices ADXL367 reference). PURE math
// over an already-decoded accelerometer-magnitude signal. The I/O around it — re-
// decoding the IMU frames from R2, ordering + per-minute grouping, persistence —
// lives in the backend runner (steps_imu.ts), exactly like the HRV/resp runners.
//
// Pipeline (per contiguous signal):
//   sum-of-abs accel → low-pass moving average → centered-window max/min peak
//   detection → dynamic threshold ± sensitivity/2 → CONFIRM consecutive "possible
//   steps" to confirm (the regularity gate that rejects waving/typing/handling —
//   validated to read 0 at rest). Params scaled to our ~100 Hz IMU; a calibration
//   gain corrects the normal ~10% wrist undercount (locked vs a 100-step ground-
//   truth walk: raw 90 → ×1.11 ≈ 100).

// ── locked AN-2554 parameters (calibrated on a 100-step ground-truth walk) ──
const FS = 100             // assembled IMU sample rate (Hz)
const FILTER = 8           // low-pass moving-average taps
const WINDOW = 33          // centered peak window (~0.33 s @100 Hz)
const SENS = 0.10          // g — dead-zone around the dynamic threshold
const THR_ORDER = 4        // dynamic-threshold smoothing buffer
const CONFIRM = 8          // consecutive possible steps before counting (rejects non-gait)
const MAXMIN_TIMEOUT = 120 // samples to find a min after a max (~1.2 s)
const GAIN = 1.11          // calibration: raw 90 → ~100 on the ground-truth walk

/** The locked parameters, exposed for documentation/tests. */
export const STEP_PARAMS = {
  FS, FILTER, WINDOW, SENS, THR_ORDER, CONFIRM, MAXMIN_TIMEOUT, GAIN,
} as const

/**
 * pedometer(sig) — AN-2554 time-domain step count over ONE contiguous
 * accelerometer-magnitude signal (g, ~100 Hz). Raw count, no calibration gain.
 */
export function pedometer(sig: number[]): number {
  const n = sig.length
  if (n < WINDOW) return 0
  // low-pass: trailing moving average
  const lp = new Array<number>(n)
  let acc = 0
  for (let i = 0; i < n; i++) {
    acc += sig[i]
    if (i >= FILTER) acc -= sig[i - FILTER]
    lp[i] = acc / Math.min(i + 1, FILTER)
  }
  const half = WINDOW >> 1
  // centered-window extrema candidates
  const cand: { i: number; max: boolean; v: number }[] = []
  for (let i = half; i < n - half; i++) {
    let isMax = true, isMin = true
    const v = lp[i]
    for (let j = i - half; j <= i + half; j++) {
      if (lp[j] > v) isMax = false
      if (lp[j] < v) isMin = false
      if (!isMax && !isMin) break
    }
    if (isMax) cand.push({ i, max: true, v })
    else if (isMin) cand.push({ i, max: false, v })
  }
  // dynamic threshold + CONFIRM-step regularity
  const dyn: number[] = []
  let dynVal = sig.reduce((s, v) => s + v, 0) / n
  let steps = 0, poss = 0, regulation = false
  let state: 'max' | 'min' = 'max'
  let curMax = 0, curMaxIdx = -1
  for (const c of cand) {
    if (state === 'max') {
      if (c.max) { curMax = c.v; curMaxIdx = c.i; state = 'min' }
    } else {
      if (c.max) { if (c.v > curMax) { curMax = c.v; curMaxIdx = c.i } continue }
      if (c.i - curMaxIdx > MAXMIN_TIMEOUT) { state = 'max'; poss = 0; regulation = false; continue }
      const mx = curMax, mn = c.v
      if (mx > dynVal + SENS / 2 && mn < dynVal - SENS / 2) {
        if (mx - mn > SENS) { dyn.push((mx + mn) / 2); if (dyn.length > THR_ORDER) dyn.shift(); dynVal = dyn.reduce((s, v) => s + v, 0) / dyn.length }
        poss++
        if (regulation) steps++
        else if (poss >= CONFIRM) { steps += poss; regulation = true }
      } else { poss = 0; regulation = false }
      state = 'max'
    }
  }
  return steps
}

/**
 * calcSteps(minuteSignals) — run the pedometer over each per-minute contiguous
 * signal, sum, and apply the calibration gain. `minuteSignals[m]` is the ordered
 * (ts, sub-frame) magnitude samples for minute m. Returns the calibrated daily total.
 */
export function calcSteps(minuteSignals: number[][]): number {
  let total = 0
  for (const sig of minuteSignals) total += pedometer(sig)
  return Math.round(total * GAIN)
}
