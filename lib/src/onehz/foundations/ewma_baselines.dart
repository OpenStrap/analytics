// FOUNDATION — Winsorized-EWMA personal baselines.
//
// Ported from `Baselines.swift` (itself ported from
// server/ingest/app/analysis/baselines.py). This is the baseline ENGINE that the
// recovery / illness / stress stack consumes: a robust, recency-weighted center
// (`baseline`) with an EWMA-of-absolute-deviation spread tracker, cold-start
// gating, early-life anti-anchoring (fast adapt + suspended hard-outlier gate +
// inflated Winsor band), hard-outlier rejection, and Winsor clamping.
//
// [Baselines.update] folds one night, [Baselines.foldHistory] replays a series,
// [Baselines.deviation] computes z / delta / ratio / in-normal-range.
//
// HONESTY: insufficient nights => status `calibrating`; NO nights => no state
// at all (null), never a baseline invented from the midpoint of the metric's
// physiological bounds. The engine never fabricates a baseline, trusted or
// otherwise.

import 'dart:math' as math;

/// Per-metric configuration for the baseline model (`MetricCfg`).
class MetricCfg {
  /// Physiological lower bound (hard reject below).
  final double minVal;

  /// Physiological upper bound (hard reject above).
  final double maxVal;

  /// Minimum [BaselineState.spread] — i.e. a floor in ABS-DEVIATION units, not
  /// in σ. (Multiply by 1.253 for the σ it implies.) The dead trailing-mean/SD
  /// path applied the same constant as a σ floor, which put the two paths 25 %
  /// apart on identical history; it has been deleted, so only this reading
  /// exists now.
  final double floorSpread;

  /// Baseline-center half-life (nights).
  final double halfLifeB;

  /// Spread half-life (nights, slower than center).
  final double halfLifeS;

  const MetricCfg({
    required this.minVal,
    required this.maxVal,
    required this.floorSpread,
    required this.halfLifeB,
    required this.halfLifeS,
  });
}

/// Baseline status flags (cold-start → trusted → stale).
enum BaselineStatus { calibrating, provisional, trusted, stale }

/// Immutable snapshot of a personal baseline for one metric after N nights.
class BaselineState {
  /// Robust EWMA center (the personal "mean").
  final double baseline;

  /// EWMA of absolute deviations, floored at cfg.floorSpread. Multiply by 1.253
  /// to approximate Gaussian σ.
  final double spread;

  /// Count of valid nights contributing to the state.
  final int nValid;

  /// Consecutive nights with no valid value (staleness tracking).
  final int nightsSinceUpdate;

  /// Cold-start / staleness status.
  final BaselineStatus status;

  const BaselineState({
    required this.baseline,
    required this.spread,
    required this.nValid,
    required this.nightsSinceUpdate,
    required this.status,
  });

  /// True iff fully trusted (not calibrating or stale).
  bool get trusted => status == BaselineStatus.trusted;

  /// True iff at least provisionally usable (nValid ≥ MIN_NIGHTS_SEED).
  bool get usable =>
      status == BaselineStatus.provisional || status == BaselineStatus.trusted;

  Map<String, dynamic> toJson() => {
        'baseline': baseline,
        'spread': spread,
        'n_valid': nValid,
        'nights_since_update': nightsSinceUpdate,
        'status': status.name,
      };
}

/// Three forms of deviation from a personal baseline.
class Deviation {
  /// Robust z-score: (value − baseline) / (1.253 × spread).
  final double z;

  /// Signed physical-units delta: value − baseline.
  final double delta;

  /// Fractional deviation: value / baseline − 1.
  final double ratio;

  /// True iff |z| ≤ 1.0.
  final bool inNormalRange;

  const Deviation({
    required this.z,
    required this.delta,
    required this.ratio,
    required this.inNormalRange,
  });
}

/// Winsorized-EWMA baseline engine — constants + update functions.
class Baselines {
  // ── Constants (baselines.py) ───────────────────────────────────────────────

  /// Winsorization clamp: fold only within ±WINSOR_K × spread.
  static const double winsorK = 3.0;

  /// Hard-reject gate: drop the night if > HARD_OUTLIER_K × spread away.
  static const double hardOutlierK = 5.0;

