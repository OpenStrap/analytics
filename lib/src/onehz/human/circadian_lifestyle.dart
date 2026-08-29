// HUMAN LAYER — social jetlag & chronotype.
// Catalog §A: Social jetlag [PUB Wittmann/Roenneberg 2006] (ship first) and
// chronotype label via MSFsc [PUB] (HR-acrophase variant is HEUR).
//
// Mid-sleep is the clock-time midpoint of a sleep episode, supplied by the
// caller as LOCAL TIME-OF-DAY in [0, 24). That is a CIRCULAR quantity: 23.9 h
// and 0.1 h are 12 minutes apart, not 23.8 h apart. Every statistic here is
// therefore computed with circular methods (Fisher, *Statistical Analysis of
// Circular Data*, 1993, §2.2–2.3): the summary point is the circular median
// (ordinary median on the sample unwrapped about its circular mean) and the
// difference between two midpoints is the SHORTEST signed arc on the 24 h
// circle, in (−12, +12]. Taking a plain median/subtraction on raw clock-hours
// — what this file used to do — reported a ~23:50 weekday vs ~01:10 weekend
// midsleep as 22.5 h of social jetlag instead of +1.4 h.
//
// Social jetlag = signed shortest-arc difference between free-day (weekend) and
// work-day (weekday) mid-sleep [PUB Wittmann, Dinich, Merrow & Roenneberg,
// *Chronobiol Int* 2006;23(1-2):497–509].
//
// MSFsc (sleep-corrected mid-sleep on free days) corrects the free-day midpoint
// for oversleep relative to the weekly average, the standard MCTQ chronotype
// proxy [PUB Roenneberg et al., *Curr Biol* 2004; *Sleep Med Rev* 2007]. We DO
// NOT print absolute MSFsc minutes (catalog honesty rule) — only a coarse type
// label + a percentile-of-you for stability. The label bands and the stability
// percentile are evaluated on the MCTQ band axis: clock-hours unwrapped about
// 06:00, i.e. (−6, +18], so that a 23:30 mid-sleep reads as −0.5 h (early type)
// rather than 23.5 h (which the old [0,24) bands mislabelled "evening type").
//
// HONESTY: report STATE (your weekend runs later) not a clinical chronotype
// diagnosis; gate ≥minDays with ≥2 free days; "—" when insufficient.

import 'dart:math' as math;

import '../types.dart';
import '../util.dart';
import 'percentile_of_you.dart';

// ── Circular helpers on the 24 h clock ──────────────────────────────────────

/// Wrap a clock-hour into [0, 24).
double _wrap24(double h) {
  final r = h % 24.0;
  return r < 0 ? r + 24.0 : r;
}

/// Shortest signed arc `a − b` on the 24 h circle, in (−12, +12].
double _circDiffH(double a, double b) {
  var d = (a - b) % 24.0;
  if (d < 0) d += 24.0;
  if (d > 12.0) d -= 24.0;
  return d;
}

/// Unwrap [h] onto the continuous axis centred on [centre] — i.e. the
/// representative of [h] nearest [centre]. Result lies in (centre−12, centre+12].
double _unwrapAround(double centre, double h) => centre + _circDiffH(h, centre);

/// Circular mean direction of clock-hours (Fisher 1993 §2.2): the angle of the
/// resultant of the unit vectors. Null when the resultant vanishes (an
/// antipodal/uniform sample has no defined mean direction) or the sample is
/// empty.
double? _circMeanH(List<double> hs) {
  if (hs.isEmpty) return null;
  var sx = 0.0, sy = 0.0;
  for (final h in hs) {
    final a = h * math.pi / 12.0; // 24 h ↔ 2π
    sx += math.cos(a);
    sy += math.sin(a);
  }
  if (math.sqrt(sx * sx + sy * sy) < 1e-9) return null; // no resultant
  return _wrap24(math.atan2(sy, sx) * 12.0 / math.pi);
}

