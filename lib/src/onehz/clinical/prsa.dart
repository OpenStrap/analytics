// CLINICAL TIER-1 — Phase-Rectified Signal Averaging (Bauer 2006).
//
// Deceleration Capacity (DC) and Acceleration Capacity (AC) of heart rate.
// Mortality-grade, noise-robust by averaging over thousands of anchors — our
// long all-night beat-to-beat RR is exactly its substrate.
//
// Algorithm:
//   1. Anchor selection: for DC, anchor i where RR(i) > RR(i-1) (a
//      deceleration); for AC, RR(i) < RR(i-1). Bounded by a ratio threshold T
//      to suppress artifacts, default 0.05.
//
//      THE 0.05 IS OURS. PMC6299532 gives the DCorg formula and L = 64 and
//      states NO percentage anchor-exclusion threshold; the header used to call
//      0.05 "Bauer's own" and "the canonical setting", and no primary source for
//      that could be found. DC scales strongly with it — at RMSSD 80 the capped
//      estimate is 10.3 ms against 35.1 ms unbounded — so it is a calibration
//      knob that governs the number, and it must not be changed on the strength
//      of a comment in either direction. (The header before that one claimed
//      "default unbounded"; it never was.)
//   2. For each anchor, take a window of length 2L centered at the anchor.
//      Drop anchors too close to the series ends.
//   3. Phase-aligned averaging: X(k) = mean over anchors of RR(anchor+k),
//      k in [-L, L-1].
//   4. Quantify with the Haar-wavelet-like contrast (s=2):
//      DC = [X(0) + X(1) − X(−1) − X(−2)] / 4.   (ms; positive = healthier)
//
// NO RISK TIER. This used to emit Bauer's post-MI mortality tier (≤2.5 high /
// 2.6–4.5 intermediate / >4.5 low). Those cut-offs come from 24-h Holter ECG in
// 1,455 post-MI patients (Lancet 2006;367:1674-81); healthy 24-h DC is
// 13.43 ± 5.60 ms, so every wrist-PPG night sits below the whole table and the
// string read "low risk" or worse for a healthy user forever. Measured on one
// subject across three straps inside nine days: gen4 DC 7.61–9.90 → 'low' every
// night, MG 4.06/4.87/5.96 → 'intermediate'/'low'/'low', W5 1.70 → 'high'. The
// tier was decided by which strap he wore that week. Detection, never diagnosis.
// `capacity` stays as a RELATIVE trended number against the user's own baseline.
// A tier may come back only with per-family calibration (`device.dart`) plus a
// validation on a comparable signal — the one wrist-PPG DC validation that
// exists (Sci Rep 2026, doi 10.1038/s41598-026-52700-7, ρ = 0.95) is 5 min 30 s
// of continuous beat detection in sinus rhythm, not an all-night PPG tachogram.

import '../types.dart';
import '../util.dart';

class PrsaResult {
  final double capacity; // DC (deceleration) or AC (acceleration), ms
  final List<double> profile; // averaged X(k), k=-L..L-1
  final int anchors; // number of anchors averaged
  final String kind; // 'DC' or 'AC'
  const PrsaResult({
    required this.capacity,
    required this.profile,
    required this.anchors,
    required this.kind,
  });
  Map<String, dynamic> toJson() => {
        'capacity_ms': round6(capacity),
        'anchors': anchors,
        'kind': kind,
      };
}

/// PRSA deceleration capacity.
///
/// Pass [nnTimesMs] (aligned to [nnMs], e.g. `correctRr(...).nnTimes`) so no
/// anchor window is formed across a hole in the beat record.
Metric<PrsaResult> decelerationCapacity(List<double> nnMs,
        {int l = 2, double anchorRatioCap = 0.05, List<num>? nnTimesMs}) =>
    _prsa(nnMs,
        l: l,
        deceleration: true,
        anchorRatioCap: anchorRatioCap,
        nnTimesMs: nnTimesMs);

/// PRSA acceleration capacity. See [decelerationCapacity] for [nnTimesMs].
Metric<PrsaResult> accelerationCapacity(List<double> nnMs,
        {int l = 2, double anchorRatioCap = 0.05, List<num>? nnTimesMs}) =>
    _prsa(nnMs,
        l: l,
        deceleration: false,
        anchorRatioCap: anchorRatioCap,
        nnTimesMs: nnTimesMs);

