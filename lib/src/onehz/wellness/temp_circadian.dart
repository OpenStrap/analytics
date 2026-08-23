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
//
// M10, L5 AND RA ARE WITHHELD — not null-when-unobserved, absent from the type.
// The series this runs on is median-centred, so it is SIGNED, and
// RA = (M10−L5)/(M10+L5) has a denominator that crosses zero: the "relative
// amplitude" flips sign and blows up on a series whose warm and cool windows
// straddle the centre. M10/L5 go with it because their only published use is
// RA and because a "warmest 10 h" of a centred series is not a level. IS/IV
// need no such level and stay.
//
// PER-DEVICE (device.dart contract). gen4 reports skin temperature as a raw
// ADC count and gen5 as centi-°C; they arrive in ONE array with no unit. A
// cosinor amplitude is unit-bearing, so an amplitude computed here is only
// comparable to another of the SAME family — hence [TempCircadian.unit], which
// exists so that no screen and no aggregate ever puts the two side by side.
// The de-mask motion gate is also per-family: on our own captures the resting
// accel noise floor differs ~4x between the families (gen4 |‖a‖−1| median
// 0.034 g / p90 0.058 g; gen5+MG median 0.007–0.012 g / p90 0.018–0.024 g), so
// one shared gate either de-masks half a gen4 night or nothing on a gen5 one.
// Unknown family REFUSES.
//
// HONESTY: phase only. No absolute °C, no fever, no core temperature, and the
// antiphase relationship to core is not to be quietly inverted for a nicer
// chart. Charging happens at a consistent time for most people, so the off-wrist
// gap is PHASE-LOCKED and biases the rhythm — the de-masking exists for that.

import 'dart:math' as math;
import '../device.dart';
import '../types.dart';
import '../util.dart';
import '../clinical/cosinor.dart';

class CircadianNonparam {
  final double interdailyStability; // IS, 0..1 (higher = more stable)
  final double intradailyVariability; // IV, ~0..2 (higher = more fragmented)
  final int epochsPerDay;
  final int nDays;
  const CircadianNonparam({
    required this.interdailyStability,
    required this.intradailyVariability,
    required this.epochsPerDay,
    required this.nDays,
  });
  Map<String, dynamic> toJson() => {
        'interdaily_stability': round6(interdailyStability),
        'intradaily_variability': round6(intradailyVariability),
        'epochs_per_day': epochsPerDay,
        'n_days': nDays,
      };
}

class TempCircadian {
  final CosinorFit? cosinorFit;
  final CircadianNonparam? nonparam;

  /// The unit the input series was in — `adc_counts` (gen4) or `centi_c`
  /// (gen5). The cosinor AMPLITUDE is in this unit. Two families' amplitudes
  /// are not comparable and must never be pooled, plotted together or
  /// converted; nothing here is °C on screen.
  final String unit;
  const TempCircadian(this.cosinorFit, this.nonparam, this.unit);
  Map<String, dynamic> toJson() => {
        if (cosinorFit != null) 'cosinor': cosinorFit!.toJson(),
        if (nonparam != null) 'nonparam': nonparam!.toJson(),
        'unit': unit,
      };
}

/// What each family's skin-temp column actually holds, how still "still" is on
/// its accelerometer, and how far BELOW a night's own level a reading can fall
/// and still be skin. All three are sensor properties, not physiology.
class _TempCal {
  final String unit;
  final double motionGate; // g of |‖a‖ − 1| above which an epoch is masked
  /// One-sided settle band, in [unit]: a sample more than this far BELOW the
  /// night's median is not settled skin (see [nightlySkinTemp]). Null = this
  /// family has no measured band, so the settled mean REFUSES for it rather
  /// than borrow gen4's counts.
  final double? settleBandLow;
  const _TempCal(this.unit, this.motionGate, this.settleBandLow);
}

