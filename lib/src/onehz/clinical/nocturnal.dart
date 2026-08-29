// CLINICAL TIER-1 — nocturnal RHR and HR dip %.
//
// Nocturnal RHR (Avram 2019; Dial 2025): lowest-30-min rolling mean of valid
// HR, plus the 1st-percentile of valid HR as a floor reference. HR=0 (off-skin)
// is EXCLUDED — never treated as bradycardia.
//
// HR dip % (dipper / non-dipper / riser): the nocturnal HR trough relative to
// the daytime mean, a CV-risk + acute-strain signal.

import '../types.dart';
import '../util.dart';

class NocturnalRhr {
  final double low30Mean; // lowest 30-min mean HR (bpm)
  final double p1; // 1st-percentile valid HR (bpm)
  final int validSamples;
  const NocturnalRhr(this.low30Mean, this.p1, this.validSamples);
  Map<String, dynamic> toJson() => {
        'low30_mean_bpm': round6(low30Mean),
        'p1_bpm': round6(p1),
        'valid_samples': validSamples,
      };
}

/// Nocturnal resting HR from a night of HR samples.
///
/// [hr] HR samples (bpm; 0 = off-skin, excluded). [window] the rolling trough
/// window as a DURATION (default 30 min). [tsSec] their sample times (seconds);
/// null keeps the historical contract — one sample per second, so a position IS
/// a wall-clock second, which is what every WHOOP caller feeds. [minCoverage]
/// fraction of a window's expected samples that must carry a valid on-skin
/// reading for the window to count.
///
/// The window slides over WALL-CLOCK TIME, not over sample positions. It used
/// to be a fixed 1800 POSITIONS, which is 30 min only at 1 Hz: on a 15 s band
/// the same 1800 positions span 7.5 h, so "the lowest 30-min mean" quietly
/// became "the whole-night mean" — measured on a real night, 59.7 bpm published
/// as 66.4. With [tsSec] the window length is derived from the stream's own
/// measured cadence ([sampleCadenceSeconds]), which ABSTAINS rather than
/// guessing, so an unmeasurable cadence yields an absent metric.
///
/// Off-skin gaps are still never compacted away: coverage is checked against
/// the samples a full window SHOULD hold, so a window that is mostly hole stays
/// ineligible. A night with no window meeting [minCoverage] yields an ABSENT
/// metric — we never relabel the whole-night mean as a lowest-30-min trough.
Metric<NocturnalRhr> nocturnalRhr(List<double> hr,
    {List<double>? tsSec,
    Duration window = const Duration(minutes: 30),
    double minCoverage = 0.9}) {
  const inputs = ['hr_1hz'];
  final valid = hr.where((h) => h > 0).toList();
  if (tsSec != null && tsSec.length != hr.length) {
    return const Metric<NocturnalRhr>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'HR and timestamps disagree in length',
    );
  }
  final ts = tsSec ?? [for (var i = 0; i < hr.length; i++) i.toDouble()];
  // The null path is 1 Hz BY CONTRACT, not by measurement — pinning it here
  // keeps WHOOP output bit-identical instead of routing it through a helper
  // that can abstain on a night the app already scores today.
  final cadence = tsSec == null ? 1.0 : sampleCadenceSeconds(ts);
  final winSec = window.inSeconds.toDouble();
  if (cadence == null) {
    return const Metric<NocturnalRhr>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'no measurable sampling cadence — a 30-min trough cannot be '
          'located without knowing how much time one sample covers',
    );
  }
  // Samples a fully-covered window holds at this cadence: 1800 at 1 Hz, 120 at
  // 15 s, 30 at 60 s. This is the number the old fixed `windowSamples = 1800`
  // got wrong for every stream that is not 1 Hz.
  final perWindow = winSec / cadence;
  if (perWindow < 1 || hr.length < perWindow) {
    return const Metric<NocturnalRhr>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'insufficient valid (on-skin) HR for nocturnal RHR',
    );
  }
  // Lowest rolling mean over CONTIGUOUS wall-clock windows. A window is only
  // eligible when at least [minCoverage] of the samples it should hold are
  // on-skin; its mean is taken over the valid samples inside it.
  final needValid = (minCoverage * perWindow).ceil();
  // A window ending before this has not had a full [window] of stream behind
  // it — the same rule the positional loop expressed as "start at index 1800".
  final firstFullEnd = ts.first + winSec - cadence;
  var sum = 0.0;
  var count = 0;
  var lo = 0;
  double? best;
  for (var hi = 0; hi < hr.length; hi++) {
    if (hr[hi] > 0) {
      sum += hr[hi];
      count++;
    }
    while (ts[hi] - ts[lo] >= winSec) {
      if (hr[lo] > 0) {
        sum -= hr[lo];
        count--;
      }
      lo++;
    }
    // `count == 0` is its own guard, not just a stricter `needValid`: a caller
    // that passes `minCoverage: 0` makes `needValid` 0 too, and `count <
    // needValid` is then never true for a non-negative count — so a window
    // with NO on-skin sample would otherwise reach `sum / count` as `0.0 / 0`,
    // which is NaN in Dart. NaN LATCHES here (`m < best` is false for a NaN
    // `m`, and false again once a NaN `best` is compared against anything
    // later), so one such window would silently poison the whole night's
    // trough instead of being skipped.
    if (ts[hi] < firstFullEnd || count < needValid || count == 0) continue;
    final m = sum / count;
    if (best == null || m < best) best = m;
  }
  if (best == null) {
    return const Metric<NocturnalRhr>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'no contiguous on-skin window long enough for a nocturnal RHR '
          'trough (off-skin gaps are never compacted away)',
    );
  }
  final p1 = percentile(valid, 1)!;
  // Confidence is COVERAGE IN SECONDS, not a sample count — 480 samples of a
  // 60 s band is the same 8 h of night as 28,800 samples at 1 Hz.
  final conf =
      (valid.length * cadence / 7200.0).clamp(0.4, 0.95); // ~2 h => high
  return Metric<NocturnalRhr>(
    value: NocturnalRhr(best, p1, valid.length),
    confidence: conf,
    tier: Tier.high,
    inputs_used: inputs,
    note: 'lowest-${window.inMinutes}-min mean + 1st-percentile; HR=0 excluded '
        'as off-skin',
  );
}

