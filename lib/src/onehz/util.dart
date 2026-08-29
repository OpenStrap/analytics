// 1 Hz-native analytics family — pure math utilities.
// dart:math only. No I/O, no clock, no randomness.
//
// All functions are pure. Where a statistic is undefined (empty input,
// degenerate variance), they return null rather than a fabricated value.

import 'dart:math' as math;

/// Mean, or null if empty.
double? mean(List<double> xs) {
  if (xs.isEmpty) return null;
  var s = 0.0;
  for (final x in xs) {
    s += x;
  }
  return s / xs.length;
}

/// Sample standard deviation (N-1), or null if <2 points.
double? stddev(List<double> xs) {
  if (xs.length < 2) return null;
  final m = mean(xs)!;
  var s = 0.0;
  for (final x in xs) {
    final d = x - m;
    s += d * d;
  }
  return math.sqrt(s / (xs.length - 1));
}

/// Population standard deviation (N), or null if empty.
double? stddevPop(List<double> xs) {
  if (xs.isEmpty) return null;
  final m = mean(xs)!;
  var s = 0.0;
  for (final x in xs) {
    final d = x - m;
    s += d * d;
  }
  return math.sqrt(s / xs.length);
}

/// Linear-interpolated percentile (p in [0,100]) of an ALREADY-ASCENDING list;
/// null if empty. For when you hold a sorted list already, or want several
/// percentiles of one window without re-sorting it each time.
///
/// Null on empty, never 0 — a 0.0 is a measurement, and an empty window is the
/// absence of one.
double? percentileSorted(List<double> sorted, double p) {
  if (sorted.isEmpty) return null;
  if (sorted.length == 1) return sorted[0];
  final rank = (p / 100) * (sorted.length - 1);
  final lo = rank.floor();
  final hi = rank.ceil();
  if (lo == hi) return sorted[lo];
  final frac = rank - lo;
  return sorted[lo] + (sorted[hi] - sorted[lo]) * frac;
}

/// Linear-interpolated percentile (p in [0,100]); null if empty.
double? percentile(List<double> values, double p) =>
    percentileSorted([...values]..sort(), p);

/// Median (linear-interpolated), or null if empty.
double? median(List<double> xs) => percentile(xs, 50);

/// Median absolute deviation, scaled to be a consistent estimator of σ for
/// normal data (× 1.4826). Returns null if empty. NOTE: on quantized data the
/// raw MAD can be 0 — callers must guard division (see [robustZ]).
double? mad(List<double> xs, {bool scaled = true}) {
  if (xs.isEmpty) return null;
  final m = median(xs)!;
  final dev = xs.map((x) => (x - m).abs()).toList();
  final raw = median(dev)!;
  return scaled ? raw * 1.4826 : raw;
}

/// The fastest cadence [sampleCadenceSeconds] will vouch for (seconds).
///
/// Above this the metrics that consume a cadence — time-in-zone credit, TRIMP
/// per-sample duration, the still-window sample count — have no calibration and
/// no validation data, so the helper abstains rather than picking a number.
/// It is a CEILING ON WHAT WE HAVE MEASURED, not a physical limit: raising it
/// is one edit here plus evidence for the metrics downstream.
const double maxSupportedCadenceSec = 300;

/// Gaps within this factor of the median count as belonging to the same mode.
/// 2× because every downstream use of a cadence — sample counts for a window,
/// one sample's worth of tail credit — degrades gracefully at a 2× error and
/// catastrophically at a 300× one, which is the failure this exists to stop.
const double _cadenceModeTolerance = 2.0;

/// The median must describe at least this share of the gaps. Below it the
/// stream has no single cadence (two interleaved sources, a burst-mode band)
/// and the median is the midpoint between two regimes rather than either of
/// them — a number that is wrong for both halves of the record.
const double _cadenceMinModeFraction = 0.5;

