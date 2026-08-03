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
///   * [dailyActiveMinutes] reports MINUTES OF SUSTAINED WRIST MOVEMENT from
///     the 1 Hz substrate — the only quantity resolvable there — and emits NO
///     step count: at the wrist, arm work out-accelerates walking, so movement
///     minutes are activity volume, not locomotion. Its threshold is a
///     multi-day personal reference ([personalDynFloor]); with too little
///     history it ABSTAINS rather than substituting a constant.
///   * [calibrateCadence] measures the user's real walking cadence from the
///     100 Hz path. Reportable on its own; never used to synthesise steps.
/// Still genuinely impossible / not faked: dynamic-orientation limb tracking,
/// frequency-domain activity TYPE classification (walk vs run vs cycle).
/// At 1 Hz only an AMPLITUDE index + STATIC orientation are recoverable, and
/// intensity is RELATIVE-to-you, never absolute METs.
/// ─────────────────────────────────────────────────────────────────────────
library onehz_motion;

export 'enmo.dart';
export 'orientation.dart';
export 'energy_fusion.dart';
export 'steps.dart';
