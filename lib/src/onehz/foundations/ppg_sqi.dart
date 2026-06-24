// FOUNDATION — PPG signal-quality gate.
//
// Elgendi 2016 skewness-SQI (the best single cheap PPG quality index; works on
// a short window of 1 Hz-or-faster samples) + Orphanidou 2015 physiological-
// range rules (plausible HR 40–180 bpm; plausible RR; not-too-variable HR).
//
// Template-matching SQI is foreground-only (needs the 419 Hz waveform) and is
// deliberately NOT implemented here — see the catalog. We expose only what a
// 1 Hz substrate honestly supports: a per-window TRUST flag.

import 'dart:math' as math;
import '../util.dart';

class SqiResult {
  final bool trusted;
  final double skewness; // Elgendi skewness-SQI of the window
  final List<String> reasons; // why it failed, if it did
  const SqiResult({
    required this.trusted,
    required this.skewness,
    required this.reasons,
  });
}

/// Skewness of a window. Positive skew correlates with good PPG (systolic
/// upstroke). Returns 0 for degenerate windows.
double skewnessSqi(List<double> window) {
  if (window.length < 3) return 0;
  final m = mean(window)!;
  final sd = stddevPop(window)!;
  if (sd == 0) return 0;
  var s = 0.0;
  for (final x in window) {
    final d = (x - m) / sd;
    s += d * d * d;
  }
  return s / window.length;
}

/// Per-window PPG trust gate.
///
/// [ppgWindow] raw green-ADC samples for the window (skewness-SQI input).
/// [hrBpm] the window's HR (bpm) for the physiological-range rule.
/// [skewMin] minimum acceptable skewness (Elgendi suggests >0 good quality).
SqiResult ppgTrust(
  List<double> ppgWindow,
  double hrBpm, {
  double skewMin = -0.1,
}) {
  final reasons = <String>[];
  final sk = skewnessSqi(ppgWindow);

  // Orphanidou physiological-range rules.
  if (hrBpm <= 0) {
    reasons.add('off-skin');
  } else if (hrBpm < 40 || hrBpm > 180) {
    reasons.add('hr-out-of-range');
  }
  if (ppgWindow.isEmpty) {
    reasons.add('no-ppg');
  } else if (sk < skewMin) {
    reasons.add('low-skewness');
  }
  // Flatline check (no perfusion variability).
  if (ppgWindow.isNotEmpty) {
    final sd = stddevPop(ppgWindow)!;
    final m = mean(ppgWindow)!.abs();
    if (sd == 0 || (m > 0 && sd / m < 1e-4)) reasons.add('flatline');
  }

  return SqiResult(trusted: reasons.isEmpty, skewness: sk, reasons: reasons);
}

/// Orphanidou physiological RR-range rule on a beat series (ms): every NN in
/// [300,2000] and no successive ratio > 3 (a missed/extra beat signature).
bool rrPhysiologicallyPlausible(List<double> rrMs) {
  if (rrMs.isEmpty) return false;
  for (var i = 0; i < rrMs.length; i++) {
    if (rrMs[i] < 300 || rrMs[i] > 2000) return false;
    if (i > 0) {
      final ratio =
          math.max(rrMs[i], rrMs[i - 1]) / math.min(rrMs[i], rrMs[i - 1]);
      if (ratio > 3) return false;
    }
  }
  return true;
}