/// Measured sampling cadence (seconds) of a time-ordered stream — or NULL.
///
/// ONE helper for what used to be three near-duplicates with three signatures
/// (`StrainScorer.medianIntervalSeconds`, `HeartRateZones._medianIntervalSeconds`,
/// `AdvancedSleepStager._medianIntervalS`). Callers pass seconds; a stream held
/// in ms or ints maps at the call site.
///
/// IT ABSTAINS INSTEAD OF FALLING BACK. The three originals returned 1.0, 1.0
/// and 60 respectively when they could not measure a cadence — and the case
/// that reached those fallbacks was not "no data", it was "every gap exceeded
/// the plausibility filter", i.e. a device SLOWER than the filter. A 301 s band
/// therefore had every reading credited with one second: roughly a 300×
/// undercount, published at full confidence. An absent cadence has to become an
/// absent metric, which is this project's contract; a wrong one becomes a
/// wrong number nobody can see.
///
/// Returns null when:
///  * fewer than two samples, or no positive gap — nothing to measure;
///  * the median gap exceeds [maxSupportedCadenceSec] — a device we cannot
///    yet score (this is the 301 s case, and it is now absent, not 1.0);
///  * the median describes under [_cadenceMinModeFraction] of the gaps — see
///    that constant. Ordinary dropouts do NOT trip this: a night of 1 Hz with a
///    16 h hole still has essentially every gap at 1 s, and mild jitter (1 s
///    alternating with 2 s) stays inside [_cadenceModeTolerance].
///
/// There is deliberately NO floor at 1 s. All three originals had one; on a
/// 1 Hz substrate it never bound, and on a faster source it would have been a
/// fabrication in the small direction.
double? sampleCadenceSeconds(List<double> tsSec) {
  if (tsSec.length < 2) return null;
  final gaps = <double>[];
  for (var i = 1; i < tsSec.length; i++) {
    final g = tsSec[i] - tsSec[i - 1];
    // Non-positive gaps are duplicate or unsorted timestamps, not a cadence.
    // Pathological LONG gaps are deliberately kept: a dropout is a minority of
    // the gaps and cannot move a median, whereas filtering them out first is
    // exactly how a genuinely-slow device ended up indistinguishable from a
    // stream with no usable gaps at all.
    if (g > 0) gaps.add(g);
  }
  final m = median(gaps);
  if (m == null || m > maxSupportedCadenceSec) return null;
  var inMode = 0;
  for (final g in gaps) {
    if (g <= m * _cadenceModeTolerance && g * _cadenceModeTolerance >= m) {
      inMode++;
    }
  }
  if (inMode < gaps.length * _cadenceMinModeFraction) return null;
  return m;
}

/// Iglewicz–Hoaglin modified z-score of [x] against a sample, using
/// median + MAD. Returns null if MAD is 0 (degenerate / fully-quantized) so
/// the caller can fall back to a coarser test rather than divide by zero.
double? robustZ(double x, List<double> sample) => RobustScale.of(sample)?.z(x);

/// The median + MAD of a sample, computed once.
///
/// [robustZ] re-derives both on every call, which sorts the sample twice. When
/// scoring many values against the SAME unchanging sample — the usual case
/// inside a per-epoch loop — build one of these outside the loop instead.
/// Results are identical to [robustZ], including its null semantics: absent
/// for a sample under two values or a MAD of zero.
class RobustScale {
  final double med;
  final double scale;

  const RobustScale(this.med, this.scale);

  static RobustScale? of(List<double> sample) {
    if (sample.length < 2) return null;
    final m = median(sample)!;
    final s = mad(sample);
    if (s == null || s == 0) return null;
    return RobustScale(m, s);
  }

  double z(double x) => (x - med) / scale;
}

/// Ordinary z-score against a sample (mean+SD). Null if SD undefined or 0.
double? z(double x, List<double> sample) {
  final m = mean(sample);
  final sd = stddev(sample);
  if (m == null || sd == null || sd == 0) return null;
  return (x - m) / sd;
}

/// Ordinary-least-squares slope of y vs x (x defaults to 0..n-1). Null if <2.
double? olsSlope(List<double> y, [List<double>? x]) {
  final n = y.length;
  if (n < 2) return null;
  final xs = x ?? List<double>.generate(n, (i) => i.toDouble());
  final mx = mean(xs)!;
  final my = mean(y)!;
  var num = 0.0, den = 0.0;
  for (var i = 0; i < n; i++) {
    num += (xs[i] - mx) * (y[i] - my);
    den += (xs[i] - mx) * (xs[i] - mx);
  }
  return den == 0 ? null : num / den;
}

