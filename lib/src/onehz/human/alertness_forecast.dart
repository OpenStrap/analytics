// HUMAN — when today is likely to get hard (MIND-11).
//
// Åkerstedt & Folkard's Three-Process Model of alertness regulation: a
// homeostatic process S that falls exponentially with time awake and recovers
// exponentially across sleep, a circadian process C anchored to clock time, and
// a sleep-inertia term W that decays over the first hour after waking.
// Alertness = S + C − W.
//
// WHAT THIS IS. A MODEL PREDICTION, not a measurement. Nothing on this band
// measures alertness — there is no reaction time, no KSS, no eye tracking, no
// EEG. The Three-Process parameters are fitted to GROUP data from laboratory
// sleep-restriction studies, so what comes out is *the average person's*
// alertness given *your* sleep timing. Individual differences in sleep need and
// circadian amplitude are large, and this model cannot see yours.
//
// THEREFORE: NO NUMERIC SCORE, ANYWHERE. The output is a SHAPE — a unitless
// curve normalised inside its own day, good for drawing and for nothing else —
// plus a NAMED trough window. A KSS-like number is the thing that gets
// screenshotted and quoted back at us, so there isn't one, and there must never
// be one bolted on: not a 0-100, not a letter, not "alertness 42".
//
// TWO GATES, and they are the feature:
//   1. It ABSTAINS on a missing or unjudged night. It never assumes eight
//      hours — assuming the input is how a model prediction becomes a
//      fabrication with a chart around it.
//   2. The SAFETY REFUSAL is explicit and belongs on the card: this is not a
//      fitness-to-drive assessment, not a shift-safety tool, and it never says
//      you are impaired.

import 'dart:math' as math;

import '../types.dart';
import '../util.dart';

/// A daytime sleep, in local clock hours since midnight of the wake day.
class DaytimeSleepWindow {
  final double startHour;
  final double endHour;
  const DaytimeSleepWindow(this.startHour, this.endHour);
}

/// The forecast: a drawable shape and the window it bottoms out in.
class AlertnessForecast {
  /// Local clock hour of the first point of [shape].
  final double startHour;

  /// Hours between consecutive [shape] points.
  final double stepHours;

  /// UNITLESS, normalised to its own min/max within this day. It is a picture
  /// of a shape and it is NOT a score: do not print a value from it, do not
  /// compare one day's to another's, do not put a number on an axis.
  final List<double> shape;

  /// The lowest window of the day, in local clock hours.
  final double troughStartHour;
  final double troughEndHour;

  /// A plain name for that window ("early afternoon"), so the card can say
  /// when without saying how much.
  final String troughLabel;

  const AlertnessForecast({
    required this.startHour,
    required this.stepHours,
    required this.shape,
    required this.troughStartHour,
    required this.troughEndHour,
    required this.troughLabel,
  });

  Map<String, dynamic> toJson() => {
        'start_hour': round6(startHour),
        'step_hours': round6(stepHours),
        'shape': [for (final v in shape) round6(v)],
        'trough_start_hour': round6(troughStartHour),
        'trough_end_hour': round6(troughEndHour),
        'trough_label': troughLabel,
      };
}

// Published Three-Process parameters (Åkerstedt & Folkard). They are group
// values on the model's own 1-16 alertness scale; we only ever use the SHAPE
// they produce, which is why no constant here is exposed or printed.
const double _sUpper = 14.3; // asymptote S recovers toward during sleep
const double _sLower = 2.4; // asymptote S decays toward while awake
const double _tauWake = 2.6; // h, decay time constant awake
const double _tauSleep = 4.2; // h, recovery time constant asleep
const double _cAmplitude = 2.5; // circadian amplitude
const double _wInertia = 5.72; // sleep-inertia magnitude at wake
const double _tauInertia = 0.67; // h, inertia decay

/// Population circadian peak, used only when the user's own acrophase is not
/// available. Disclosed in the note, because it is an assumption about *this*
/// user's body clock made from other people's.
const double _defaultAcrophaseHours = 16.0;

const double _stepHours = 0.25;