  /// Minimum valid nights before "provisionally" trusted.
  static const int minNightsSeed = 4;

  /// Minimum valid nights before fully trusted.
  static const int minNightsTrust = 14;

  /// Missing-night count after which a baseline is marked stale.
  static const int staleDays = 14;

  // ── Early-life anti-anchoring ───────────────────────────────────────────────

  /// Valid-night count below which the baseline is treated as "young".
  static const int earlyAdaptNights = 8;

  /// Center half-life (nights) used while the baseline is young.
  static const double earlyHalfLifeB = 3.0;

  /// Multiplier on spread for the Winsor clamp while young.
  static const double earlySpreadInflate = 2.5;

  /// Default per-metric configurations (HRV, resting HR, respiration, skin temp).
  static const Map<String, MetricCfg> metricCfg = {
    'hrv': MetricCfg(
        minVal: 5.0,
        maxVal: 250.0,
        floorSpread: 5.0,
        halfLifeB: 14.0,
        halfLifeS: 21.0),
    'resting_hr': MetricCfg(
        minVal: 30.0,
        maxVal: 120.0,
        floorSpread: 2.0,
        halfLifeB: 14.0,
        halfLifeS: 21.0),
    'resp': MetricCfg(
        minVal: 4.0,
        maxVal: 40.0,
        floorSpread: 0.5,
        halfLifeB: 14.0,
        halfLifeS: 21.0),
    'skin_temp': MetricCfg(
        minVal: 20.0,
        maxVal: 42.0,
        floorSpread: 0.3,
        halfLifeB: 14.0,
        halfLifeS: 21.0),
  };

  /// Convenience accessors for the standard configs.
  static MetricCfg get hrvCfg => metricCfg['hrv']!;
  static MetricCfg get restingHRCfg => metricCfg['resting_hr']!;
  static MetricCfg get respCfg => metricCfg['resp']!;
  static MetricCfg get skinTempCfg => metricCfg['skin_temp']!;

  /// Convert a half-life in nights to an EWMA smoothing factor.
  static double lambda(double halfLife) =>
      1.0 - math.pow(0.5, 1.0 / halfLife).toDouble();

  static BaselineStatus computeStatus(int nValid, int nightsSinceUpdate) {
    if (nightsSinceUpdate > staleDays && nValid >= minNightsSeed) {
      return BaselineStatus.stale;
    }
    if (nValid < minNightsSeed) return BaselineStatus.calibrating;
    if (nValid < minNightsTrust) return BaselineStatus.provisional;
    return BaselineStatus.trusted;
  }

  // ── Winsorized EWMA update (production model) ───────────────────────────────

