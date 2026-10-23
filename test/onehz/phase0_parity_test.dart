// PHASE 0 PARITY (round 15) - characterization tests.
//
// The `_ref*` functions below are FROZEN verbatim copies of the code as it
// stood before round 15 (CVHR baseline loop, 1 g reference loop, Welch segment
// scan, and the callers around them). The production code is being refactored
// for speed with a bit-identical contract, so every comparison here is exact:
// doubles with `identical`-style equality (== or both NaN), every result field.
//
// Do NOT "fix" or tidy the reference copies. If production output changes, this
// test is supposed to fail.
//
// Only deviation from a straight copy: the cardio stager reference calls the
// PUBLIC `cleanRrBeatsBetween` / `remFeaturesFromBeats` / `classifyCardioEpochs`
// where the original called private wrappers around them (same bodies).

import 'dart:math' as math;

import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

// ───────────────────────── frozen CVHR reference ─────────────────────────────

/// [p25, p50, p75] of [xs], or null when empty. Same linear-interpolated
/// percentile the rest of the package uses.
List<double>? _refQuartiles(List<double> xs) => xs.isEmpty
    ? null
    : [percentile(xs, 25)!, percentile(xs, 50)!, percentile(xs, 75)!];

Metric<CvhrResult> refCvhrApneaScreen(
  List<double> nnMs,
  List<double> nnTimesMs, {
  required double artifactFraction,
  double minWidthSec = 10,
  double maxWidthSec = 120,
  double depthWidthRatioMin = 0.7, // ms per second
  double envWindowSec = 130,
  double maxArtifact = 0.30,
  double maxGapSec = 30,
}) {
  const inputs = ['rr_cleaned', 'beat_times'];
  if (nnMs.length < 60 || nnTimesMs.length != nnMs.length) {
    return const Metric<CvhrResult>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'too few beats for a CVHR screen (need ≥60)',
    );
  }
  if (artifactFraction > maxArtifact) {
    return Metric<CvhrResult>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'artifact fraction ${round6(artifactFraction)} > gate '
          '— CVHR dip detection unreliable',
    );
  }

  final tSec = [for (final t in nnTimesMs) t / 1000.0];
  if (tSec.last - tSec.first <= 0) {
    return const Metric<CvhrResult>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'degenerate beat times',
    );
  }

  // SEGMENT AT GAPS. Beats more than [maxGapSec] apart are two recordings, not
  // one: interpolating a straight line across the hole invents a flat stretch
  // with no cycles in it, and charging the hole to `analyzedHours` divides a
  // real cycle count by time we never observed. Both push the index DOWN, so a
  // charging break used to read as an improvement.
  final segStart = <int>[0];
  for (var i = 1; i < tSec.length; i++) {
    if (tSec[i] - tSec[i - 1] > maxGapSec) segStart.add(i);
  }

  var cycleCount = 0;
  var analyzedHours = 0.0;
  final depths = <double>[]; // ms
  final widths = <double>[]; // s
  for (var s = 0; s < segStart.length; s++) {
    final lo = segStart[s];
    final hi = (s + 1 < segStart.length ? segStart[s + 1] : tSec.length) - 1;
    final segT = tSec.sublist(lo, hi + 1);
    final segNn = nnMs.sublist(lo, hi + 1);
    final spanSec = segT.last - segT.first;
    // Too short to hold even one cycle plus its baseline window — it also can't
    // be scored, so it contributes neither cycles nor hours.
    if (segT.length < 60 || spanSec < 60) continue;
    analyzedHours += spanSec / 3600.0;
    _refScoreSegment(
      segT,
      segNn,
      minWidthSec: minWidthSec,
      maxWidthSec: maxWidthSec,
      depthWidthRatioMin: depthWidthRatioMin,
      envWindowSec: envWindowSec,
      onCycle: (depth, width) {
        cycleCount++;
        depths.add(depth);
        widths.add(width);
      },
    );
  }

  if (analyzedHours <= 0) {
    return const Metric<CvhrResult>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'no gap-free stretch long enough for a CVHR screen (<60 s)',
    );
  }

  final perHour = cycleCount / analyzedHours;
  final conf = ((1 - artifactFraction) * 0.85).clamp(0.2, 0.85);
  return Metric<CvhrResult>(
    value: CvhrResult(
      cycleCount: cycleCount,
      cvhrPerHour: perHour,
      analyzedHours: analyzedHours,
      meanDepthMs: depths.isEmpty ? null : mean(depths),
      meanWidthSec: widths.isEmpty ? null : mean(widths),
      depthQuartilesMs: _refQuartiles(depths),
      widthQuartilesSec: _refQuartiles(widths),
    ),
    confidence: conf,
    tier: Tier.high,
    inputs_used: inputs,
    note: 'CVHR/ACAT (Hayano) apnea SCREEN — NOT a diagnosis, NOT an AHI; '
        'single-night CVHR has substantial night-to-night variability, '
        'interpret as a trend over multiple nights',
  );
}

