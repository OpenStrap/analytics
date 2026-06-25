// CLINICAL TIER-1 — NightSignal / CUSUM illness flag on nightly RHR.
//
// Alavi 2022 (NightSignal) + Mishra 2020 (RHR-AD CUSUM). A deterministic finite
// state machine on the nightly resting-HR series:
//   * 28-day ROBUST baseline (median + MAD) over the trailing window.
//   * One-sided upper CUSUM accumulator on the standardized RHR deviation with
//     a slack k and a decision threshold h (designed for a target ARL).
//   * State ladder: green -> yellow (CUSUM crosses h) -> red (yellow persists
//     ≥ persistDays). Recovers to green when CUSUM resets to 0.
//
// HONESTY: an elevated-RHR night has many causes (alcohol, late meal, hot room,
// luteal phase, illness). This flag reports a STATE ("elevated, sustained"),
// not a diagnosis — the human layer must gate it behind ≥2 of {RHR↑,temp↑,
// resp↑} + cycle-awareness before ever saying "illness".

import 'dart:math' as math;
import '../types.dart' show needBaselineNote;
import '../util.dart';

enum IllnessState { green, yellow, red }

/// Required minimum valid baseline nights before the CUSUM can flag.
const int illnessCusumMinBaseline = 7;

class IllnessDay {
  final String date;
  final IllnessState state;
  final double? cusum; // accumulator value this night (null if no baseline)
  final double? z; // standardized RHR deviation (modified-z)

  /// Machine-readable "need_baseline:have=H,need=N" note set on nights that
  /// could not be evaluated because the trailing baseline is too short. Null on
  /// nights that were honestly evaluated (or had no RHR tonight at all).
  final String? need;
  const IllnessDay(this.date, this.state, this.cusum, this.z, {this.need});
  Map<String, dynamic> toJson() => {
        'date': date,
        'state': state.name,
        if (cusum != null) 'cusum': round6(cusum!),
        if (z != null) 'z': round6(z!),
        if (need != null) 'note': need,
      };
}

/// Run the CUSUM/NightSignal FSM over a time-ordered nightly RHR series.
///
/// [dates] display labels, [rhr] nightly resting HR (bpm), same length.
/// [baselineDays] trailing robust-baseline window (default 28).
/// [k] CUSUM slack in z-units (reference value, default 0.5).
/// [h] CUSUM decision threshold (default 4.0 — conservative, low false-alarm).
/// [persistDays] yellow nights required before escalating to red.
///
/// Returns a per-night list. Nights before [minBaseline] valid history are
/// green with null cusum (we never flag without a baseline — no fabrication).
List<IllnessDay> illnessCusum(
  List<String> dates,
  List<double?> rhr, {
  int baselineDays = 28,
  double k = 0.5,
  double h = 4.0,
  int persistDays = 2,
  int minBaseline = illnessCusumMinBaseline,
  double returnZ = 0.5,
  int recoverDays = 2,
}) {
  final n = rhr.length;
  final out = <IllnessDay>[];
  var cusum = 0.0;
  var yellowRun = 0;
  var normalRun = 0;
  for (var i = 0; i < n; i++) {
    final r = rhr[i];
    // Robust baseline from the trailing window (valid nights only).
    final lo = math.max(0, i - baselineDays);
    final window = <double>[];
    for (var j = lo; j < i; j++) {
      final v = rhr[j];
      if (v != null) window.add(v);
    }
    if (r == null || window.length < minBaseline) {
      // No data tonight or no baseline yet: hold green, don't accumulate.
      // When RHR IS present but the baseline is too short, attach a
      // machine-readable need_baseline note so the edge can say "Need N more".
      final need = r != null
          ? needBaselineNote(have: window.length, need: minBaseline)
          : null;
      out.add(IllnessDay(dates[i], IllnessState.green, null, null, need: need));
      // A missing night neither advances nor resets the run.
      continue;
    }
    final med = median(window)!;
    var scale = mad(window) ?? 0;
    if (scale <= 0) {
      // Quantized/constant baseline: fall back to a small physiological floor
      // (1 bpm) so we can still standardize, but flag low confidence by never
      // letting tiny noise trip the alarm.
      scale = math.max(1.0, (stddev(window) ?? 1.0));
    }
    final z = (r - med) / scale;
    // One-sided upper CUSUM on elevation (RHR up = potential illness).
    cusum = math.max(0, cusum + (z - k));

    // NightSignal-style recovery: once the RHR is back within the normal band
    // (z below returnZ) for [recoverDays] consecutive nights, clear the
    // accumulator. This stops a brief spike from latching the alarm "red" for
    // weeks (the bare one-sided CUSUM only bleeds off at rate k) while keeping
    // the alarm responsive — the FSM, not the raw CUSUM, governs the state.
    if (z < returnZ) {
      normalRun++;
      if (normalRun >= recoverDays) cusum = 0;
    } else {
      normalRun = 0;
    }

    IllnessState state;
    if (cusum > h) {
      yellowRun++;
      state = yellowRun >= persistDays ? IllnessState.red : IllnessState.yellow;
    } else {
      yellowRun = 0;
      state = IllnessState.green;
      // Soft reset toward 0 already handled by max(0, …).
    }
    out.add(IllnessDay(dates[i], state, cusum, z));
  }
  return out;
}
