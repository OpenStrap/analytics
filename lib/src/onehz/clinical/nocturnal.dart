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

/// Nocturnal resting HR from a night of 1 Hz HR samples.
///
/// [hr] 1 Hz HR samples (bpm; 0 = off-skin, excluded). [windowSamples] rolling
/// window length in SAMPLE POSITIONS (default 1800 = 30 min at 1 Hz).
/// [minCoverage] fraction of a window's positions that must carry a valid
/// on-skin sample for the window to count.
///
/// The window slides over WALL-CLOCK POSITIONS, not over the compacted valid
/// stream: an off-skin gap must not be closed up, or the "30-min" window can
/// silently span the whole night. A night with no window meeting [minCoverage]
/// yields an ABSENT metric — we never relabel the whole-night mean as a
/// lowest-30-min trough.
Metric<NocturnalRhr> nocturnalRhr(List<double> hr,
    {int windowSamples = 1800, double minCoverage = 0.9}) {
  const inputs = ['hr_1hz'];
  final valid = hr.where((h) => h > 0).toList();
  if (windowSamples < 1 || hr.length < windowSamples) {
    return const Metric<NocturnalRhr>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'insufficient valid (on-skin) HR for nocturnal RHR',
    );
  }
  // Lowest rolling mean over CONTIGUOUS wall-clock windows. A window is only
  // eligible when at least [minCoverage] of its positions are on-skin; its
  // mean is taken over the valid samples inside it.
  final needValid = (minCoverage * windowSamples).ceil();
  var sum = 0.0;
  var count = 0;
  for (var i = 0; i < windowSamples; i++) {
    if (hr[i] > 0) {
      sum += hr[i];
      count++;
    }
  }
  double? best;
  if (count >= needValid) best = sum / count;
  for (var i = windowSamples; i < hr.length; i++) {
    if (hr[i] > 0) {
      sum += hr[i];
      count++;
    }
    final out = hr[i - windowSamples];
    if (out > 0) {
      sum -= out;
      count--;
    }
    if (count >= needValid) {
      final m = sum / count;
      if (best == null || m < best) best = m;
    }
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
  final conf = clamp(valid.length / 7200.0, 0.4, 0.95); // ~2 h coverage => high
  return Metric<NocturnalRhr>(
    value: NocturnalRhr(best, p1, valid.length),
    confidence: conf,
    tier: Tier.high,
    inputs_used: inputs,
    note: 'lowest-30-min mean + 1st-percentile; HR=0 excluded as off-skin',
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
  final conf = clamp((dv.length + nv.length) / 14400.0, 0.4, 0.9);
  return Metric<HrDip>(
    value: HrDip(dip, dm, nm, band),
    confidence: conf,
    tier: Tier.high,
    inputs_used: inputs,
    note: 'night-day HR ratio; CV-risk + acute-strain signal',
  );
}
