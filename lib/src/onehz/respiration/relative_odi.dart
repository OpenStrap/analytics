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
/// [maxGapSec] splits the night at recording gaps (off-wrist/charging), same
/// as `cvhr_apnea.dart`: each gap-free segment is windowed and scored on its
/// own, so the AC/DC and baseline windows never blend samples across a hole,
/// and `analyzedHours` sums only the segments' own OBSERVED spans instead of
/// the raw first-to-last span (which lets a charging break dilute the index).
Metric<RelativeOdiResult> relativeOdi(
  List<double> red,
  List<double> ir,
  List<double> tsSec, {
  double validFraction = 1.0,
  int acWindowSec = 8,
  int baselineSec = 120,
  double dipPct = 3.0,
  double maxGapSec = 30,
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

  // SEGMENT AT GAPS. A stretch more than maxGapSec apart is a separate
  // recording, not a straight line to interpolate across or window through.
  final segStart = <int>[0];
  for (var i = 1; i < tsSec.length; i++) {
    if (tsSec[i] - tsSec[i - 1] > maxGapSec) segStart.add(i);
  }

  final relR = List<double>.filled(n, double.nan);
  var analyzedHours = 0.0;
  var dipCount = 0;
  final dipMags = <double>[];
  var totalDipSec = 0; // sum of qualifying excursion seconds (for burden)
  var longestDipSec = 0; // longest single excursion

  for (var s = 0; s < segStart.length; s++) {
    final lo = segStart[s];
    final hi = (s + 1 < segStart.length ? segStart[s + 1] : n) - 1;
    final segRed = red.sublist(lo, hi + 1);
    final segIr = ir.sublist(lo, hi + 1);
    final segTs = tsSec.sublist(lo, hi + 1);
    final segSpanSec = segTs.last - segTs.first;
    if (segTs.length < 2 || segSpanSec <= 0) continue; // nothing observable
    analyzedHours += segSpanSec / 3600.0;

    // Rolling AC (stddev) / DC (mean) per channel, scoped to this segment.
    final acRed = _rollingStd(segRed, acWindowSec);
    final dcRed = _rollingMean(segRed, acWindowSec);
    final acIr = _rollingStd(segIr, acWindowSec);
    final dcIr = _rollingMean(segIr, acWindowSec);

    // Ratio-of-ratios R = (AC_red/DC_red)/(AC_ir/DC_ir). Higher R ⇒ lower
    // SpO₂ (well-established direction), but we keep it UNITLESS / relative.
    final segRelR = <double>[];
    for (var i = 0; i < segRed.length; i++) {
      // A zero DC on EITHER channel means every raw sample in this window was
      // literally zero — a contact-loss/dropout signature, not a real
      // reading. That must become NaN immediately, same as the IR-side guard
      // below, and never a fabricated 0.0 flowing into meanRelR/baseR.
      if (dcRed[i] == 0 || dcIr[i] == 0) {
        segRelR.add(double.nan);
        continue;
      }
      final rRed = acRed[i] / dcRed[i];
      final rIr = acIr[i] / dcIr[i];
      segRelR.add(rIr <= 0 ? double.nan : rRed / rIr);
    }
    for (var i = 0; i < segRelR.length; i++) {
      relR[lo + i] = segRelR[i];
    }

    // Rolling baseline of R over baselineSec, scoped to this segment; a
    // desaturation event = R rises ≥ dipPct above it for ≥minDipSec.
    final baseR = _rollingMean(segRelR, baselineSec, skipNan: true);
    final segLen = segRelR.length;
    var i = 0;
    const minDipSec = 8;
    const refractorySec = 10; // min separation between distinct events
    var lastEnd = -refractorySec - 1;
    while (i < segLen) {
      final b = baseR[i];
      if (segRelR[i].isNaN || b <= 0) {
        i++;
        continue;
      }
      final risePct = 100.0 * (segRelR[i] - b) / b;
      if (risePct < dipPct) {
        i++;
        continue;
      }
      final start = i;
      var peakPct = 0.0;
      while (i < segLen &&
          !segRelR[i].isNaN &&
          baseR[i] > 0 &&
          100.0 * (segRelR[i] - baseR[i]) / baseR[i] >= dipPct) {
        final p = 100.0 * (segRelR[i] - baseR[i]) / baseR[i];
        if (p > peakPct) peakPct = p;
        i++;
      }
      final widthSec = i - start;
      if (widthSec >= minDipSec) {
        totalDipSec += widthSec;
        if (widthSec > longestDipSec) longestDipSec = widthSec;
        // Refractory gate: merge events that start within refractorySec of
        // the previous one's end (one physiological desaturation, not two).
        if (start - lastEnd <= refractorySec && dipMags.isNotEmpty) {
          if (peakPct > dipMags.last) dipMags[dipMags.length - 1] = peakPct;
        } else {
          dipCount++;
          dipMags.add(peakPct);
        }
        lastEnd = i;
      }
    }
  }

  if (analyzedHours <= 0) {
    return const Metric<RelativeOdiResult>.absent(
      tier: Tier.relative,
      inputs_used: inputs,
      note: 'no gap-free stretch long enough for a relative-ODI screen',
    );
  }

  // HONEST-BY-TYPE: if EVERY ratio sample is NaN (no channel passed the
  // DC/IR guards) there is no self-referential trend to report — a
  // fabricated 0.0 would read as a real (and impossibly stable) relative-R.
  final validR = [
    for (final v in relR)
      if (!v.isNaN) v
  ];
  if (validR.isEmpty) {
    return const Metric<RelativeOdiResult>.absent(
      tier: Tier.relative,
      inputs_used: inputs,
      note: 'no valid ratio-of-ratios samples (all NaN); '
          'cannot compute a relative-ODI screen',
    );
  }
  final meanRelR = mean(validR)!;

  final odiPerHour = dipCount / analyzedHours;
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
  final conf = (0.5 * validFraction).clamp(0.1, 0.5);
  return Metric<RelativeOdiResult>(
    value: RelativeOdiResult(
      meanRelR: meanRelR,
      dipCount: dipCount,
      odiPerHour: odiPerHour,
      analyzedHours: analyzedHours,
      meanDipPct: dipMags.isEmpty ? 0 : mean(dipMags)!,
      maxDipPct: dipMags.isEmpty ? 0 : dipMags.reduce((a, b) => a > b ? a : b),
      longestDipSec: longestDipSec,
      // OBSERVED-time denominator (analyzedHours), not the raw span — same
      // fix as cvhr_apnea.dart's burden accounting.
      burdenPct: 100.0 * totalDipSec / (analyzedHours * 3600.0),
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
