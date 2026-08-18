/// WORKOUT / ACTIVITY DETECTION family — 1 Hz-native, HYBRID.
///
/// Keeps OpenStrap's existing day-level strain / HR-zones (clinical/load_trimp)
/// untouched and adds bout-detection:
///
///   * [AutoWorkoutDetector] — opt-in "did you just work out?" SUGGESTION
///     detector (HR ≥ max(RHR+40, RHR+0.45·HRR) sustained ≥12 min, brief dips
///     tolerated, optional motion confirmation, overlap-excluded). Never writes
///     a row, and is the ONLY bout detector here. → auto_detect.dart
///   * [Calories] — Keytel 2005 + Harris–Benedict per-bout energy. → calories.dart
///
/// A second, retroactive per-day detector (`WorkoutDetector` / `detectWorkouts`
/// / `ExerciseSession`, workout_detect.dart) lived here for a while and was
/// never called by anything but its own tests. It is deleted rather than kept
/// warm: edge's `derivation_engine` no longer writes the `detected_workouts`
/// stub it would have fed, and auto-detected bouts reach the UI through
/// `workout_suggestions` from [AutoWorkoutDetector] instead.
///
/// HYBRID SEAM: every detected bout is typed through a [SportClassifier]
/// (default "detected"). OpenStrap's motion-based HAR typer can be injected
/// when high-rate accel features ([MotionFeatures]) are available. → sport.dart
library onehz_workout;

export 'sport.dart';
export 'calories.dart';
export 'auto_detect.dart';
export 'hr_zones.dart';
export 'observed_max_hr.dart';
export 'hr_recovery.dart';
