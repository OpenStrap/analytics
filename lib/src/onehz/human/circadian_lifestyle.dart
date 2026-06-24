// HUMAN LAYER — social jetlag & chronotype.
// Catalog §A: Social jetlag [PUB Wittmann/Roenneberg 2006] (ship first) and
// chronotype label via MSFsc [PUB] (HR-acrophase variant is HEUR).
//
// Mid-sleep is the clock-time midpoint of a sleep episode (decimal hours, may
// exceed 24 for after-midnight midpoints — we keep it on a continuous axis so
// circular wrap doesn't corrupt the mean). Social jetlag = signed difference
// between free-day (weekend) and work-day (weekday) mid-sleep.
//
// MSFsc (sleep-corrected mid-sleep on free days) corrects the free-day midpoint
// for oversleep relative to the weekly average, the standard MCTQ chronotype
// proxy. We DO NOT print absolute MSFsc minutes (catalog honesty rule) — only a
// coarse type label + a percentile-of-you for stability.
//
// HONESTY: report STATE (your weekend runs later) not a clinical chronotype
// diagnosis; gate ≥minDays with ≥2 free days; "—" when insufficient.

import '../types.dart';
import '../util.dart';
import 'percentile_of_you.dart';

class SocialJetlag {
  final double sjlHours; // signed: free-day midsleep − work-day midsleep
  final double absHours; // |sjlHours|, the headline "jet zones" magnitude
  final double midSleepFree; // mean free-day mid-sleep (decimal h)
  final double midSleepWork; // mean work-day mid-sleep (decimal h)
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
/// [freeMidSleepH] / [workMidSleepH] are decimal clock-hours of the sleep
/// midpoint for each night in the respective category. We use the MEDIAN
/// (robust to the odd late night). Positive SJL => weekends run LATER.
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
  final msf = median(freeMidSleepH)!;
  final msw = median(workMidSleepH)!;
  final sjl = msf - msw; // signed
  final conf = clamp(
      (freeMidSleepH.length + workMidSleepH.length) / 14.0, 0.3, 0.9);
  return Metric<SocialJetlag>(
    value: SocialJetlag(
        sjl, sjl.abs(), msf, msw, freeMidSleepH.length, workMidSleepH.length),
    confidence: conf,
    tier: Tier.high,
    inputs_used: inputs,
    note: 'signed weekend−weekday mid-sleep drift (≈ jet zones), behavioral',
  );
}

class Chronotype {
  /// Sleep-corrected free-day mid-sleep, decimal clock-hours. INTERNAL — never
  /// surfaced as an absolute number; drives the label + percentile only.
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
  if (freeMidSleepH.length < minFreeDays ||
      freeSleepDurH.length != freeMidSleepH.length ||
      totalDaysObserved < minTotalDays) {
    return const Metric<Chronotype>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'chronotype needs ≥14 days with ≥2 free days',
    );
  }
  final msf = median(freeMidSleepH)!;
  final sdFree = median(freeSleepDurH)!;
  // Oversleep correction only when free-day sleep exceeds the weekly average.
  final correction =
      sdFree > avgWeekSleepDurH ? (sdFree - avgWeekSleepDurH) / 2.0 : 0.0;
  final msfSc = msf - correction;

  // Coarse label off MSFsc clock-hour (population anchors are only for the
  // label band — never printed as a number).
  String label;
  if (msfSc < 3.0) {
    label = 'early type';
  } else if (msfSc < 4.0) {
    label = 'moderate early type';
  } else if (msfSc < 5.0) {
    label = 'intermediate type';
  } else if (msfSc < 6.0) {
    label = 'moderate evening type';
  } else {
    label = 'evening type';
  }

  Metric<PercentileOfYou>? stability;
  if (history.length >= 14) {
    stability = percentileOfYou(msfSc, history, minN: 14);
  }

  return Metric<Chronotype>(
    value: Chronotype(msfSc, label, stability),
    confidence: clamp(totalDaysObserved / 28.0, 0.3, 0.9),
    tier: Tier.high,
    inputs_used: inputs,
    note: 'MSFsc chronotype label (direction only, no absolute minutes)',
  );
}
