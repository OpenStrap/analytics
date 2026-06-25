// CLINICAL TIER-1 — lnRMSSD readiness stack (Plews 2013/2014; Kiviniemi 2007).
//
// Nightly ln(RMSSD), a 7-day rolling mean, its coefficient of variation, the
// Smallest Worthwhile Change band, and a z-score decision band. Our whole-night
// baseline beats the morning-spot baseline the literature is stuck with
// (Nuuttila 2022). Includes the LnRMSSD:RR saturation guard: at high HRV the
// RMSSD-RR relationship saturates, so we flag when nightly RR (mean NN) is high
// AND lnRMSSD is near the top of its personal range (interpretation caution).
//
// HONESTY: needs ≥ minNights of valid history; absent otherwise. PRV.

import '../types.dart';
import '../util.dart';

class ReadinessLnRmssd {
  final double lnRmssdToday;
  final double rolling7Mean;
  final double cvPct; // CV of lnRMSSD over the window
  final double? z; // (today - rollingMean)/rollingSD
  final double? swc; // smallest worthwhile change (0.5×SD, Plews-style)
  final String band; // 'suppressed' | 'normal' | 'elevated'
  final bool saturationFlag;
  const ReadinessLnRmssd({
    required this.lnRmssdToday,
    required this.rolling7Mean,
    required this.cvPct,
    required this.z,
    required this.swc,
    required this.band,
    required this.saturationFlag,
  });
  Map<String, dynamic> toJson() => {
        'ln_rmssd_today': round6(lnRmssdToday),
        'rolling7_mean': round6(rolling7Mean),
        'cv_pct': round6(cvPct),
        if (z != null) 'z': round6(z!),
        if (swc != null) 'swc': round6(swc!),
        'band': band,
        'saturation_flag': saturationFlag,
      };
}

/// Required minimum nights of lnRMSSD history before this metric computes.
const int readinessLnRmssdMinNights = 4;

/// Compute the lnRMSSD readiness stack.
///
/// [historyLnRmssd] trailing nightly ln(RMSSD), OLDEST→NEWEST, INCLUDING tonight
/// as the last element. [meanNnTodayMs] tonight's mean NN (for the saturation
/// guard; optional). [windowDays] rolling window (default 7).
Metric<ReadinessLnRmssd> readinessLnRmssd(
  List<double> historyLnRmssd, {
  double? meanNnTodayMs,
  int windowDays = 7,
  int minNights = readinessLnRmssdMinNights,
}) {
  const inputs = ['ln_rmssd_history'];
  if (historyLnRmssd.length < minNights) {
    return Metric<ReadinessLnRmssd>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: needBaselineNote(have: historyLnRmssd.length, need: minNights),
    );
  }
  final today = historyLnRmssd.last;
  final n = historyLnRmssd.length;
  final start = n - windowDays < 0 ? 0 : n - windowDays;
  final window = historyLnRmssd.sublist(start);
  final m = mean(window)!;
  final sd = stddev(window);
  final cv = (m != 0 && sd != null) ? (sd / m).abs() * 100 : 0.0;
  final z = (sd != null && sd > 0) ? (today - m) / sd : null;
  // Plews SWC ≈ 0.5 × within-window SD (a small worthwhile change in lnRMSSD).
  final swc = sd != null ? 0.5 * sd : null;

  String band;
  if (swc != null) {
    if (today < m - swc) {
      band = 'suppressed';
    } else if (today > m + swc) {
      band = 'elevated';
    } else {
      band = 'normal';
    }
  } else {
    band = 'normal';
  }

  // LnRMSSD:RR saturation guard: when mean NN is long (low HR, high vagal tone)
  // and lnRMSSD is at the top of the personal range, the metric saturates.
  final saturation = meanNnTodayMs != null &&
      meanNnTodayMs > 1100 &&
      (sd != null && sd > 0 && (today - m) / sd > 1.0);

  final conf = clamp(window.length / windowDays.toDouble(), 0.3, 0.9);
  return Metric<ReadinessLnRmssd>(
    value: ReadinessLnRmssd(
      lnRmssdToday: today,
      rolling7Mean: m,
      cvPct: cv,
      z: z,
      swc: swc,
      band: band,
      saturationFlag: saturation,
    ),
    confidence: conf,
    tier: Tier.high,
    inputs_used: inputs,
    note: saturation
        ? 'lnRMSSD:RR saturation — high-HRV interpretation caution'
        : 'Plews/Kiviniemi whole-night lnRMSSD readiness; PRV',
  );
}
