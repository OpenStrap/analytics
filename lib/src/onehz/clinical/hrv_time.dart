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
//
// That warning used to be advice only: every RMSSD in this file shipped, at
// confidence 0.95, however much of it was beat-timing jitter. [kNnDiffAcf1Floor]
// makes it behaviour — see that constant for the measurement and the threshold.

import 'dart:math' as math;
import '../types.dart';
import '../util.dart';

/// Lag-1 ACF floor for the NN successive-difference series, below which RMSSD
/// and pNN50 are REFUSED (SDNN / SDANN survive it and are the honest lead).
///
/// Differencing a smooth tachogram leaves ACF1 near 0; differencing white noise
/// leaves exactly −0.5. So ACF1 measures, per night and from the series already
/// in hand, how much of the "variability" is beat-timing jitter rather than
/// physiology. It is deliberately the gate INSTEAD of a per-family constant
/// (`device.dart`): the sensor difference is real and large, but it reaches us
/// as something measurable, not as a label — a strap that starts reporting
/// cleaner beats is believed the night it does so, and an unknown strap is
/// judged on its own signal rather than refused for its badge.
///
/// MEASURED over the 13-night audit corpus: gen4 −0.057..−0.324,
/// MG −0.426..−0.456, WHOOP 5 −0.428..−0.517. −0.35 keeps every gen4 night and
/// refuses every gen5/MG night. OURS, not a published threshold — there is no
/// literature constant for this, and it is calibration, so it is a knob.
const double kNnDiffAcf1Floor = -0.35;

/// Fewest successive differences [nnDiffAcf1] will judge a series on. Below it
/// the ACF1 estimate is noisier than what it is meant to screen out, so it
/// returns null and NOTHING is gated — thin windows are already handled by the
/// beat-count term in confidence.
const int _acf1MinDiffs = 30;

/// Lag-1 autocorrelation of the successive-difference series, pooled over
/// CONTIGUOUS runs.
///
/// Each entry of [diffRuns] must be differences between beats that are adjacent
/// in time; a dropped run / sensor hole ends one run and starts the next, so no
/// lag-1 pair is ever formed across a seam. Null when there is too little to
/// judge or the series is constant.
double? nnDiffAcf1(List<List<double>> diffRuns) {
  var n = 0;
  var sum = 0.0;
  for (final r in diffRuns) {
    for (final d in r) {
      sum += d;
      n++;
    }
  }
  if (n < _acf1MinDiffs) return null;
  final m = sum / n;
  var cov = 0.0;
  var varSum = 0.0;
  for (final r in diffRuns) {
    for (var i = 0; i < r.length; i++) {
      final a = r[i] - m;
      varSum += a * a;
      if (i > 0) cov += (r[i - 1] - m) * a;
    }
  }
  return varSum > 0 ? cov / varSum : null;
}

/// Confidence multiplier for a measured [acf1]: 1.0 on a smooth tachogram,
/// falling linearly to 0 at [kNnDiffAcf1Floor] so confidence bottoms out
/// exactly where RMSSD is refused. 1.0 when ACF1 could not be measured.
double _acf1Quality(double? acf1) =>
    acf1 == null ? 1.0 : (1 - acf1 / kNnDiffAcf1Floor).clamp(0.0, 1.0);

String _jitterNote(double acf1) =>
    'rmssd_refused:acf1=${acf1.toStringAsFixed(3)} — the NN successive '
    'differences are essentially differenced white noise (−0.5 = pure, floor '
    '$kNnDiffAcf1Floor), so RMSSD/pNN50 would measure beat-timing jitter, not '
    'vagal tone';

class HrvTime {
  final double? rmssd; // ms
  final double? sdnn; // ms
  final double? sdann; // ms (24-h: SD of 5-min means)
  final double? sdnnIndex; // ms (24-h: mean of 5-min SDs)
  final double? pnn50; // %
  final int nBeats;
  final double? diffAcf1; // lag-1 ACF of the NN successive differences
  const HrvTime({
    this.rmssd,
    this.sdnn,
    this.sdann,
    this.sdnnIndex,
    this.pnn50,
    required this.nBeats,
    this.diffAcf1,
  });
  Map<String, dynamic> toJson() => {
        if (rmssd != null) 'rmssd_ms': round6(rmssd!),
        if (sdnn != null) 'sdnn_ms': round6(sdnn!),
        if (sdann != null) 'sdann_ms': round6(sdann!),
        if (sdnnIndex != null) 'sdnn_index_ms': round6(sdnnIndex!),
        if (pnn50 != null) 'pnn50_pct': round6(pnn50!),
        'n_beats': nBeats,
        if (diffAcf1 != null) 'diff_acf1': round6(diffAcf1!),
      };
}

