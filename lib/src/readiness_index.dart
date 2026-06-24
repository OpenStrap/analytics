// §Composite Readiness — weighted HRV + sleep blend.
import 'types.dart';
import 'util.dart';

class ReadinessInputs {
  final double? recovery;
  final double? sleepDurationMin;
  final double? sleepNeedMin;
  final double? dipPct;
  final double? sleepStress;
  const ReadinessInputs({
    this.recovery,
    this.sleepDurationMin,
    this.sleepNeedMin,
    this.dipPct,
    this.sleepStress,
  });
}

class ReadinessIndexResult {
  final double? score;
  final Map<String, double?> components;
  final String note;
  final double confidence;
  final String tier;
  final List<String> inputs_used;
  final List<Driver>? drivers;
  const ReadinessIndexResult({
    required this.score,
    required this.components,
    required this.note,
    required this.confidence,
    required this.tier,
    required this.inputs_used,
    this.drivers,
  });
  Map<String, dynamic> toJson() {
    final m = <String, dynamic>{
      'score': score,
      'components': components,
      'note': note,
      'confidence': confidence,
      'tier': tier,
      'inputs_used': inputs_used,
    };
    if (drivers != null) m['drivers'] = drivers!.map((d) => d.toJson()).toList();
    return m;
  }
}

const _w = {'recovery': 0.5, 'sleep': 0.2, 'dip': 0.15, 'arousal': 0.15};

ReadinessIndexResult calcReadinessIndex(ReadinessInputs inp) {
  final components = <String, double?>{
    'recovery': inp.recovery,
    'sleep': (inp.sleepDurationMin != null &&
            inp.sleepNeedMin != null &&
            inp.sleepNeedMin! > 0)
        ? round(clamp((inp.sleepDurationMin! / inp.sleepNeedMin!) * 100, 0, 100), 0)
        : null,
    'dip': inp.dipPct != null
        ? round(clamp((inp.dipPct! / 0.10) * 100, 0, 100), 0)
        : null,
    'arousal': inp.sleepStress != null
        ? round(clamp(100 - inp.sleepStress!, 0, 100), 0)
        : null,
  };

  if (components['recovery'] == null) {
    return ReadinessIndexResult(
      score: null,
      components: components,
      note: 'Building baseline — needs nocturnal HRV',
      confidence: 0,
      tier: 'ESTIMATE',
      inputs_used: const [],
    );
  }

  double wsum = 0, acc = 0;
  final used = <String>[];
  final drivers = <Driver>[];
  void add(String key, double w, String label) {
    final v = components[key];
    if (v == null) return;
    wsum += w;
    acc += w * v;
    used.add(key);
    drivers.add(Driver(
      label: label,
      contribution: round((w * (v - 50)) / 50, 3),
      detail: '${_fmtInt(v)}/100',
      ref: MetricRef(
          metric: key == 'recovery'
              ? 'recovery'
              : key == 'sleep'
                  ? 'sleep'
                  : 'hrv',
          scale: 'day'),
    ));
  }

  add('recovery', _w['recovery']!, 'HRV recovery');
  add('sleep', _w['sleep']!, 'Sleep vs need');
  add('dip', _w['dip']!, 'Nocturnal HR dip');
  add('arousal', _w['arousal']!, 'Sleep calmness');

  final double? score = wsum > 0 ? jsRound(acc / wsum) : null;
  drivers.sort((a, b) => b.contribution.abs().compareTo(a.contribution.abs()));

  return ReadinessIndexResult(
    score: score,
    components: components,
    note: 'Composite (HRV + sleep) — a guide, not a diagnosis',
    confidence: round(clamp(wsum, 0, 1), 3),
    tier: 'ESTIMATE',
    inputs_used: used,
    drivers: drivers,
  );
}

String _fmtInt(double v) =>
    v == v.truncateToDouble() ? v.toInt().toString() : v.toString();
