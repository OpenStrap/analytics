// WELLNESS — relative skin-temp circadian analysis.
//
// Catalog: "Wrist circadian-temp: cosinor + IS/IV/RA/L5/M10 (Sarabia/Madrid
// 2008). Best-matched to our relative single-site sensor; no calibration.
// ANTIPHASE to core — de-mask with activity/ambient." `24/7 · MED-HIGH (phase
// only)`.
//
// Two complementary descriptions of the daily rhythm on the RELATIVE skin-temp
// ADC (raw counts, NEVER °C):
//   1. Parametric cosinor (reuse clinical/cosinor.dart) -> acrophase/amplitude.
//   2. Nonparametric circadian statistics (Witting/van Someren):
//      IS  interdaily stability       (rhythm strength vs population of days)
//      IV  intradaily variability      (fragmentation)
//      M10 most-active 10 h mean + onset; L5 least-active 5 h mean + onset
//      RA  relative amplitude = (M10-L5)/(M10+L5)
//   (Computed on temp; "active" = warmest for temp, since wrist temp is
//   ANTIPHASE to core — high distal skin temp marks rest/sleep.)
//
// HONESTY: phase only. No absolute °C, no fever. We optionally de-mask by
// dropping high-motion epochs (activity raises distal skin temp via vasomotor
// confound) before computing the rhythm, and report how many epochs survived.

import 'dart:math' as math;
import '../types.dart';
import '../util.dart';
import '../clinical/cosinor.dart';

class CircadianNonparam {
  final double interdailyStability; // IS, 0..1 (higher = more stable)
  final double intradailyVariability; // IV, ~0..2 (higher = more fragmented)
  final double m10; // mean of most-active (warmest) 10 h
  final double m10OnsetHour; // start hour-of-day of the M10 window
  final double l5; // mean of least-active (coolest) 5 h
  final double l5OnsetHour; // start hour-of-day of the L5 window
  final double relativeAmplitude; // RA = (M10-L5)/(M10+L5)
  final int epochsPerDay;
  final int nDays;
  const CircadianNonparam({
    required this.interdailyStability,
    required this.intradailyVariability,
    required this.m10,
    required this.m10OnsetHour,
    required this.l5,
    required this.l5OnsetHour,
    required this.relativeAmplitude,
    required this.epochsPerDay,
    required this.nDays,
  });
  Map<String, dynamic> toJson() => {
        'interdaily_stability': round6(interdailyStability),
        'intradaily_variability': round6(intradailyVariability),
        'm10': round6(m10),
        'm10_onset_hour': round6(m10OnsetHour),
        'l5': round6(l5),
        'l5_onset_hour': round6(l5OnsetHour),
        'relative_amplitude': round6(relativeAmplitude),
        'epochs_per_day': epochsPerDay,
        'n_days': nDays,
      };
}

class TempCircadian {
  final CosinorFit? cosinorFit;
  final CircadianNonparam? nonparam;
  const TempCircadian(this.cosinorFit, this.nonparam);
  Map<String, dynamic> toJson() => {
        if (cosinorFit != null) 'cosinor': cosinorFit!.toJson(),
        if (nonparam != null) 'nonparam': nonparam!.toJson(),
      };
}

/// Relative skin-temp circadian analysis on a (de-masked) time-series of the
/// relative temp ADC.
///
/// [samples] consecutive AdcSamples of the relative skin-temp channel (raw
/// counts). [accel] OPTIONAL co-sampled accel for activity de-masking; when
/// supplied, epochs whose accel motion exceeds [motionGate] (in g of deviation
/// from 1 g rest) are dropped before fitting (vasomotor confound). [epochMin]
/// the binning interval in minutes for the nonparametric statistics
/// (van Someren standard is hourly; we allow finer).
///
/// Returns a RELATIVE-tier metric (phase only). Null/absent if too little data.
Metric<TempCircadian> tempCircadian(
  List<AdcSample> samples, {
  List<AccelSample>? accel,
  double motionGate = 0.08,
  int epochMin = 60,
}) {
  const inputs = ['skin_temp_adc'];
  // De-mask: drop invalid + high-motion epochs.
  final ts = <double>[];
  final adc = <double>[];
  var deMasked = 0;
  for (var i = 0; i < samples.length; i++) {
    final s = samples[i];
    if (!s.valid) continue;
    if (accel != null && i < accel.length) {
      final a = accel[i];
      if (a.valid) {
        final mag = math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z);
        if ((mag - 1.0).abs() > motionGate) {
          deMasked++;
          continue;
        }
      }
    }
    ts.add(s.tsMs);
    adc.add(s.adc);
  }

  if (adc.length < 4) {
    return Metric<TempCircadian>.absent(
      tier: Tier.relative,
      inputs_used: accel == null ? inputs : [...inputs, 'accel'],
      note: 'too few valid temp epochs for circadian analysis',
    );
  }

  // --- Parametric cosinor (phase only, relative counts) ---
  final tHours = [for (final t in ts) t / 3.6e6]; // ms -> hours
  final cos = cosinor(tHours, adc, periodHours: 24);

  // --- Nonparametric IS/IV/RA/L5/M10 ---
  final np = _nonparam(ts, adc, epochMin: epochMin);

  if (cos.value == null && np == null) {
    return Metric<TempCircadian>.absent(
      tier: Tier.relative,
      inputs_used: inputs,
      note: 'circadian fit degenerate',
    );
  }

  // Confidence: tie to cosinor R² when present, else a modest np-only value.
  final conf = cos.value != null
      ? clamp(cos.value!.r2, 0.1, 0.9)
      : 0.3;
  return Metric<TempCircadian>(
    value: TempCircadian(cos.value, np),
    confidence: conf,
    tier: Tier.relative,
    inputs_used: accel == null ? inputs : [...inputs, 'accel'],
    note: 'RELATIVE skin-temp phase only (no °C/fever). Wrist temp is ANTIPHASE '
        'to core; activity-demasked epochs dropped=$deMasked. '
        'M10/L5 are warmest/coolest windows.',
  );
}