  /// Incorporate one new nightly value into the baseline state.
  ///
  /// - `state == null`: seed the first night — or return NULL when that night
  ///   carries no usable value, because nothing has been observed yet and a
  ///   baseline for nothing does not exist.
  /// - `value == null` or out-of-range: skip-and-hold (carry forward).
  /// - hard outlier (> HARD_OUTLIER_K × spread): seen but not folded.
  /// - otherwise: Winsorized EWMA center + EWMA-abs-dev spread update.
  static BaselineState? update(
      BaselineState? state, double? value, MetricCfg cfg) {
    final lb = lambda(cfg.halfLifeB);
    final ls = lambda(cfg.halfLifeS);

    // First night ever.
    if (state == null) {
      if (value != null && cfg.minVal <= value && value <= cfg.maxVal) {
        return BaselineState(
            baseline: value,
            spread: cfg.floorSpread,
            nValid: 1,
            nightsSinceUpdate: 0,
            status: BaselineStatus.calibrating);
      }
      // No usable observation yet. This used to return a state whose baseline
      // was `(minVal + maxVal) / 2` — a number nobody measured — and
      // [deviation] then dutifully reported z = −13 against it. There is no
      // baseline; say so.
      return null;
    }

    // Missing night: skip-and-hold.
    if (value == null) {
      final m = state.nightsSinceUpdate + 1;
      return BaselineState(
          baseline: state.baseline,
          spread: state.spread,
          nValid: state.nValid,
          nightsSinceUpdate: m,
          status: computeStatus(state.nValid, m));
    }

    // Step 0: sanity gate — physiologically implausible → skip-and-hold.
    if (!(cfg.minVal <= value && value <= cfg.maxVal)) {
      final m = state.nightsSinceUpdate + 1;
      return BaselineState(
          baseline: state.baseline,
          spread: state.spread,
          nValid: state.nValid,
          nightsSinceUpdate: m,
          status: computeStatus(state.nValid, m));
    }

    final isYoung = state.nValid < earlyAdaptNights;

    // Hard outlier rejection (only once seeded AND no longer young).
    if (state.nValid >= minNightsSeed && !isYoung) {
      final dev = (value - state.baseline).abs();
      if (dev > hardOutlierK * state.spread) {
        // [nightsSinceUpdate] counts nights the baseline DID NOT MOVE — that is
        // the only reading `computeStatus` uses it for (stale after 14). A
        // rejected night moved nothing, so it increments, exactly like the
        // missing-night and out-of-range holds above. It used to reset to 0
        // here, so the same counter meant "nights since we heard from the
        // sensor" on one branch and "nights since the baseline moved" on the
        // other, and 14 straight rejected nights read as trusted.
        final m = state.nightsSinceUpdate + 1;
        return BaselineState(
            baseline: state.baseline,
            spread: state.spread,
            nValid: state.nValid,
            nightsSinceUpdate: m,
            status: computeStatus(state.nValid, m));
      }
    }

    // Step 1: Winsorized EWMA update.
    final effSpread =
        isYoung ? state.spread * earlySpreadInflate : state.spread;
    final effLb = isYoung ? lambda(earlyHalfLifeB) : lb;
    final lo = state.baseline - winsorK * effSpread;
    final hi = state.baseline + winsorK * effSpread;
    final clamped = math.max(lo, math.min(hi, value));
    final newBaseline = effLb * clamped + (1.0 - effLb) * state.baseline;

    // Spread uses the UNCLAMPED value so true deviations are tracked — and it
    // is measured against the baseline the night ARRIVED at, not the one the
    // night has already pulled toward itself. Measuring against `newBaseline`
    // (what shipped) makes the deviation identically (1 − λ_B)·(value −
    // baseline) for anything inside the Winsor band, so the spread tracker was
    // fed a systematically shrunken deviation: −4.83 % at halfLifeB = 14 and
    // −20.63 % while young (earlyHalfLifeB = 3). A too-tight spread inflates
    // every z downstream, which means MORE alerts, not fewer.
    final absDev = (value - state.baseline).abs();
    final newSpread =
        math.max(cfg.floorSpread, ls * absDev + (1.0 - ls) * state.spread);
    final newN = state.nValid + 1;

    return BaselineState(
        baseline: newBaseline,
        spread: newSpread,
        nValid: newN,
        nightsSinceUpdate: 0,
        status: computeStatus(newN, 0));
  }

  /// Replay an ordered sequence of nightly values (oldest first) to build state.
  /// `null` entries are treated as missing nights (skip-and-hold).
  ///
  /// NULL when no night in [values] was usable: with nothing observed there is
  /// no personal baseline, and the caller must withhold z / delta / ratio /
  /// in-normal-range rather than score today against an invented centre.
  static BaselineState? foldHistory(List<double?> values, MetricCfg cfg) {
    BaselineState? state;
    for (final v in values) {
      state = update(state, v, cfg);
    }
    return state;
  }

  // ── Deviation ───────────────────────────────────────────────────────────────

  /// Compute z / delta / ratio / in-normal-range for a value vs a baseline.
  /// z uses (value − baseline) / (1.253 × spread).
  ///
  /// NULL when the state rests on zero valid nights — there is nothing to
  /// deviate FROM. (The engine can no longer produce such a state; the guard
  /// holds the contract for a hand-built or rehydrated one.)
  static Deviation? deviation(double value, BaselineState state) {
    if (state.nValid == 0) return null;
    final sigma = math.max(1.253 * state.spread, 1e-9);
    final z = (value - state.baseline) / sigma;
    final delta = value - state.baseline;
    final ratio = state.baseline != 0 ? (value / state.baseline - 1.0) : 0.0;
    return Deviation(
        z: z, delta: delta, ratio: ratio, inNormalRange: z.abs() <= 1.0);
  }
}