/// Circular median of clock-hours (Fisher 1993 §2.3): the ordinary median taken
/// on the sample unwrapped about its circular mean, wrapped back to [0, 24).
/// Robust to the odd late night AND correct across midnight. Null when the
/// sample is empty or has no defined mean direction.
double? _circMedianH(List<double> hs) {
  if (hs.isEmpty) return null;
  final anchor = _circMeanH(hs);
  if (anchor == null) return null;
  final unwrapped = [for (final h in hs) _unwrapAround(anchor, h)];
  return _wrap24(median(unwrapped)!);
}

/// Anchor for the MCTQ chronotype band axis: 06:00. Mid-sleep on free days sits
/// in the small hours for essentially everyone, so unwrapping about 06:00 puts
/// early types at negative hours and evening types at 5–8 h — a monotone axis
/// the label bands can be read off directly.
const double _mctqBandAnchorH = 6.0;

class SocialJetlag {
  /// Signed SHORTEST ARC free-day − work-day mid-sleep on the 24 h circle,
  /// in (−12, +12]. Positive => weekends run later.
  final double sjlHours;
  final double absHours; // |sjlHours| ≤ 12, the headline "jet zones" magnitude
  final double midSleepFree; // circular median free-day mid-sleep, [0,24)
  final double midSleepWork; // circular median work-day mid-sleep, [0,24)
  final int nFree;
  final int nWork;
  const SocialJetlag(this.sjlHours, this.absHours, this.midSleepFree,
      this.midSleepWork, this.nFree, this.nWork);
  Map<String, dynamic> toJson() => {
        'sjl_hours': round6(sjlHours),
        'abs_hours': round6(absHours),
        'mid_sleep_free_h': round6(midSleepFree),
        'mid_sleep_work_h': round6(midSleepWork),
        'n_free': nFree,
        'n_work': nWork,
      };
}

/// Social jetlag from per-night mid-sleep clock-hours, split into free-day
/// (e.g. weekend / unconstrained) and work-day midpoints.
///
/// [freeMidSleepH] / [workMidSleepH] are decimal LOCAL clock-hours in [0, 24)
/// of the sleep midpoint for each night in the respective category. We use the
/// CIRCULAR MEDIAN (robust to the odd late night, and correct across midnight)
/// and the SHORTEST SIGNED ARC between the two midpoints, so |SJL| can never
/// exceed 12 h [PUB Wittmann/Roenneberg 2006]. Positive SJL => weekends run
/// LATER.
Metric<SocialJetlag> socialJetlag(
  List<double> freeMidSleepH,
  List<double> workMidSleepH, {
  int minPerSide = 2,
}) {
  const inputs = ['mid_sleep_free', 'mid_sleep_work'];
  if (freeMidSleepH.length < minPerSide || workMidSleepH.length < minPerSide) {
    return const Metric<SocialJetlag>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'need ≥2 free-day and ≥2 work-day nights to compare',
    );
  }
  final msf = _circMedianH(freeMidSleepH);
  final msw = _circMedianH(workMidSleepH);
  if (msf == null || msw == null) {
    return const Metric<SocialJetlag>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'mid-sleep times have no resultant direction on the 24 h circle '
          '— no meaningful midpoint (never imputed)',
    );
  }
  final sjl = _circDiffH(msf, msw); // signed shortest arc, (−12, +12]
  final conf =
      ((freeMidSleepH.length + workMidSleepH.length) / 14.0).clamp(0.3, 0.9);
  return Metric<SocialJetlag>(
    value: SocialJetlag(
        sjl, sjl.abs(), msf, msw, freeMidSleepH.length, workMidSleepH.length),
    confidence: conf,
    tier: Tier.high,
    inputs_used: inputs,
    note: 'signed weekend−weekday mid-sleep drift on the 24 h circle '
        '(≈ jet zones, |SJL| ≤ 12 h), behavioral',
  );
}

class Chronotype {
  /// Sleep-corrected free-day mid-sleep, decimal clock-hours wrapped to [0,24).
  /// INTERNAL — never surfaced as an absolute number; the label and the
  /// stability percentile are derived from it on the MCTQ band axis (unwrapped
  /// about 06:00), so both agree with this value.
  final double msfScHours;
  final String typeLabel; // coarse early/intermediate/late label
  final Metric<PercentileOfYou>? stability; // percentile-of-you for steadiness
  const Chronotype(this.msfScHours, this.typeLabel, this.stability);
  Map<String, dynamic> toJson() => {
        // NOTE: msfScHours is deliberately NOT emitted as an absolute minute.
        'type_label': typeLabel,
        if (stability != null) 'stability': stability!.toJson(),
      };
}

