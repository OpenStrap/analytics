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

import 'dart:math' as math;

import '../types.dart';
import '../util.dart';

class ReadinessLnRmssd {
  final double lnRmssdToday;
  final double rolling7Mean;

  /// The window's MEDIAN — the centre z/SWC/band are taken against.
  final double rolling7Median;
  final double cvPct; // CV of lnRMSSD over the window
  final double? z; // (today - rollingMedian)/robustSD
  final double? swc; // smallest worthwhile change (0.5×robust SD, Plews-style)
  /// 'suppressed' | 'normal' | 'elevated': tonight against centre ± spread ×
  /// [_lnRmssdBandWidening] of the prior-window size (wider than ± 1 spread on
  /// short windows, see that function).
  final String band;
  final bool saturationFlag;
  const ReadinessLnRmssd({
    required this.lnRmssdToday,
    required this.rolling7Mean,
    required this.rolling7Median,
    required this.cvPct,
    required this.z,
    required this.swc,
    required this.band,
    required this.saturationFlag,
  });
  Map<String, dynamic> toJson() => {
        'ln_rmssd_today': round6(lnRmssdToday),
        'rolling7_mean': round6(rolling7Mean),
        'rolling7_median': round6(rolling7Median),
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
/// [dates] optional `yyyy-MM-dd` labels parallel to [historyLnRmssd]. Pass
/// them: without them the window is the last [windowDays] ROWS, which after a
/// wear gap are nights from weeks ago (see [calendarDays]).
Metric<ReadinessLnRmssd> readinessLnRmssd(
  List<double> historyLnRmssd, {
  List<String>? dates,
  double? meanNnTodayMs,
  int windowDays = 7,
  int minNights = readinessLnRmssdMinNights,
}) {
  if (historyLnRmssd.length < minNights) {
    return _tooShort(historyLnRmssd.length, minNights);
  }
  final n = historyLnRmssd.length;
  final start = n - 1 - windowDays < 0 ? 0 : n - 1 - windowDays;
  // all-or-nothing: calendarDays falls back to the row index for a label it
  // can't parse, and an index compared against epoch days is meaningless.
  if (dates != null &&
      dates.length == n &&
      dates.every((d) => DateTime.tryParse(d) != null)) {
    final day = calendarDays(dates);
    return readinessLnRmssdFromSuffix(
      n,
      [
        for (var i = 0; i < n - 1; i++)
          if (day[i] < day[n - 1] && day[n - 1] - day[i] <= windowDays)
            historyLnRmssd[i],
        historyLnRmssd.last,
      ],
      meanNnTodayMs: meanNnTodayMs,
      windowDays: windowDays,
      minNights: minNights,
    );
  }
  if (windowDays >= 0) {
    return readinessLnRmssdFromSuffix(
      n,
      historyLnRmssd.sublist(start, n),
      meanNnTodayMs: meanNnTodayMs,
      windowDays: windowDays,
      minNights: minNights,
    );
  }
  // A negative window cannot be built as a suffix block, so it keeps the old
  // path: otherwise sublist(start, n - 1) with start > n - 1 throws RangeError,
  // as it always did.
  final priorWindow = historyLnRmssd.sublist(start, n - 1);
  return readinessLnRmssdFromSuffix(
    n,
    [...priorWindow, historyLnRmssd.last],
    meanNnTodayMs: meanNnTodayMs,
    windowDays: windowDays,
    minNights: minNights,
  );
}

const _inputs = ['ln_rmssd_history'];

/// The absent result for a history shorter than [minNights].
Metric<ReadinessLnRmssd> _tooShort(int n, int minNights) =>
    Metric<ReadinessLnRmssd>.absent(
      tier: Tier.high,
      inputs_used: _inputs,
      note: needBaselineNote(have: n, need: minNights),
    );

/// Shared by [readinessLnRmssd] and the aggregator (not public API): the
/// arithmetic after the length check, given the history length [n] and its
/// last min(windowDays + 1, n) values [suffix] (tonight last).
// Plews et al. 2013, as implemented by readinessLnRmssd(). Retains the history
// count and relevant prior-night suffix, then calls identical scoring
// arithmetic. The aggregator uses positional history; calendar-date filtering
// remains in the batch wrapper.
Metric<ReadinessLnRmssd> readinessLnRmssdFromSuffix(
  int n,
  List<double> suffix, {
  double? meanNnTodayMs,
  required int windowDays,
  required int minNights,
}) {
  const inputs = _inputs;
  final today = suffix.last;
  // this used to be historyLnRmssd.sublist(start), which runs to the END of
  // the list - including tonight's own value in its own baseline. that
  // pulls the mean/sd toward tonight, understating how far off a genuinely
  // suppressed/elevated night actually is, worst right when the window is
  // smallest (minNights). the baseline has to be strictly prior nights.
  final priorWindow = suffix.sublist(0, suffix.length - 1);
  if (priorWindow.isEmpty || priorWindow.length < minNights - 1) {
    // empty only if minNights got set to 1 somewhere; short when a wear gap
    // left too few nights inside the calendar window. either way there's no
    // baseline yet, same as not enough history.
    return Metric<ReadinessLnRmssd>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: needBaselineNote(
          have: priorWindow.length + 1, need: minNights < 2 ? 2 : minNights),
    );
  }
  final m = mean(priorWindow)!;
  final sd = stddev(priorWindow);
  if (sd == null || m == 0) {
    // The published outputs of this stack (CV, SWC, band) are all defined
    // RELATIVE to the baseline's dispersion. With a single prior night the SD
    // is UNDEFINED — and the metric used to fill in cvPct 0.0 and band
    // 'normal', asserting "tonight is typical" on the strength of nothing at
    // all. Abstain instead (a zero-but-DEFINED SD is a different case: CV is
    // genuinely 0 and SWC is genuinely 0, so that still computes below).
    return Metric<ReadinessLnRmssd>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'lnRMSSD baseline dispersion undefined (needs ≥2 prior nights) — '
          'CV/z/SWC/band are undefined',
    );
  }
  final cv = (sd / m).abs() * 100;
  // ROBUST CENTRE AND SPREAD for the decision band. One illness night in a
  // seven-night window both drags the mean down and inflates the SD, so a
  // genuinely low night reads "normal": on a real window holding a 35.5 ms
  // night, mean 4.465 / SD 0.405 put a 4.478 night (88 ms) inside the band,
  // while the other six nights sat at 4.40–4.79. Median + MAD (×1.4826) are
  // what the window looks like without that one night. MAD collapses only when
  // more than half the window is identical; the SD stands in then. The CV
  // above stays the classic SD/mean (Plews' published CV).
  final centre = median(priorWindow)!;
  final robustSd = mad(priorWindow)!;
  final spread = robustSd > 0 ? robustSd : sd;
  final z = spread > 0 ? (today - centre) / spread : null;
  // Plews SWC ≈ 0.5 × within-window SD (a small worthwhile change in lnRMSSD).
  final swc = 0.5 * spread;

