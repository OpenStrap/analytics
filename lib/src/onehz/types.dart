// 1 Hz-native analytics family — input/output types.
//
// Independent of the minute-resolution family in lib/src/*.dart. Models the
// always-on 1 Hz substrate described in
// docs/ALGORITHM_CATALOG_1HZ.md:
//   - beat-to-beat RR (0–4 beats/s, ms)
//   - 1 Hz HR
//   - 1 Hz tri-axial accel (one gravity vector / s)
//   - relative-ADC channels (skin-temp / SpO2 red+IR / ambient light)
//
// HONESTY CEILINGS encoded here:
//   * PRV not ECG-HRV — RR is pulse-derived.
//   * Relative signals carry no absolute %/°C — ADC counts only.
//   * Absent input => null + confidence 0, NEVER a heuristic fallback.
//   * Every Metric carries tier + confidence + inputs_used.

import 'util.dart' show round6;

/// MACHINE-READABLE "needs more baseline" convention (single source of truth).
///
/// A baseline-relative metric (recovery composite, lnRMSSD readiness, illness
/// CUSUM, multivariate anomaly, skin-temp deviation) is meaningless until it has
/// enough trailing history. When the supplied history is shorter than the
/// metric's REQUIRED MINIMUM, the metric MUST return an ABSENT Metric (value
/// null, confidence 0) whose `note` is EXACTLY:
///
///     need_baseline:have=<H>,need=<N>
///
/// where <H> is the count of valid history points actually supplied and <N> is
/// the required minimum (exposed per-metric as a public `*MinNights`/`*MinBaseline`
/// constant so the edge can render "Need N−H more nights"). NEVER fabricate a
/// value or a placeholder number. Build the note with [needBaselineNote].
String needBaselineNote({required int have, required int need}) =>
    'need_baseline:have=$have,need=$need';

/// Confidence/quality tier of a published method on our substrate.
class Tier {
  /// Directly measured / definitional (e.g. RR count, raw ADC).
  static const String auth = 'AUTH';

  /// Strong literature support on our substrate (e.g. long-window HRV, RHR).
  static const String high = 'HIGH';

  /// Published but estimate-grade on a wrist 1 Hz signal (e.g. TRIMP).
  static const String estimate = 'ESTIMATE';

  /// Relative-only — direction/percentile, never an absolute unit.
  static const String relative = 'RELATIVE';

  static const Set<String> all = {auth, high, estimate, relative};
}

/// A single ranked contributor to a metric (for glass-box narratives).
class Driver {
  final String label;
  final double contribution; // signed standardized contribution
  final String? detail;
  const Driver(this.label, this.contribution, {this.detail});
  Map<String, dynamic> toJson() {
    final m = <String, dynamic>{
      'label': label,
      'contribution': round6(contribution),
    };
    if (detail != null) m['detail'] = detail;
    return m;
  }
}

/// Honest metric wrapper.
///
/// `value == null` means the inputs to compute this metric were absent or
/// insufficient. In that case `confidence` MUST be 0 and `toJson` emits a
/// `"—"` placeholder for `value` (never a fabricated number).
class Metric<T> {
  final T? value;
  final double confidence; // 0..1
  final String tier; // one of Tier.*
  final List<String> inputs_used;
  final List<Driver>? drivers;
  final String? note;

  const Metric({
    required this.value,
    required this.confidence,
    required this.tier,
    required this.inputs_used,
    this.drivers,
    this.note,
  });

  /// Absent metric: no data. Confidence forced to 0.
  const Metric.absent({
    required this.tier,
    required this.inputs_used,
    this.note,
  })  : value = null,
        confidence = 0,
        drivers = null;

  bool get present => value != null;

  /// JSON encodes `value` via [encode] (defaults to the value itself for
  /// numerics/maps). When absent, emits the honest `"—"` placeholder.
  Map<String, dynamic> toJson([Object? Function(T v)? encode]) {
    final m = <String, dynamic>{};
    if (value == null) {
      m['value'] = '—';
    } else {
      m['value'] = encode != null ? encode(value as T) : value;
    }
    m['confidence'] = round6(confidence);
    m['tier'] = tier;
    m['inputs_used'] = inputs_used;
    if (drivers != null) m['drivers'] = drivers!.map((d) => d.toJson()).toList();
    if (note != null) m['note'] = note;
    return m;
  }
}

/// A beat-to-beat RR (inter-beat-interval) series.
///
/// `tsMs[i]` is the wall-clock time (ms) at which beat i's interval was
/// observed (the END of the RR interval). `rrMs[i]` is that interval in ms.
/// Pulse-derived — this is PRV, not ECG HRV.
class RrSeries {
  final List<double> tsMs;
  final List<double> rrMs;
  const RrSeries(this.tsMs, this.rrMs)
      : assert(tsMs.length == rrMs.length);

  int get length => rrMs.length;
  bool get isEmpty => rrMs.isEmpty;

  /// Reconstruct cumulative beat-occurrence times (ms) from RR intervals,
  /// anchored at [t0Ms]. Used by Lomb-Scargle/PRSA on native beat times.
  List<double> beatTimesMs([double t0Ms = 0]) {
    final out = <double>[];
    var t = t0Ms;
    for (final rr in rrMs) {
      t += rr;
      out.add(t);
    }
    return out;
  }
}

/// 1 Hz heart-rate sample. `hr == 0` means OFF-SKIN (never bradycardia).
class HrSample {
  final double tsMs;
  final double hr; // bpm; 0 = off-skin
  const HrSample(this.tsMs, this.hr);
  bool get valid => hr > 0;
}

/// 1 Hz tri-axial accel sample (gravity vector, g).
class AccelSample {
  final double tsMs;
  final double x;
  final double y;
  final double z;
  final bool valid;
  const AccelSample(this.tsMs, this.x, this.y, this.z, {this.valid = true});
}

/// A relative-ADC sample (skin-temp / SpO2 channel / ambient). Carries NO
/// absolute unit — only the raw count + a validity/contact flag.
class AdcSample {
  final double tsMs;
  final double adc;
  final bool valid;
  const AdcSample(this.tsMs, this.adc, {this.valid = true});
}

/// One nightly aggregate row, the unit the 24/7 stack reasons over.
/// All fields nullable — a missing night contributes nothing (no fabrication).
class NightlyRecord {
  final String date; // display-only label (edge-supplied), wake-to-wake day
  final double? rhr; // nocturnal resting HR (bpm)
  final double? lnRmssd; // ln(RMSSD ms)
  final double? rmssd; // RMSSD (ms)
  final double? sdnn; // SDNN (ms)
  final double? skinTempZ; // relative skin-temp deviation (z), unitless
  final double? respRate; // breaths/min
  final double? coverage; // 0..1 valid-data fraction for the night
  const NightlyRecord(
    this.date, {
    this.rhr,
    this.lnRmssd,
    this.rmssd,
    this.sdnn,
    this.skinTempZ,
    this.respRate,
    this.coverage,
  });
}

/// Sex constant for Banister TRIMP.
enum Sex { male, female }