/// Score ONE gap-free stretch: resample → smooth → sliding-median baseline →
/// positive-excursion runs → width + steepness gates. Calls [onCycle] with
/// (depthMs, widthSec) per surviving cycle. [t] in seconds, [nn] in ms.
void _refScoreSegment(
  List<double> t,
  List<double> nn, {
  required double minWidthSec,
  required double maxWidthSec,
  required double depthWidthRatioMin,
  required double envWindowSec,
  required void Function(double depthMs, double widthSec) onCycle,
}) {
  // Resample NN onto a uniform 1 Hz grid by piecewise-linear interpolation of
  // the tachogram (NN vs beat time). This gives evenly-spaced points for the
  // sliding-window baseline and the polynomial smoother. Only ever called on a
  // stretch with no gap larger than the caller's tolerance, so no interpolation
  // here spans a hole.
  final t0 = t.first;
  final nGrid = (t.last - t0).floor() + 1;
  final grid = List<double>.generate(nGrid, (i) => t0 + i);
  final nnGrid = _refResampleLinear(t, nn, grid);

  // 2nd-order local-polynomial smoothing (Savitzky-Golay quadratic, ~7 s half
  // window) to suppress beat jitter while keeping the cyclic shape.
  final smooth = _refSavgolQuadratic(nnGrid, halfWin: 7);

  // Adaptive baseline over a ~130 s sliding median (spans ≥2 apnea cycles, so
  // it tracks the eupneic level without being pulled into individual dips).
  // The CVHR bradycardia shows up as a local NN MAXIMUM (NN ↑ ⇔ HR ↓) standing
  // proud of this baseline; the following tachycardia is the recovery valley.
  final halfEnv = (envWindowSec / 2).round();
  final base = List<double>.filled(nGrid, 0);
  for (var j = 0; j < nGrid; j++) {
    final lo = math.max(0, j - halfEnv);
    final hi = math.min(nGrid - 1, j + halfEnv);
    base[j] = median(smooth.sublist(lo, hi + 1)) ?? smooth[j];
  }
  // Baseline-subtracted bradycardic excursion (clip negatives — we only score
  // the NN-up bradycardia, not the tachycardia trough).
  final exc = [
    for (var j = 0; j < nGrid; j++) math.max(0.0, smooth[j] - base[j])
  ];

  // Prominence threshold: a dip must clear a robust noise floor AND a fraction
  // of the typical excursion amplitude. We anchor it BELOW the median positive
  // excursion (Hayano's adaptive amplitude criterion is permissive enough to
  // capture the whole bradycardia run, not just its tip) — a threshold at the
  // peak would clip the run width to a few seconds and miss the cycle.
  final posExc = [
    for (final e in exc)
      if (e > 0) e
  ];
  final excP75 = (posExc.isNotEmpty ? percentile(posExc, 75) : null) ?? 0;
  // half of the upper-quartile excursion: well inside each genuine dip's run.
  final prom = math.max(0.5 * excP75, 5.0); // ms

  // Find peaks of `exc`: local maxima exceeding `prom`, each isolated to one
  // contiguous super-threshold run (so one bradycardia = one cycle). Measure
  // the run width and the peak depth; apply the width + depth/width gates.
  var i = 0;
  while (i < nGrid) {
    if (exc[i] <= prom) {
      i++;
      continue;
    }
    final start = i;
    var peakDepth = 0.0;
    while (i < nGrid && exc[i] > prom) {
      if (exc[i] > peakDepth) peakDepth = exc[i];
      i++;
    }
    final widthSec = (i - start).toDouble(); // 1 Hz grid => samples == seconds
    if (widthSec < minWidthSec || widthSec > maxWidthSec) continue;
    // Depth-to-width steepness gate (ms per second): the bradycardia-tachycardia
    // swing is steep; slow baseline drift is shallow per second.
    if (peakDepth / widthSec < depthWidthRatioMin) continue;
    onCycle(peakDepth, widthSec);
  }
}

/// Piecewise-linear resample of (t,y) onto a sorted [grid] of times (same unit).
/// Out-of-range grid points clamp to the nearest endpoint value.
List<double> _refResampleLinear(
    List<double> t, List<double> y, List<double> grid) {
  final out = List<double>.filled(grid.length, 0);
  var j = 0;
  for (var k = 0; k < grid.length; k++) {
    final g = grid[k];
    if (g <= t.first) {
      out[k] = y.first;
      continue;
    }
    if (g >= t.last) {
      out[k] = y.last;
      continue;
    }
    while (j < t.length - 1 && t[j + 1] < g) {
      j++;
    }
    final t0 = t[j], t1 = t[j + 1];
    final span = t1 - t0;
    final frac = span == 0 ? 0.0 : (g - t0) / span;
    out[k] = y[j] + (y[j + 1] - y[j]) * frac;
  }
  return out;
}

/// 2nd-order Savitzky-Golay smoothing via a local quadratic least-squares fit
/// over a symmetric window of half-width [halfWin]. Evaluated at the centre.
List<double> _refSavgolQuadratic(List<double> x, {int halfWin = 7}) {
  final n = x.length;
  final out = List<double>.filled(n, 0);
  for (var i = 0; i < n; i++) {
    final lo = math.max(0, i - halfWin);
    final hi = math.min(n - 1, i + halfWin);
    final m = hi - lo + 1;
    if (m < 3) {
      out[i] = x[i];
      continue;
    }
    // Fit y = a + b·u + c·u² with u centred at i; return a (value at u=0).
    var s0 = 0.0, s1 = 0.0, s2 = 0.0, s3 = 0.0, s4 = 0.0;
    var sy = 0.0, suy = 0.0, su2y = 0.0;
    for (var k = lo; k <= hi; k++) {
      final u = (k - i).toDouble();
      final u2 = u * u;
      s0 += 1;
      s1 += u;
      s2 += u2;
      s3 += u2 * u;
      s4 += u2 * u2;
      sy += x[k];
      suy += u * x[k];
      su2y += u2 * x[k];
    }
    // Solve the 3x3 normal equations for [a,b,c]; we only need a.
    final a = _refSolve3(
      [s0, s1, s2, s1, s2, s3, s2, s3, s4],
      [sy, suy, su2y],
    );
    out[i] = a == null ? x[i] : a[0];
  }
  return out;
}