class LineFit {
  final double slope;
  final double intercept;
  const LineFit(this.slope, this.intercept);
}

/// OLS line fit (slope + intercept). Null if degenerate.
LineFit? olsFit(List<double> y, [List<double>? x]) {
  final n = y.length;
  if (n < 2) return null;
  final xs = x ?? List<double>.generate(n, (i) => i.toDouble());
  final s = olsSlope(y, xs);
  if (s == null) return null;
  final b = mean(y)! - s * mean(xs)!;
  return LineFit(s, b);
}

/// Theil–Sen robust slope estimator: median of all pairwise slopes. Robust to
/// outliers (breakdown ~29%). Null if <2 points or all x identical.
double? theilSen(List<double> y, [List<double>? x]) {
  final n = y.length;
  if (n < 2) return null;
  final xs = x ?? List<double>.generate(n, (i) => i.toDouble());
  final slopes = <double>[];
  for (var i = 0; i < n; i++) {
    for (var j = i + 1; j < n; j++) {
      final dx = xs[j] - xs[i];
      if (dx == 0) continue;
      slopes.add((y[j] - y[i]) / dx);
    }
  }
  return slopes.isEmpty ? null : median(slopes);
}

/// 6-dp rounding used for stable JSON output.
///
/// Returns `null` for a non-finite input. NaN/Infinity is not a measurement, and
/// `jsonEncode` THROWS on it — one bad field used to take down a whole
/// serialised bundle. Absence is the only honest encoding of "not a number".
double? round6(double x) {
  if (!x.isFinite) return null;
  return (x * 1e6).roundToDouble() / 1e6;
}

double roundTo(double x, int decimals) {
  final f = math.pow(10, decimals).toDouble();
  return (x * f).roundToDouble() / f;
}

/// One spectral estimate: power spectral DENSITY at an ordinary frequency.
///
/// UNITS — this is the whole contract, and getting it wrong has shipped a
/// "Total power 0.1 ms²" for a night whose true total was 1260 ms²:
/// [psd] is in (unit of y)² per Hz. For an RR series in ms sampled on beat
/// times in SECONDS, that is **ms²/Hz**. Integrating it over a band (see
/// [LombScargle.bandPower]) therefore yields **ms²**, the unit the HRV
/// literature reports LF/HF/VLF/total in.
class LsPoint {
  final double freqHz;
  final double psd;
  const LsPoint(this.freqHz, this.psd);
}

class LombScargle {
  final List<LsPoint> spectrum;
  const LombScargle(this.spectrum);

  /// Band power = ∫ PSD(f)·df over [loHz, hiHz), rectangular sum over the grid.
  ///
  /// Returns (unit of y)² — **ms² for an RR series in ms** (see [LsPoint.psd]).
  /// Integrated over the full resolvable band it approximates the series
  /// variance, i.e. SDNN²; that identity is the unit test for this scaling.
  double bandPower(double loHz, double hiHz) {
    var p = 0.0;
    for (var i = 0; i < spectrum.length; i++) {
      final f = spectrum[i].freqHz;
      if (f < loHz || f >= hiHz) continue;
      // Bin width: the step to the previous grid point, or (for the first grid
      // point) the step to the next. Starting the loop at i=1 used to drop the
      // grid's lowest point entirely, which zeroed narrow low-frequency bands.
      final df = i > 0
          ? spectrum[i].freqHz - spectrum[i - 1].freqHz
          : (spectrum.length > 1
              ? spectrum[1].freqHz - spectrum[0].freqHz
              : 0.0);
      p += spectrum[i].psd * df;
    }
    return p;
  }

  /// Peak frequency within [loHz,hiHz], or null if no grid points there.
  double? peakFreq(double loHz, double hiHz) {
    double? best;
    var bestP = double.negativeInfinity;
    for (final pt in spectrum) {
      if (pt.freqHz < loHz || pt.freqHz > hiHz) continue;
      if (pt.psd > bestP) {
        bestP = pt.psd;
        best = pt.freqHz;
      }
    }
    return best;
  }
}

