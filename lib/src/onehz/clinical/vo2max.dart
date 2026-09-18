// CLINICAL — submaximal VO2max estimate from a real steady-state workout bout.
//
// A previous `vo2maxEstimate` was deleted (see repo history) because its
// formula (15.3 * HRmax/HRrest) reduces algebraically to a rescaled resting
// heart rate — not an independent fitness signal, and it fed a
// `physiologicalAge` that then double-counted the same RHR input again. This
// is a DIFFERENT mechanism: it needs an actual recorded submaximal exercise
// bout (speed + heart rate together), not just two resting-state numbers.
//
// METHOD:
//  1. ACSM metabolic equations (ACSM's Guidelines for Exercise Testing and
//     Prescription) convert steady-state speed to submaximal VO2
//     (ml/kg/min) — walking below ~2.0 m/s, running at/above it:
//       walking: VO2 = 0.1*speed(m/min) + 1.8*speed(m/min)*grade + 3.5
//       running: VO2 = 0.2*speed(m/min) + 0.9*speed(m/min)*grade + 3.5
//  2. Swain & Leutholtz (Med Sci Sports Exerc, 1997): %heart-rate-reserve is
//     equivalent to %VO2-reserve (NOT %VO2max) — the relationship this
//     estimate actually leans on. %HRR = (HRsubmax-HRrest)/(HRmax-HRrest).
//  3. VO2max = 3.5 + (VO2submax - 3.5) / %HRR.
//
// HONESTY: needs a real steady-state bout — not just RHR and HRmax alone.
// %HRR outside a plausible submax band (too easy to extrapolate reliably, or
// too close to max to call "submaximal") abstains rather than fabricate.
// Tier ESTIMATE: wrist HR + GPS speed, not a lab treadmill/gas-exchange test.

import '../types.dart';
import '../util.dart';

/// Minimum steady-state bout duration (s) the estimate accepts — under the
/// ~5-6 min Åstrand-style submax convention, HR has not plausibly reached
/// steady state and the whole-bout average is really a warm-up average.
const int vo2maxMinBoutSec = 300;

/// %HRR band this estimate trusts. Below it the extrapolation to HRmax is
/// too large a reach from a low-intensity bout; above it the bout was near
/// maximal and is no longer "submaximal" by definition.
const double vo2maxMinHrr = 0.40;
const double vo2maxMaxHrr = 0.90;

/// Speed threshold (m/s) separating the ACSM walking vs. running equations.
const double vo2maxRunThresholdMps = 2.0;

/// Submaximal VO2max estimate from one steady-state outdoor bout.
///
/// [speedMps] and [avgHrBpm] are the bout's average pace and heart rate.
/// [boutDurationSec] is how long that average was held (see
/// [vo2maxMinBoutSec]). [restingHrBpm] and [hrMaxBpm] are the wearer's own
/// resting/max heart rate — NEVER population defaults; caller supplies real
/// derived values or this abstains. [gradePercent] is optional average grade
/// (rise/run * 100); omitted, the flat-ground equation is used, which
/// understates VO2 on a net-uphill bout and overstates it on a net-downhill
/// one — a real source of noise this does not correct for.
Metric<double> vo2maxSubmaxEstimate({
  required double speedMps,
  required double avgHrBpm,
  required int boutDurationSec,
  required double restingHrBpm,
  required double hrMaxBpm,
  double? gradePercent,
}) {
  const inputs = ['workout_speed', 'workout_hr', 'resting_hr', 'hr_max'];
  if (boutDurationSec < vo2maxMinBoutSec) {
    return Metric<double>.absent(
      tier: Tier.estimate,
      inputs_used: inputs,
      note: 'bout too short for steady-state HR '
          '(${boutDurationSec}s < ${vo2maxMinBoutSec}s)',
    );
  }
  if (speedMps <= 0 || !speedMps.isFinite) {
    return Metric<double>.absent(
      tier: Tier.estimate,
      inputs_used: inputs,
      note: 'no steady-state pace for this bout',
    );
  }
  final hrReserve = hrMaxBpm - restingHrBpm;
  if (hrReserve < 20) {
    return Metric<double>.absent(
      tier: Tier.estimate,
      inputs_used: inputs,
      note: 'hr_max too close to resting_hr — unreliable %HRR',
    );
  }
  final hrr = (avgHrBpm - restingHrBpm) / hrReserve;
  if (!hrr.isFinite || hrr < vo2maxMinHrr || hrr > vo2maxMaxHrr) {
    return Metric<double>.absent(
      tier: Tier.estimate,
      inputs_used: inputs,
      note: 'bout intensity outside the submaximal %HRR band '
          '(${(hrr * 100).round()}%, need '
          '${(vo2maxMinHrr * 100).round()}-${(vo2maxMaxHrr * 100).round()}%)',
    );
  }

  final speedMMin = speedMps * 60.0;
  final grade = (gradePercent ?? 0.0) / 100.0;
  final vo2Submax = speedMps >= vo2maxRunThresholdMps
      ? 0.2 * speedMMin + 0.9 * speedMMin * grade + 3.5
      : 0.1 * speedMMin + 1.8 * speedMMin * grade + 3.5;

  final vo2max = 3.5 + (vo2Submax - 3.5) / hrr;
  if (!vo2max.isFinite || vo2max <= 3.5 || vo2max > 95) {
    return Metric<double>.absent(
      tier: Tier.estimate,
      inputs_used: inputs,
      note: 'extrapolated VO2max outside a plausible human range',
    );
  }

  // Confidence peaks mid-band (~65% HRR, the classic submax sweet spot) and
  // falls toward either edge, where the %HRR-to-%VO2R equivalence is
  // stretched thinnest or the bout is barely submaximal at all.
  final bandCenter = (vo2maxMinHrr + vo2maxMaxHrr) / 2;
  final bandHalfWidth = (vo2maxMaxHrr - vo2maxMinHrr) / 2;
  final centerDist = (hrr - bandCenter).abs() / bandHalfWidth; // 0..1
  final conf = (0.6 - 0.25 * centerDist).clamp(0.25, 0.6);

  return Metric<double>(
    value: round6(vo2max),
    confidence: conf,
    tier: Tier.estimate,
    // Grade changes vo2Submax above whenever it's supplied, so it belongs in
    // provenance too — only from here on, since the early abstentions above
    // never reached the line that reads it.
    inputs_used: gradePercent == null ? inputs : [...inputs, 'workout_grade'],
    note: 'submax VO2max via ACSM speed->VO2 + Swain %HRR~%VO2R '
        '(Swain & Leutholtz 1997); one steady bout, not a lab test',
  );
}