/// Solve a 3x3 linear system (row-major A, rhs b) via Cramer's rule. Null if
/// singular.
List<double>? _refSolve3(List<double> a, List<double> b) {
  double det3(double a0, double a1, double a2, double a3, double a4, double a5,
          double a6, double a7, double a8) =>
      a0 * (a4 * a8 - a5 * a7) -
      a1 * (a3 * a8 - a5 * a6) +
      a2 * (a3 * a7 - a4 * a6);
  final d = det3(a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8]);
  if (d == 0) return null;
  final dx = det3(b[0], a[1], a[2], b[1], a[4], a[5], b[2], a[7], a[8]);
  final dy = det3(a[0], b[0], a[2], a[3], b[1], a[5], a[6], b[2], a[8]);
  final dz = det3(a[0], a[1], b[0], a[3], a[4], b[1], a[6], a[7], b[2]);
  return [dx / d, dy / d, dz / d];
}

// ───────────────────────── frozen hrvFreq / Welch reference ──────────────────

Metric<HrvFreq> refHrvFreq(
  List<double> nnMs,
  List<double> nnTimesMs, {
  required double artifactFraction,
  double hfArtifactGate = 0.15,
  double oversample = 4.0,
}) {
  const inputs = ['rr_cleaned', 'beat_times'];
  if (nnMs.length < 16 || nnTimesMs.length != nnMs.length) {
    return const Metric<HrvFreq>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'too few beats for a spectral estimate',
    );
  }

  // Times in seconds for Hz output; tachogram value = NN (ms).
  final tSec = [for (final t in nnTimesMs) t / 1000.0];
  final spanSec = tSec.last - tSec.first;
  if (spanSec <= 0) {
    return const Metric<HrvFreq>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'degenerate beat times',
    );
  }

  // Each band gets its own segment length and its own resolution-matched grid.
  // A band whose lowest frequency the record is too short to resolve returns
  // null — absent, not a leakage-filled 0.0 (ULF used to be emitted as exactly
  // 0.0 for any session over 333 s, which is not a 24-h record by any reading).
  final ulf =
      _refWelchBandPower(tSec, nnMs, 0.0003, 0.003, oversample: oversample);
  final vlf = _refWelchBandPower(tSec, nnMs, 0.003, 0.04, oversample: oversample);
  final lf = _refWelchBandPower(tSec, nnMs, 0.04, 0.15, oversample: oversample);
  final hfRaw = _refWelchBandPower(tSec, nnMs, 0.15, 0.40, oversample: oversample);
  if (lf == null && hfRaw == null) {
    return const Metric<HrvFreq>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'record too short to resolve any HRV band',
    );
  }

  final hfGated = artifactFraction > hfArtifactGate;
  final hf = hfGated ? null : hfRaw;

  double? lfhf, nuLf, nuHf;
  if (lf != null && hf != null && (lf + hf) > 0) {
    lfhf = hf == 0 ? null : lf / hf;
    nuLf = 100.0 * lf / (lf + hf);
    nuHf = 100.0 * hf / (lf + hf);
  }
  // TOTAL POWER is by definition the sum over ALL bands (Task Force 1996).
  // When HF is suppressed we do not have a trustworthy HF term, so a "total"
  // is not computable: silently summing the withheld hfRaw back in republished
  // exactly the quantity the gate withheld (the gated and ungated totals came
  // out bit-identical), and dropping HF from the sum would republish a
  // different quantity under the same name. Either way it would be dishonest —
  // so total is WITHHELD alongside HF.
  //
  // A band the record could not RESOLVE is a different case, and it used to be
  // handled with `?? 0` — which is exactly the absence-as-zero this package
  // forbids, and it is not hypothetical: ULF needs 33 333 s of span (10 cycles
  // at 0.0003 Hz) and a night is ~28 700 s, so ULF resolved on precisely no
  // nights and the published total was silently the ULF-less sum. Withholding
  // total instead would delete a rendered number on every night forever. So it
  // is published with its composition NAMED in [totalBands]: the sum is over
  // those bands and no others.
  final bands = <String, double?>{
    'ulf': ulf,
    'vlf': vlf,
    'lf': lf,
    'hf': hfRaw
  };
  final resolved = [
    for (final e in bands.entries)
      if (e.value != null) e.key
  ];
  final total = (hfGated || lf == null || hfRaw == null)
      ? null
      : [for (final b in resolved) bands[b]!].reduce((a, b) => a + b);

  // Confidence: penalize artifacts heavily; low-band-only reads still HIGH-ish.
  final conf = ((1 - artifactFraction) * (hfGated ? 0.6 : 0.9)).clamp(0.2, 0.9);
  return Metric<HrvFreq>(
    value: HrvFreq(
      ulf: ulf,
      vlf: vlf,
      lf: lf,
      hf: hf,
      total: total,
      totalBands: total == null ? null : resolved,
      lfhf: lfhf,
      nuLf: nuLf,
      nuHf: nuHf,
      hfGated: hfGated,
    ),
    confidence: conf,
    tier: Tier.high,
    inputs_used: inputs,
    note: hfGated
        ? 'HF suppressed: artifact fraction ${round6(artifactFraction)} '
            '> gate — LF/VLF reported, HF/LF-HF/nu/total withheld'
        : 'PRV spectrum; HF band quantization-limited at 1 Hz',
  );
}