/// Short-window time-domain HRV on a cleaned NN series (ms).
///
/// [nnMs] cleaned NN intervals. [nnTimesMs] beat times, used both for
/// SDANN/SDNN-index segmentation and to skip successive-difference pairs that
/// straddle a dropped run (optional; without it SDANN/SDNN-index are null and
/// RMSSD/pNN50 include the seams). [artifactFraction] is the fraction of beats
/// the upstream corrector rejected (0..1), folded into confidence exactly as
/// `hrvFreq` and `irregularBeatScreen` already do. Returns an absent Metric when
/// there are too few beats; RMSSD/pNN50 alone go null when the successive
/// differences fail [kNnDiffAcf1Floor].
Metric<HrvTime> hrvTime(
  List<double> nnMs, {
  List<double>? nnTimesMs,
  double artifactFraction = 0.0,
}) {
  const inputs = ['rr_cleaned'];
  if (nnMs.length < 2) {
    return const Metric<HrvTime>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'too few NN intervals',
    );
  }

  // RMSSD / pNN50: root mean square of SUCCESSIVE differences — successive in
  // TIME, not merely adjacent in the compacted list. correctRr drops multi-beat
  // artifact runs while advancing its clock across them, so nn[i-1] and nn[i]
  // can sit either side of a seconds-long hole; differencing straight down the
  // list manufactured one large difference per dropped run. Same `keep`-mask
  // treatment irregular_rhythm.dart already applies. A pair is contiguous iff
  // the elapsed time between the two beat times is the interval itself.
  //
  // The differences are kept as contiguous RUNS (a seam ends a run) so the same
  // pass feeds [nnDiffAcf1] without ever forming a lag-1 pair across a hole.
  final gapAware = nnTimesMs != null && nnTimesMs.length == nnMs.length;
  final runs = <List<double>>[];
  var run = <double>[];
  for (var i = 1; i < nnMs.length; i++) {
    if (gapAware && nnTimesMs[i] - nnTimesMs[i - 1] > nnMs[i] + 0.5) {
      if (run.isNotEmpty) {
        runs.add(run);
        run = <double>[];
      }
      continue;
    }
    run.add(nnMs[i] - nnMs[i - 1]);
  }
  if (run.isNotEmpty) runs.add(run);

  var ssd = 0.0;
  var nn50 = 0;
  var pairs = 0;
  for (final r in runs) {
    for (final d in r) {
      ssd += d * d;
      if (d.abs() > 50) nn50++;
      pairs++;
    }
  }
  // RMSSD and pNN50 are the two outputs made of successive differences, so they
  // are the two the jitter floor refuses. SDNN/SDANN are made of the levels and
  // are far less contaminated (jitter share 1–27 % against RMSSD's 11–100 % on
  // the audit corpus) — they keep publishing, which is what the header has
  // always advised.
  final acf1 = nnDiffAcf1(runs);
  final jittery = acf1 != null && acf1 < kNnDiffAcf1Floor;
  final rmssd = (pairs > 0 && !jittery) ? math.sqrt(ssd / pairs) : null;
  final pnn50 = (pairs > 0 && !jittery) ? 100.0 * nn50 / pairs : null;
  final sdnn = stddev(nnMs);

  double? sdann, sdnnIndex;
  if (gapAware) {
    final seg = _fiveMinSegments(nnMs, nnTimesMs);
    if (seg.length >= 2) {
      final means = [for (final s in seg) mean(s)!];
      sdann = stddev(means);
      final sds = [for (final s in seg) stddev(s)].whereType<double>().toList();
      sdnnIndex = sds.isEmpty ? null : mean(sds);
    }
  }

  // Confidence scales with beat count (ultra-short reads are less reliable),
  // with the artifact fraction we were handed, and with the measured jitter
  // level. It used to be beat count alone, which published 0.95 on all 13 nights
  // of the audit corpus — including a 15.3 %-artifact night whose differences
  // were ~pure noise. The beat-count term is capped BEFORE the quality terms
  // multiply it; multiplying first let an all-night beat count (n/250 ≈ 100)
  // swallow any penalty and re-clamp to 0.95 regardless.
  final conf = ((nnMs.length / 250.0).clamp(0.0, 1.0) // ~250 beats ≈ 5 min
        *
        _acf1Quality(acf1) *
        (1 - artifactFraction)).clamp(0.3, 0.95);
  return Metric<HrvTime>(
    value: HrvTime(
      rmssd: rmssd,
      sdnn: sdnn,
      sdann: sdann,
      sdnnIndex: sdnnIndex,
      pnn50: pnn50,
      nBeats: nnMs.length,
      diffAcf1: acf1,
    ),
    confidence: conf,
    tier: Tier.high,
    inputs_used: inputs,
    note: jittery
        ? '${_jitterNote(acf1)}. SDNN/SDANN survive it and are the lead here. '
            'PRV not ECG-HRV.'
        : 'PRV not ECG-HRV; RMSSD/pNN50 are quantization-sensitive at 1 Hz '
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
/// PRV-not-ECG honesty note. Absent when there are too few usable windows, or
/// when the night's successive differences fail [kNnDiffAcf1Floor]. A window
/// contributes only if it holds [minBeatsPerWindow] differences between beats
/// that are ADJACENT IN TIME, not merely adjacent in the compacted NN list.
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
  // Bucket beat INDICES by window index, so each window keeps its beat times and
  // the successive differences below can skip the ones that straddle a dropped
  // run — the same seam rule `hrvTime` applies.
  final buckets = <int, List<int>>{};
  for (var i = 0; i < nnMs.length; i++) {
    final idx = ((nnTimesMs[i] - t0) / windowMs).floor();
    (buckets[idx] ??= <int>[]).add(i);
  }
  // Compute per-window RMSSD over the windows we keep. Each window's difference
  // series is also kept as one contiguous run for the jitter floor below.
  final rmssds = <double>[];
  // The jitter floor is judged over the WHOLE night, pooled across windows, not
  // per window: at 5 min a window holds a few hundred differences and its ACF1
  // is noisy enough that dropping only the windows that fail keeps the ones that
  // passed by luck — measured, that let WHOOP 5 publish 109-116 ms from its
  // calmest-looking windows while the night pooled to −0.43/−0.51.
  final runs = <List<double>>[];
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
    // Contiguous runs inside the window: a pair whose beat times are further
    // apart than the interval itself sits either side of a dropped run, and
    // differencing across it manufactures one large difference per hole.
    final winRuns = <List<double>>[];
    var run = <double>[];
    for (var k = 1; k < seg.length; k++) {
      final i = seg[k], p = seg[k - 1];
      if (nnTimesMs[i] - nnTimesMs[p] > nnMs[i] + 0.5) {
        if (run.isNotEmpty) {
          winRuns.add(run);
          run = <double>[];
        }
        continue;
      }
      run.add(nnMs[i] - nnMs[p]);
    }
    if (run.isNotEmpty) winRuns.add(run);
    var ssd = 0.0;
    var nd = 0;
    for (final r in winRuns) {
      for (final d in r) {
        ssd += d * d;
        nd++;
      }
    }
    if (nd < minBeatsPerWindow) continue;
    runs.addAll(winRuns);
    rmssds.add(math.sqrt(ssd / nd));
  }
  final acf1 = nnDiffAcf1(runs);
  if (acf1 != null && acf1 < kNnDiffAcf1Floor) {
    return Metric<double>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: _jitterNote(acf1),
    );
  }
  if (rmssds.isEmpty) {
    return const Metric<double>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'no usable 5-min windows for nocturnal RMSSD',
    );
  }
  final robust = median(rmssds)!;
  // Confidence scales with how many windows we could median over, and with the
  // measured jitter level (see [kNnDiffAcf1Floor]).
  final conf = ((rmssds.length / 12.0).clamp(0.0, 1.0) // 12 ≈ 1 h
          *
          _acf1Quality(acf1))
      .clamp(0.3, 0.95);
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
/// This is the nightly HEADLINE (→ `ln_rmssd` → readiness), so it refuses
/// rather than approximates: absent when the successive differences fail
/// [kNnDiffAcf1Floor].
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
  final runs = <List<double>>[]; // pooled jitter floor — see [nocturnalRmssd]
  final indices = buckets.keys.toList()..sort();
  for (final idx in indices) {
    final diffRuns = [
      for (final r in _cleanWindowRuns(buckets[idx]!))
        if (r.length >= 2) [for (var i = 1; i < r.length; i++) r[i] - r[i - 1]]
    ];
    var ssd = 0.0;
    var nd = 0;
    for (final r in diffRuns) {
      for (final d in r) {
        ssd += d * d;
        nd++;
      }
    }
    if (nd == 0) continue;
    runs.addAll(diffRuns);
    rmssds.add(math.sqrt(ssd / nd));
  }

  // THE HEADLINE nightly RMSSD (→ ln_rmssd → readiness). When the differences
  // are noise, the honest output is no headline, not a plausible one — the
  // readiness composite already treats a null HRV driver as absent.
  final acf1 = nnDiffAcf1(runs);
  if (acf1 != null && acf1 < kNnDiffAcf1Floor) {
    return Metric<double>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: _jitterNote(acf1),
    );
  }
  if (rmssds.isEmpty) {
    return const Metric<double>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'no valid 5-min windows for sleep-session RMSSD',
    );
  }

  final meanRmssd = mean(rmssds)!;
  final conf = ((rmssds.length / 12.0).clamp(0.0, 1.0) * _acf1Quality(acf1)).clamp(0.3, 0.95);
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