/// Forecast the SHAPE of today's alertness from last night's sleep.
///
/// [wakeLocalHour] local clock hour the night ended; [sleepDurationHours] how
/// long that night's sleep actually was. BOTH are required to be present — a
/// null in either is an abstention, not a default. [naps] are daytime sleeps in
/// the same local-hour frame. [circadianAcrophaseHours] is the user's own
/// cosinor acrophase when we have one.
///
/// Local clock hours throughout, never epochs: mixing the two is how a day
/// label ends up an hour out and a "trough" lands in the wrong afternoon.
Metric<AlertnessForecast> alertnessForecast({
  required double? wakeLocalHour,
  required double? sleepDurationHours,
  List<DaytimeSleepWindow> naps = const [],
  double? circadianAcrophaseHours,
  double horizonHours = 18,
}) {
  const inputs = [
    'sleep_offset',
    'sleep_duration',
    'naps',
    'circadian_acrophase?'
  ];
  const safety = 'MODEL PREDICTION from group data, not a measurement of you — '
      'nothing here measures alertness. NOT a fitness-to-drive or shift-safety '
      'assessment, and it never says you are impaired.';

  if (wakeLocalHour == null ||
      sleepDurationHours == null ||
      !wakeLocalHour.isFinite ||
      !sleepDurationHours.isFinite ||
      sleepDurationHours <= 0) {
    // The night is missing or the window was never judged. There is no eight
    // hours to fall back on. This abstention is the gate; do not remove it.
    return const Metric<AlertnessForecast>.absent(
      tier: Tier.estimate,
      inputs_used: inputs,
      note: 'no_judged_night: alertness is not forecast without last night. '
          '$safety',
    );
  }

  // S at wake: recovery across last night from wherever the previous day left
  // it. Starting the recovery from the lower asymptote is the conservative
  // choice — it makes a short night matter and a long one saturate.
  final s0 =
      _sUpper - (_sUpper - _sLower) * math.exp(-sleepDurationHours / _tauSleep);

  final phase =
      (circadianAcrophaseHours != null && circadianAcrophaseHours.isFinite)
          ? circadianAcrophaseHours
          : _defaultAcrophaseHours;

  final steps = (horizonHours / _stepHours).round();
  final raw = <double>[];
  var s = s0;
  for (var i = 0; i <= steps; i++) {
    final hour = wakeLocalHour + i * _stepHours;
    final clock = hour % 24;
    final asleep = naps.any((n) => clock >= n.startHour && clock < n.endHour);
    if (i > 0) {
      s = asleep
          ? _sUpper - (_sUpper - s) * math.exp(-_stepHours / _tauSleep)
          : _sLower + (s - _sLower) * math.exp(-_stepHours / _tauWake);
    }
    final c = _cAmplitude * math.cos(2 * math.pi * (clock - phase) / 24.0);
    final w = _wInertia * math.exp(-(i * _stepHours) / _tauInertia);
    raw.add(s + c - w);
  }

  // Normalise inside the day. The result is a picture, not a quantity.
  final lo = raw.reduce(math.min);
  final hi = raw.reduce(math.max);
  final span = hi - lo;
  if (!(span > 0)) {
    return const Metric<AlertnessForecast>.absent(
      tier: Tier.estimate,
      inputs_used: inputs,
      note: 'degenerate forecast (flat curve); nothing to show. $safety',
    );
  }
  final shape = [for (final v in raw) (v - lo) / span];

  // The trough is the lowest TWO-HOUR window, not the single lowest point:
  // "around mid-afternoon" is the resolution this model supports, and a
  // to-the-minute low would imply a precision it does not have. The first hour
  // is excluded — that dip is sleep inertia, which is over, not a forecast.
  final w2 = (2.0 / _stepHours).round();
  final skip = (1.0 / _stepHours).round();
  var bestStart = skip;
  var bestSum = double.infinity;
  for (var i = skip; i + w2 <= shape.length; i++) {
    var sum = 0.0;
    for (var k = 0; k < w2; k++) {
      sum += shape[i + k];
    }
    if (sum < bestSum) {
      bestSum = sum;
      bestStart = i;
    }
  }
  final tStart = (wakeLocalHour + bestStart * _stepHours) % 24;
  final tEnd = (tStart + 2.0) % 24;

  return Metric<AlertnessForecast>(
    value: AlertnessForecast(
      startHour: wakeLocalHour % 24,
      stepHours: _stepHours,
      shape: shape,
      troughStartHour: tStart,
      troughEndHour: tEnd,
      troughLabel: _partOfDay(tStart),
    ),
    // Deliberately modest and flat: the confidence of a group model applied to
    // one person does not improve with more of that person's data.
    confidence: 0.35,
    tier: Tier.estimate,
    inputs_used: inputs,
    note: 'Three-Process Model shape only — NO SCORE. '
        '${circadianAcrophaseHours == null ? "Circadian phase ASSUMED from the population (peak ~16:00), not measured on you. " : ""}'
        '$safety',
  );
}

String _partOfDay(double hour) {
  if (hour < 5) return 'the small hours';
  if (hour < 9) return 'early morning';
  if (hour < 12) return 'mid-morning';
  if (hour < 15) return 'early afternoon';
  if (hour < 18) return 'late afternoon';
  if (hour < 21) return 'evening';
  return 'late evening';
}