double? _refWelchBandPower(
  List<double> tSec,
  List<double> y,
  double loHz,
  double hiHz, {
  double cyclesPerSegment = 10.0,
  double oversample = 4.0,
  int minPointsPerSegment = 16,
}) {
  if (loHz <= 0 || hiHz <= loHz || tSec.length < minPointsPerSegment)
    return null;
  final span = tSec.last - tSec.first;
  final segSec = cyclesPerSegment / loHz;
  if (span < segSec) return null; // band not resolvable in this record

  final df = 1.0 / segSec / oversample;
  final nGrid = ((hiHz - loHz) / df).ceil() + 1;
  final grid = freqGrid(loHz, hiHz, nGrid);

  var sum = 0.0;
  var k = 0;
  final step = segSec / 2; // 50 % overlap, the Welch default
  for (var start = tSec.first; start + segSec <= tSec.last; start += step) {
    final end = start + segSec;
    final ts = <double>[];
    final ys = <double>[];
    for (var i = 0; i < tSec.length; i++) {
      if (tSec[i] < start) continue;
      if (tSec[i] >= end) break;
      ts.add(tSec[i]);
      ys.add(y[i]);
    }
    // A segment has to be BOTH beat-dense and time-complete: a dropout in
    // the middle leaves few beats spanning the full window, and its
    // periodogram is a window function, not a spectrum. Endpoint span alone
    // misses an internal dropout that still leaves beats near both edges, so
    // also reject on the single largest gap between consecutive beats.
    if (ts.length < minPointsPerSegment || ts.last - ts.first < segSec * 0.8) {
      continue;
    }
    var maxGap = 0.0;
    for (var i = 1; i < ts.length; i++) {
      final g = ts[i] - ts[i - 1];
      if (g > maxGap) maxGap = g;
    }
    if (maxGap > segSec * 0.2) continue;
    final ls = lombScargle(ts, ys, grid);
    if (ls == null) continue;
    final p = ls.bandPower(loHz, hiHz);
    if (!p.isFinite) continue;
    sum += p;
    k++;
  }
  return k == 0 ? null : sum / k;
}

// ───────────────────────── frozen cardio stager reference ────────────────────

CardioStagerResult refCardioStager(
  List<double> hr1hz,
  List<AccelSample> accel, {
  List<double> rrMs = const [],
  List<double> rrTsMs = const [],
  int epochSec = 30,
  SleepUserProfile? userProfile,
}) {
  // Explicit arg wins (unit tests); else the ambient profile the edge set for
  // this staging pass; else null ⇒ pure per-night-local (cold-start behavior).
  final profile = userProfile ?? cardioUserProfile;
  // `_cleanBeatsInWindow` binary-searches this, so it has to be non-decreasing.
  // The producer guarantees it — beats inherit their record's second and the
  // records are sorted, and the one path that folds in loose live beats
  // re-sorts the pair explicitly. An `assert` rather than a linear fallback:
  // a fallback would pay the scan back on every window to insure against a
  // state the caller cannot reach, whereas this is free in release and loud in
  // every test the moment somebody builds an unsorted series.
  assert(() {
    for (var i = 1; i < rrTsMs.length; i++) {
      if (rrTsMs[i] < rrTsMs[i - 1]) return false;
    }
    return true;
  }(), 'rrTsMs must be non-decreasing — the beat window is binary-searched');
  final n = math.min(hr1hz.length, accel.length);
  // ── REAL-TIME epoch grid ──────────────────────────────────────────────────
  // `n ~/ epochSec` conflated ARRAY POSITIONS with SECONDS. At 1 Hz they are
  // the same number and everything below is unchanged; off 1 Hz they are not,
  // and the failure was not an accuracy one — a 300 s band gave
  // `96 ~/ 30 = 3` "epochs" of 2.5 REAL HOURS each, which the 30-s-tuned rules
  // labelled NREM end to end and published as `wakePct = 0.0`: a night this
  // stager could not read, reported as zero wake. No new parameter is needed
  // for the fix — `accel[i].tsMs` is already the clock `_cleanBeatsInWindow`
  // binary-searches, so the cadence is measurable from the input we have.
  final cadenceSec = sampleCadenceSeconds(
      [for (var i = 0; i < n; i++) accel[i].tsMs / 1000.0]);
  // Coarser than one sample per epoch ⇒ there is no 30-s epoch to score, and
  // the Webster/Cole-Kripke continuity rules below are specified at this epoch
  // length. Stretching `epochSec` to fit the device would make a number appear
  // where the evidence for it does not; abstain instead.
  if (cadenceSec == null || cadenceSec > epochSec) return _refAbstain(epochSec);
  final perEpoch = math.max(1, (epochSec / cadenceSec).round());
  // `perEpoch` samples at this cadence must actually SPAN `epochSec` — a
  // cadence that does not divide it evenly (4 s against a 30 s epoch rounds
  // `perEpoch` to 8, an 8 * 4 = 32 s epoch) drifts the real grid against the
  // reported one. `epochSec` is not just a label: it is what the result
  // reports (`CardioStagerResult.epochSec`) and what `consolidateSleepStages`
  // / `_websterRescore` / `_mergeShortDeep` derive the Webster and bout
  // thresholds from below, and the drift accumulates over the whole night.
  // Abstain rather than publish a grid whose real spacing does not match its
  // own label.
  if ((perEpoch * cadenceSec - epochSec).abs() > 1e-6)
    return _refAbstain(epochSec);
  final nEpoch = n ~/ perEpoch;
  if (nEpoch < 3) return _refAbstain(epochSec);

  // ── per-second ENMO (motion) against a LOCALLY-ADAPTIVE 1 g reference ──────
  // A single whole-night gravity-magnitude reference (the old approach) is
  // wrong on real WHOOP-4 units: the decoded gravity vector's magnitude is NOT
  // perfectly orientation-invariant (per-axis gain/calibration isn't exact),
  // so different STATIC sleep postures can read meaningfully apart in |accel|
  // even though nothing is moving. Verified on a real overnight capture: a
  // person lying rock-still for 30+ min (within-epoch stddev of |accel| <
  // 0.0003 g) read |accel| = 1.0512 g against that whole-night's calibrated
  // reference of 1.0348 g — a 0.0167 g "motion" score, ~3x the bigMove
  // threshold, purely from holding a different (but equally static) posture
  // than whichever one the night happened to calibrate against. Across that
  // night, 389 of 421 "big move" epochs (92%) were this exact artifact (tiny
  // within-epoch variance, large offset from the single global reference),
  // not real movement — and the resulting misclassified WAKE blocks could not
  // be fully bridged back by Webster rescore below. Recomputing the reference
  // locally (a window wide enough to not react to real short movement bouts,
  // narrow enough to track a genuine posture change within a few minutes)
  // absorbs each posture as its own baseline instead of misreading it as
  // sustained motion.
  final mag = List<double>.filled(n, 0);
  for (var i = 0; i < n; i++) {
    final a = accel[i];
    mag[i] = math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z);
  }
  const int _gRefWinSec = 300; // 5 min window, centered per epoch
  // …in SAMPLES at the measured cadence. 300 at 1 Hz, unchanged.
  final gRefHalf = math.max(1, (_gRefWinSec / cadenceSec).round()) ~/ 2;
  final gRefByEpoch = List<double>.filled(nEpoch, 1.0);
  for (var e = 0; e < nEpoch; e++) {
    final es = e * perEpoch;
    final lo = math.max(0, es - gRefHalf);
    final hi = math.min(n, es + perEpoch + gRefHalf);
    gRefByEpoch[e] = median(mag.sublist(lo, hi)) ?? 1.0;
  }

  // ── per-epoch features ─────────────────────────────────────────────────────
  final motion = List<double>.filled(nEpoch, 0);
  final hr = List<double>.filled(nEpoch, double.nan);
  final hrSd = List<double>.filled(nEpoch, 0);
  final rmssd = List<double>.filled(nEpoch, double.nan);
  final sdnn = List<double>.filled(nEpoch, double.nan);
  // REM autonomic features (P1): LF/HF from the RR spectrum + R(k) = rolling
  // mean |ΔIHR|. REM's signature at 1 Hz beat-timing is a SYMPATHETIC shift —
  // LF/HF rises, RR variability drops (low RMSSD), and instantaneous HR gets
  // "jittery" (elevated |ΔIHR|). The old REM rule leaned only on the RMSSD drop
  // and under-called REM; these two independent axes recover it (OR-combined
  // below), gated by atonia + an HR floor so a plain arousal is not miscalled.
  final lfhf = List<double>.filled(nEpoch, double.nan);
  final rk = List<double>.filled(nEpoch, double.nan);

  for (var e = 0; e < nEpoch; e++) {
    final s = e * perEpoch, t = math.min(s + perEpoch, n);
    // motion = mean ENMO over the epoch, against THIS epoch's local reference.
    final gRefE = gRefByEpoch[e];
    var ms = 0.0;
    for (var i = s; i < t; i++) {
      final d = mag[i] - gRefE;
      ms += d > 0 ? d : 0.0;
    }
    motion[e] = ms / (t - s);
    // hr mean/sd over valid (>0) seconds
    final hv = <double>[
      for (var i = s; i < t; i++)
        if (hr1hz[i] > 0) hr1hz[i]
    ];
    if (hv.isNotEmpty) hr[e] = mean(hv)!;
    if (hv.length >= 2) hrSd[e] = stddev(hv) ?? 0;
    // rmssd over RR beats within a ±2.5-min window centred on the epoch
    rmssd[e] = _refWindowRmssd(rrMs, rrTsMs, accel, s, t, epochSec);
    sdnn[e] = _refWindowSdnn(rrMs, rrTsMs, accel, s, t, epochSec);
    // LF/HF + R(k) over a ±90-s RR window centred on the epoch.
    final rem = _refWindowRemFeatures(rrMs, rrTsMs, accel, s, t, epochSec);
    if (rem.lfhf != null) lfhf[e] = rem.lfhf!;
    if (rem.rk != null) rk[e] = rem.rk!;
  }

  return classifyCardioEpochs(
    CardioEpochFeatures(
      motion: motion,
      hr: hr,
      hrSd: hrSd,
      rmssd: rmssd,
      lfhf: lfhf,
      rk: rk,
      sdnn: sdnn,
    ),
    epochSec: epochSec,
    userProfile: profile,
  );
}

