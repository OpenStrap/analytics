// coach.ts — deterministic coaching engine. NO AI: pure math + rules.
import 'dart:math' as math;
import 'util.dart';

class CoachReadinessComponents {
  final double rhr;
  final double sleep_debt;
  final double sleep_quality;
  const CoachReadinessComponents(this.rhr, this.sleep_debt, this.sleep_quality);
}

class CoachAnomaly {
  final bool signal;
  final String? kind;
  final String? note;
  const CoachAnomaly({required this.signal, this.kind, this.note});
}

class CoachInputs {
  final double? readiness;
  final CoachReadinessComponents? readiness_components;
  final double? resting_hr;
  final double? baseline_rhr;
  final List<double> rhr_recent;
  final double? strain_today;
  final double? acwr;
  final double? sleep_last_min;
  final double sleep_need_min;
  final double sleep_debt_min;
  final double? sleep_efficiency;
  final double? sri;
  final String? fitness_direction;
  final CoachAnomaly? anomaly;
  const CoachInputs({
    required this.readiness,
    this.readiness_components,
    required this.resting_hr,
    required this.baseline_rhr,
    required this.rhr_recent,
    required this.strain_today,
    required this.acwr,
    required this.sleep_last_min,
    required this.sleep_need_min,
    required this.sleep_debt_min,
    required this.sleep_efficiency,
    required this.sri,
    required this.fitness_direction,
    required this.anomaly,
  });
}

class Why {
  final String label;
  final String value;
  final String? detail;
  const Why(this.label, this.value, [this.detail]);
  Map<String, dynamic> toJson() {
    final m = <String, dynamic>{'label': label, 'value': value};
    if (detail != null) m['detail'] = detail;
    return m;
  }
}

class Suggestion {
  final String id;
  final String category;
  final String title;
  final String body;
  final int severity;
  final List<Why> why;
  final String? target;
  const Suggestion({
    required this.id,
    required this.category,
    required this.title,
    required this.body,
    required this.severity,
    required this.why,
    this.target,
  });
  Map<String, dynamic> toJson() {
    final m = <String, dynamic>{
      'id': id,
      'category': category,
      'title': title,
      'body': body,
      'severity': severity,
      'why': why.map((w) => w.toJson()).toList(),
    };
    if (target != null) m['target'] = target;
    return m;
  }
}

class Contributor {
  final String key;
  final String label;
  final double? value;
  final double? baseline;
  final double impact;
  final String note;
  const Contributor({
    required this.key,
    required this.label,
    required this.value,
    required this.baseline,
    required this.impact,
    required this.note,
  });
  Map<String, dynamic> toJson() => {
        'key': key,
        'label': label,
        'value': value,
        'baseline': baseline,
        'impact': impact,
        'note': note,
      };
}

class StrainTarget {
  final double value;
  final double low;
  final double high;
  final String rationale;
  const StrainTarget(this.value, this.low, this.high, this.rationale);
  Map<String, dynamic> toJson() =>
      {'value': value, 'low': low, 'high': high, 'rationale': rationale};
}

class CoachOutput {
  final StrainTarget? strain_target;
  final List<Suggestion> plan;
  final List<Contributor> readiness_contributors;
  final String summary;
  const CoachOutput({
    required this.strain_target,
    required this.plan,
    required this.readiness_contributors,
    required this.summary,
  });
  Map<String, dynamic> toJson() => {
        'strain_target': strain_target?.toJson(),
        'plan': plan.map((p) => p.toJson()).toList(),
        'readiness_contributors':
            readiness_contributors.map((c) => c.toJson()).toList(),
        'summary': summary,
      };
}

double _mean(List<double> xs) => xs.fold<double>(0, (s, v) => s + v) / xs.length;
double _std(List<double> xs) {
  if (xs.length < 2) return 0;
  final m = _mean(xs);
  return math.sqrt(
      xs.fold<double>(0, (s, v) => s + math.pow(v - m, 2)) / xs.length);
}

String _hm(double min) =>
    '${(min / 60).floor()}h ${jsRound(min % 60).toInt()}m';

StrainTarget? _strainTarget(CoachInputs i) {
  if (i.readiness == null) return null;
  double base = 6 + (clamp(i.readiness!, 0, 100) / 100) * 12;
  final reasons = <String>['recovery ${jsRound(i.readiness!).toInt()}'];
  if (i.acwr != null && i.acwr! > 1.3) {
    base = math.min(base, 10);
    reasons.add('load high (ACWR ${i.acwr!.toStringAsFixed(2)})');
  }
  if (i.anomaly?.signal == true) {
    base = math.min(base, 8);
    reasons.add('body-strain signal');
  }
  final v = round(base, 1);
  return StrainTarget(
    v,
    round(math.max(0, v - 2), 1),
    round(math.min(21, v + 2), 1),
    reasons.join(' · '),
  );
}

