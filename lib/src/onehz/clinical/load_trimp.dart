// CLINICAL TIER-1 — training load: TRIMP + CTL/ATL/TSB.
//
// Edwards 1993 zone-sum TRIMP and Banister exponential TRIMP (Morton 1990).
// CTL (Chronic Training Load, 42-day EWMA of daily TRIMP), ATL (Acute, 7-day
// EWMA), TSB = CTL − ATL (Training Stress Balance / "form").
//
// Banister: TRIMP = Σ Δt(min) · ΔHRr · y, where ΔHRr = (HR−RHR)/(HRmax−RHR)
// and y = e^(b·ΔHRr), b = 1.92 (male) / 1.67 (female). Needs measured HRmax+RHR.
//
// HONESTY: ESTIMATE tier (wrist HR, no power/VO2). Non-wear gaps must be guarded
// — pass only valid on-skin minutes. CTL/ATL are descriptive load, not injury
// prediction.

import 'dart:math' as math;
import '../types.dart';
import '../util.dart';

/// Banister TRIMP over a series of per-minute mean HRs.
///
/// [hrPerMin] mean HR for each worn minute (bpm; pass only valid minutes).
/// [restingHr], [maxHr] the personal anchors. [sex] selects the b constant.
/// Returns absent if anchors are missing/degenerate (no fabrication).
Metric<double> banisterTrimp(
  List<double> hrPerMin, {
  required double? restingHr,
  required double? maxHr,
  required Sex sex,
}) {
  const inputs = ['hr_per_min', 'resting_hr', 'max_hr'];
  if (restingHr == null ||
      maxHr == null ||
      maxHr <= restingHr ||
      hrPerMin.isEmpty) {
    return const Metric<double>.absent(
      tier: Tier.estimate,
      inputs_used: inputs,
      note: 'Banister TRIMP needs measured RHR and HRmax (HRmax>RHR)',
    );
  }
  final b = sex == Sex.male ? 1.92 : 1.67;
  final reserve = maxHr - restingHr;
  var trimp = 0.0;
  for (final hr in hrPerMin) {
    if (hr <= 0) continue; // off-skin guard
    var hrr = (hr - restingHr) / reserve;
    if (hrr < 0) hrr = 0;
    if (hrr > 1) hrr = 1;
    trimp += 1.0 * hrr * math.exp(b * hrr); // 1 minute each
  }
  return Metric<double>(
    value: trimp,
    confidence: 0.6,
    tier: Tier.estimate,
    inputs_used: inputs,
    note: 'Banister exponential TRIMP (wrist HR estimate)',
  );
}

/// Edwards zone-sum TRIMP. [zoneMinutes] minutes in each of the 5 HR zones
/// (50–60/60–70/70–80/80–90/90–100 %HRmax); weights 1..5.
Metric<double> edwardsTrimp(List<double> zoneMinutes) {
  const inputs = ['zone_minutes'];
  if (zoneMinutes.length != 5) {
    return const Metric<double>.absent(
      tier: Tier.estimate,
      inputs_used: inputs,
      note: 'Edwards TRIMP needs 5 zone minutes',
    );
  }
  var t = 0.0;
  for (var i = 0; i < 5; i++) {
    t += zoneMinutes[i] * (i + 1);
  }
  return Metric<double>(
    value: t,
    confidence: 0.6,
    tier: Tier.estimate,
    inputs_used: inputs,
    note: 'Edwards zone-sum TRIMP',
  );
}

class LoadState {
  final double ctl; // chronic (42d)
  final double atl; // acute (7d)
  final double tsb; // form = ctl - atl
  const LoadState(this.ctl, this.atl, this.tsb);
  Map<String, dynamic> toJson() => {
        'ctl': round6(ctl),
        'atl': round6(atl),
        'tsb': round6(tsb),
      };
}

/// CTL/ATL/TSB from a time-ordered daily-TRIMP series (oldest→newest).
/// EWMA with time constants 42 d (CTL) and 7 d (ATL): λ = 1 − e^(−1/τ).
/// A missing day contributes a 0-load impulse (rest day) — the EWMA decays.
Metric<LoadState> ctlAtlTsb(List<double> dailyTrimp,
    {double ctlDays = 42, double atlDays = 7}) {
  const inputs = ['daily_trimp'];
  if (dailyTrimp.isEmpty) {
    return const Metric<LoadState>.absent(
      tier: Tier.estimate,
      inputs_used: inputs,
      note: 'no daily TRIMP history',
    );
  }
  final lc = 1 - math.exp(-1 / ctlDays);
  final la = 1 - math.exp(-1 / atlDays);
  var ctl = dailyTrimp.first;
  var atl = dailyTrimp.first;
  for (var i = 1; i < dailyTrimp.length; i++) {
    ctl = ctl + lc * (dailyTrimp[i] - ctl);
    atl = atl + la * (dailyTrimp[i] - atl);
  }
  final conf = clamp(dailyTrimp.length / 42.0, 0.3, 0.85);
  return Metric<LoadState>(
    value: LoadState(ctl, atl, ctl - atl),
    confidence: conf,
    tier: Tier.estimate,
    inputs_used: inputs,
    note: 'Banister CTL(42d)/ATL(7d)/TSB; descriptive load, not injury risk',
  );
}
