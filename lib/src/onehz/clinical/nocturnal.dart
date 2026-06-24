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
/// [hr] 1 Hz HR samples (bpm; 0 = off-skin, excluded). [windowSec] rolling mean
/// window (default 30 min). Assumes ~1 Hz spacing; uses a sample-count window.
Metric<NocturnalRhr> nocturnalRhr(List<double> hr, {int windowSamples = 1800}) {
  const inputs = ['hr_1hz'];
  final valid = hr.where((h) => h > 0).toList();
  if (valid.length < windowSamples ~/ 2) {
    return const Metric<NocturnalRhr>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'insufficient valid (on-skin) HR for nocturnal RHR',
    );
  }
  // Lowest rolling mean over the valid stream.
  final w = windowSamples > valid.length ? valid.length : windowSamples;
  var sum = 0.0;
  for (var i = 0; i < w; i++) {
    sum += valid[i];
  }
  var best = sum / w;
  for (var i = w; i < valid.length; i++) {
    sum += valid[i] - valid[i - w];
    final m = sum / w;
    if (m < best) best = m;
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

/// Nocturnal HR dip %. [dayHr] and [nightHr] are 1 Hz HR samples for the waking
/// and sleeping periods respectively (0 excluded). Bands follow the BP-dip
/// convention applied to HR: ≥10% dipper, 0–10% non-dipper, <0 riser.
Metric<HrDip> hrDip(List<double> dayHr, List<double> nightHr) {
  const inputs = ['hr_1hz_day', 'hr_1hz_night'];
  final dv = dayHr.where((h) => h > 0).toList();
  final nv = nightHr.where((h) => h > 0).toList();
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