Metric<PrsaResult> _prsa(
  List<double> nnMs, {
  required int l,
  required bool deceleration,
  required double anchorRatioCap,
  List<num>? nnTimesMs,
}) {
  final kind = deceleration ? 'DC' : 'AC';
  final n = nnMs.length;
  final inputs = nnTimesMs == null
      ? const ['rr_cleaned']
      : const ['rr_cleaned', 'beat_times'];
  // Beat times that do not line up with the intervals cannot place a seam, and
  // falling back to the untimed path would anchor across exactly the holes
  // the caller passed them to guard against.
  if (nnTimesMs != null && nnTimesMs.length != n) {
    return Metric<PrsaResult>.absent(
      tier: Tier.relative,
      inputs_used: inputs,
      note: 'PRSA ($kind): beat times not aligned with intervals',
    );
  }
  if (l < 2) {
    // Bauer 2006 quantifies PRSA with the Haar contrast at wavelet scale s = 2:
    // DC = [X(0) + X(1) − X(−1) − X(−2)]/4, which needs TWO profile points on
    // each side of the anchor. With l < 2 the profile is too short (l = 1 used
    // to index profile[l−2] = profile[−1] and throw a RangeError).
    return Metric<PrsaResult>.absent(
      tier: Tier.relative,
      inputs_used: inputs,
      note: 'PRSA ($kind) needs l≥2 for the s=2 Haar contrast',
    );
  }
  if (n < 2 * l + 4) {
    return Metric<PrsaResult>.absent(
      tier: Tier.relative,
      inputs_used: inputs,
      note: 'too few beats for PRSA ($kind)',
    );
  }

  // Anchor selection with an artifact-suppression ratio cap: |RR(i)/RR(i-1)-1|
  // must be ≤ anchorRatioCap so gross jumps (residual artifacts) don't anchor.
  //
  // Anchors must also sit in a stretch that is contiguous in TIME. correctRr
  // drops artifact runs and re-anchors its clock across sensor holes, so two
  // beats adjacent in the list can sit either side of a 40-minute gap; one
  // such pair used to anchor on its own and publish a DC built from beats an
  // hour apart. Same seam test as hrv_time.dart: a pair is contiguous iff the
  // elapsed time between the two beat times is the interval itself.
  final gapAware = nnTimesMs != null;
  // seamBefore[j] = the step from beat j-1 to beat j crosses a hole. A beat
  // time that runs backwards is a break in the record too; equal times are
  // left contiguous (whole-second source clocks repeat them).
  final seamBefore = List<bool>.filled(n, false);
  if (gapAware) {
    for (var j = 1; j < n; j++) {
      final dt = nnTimesMs[j] - nnTimesMs[j - 1];
      seamBefore[j] = dt < 0 || dt > nnMs[j] + 0.5;
    }
  }
  final anchors = <int>[];
  for (var i = l; i < n - l; i++) {
    if (gapAware) {
      // The averaged window is i-l .. i+l-1; every step inside it must be
      // contiguous.
      var crosses = false;
      for (var j = i - l + 1; j <= i + l - 1; j++) {
        if (seamBefore[j]) {
          crosses = true;
          break;
        }
      }
      if (crosses) continue;
    }
    final prev = nnMs[i - 1];
    if (prev <= 0) continue;
    final delta = nnMs[i] - prev;
    final isDecel = delta > 0;
    if (isDecel != deceleration) continue;
    final ratio = (nnMs[i] / prev - 1).abs();
    if (ratio > anchorRatioCap) continue;
    anchors.add(i);
  }
  if (anchors.isEmpty) {
    return Metric<PrsaResult>.absent(
      tier: Tier.relative,
      inputs_used: inputs,
      note: 'no valid PRSA anchors ($kind)',
    );
  }

  // Phase-aligned averaging over k in [-l, l-1]  (indices 0..2l-1).
  final profile = List<double>.filled(2 * l, 0);
  for (final a in anchors) {
    for (var k = -l; k < l; k++) {
      profile[k + l] += nnMs[a + k];
    }
  }
  for (var k = 0; k < profile.length; k++) {
    profile[k] /= anchors.length;
  }

  // Quantify with the Haar contrast at the anchor: X(0)+X(1)-X(-1)-X(-2).
  // For l=2: indices are X(-2)=0, X(-1)=1, X(0)=2, X(1)=3.
  final x0 = profile[l]; // k=0
  final x1 = profile[l + 1]; // k=1
  final xm1 = profile[l - 1]; // k=-1
  final xm2 = profile[l - 2]; // k=-2
  final capacity = (x0 + x1 - xm1 - xm2) / 4;

  final conf = (anchors.length / 1000.0).clamp(0.3, 0.95);
  return Metric<PrsaResult>(
    value: PrsaResult(
      capacity: capacity,
      profile: profile,
      anchors: anchors.length,
      kind: kind,
    ),
    confidence: conf,
    tier: Tier.relative,
    inputs_used: inputs,
    // RELATIVE, not HIGH: the same subject read 7.6-9.9 ms on gen4 and 1.7 ms
    // on W5 (header), so the number only trends against the user's own
    // baseline on one device family. Callers must not chart it across a
    // family change.
    note: 'Bauer 2006 PRSA $kind; relative to own baseline on one device '
        'family only',
  );
}
