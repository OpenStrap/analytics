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

import 'dart:math' as math;

import '../types.dart';
import '../util.dart';

class HrRecovery {
  final double peakHr; // bpm at/near exercise end
  final double hrAt60s; // bpm 60 s later
  final double dropBpm; // peakHr - hrAt60s (≥0)
  final double dropPct; // drop as % of peak

  /// Time constant (s) of a single exponential fitted to the 0–[tauWindowSec]
  /// recovery tail: `hr(t) = asymptote + amp·exp(−t/tau)`. Null whenever the
  /// fit did not clear its gates — see [tauAbsenceReason], which is the usual
  /// outcome and is meant to be.
  ///
  /// IT PUBLISHES ALONGSIDE [dropBpm], NEVER INSTEAD OF IT. And it is NOT
  /// intensity-invariant: HR recovery is biphasic and the fast-phase constant
  /// is itself intensity-dependent, so one exponential over 0–180 s conflates
  /// the two phases. Compare a tau only against other taus that started from a
  /// similar [tauStartHr] — which is why that number ships with it and is not
  /// optional on any surface that shows tau.
  final double? tauSec;

  /// Fitted HR at t = 0 (`asymptote + amp`), i.e. the intensity this recovery
  /// started from. Null when [tauSec] is.
  final double? tauStartHr;

  /// Fitted amplitude (bpm) — how far the exponential falls in total.
  final double? tauAmpBpm;

  /// Fitted asymptote (bpm) the curve settles toward.
  final double? tauAsymptoteBpm;

  /// Fit RMSE as a FRACTION of [tauAmpBpm]. Dimensionless on purpose: a bpm
  /// threshold would be a per-strap constant with nothing behind it, while
  /// "the residual is under 15 % of the swing being fitted" means the same
  /// thing on any sensor. Null when [tauSec] is.
  final double? tauResidualRatio;

  /// Machine-readable reason the tau fit abstained, or null when it did not.
  final String? tauAbsenceReason;
  const HrRecovery({
    required this.peakHr,
    required this.hrAt60s,
    required this.dropBpm,
    required this.dropPct,
    this.tauSec,
    this.tauStartHr,
    this.tauAmpBpm,
    this.tauAsymptoteBpm,
    this.tauResidualRatio,
    this.tauAbsenceReason,
  });
  Map<String, dynamic> toJson() => {
        'peak_hr': round6(peakHr),
        'hr_at_60s': round6(hrAt60s),
        'drop_bpm': round6(dropBpm),
        'drop_pct': round6(dropPct),
        'tau_sec': tauSec == null ? null : round6(tauSec!),
        'tau_start_hr': tauStartHr == null ? null : round6(tauStartHr!),
        'tau_amp_bpm': tauAmpBpm == null ? null : round6(tauAmpBpm!),
        'tau_asymptote_bpm':
            tauAsymptoteBpm == null ? null : round6(tauAsymptoteBpm!),
        'tau_residual_ratio':
            tauResidualRatio == null ? null : round6(tauResidualRatio!),
        if (tauAbsenceReason != null) 'tau_absence_reason': tauAbsenceReason,
      };
}

