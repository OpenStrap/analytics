// CLINICAL TIER-1 — time-domain HRV (PRV).
//
// Task Force 1996 conventions: RMSSD, SDNN, SDANN, pNN50, computed on the
// CLEANED NN series (run correctRr first). Window conventions:
//   ultra-short  : < 5 min   (RMSSD only, with caution)
//   short        : 5 min
//   24-h         : SDANN / SDNN-index use 5-min segment means / SDs.
//
// HONESTY: this is PRV (pulse-rate variability), not ECG HRV. RMSSD and pNNx
// are the metrics most biased by the 1 Hz beat-time quantization (successive-
// difference inflation) — flagged in `note`. Lead with SDNN / SDANN.

import 'dart:math' as math;
import '../types.dart';
import '../util.dart';

class HrvTime {
  final double? rmssd; // ms
  final double? sdnn; // ms
  final double? sdann; // ms (24-h: SD of 5-min means)
  final double? sdnnIndex; // ms (24-h: mean of 5-min SDs)
  final double? pnn50; // %
  final int nBeats;
  const HrvTime({
    this.rmssd,
    this.sdnn,
    this.sdann,
    this.sdnnIndex,
    this.pnn50,
    required this.nBeats,
  });
  Map<String, dynamic> toJson() => {
        if (rmssd != null) 'rmssd_ms': round6(rmssd!),
        if (sdnn != null) 'sdnn_ms': round6(sdnn!),
        if (sdann != null) 'sdann_ms': round6(sdann!),
        if (sdnnIndex != null) 'sdnn_index_ms': round6(sdnnIndex!),
        if (pnn50 != null) 'pnn50_pct': round6(pnn50!),
        'n_beats': nBeats,
      };
}

/// Short-window time-domain HRV on a cleaned NN series (ms).
///
/// [nnMs] cleaned NN intervals. [nnTimesMs] beat times for SDANN/SDNN-index
/// segmentation (optional; if absent, SDANN/SDNN-index are null). Returns an
/// absent Metric when there are too few beats.
Metric<HrvTime> hrvTime(List<double> nnMs, {List<double>? nnTimesMs}) {
  const inputs = ['rr_cleaned'];
  if (nnMs.length < 2) {
    return const Metric<HrvTime>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'too few NN intervals',
    );
  }

  // RMSSD: root mean square of successive differences.
  var ssd = 0.0;
  var nn50 = 0;
  for (var i = 1; i < nnMs.length; i++) {
    final d = nnMs[i] - nnMs[i - 1];
    ssd += d * d;
    if (d.abs() > 50) nn50++;
  }
  final rmssd = math.sqrt(ssd / (nnMs.length - 1));
  final pnn50 = 100.0 * nn50 / (nnMs.length - 1);
  final sdnn = stddev(nnMs);

  double? sdann, sdnnIndex;
  if (nnTimesMs != null && nnTimesMs.length == nnMs.length) {
    final seg = _fiveMinSegments(nnMs, nnTimesMs);
    if (seg.length >= 2) {
      final means = [for (final s in seg) mean(s)!];
      sdann = stddev(means);
      final sds = [for (final s in seg) stddev(s)].whereType<double>().toList();
      sdnnIndex = sds.isEmpty ? null : mean(sds);
    }
  }

  // Confidence scales with beat count (ultra-short reads are less reliable).
  final conf = clamp(nnMs.length / 250.0, 0.3, 0.95); // ~250 beats ≈ 5 min
  return Metric<HrvTime>(
    value: HrvTime(
      rmssd: rmssd,
      sdnn: sdnn,
      sdann: sdann,
      sdnnIndex: sdnnIndex,
      pnn50: pnn50,
      nBeats: nnMs.length,
    ),
    confidence: conf,
    tier: Tier.high,
    inputs_used: inputs,
    note: 'PRV not ECG-HRV; RMSSD/pNN50 are quantization-sensitive at 1 Hz '
        '— lead with SDNN/SDANN',
  );
}