const Map<String, _TempCal> _tempCal = {
  // gen4's 40 counts: on the 8 real gen4 nights in whoop-4.db the seven clean
  // nights keep 94.4–100.0 % of their sleep-window samples above
  // (night median − 40), while the one night carrying a two-hour cold segment
  // keeps 78.7 %. The band is ~6× the 6.47-count between-night SD and ~1.4× the
  // 29.3-count corpus-wide circadian range, so ordinary rhythm survives it.
  'gen4': _TempCal('adc_counts', 0.10, 40.0),
  // gen5 has NO measured band. The exports carry 106 (W5) and 933 (MG) non-zero
  // skin-temp rows in total — not one night clears the 60-sample floor — so
  // there is nothing to calibrate against. Scaling gen4's 40 counts by a
  // counts-per-°C guess would be gen4's number wearing a gen5 badge, which is
  // exactly what device.dart's contract forbids. Fill this in from gen5 nights,
  // not from arithmetic.
  'gen5': _TempCal('centi_c', 0.04, null),
};

/// A nightly skin-temp mean that knows how much of the night it is made of.
class SettledSkinTemp {
  /// Mean of the SETTLED samples only (see [nightlySkinTemp]), in [unit].
  final double mean;

  /// Fraction of the night's valid samples that were settled, 0..1. This is the
  /// scalar RD-15 asks for (`skin_temp_settled_fraction`) — persist it.
  final double settledFraction;

  /// `adc_counts` (gen4) or `centi_c` (gen5). Never °C on screen.
  final String unit;
  const SettledSkinTemp(this.mean, this.settledFraction, this.unit);
  Map<String, dynamic> toJson() => {
        'mean': round6(mean),
        'settled_fraction': round6(settledFraction),
        'unit': unit,
      };
}

/// Minimum settled fraction a night must reach before its skin-temp mean may be
/// USED as a measurement. 0.80 is the audit's floor and costs one night in
/// eight on the real gen4 corpus.
const double kMinSettledFraction = 0.80;

/// Nightly skin-temp mean over the SETTLED portion of a sleep window.
///
/// THE PROBLEM THIS EXISTS FOR. The plain mean of a sleep window's skin-temp
/// samples cannot tell a fever from a strap that was just put on. On the real
/// gen4 corpus one night carries a two-hour segment ~100 counts below the rest
/// of that same night — a cold strap, HR present throughout, so not off-wrist,
/// just not yet at skin temperature — and it displaces that night's mean by
/// more than the entire 29.3-count daily rhythm. Every consumer of the nightly
/// mean (readiness's temp driver, `tempIllnessFlag`, `multivariateAnomaly`'s
/// temp column, `tempCircadian`) inherits that displacement.
///
/// THE RULE. A sample is SETTLED when it sits no more than the family's
/// [_TempCal.settleBandLow] BELOW the night's own median. One-sided on purpose:
/// warm-up and off-wrist both read LOW, while a fever reads HIGH and must pass
/// through untouched — a symmetric band would delete the signal the channel
/// exists for.
///
/// Returns the settled mean plus the settled fraction. ABSENT when the family
/// has no measured band, when there are fewer than [minSamples] valid samples,
/// or when the settled fraction is below [minSettledFraction] — in that last
/// case the night has no usable temperature and the consumer must drop the
/// input, not substitute one.
///
/// The channel itself is NEVER removed or nulled by this: it gates USE.
Metric<SettledSkinTemp> nightlySkinTemp(
  List<AdcSample> samples, {
  required String? deviceFamily,
  double minSettledFraction = kMinSettledFraction,
  int minSamples = 60,
}) {
  const inputs = ['skin_temp_adc', 'device_family'];
  final cal = calibrationFor(_tempCal, deviceFamily);
  if (cal == null || cal.settleBandLow == null) {
    return Metric<SettledSkinTemp>.absent(
      tier: Tier.relative,
      inputs_used: inputs,
      note: unknownFamilyNote(deviceFamily),
    );
  }
  final v = [
    for (final s in samples)
      if (s.valid && s.adc > 0) s.adc
  ];
  if (v.length < minSamples) {
    return Metric<SettledSkinTemp>.absent(
      tier: Tier.relative,
      inputs_used: inputs,
      note: needBaselineNote(have: v.length, need: minSamples),
    );
  }
  final floor = median(v)! - cal.settleBandLow!;
  final kept = [
    for (final x in v)
      if (x >= floor) x
  ];
  final frac = kept.length / v.length;
  if (frac < minSettledFraction) {
    return Metric<SettledSkinTemp>.absent(
      tier: Tier.relative,
      inputs_used: inputs,
      note: 'unsettled_skin_temp:settled=${round6(frac)},'
          'need=${round6(minSettledFraction)} — the strap spent part of this '
          'night below skin temperature (warm-up or off-body), so the nightly '
          'mean is not a measurement of this person',
    );
  }
  return Metric<SettledSkinTemp>(
    value: SettledSkinTemp(mean(kept)!, frac, cal.unit),
    confidence: clamp(frac, 0.0, 1.0),
    tier: Tier.relative,
    inputs_used: inputs,
    note: 'RELATIVE nightly skin-temp mean over the SETTLED portion only '
        '(${round6(frac)} of valid samples, band ${cal.settleBandLow} '
        '${cal.unit} below the night median; one-sided so a fever passes). '
        'Unit is ${cal.unit} — never °C, never compared across families.',
  );
}