/// Grid-search a single-exponential recovery `hr(t) = a + b·exp(−t/tau)` over
/// the post-exercise tail, and REFUSE unless the fit is clean.
///
/// [tSec] seconds since exercise end (0 at end, ascending), [hr] bpm, both
/// already filtered to valid samples. For each candidate tau the basis
/// `exp(−t/tau)` is fixed, so a and b fall out of a two-parameter least
/// squares in closed form — no iteration, no optimiser, no dependency.
///
/// The gates exist because most bouts will not survive them, which is the
/// correct outcome: a walk-home cooldown, a stop that was not really a stop,
/// or a sparse tail all produce a number this fit would happily print.
({
  double tau,
  double amp,
  double asymptote,
  double residualRatio,
})? _fitTau(
  List<double> tSec,
  List<double> hr, {
  required double minTau,
  required double maxTau,
  required double maxResidualRatio,
}) {
  final m = tSec.length;
  if (m < 30) return null;
  double? bestSse;
  double bestTau = 0, bestA = 0, bestB = 0;
  for (var tau = minTau; tau <= maxTau; tau += 1.0) {
    var se = 0.0, see = 0.0, sy = 0.0, sey = 0.0;
    for (var i = 0; i < m; i++) {
      final e = math.exp(-tSec[i] / tau);
      se += e;
      see += e * e;
      sy += hr[i];
      sey += e * hr[i];
    }
    final den = m * see - se * se;
    if (den.abs() < 1e-12) continue;
    final b = (m * sey - se * sy) / den;
    final a = (sy - b * se) / m;
    var sse = 0.0;
    for (var i = 0; i < m; i++) {
      final r = hr[i] - (a + b * math.exp(-tSec[i] / tau));
      sse += r * r;
    }
    if (bestSse == null || sse < bestSse) {
      bestSse = sse;
      bestTau = tau;
      bestA = a;
      bestB = b;
    }
  }
  if (bestSse == null) return null;
  // Must actually decay. A negative amplitude is HR still climbing — a stop
  // that was not a stop.
  if (bestB <= 0) return null;
  // A tau pinned to either end of the grid is not an estimate, it is the grid
  // boundary: the tail did not constrain it.
  if (bestTau <= minTau || bestTau >= maxTau) return null;
  final ratio = math.sqrt(bestSse / m) / bestB;
  if (!ratio.isFinite || ratio > maxResidualRatio) return null;
  return (
    tau: bestTau,
    amp: bestB,
    asymptote: bestA,
    residualRatio: ratio,
  );
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
/// Without them EVERY window here is really ARRAY POSITIONS: the substrate this
/// is sliced from is one row per decoded record, not a dense 1 Hz grid, so on a
/// gappy tail the "HR at +60 s" sample can be many minutes post-exercise and
/// `hrr_bpm` is overstated — read by the user as a fitness marker. With [tsSec]
/// ALL THREE windows are resolved on the clock: the peak window before end, the
/// recovery point, and the ±3 s median around it. Supplying [tsSec] used to
/// convert only the recovery point, leaving the peak window positional — a
/// 30-position window on a 20 s-spaced tail spanned 580 s of clock, so "peak at
/// exercise end" came from nine minutes earlier and inflated the drop by 28 bpm
/// while ALSO collecting the +0.2 timestamped-confidence bonus.
///
/// [maxGapSec] bounds a hole in either direction. A gap inside the peak window
/// is not fatal — the window simply stops there — but it does forfeit the
/// timestamped bonus, because the peak is then measured over less clock time
/// than was asked for.
/// [tauWindowSec] is the tail the exponential is fitted over (CV-08). The
/// caller has to actually SLICE that much substrate — with a −30/+75 s tail
/// there is nothing to fit and tau abstains with a reason, which is honest but
/// useless.
Metric<HrRecovery> hrRecovery(
  List<int> hrTailBpm, {
  int? endIndex,
  int recoverySec = 60,
  int peakWindowSec = 30,
  List<int>? tsSec,
  int maxGapSec = 30,
  int tauWindowSec = 180,
  double tauMaxResidualRatio = 0.15,
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
  final times =
      (tsSec != null && tsSec.length == hrTailBpm.length) ? tsSec : null;
  // Peak HR over the window ending at exercise end (valid samples only).
  // With timestamps the window is peakWindowSec of CLOCK TIME walked backwards
  // from end, stopping at a hole; without them it is peakWindowSec positions,
  // which is all the caller has given us to go on.
  int peakLo;
  var peakWindowFull = true;
  if (times != null) {
    var i = end;
    while (i > 0 &&
        times[end] - times[i - 1] <= peakWindowSec &&
        times[i] - times[i - 1] <= maxGapSec) {
      i--;
    }
    peakLo = i;
    // "Full" = the window covers the requested clock span, OR it was cut short
    // by the start of the caller's slice rather than by the DATA. Stopping at
    // peakLo > 0 with a short span means the samples themselves are too far
    // apart (or a hole intervened) to resolve the window — that is the case
    // that forfeits the timestamped confidence bonus below.
    peakWindowFull = peakLo == 0 || times[end] - times[peakLo] >= peakWindowSec;
  } else {
    peakLo = (end - peakWindowSec).clamp(0, hrTailBpm.length - 1);
  }
  double peak = 0;
  for (var i = peakLo; i <= end; i++) {
    final h = hrTailBpm[i];
    if (h > peak) peak = h.toDouble();
  }
  // Recovery HR: median of a ±3 s window around end + recoverySec.
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
  if (target >= hrTailBpm.length) {
    return Metric<HrRecovery>.absent(
      tier: Tier.estimate,
      inputs_used: inputs,
      note: 'HR tail too short to reach +${recoverySec}s recovery point',
    );
  }
  // The ±3 s median window, on the clock when we have one. Positionally it was
  // ±3 ROWS, which on a sparse tail averages HR from minutes apart.
  int lo, hi;
  if (times != null) {
    lo = target;
    while (lo > 0 && times[target] - times[lo - 1] <= 3) {
      lo--;
    }
    hi = target;
    while (hi + 1 < times.length && times[hi + 1] - times[target] <= 3) {
      hi++;
    }
  } else {
    lo = (target - 3).clamp(0, hrTailBpm.length - 1);
    hi = (target + 3).clamp(0, hrTailBpm.length - 1);
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
  // `(drop / 30).clamp(0.3, 0.9)` — confidence derived from the metric's own
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
  // we have no way to know the recovery sample is really 60 s later. A
  // timestamped tail too sparse to fill the peak window doesn't earn it either
  // — the timestamps proved the window was short rather than fixing it.
  final conf =
      (0.3 + 0.4 * validFrac + (times != null && peakWindowFull ? 0.2 : 0.0))
          .clamp(0.2, 0.9);

  // TAU (CV-08). Same tail, same slice, no second pass over the substrate.
  // Timestamps are REQUIRED: a time constant fitted to array positions of
  // unknown spacing is a number in seconds that was never measured in seconds.
  String? tauWhy;
  ({double tau, double amp, double asymptote, double residualRatio})? fit;
  if (times == null) {
    tauWhy = 'tau_needs_timestamps';
  } else {
    final t0 = times[end];
    final tt = <double>[];
    final yy = <double>[];
    for (var i = end; i < times.length; i++) {
      if (i > end && times[i] - times[i - 1] > maxGapSec) break;
      final dt = times[i] - t0;
      if (dt > tauWindowSec) break;
      if (hrTailBpm[i] <= 0) continue;
      tt.add(dt.toDouble());
      yy.add(hrTailBpm[i].toDouble());
    }
    // Half the window, on the clock, or there is not enough curve to separate
    // the decay from the asymptote.
    if (tt.isEmpty || tt.last < tauWindowSec / 2) {
      tauWhy = 'tau_tail_short:span=${tt.isEmpty ? 0 : tt.last.round()}s';
    } else {
      fit = _fitTau(
        tt,
        yy,
        minTau: 5,
        maxTau: 200,
        maxResidualRatio: tauMaxResidualRatio,
      );
      if (fit == null) tauWhy = 'tau_fit_rejected';
    }
  }

  return Metric<HrRecovery>(
    value: HrRecovery(
      peakHr: peak,
      hrAt60s: hrAt60,
      dropBpm: drop,
      dropPct: pct,
      tauSec: fit?.tau,
      tauStartHr: fit == null ? null : fit.asymptote + fit.amp,
      tauAmpBpm: fit?.amp,
      tauAsymptoteBpm: fit?.asymptote,
      tauResidualRatio: fit?.residualRatio,
      tauAbsenceReason: tauWhy,
    ),
    confidence: conf,
    tier: Tier.estimate,
    inputs_used: inputs,
    note: 'HRR-${recoverySec}s = peak − HR@+${recoverySec}s. Higher = faster '
        'parasympathetic reactivation (fitter). PRV not ECG.',
  );
}
