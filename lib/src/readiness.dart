// §10 Anomaly signal (RHR-elevation rule).
import 'dart:math' as math;
import 'types.dart';
import 'util.dart';

class AnomalyInputs {
  final List<double> recent_rhr;
  final double? skin_temp;
  final double? sleep_efficiency;
  final double? baseline_sleep_efficiency;
  const AnomalyInputs({
    required this.recent_rhr,
    this.skin_temp,
    this.sleep_efficiency,
    this.baseline_sleep_efficiency,
  });
}

class AnomalyResult {
  final bool signal;
  final List<String> triggers;
  final String note;
  final double confidence;
  final String tier;
  final List<String> inputs_used;
  const AnomalyResult({
    required this.signal,
    required this.triggers,
    required this.note,
    required this.confidence,
    required this.tier,
    required this.inputs_used,
  });
  Map<String, dynamic> toJson() => {
        'signal': signal,
        'triggers': triggers,
        'note': note,
        'confidence': confidence,
        'tier': tier,
        'inputs_used': inputs_used,
      };
}

AnomalyResult calcAnomaly(AnomalyInputs inputs, Baseline baseline,
    {String? cyclePhase}) {
  String note = 'signal, not a diagnosis';
  final triggers = <String>[];
  final used = <String>[];

  final rhrThreshold = baseline.resting_hr! * 1.07;

  int consecutive = 0;
  if (inputs.recent_rhr.isNotEmpty) {
    used.add('recent_rhr');
    used.add('baseline.resting_hr');
    for (var i = inputs.recent_rhr.length - 1; i >= 0; i--) {
      if (inputs.recent_rhr[i] >= rhrThreshold) {
        consecutive++;
      } else {
        break;
      }
    }
  }
  final ruleA = consecutive >= 2;
  if (ruleA) triggers.add('rhr_elevated_2d');

  final double? latestRhr = inputs.recent_rhr.isNotEmpty
      ? inputs.recent_rhr[inputs.recent_rhr.length - 1]
      : null;
  final rhrUp = latestRhr != null && latestRhr >= rhrThreshold;
  bool tempUp = false;
  if (inputs.skin_temp != null && baseline.skin_temp != null) {
    used.add('skin_temp');
    used.add('baseline.skin_temp');
    tempUp = inputs.skin_temp! - baseline.skin_temp! > 0.5;
  }
  bool effDown = false;
  if (inputs.sleep_efficiency != null &&
      inputs.baseline_sleep_efficiency != null) {
    used.add('sleep_efficiency');
    used.add('baseline_sleep_efficiency');
    effDown = inputs.sleep_efficiency! < inputs.baseline_sleep_efficiency!;
  }
  final ruleB = rhrUp && tempUp && effDown;
  if (ruleB) triggers.add('rhr_temp_efficiency');

  final inCyclePhase =
      cyclePhase == 'luteal' || cyclePhase == 'menstruation';
  final signal = (ruleA && !inCyclePhase) || ruleB;
  if (ruleA && inCyclePhase && !ruleB) {
    note =
        'signal, not a diagnosis (an elevated resting HR can be expected in this phase of your cycle)';
  }

  final evaluable = [
    inputs.recent_rhr.length >= 2,
    inputs.skin_temp != null && baseline.skin_temp != null,
    inputs.sleep_efficiency != null &&
        inputs.baseline_sleep_efficiency != null,
  ].where((b) => b).length;
  final confidence = math.min(0.5, (evaluable / 3) * 0.5);

  return AnomalyResult(
    signal: signal,
    triggers: triggers,
    note: note,
    confidence: round(confidence, 4),
    tier: 'ESTIMATE',
    inputs_used: _dedupe(used),
  );
}

List<String> _dedupe(List<String> xs) {
  final seen = <String>{};
  final out = <String>[];
  for (final x in xs) {
    if (seen.add(x)) out.add(x);
  }
  return out;
}
