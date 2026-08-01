/// MOTION / ACTIVITY / ENERGY family — 1 Hz-native, 24/7 capable.
///
/// Per docs/ALGORITHM_CATALOG_1HZ.md §"Motion / energy" and the explicit
/// "what 1 Hz accel CANNOT do" honesty section. Three published methods that
/// SURVIVE the 1 Hz / Nyquist ceiling:
///
///   * ENMO + MAD per-minute amplitude index (van Hees 2013 / Vähä-Ypyä 2015),
///     with auto-calibrated 1 g reference and RELATIVE (not MET) intensity
///     bands — PLUS `dynAmp`, a per-axis high-passed dynamic amplitude that is
///     invariant to per-axis sensor offset (and hence to which posture the
///     gravity reference happened to be calibrated in). Threshold dynAmp, not
///     ENMO, whenever a cut-point has to hold across days.  → enmo.dart
///   * Static gravity-tilt orientation → sleep-position proxy (low-motion
///     epochs).  → orientation.dart
///   * Branched HR + accel energy fusion (Brage 2004) — RELATIVE EE index, or
///     %HR-reserve ESTIMATE when per-user HR anchors are supplied.
///     → energy_fusion.dart
///
/// ─────────────────────────────────────────────────────────────────────────
/// STEPS — the honest hybrid (see steps.dart). True per-step counting is
/// physically impossible on the 1 Hz substrate (Nyquist 0.5 Hz < gait
/// 1.4–2.5 Hz), so:
///   * [livePedometer] counts REAL steps on the ~100 Hz foreground accel
///     (R10 / 0x2B) — adaptive-threshold peak detection (AN-2554 family).
///   * [dailyStepEstimate] reports ACTIVE MINUTES from the 1 Hz substrate —
///     the quantity that IS resolvable there — and derives a step RANGE from
///     the free-living cadence band. Its threshold is a multi-day personal
///     reference ([personalDynFloor]); with too little history it ABSTAINS
///     rather than substituting a constant.
///   * [calibrateCadence] lets the live path narrow that range to the user's
///     own measured cadence.
/// Still genuinely impossible / not faked: dynamic-orientation limb tracking,
/// frequency-domain activity TYPE classification (walk vs run vs cycle) AT
/// 1 HZ. At 1 Hz only an AMPLITUDE index + STATIC orientation are
/// recoverable, and intensity is RELATIVE-to-you, never absolute METs.
/// ─────────────────────────────────────────────────────────────────────────
/// IMU GAIT-BAND (foreground, LAYER 2) — see imu_activity.dart. A 100 Hz-class
/// accel+gyro buffer (first available from a WHOOP5 R22 opt-in raw buffer;
/// gen4 has no gyroscope at all) unlocks a real spectral cadence + motion-
/// energy estimate that 1 Hz structurally cannot — still an ESTIMATE, still
/// not a step count, and purely additive (nothing else in this package calls
/// it yet).
/// ─────────────────────────────────────────────────────────────────────────
library onehz_motion;

export 'enmo.dart';
export 'orientation.dart';
export 'energy_fusion.dart';
export 'steps.dart';
export 'imu_activity.dart';