/// Lomb–Scargle PSD for UNEVENLY-sampled data (Press & Rybicki 1989).
///
/// [t] sample times — pass SECONDS, so the grid and the output are in Hz.
/// [y] sample values. Computed on the supplied [freqsHz] grid. The series is
/// mean-subtracted; the τ phase-offset makes the estimate time-shift
/// invariant. Returns null if <4 points, zero variance, or zero time span.
///
/// UNITS: the returned [LsPoint.psd] is a PHYSICAL density in (unit of y)²/Hz —
/// NOT the dimensionless Horne–Baliunas variance-normalised power. The classic
/// normalisation divides the periodogram by the data variance, which cancels
/// the very unit the caller wants: `bandPower` then returns Hz, and labelling
/// it ms² understates a real 1260 ms² night as 0.1. So we keep the unnormalised
/// periodogram `0.5·(term1+term2)` and apply the standard one-sided
/// periodogram→density scaling `2·Δt`, with Δt the MEAN sample interval. The
/// identity that pins it: ∫PSD df over the resolvable band ≈ var(y).
///
/// Ratios of band powers (LF/HF, nu_lf, coherence) are unaffected by this
/// scaling — it is a single positive constant across the whole spectrum.
///
/// This operates on NATIVE sample times — no resampling — which is exactly why
/// it's the correct PSD for unevenly-sampled beat-time RR.
LombScargle? lombScargle(List<double> t, List<double> y, List<double> freqsHz) {
  final n = t.length;
  if (n < 4 || y.length != n || freqsHz.isEmpty) return null;
  final my = mean(y)!;
  final yc = [for (final v in y) v - my];
  var variance = 0.0;
  for (final v in yc) {
    variance += v * v;
  }
  variance /= (n - 1);
  if (variance <= 0) return null;

  var tMin = t[0], tMax = t[0];
  for (final ti in t) {
    if (ti < tMin) tMin = ti;
    if (ti > tMax) tMax = ti;
  }
  final span = tMax - tMin;
  if (span <= 0) return null;
  // One-sided periodogram → density: 2·Δt, with Δt the MEAN sample interval.
  final psdScale = 2.0 * span / (n - 1);

  final out = <LsPoint>[];
  for (final fHz in freqsHz) {
    final w = 2 * math.pi * fHz; // angular frequency (rad / time-unit)
    if (w == 0) {
      out.add(const LsPoint(0, 0));
      continue;
    }
    // τ: phase reference for time-shift invariance.
    var sin2 = 0.0, cos2 = 0.0;
    for (final ti in t) {
      sin2 += math.sin(2 * w * ti);
      cos2 += math.cos(2 * w * ti);
    }
    final tau = math.atan2(sin2, cos2) / (2 * w);

    var cNum = 0.0, cDen = 0.0, sNum = 0.0, sDen = 0.0;
    for (var i = 0; i < n; i++) {
      final arg = w * (t[i] - tau);
      final c = math.cos(arg);
      final s = math.sin(arg);
      cNum += yc[i] * c;
      cDen += c * c;
      sNum += yc[i] * s;
      sDen += s * s;
    }
    final term1 = cDen == 0 ? 0.0 : (cNum * cNum) / cDen;
    final term2 = sDen == 0 ? 0.0 : (sNum * sNum) / sDen;
    out.add(LsPoint(fHz, 0.5 * (term1 + term2) * psdScale));
  }
  return LombScargle(out);
}

/// Build a linear frequency grid [loHz, hiHz] with [n] points (inclusive).
List<double> freqGrid(double loHz, double hiHz, int n) {
  if (n < 1) return const [];
  if (n == 1) return [loHz];
  final step = (hiHz - loHz) / (n - 1);
  return List<double>.generate(n, (i) => loHz + step * i);
}

/// Natural log guard: ln of a positive value, else null.
double? safeLn(double x) => x > 0 ? math.log(x) : null;