/// Witting/van Someren nonparametric circadian statistics. Bins the series into
/// fixed [epochMin]-minute epochs aligned to wall-clock (hour-of-day from
/// tsMs), averages within epoch, then computes IS/IV/RA/L5/M10.
CircadianNonparam? _nonparam(
  List<double> tsMs,
  List<double> adc, {
  required int epochMin,
}) {
  if (tsMs.isEmpty) return null;
  final epochsPerDay = (24 * 60) ~/ epochMin;
  if (epochsPerDay < 5) return null;
  final epochMs = epochMin * 60 * 1000.0;

  // Bin into absolute epoch index (continuous timeline), averaging samples.
  final sums = <int, double>{};
  final counts = <int, int>{};
  var minBin = 1 << 62, maxBin = -(1 << 62);
  for (var i = 0; i < tsMs.length; i++) {
    final bin = (tsMs[i] / epochMs).floor();
    sums[bin] = (sums[bin] ?? 0) + adc[i];
    counts[bin] = (counts[bin] ?? 0) + 1;
    if (bin < minBin) minBin = bin;
    if (bin > maxBin) maxBin = bin;
  }
  // Dense epoch series across the span (gaps left as null -> skipped).
  final series = <double?>[];
  for (var b = minBin; b <= maxBin; b++) {
    series.add(counts.containsKey(b) ? sums[b]! / counts[b]! : null);
  }
  final present = [for (final v in series) if (v != null) v];
  if (present.length < epochsPerDay) return null; // <1 day of epochs
  final nDays = (series.length / epochsPerDay).ceil();

  final grand = mean(present)!;

  // IV: mean squared first-difference of consecutive present epochs / variance.
  var diffSq = 0.0;
  var diffN = 0;
  for (var i = 1; i < series.length; i++) {
    final a = series[i - 1], b = series[i];
    if (a == null || b == null) continue;
    final d = b - a;
    diffSq += d * d;
    diffN++;
  }
  var varTot = 0.0;
  for (final v in present) {
    final d = v - grand;
    varTot += d * d;
  }
  final p = present.length;
  final iv = (diffN > 0 && varTot > 0)
      ? (diffSq / diffN) / (varTot / p)
      : 0.0;

  // IS: between-day stability. Average each within-day epoch-of-day across days,
  // then variance-of-the-24h-profile / total variance.
  final phaseSum = List<double>.filled(epochsPerDay, 0);
  final phaseN = List<int>.filled(epochsPerDay, 0);
  for (var i = 0; i < series.length; i++) {
    final v = series[i];
    if (v == null) continue;
    final eod = (minBin + i) % epochsPerDay; // epoch-of-day
    final idx = eod < 0 ? eod + epochsPerDay : eod;
    phaseSum[idx] += v;
    phaseN[idx] += 1;
  }
  final profile = <double>[];
  for (var e = 0; e < epochsPerDay; e++) {
    if (phaseN[e] > 0) profile.add(phaseSum[e] / phaseN[e]);
  }
  var profVar = 0.0;
  if (profile.isNotEmpty) {
    final pm = mean(profile)!;
    for (final v in profile) {
      profVar += (v - pm) * (v - pm);
    }
    profVar /= profile.length;
  }
  final is_ = varTot > 0 ? clamp(profVar / (varTot / p), 0, 1) : 0.0;

  // M10 / L5 on the averaged 24-h profile (warmest 10 h, coolest 5 h windows).
  // Use the epoch-of-day profile, circularly. epochs in 10h / 5h windows:
  final per = profile.length == epochsPerDay ? profile : null;
  double m10 = grand, l5 = grand, m10On = 0, l5On = 0;
  if (per != null) {
    final w10 = (epochsPerDay * 10 / 24).round();
    final w5 = (epochsPerDay * 5 / 24).round();
    var bestHi = double.negativeInfinity, bestLo = double.infinity;
    for (var start = 0; start < epochsPerDay; start++) {
      var s10 = 0.0;
      for (var k = 0; k < w10; k++) {
        s10 += per[(start + k) % epochsPerDay];
      }
      final m = s10 / w10;
      if (m > bestHi) {
        bestHi = m;
        m10 = m;
        m10On = start * (24.0 / epochsPerDay);
      }
      var s5 = 0.0;
      for (var k = 0; k < w5; k++) {
        s5 += per[(start + k) % epochsPerDay];
      }
      final ml = s5 / w5;
      if (ml < bestLo) {
        bestLo = ml;
        l5 = ml;
        l5On = start * (24.0 / epochsPerDay);
      }
    }
  }
  final denom = m10 + l5;
  final ra = denom != 0 ? (m10 - l5) / denom : 0.0;

  return CircadianNonparam(
    interdailyStability: is_,
    intradailyVariability: iv,
    m10: m10,
    m10OnsetHour: m10On,
    l5: l5,
    l5OnsetHour: l5On,
    relativeAmplitude: ra,
    epochsPerDay: epochsPerDay,
    nDays: nDays,
  );
}
