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
///
/// [tsSec] OPTIONAL unix-second timestamps parallel to [hrTailBpm]. SUPPLY THEM.
/// Without them "+60 s" is really "+60 ARRAY POSITIONS": the substrate this is
/// sliced from is one row per decoded record, not a dense 1 Hz grid, so on a
/// gappy tail the "HR at +60 s" sample can be many minutes post-exercise and
/// `hrr_bpm` is overstated — read by the user as a fitness marker. With [tsSec]
/// the recovery point is found by CLOCK TIME and the span is checked for holes.
Metric<HrRecovery> hrRecovery(
  List<int> hrTailBpm, {
  int? endIndex,
  int recoverySec = 60,
  int peakWindowSec = 30,
  List<int>? tsSec,
  int maxGapSec = 30,
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
  final times = (tsSec != null && tsSec.length == hrTailBpm.length) ? tsSec : null;
  int target;
  if (times != null) {
    // Locate the recovery point on the CLOCK, and refuse if the tail has a hole
    // in it between exercise end and there.
    final wantTs = times[end] + recoverySec;
    var t = -1;
    for (var i = end; i < times.length; i++) {
      if (i > end && times[i] - times[i - 1] > maxGapSec) break;
      if (times[i] >= wantTs) {
        t = i;
        break;
      }
    }
    if (t < 0) {
      return Metric<HrRecovery>.absent(
        tier: Tier.estimate,
        inputs_used: inputs,
        note: 'HR tail does not reach +${recoverySec}s without a gap — no HRR',
      );
    }
    target = t;
  } else {
    target = end + recoverySec;
  }
  final lo = (target - 3).clamp(0, hrTailBpm.length - 1);
  final hi = (target + 3).clamp(0, hrTailBpm.length - 1);
  if (target >= hrTailBpm.length) {
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
  // Confidence from DATA QUALITY, not from the answer. This used to be
  // `clamp(drop / 30, 0.3, 0.9)` — confidence derived from the metric's own
  // magnitude, so a motion-artifact spike inflated `peak`, inflated `drop`, and
  // RAISED the confidence: the least trustworthy readings scored highest.
  var seen = 0, valid = 0;
  for (var i = peakLo; i <= end; i++) {
    seen++;
    if (hrTailBpm[i] > 0) valid++;
  }
  for (var i = lo; i <= hi; i++) {
    seen++;
    if (hrTailBpm[i] > 0) valid++;
  }
  final validFrac = seen == 0 ? 0.0 : valid / seen;
  // Timestamped tails earn the top of the band; positional ones cannot, because
  // we have no way to know the recovery sample is really 60 s later.
  final conf =
      clamp(0.3 + 0.4 * validFrac + (times != null ? 0.2 : 0.0), 0.2, 0.9);
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
