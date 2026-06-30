// SLEEP & CIRCADIAN family barrel.
//
// The 1 Hz-native sleep/circadian stack from docs/ALGORITHM_CATALOG_1HZ.md:
//
//   - van Hees / GGIR angle-based sleep window  (van_hees.dart) — the spine.
//   - segmentSleep SINGLE-SOURCE entry point      (segment.dart) — THE source:
//       window + per-second stages + TST/WASO/eff all from one staging.
//   - True Phillips Sleep Regularity Index       (sri.dart)
//   - Sleep accounting (onset/offset/WASO/TST/eff/cycles) (accounting.dart)
//   - 3-class autonomic stager (wake/NREM/REM)    (stager.dart) — honesty-bounded
//   - Cardiopulmonary Coupling (CPC)              (cpc.dart)
//   - Nonparametric circadian IS/IV/RA/L5/M10     (circadian_np.dart)
//
// Pure Dart, built on the package foundations (RR correction, Lomb-Scargle,
// robust stats). Validated by synthetic known-answer tests + real-capture
// plausibility.

export 'van_hees.dart';
export 'segment.dart';
export 'hr_fallback.dart';
export 'advanced_stager.dart';
export 'sri.dart';
export 'accounting.dart';
export 'stager.dart';
export 'cardio_stager.dart';
export 'cpc.dart';
export 'circadian_np.dart';
export 'cycles.dart';