/// Robust NOCTURNAL RMSSD (ms).
///
/// A single whole-night RMSSD is dominated by the few high-Δ segments produced
/// by REM bursts, arousals and stage transitions, inflating it well above the
/// resting parasympathetic level (~tens of ms). Instead we compute RMSSD WITHIN
/// each consecutive ~5-min window of the NN series and take the MEDIAN across
/// windows — a robust estimator far less sensitive to a handful of high-variance
/// windows. Optionally restrict to NREM / low-motion windows via [stageMaskPerSec].
///
/// [nnMs] cleaned NN intervals. [nnTimesMs] beat times (ms, same length) used to
/// window into 5-min bins; required (returns absent without it). [windowMs] bin
/// width (default 300 000 = 5 min). [minBeatsPerWindow] min NN diffs a window
/// needs to contribute (default 5). [stageMaskPerSec] OPTIONAL per-second mask
/// (true = keep, e.g. NREM & immobile); a window is kept only when the mask is
/// true at the window's MIDPOINT second.
///
/// Returns a Metric whose value is the median-of-windows RMSSD (ms). Keeps the
/// PRV-not-ECG honesty note. Absent when there are too few usable windows.
Metric<double> nocturnalRmssd(
  List<double> nnMs,
  List<double> nnTimesMs, {
  double windowMs = 300000.0,
  int minBeatsPerWindow = 5,
  List<bool>? stageMaskPerSec,
}) {
  const inputs = ['rr_cleaned', 'beat_times'];
  if (nnMs.length != nnTimesMs.length || nnMs.length < minBeatsPerWindow + 1) {
    return const Metric<double>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'too few NN intervals for windowed nocturnal RMSSD',
    );
  }
  final t0 = nnTimesMs.first;
  // Bucket NN values by window index, carrying each window's time span so we can
  // mask it (the successive difference uses consecutive NN within the window).
  final buckets = <int, List<double>>{};
  for (var i = 0; i < nnMs.length; i++) {
    final idx = ((nnTimesMs[i] - t0) / windowMs).floor();
    (buckets[idx] ??= <double>[]).add(nnMs[i]);
  }
  // Compute per-window RMSSD over the windows we keep.
  final rmssds = <double>[];
  final indices = buckets.keys.toList()..sort();
  for (final idx in indices) {
    if (stageMaskPerSec != null) {
      final midSec = ((idx + 0.5) * windowMs / 1000.0).floor();
      final keep = midSec >= 0 &&
          midSec < stageMaskPerSec.length &&
          stageMaskPerSec[midSec];
      if (!keep) continue;
    }
    final seg = buckets[idx]!;
    if (seg.length < minBeatsPerWindow + 1) continue;
    var ssd = 0.0;
    for (var i = 1; i < seg.length; i++) {
      final d = seg[i] - seg[i - 1];
      ssd += d * d;
    }
    rmssds.add(math.sqrt(ssd / (seg.length - 1)));
  }
  if (rmssds.isEmpty) {
    return const Metric<double>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'no usable 5-min windows for nocturnal RMSSD',
    );
  }
  final robust = median(rmssds)!;
  // Confidence scales with how many windows we could median over.
  final conf = clamp(rmssds.length / 12.0, 0.3, 0.95); // ~1 h ≈ 12 windows
  return Metric<double>(
    value: robust,
    confidence: conf,
    tier: Tier.high,
    inputs_used: inputs,
    note: 'robust nocturnal RMSSD = MEDIAN of ${rmssds.length} consecutive '
        '5-min-window RMSSDs (REM/arousal-robust). PRV not ECG-HRV; '
        'RMSSD is quantization-sensitive at 1 Hz.',
  );
}

