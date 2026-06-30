// WORKOUT — Heart-Rate Recovery (HRR) after exercise.
//
// HRR is the drop in heart rate in the first minute(s) after exercise stops — a
// validated marker of parasympathetic reactivation and cardiovascular fitness
// (Cole 1999: HRR-1min < 12 bpm after upright exercise is a known risk marker;
// fitter people recover faster). Computed from the per-second HR tail at the end
// of a bout: peak (or end) HR minus HR at +60 s.
//
// HONESTY: needs a clean HR tail that actually descends from an elevated peak.
// If the wearer kept moving (HR stayed high) or the signal is missing, we return
// absent rather than a fabricated drop. Tier ESTIMATE (wrist pulse, not ECG).

import '../types.dart';
import '../util.dart';

class HrRecovery {
  final double peakHr; // bpm at/near exercise end
  final double hrAt60s; // bpm 60 s later
  final double dropBpm; // peakHr - hrAt60s (≥0)
  final double dropPct; // drop as % of peak
  const HrRecovery({
    required this.peakHr,
    required this.hrAt60s,
    required this.dropBpm,
    required this.dropPct,
  });
  Map<String, dynamic> toJson() => {
        'peak_hr': round6(peakHr),
        'hr_at_60s': round6(hrAt60s),
        'drop_bpm': round6(dropBpm),
        'drop_pct': round6(dropPct),
      };
}

/// Heart-rate recovery from a per-second HR tail bracketing the end of a bout.
///
/// [hrTailBpm] is a contiguous per-second HR series (bpm; 0 = off-skin) covering
/// roughly the last [peakWindowSec] of exercise through at least [recoverySec]
/// after it stopped. [endIndex] is the index in [hrTailBpm] where exercise ended
/// (the recovery clock starts there); if null, the series is assumed to start at
/// exercise end. Peak HR is the max over the [peakWindowSec] before end; recovery
/// HR is the median of a small window around end+[recoverySec] (robust to a single
/// spike). Returns absent if the tail is too short, off-skin, or doesn't descend.
Metric<HrRecovery> hrRecovery(
  List<int> hrTailBpm, {
  int? endIndex,
  int recoverySec = 60,
  int peakWindowSec = 30,
}) {
  const inputs = ['hr_1hz'];
  final end = endIndex ?? 0;
  if (hrTailBpm.isEmpty || end < 0 || end >= hrTailBpm.length) {
    return const Metric<HrRecovery>.absent(
      tier: Tier.estimate,
      inputs_used: inputs,
      note: 'no HR tail for HRR',
    );
  }
  // Peak HR over the window ending at exercise end (valid samples only).
  final peakLo = (end - peakWindowSec).clamp(0, hrTailBpm.length - 1);
  double peak = 0;
  for (var i = peakLo; i <= end; i++) {
    final h = hrTailBpm[i];
    if (h > peak) peak = h.toDouble();
  }
  // Recovery HR: median of a ±3 s window around end + recoverySec.
  final target = end + recoverySec;
  final lo = (target - 3).clamp(0, hrTailBpm.length - 1);
  final hi = (target + 3).clamp(0, hrTailBpm.length - 1);
  if (hi >= hrTailBpm.length || target >= hrTailBpm.length) {
    return const Metric<HrRecovery>.absent(
      tier: Tier.estimate,
      inputs_used: inputs,
      note: 'HR tail too short to reach +${60}s recovery point',
    );
  }
  final recWin = [
    for (var i = lo; i <= hi; i++)
      if (hrTailBpm[i] > 0) hrTailBpm[i].toDouble()
  ];
  if (peak <= 0 || recWin.isEmpty) {
    return const Metric<HrRecovery>.absent(
      tier: Tier.estimate,
      inputs_used: inputs,
      note: 'off-skin or missing HR around the recovery point',
    );
  }
  final hrAt60 = median(recWin)!;
  final drop = peak - hrAt60;
  if (drop <= 0) {
    return const Metric<HrRecovery>.absent(
      tier: Tier.estimate,
      inputs_used: inputs,
      note: 'HR did not descend after exercise end — likely still active',
    );
  }
  final pct = peak > 0 ? 100.0 * drop / peak : 0.0;
  // Confidence: a clearly descending tail from a high peak is more trustworthy.
  final conf = clamp(drop / 30.0, 0.3, 0.9);
  return Metric<HrRecovery>(
    value: HrRecovery(
      peakHr: peak,
      hrAt60s: hrAt60,
      dropBpm: drop,
      dropPct: pct,
    ),
    confidence: conf,
    tier: Tier.estimate,
    inputs_used: inputs,
    note: 'HRR-${recoverySec}s = peak − HR@+${recoverySec}s. Higher = faster '
        'parasympathetic reactivation (fitter). PRV not ECG.',
  );
}
