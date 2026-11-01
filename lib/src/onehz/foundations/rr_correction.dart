// Lipponen & Tarvainen 2019 classification with Peltola 2012 correction policy.
// The unpublished artifact-run cap is an internal rule, ESTIMATE with low
// confidence:
// over-cap runs become gaps and each side is re-corrected. Without a cap split
// the result equals uncapped correction. Shared kernel arithmetic and raw seam
// context preserve capped batch NN/classes; settled stream plus provisional tail
// equals capped batch. RrSandwich preserves source-beat absolute timestamps;
// uncapped arbitrarily long artifact runs have no exactness guarantee.
// FOUNDATION — RR artifact correction.
//
// Lipponen & Tarvainen 2019 ("A robust algorithm for heart rate variability
// time series artefact correction using novel beat classification", J Med Eng
// Technol) — the detector Kubios automates. Applies the dRR / mRR / sRR
// decision logic with a time-varying threshold derived from a quantile-based
// dispersion of dRR over a sliding window.
//
// Correction policy (Peltola 2012):
//   * cubic-spline interpolate ONLY isolated single ectopic/missed/extra beats;
//   * flag-and-drop multi-beat runs — never interpolate a run.
//
// This is PRV. Output = cleaned NN series + per-beat artifact mask + clean
// fraction. Multi-beat gaps are never silently bridged.

import 'rr_correction_kernel.dart';

/// Longest artifact run (beats) the corrector will carry. A longer run is not a
/// correction problem but an absence: it breaks the series into independent
/// segments and its beats are left out (a gap). 32 beats leaves no run on the
/// owner's 18 days of data over the cap (longest seen: 16) and bounds the
/// streaming state; see combined-bump/brief.md.
const int kMaxArtifactRun = 32;

/// Artifact label for a single beat.
enum BeatClass { normal, ectopic, longShort, missed, extra }

class RrCorrectionResult {
  /// Cleaned NN intervals (ms). Isolated artifacts spline-corrected; multi-beat
  /// runs dropped (length may differ from the input).
  final List<double> nn;

  /// Beat-time (ms) for each NN interval, relative to the START of the first
  /// input beat (so `nnTimesMs.first == rrMs.first` when the first beat is
  /// kept, and adding `rrTsMs.first - rrMs.first` puts it back on the epoch).
  ///
  /// Built by cumulative-summing RR *within a contiguous run*, and RE-ANCHORED
  /// to the beat's real timestamp at every sensor dropout — see [correctRr]'s
  /// `rrTsMs`. Without `rrTsMs` it is a pure cumsum and the dropouts are
  /// spliced out; pass the timestamps.
  final List<double> nnTimesMs;

  /// For each NN, the index of the input beat it came from: the beat itself,
  /// or, for a spline-corrected beat, that beat's own index. Strictly
  /// increasing; the input beats not listed here were dropped. Lets a caller
  /// pair each NN with that beat's own (absolute) timestamp. Empty on a
  /// hand-built result that did not track it.
  final List<int> nnSourceIndex;

  /// Per-input-beat classification (same length as the input rr).
  final List<BeatClass> classes;

  /// Fraction of input beats classified normal (0..1).
  final double cleanFraction;

  /// Count of beats dropped (part of a multi-beat run, not interpolated).
  final int droppedCount;

  /// Count of isolated beats that were spline-corrected.
  final int correctedCount;

  const RrCorrectionResult({
    required this.nn,
    required this.nnTimesMs,
    required this.classes,
    required this.cleanFraction,
    required this.droppedCount,
    required this.correctedCount,
    this.nnSourceIndex = const [],
  });
}

