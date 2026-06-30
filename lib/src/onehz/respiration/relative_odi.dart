// RESPIRATION TIER-RELATIVE — relative-R index + relative ODI.
//
// Pulse oximetry's "R" is the ratio-of-ratios R = (AC_red/DC_red) /
// (AC_ir/DC_ir) (TI SLAA655). A calibration curve maps R → SpO₂% — but that
// curve is device/skin-specific and we DID NOT calibrate it. So we NEVER output
// a %SpO₂. Instead we expose:
//   * relative-R index — the raw ratio-of-ratios as a unitless, self-referential
//     trend (R rises as oxygenation falls). Only deviations vs the wearer's own
//     rolling baseline are meaningful.
//   * relative ODI — a self-referential desaturation-event rate: a "dip" is when
//     a proxy oxygenation index drops ≥3% below its own rolling 120 s baseline.
//     We report events/hour as a SCREEN, never an absolute oxygen saturation.
//
// AC/DC at 1 Hz: we cannot see the pulsatile waveform (that needs 419 Hz), so
// AC is estimated as the rolling standard deviation of the channel over a short
// window (pulsatile + respiratory variation amplitude) and DC as the rolling
// mean (the perfusion baseline). This is a 1 Hz-honest surrogate, hence the
// RELATIVE tier and the explicit "never %SpO₂" guard.
//
// HONESTY: RELATIVE tier always. Output carries no absolute %. ODI is a SCREEN.

import 'dart:math' as math;
import '../types.dart';
import '../util.dart';

class RelativeOdiResult {
  final double meanRelR; // mean relative ratio-of-ratios (unitless)
  final int dipCount; // self-referential desaturation events
  final double odiPerHour; // events / hour (relative ODI screen)
  final double analyzedHours;
  final double meanDipPct; // mean relative drop at a dip (% of own baseline)
  final double maxDipPct; // largest relative drop across events
  final int longestDipSec; // longest single excursion (s)
  final double burdenPct; // % of analyzed time spent in desaturation
  final double signalCoverage; // 0..1 fraction passing the contact/SQI gate
  final double trustedCoverage; // 0..1 fraction of non-NaN ratio samples
  final Map<String, int> rejectCounts; // rejected-sample reasons → counts
  final Map<String, int> severityCounts; // dips bucketed mild/moderate/severe
  const RelativeOdiResult({
    required this.meanRelR,
    required this.dipCount,
    required this.odiPerHour,
    required this.analyzedHours,
    required this.meanDipPct,
    this.maxDipPct = 0,
    this.longestDipSec = 0,
    this.burdenPct = 0,
    this.signalCoverage = 0,
    this.trustedCoverage = 0,
    this.rejectCounts = const {},
    this.severityCounts = const {},
  });
  Map<String, dynamic> toJson() => {
        'mean_rel_r': round6(meanRelR),
        'dip_count': dipCount,
        'odi_per_hour': round6(odiPerHour),
        'analyzed_hours': round6(analyzedHours),
        'mean_dip_pct': round6(meanDipPct),
        'max_dip_pct': round6(maxDipPct),
        'longest_dip_sec': longestDipSec,
        'burden_pct': round6(burdenPct),
        'signal_coverage': round6(signalCoverage),
        'trusted_coverage': round6(trustedCoverage),
        'reject_counts': rejectCounts,
        'severity_counts': severityCounts,
        // explicit honesty flag carried into any UI:
        'absolute_spo2': false,
      };
}