  // The band is a SINGLE-NIGHT decision, so its threshold has to be a
  // single-night one: tonight outside centre ± 1 × spread, Kiviniemi 2007's
  // daily reference value (baseline mean ± SD). The SWC above (0.5 × spread)
  // is Plews' threshold for a 7-day ROLLING mean, where averaging has already
  // cut night-to-night noise by ~1/sqrt(7); applied to one night it sits inside
  // ordinary noise and a user whose HRV never changed read 'suppressed' or
  // 'elevated' on ~70% of nights. Comparing a rolling mean instead does not
  // work against this baseline: the week being tested is six-sevenths the same
  // nights the centre comes from, so a real multi-night drop drags the centre
  // with it and goes unflagged, and one old bad night keeps an ordinary
  // tonight 'suppressed' for the rest of the week. At zero spread any
  // departure from the centre is outside the band.
  //
  // "± 1 SD" only means a ~32% flag rate when the centre and spread are known.
  // Here they come from 3-7 prior nights: the median misses the true level and
  // the MAD of so few points is biased low and noisy, so a user whose HRV
  // never changed still read 'suppressed'/'elevated' on 62% of nights with 3
  // prior nights and 45% with 7. [_lnRmssdBandWidening] restores the intended
  // single-night rate for the window size actually used.
  final halfWidth = spread * _lnRmssdBandWidening(priorWindow.length);
  final String band;
  if (today < centre - halfWidth) {
    band = 'suppressed';
  } else if (today > centre + halfWidth) {
    band = 'elevated';
  } else {
    band = 'normal';
  }

  // LnRMSSD:RR saturation guard: when mean NN is long (low HR, high vagal tone)
  // and lnRMSSD is at the top of the personal range, the metric saturates.
  final saturation =
      meanNnTodayMs != null && meanNnTodayMs > 1100 && z != null && z > 1.0;

  final conf = (priorWindow.length / windowDays.toDouble()).clamp(0.3, 0.9);
  return Metric<ReadinessLnRmssd>(
    value: ReadinessLnRmssd(
      lnRmssdToday: today,
      rolling7Mean: m,
      rolling7Median: centre,
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

/// Half-width of the single-night band in units of the baseline's robust SD
/// (MAD × 1.4826), by number of prior nights. Each entry is the empirical
/// 68.27th percentile of |tonight − median| / (MAD × 1.4826) when tonight and
/// the prior nights are drawn from one fixed normal distribution (400k trials
/// per n), so a stable user lands outside the band on ~31.7% of nights,
/// Kiviniemi's mean ± SD rate with known parameters. It folds in both the
/// prediction-interval term for a new observation (√(1 + 1/n)) and the small-n
/// bias and noise of the MAD; 3 is above 2 because the MAD of three points is
/// 1.4826 × the smaller non-median deviation and runs especially small.
/// Interpolated log-linearly in n; past the last anchor it decays toward 1 as
/// 1/n, since the MAD then converges to σ.
const List<(int, double)> _lnRmssdBandWideningTable = [
  (2, 2.144),
  (3, 2.851),
  (4, 1.884),
  (5, 1.687),
  (6, 1.487),
  (7, 1.418),
  (8, 1.334),
  (10, 1.257),
  (14, 1.172),
  (20, 1.119),
  (28, 1.085),
  (45, 1.051),
  (90, 1.025),
];

double _lnRmssdBandWidening(int n) {
  final first = _lnRmssdBandWideningTable.first;
  final last = _lnRmssdBandWideningTable.last;
  if (n <= first.$1) return first.$2;
  if (n >= last.$1) return 1 + (last.$2 - 1) * last.$1 / n;
  for (var i = 1; i < _lnRmssdBandWideningTable.length; i++) {
    final (n1, f1) = _lnRmssdBandWideningTable[i];
    if (n > n1) continue;
    final (n0, f0) = _lnRmssdBandWideningTable[i - 1];
    final t = (math.log(n) - math.log(n0)) / (math.log(n1) - math.log(n0));
    return math.exp(math.log(f0) + t * (math.log(f1) - math.log(f0)));
  }
  return 1.0;
}
