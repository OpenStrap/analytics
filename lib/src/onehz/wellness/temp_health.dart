// WELLNESS — relative skin-temp health signals (illness flag + menstrual).
//
// Both operate on the NIGHTLY-MEAN RELATIVE skin-temp (z-scored or raw ADC).
// NEVER absolute °C / fever.
//
// 1. Skin-temp z-score illness flag (Smarr 2020) — nightly relative-temp z vs a
//    trailing personal baseline; flags a sustained elevation. MUST be
//    cycle-aware: the luteal phase raises distal temp ~0.3 °C ≈ a fever-sized
//    deviation, so when the night is luteal we DOWN-CONFIDENCE and tag the
//    confound instead of crying "illness".
//
// 2. Menstrual 3-over-6 / coverline (Shilaih 2018) — classic fertility-awareness
//    rule on nightly temp: a coverline = max of the prior 6 nights; ovulation is
//    CONFIRMED retrospectively when 3 consecutive nights exceed the coverline by
//    a threshold. This is CONFIRMATION ONLY — never forward prediction.

import '../types.dart';
import '../util.dart';
import '../foundations/baseline.dart';

// ---------------------------------------------------------------------------
// 1. Skin-temp z-score illness flag (cycle-aware)
// ---------------------------------------------------------------------------

enum TempFlag { normal, elevated, lutealConfound }

/// Required minimum valid baseline nights before a skin-temp deviation z is
/// computed.
const int tempIllnessMinBaseline = 7;

class TempIllnessDay {
  final String date;
  final TempFlag flag;
  final double? z; // robust z of tonight's temp vs trailing baseline
  final bool luteal;
  final double confidence; // down-weighted in luteal phase

  /// Machine-readable "need_baseline:have=H,need=N" note set on nights that
  /// could not be evaluated for lack of baseline. Null when evaluated.
  final String? need;
  const TempIllnessDay(this.date, this.flag, this.z, this.luteal,
      this.confidence, {this.need});
  Map<String, dynamic> toJson() => {
        'date': date,
        'flag': flag.name,
        if (z != null) 'z': round6(z!),
        'luteal': luteal,
        'confidence': round6(confidence),
        if (need != null) 'note': need,
      };
}

/// Nightly relative skin-temp z-score illness flag, cycle-aware.
///
/// [dates] labels; [nightlyTemp] nightly-mean RELATIVE temp ADC (null = missing
/// night); [luteal] OPTIONAL per-night luteal-phase flag (true => suppress).
/// [baselineDays] trailing robust-baseline window; [zThresh] flag elevation
/// above this robust z; [persistDays] consecutive elevated nights required.
///
/// HONESTY: when MAD baseline is degenerate (quantized/flat) we report null z
/// and stay `normal` — we never invent a deviation. In luteal nights an
/// elevation is tagged `lutealConfound` (not `elevated`) and confidence is
/// halved, because luteal warming mimics fever on a relative sensor.
List<TempIllnessDay> tempIllnessFlag(
  List<String> dates,
  List<double?> nightlyTemp, {
  List<bool>? luteal,
  int baselineDays = 21,
  double zThresh = 2.0,
  int persistDays = 2,
  int minBaseline = tempIllnessMinBaseline,
}) {
  final n = nightlyTemp.length;
  final out = <TempIllnessDay>[];
  var elevatedRun = 0;
  for (var i = 0; i < n; i++) {
    final t = nightlyTemp[i];
    final lut = (luteal != null && i < luteal.length) ? luteal[i] : false;
    final lo = i - baselineDays < 0 ? 0 : i - baselineDays;
    final window = <double>[];
    for (var j = lo; j < i; j++) {
      final v = nightlyTemp[j];
      if (v != null) window.add(v);
    }
    if (t == null || window.length < minBaseline) {
      // RHR-style need_baseline note when tonight HAS a temp but the baseline
      // is too short (no fabricated deviation).
      final need = t != null
          ? needBaselineNote(have: window.length, need: minBaseline)
          : null;
      out.add(
          TempIllnessDay(dates[i], TempFlag.normal, null, lut, 0.0, need: need));
      elevatedRun = 0;
      continue;
    }
    final base = robustBaseline(window, minValid: minBaseline);
    final zz = base.modZ(t); // null if MAD degenerate
    if (zz == null) {
      // Can't standardize honestly -> stay normal, confidence 0.
      out.add(TempIllnessDay(dates[i], TempFlag.normal, null, lut, 0.0));
      elevatedRun = 0;
      continue;
    }
    final elevated = zz >= zThresh;
    if (elevated) {
      elevatedRun++;
    } else {
      elevatedRun = 0;
    }
    TempFlag flag;
    double conf;
    if (!elevated || elevatedRun < persistDays) {
      flag = TempFlag.normal;
      conf = elevated ? 0.3 : 0.6; // single elevated night = low confidence
    } else if (lut) {
      // Sustained elevation but luteal: it is the dominant confound.
      flag = TempFlag.lutealConfound;
      conf = 0.35; // honest: cannot separate luteal warming from illness
    } else {
      flag = TempFlag.elevated;
      conf = 0.7;
    }
    out.add(TempIllnessDay(dates[i], flag, zz, lut, conf));
  }
  return out;
}