/// Sleep-session nightly RMSSD (ms) as the arithmetic mean of cleaned
/// consecutive 5-minute window RMSSDs.
///
/// Split the detected sleep session into consecutive 5-minute windows, apply a
/// simple RR cleaner (range-filter [300, 2000] ms + Malik-style ectopic
/// rejection against a local median), compute RMSSD inside each valid window,
/// then return the ARITHMETIC MEAN across windows. This is intentionally
/// distinct from [nocturnalRmssd], which uses cleaned NN +
/// median-of-windows robustness.
///
/// [rrMs]/[rrTsMs] are the raw RR intervals and their beat-end epoch times in
/// milliseconds. [startSec]/[endSec] bound the chosen sleep session in epoch
/// seconds. The implementation is one-pass over the time-sorted RR stream:
/// beats are bucketed once by `(tsSec - startSec) ~/ windowSec`.
Metric<double> sleepSessionWindowedRmssd(
  List<double> rrMs,
  List<double> rrTsMs, {
  required int startSec,
  required int endSec,
  int windowSec = 300,
}) {
  const inputs = ['rr_sleep_window'];
  if (startSec <= 0 ||
      endSec <= startSec ||
      rrMs.isEmpty ||
      rrTsMs.isEmpty ||
      rrMs.length != rrTsMs.length) {
    return const Metric<double>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'invalid or empty RR session window',
    );
  }

  final buckets = <int, List<double>>{};
  for (var i = 0; i < rrMs.length; i++) {
    final tsSec = (rrTsMs[i] / 1000.0).round();
    if (tsSec < startSec || tsSec >= endSec) continue;
    final idx = ((tsSec - startSec) ~/ windowSec);
    (buckets[idx] ??= <double>[]).add(rrMs[i]);
  }

  if (buckets.isEmpty) {
    return const Metric<double>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'no RR beats inside the session window',
    );
  }

  final rmssds = <double>[];
  final indices = buckets.keys.toList()..sort();
  for (final idx in indices) {
    final cleaned = _cleanWindowRr(buckets[idx]!);
    if (cleaned.length < 2) continue;
    final rmssd = _rmssdRaw(cleaned);
    if (rmssd != null) rmssds.add(rmssd);
  }

  if (rmssds.isEmpty) {
    return const Metric<double>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'no valid 5-min windows for sleep-session RMSSD',
    );
  }

  final meanRmssd = mean(rmssds)!;
  final conf = clamp(rmssds.length / 12.0, 0.3, 0.95);
  return Metric<double>(
    value: meanRmssd,
    confidence: conf,
    tier: Tier.high,
    inputs_used: inputs,
    note: 'sleep-session HRV: mean RMSSD over cleaned 5-min windows.',
  );
}

/// Group NN intervals into consecutive 5-minute (300 000 ms) segments by beat
/// time. Segments with <2 beats are dropped.
List<List<double>> _fiveMinSegments(List<double> nn, List<double> times) {
  const segMs = 300000.0;
  final out = <List<double>>[];
  if (nn.isEmpty) return out;
  final t0 = times.first;
  var curIdx = 0;
  var cur = <double>[];
  for (var i = 0; i < nn.length; i++) {
    final idx = ((times[i] - t0) / segMs).floor();
    if (idx != curIdx) {
      if (cur.length >= 2) out.add(cur);
      cur = <double>[];
      curIdx = idx;
    }
    cur.add(nn[i]);
  }
  if (cur.length >= 2) out.add(cur);
  return out;
}

List<double> _cleanWindowRr(List<double> rr) =>
    _rejectWindowEctopic([for (final v in rr) if (v >= 300 && v <= 2000) v]);

List<double> _rejectWindowEctopic(List<double> nn) {
  const radius = 2;
  const threshold = 0.20;
  if (nn.length <= radius) return nn;
  final kept = <double>[];
  for (var i = 0; i < nn.length; i++) {
    final lo = math.max(0, i - radius);
    final hi = math.min(nn.length - 1, i + radius);
    final neighbors = <double>[];
    for (var j = lo; j <= hi; j++) {
      if (j != i) neighbors.add(nn[j]);
    }
    if (neighbors.length < 2) {
      kept.add(nn[i]);
      continue;
    }
    final med = median(neighbors);
    if (med == null || med <= 0) {
      kept.add(nn[i]);
      continue;
    }
    final deviation = (nn[i] - med).abs() / med;
    if (deviation <= threshold) kept.add(nn[i]);
  }
  return kept;
}

double? _rmssdRaw(List<double> nn) {
  if (nn.length < 2) return null;
  var sumSq = 0.0;
  for (var i = 1; i < nn.length; i++) {
    final d = nn[i] - nn[i - 1];
    sumSq += d * d;
  }
  return math.sqrt(sumSq / (nn.length - 1));
}