CardioStagerResult _refAbstain(int epochSec) => CardioStagerResult(
      StagerResult(
        stages: const <SleepStage>[],
        epochSec: epochSec,
        wakePct: 0,
        nremPct: 0,
        remPct: 0,
      ),
      const <bool>[],
      0,
    );

({List<double> beats, List<double> tsSec, List<bool> seam})
    _refCleanBeatsInWindow(
  List<double> rrMs,
  List<double> rrTsMs,
  List<AccelSample> accel,
  int s,
  int t, {
  int halfWinMs = 150 * 1000,
}) {
  const empty = (beats: <double>[], tsSec: <double>[], seam: <bool>[]);
  if (rrMs.isEmpty || rrTsMs.length != rrMs.length) return empty;
  final mid = (s + t) ~/ 2;
  if (mid >= accel.length) return empty;
  final centreMs = accel[mid].tsMs;
  return cleanRrBeatsBetween(
      rrMs, rrTsMs, centreMs - halfWinMs, centreMs + halfWinMs);
}

double _refWindowRmssd(List<double> rrMs, List<double> rrTsMs,
    List<AccelSample> accel, int s, int t, int epochSec) {
  // Upstream's seam rule (merged 2026-10-18): skip seam pairs, gate on pairs.
  final win = _refCleanBeatsInWindow(rrMs, rrTsMs, accel, s, t);
  final beats = win.beats;
  if (beats.length < 5) return double.nan;
  var ss = 0.0;
  var pairs = 0;
  for (var i = 1; i < beats.length; i++) {
    if (win.seam[i]) continue;
    final d = beats[i] - beats[i - 1];
    ss += d * d;
    pairs++;
  }
  return pairs >= 4 ? math.sqrt(ss / pairs) : double.nan;
}