/// Calendar-day index (days since epoch) for each `yyyy-MM-dd` label.
///
/// Trailing windows and "N nights running" counters in this package used to be
/// POSITIONAL — N rows, not N days — and the callers feed them only the days
/// that produced a derived row. After a wear gap a "28-day baseline" spanned
/// months, and `persistDays: 2` meant two RECORDED nights, so an elevated
/// Monday plus an elevated night three weeks later escalated an illness CUSUM
/// to red "sustained elevation". Index by these instead.
///
/// An unparseable label falls back to its position — that is exactly the old
/// behaviour, so a caller with non-ISO labels is no worse off than before.
List<int> calendarDays(List<String> dates) {
  final out = List<int>.filled(dates.length, 0);
  for (var i = 0; i < dates.length; i++) {
    final d = DateTime.tryParse(dates[i]);
    out[i] = d == null
        ? i
        : DateTime.utc(d.year, d.month, d.day).millisecondsSinceEpoch ~/
            86400000;
  }
  return out;
}

/// Average ranks, 1-based, ties sharing their mean rank.
///
/// Tie handling is not a detail wherever this is used: journal fields are full
/// of ties (mood is 1–5, most people log the same 2 coffees most days) and so
/// are quantised daily metrics. Ranking ties arbitrarily invents an ordering
/// nobody reported.
List<double> averageRanks(List<double> xs) {
  final idx = List<int>.generate(xs.length, (i) => i)
    ..sort((a, b) => xs[a].compareTo(xs[b]));
  final ranks = List<double>.filled(xs.length, 0);
  var i = 0;
  while (i < idx.length) {
    var j = i;
    while (j + 1 < idx.length && xs[idx[j + 1]] == xs[idx[i]]) {
      j++;
    }
    // Ranks are 1-based, so positions i..j map to ranks i+1..j+1.
    final shared = (i + 1 + j + 1) / 2.0;
    for (var k = i; k <= j; k++) {
      ranks[idx[k]] = shared;
    }
    i = j + 1;
  }
  return ranks;
}

/// Two-sided p for a standard-normal z. `2·(1 − Φ(|z|))`.
///
/// Numerical Recipes' `erfcc` — a Chebyshev fit to erfc with fractional error
/// under 1.2e-7 everywhere, which is four orders of magnitude finer than any
/// gate that reads it. No special-function dependency, no table.
double normalTwoSidedP(double zScore) {
  if (!zScore.isFinite) return 1.0;
  final x = zScore.abs() / math.sqrt2;
  final t = 1.0 / (1.0 + 0.5 * x);
  final ans = t *
      math.exp(-x * x -
          1.26551223 +
          t *
              (1.00002368 +
                  t *
                      (0.37409196 +
                          t *
                              (0.09678418 +
                                  t *
                                      (-0.18628806 +
                                          t *
                                              (0.27886807 +
                                                  t *
                                                      (-1.13520398 +
                                                          t *
                                                              (1.48851587 +
                                                                  t *
                                                                      (-0.82215223 +
                                                                          t * 0.17087277)))))))));
  return ans.clamp(0.0, 1.0);
}

/// Benjamini-Hochberg (1995) step-up FDR adjustment over a family of p-values.
///
/// Returns q-values POSITIONALLY ALIGNED to [ps]; a null p (a test that could
/// not be run) stays null and does not enter the family size — a test we
/// abstained from is not a test we performed.
///
/// WHY THIS IS NOT OPTIONAL where it is used: a per-test 0.05 gate over a grid
/// of 36 simultaneous tests produces ~2 "findings" from pure noise, every time,
/// for every user. BH controls the expected FRACTION of the published findings
/// that are false, which is the quantity a screen full of "this moves your
/// recovery" rows is actually promising.
///
/// The step-up enforcement (running minimum from the largest p downwards) is
/// the part everyone drops: without it the q-values are not monotone in p and a
/// weaker test can be published while a stronger one is refused.
List<double?> benjaminiHochberg(List<double?> ps) {
  final idx = <int>[
    for (var i = 0; i < ps.length; i++)
      if (ps[i] != null) i
  ]..sort((a, b) => ps[a]!.compareTo(ps[b]!));
  final m = idx.length;
  final out = List<double?>.filled(ps.length, null);
  var running = 1.0;
  for (var k = m - 1; k >= 0; k--) {
    final q = ps[idx[k]]! * m / (k + 1);
    running = math.min(running, q);
    out[idx[k]] = running;
  }
  return out;
}
