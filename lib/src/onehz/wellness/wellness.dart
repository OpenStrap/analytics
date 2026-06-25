// WELLNESS family barrel — temperature / anomaly / change-point / readiness.
//
// Built on the foundations (types/util/baseline/fusion) and clinical (cosinor,
// illness_cusum) layers. MED-tier, RELATIVE-honest methods:
//   - tempCircadian        : relative skin-temp cosinor + IS/IV/RA/L5/M10
//   - tempIllnessFlag      : Smarr nightly relative-temp z, CYCLE-AWARE
//   - menstrualCoverline   : 3-over-6 retrospective ovulation CONFIRMATION
//   - multivariateAnomaly  : robust Mahalanobis {RHR↑,HRV↓,temp↑,resp↑} + gates
//   - cusumChangePoints    : online two-sided CUSUM change detector
//   - segmentChangePoints  : offline binary-segmentation (BIC, min-seg ≥7)
//   - readinessComposite   : ★ CANONICAL recovery/readiness — glass-box weighted
//                            readiness (personal-baseline z-scores) w/ "why"
//                            breakdown. The single headline (ARCHITECTURE_V2).
//
// Honesty: relative temp only (no °C/fever); illness flag cycle-aware; anomaly
// detectors persistence-gated so they don't cry wolf; readiness weights
// disclosed.
library wellness;

// Re-export the shared types/util this family's public API surfaces (Metric,
// Driver, Tier, AdcSample, AccelSample, NightlyRecord, round6…) so callers can
// depend on just this barrel.
export '../types.dart';
export '../util.dart';

export 'temp_circadian.dart';
export 'temp_health.dart';
export 'anomaly.dart';
export 'changepoint.dart';
export 'readiness_composite.dart';