/// Lipponen–Tarvainen RR artifact correction.
///
/// [rrMs] the raw RR series (ms). [alpha] scales the time-varying threshold
/// (paper default 5.2 on the QD estimate). [windowBeats] sliding window for the
/// local dispersion estimate.
///
/// [rrTsMs] the beat timestamps that came with [rrMs] (same length, sorted,
/// epoch ms). PASS THEM. Without them the output clock is Σrr, which splices
/// every sensor dropout out of the record: the intervals the band never
/// reported are not in [rrMs] at all, so no amount of book-keeping inside this
/// function can recover them. Measured on 13 real nights, the cumsum span was
/// 0.13–0.87 of the true rec_ts span, and the Lomb-Scargle spectrum built on it
/// moved LF/HF across the sympatho-vagal line (0.65 → 1.53 on one MG night).
/// With them, the clock cumsums RR *inside* a contiguous run — the RR values
/// are the only sub-second information that exists, since `rr_ts_ms` is
/// `rec_ts*1000` and therefore whole-second — and re-anchors to the real
/// timestamp whenever the wall step exceeds the interval by more than
/// [reanchorGapMs], i.e. at a dropout.
///
/// [maxArtifactRun] caps a run of artifact beats: a longer run splits the series
/// (output = correctRr(before) ++ correctRr(after), times absolute, the run's
/// beats absent). null = uncapped, the pre-cap behaviour.
RrCorrectionResult correctRr(
  List<double> rrMs, {
  List<double>? rrTsMs,
  double alpha = 5.2,
  int windowBeats = 91,
  double minThresholdMs = 100,
  double reanchorGapMs = 1000,
  int? maxArtifactRun = kMaxArtifactRun,
}) {
  if (maxArtifactRun != null && maxArtifactRun < 1) {
    throw ArgumentError.value(maxArtifactRun, 'maxArtifactRun');
  }
  if (windowBeats < 1) throw ArgumentError.value(windowBeats, 'windowBeats');
  if (maxArtifactRun != null) {
    // The overwhelmingly common path has no run over the cap. Reuse the
    // original vectorized correction verbatim, including its clock, and only
    // evaluate split windows when a run actually requires a cut.
    var hardRun = 0, hardGap = false;
    for (final rr in rrMs) {
      hardRun = rr < 300 || rr > 2000 ? hardRun + 1 : 0;
      if (hardRun > maxArtifactRun) { hardGap = true; break; }
    }
    if (!hardGap) {
      final ordinary = correctRr(rrMs, rrTsMs: rrTsMs, alpha: alpha,
          windowBeats: windowBeats, minThresholdMs: minThresholdMs,
          reanchorGapMs: reanchorGapMs, maxArtifactRun: null);
      var run = 0, gap = false;
      for (final cls in ordinary.classes) {
        run = cls == BeatClass.normal ? 0 : run + 1;
        if (run > maxArtifactRun) { gap = true; break; }
      }
      if (!gap) return ordinary;
    }
    final w = RrCapWindow.evaluate(rrMs,
        ts: rrTsMs, cap: maxArtifactRun, alpha: alpha,
        windowBeats: windowBeats, minThresholdMs: minThresholdMs,
        reanchorGapMs: reanchorGapMs);
    final nn = <double>[], times = <double>[], source = <int>[];
    var normal = 0, dropped = 0, corrected = 0;
    for (var i = 0; i < rrMs.length; i++) {
      if (w.classes[i] == BeatClass.normal) normal++;
      final v = w.values[i];
      if (v == null) {
        dropped++;
      } else {
        nn.add(v);
        times.add(w.times[i]);
        source.add(i);
        if (w.classes[i] != BeatClass.normal) corrected++;
      }
    }
    return RrCorrectionResult(nn: nn, nnTimesMs: times, classes: w.classes,
        cleanFraction: rrMs.isEmpty ? 0 : normal / rrMs.length,
        droppedCount: dropped, correctedCount: corrected,
        nnSourceIndex: source);
  }
  final n = rrMs.length;
  // Beat-end time for EVERY input beat, kept or not. One array, built once, so
  // every branch below reads a clock instead of advancing its own.
  final tAll = _beatTimes(rrMs, rrTsMs, reanchorGapMs);
  if (n == 0) {
    return const RrCorrectionResult(
      nn: [],
      nnTimesMs: [],
      classes: [],
      cleanFraction: 0,
      droppedCount: 0,
      correctedCount: 0,
    );
  }
  if (n < 3) {
    // Too short to estimate dispersion: pass through physiologically-plausible
    // beats only, classify the rest as long/short. No fabrication.
    final classes = [
      for (final rr in rrMs)
        (rr >= 300 && rr <= 2000) ? BeatClass.normal : BeatClass.longShort
    ];
    final nn = <double>[];
    final times = <double>[];
    final source = <int>[];
    for (var i = 0; i < n; i++) {
      if (classes[i] == BeatClass.normal) {
        nn.add(rrMs[i]);
        times.add(tAll[i]);
        source.add(i);
      }
    }
    return RrCorrectionResult(
      nn: nn,
      nnTimesMs: times,
      classes: classes,
      cleanFraction: nn.length / n,
      droppedCount: n - nn.length,
      correctedCount: 0,
      nnSourceIndex: source,
    );
  }

  // dRR[i] = rr[i] - rr[i-1].
  final dRR = List<double>.filled(n, 0);
  for (var i = 1; i < n; i++) {
    dRR[i] = rrMs[i] - rrMs[i - 1];
  }

  // Time-varying threshold from a sliding quartile-deviation (QD) of dRR.
  // th1 ~ dispersion of dRR (short artifacts), th2 ~ dispersion of medianed RR.
  final th1 = _slidingThreshold(dRR, windowBeats, alpha, minThresholdMs);

  // medRR: rr minus local median (for missed/extra long-range tests).
  final med = _slidingMedian(rrMs, windowBeats);
  final mRR = List<double>.generate(n, (i) => medianDeviation(rrMs[i], med[i]));
  final th2 = _slidingThreshold(mRR, windowBeats, alpha, minThresholdMs);

  final classes = [
    for (var i = 0; i < n; i++)
      classifyBeat(rrMs[i], dRR[i], th1[i], med[i], mRR[i], th2[i])
  ];

  // Compensatory-pair reconciliation. A single ectopic/extra beat shows up as
  // TWO successive dRR spikes of opposite sign (the bad beat, then the
  // recovery). If beat i was flagged ONLY by the dRR jump (ectopic) but its
  // value is physiologically normal and close to the local median, while its
  // predecessor was a short/extra or long/missed event of opposite-sign dRR,
  // then i is just the recovery — demote it to normal so the event stays a
  // single isolated artifact rather than a spurious 2-beat run.
  for (var k = 1; k < n; k++) {
    if (classes[k] != BeatClass.ectopic) continue;
    final prevBad = classes[k - 1] != BeatClass.normal;
    if (isRecoveryBeat(
        prevIsArtifact: prevBad,
        rr: rrMs[k],
        dRR: dRR[k],
        dRRPrev: dRR[k - 1],
        med: med[k])) {
      classes[k] = BeatClass.normal;
    }
  }

  // Build cleaned NN. Isolated single artifact -> cubic-spline (Catmull-Rom on
  // the 4 surrounding NORMAL beats). A run of ≥2 consecutive artifacts -> drop.
  final isArtifact = [for (final c in classes) c != BeatClass.normal];
  final nn = <double>[];
  final times = <double>[];
  final source = <int>[];
  var dropped = 0;
  var corrected = 0;
  var i = 0;
  while (i < n) {
    if (!isArtifact[i]) {
      nn.add(rrMs[i]);
      times.add(tAll[i]);
      source.add(i);
      i++;
      continue;
    }
    // Measure run length.
    var j = i;
    while (j < n && isArtifact[j]) {
      j++;
    }
    final runLen = j - i;
    if (runLen == 1) {
      // Isolated -> spline-correct from surrounding normals.
      final corr = _splineCorrect(rrMs, isArtifact, i);
      if (corr != null) {
        // The beat keeps its REAL time, not the interpolated one. `corr` is our
        // best guess at what the NN *should* have been (a missed beat splits one
        // ~2000 ms interval into two ~1000 ms ones), but the 2000 ms still
        // elapsed. Advancing by `corr` deleted ~1 s of record per corrected beat
        // — 1.6 % of a night at one missed beat in sixty.
        nn.add(corr);
        times.add(tAll[i]);
        source.add(i);
        corrected++;
      } else {
        dropped++; // no anchors -> honest drop; the clock already elapsed
      }
    } else {
      // Multi-beat run: NEVER interpolate. The clock is not touched here at all
      // — `tAll` already carries the run's elapsed time, so the two sides of a
      // dropped run are not spliced together. Not doing this compacted
      // `nnTimesMs` (299.0 s of real record emitted as a 294.0 s span) and
      // inflated everything keyed off it: cvhr_per_hour's analyzedHours, the
      // Lomb-Scargle axis, spanSec — on exactly the noisy nights that needed
      // the correction most.
      dropped += runLen;
    }
    i = j;
  }

  final normalCount = classes.where((c) => c == BeatClass.normal).length;
  return RrCorrectionResult(
    nn: nn,
    nnTimesMs: times,
    classes: classes,
    cleanFraction: normalCount / n,
    droppedCount: dropped,
    correctedCount: corrected,
    nnSourceIndex: source,
  );
}