List<Contributor> _contributors(CoachInputs i) {
  final c = i.readiness_components;
  if (c == null) return [];
  const wRhr = 0.5, wSleepDebt = 0.3, wSleepQuality = 0.2;
  final wSum = wRhr + wSleepDebt + wSleepQuality;
  double pts(double w, double comp) =>
      round(-((w / wSum) * 100 * (1 - comp)), 1);
  String note(double comp, String good, String bad) =>
      comp >= 0.85 ? good : bad;
  return [
    Contributor(
      key: 'rhr',
      label: 'Resting HR',
      value: i.resting_hr,
      baseline: i.baseline_rhr,
      impact: pts(wRhr, c.rhr),
      note: note(c.rhr, 'at/below baseline — supporting recovery',
          'elevated vs baseline — dragging recovery down'),
    ),
    Contributor(
      key: 'sleep_debt',
      label: 'Sleep duration',
      value: i.sleep_last_min,
      baseline: i.sleep_need_min,
      impact: pts(wSleepDebt, c.sleep_debt),
      note: note(c.sleep_debt, 'met your sleep need',
          'short vs your need — costing recovery'),
    ),
    Contributor(
      key: 'sleep_quality',
      label: 'Sleep quality',
      value:
          i.sleep_efficiency == null ? null : round(i.sleep_efficiency! * 100, 0),
      baseline: null,
      impact: pts(wSleepQuality, c.sleep_quality),
      note: note(c.sleep_quality, 'efficient + consistent',
          'fragmented or irregular'),
    ),
  ];
}

List<Suggestion> _rules(CoachInputs i) {
  final out = <Suggestion>[];
  final tgt = _strainTarget(i);
  final recovery = i.readiness;
  final acwrHigh = i.acwr != null && i.acwr! > 1.3;
  final acwrLow = i.acwr != null && i.acwr! < 0.8;

  double? rhrZ;
  if (i.rhr_recent.length >= 3 && i.resting_hr != null) {
    final prior = i.rhr_recent.sublist(0, i.rhr_recent.length - 1);
    final s = _std(prior);
    if (s > 0) rhrZ = (i.resting_hr! - _mean(prior)) / s;
  }

  if (i.anomaly?.signal == true) {
    out.add(Suggestion(
      id: 'health.anomaly',
      category: 'health',
      title: i.anomaly!.kind == 'overtraining'
          ? 'Back off — high load'
          : 'Recovery flag',
      body: (i.anomaly!.note != null && i.anomaly!.note!.isNotEmpty)
          ? i.anomaly!.note!
          : 'Your body is showing strain signals. Prioritise rest, hydration and easy movement today. A signal, not a diagnosis.',
      severity: 3,
      why: [
        if (i.resting_hr != null && i.baseline_rhr != null)
          Why('Resting HR', '${jsRound(i.resting_hr!).toInt()} bpm',
              'baseline ${jsRound(i.baseline_rhr!).toInt()}'),
        if (i.acwr != null) Why('Load (ACWR)', i.acwr!.toStringAsFixed(2)),
      ],
      target: tgt != null ? 'Keep strain ≤ ${_numStr(tgt.high)}' : null,
    ));
  }

  if (acwrHigh && !(i.anomaly?.signal == true)) {
    out.add(Suggestion(
      id: 'load.high',
      category: 'load',
      title: 'Ease off the gas',
      body:
          'Your acute training load is well above your 28-day baseline. Stack an easy or rest day to let it settle before pushing again.',
      severity: 2,
      why: [
        Why('Load (ACWR)', i.acwr!.toStringAsFixed(2), 'optimal 0.8–1.3'),
      ],
      target: tgt != null
          ? 'Target strain ${_numStr(tgt.low)}–${_numStr(tgt.value)}'
          : null,
    ));
  }
  if (acwrLow && (recovery == null || recovery >= 55)) {
    out.add(Suggestion(
      id: 'load.low',
      category: 'activity',
      title: 'Room to push',
      body:
          "You're fresh and your recent load is light. A solid session today moves your fitness forward without overreaching.",
      severity: 1,
      why: [Why('Load (ACWR)', i.acwr!.toStringAsFixed(2), '< 0.8 = detraining zone')],
      target: tgt != null
          ? 'Aim for strain ${_numStr(tgt.value)}–${_numStr(tgt.high)}'
          : null,
    ));
  }

  if (recovery != null && recovery < 40 && !(i.anomaly?.signal == true)) {
    out.add(Suggestion(
      id: 'recovery.low',
      category: 'recovery',
      title: 'Take it easy today',
      body:
          "Recovery is low. Favour light movement, mobility or a walk over hard training, and protect tonight's sleep.",
      severity: 2,
      why: [Why('Recovery', '${jsRound(recovery).toInt()}', '(est.) — not HRV-based')],
      target: tgt != null ? 'Keep strain ≤ ${_numStr(tgt.value)}' : null,
    ));
  }
  if (recovery != null && recovery >= 70 && !acwrHigh && !(i.anomaly?.signal == true)) {
    out.add(Suggestion(
      id: 'recovery.high',
      category: 'activity',
      title: 'Green light',
      body:
          "Recovery is strong — your body's ready for a harder effort if you want it.",
      severity: 0,
      why: [Why('Recovery', '${jsRound(recovery).toInt()}')],
      target: tgt != null ? 'You can target strain up to ${_numStr(tgt.high)}' : null,
    ));
  }
  if (rhrZ != null && rhrZ > 1.5 && !(i.anomaly?.signal == true)) {
    out.add(Suggestion(
      id: 'recovery.rhr_spike',
      category: 'recovery',
      title: 'Resting HR is up',
      body:
          'Your resting HR is notably above your recent norm — often a sign of incomplete recovery, stress, alcohol or oncoming illness. Keep today gentle.',
      severity: 2,
      why: [
        Why('Resting HR', '${jsRound(i.resting_hr!).toInt()} bpm',
            '+${rhrZ.toStringAsFixed(1)}σ vs recent'),
      ],
    ));
  }

  if (i.sleep_debt_min >= 90) {
    final earlier = math.min(90, jsRound(i.sleep_debt_min / 3 / 5) * 5);
    out.add(Suggestion(
      id: 'sleep.debt',
      category: 'sleep',
      title: 'Pay down sleep debt',
      body:
          "You're carrying about ${_hm(i.sleep_debt_min)} of sleep debt. Going to bed ~${earlier.toInt()} min earlier tonight will start closing the gap.",
      severity: 2,
      why: [
        Why('Sleep debt', _hm(i.sleep_debt_min),
            'need ${_hm(i.sleep_need_min)}/night'),
      ],
    ));
  }
  if (i.sri != null && i.sri! < 70) {
    out.add(Suggestion(
      id: 'sleep.consistency',
      category: 'sleep',
      title: 'Anchor your sleep timing',
      body:
          'Your sleep schedule is inconsistent. Going to bed and waking within the same ~30-min window — even on weekends — is one of the biggest levers on recovery.',
      severity: 1,
      why: [Why('Sleep regularity', '${jsRound(i.sri!).toInt()}/100', 'higher = steadier')],
    ));
  }
  if (i.sleep_last_min != null &&
      i.sleep_efficiency != null &&
      i.sleep_efficiency! < 0.8 &&
      i.sleep_last_min! > 120) {
    out.add(Suggestion(
      id: 'sleep.efficiency',
      category: 'sleep',
      title: 'Restless night',
      body:
          'You spent a good chunk of last night awake in bed. A cooler, darker room and no screens before bed usually lift efficiency.',
      severity: 1,
      why: [
        Why('Sleep efficiency', '${jsRound(i.sleep_efficiency! * 100).toInt()}%',
            'target ≥ 85%'),
      ],
    ));
  }

  return out;
}

