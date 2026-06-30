/// WORKOUT / ACTIVITY DETECTION family — 1 Hz-native, HYBRID.
///
/// Keeps OpenStrap's existing day-level strain / HR-zones (clinical/load_trimp)
/// untouched and adds bout-detection:
///
///   * [AutoWorkoutDetector] — opt-in "did you just work out?" SUGGESTION
///     detector (HR ≥ RHR+30 sustained ≥12 min, brief dips tolerated, optional
///     motion confirmation, overlap-excluded). Never writes a row. → auto_detect.dart
///   * [WorkoutDetector] — persistent per-day detector (HR + motion gated, ≥5 min,
///     ≥50% time in zone 2+, #303 HR-bridge) producing per-bout avg/peak HR,
///     Edwards zone time-%, mean %HRR, strain (reuses [StrainScorer]), HRmax, and
///     calories (Keytel + Harris–Benedict via [Calories]). → workout_detect.dart
///   * [Calories] — Keytel 2005 + Harris–Benedict per-bout energy. → calories.dart
///
/// HYBRID SEAM: every detected bout is typed through a [SportClassifier]
/// (default "detected"). OpenStrap's motion-based HAR typer can be injected
/// when high-rate accel features ([MotionFeatures]) are available. → sport.dart
library onehz_workout;

export 'sport.dart';
export 'calories.dart';
export 'auto_detect.dart';
export 'hr_zones.dart';
export 'workout_detect.dart';
export 'hr_recovery.dart';
