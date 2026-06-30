/// HUMAN LAYER barrel — everyday, behavior-changing insights.
///
/// Deterministic recombinations of the clinical primitives (lib/src/onehz/) into
/// honest narratives, per docs/ALGORITHM_CATALOG_1HZ.md "THE HUMAN LAYER".
///
/// Governing honesty (enforced in code): report STATE confidently, CAUSE only as
/// a tag-confirmable hypothesis; MDC-gate every insight; within-user percentiles
/// (never population); never print numbers the sensor can't support; anchor
/// circadian phase on the nocturnal trough; "—" when data absent.
///
/// All functions are pure Dart (dart:math only), timestamps passed in, no ML.
library onehz_human;

export 'percentile_of_you.dart';
export 'circadian_lifestyle.dart';
export 'sleep_regularity.dart';
export 'event_detection.dart';
export 'coaching.dart';
// readiness_glassbox.dart is DEPRECATED/INTERNAL (duplicate readiness). The
// canonical readiness is wellness/readiness_composite.dart. Kept exported only
// for back-compat — do NOT surface as the headline.
export 'readiness_glassbox.dart';