String _narrative(CoachInputs i) {
  final parts = <String>[];
  if (i.readiness != null) {
    final w = i.readiness! >= 70
        ? 'Strong'
        : i.readiness! >= 40
            ? 'Moderate'
            : 'Low';
    parts.add('$w recovery');
  }
  if (i.sleep_last_min != null && i.sleep_last_min! > 0) {
    parts.add('slept ${_hm(i.sleep_last_min!)}');
  }
  if (i.acwr != null) {
    final w = i.acwr! > 1.3
        ? 'high load'
        : i.acwr! < 0.8
            ? 'light load'
            : 'balanced load';
    parts.add(w);
  }
  return parts.isNotEmpty
      ? parts.join(' · ')
      : 'Wear your strap and sync to see your daily read.';
}

CoachOutput buildCoach(CoachInputs i) {
  final ruled = _rules(i);
  // stable sort by severity desc (JS Array.sort is stable).
  final indexed = <List<dynamic>>[];
  for (var k = 0; k < ruled.length; k++) {
    indexed.add([ruled[k], k]);
  }
  indexed.sort((a, b) {
    final s = (b[0] as Suggestion).severity - (a[0] as Suggestion).severity;
    if (s != 0) return s;
    return (a[1] as int) - (b[1] as int);
  });
  final plan = indexed
      .map((e) => e[0] as Suggestion)
      .take(5)
      .toList();
  return CoachOutput(
    strain_target: _strainTarget(i),
    plan: plan,
    readiness_contributors: _contributors(i),
    summary: _narrative(i),
  );
}

// JS number-to-string for template literals (no trailing .0 for integers).
String _numStr(double v) =>
    v == v.truncateToDouble() ? v.toInt().toString() : v.toString();
