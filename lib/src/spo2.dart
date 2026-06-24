// §SpO₂ — RELATIVE blood-oxygen index + overnight desaturation screen.
import 'dart:math' as math;
import 'types.dart';
import 'util.dart';

const _minMinutes = 30;
bool _plausible(double r) => r > 0.4 && r < 1.5;
const _cvFloor = 0.08;

class Spo2Result {
  final double? index;
  final double? night_ratio;
  final double confidence;
  final String tier;
  final List<String> inputs_used;
  final List<Driver>? drivers;
  const Spo2Result({
    required this.index,
    required this.night_ratio,
    required this.confidence,
    required this.tier,
    required this.inputs_used,
    this.drivers,
  });
  Map<String, dynamic> toJson() {
    final m = <String, dynamic>{
      'index': index,
      'night_ratio': night_ratio,
      'confidence': confidence,
      'tier': tier,
      'inputs_used': inputs_used,
    };
    if (drivers != null) m['drivers'] = drivers!.map((d) => d.toJson()).toList();
    return m;
  }
}

Spo2Result calcSpo2Index(List<double> ratios, double? baselineRatio) {
  final r = ratios.where(_plausible).toList();
  Spo2Result none([double conf = 0]) => Spo2Result(
        index: null,
        night_ratio: null,
        confidence: conf,
        tier: 'RELATIVE',
        inputs_used: const [],
      );
  if (r.length < _minMinutes) return none();

  final med = median(r);
  if (med == null) return none();
  final nightR = round(med, 4);
  final m = mean(r);
  final cv = m > 0 ? stddev(r) / m : 1.0;
  final conf = round(
      clamp(math.min(r.length / 180, 1.0) * math.max(0, 1 - cv / _cvFloor), 0, 1),
      3);
  const inputs_used = ['spo2_red_raw', 'spo2_ir_raw'];
  final ref = const MetricRef(metric: 'spo2', scale: 'day');

  if (baselineRatio == null || !(baselineRatio > 0)) {
    return Spo2Result(
      index: null,
      night_ratio: nightR,
      confidence: round(conf * 0.5, 3),
      tier: 'RELATIVE',
      inputs_used: inputs_used,
    );
  }

  final index = round(((baselineRatio - nightR) / baselineRatio) * 100, 2);
  final drivers = <Driver>[
    Driver(
      label: 'Blood-oxygen vs baseline',
      contribution: index,
      detail: 'R $nightR vs baseline ${round(baselineRatio, 4)}',
      ref: ref,
    ),
  ];
  return Spo2Result(
    index: index,
    night_ratio: nightR,
    confidence: conf,
    tier: 'RELATIVE',
    inputs_used: inputs_used,
    drivers: drivers,
  );
}

const _desatRel = 0.04;
const _desatMinutes = 1;

class DesaturationResult {
  final double events;
  final double? odi;
  final double? deepest_pct;
  final String note;
  final double confidence;
  final String tier;
  final List<String> inputs_used;
  final List<Driver>? drivers;
  const DesaturationResult({
    required this.events,
    required this.odi,
    required this.deepest_pct,
    required this.note,
    required this.confidence,
    required this.tier,
    required this.inputs_used,
    this.drivers,
  });
  Map<String, dynamic> toJson() {
    final m = <String, dynamic>{
      'events': events,
      'odi': odi,
      'deepest_pct': deepest_pct,
      'note': note,
      'confidence': confidence,
      'tier': tier,
      'inputs_used': inputs_used,
    };
    if (drivers != null) m['drivers'] = drivers!.map((d) => d.toJson()).toList();
    return m;
  }
}

DesaturationResult calcDesaturation(List<double> ratios, double? baselineRatio) {
  const note = 'a screen, not a diagnosis';
  final r = ratios.where(_plausible).toList();
  DesaturationResult none([double conf = 0]) => DesaturationResult(
        events: 0,
        odi: null,
        deepest_pct: null,
        note: note,
        confidence: conf,
        tier: 'RELATIVE',
        inputs_used: const [],
      );
  if (r.length < _minMinutes ||
      baselineRatio == null ||
      !(baselineRatio > 0)) {
    return none();
  }

  final thresh = baselineRatio * (1 + _desatRel);
  double events = 0, run = 0, deepest = 0;
  for (final v in r) {
    if (v >= thresh) {
      run++;
      final dipPct = ((v - baselineRatio) / baselineRatio) * 100;
      if (dipPct > deepest) deepest = dipPct;
      if (run == _desatMinutes) events++;
    } else {
      run = 0;
    }
  }
  final hours = math.max(0.5, r.length / 60);
  final m = mean(r);
  final cv = m > 0 ? stddev(r) / m : 1.0;
  final conf = round(
      clamp(math.min(r.length / 180, 1.0) * math.max(0, 1 - cv / _cvFloor), 0, 1),
      3);
  final drivers = <Driver>[
    Driver(
      label: 'Desaturation dips',
      contribution: events,
      detail: '${events.toInt()} dips (${round(events / hours, 1)}/h)',
      ref: const MetricRef(metric: 'spo2', scale: 'day'),
    ),
  ];
  return DesaturationResult(
    events: events,
    odi: round(events / hours, 1),
    deepest_pct: round(deepest, 1),
    note: note,
    confidence: conf,
    tier: 'RELATIVE',
    inputs_used: const ['spo2_red_raw', 'spo2_ir_raw'],
    drivers: drivers,
  );
}