/// Chronotype from MCTQ-style mid-sleep.
///
/// [freeMidSleepH] free-day mid-sleep clock-hours; [freeSleepDurH] matching
/// free-day sleep durations (h); [avgWeekSleepDurH] the average sleep duration
/// across the whole week (work+free). MSFsc = MSF − (SD_free − SD_week)/2 when
/// the person sleeps longer on free days (oversleep correction; Roenneberg).
///
/// [history] optional prior MSFsc values (decimal h) for a stability
/// percentile-of-you. Gate: ≥[minFreeDays] free days and ≥[minTotalDays].
Metric<Chronotype> chronotype(
  List<double> freeMidSleepH,
  List<double> freeSleepDurH, {
  required double avgWeekSleepDurH,
  List<double> history = const [],
  int minFreeDays = 2,
  int minTotalDays = 14,
  int totalDaysObserved = 0,
}) {
  const inputs = ['mid_sleep_free', 'sleep_duration'];
  // The two lists are index-paired free nights. A length mismatch is a CALLER
  // bug (one list gated on the sleep window, the other on the accounting block),
  // not a coverage problem — saying "you need 14 days" to someone who has 40 is
  // a false statement about their data, so it gets its own note.
  if (freeSleepDurH.length != freeMidSleepH.length) {
    return Metric<Chronotype>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'free-day mid-sleep and sleep-duration nights are not paired '
          '(${freeMidSleepH.length} vs ${freeSleepDurH.length})',
    );
  }
  if (freeMidSleepH.length < minFreeDays || totalDaysObserved < minTotalDays) {
    return Metric<Chronotype>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'chronotype needs ≥$minTotalDays days with ≥$minFreeDays free days',
    );
  }
  // CIRCULAR median (see the helpers at the top): a free-day mid-sleep set
  // straddling midnight must not be averaged on a linear axis.
  final msfCirc = _circMedianH(freeMidSleepH);
  if (msfCirc == null) {
    return const Metric<Chronotype>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'free-day mid-sleep has no resultant direction on the 24 h circle',
    );
  }
  final sdFree = median(freeSleepDurH)!; // a DURATION — linear, not circular
  // Oversleep correction only when free-day sleep exceeds the weekly average.
  // MSFsc = MSF − (SD_free − SD_week)/2 [PUB Roenneberg, MCTQ].
  final correction =
      sdFree > avgWeekSleepDurH ? (sdFree - avgWeekSleepDurH) / 2.0 : 0.0;
  final msfSc = _wrap24(msfCirc - correction);

  // Coarse label off MSFsc, read on the MCTQ BAND AXIS — clock-hours unwrapped
  // about 06:00, so a 23:30 mid-sleep is −0.5 h (early) rather than 23.5 h,
  // which the old [0,24) bands mislabelled as the latest possible type. The
  // population anchors are only for the label band — never printed as a number.
  final band = _unwrapAround(_mctqBandAnchorH, msfSc);
  String label;
  if (band < 3.0) {
    label = 'early type';
  } else if (band < 4.0) {
    label = 'moderate early type';
  } else if (band < 5.0) {
    label = 'intermediate type';
  } else if (band < 6.0) {
    label = 'moderate evening type';
  } else {
    label = 'evening type';
  }

  Metric<PercentileOfYou>? stability;
  if (history.length >= 14) {
    // Compare on the same continuous band axis, so a history straddling
    // midnight ranks by real chronotype distance instead of by clock wrap.
    stability = percentileOfYou(
      band,
      [for (final h in history) _unwrapAround(_mctqBandAnchorH, _wrap24(h))],
      // A chronotype has no better end — an early type is not a good type.
      better: Better.neither,
      minN: 14,
    );
  }

  return Metric<Chronotype>(
    value: Chronotype(msfSc, label, stability),
    confidence: (totalDaysObserved / 28.0).clamp(0.3, 0.9),
    tier: Tier.high,
    inputs_used: inputs,
    note: 'MSFsc chronotype label (direction only, no absolute minutes)',
  );
}
