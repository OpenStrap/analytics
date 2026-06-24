/// MOTION / ACTIVITY / ENERGY family — 1 Hz-native, 24/7 capable.
///
/// Per docs/ALGORITHM_CATALOG_1HZ.md §"Motion / energy" and the explicit
/// "what 1 Hz accel CANNOT do" honesty section. Three published methods that
/// SURVIVE the 1 Hz / Nyquist ceiling:
///
///   * ENMO + MAD per-minute amplitude index (van Hees 2013 / Vähä-Ypyä 2015),
///     with auto-calibrated 1 g reference and RELATIVE (not MET) intensity
///     bands.  → enmo.dart
///   * Static gravity-tilt orientation → sleep-position proxy (low-motion
///     epochs).  → orientation.dart
///   * Branched HR + accel energy fusion (Brage 2004) — RELATIVE EE index, or
///     %HR-reserve ESTIMATE when per-user HR anchors are supplied.
///     → energy_fusion.dart
///
/// ─────────────────────────────────────────────────────────────────────────
/// DEFERRED TO A FUTURE FOREGROUND MODULE (NOT implemented here, NOT faked):
/// these are physically impossible on a 1 Hz stream (Nyquist limit = 0.5 Hz;
/// human gait is 1.4–2.5 Hz) and require the ~100 Hz foreground accel/gyro:
///   - Step / cadence counting + autocorrelation gait regularity (Moe-Nilssen
///     2004; AN-2554 peak-detection).
///   - Madgwick / Mahony quaternion (dynamic) orientation for limb tracking.
///   - Frequency-domain activity TYPE classification (walk vs run vs cycle).
/// At 1 Hz only an AMPLITUDE index + STATIC orientation are recoverable, and
/// intensity is RELATIVE-to-you, never absolute METs.
/// ─────────────────────────────────────────────────────────────────────────
library onehz_motion;

export 'enmo.dart';
export 'orientation.dart';
export 'energy_fusion.dart';
