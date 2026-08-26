// SLEEP & CIRCADIAN family barrel.
//
// The 1 Hz-native sleep/circadian stack from docs/ALGORITHM_CATALOG_1HZ.md:
//
//   - van Hees / GGIR angle-based sleep window  (van_hees.dart) — the spine.
//   - segmentSleep SINGLE-SOURCE entry point      (segment.dart) — THE source:
//       window + per-second stages + TST/WASO/eff all from one staging.
//   - Daytime nap detection                       (nap.dart) — the ONLY nap
//       source. Separate from the nocturnal detector on purpose: that one
//       rejects naps by design (minSleepMin=60, plus a 90-min daytime guard),
//       and those gates are load-bearing for night accuracy.
//   - True Phillips Sleep Regularity Index       (sri.dart)
//   - Sleep accounting (onset/offset/WASO/TST/eff/cycles) (accounting.dart)
//   - 3-class cardio stager (wake/NREM/REM)       (cardio_stager.dart) —
//       honesty-bounded; stager.dart holds only the shared post-processing
//       (StagerResult, Webster rescore, consolidation) it reuses. The
//       autonomic-HR-only stager that used to live in stager.dart is DELETED.
//   - Cardiopulmonary Coupling (CPC)              (cpc.dart)
//   - Nonparametric circadian IS/IV/RA/L5/M10     (circadian_np.dart)
//
// Pure Dart, built on the package foundations (RR correction, Lomb-Scargle,
// robust stats). Validated by synthetic known-answer tests + real-capture
// plausibility.

export 'van_hees.dart';
export 'nap.dart';
export 'segment.dart';
export 'hr_fallback.dart';
export 'advanced_stager.dart';
export 'sri.dart';
export 'accounting.dart';
// stager.dart provides StagerResult + the shared Webster/consolidation
// post-processing (both used by cardio_stager and tests). Its deprecated
// `autonomicStager` is DELETED — `cardioStager` is the stager.
export 'stager.dart';
export 'cardio_stager.dart';
export 'cpc.dart';
export 'circadian_np.dart';
export 'cycles.dart';
export 'night_hrv_shape.dart';