// ---------------------------------------------------------------------------
// 2. Menstrual 3-over-6 / coverline
// ---------------------------------------------------------------------------

class OvulationEvent {
  final int index; // index of the 3rd confirming night (confirmation day)
  final String date;
  final double coverline; // the coverline that was crossed
  final int estimatedOvulationIndex; // ~the night BEFORE the shift (retro)
  const OvulationEvent(
      this.index, this.date, this.coverline, this.estimatedOvulationIndex);
  Map<String, dynamic> toJson() => {
        'confirmation_index': index,
        'date': date,
        'coverline': round6(coverline),
        'estimated_ovulation_index': estimatedOvulationIndex,
      };
}

/// Retrospective ovulation CONFIRMATION via the 3-over-6 coverline rule on
/// nightly-mean relative temp.
///
/// For each candidate night i: the coverline = max of the prior [lookback]
/// nights; if night i and the next ([confirm]-1) nights all exceed
/// (coverline + [threshold]) ADC counts, ovulation is confirmed, estimated at
/// the night just before the rise (i-1).
///
/// HONESTY: confirmation ONLY — this NEVER predicts a future ovulation. Returns
/// all detected events over the series. `relative` tier (ADC counts, no °C).
Metric<List<OvulationEvent>> menstrualCoverline(
  List<String> dates,
  List<double?> nightlyTemp, {
  int lookback = 6,
  int confirm = 3,
  double threshold = 1.0,
}) {
  const inputs = ['nightly_skin_temp_adc'];
  final n = nightlyTemp.length;
  if (n < lookback + confirm) {
    return Metric<List<OvulationEvent>>.absent(
      tier: Tier.relative,
      inputs_used: inputs,
      note: 'too few nights for a 3-over-6 coverline confirmation',
    );
  }
  final events = <OvulationEvent>[];
  var i = lookback;
  while (i <= n - confirm) {
    // Coverline = max of prior `lookback` VALID nights.
    final prior = <double>[];
    for (var j = i - lookback; j < i; j++) {
      final v = nightlyTemp[j];
      if (v != null) prior.add(v);
    }
    if (prior.length < lookback) {
      i++;
      continue;
    }
    final coverline = prior.reduce((a, b) => a > b ? a : b);
    // Need `confirm` consecutive valid nights all above coverline + threshold.
    var ok = true;
    for (var k = 0; k < confirm; k++) {
      final v = nightlyTemp[i + k];
      if (v == null || v < coverline + threshold) {
        ok = false;
        break;
      }
    }
    if (ok) {
      final confIdx = i + confirm - 1;
      events.add(OvulationEvent(confIdx, dates[confIdx], coverline, i - 1));
      // Jump past this luteal rise to avoid re-detecting the plateau.
      i += confirm;
    } else {
      i++;
    }
  }
  return Metric<List<OvulationEvent>>(
    value: events,
    confidence: events.isEmpty ? 0.4 : 0.6,
    tier: Tier.relative,
    inputs_used: inputs,
    note: 'Retrospective ovulation CONFIRMATION only (3-over-6 coverline on '
        'RELATIVE temp ADC). NEVER a forward fertility prediction.',
  );
}