class HrDip {
  final double dipPct; // (day - night)/day * 100
  final double dayMean;
  final double nightMean;
  final String band; // 'dipper' | 'non_dipper' | 'riser'
  const HrDip(this.dipPct, this.dayMean, this.nightMean, this.band);
  Map<String, dynamic> toJson() => {
        'dip_pct': round6(dipPct),
        'day_mean_bpm': round6(dayMean),
        'night_mean_bpm': round6(nightMean),
        'band': band,
      };
}

/// Minimum valid on-skin samples required on EACH side (day, night) before a
/// dip % is reported: 300 samples ≈ 5 min at 1 Hz. Below that a "daytime mean"
/// and a "nocturnal mean" are single moments, not periods.
const int hrDipMinSamples = 300;

/// Nocturnal HR dip %. [dayHr] and [nightHr] are 1 Hz HR samples for the waking
/// and sleeping periods respectively (0 excluded). Bands follow the BP-dip
/// convention applied to HR: ≥10% dipper, 0–10% non-dipper, <0 riser.
///
/// Both sides need at least [minSamples] valid samples — one day sample and one
/// night sample can produce any dip % at all, so a dip band computed from a
/// handful of samples is fabrication, not measurement.
Metric<HrDip> hrDip(List<double> dayHr, List<double> nightHr,
    {int minSamples = hrDipMinSamples}) {
  const inputs = ['hr_1hz_day', 'hr_1hz_night'];
  final dv = dayHr.where((h) => h > 0).toList();
  final nv = nightHr.where((h) => h > 0).toList();
  if (dv.length < minSamples || nv.length < minSamples) {
    return Metric<HrDip>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'HR dip needs ≥$minSamples valid samples on each of day and night '
          '(have day=${dv.length}, night=${nv.length})',
    );
  }
  final dm = mean(dv);
  final nm = mean(nv);
  if (dm == null || nm == null || dm <= 0) {
    return const Metric<HrDip>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'need both day and night valid HR',
    );
  }
  final dip = (dm - nm) / dm * 100;
  final band = dip >= 10 ? 'dipper' : (dip >= 0 ? 'non_dipper' : 'riser');
  final conf = ((dv.length + nv.length) / 14400.0).clamp(0.4, 0.9);
  return Metric<HrDip>(
    value: HrDip(dip, dm, nm, band),
    confidence: conf,
    tier: Tier.high,
    inputs_used: inputs,
    note: 'night-day HR ratio; CV-risk + acute-strain signal',
  );
}