/// Relative skin-temp circadian analysis on a (de-masked) time-series of the
/// relative temp ADC.
///
/// [samples] consecutive AdcSamples of the relative skin-temp channel, in
/// whatever unit [deviceFamily] reports it in. [accel] OPTIONAL co-sampled
/// accel for activity de-masking; when supplied, epochs whose accel motion
/// exceeds the family's gate (in g of deviation from 1 g rest) are dropped
/// before fitting (vasomotor confound). [motionGate] overrides that gate for
/// tests and tuning only — production passes the family and nothing else.
/// [epochMin] the binning interval in minutes for the nonparametric statistics
/// (van Someren standard is hourly; we allow finer).
///
/// [deviceFamily] is the ingest-stamped id. NULL — every pre-schema-41 row,
/// every import, every raw replay — REFUSES, because a gen4 ADC count and a
/// gen5 centi-°C in the same array cannot be told apart afterwards.
///
/// Returns a RELATIVE-tier metric (phase only). Absent if too little data.
Metric<TempCircadian> tempCircadian(
  List<AdcSample> samples, {
  required String? deviceFamily,
  List<AccelSample>? accel,
  double? motionGate,
  int epochMin = 60,
}) {
  const inputs = ['skin_temp_adc', 'device_family'];
  final cal = calibrationFor(_tempCal, deviceFamily);
  if (cal == null) {
    return Metric<TempCircadian>.absent(
      tier: Tier.relative,
      inputs_used: inputs,
      note: unknownFamilyNote(deviceFamily),
    );
  }
  final gate = motionGate ?? cal.motionGate;
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
        if ((mag - 1.0).abs() > gate) {
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
  final conf = cos.value != null ? clamp(cos.value!.r2, 0.1, 0.9) : 0.3;
  return Metric<TempCircadian>(
    value: TempCircadian(cos.value, np, cal.unit),
    confidence: conf,
    tier: Tier.relative,
    inputs_used: accel == null ? inputs : [...inputs, 'accel'],
    note: 'RELATIVE skin-temp phase only (no °C/fever/core). Wrist temp is '
        'ANTIPHASE to core; activity-demasked epochs dropped=$deMasked '
        '(gate=${gate}g). Amplitude is in ${cal.unit} — never compare it '
        'across device families. M10/L5/RA are WITHHELD: the series is '
        'median-centred, so RA divides by a quantity that crosses zero.',
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
  final present = [
    for (final v in series)
      if (v != null) v
  ];
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
  final iv = (diffN > 0 && varTot > 0) ? (diffSq / diffN) / (varTot / p) : 0.0;

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
    // van Someren's IS takes BOTH variances about the GRAND mean. Using the
    // profile's own mean here (which it did until 2026-08-17) minimises profVar
    // by construction, so IS came out biased low whenever epoch-of-day coverage
    // was unbalanced across days — the normal case (per-day bin coverage on real
    // gen4 data runs 14/24 to 24/24).
    for (final v in profile) {
      profVar += (v - grand) * (v - grand);
    }
    profVar /= profile.length;
  }
  final is_ = varTot > 0 ? clamp(profVar / (varTot / p), 0, 1) : 0.0;

  // M10 / L5 / RA are DELIBERATELY NOT COMPUTED. See the file header: the temp
  // series that survives retention is median-centred, so it is signed, and
  // RA's (M10+L5) denominator crosses zero. Restoring them needs an UNCENTRED
  // multi-day series first, not a null guard here.

  return CircadianNonparam(
    interdailyStability: is_,
    intradailyVariability: iv,
    epochsPerDay: epochsPerDay,
    nDays: nDays,
  );
}