/// Beat-end time (ms, relative to the start of beat 0) for every input beat.
///
/// RR intervals tile the timeline, so the clock advances for EVERY interval,
/// kept or dropped — but only for intervals the band actually REPORTED. A
/// sensor dropout is not an interval at all: it is absent from [rrMs], and
/// summing across it splices the two sides of the hole together. [rrTsMs] is
/// the only witness that the hole existed, so when the wall step between two
/// consecutive reported beats exceeds that beat's own interval by more than
/// [reanchorGapMs], the clock is RE-ANCHORED to the real timestamp instead of
/// accumulated. Inside a contiguous run the RR cumsum is kept, because
/// `rr_ts_ms = rec_ts*1000` is whole-second and the RR values are the only
/// sub-second information in the record.
///
/// The slack has to be ≥ the max plausible RR (2,400 ms saturation) minus a
/// normal beat, or ordinary quantisation would re-anchor constantly; 1,000 ms
/// is the audit's figure and is ~1 whole quantisation step.
List<double> _beatTimes(
    List<double> rrMs, List<double>? rrTsMs, double reanchorGapMs) {
  final n = rrMs.length;
  final t = List<double>.filled(n, 0);
  if (n == 0) return t;
  final wall = rrTsMs != null && rrTsMs.length == n;
  final origin = wall ? rrTsMs[0] - rrMs[0] : 0.0;
  var cur = 0.0;
  for (var i = 0; i < n; i++) {
    // The test is LOCAL — this beat's wall step against this beat's own
    // interval — so a run's accumulated cumsum-vs-wall drift never triggers it.
    //
    // That drift is real and NOT resolved here. Inside contiguous runs of ≥200
    // beats, Σrr / rec_ts-span measures 0.9631 on gen4 against 0.9988 (W5) and
    // 1.0013 (MG). Which clock is wrong is not decidable from the exports: the
    // band's `hr` field is computed from the same beat detector as `rr_ms`, so
    // it is not independent evidence, and a low rate of beats the band never
    // reports produces the same deficit with a perfectly correct clock. So
    // there is deliberately no `rrClockScale` — applying 0.963 to gen4's RR
    // values would be actively wrong under that second explanation. The
    // consequence to carry: **gen4 and gen5/MG nights are not comparable on any
    // frequency-domain or per-hour quantity** until it is resolved.
    final dropout =
        wall && i > 0 && (rrTsMs[i] - rrTsMs[i - 1]) - rrMs[i] > reanchorGapMs;
    final anchored = wall ? rrTsMs[i] - origin : 0.0;
    // `> cur` keeps the clock monotonic even if timestamps arrive out of order
    // or the cumsum has run ahead of the wall — a backwards jump is never taken.
    cur = (dropout && anchored > cur) ? anchored : cur + rrMs[i];
    t[i] = cur;
  }
  return t;
}

