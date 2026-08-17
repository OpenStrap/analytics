// RESPIRATION TIER-1 — CVHR / ACAT apnea SCREEN (Hayano 2011).
//
// Cyclic Variation of Heart Rate is the cardiac signature of sleep-disordered
// breathing: each apnea/hypopnea episode produces a bradycardia during the
// event followed by a tachycardia at the arousal/resumption of breathing,
// recurring with a ~20–120 s period. Hayano's Autonomic Cardiac Activity
// (ACAT) / ACT algorithm scores these cycles RR-only (r≈0.84 vs AHI), needs
// zero calibration, and runs all night on our continuous beat-to-beat RR — our
// structural edge.
//
// Method (ACAT-style, deterministic):
//   1. Build a 1 Hz HR-equivalent envelope from cleaned NN (instantaneous HR
//      = 60000/NN), smoothed with a 2nd-order (quadratic) Savitzky-Golay-like
//      local polynomial to suppress beat jitter while preserving cycle shape.
//   2. An adaptive baseline — the sliding MEDIAN over a ~130 s window, which
//      spans ≥2 apnea cycles so it tracks the eupneic level without being
//      pulled into any single event. The bradycardia is an NN MAXIMUM (NN ↑ ⇔
//      HR ↓), so the scored quantity is the POSITIVE excursion above that
//      baseline; negative excursions (the recovery tachycardia) are clipped.
//      A run clears the baseline when it exceeds max(0.5 × the 75th percentile
//      of the positive excursions, 5 ms) — the only percentile in this file.
//   3. Keep a run as a CVHR cycle only if its width is 10–120 s AND its
//      depth-to-width ratio > 0.7 ms/s (the steep bradycardia-then-tachycardia
//      signature, not slow drift).
//   4. CVHR cycles per hour => an apnea SCREEN index (NOT an AHI, NOT a
//      diagnosis). Report night-to-night variability caveat.
//
// HONESTY: this is a SCREEN. We never output an AHI or a clinical category, and
// we flag that single-night CVHR has substantial night-to-night variability.
// The denominator is OBSERVED time: the night is split at recording gaps, each
// contiguous stretch is analysed on its own, and the hole contributes neither
// interpolated beats nor hours. Dividing by the first-to-last span instead let
// a 2 h charging break cut the index from 80.0/h to 53.3/h on identical beats.

import 'dart:math' as math;
import '../types.dart';
import '../util.dart';

class CvhrResult {
  final int cycleCount; // detected CVHR cycles
  final double cvhrPerHour; // cycles / hour (the screen index)
  final double analyzedHours; // OBSERVED hours analysed (gaps excluded)

  /// Mean dip depth (ms of NN excursion) — NULL when no cycle was detected.
  /// It used to be 0 in that case, which serialised an absence as a
  /// measurement. `cycleCount == 0` and these being null are the same fact.
  final double? meanDepthMs;

  /// Mean dip width (s) — NULL when no cycle was detected. See [meanDepthMs].
  final double? meanWidthSec;

  /// [p25, p50, p75] of the per-cycle dip depths (ms). NULL when no cycle was
  /// detected. The mean alone hides the shape: a night of a few deep dips and a
  /// night of many shallow ones can share it. These are the raw quartiles of
  /// the same per-cycle list the means come from — no adjective attached, no
  /// threshold, and specifically no category.
  final List<double>? depthQuartilesMs;

  /// [p25, p50, p75] of the per-cycle widths (s) — the cycle LENGTH spread.
  /// See [depthQuartilesMs].
  final List<double>? widthQuartilesSec;
  const CvhrResult({
    required this.cycleCount,
    required this.cvhrPerHour,
    required this.analyzedHours,
    required this.meanDepthMs,
    required this.meanWidthSec,
    this.depthQuartilesMs,
    this.widthQuartilesSec,
  });
  Map<String, dynamic> toJson() => {
        'cycle_count': cycleCount,
        'cvhr_per_hour': round6(cvhrPerHour),
        'analyzed_hours': round6(analyzedHours),
        'mean_depth_ms': meanDepthMs == null ? null : round6(meanDepthMs!),
        'mean_width_sec': meanWidthSec == null ? null : round6(meanWidthSec!),
        'depth_quartiles_ms':
            depthQuartilesMs?.map(round6).toList(growable: false),
        'width_quartiles_sec':
            widthQuartilesSec?.map(round6).toList(growable: false),
      };
}