double _refWindowSdnn(List<double> rrMs, List<double> rrTsMs,
    List<AccelSample> accel, int s, int t, int epochSec) {
  final beats = _refCleanBeatsInWindow(rrMs, rrTsMs, accel, s, t).beats;
  if (beats.length < 5) return double.nan;
  return stddev(beats) ?? double.nan;
}

({double? lfhf, double? rk}) _refWindowRemFeatures(List<double> rrMs,
    List<double> rrTsMs, List<AccelSample> accel, int s, int t, int epochSec) {
  final win =
      _refCleanBeatsInWindow(rrMs, rrTsMs, accel, s, t, halfWinMs: 90 * 1000);
  return remFeaturesFromBeats(win.beats, win.tsSec, win.seam);
}

// ───────────────────────────── helpers ───────────────────────────────────────

bool sameD(double? a, double? b) {
  if (a == null || b == null) return a == null && b == null;
  if (a.isNaN || b.isNaN) return a.isNaN && b.isNaN;
  return a == b && a.isNegative == b.isNegative;
}

void expectSameD(double? a, double? b, String what) {
  expect(sameD(a, b), isTrue, reason: '$what: $a vs $b');
}

void expectSameList(List<double>? a, List<double>? b, String what) {
  if (a == null || b == null) {
    expect(a == null && b == null, isTrue, reason: '$what nullness');
    return;
  }
  expect(a.length, b.length, reason: '$what length');
  for (var i = 0; i < a.length; i++) {
    if (!sameD(a[i], b[i])) fail('$what[$i]: ${a[i]} vs ${b[i]}');
  }
}

void expectSameMetric<T>(Metric<T> a, Metric<T> b) {
  expect(a.value == null, b.value == null, reason: 'value presence');
  expectSameD(a.confidence, b.confidence, 'confidence');
  expect(a.tier, b.tier);
  expect(a.inputs_used, b.inputs_used);
  expect(a.note, b.note);
  expect(a.drivers == null, b.drivers == null);
}

void expectSameCvhr(Metric<CvhrResult> a, Metric<CvhrResult> b) {
  expectSameMetric(a, b);
  final x = a.value, y = b.value;
  if (x == null || y == null) return;
  expect(x.cycleCount, y.cycleCount);
  expectSameD(x.cvhrPerHour, y.cvhrPerHour, 'cvhrPerHour');
  expectSameD(x.analyzedHours, y.analyzedHours, 'analyzedHours');
  expectSameD(x.meanDepthMs, y.meanDepthMs, 'meanDepthMs');
  expectSameD(x.meanWidthSec, y.meanWidthSec, 'meanWidthSec');
  expectSameList(x.depthQuartilesMs, y.depthQuartilesMs, 'depthQuartiles');
  expectSameList(x.widthQuartilesSec, y.widthQuartilesSec, 'widthQuartiles');
}

void expectSameHrv(Metric<HrvFreq> a, Metric<HrvFreq> b) {
  expectSameMetric(a, b);
  final x = a.value, y = b.value;
  if (x == null || y == null) return;
  expectSameD(x.ulf, y.ulf, 'ulf');
  expectSameD(x.vlf, y.vlf, 'vlf');
  expectSameD(x.lf, y.lf, 'lf');
  expectSameD(x.hf, y.hf, 'hf');
  expectSameD(x.total, y.total, 'total');
  expect(x.totalBands, y.totalBands);
  expectSameD(x.lfhf, y.lfhf, 'lfhf');
  expectSameD(x.nuLf, y.nuLf, 'nuLf');
  expectSameD(x.nuHf, y.nuHf, 'nuHf');
  expect(x.hfGated, y.hfGated);
}

void expectSameStager(CardioStagerResult a, CardioStagerResult b) {
  expect(a.base.stages, b.base.stages);
  expect(a.base.epochSec, b.base.epochSec);
  expectSameD(a.base.wakePct, b.base.wakePct, 'wakePct');
  expectSameD(a.base.nremPct, b.base.nremPct, 'nremPct');
  expectSameD(a.base.remPct, b.base.remPct, 'remPct');
  expect(a.deepFlag, b.deepFlag);
  expectSameD(a.confidence, b.confidence, 'confidence');
}

// ───────────────────────────── generators ────────────────────────────────────

/// Beat series: NN with a ~[period]-s cyclic dip pattern plus noise.
///  gapEvery: mean beats between >30 s holes (0 = none)
///  nanFrac / dupFrac: fraction of NaN NN values / repeated timestamps
({List<double> nn, List<double> tMs}) genBeats(
  int seed,
  int n, {
  double period = 55,
  double amp = 60,
  int gapEvery = 0,
  double nanFrac = 0,
  double dupFrac = 0,
  double meanNn = 900,
}) {
  final r = math.Random(seed);
  final nn = <double>[];
  final t = <double>[];
  var tMs = 1000.0 * r.nextInt(1000);
  for (var i = 0; i < n; i++) {
    final ph = 2 * math.pi * (tMs / 1000.0) / period;
    var v = meanNn +
        amp * math.max(0.0, math.sin(ph)) -
        0.3 * amp * math.min(0.0, math.sin(ph)) +
        (r.nextDouble() - 0.5) * 40;
    if (nanFrac > 0 && r.nextDouble() < nanFrac) v = double.nan;
    nn.add(v);
    final isDup = dupFrac > 0 && i > 0 && r.nextDouble() < dupFrac;
    if (!isDup) {
      var step = v.isNaN ? meanNn : v;
      if (gapEvery > 0 && r.nextInt(gapEvery) == 0) {
        step += 31000 + r.nextInt(90000);
      }
      tMs += step;
    }
    t.add(tMs);
  }
  return (nn: nn, tMs: t);
}