/// Time-varying threshold: alpha × QD of the SIGNED series x in a sliding
/// window, where QD = (Q3 − Q1)/2 (Lipponen & Tarvainen 2019, eq. for th1/th2:
/// "th = α · quartile deviation of dRR over the 91-beat window", α = 5.2).
///
/// The quartile deviation MUST be taken on the SIGNED series. Taking it on |x|
/// folds the symmetric ±dRR distribution onto one side, collapsing QD by ~an
/// order of magnitude; the threshold then sinks to [floor] and the detector
/// degenerates into a fixed 100 ms cut-off that flags ordinary RSA as ectopy.
List<double> _slidingThreshold(
    List<double> x, int win, double alpha, double floor) {
  final n = x.length;
  final out = List<double>.filled(n, 0);
  final half = win ~/ 2;
  final w = _SortedWindow(x, half);
  for (var i = 0; i < n; i++) {
    w.advanceTo(i);
    out[i] = thresholdOfSorted(w.a, alpha, floor);
  }
  return out;
}

/// Median of the window around each beat EXCLUDING the beat itself (falls back
/// to the beat when the window holds nothing else). Same value as sorting the
/// window-minus-self per beat, but the window is kept sorted as it slides and
/// the self element is skipped by index arithmetic instead of copied out.
List<double> _slidingMedian(List<double> x, int win) {
  final n = x.length;
  final out = List<double>.filled(n, 0);
  final half = win ~/ 2;
  final w = _SortedWindow(x, half);
  for (var i = 0; i < n; i++) {
    w.advanceTo(i);
    out[i] = medianExcluding(w.a, x[i]) ?? x[i];
  }
  return out;
}