/// [p25, p50, p75] of [xs], or null when empty. Same linear-interpolated
/// percentile the rest of the package uses.
List<double>? _quartiles(List<double> xs) => xs.isEmpty
    ? null
    : [percentile(xs, 25)!, percentile(xs, 50)!, percentile(xs, 75)!];

/// CVHR / ACAT apnea screen on a cleaned NN series.
///
/// [nnMs] cleaned NN intervals (ms), [nnTimesMs] their cumulative beat times
/// (ms). [artifactFraction] from RR-correction. Tunables follow Hayano:
/// dip width 10–120 s, depth/width ratio > 0.7 ms/s, ~130 s baseline window.
///
/// Callers pass one unsegmented block (the whole sleep window), so a charging
/// or off-wrist stretch arrives here inline. Beats more than [maxGapSec] apart
/// start a NEW segment: each is resampled and scored on its own, and only the
/// segments' own spans enter [CvhrResult.analyzedHours]. The gap is not
/// interpolated across and is not charged to the denominator.
Metric<CvhrResult> cvhrApneaScreen(
  List<double> nnMs,
  List<double> nnTimesMs, {
  required double artifactFraction,
  double minWidthSec = 10,
  double maxWidthSec = 120,
  double depthWidthRatioMin = 0.7, // ms per second
  double envWindowSec = 130,
  double maxArtifact = 0.30,
  double maxGapSec = 30,
}) {
  const inputs = ['rr_cleaned', 'beat_times'];
  if (nnMs.length < 60 || nnTimesMs.length != nnMs.length) {
    return const Metric<CvhrResult>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'too few beats for a CVHR screen (need ≥60)',
    );
  }
  if (artifactFraction > maxArtifact) {
    return Metric<CvhrResult>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'artifact fraction ${round6(artifactFraction)} > gate '
          '— CVHR dip detection unreliable',
    );
  }

  final tSec = [for (final t in nnTimesMs) t / 1000.0];
  if (tSec.last - tSec.first <= 0) {
    return const Metric<CvhrResult>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'degenerate beat times',
    );
  }

  // SEGMENT AT GAPS. Beats more than [maxGapSec] apart are two recordings, not
  // one: interpolating a straight line across the hole invents a flat stretch
  // with no cycles in it, and charging the hole to `analyzedHours` divides a
  // real cycle count by time we never observed. Both push the index DOWN, so a
  // charging break used to read as an improvement.
  final segStart = <int>[0];
  for (var i = 1; i < tSec.length; i++) {
    if (tSec[i] - tSec[i - 1] > maxGapSec) segStart.add(i);
  }

  var cycleCount = 0;
  var analyzedHours = 0.0;
  final depths = <double>[]; // ms
  final widths = <double>[]; // s
  for (var s = 0; s < segStart.length; s++) {
    final lo = segStart[s];
    final hi = (s + 1 < segStart.length ? segStart[s + 1] : tSec.length) - 1;
    final segT = tSec.sublist(lo, hi + 1);
    final segNn = nnMs.sublist(lo, hi + 1);
    final spanSec = segT.last - segT.first;
    // Too short to hold even one cycle plus its baseline window — it also can't
    // be scored, so it contributes neither cycles nor hours.
    if (segT.length < 60 || spanSec < 60) continue;
    analyzedHours += spanSec / 3600.0;
    _scoreSegment(
      segT,
      segNn,
      minWidthSec: minWidthSec,
      maxWidthSec: maxWidthSec,
      depthWidthRatioMin: depthWidthRatioMin,
      envWindowSec: envWindowSec,
      onCycle: (depth, width) {
        cycleCount++;
        depths.add(depth);
        widths.add(width);
      },
    );
  }

  if (analyzedHours <= 0) {
    return const Metric<CvhrResult>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'no gap-free stretch long enough for a CVHR screen (<60 s)',
    );
  }

  final perHour = cycleCount / analyzedHours;
  final conf = clamp((1 - artifactFraction) * 0.85, 0.2, 0.85);
  return Metric<CvhrResult>(
    value: CvhrResult(
      cycleCount: cycleCount,
      cvhrPerHour: perHour,
      analyzedHours: analyzedHours,
      meanDepthMs: depths.isEmpty ? null : mean(depths),
      meanWidthSec: widths.isEmpty ? null : mean(widths),
      depthQuartilesMs: _quartiles(depths),
      widthQuartilesSec: _quartiles(widths),
    ),
    confidence: conf,
    tier: Tier.high,
    inputs_used: inputs,
    note: 'CVHR/ACAT (Hayano) apnea SCREEN — NOT a diagnosis, NOT an AHI; '
        'single-night CVHR has substantial night-to-night variability, '
        'interpret as a trend over multiple nights',
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// RESP-01 — the 30-night PERSONAL DISTRIBUTION.
//
// The per-night index above is not shippable on its own: single-night CVHR has
// substantial night-to-night variability, it fires on AF, on periodic breathing
// at altitude and on any arousal-rich fragmented night, and it is BLUNTED by
// beta-blockers, autonomic neuropathy and diabetes — so it misses real apnea
// too. Both directions are harm. What survives that is one statement about a
// user's OWN recent nights against their OWN earlier ones.
//
// WHAT THIS MAY NEVER BECOME: an AHI, a severity band, a per-night value on a
// screen, a finding about the user, or a notification. A quiet screen means
// NOTHING — that line is permanent copy, not a tooltip.
//
// RESP-02 (gate half) — nights where `irregular_rhythm_flag` fired are EXCLUDED
// here, not down-weighted. AF produces the same cyclic RR pattern this screen
// scores, so an AF night's index is not a weak apnea signal, it is a different
// signal wearing the same shape. The corroboration half of RESP-02 (10-second
// ENMO) is deliberately not built: it is new accel work, and its absence costs
// this aggregate nothing.

/// One stored night, as the aggregate needs it. Straight off `day_result`.
class CvhrNight {
  /// Local day label the night is filed under (used only for ordering/dedupe).
  final String dayKey;

  /// `respiration.cvhr_apnea.cvhr_per_hour` for that night.
  final double cvhrPerHour;

  /// `respiration.cvhr_apnea.analyzed_hours` — the OBSERVED, gap-excluded hours
  /// behind [cvhrPerHour], and this night's weight.
  final double analyzedHours;

  /// Whether `irregular_rhythm_flag` fired on that day. Null counts as NOT
  /// fired: the flag predates nothing here, but a night we cannot ask about is
  /// not a night we may silently drop from the denominator.
  final bool irregularRhythm;

  const CvhrNight({
    required this.dayKey,
    required this.cvhrPerHour,
    required this.analyzedHours,
    this.irregularRhythm = false,
  });
}

/// The result of the 30-night screen. Deliberately holds NO per-night value.
class CvhrDistribution {
  /// Nights that passed every gate and are behind [recentWeightedMean].
  final int nightsUsed;

  /// Nights dropped because `irregular_rhythm_flag` fired (RESP-02 cross-gate).
  final int nightsExcludedIrregular;

  /// Nights dropped for having under [minAnalyzedHoursPerNight] observed hours.
  final int nightsExcludedThin;

  /// Analyzed-hours-weighted mean cvhr/h over the whole retained window. This
  /// is the user's OWN usual level — it is not a threshold and has no published
  /// normal range.
  final double weightedMean;

  /// The same weighted mean over the most recent third of the retained nights.
  final double recentWeightedMean;

  /// [p25, p50, p75] of the retained nights' indices — the spread the recent
  /// mean is being read against.
  final List<double> quartiles;

  /// True when the recent nights sit above the retained distribution's own p75.
  /// This is the ONLY comparative statement the screen makes, and it is a
  /// statement about this user's own history, not about apnea.
  final bool aboveOwnUsual;

  const CvhrDistribution({
    required this.nightsUsed,
    required this.nightsExcludedIrregular,
    required this.nightsExcludedThin,
    required this.weightedMean,
    required this.recentWeightedMean,
    required this.quartiles,
    required this.aboveOwnUsual,
  });

  Map<String, dynamic> toJson() => {
        'nights_used': nightsUsed,
        'nights_excluded_irregular': nightsExcludedIrregular,
        'nights_excluded_thin': nightsExcludedThin,
        'weighted_mean': round6(weightedMean),
        'recent_weighted_mean': round6(recentWeightedMean),
        'quartiles': quartiles.map(round6).toList(growable: false),
        'above_own_usual': aboveOwnUsual,
      };
}

/// A night needs this many OBSERVED hours before it may weigh on the screen.
const double minAnalyzedHoursPerNight = 4.0;

/// And this many such nights must exist before the screen says anything.
const int minNightsForCvhrDistribution = 5;

/// Nights considered, newest-first, once the gates have run.
const int cvhrDistributionWindowNights = 30;

/// RESP-01 — the 30-night personal CVHR distribution.
///
/// [nights] in any order; the newest [cvhrDistributionWindowNights] retained
/// nights are used. Returns ABSENT — never a partial number — until at least
/// [minNightsForCvhrDistribution] nights clear both gates.
Metric<CvhrDistribution> cvhrPersonalDistribution(List<CvhrNight> nights) {
  const inputs = ['cvhr_apnea', 'irregular_rhythm_flag'];
  // Newest first, one row per day (a re-derive can leave two).
  final byDay = <String, CvhrNight>{};
  for (final n in nights) {
    byDay[n.dayKey] = n;
  }
  final sorted = byDay.values.toList()
    ..sort((a, b) => b.dayKey.compareTo(a.dayKey));

  var excludedIrregular = 0;
  var excludedThin = 0;
  final kept = <CvhrNight>[];
  for (final n in sorted) {
    if (kept.length >= cvhrDistributionWindowNights) break;
    if (!n.cvhrPerHour.isFinite || !n.analyzedHours.isFinite) continue;
    // RESP-02 cross-gate FIRST: an AF night is not a thin night, and counting
    // it as one would misreport why the screen is quiet.
    if (n.irregularRhythm) {
      excludedIrregular++;
      continue;
    }
    if (n.analyzedHours < minAnalyzedHoursPerNight) {
      excludedThin++;
      continue;
    }
    kept.add(n);
  }

  if (kept.length < minNightsForCvhrDistribution) {
    return Metric<CvhrDistribution>.absent(
      tier: Tier.relative,
      inputs_used: inputs,
      note: 'need_baseline:nights=${kept.length}/'
          '$minNightsForCvhrDistribution with ≥'
          '${minAnalyzedHoursPerNight.round()} analyzed hours '
          '(excluded ${excludedIrregular} for irregular rhythm, '
          '${excludedThin} too thinly observed)',
    );
  }

  double weighted(List<CvhrNight> xs) {
    var num = 0.0, den = 0.0;
    for (final n in xs) {
      num += n.cvhrPerHour * n.analyzedHours;
      den += n.analyzedHours;
    }
    return den > 0 ? num / den : 0.0;
  }

  final indices = [for (final n in kept) n.cvhrPerHour];
  // "Recent" is the newest third of the retained nights (≥2 by construction:
  // 5 nights ⇒ 2). One night is not a comparison.
  final recentCount = math.max(2, (kept.length / 3).round());
  final recent = kept.take(recentCount).toList();
  final all = weighted(kept);
  final rec = weighted(recent);
  final q = [
    percentile(indices, 25)!,
    percentile(indices, 50)!,
    percentile(indices, 75)!,
  ];

  return Metric<CvhrDistribution>(
    value: CvhrDistribution(
      nightsUsed: kept.length,
      nightsExcludedIrregular: excludedIrregular,
      nightsExcludedThin: excludedThin,
      weightedMean: all,
      recentWeightedMean: rec,
      quartiles: q,
      aboveOwnUsual: rec > q[2],
    ),
    // Relative tier on purpose: this compares the user only with themselves.
    tier: Tier.relative,
    // The floor is 5 nights, so a 5-night answer must not read like a 30-night
    // one. Confidence rises with the nights actually behind it.
    confidence: clamp(
        0.3 + 0.4 * (kept.length / cvhrDistributionWindowNights), 0.3, 0.7),
    inputs_used: inputs,
    note: 'CVHR is a CARDIAC SURROGATE, not a breathing measurement: this is '
        'how often the pattern showed up across ${kept.length} of your own '
        'nights, never an AHI, never a severity, never a per-night value. '
        'It also fires on atrial fibrillation (those nights are excluded), on '
        'periodic breathing at altitude and on any fragmented night, and it is '
        'blunted by beta-blockers, autonomic neuropathy and diabetes — so a '
        'quiet screen means nothing.',
  );
}

/// Score ONE gap-free stretch: resample → smooth → sliding-median baseline →
/// positive-excursion runs → width + steepness gates. Calls [onCycle] with
/// (depthMs, widthSec) per surviving cycle. [t] in seconds, [nn] in ms.
void _scoreSegment(
  List<double> t,
  List<double> nn, {
  required double minWidthSec,
  required double maxWidthSec,
  required double depthWidthRatioMin,
  required double envWindowSec,
  required void Function(double depthMs, double widthSec) onCycle,
}) {
  // Resample NN onto a uniform 1 Hz grid by piecewise-linear interpolation of
  // the tachogram (NN vs beat time). This gives evenly-spaced points for the
  // sliding-window baseline and the polynomial smoother. Only ever called on a
  // stretch with no gap larger than the caller's tolerance, so no interpolation
  // here spans a hole.
  final t0 = t.first;
  final nGrid = (t.last - t0).floor() + 1;
  final grid = List<double>.generate(nGrid, (i) => t0 + i);
  final nnGrid = _resampleLinear(t, nn, grid);

  // 2nd-order local-polynomial smoothing (Savitzky-Golay quadratic, ~7 s half
  // window) to suppress beat jitter while keeping the cyclic shape.
  final smooth = _savgolQuadratic(nnGrid, halfWin: 7);

  // Adaptive baseline over a ~130 s sliding median (spans ≥2 apnea cycles, so
  // it tracks the eupneic level without being pulled into individual dips).
  // The CVHR bradycardia shows up as a local NN MAXIMUM (NN ↑ ⇔ HR ↓) standing
  // proud of this baseline; the following tachycardia is the recovery valley.
  final halfEnv = (envWindowSec / 2).round();
  final base = List<double>.filled(nGrid, 0);
  for (var j = 0; j < nGrid; j++) {
    final lo = math.max(0, j - halfEnv);
    final hi = math.min(nGrid - 1, j + halfEnv);
    base[j] = median(smooth.sublist(lo, hi + 1)) ?? smooth[j];
  }
  // Baseline-subtracted bradycardic excursion (clip negatives — we only score
  // the NN-up bradycardia, not the tachycardia trough).
  final exc = [
    for (var j = 0; j < nGrid; j++) math.max(0.0, smooth[j] - base[j])
  ];

  // Prominence threshold: a dip must clear a robust noise floor AND a fraction
  // of the typical excursion amplitude. We anchor it BELOW the median positive
  // excursion (Hayano's adaptive amplitude criterion is permissive enough to
  // capture the whole bradycardia run, not just its tip) — a threshold at the
  // peak would clip the run width to a few seconds and miss the cycle.
  final posExc = [
    for (final e in exc)
      if (e > 0) e
  ];
  final excP75 = (posExc.isNotEmpty ? percentile(posExc, 75) : null) ?? 0;
  // half of the upper-quartile excursion: well inside each genuine dip's run.
  final prom = math.max(0.5 * excP75, 5.0); // ms

  // Find peaks of `exc`: local maxima exceeding `prom`, each isolated to one
  // contiguous super-threshold run (so one bradycardia = one cycle). Measure
  // the run width and the peak depth; apply the width + depth/width gates.
  var i = 0;
  while (i < nGrid) {
    if (exc[i] <= prom) {
      i++;
      continue;
    }
    final start = i;
    var peakDepth = 0.0;
    while (i < nGrid && exc[i] > prom) {
      if (exc[i] > peakDepth) peakDepth = exc[i];
      i++;
    }
    final widthSec = (i - start).toDouble(); // 1 Hz grid => samples == seconds
    if (widthSec < minWidthSec || widthSec > maxWidthSec) continue;
    // Depth-to-width steepness gate (ms per second): the bradycardia-tachycardia
    // swing is steep; slow baseline drift is shallow per second.
    if (peakDepth / widthSec < depthWidthRatioMin) continue;
    onCycle(peakDepth, widthSec);
  }
}

/// Piecewise-linear resample of (t,y) onto a sorted [grid] of times (same unit).
/// Out-of-range grid points clamp to the nearest endpoint value.
List<double> _resampleLinear(
    List<double> t, List<double> y, List<double> grid) {
  final out = List<double>.filled(grid.length, 0);
  var j = 0;
  for (var k = 0; k < grid.length; k++) {
    final g = grid[k];
    if (g <= t.first) {
      out[k] = y.first;
      continue;
    }
    if (g >= t.last) {
      out[k] = y.last;
      continue;
    }
    while (j < t.length - 1 && t[j + 1] < g) {
      j++;
    }
    final t0 = t[j], t1 = t[j + 1];
    final span = t1 - t0;
    final frac = span == 0 ? 0.0 : (g - t0) / span;
    out[k] = y[j] + (y[j + 1] - y[j]) * frac;
  }
  return out;
}

/// 2nd-order Savitzky-Golay smoothing via a local quadratic least-squares fit
/// over a symmetric window of half-width [halfWin]. Evaluated at the centre.
List<double> _savgolQuadratic(List<double> x, {int halfWin = 7}) {
  final n = x.length;
  final out = List<double>.filled(n, 0);
  for (var i = 0; i < n; i++) {
    final lo = math.max(0, i - halfWin);
    final hi = math.min(n - 1, i + halfWin);
    final m = hi - lo + 1;
    if (m < 3) {
      out[i] = x[i];
      continue;
    }
    // Fit y = a + b·u + c·u² with u centred at i; return a (value at u=0).
    var s0 = 0.0, s1 = 0.0, s2 = 0.0, s3 = 0.0, s4 = 0.0;
    var sy = 0.0, suy = 0.0, su2y = 0.0;
    for (var k = lo; k <= hi; k++) {
      final u = (k - i).toDouble();
      final u2 = u * u;
      s0 += 1;
      s1 += u;
      s2 += u2;
      s3 += u2 * u;
      s4 += u2 * u2;
      sy += x[k];
      suy += u * x[k];
      su2y += u2 * x[k];
    }
    // Solve the 3x3 normal equations for [a,b,c]; we only need a.
    final a = _solve3(
      [s0, s1, s2, s1, s2, s3, s2, s3, s4],
      [sy, suy, su2y],
    );
    out[i] = a == null ? x[i] : a[0];
  }
  return out;
}

/// Solve a 3x3 linear system (row-major A, rhs b) via Cramer's rule. Null if
/// singular.
List<double>? _solve3(List<double> a, List<double> b) {
  double det3(double a0, double a1, double a2, double a3, double a4, double a5,
          double a6, double a7, double a8) =>
      a0 * (a4 * a8 - a5 * a7) -
      a1 * (a3 * a8 - a5 * a6) +
      a2 * (a3 * a7 - a4 * a6);
  final d = det3(a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8]);
  if (d == 0) return null;
  final dx = det3(b[0], a[1], a[2], b[1], a[4], a[5], b[2], a[7], a[8]);
  final dy = det3(a[0], b[0], a[2], a[3], b[1], a[5], a[6], b[2], a[8]);
  final dz = det3(a[0], a[1], b[0], a[3], a[4], b[1], a[6], a[7], b[2]);
  return [dx / d, dy / d, dz / d];
}