({List<double> hr, List<AccelSample> accel, List<double> rr, List<double> rrTs})
    genNight(
  int seed,
  int seconds, {
  int cadenceSec = 1,
  bool nanAccel = false,
  bool hrDropouts = false,
  bool rrOutliers = false,
  bool withRr = true,
}) {
  final r = math.Random(seed);
  final n = seconds ~/ cadenceSec;
  final hr = <double>[];
  final accel = <AccelSample>[];
  final rr = <double>[];
  final rrTs = <double>[];
  var posture = 1.0;
  var moveLeft = 0;
  var hrBase = 62.0;
  for (var i = 0; i < n; i++) {
    final ts = i * cadenceSec * 1000.0;
    if (r.nextInt(900) == 0) posture = 0.95 + r.nextDouble() * 0.1;
    if (moveLeft == 0 && r.nextInt(500) == 0) moveLeft = 5 + r.nextInt(40);
    var m = posture + (r.nextDouble() - 0.5) * 0.002;
    if (moveLeft > 0) {
      m += r.nextDouble() * 0.3;
      moveLeft--;
    }
    if (r.nextInt(2000) == 0) hrBase = 52 + r.nextDouble() * 25;
    final cyc = 4 * math.sin(2 * math.pi * i * cadenceSec / 5400.0);
    var h = hrBase + cyc + (r.nextDouble() - 0.5) * 4;
    if (moveLeft > 0) h += 12;
    if (hrDropouts && (i ~/ 200) % 7 == 3) h = 0;
    if (hrDropouts && r.nextInt(300) == 0) h = double.nan;
    hr.add(h);
    var gx = m * 0.6;
    final gy = m * 0.64, gz = m * 0.48;
    if (nanAccel && r.nextInt(400) == 0) gx = double.nan;
    accel.add(AccelSample(ts, gx, gy, gz));
    if (withRr) {
      // beats inherit their record second => tied timestamps, ascending
      final nb = h.isNaN || h <= 0 ? 0 : (h * cadenceSec / 60).round();
      for (var b = 0; b < nb; b++) {
        var v = 60000.0 / h +
            (r.nextDouble() - 0.5) * 60 +
            40 * math.sin(2 * math.pi * i * cadenceSec / 25.0);
        if (rrOutliers && r.nextInt(60) == 0) {
          v = r.nextBool() ? 150 : 2600;
        } else if (rrOutliers && r.nextInt(80) == 0) {
          v += 350;
        }
        rr.add(v);
        rrTs.add(ts);
      }
    }
  }
  return (hr: hr, accel: accel, rr: rr, rrTs: rrTs);
}

// ───────────────────────────── tests ─────────────────────────────────────────

