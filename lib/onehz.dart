/// openstrap_analytics — 1 Hz-native physiological analytics family.
///
/// NET-NEW, independent of the parked minute-family in
/// `lib/openstrap_analytics.dart`. Operates on the always-on 1 Hz substrate
/// (beat-to-beat RR, 1 Hz HR, 1 Hz tri-axial accel, relative-ADC channels) per
/// docs/ALGORITHM_CATALOG_1HZ.md.
///
/// Honesty ceilings are enforced in code: PRV not ECG-HRV; relative signals
/// carry no absolute %/°C; absent input => null + confidence 0 (never a
/// heuristic fallback); every Metric carries tier + confidence + inputs_used.
library onehz;

// Layer: input types & math.
export 'src/onehz/types.dart';
export 'src/onehz/util.dart';