/// Relative-R index + relative ODI from the red & IR ADC channels.
///
/// [red] / [ir] 1 Hz relative-ADC samples (counts), [tsSec] their times (s).
/// [validFraction] of the window that passed the contact/SQI gate.
/// [acWindowSec] rolling window for the AC (variation) / DC (mean) estimate.
/// [baselineSec] rolling baseline for the dip test (Hayano-style 120 s).
/// [dipPct] relative drop threshold for a desaturation event (default 3%).
Metric<RelativeOdiResult> relativeOdi(
  List<double> red,
  List<double> ir,
  List<double> tsSec, {
  double validFraction = 1.0,
  int acWindowSec = 8,
  int baselineSec = 120,
  double dipPct = 3.0,
}) {
  const inputs = ['spo2_red_raw', 'spo2_ir_raw', 'ts'];
  final n = red.length;
  if (n < 60 || ir.length != n || tsSec.length != n) {
    return const Metric<RelativeOdiResult>.absent(
      tier: Tier.relative,
      inputs_used: inputs,
      note: 'too few red/IR samples for a relative-ODI screen (need ≥60 s)',
    );
  }
  final spanSec = tsSec.last - tsSec.first;
  final analyzedHours = spanSec / 3600.0;
  if (analyzedHours <= 0) {
    return const Metric<RelativeOdiResult>.absent(
      tier: Tier.relative,
      inputs_used: inputs,
      note: 'degenerate timestamps',
    );
  }

  // Rolling AC (stddev) / DC (mean) per channel over acWindowSec.
  final acRed = _rollingStd(red, acWindowSec);
  final dcRed = _rollingMean(red, acWindowSec);
  final acIr = _rollingStd(ir, acWindowSec);
  final dcIr = _rollingMean(ir, acWindowSec);

  // Ratio-of-ratios R = (AC_red/DC_red)/(AC_ir/DC_ir). Higher R ⇒ lower SpO₂
  // (well-established direction), but we keep it UNITLESS / relative.
  final relR = <double>[];
  for (var i = 0; i < n; i++) {
    final rRed = dcRed[i] == 0 ? 0.0 : acRed[i] / dcRed[i];
    final rIr = dcIr[i] == 0 ? 0.0 : acIr[i] / dcIr[i];
    if (rIr <= 0) {
      relR.add(double.nan);
    } else {
      relR.add(rRed / rIr);
    }
  }

  // Proxy oxygenation index: oxygenation falls as R rises, so use the IR DC-
  // normalized perfusion ratio's inverse mapping. A 1 Hz-honest self-
  // referential surrogate: oxy ∝ -R. We track dips as RISES in R relative to a
  // rolling baseline (equiv. to drops in oxygenation), thresholded at dipPct.
  final validR = [for (final v in relR) if (!v.isNaN) v];
  final meanRelR = validR.isEmpty ? 0.0 : mean(validR)!;

  // Rolling baseline of R over baselineSec; a desaturation event = R rises
  // ≥ dipPct above its rolling baseline for a sustained (≥10 s) excursion.
  final baseR = _rollingMean(relR, baselineSec, skipNan: true);
  var dipCount = 0;
  final dipMags = <double>[];
  var totalDipSec = 0; // sum of qualifying excursion seconds (for burden)
  var longestDipSec = 0; // longest single excursion
  var i = 0;
  const minDipSec = 8;
  const refractorySec = 10; // min separation between distinct events
  var lastEnd = -refractorySec - 1;
  while (i < n) {
    final b = baseR[i];
    if (relR[i].isNaN || b <= 0) {
      i++;
      continue;
    }
    final risePct = 100.0 * (relR[i] - b) / b;
    if (risePct < dipPct) {
      i++;
      continue;
    }
    final start = i;
    var peakPct = 0.0;
    while (i < n &&
        !relR[i].isNaN &&
        baseR[i] > 0 &&
        100.0 * (relR[i] - baseR[i]) / baseR[i] >= dipPct) {
      final p = 100.0 * (relR[i] - baseR[i]) / baseR[i];
      if (p > peakPct) peakPct = p;
      i++;
    }
    final widthSec = i - start;
    if (widthSec >= minDipSec) {
      totalDipSec += widthSec;
      if (widthSec > longestDipSec) longestDipSec = widthSec;
      // Refractory gate: merge events that start within refractorySec of the
      // previous one's end (one physiological desaturation, not two).
      if (start - lastEnd <= refractorySec && dipMags.isNotEmpty) {
        if (peakPct > dipMags.last) dipMags[dipMags.length - 1] = peakPct;
      } else {
        dipCount++;
        dipMags.add(peakPct);
      }
      lastEnd = i;
    }
  }

  final odiPerHour = analyzedHours > 0 ? dipCount / analyzedHours : 0.0;
  // Severity buckets by RELATIVE drop magnitude (% rise in R vs baseline).
  var mild = 0, moderate = 0, severe = 0;
  for (final m in dipMags) {
    if (m >= 10.0) {
      severe++;
    } else if (m >= 5.0) {
      moderate++;
    } else {
      mild++;
    }
  }
  final nanCount = relR.where((v) => v.isNaN).length;
  final conf = clamp(0.5 * validFraction, 0.1, 0.5);
  return Metric<RelativeOdiResult>(
    value: RelativeOdiResult(
      meanRelR: meanRelR,
      dipCount: dipCount,
      odiPerHour: odiPerHour,
      analyzedHours: analyzedHours,
      meanDipPct: dipMags.isEmpty ? 0 : mean(dipMags)!,
      maxDipPct: dipMags.isEmpty ? 0 : dipMags.reduce((a, b) => a > b ? a : b),
      longestDipSec: longestDipSec,
      burdenPct: spanSec > 0 ? 100.0 * totalDipSec / spanSec : 0.0,
      signalCoverage: validFraction.clamp(0.0, 1.0),
      trustedCoverage: n > 0 ? (n - nanCount) / n : 0.0,
      rejectCounts: {'low_signal': nanCount},
      severityCounts: {'mild': mild, 'moderate': moderate, 'severe': severe},
    ),
    confidence: conf,
    tier: Tier.relative,
    inputs_used: inputs,
    note: 'RELATIVE desaturation-event rate (self-referential ratio-of-ratios, '
        'AC=rolling-σ / DC=rolling-mean at 1 Hz). NEVER an absolute SpO₂ %; '
        'a SCREEN, not a diagnosis.',
  );
}

/// Rolling mean over a centred window of [win] samples. [skipNan] excludes NaN.
List<double> _rollingMean(List<double> x, int win, {bool skipNan = false}) {
  final n = x.length;
  final out = List<double>.filled(n, 0);
  final half = win ~/ 2;
  for (var i = 0; i < n; i++) {
    final lo = math.max(0, i - half);
    final hi = math.min(n - 1, i + half);
    var s = 0.0;
    var c = 0;
    for (var k = lo; k <= hi; k++) {
      if (skipNan && x[k].isNaN) continue;
      s += x[k];
      c++;
    }
    out[i] = c == 0 ? double.nan : s / c;
  }
  return out;
}

/// Rolling population stddev over a centred window of [win] samples.
List<double> _rollingStd(List<double> x, int win) {
  final n = x.length;
  final out = List<double>.filled(n, 0);
  final half = win ~/ 2;
  for (var i = 0; i < n; i++) {
    final lo = math.max(0, i - half);
    final hi = math.min(n - 1, i + half);
    final seg = <double>[];
    for (var k = lo; k <= hi; k++) {
      seg.add(x[k]);
    }
    out[i] = stddevPop(seg) ?? 0.0;
  }
  return out;
}