void main() {
  group('CVHR baseline parity (frozen cvhrApneaScreen)', () {
    void check(String name, int seed, int n,
        {int gapEvery = 0,
        double nanFrac = 0,
        double dupFrac = 0,
        double artifact = 0.05,
        double period = 55}) {
      test(name, () {
        final b = genBeats(seed, n,
            gapEvery: gapEvery,
            nanFrac: nanFrac,
            dupFrac: dupFrac,
            period: period);
        expectSameCvhr(
          cvhrApneaScreen(b.nn, b.tMs, artifactFraction: artifact),
          refCvhrApneaScreen(b.nn, b.tMs, artifactFraction: artifact),
        );
      });
    }

    check('clean 1 h', 1, 3800);
    check('clean 2 h, other period', 2, 7600, period: 83);
    check('gaps', 3, 4000, gapEvery: 700);
    check('many gaps (short segments dropped)', 4, 2500, gapEvery: 90);
    // NaN NN values are deliberately NOT exercised here: a NaN reaching the run
    // detection (`exc[i] <= prom` is false for NaN, and the inner
    // `while (exc[i] > prom)` is false too) never advances `i` - an infinite loop
    // in today's code, so no frozen output exists to compare against.
    check('duplicate timestamps', 6, 3600, dupFrac: 0.05);
    check('gaps + duplicates', 7, 4200, gapEvery: 600, dupFrac: 0.03);
    check('exactly 60 beats', 8, 60);
    check('59 beats (absent)', 9, 59);
    check('short, 75 beats', 10, 75);
    check('artifact gate (absent)', 11, 3600, artifact: 0.5);

    test('mismatched lengths and degenerate times', () {
      final b = genBeats(12, 100);
      expectSameCvhr(
        cvhrApneaScreen(b.nn, b.tMs.sublist(1), artifactFraction: 0.0),
        refCvhrApneaScreen(b.nn, b.tMs.sublist(1), artifactFraction: 0.0),
      );
      final flat = List<double>.filled(100, 5000.0);
      expectSameCvhr(
        cvhrApneaScreen(b.nn, flat, artifactFraction: 0.0),
        refCvhrApneaScreen(b.nn, flat, artifactFraction: 0.0),
      );
    });

    test('non-default tunables', () {
      final b = genBeats(13, 3600);
      expectSameCvhr(
        cvhrApneaScreen(b.nn, b.tMs,
            artifactFraction: 0.1,
            envWindowSec: 91,
            minWidthSec: 8,
            maxWidthSec: 100,
            depthWidthRatioMin: 0.5,
            maxGapSec: 20),
        refCvhrApneaScreen(b.nn, b.tMs,
            artifactFraction: 0.1,
            envWindowSec: 91,
            minWidthSec: 8,
            maxWidthSec: 100,
            depthWidthRatioMin: 0.5,
            maxGapSec: 20),
      );
    });

    test('full 8 h night with gaps', () {
      final b = genBeats(14, 30000, gapEvery: 6000, amp: 45);
      final a = cvhrApneaScreen(b.nn, b.tMs, artifactFraction: 0.04);
      expectSameCvhr(
          a, refCvhrApneaScreen(b.nn, b.tMs, artifactFraction: 0.04));
      // Not vacuous: the synthetic dips must actually be scored.
      expect(a.value!.cycleCount, greaterThan(0));
    });
  });

  group('hrvFreq / Welch parity (frozen _welchBandPower)', () {
    void check(String name, int seed, int n,
        {int gapEvery = 0,
        double nanFrac = 0,
        double dupFrac = 0,
        double artifact = 0.05,
        double meanNn = 900}) {
      test(name, () {
        final b = genBeats(seed, n,
            gapEvery: gapEvery,
            nanFrac: nanFrac,
            dupFrac: dupFrac,
            meanNn: meanNn);
        expectSameHrv(
          hrvFreq(b.nn, b.tMs, artifactFraction: artifact),
          refHrvFreq(b.nn, b.tMs, artifactFraction: artifact),
        );
      });
    }

    check('clean 1.2 h', 21, 4500);
    check('clean 1.5 h, faster heart', 22, 6000, meanNn: 700);
    check('beat gaps reject segments', 23, 5000, gapEvery: 400);
    check('NaN NN values', 24, 4000, nanFrac: 0.002);
    check('duplicate timestamps', 25, 4000, dupFrac: 0.05);
    check('gaps + NaN + duplicates', 26, 5000,
        gapEvery: 900, nanFrac: 0.001, dupFrac: 0.02);
    check('HF gated by artifact fraction', 27, 4000, artifact: 0.3);
    check('short record, VLF unresolved', 28, 400);
    check('16 beats', 29, 16);
    check('15 beats (absent)', 30, 15);
    check('very short span (nothing resolves)', 31, 50, meanNn: 400);
    // 10 h of sparse beats so the ULF band (33 333 s segment) resolves too.
    check('ULF resolves (10 h sparse)', 32, 6000, meanNn: 6000);
    check('ULF with gaps', 33, 6000, meanNn: 6000, gapEvery: 1500);

    test('non-default oversample', () {
      final b = genBeats(34, 3500);
      expectSameHrv(
        hrvFreq(b.nn, b.tMs, artifactFraction: 0.0, oversample: 2.5),
        refHrvFreq(b.nn, b.tMs, artifactFraction: 0.0, oversample: 2.5),
      );
    });

    test('degenerate times and mismatched lengths', () {
      final b = genBeats(35, 40);
      expectSameHrv(
        hrvFreq(b.nn, List.filled(40, 7000.0), artifactFraction: 0.0),
        refHrvFreq(b.nn, List.filled(40, 7000.0), artifactFraction: 0.0),
      );
      expectSameHrv(
        hrvFreq(b.nn, b.tMs.sublist(2), artifactFraction: 0.0),
        refHrvFreq(b.nn, b.tMs.sublist(2), artifactFraction: 0.0),
      );
    });
  });

  group('cardio stager parity (frozen 1 g reference loop + entry point)', () {
    void check(String name, int seed, int seconds,
        {int cadenceSec = 1,
        bool nanAccel = false,
        bool hrDropouts = false,
        bool rrOutliers = false,
        bool withRr = true}) {
      test(name, () {
        final g = genNight(seed, seconds,
            cadenceSec: cadenceSec,
            nanAccel: nanAccel,
            hrDropouts: hrDropouts,
            rrOutliers: rrOutliers,
            withRr: withRr);
        final a = cardioStager(g.hr, g.accel, rrMs: g.rr, rrTsMs: g.rrTs);
        final b = refCardioStager(g.hr, g.accel, rrMs: g.rr, rrTsMs: g.rrTs);
        expectSameStager(a, b);
        // Not vacuous: normal inputs must actually stage something.
        if (name.startsWith('staged')) {
          expect(a.base.stages, isNotEmpty);
        }
      });
    }

    check('staged 40 min with RR', 41, 2400);
    check('staged 50 min, RR outliers + HR dropouts', 42, 3000,
        rrOutliers: true, hrDropouts: true);
    check('staged 40 min, NaN accel magnitudes', 43, 2400, nanAccel: true);
    check('staged 1 h without RR', 44, 3600, withRr: false);
    check('staged 10 s cadence', 45, 7200, cadenceSec: 10);
    check('5 s cadence (abstains: 30/5 grid)', 46, 7200, cadenceSec: 5);
    check('60 s cadence (abstains)', 47, 14400, cadenceSec: 60);
    check('short: 2 epochs (abstains)', 48, 70);
    check('short: 3 epochs', 49, 95);
    check('short: 100 s partial last epoch', 50, 100);

    test('mismatched hr/accel lengths and empty input', () {
      final g = genNight(51, 1800);
      expectSameStager(
        cardioStager(g.hr.sublist(0, 1500), g.accel,
            rrMs: g.rr, rrTsMs: g.rrTs),
        refCardioStager(g.hr.sublist(0, 1500), g.accel,
            rrMs: g.rr, rrTsMs: g.rrTs),
      );
      expectSameStager(cardioStager(const [], const []),
          refCardioStager(const [], const []));
    });

    test('custom epochSec', () {
      final g = genNight(52, 2400);
      expectSameStager(
        cardioStager(g.hr, g.accel, rrMs: g.rr, rrTsMs: g.rrTs, epochSec: 60),
        refCardioStager(g.hr, g.accel,
            rrMs: g.rr, rrTsMs: g.rrTs, epochSec: 60),
      );
    });

    test('long night (3 h)', () {
      final g = genNight(53, 3 * 3600, hrDropouts: true, rrOutliers: true);
      expectSameStager(
        cardioStager(g.hr, g.accel, rrMs: g.rr, rrTsMs: g.rrTs),
        refCardioStager(g.hr, g.accel, rrMs: g.rr, rrTsMs: g.rrTs),
      );
    });
  });
}