/// Range-filter [300, 2000] ms + Malik-style ectopic rejection against a local
/// median, returned as CONTIGUOUS RUNS of kept intervals.
///
/// Runs, not one compacted list: differencing straight down a compacted list
/// manufactures exactly one difference per rejected beat, spanning it — the same
/// defect `hrvTime` refuses at dropped runs and `irregularBeatScreen` refuses
/// with its keep-mask. This was the last producer in the file still doing it,
/// and it is the one feeding the nightly headline. MEASURED over the 13-night
/// audit corpus: it inflated the headline by 2–13 % on gen4 (57.2 → 52.3 ms at
/// worst) and by 51–102 % on MG (87.7 → 58.2, 82.9 → 40.9, 76.9 → 40.2 ms) —
/// i.e. most of the "gen5 reads 2× gen4" gap was this, not physiology.
List<List<double>> _cleanWindowRuns(List<double> rr) {
  const radius = 2;
  const threshold = 0.20;
  // Range filter first, keeping each survivor's position in [rr] — BOTH filters
  // break a run, so neither one's compaction can manufacture a difference.
  final nn = <double>[];
  final at = <int>[];
  for (var i = 0; i < rr.length; i++) {
    if (rr[i] >= 300 && rr[i] <= 2000) {
      nn.add(rr[i]);
      at.add(i);
    }
  }
  final runs = <List<double>>[];
  var run = <double>[];
  var lastKept = -2;
  for (var i = 0; i < nn.length; i++) {
    var keep = true;
    if (nn.length > radius) {
      final lo = math.max(0, i - radius);
      final hi = math.min(nn.length - 1, i + radius);
      final neighbors = <double>[];
      for (var j = lo; j <= hi; j++) {
        if (j != i) neighbors.add(nn[j]);
      }
      final med = neighbors.length < 2 ? null : median(neighbors);
      if (med != null && med > 0) keep = (nn[i] - med).abs() / med <= threshold;
    }
    if (!keep) {
      if (run.isNotEmpty) {
        runs.add(run);
        run = <double>[];
      }
      continue;
    }
    if (run.isNotEmpty && at[i] != lastKept + 1) {
      runs.add(run);
      run = <double>[];
    }
    run.add(nn[i]);
    lastKept = at[i];
  }
  if (run.isNotEmpty) runs.add(run);
  return runs;
}
