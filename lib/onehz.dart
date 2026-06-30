/// openstrap_analytics — 1 Hz-native physiological analytics family.
///
/// Independent of the minute-resolution library in
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

// Layer 0: foundations.
export 'src/onehz/foundations/rr_correction.dart';
export 'src/onehz/foundations/ppg_sqi.dart';
export 'src/onehz/foundations/baseline.dart';
export 'src/onehz/foundations/ewma_baselines.dart';
export 'src/onehz/foundations/fusion.dart';

// Tier-1 clinical.
export 'src/onehz/clinical/hrv_time.dart';
export 'src/onehz/clinical/hrv_freq.dart';
export 'src/onehz/clinical/prsa.dart';
export 'src/onehz/clinical/nocturnal.dart';
export 'src/onehz/clinical/illness_cusum.dart';
export 'src/onehz/clinical/readiness_lnrmssd.dart';
export 'src/onehz/clinical/cosinor.dart';
export 'src/onehz/clinical/load_trimp.dart';
export 'src/onehz/clinical/stress_si.dart';
export 'src/onehz/clinical/irregular_rhythm.dart';

// Metric families (each a self-contained barrel over the foundations + clinical).
export 'src/onehz/sleep/sleep.dart';
export 'src/onehz/respiration/respiration.dart';
export 'src/onehz/motion/motion.dart';
export 'src/onehz/workout/workout.dart';
export 'src/onehz/wellness/wellness.dart';
export 'src/onehz/human/human.dart';