/// Ascending-sorted copy of `x[max(0,i-half) .. min(n-1,i+half)]`, maintained
/// incrementally as [advanceTo] steps i forward by one (O(log w) search plus a
/// w-element memmove per beat instead of an O(w log w) sort).
class _SortedWindow {
  final List<double> _x;
  final int _half;
  final _set = SortedMultiset();
  List<double> get a => _set.a;
  int _lo = 0;
  int _hi = -1; // inclusive; -1 = empty

  _SortedWindow(this._x, this._half);

  void advanceTo(int i) {
    final n = _x.length;
    final newLo = i - _half < 0 ? 0 : i - _half;
    final newHi = i + _half > n - 1 ? n - 1 : i + _half;
    if (_hi < _lo) {
      // First call: build once.
      _set.resetFrom(_x.getRange(newLo, newHi + 1));
    } else {
      while (_lo < newLo) {
        _set.remove(_x[_lo++]);
      }
      while (_hi < newHi) {
        _set.add(_x[++_hi]);
      }
    }
    _lo = newLo;
    _hi = newHi;
  }
}

/// Catmull-Rom cubic interpolation at the artifact index using the nearest two
/// NORMAL beats on each side. Returns null if anchors are unavailable.
double? _splineCorrect(List<double> rr, List<bool> isArtifact, int idx) {
  final left = <double>[];
  for (var k = idx - 1; k >= 0 && left.length < 2; k--) {
    if (!isArtifact[k]) left.insert(0, rr[k]);
  }
  final right = <double>[];
  for (var k = idx + 1; k < rr.length && right.length < 2; k++) {
    if (!isArtifact[k]) right.add(rr[k]);
  }
  return splineMid(left, right);
}
