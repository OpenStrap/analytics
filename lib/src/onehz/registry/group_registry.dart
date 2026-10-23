// group_registry.dart — the calculation-group registry (design 06 phase 1b).
//
// Types moved verbatim from edge's lib/compute/groups/group_types.dart (same
// API). Pure Dart, const-constructible. test/registry_closure_test.dart pins
// the declared groups and their source closures.

/// What a group is. Foundations carry no cost rule; edge transforms are the
/// gating/assembly steps edge runs around analytics results.
enum GroupKind { algorithm, foundation, edgeTransform }

/// How far in time a declared input reaches.
enum InputScope { day, dayAndNext, range, global }

class InputDecl {
  /// An id from edge's input catalogue.
  final String id;
  final InputScope scope;
  const InputDecl(this.id, this.scope);
}

class GroupDecl {
  /// Stable; never reused after a split or merge.
  final String id;
  final GroupKind kind;

  /// Plain integer, bumped when the group's algorithm changes, including
  /// output rounding or abstention changes. Dependency-only changes propagate
  /// through [deps]; they do not require another bump of this counter.
  final int counter;

  /// Exported function names, at most 3.
  final List<String> members;

  /// Exported functions whose output depends on this group, beyond the
  /// cost-bearing [members]. Uncapped (design 06 section 13); the cost rule
  /// and the member cap look at [members] only. Each function is owned by
  /// exactly one group, as a member or an api entry.
  final List<String> api;

  /// Group ids this group reads, foundations included.
  final List<String> deps;
  final List<InputDecl> inputs;

  /// Repo-relative paths (lib/src/...) this group's output depends on.
  final List<String> files;

  const GroupDecl({
    required this.id,
    required this.kind,
    required this.counter,
    required this.members,
    this.api = const [],
    this.deps = const [],
    this.inputs = const [],
    this.files = const [],
  });
}

class GroupRegistry {
  final int registryVersion;
  final List<GroupDecl> groups;
  const GroupRegistry(this.registryVersion, this.groups);
}

/// The groups analytics declares (registry schema version 1).
///
/// `members` are the group's cost-bearing entry functions (at most 3); `api`
/// lists the other exported functions whose output depends on the group, so
/// every function edge calls has exactly one owner. `files` is the import
/// closure of members and api, minus the files of the foundations the group
/// depends on. Names only in lib/aggregate.dart (`prsaAggregator`) count as
/// public. test/registry_closure_test.dart re-derives all of this from source.
const GroupRegistry kAnalyticsGroupRegistry = GroupRegistry(1, <GroupDecl>[
  GroupDecl(
    id: 'found.core',
    kind: GroupKind.foundation,
    counter: 2,
    members: ['median'],
    api: ['needBaselineNote'],
    files: ['lib/src/onehz/types.dart', 'lib/src/onehz/util.dart'],
  ),
  GroupDecl(
    id: 'found.rr_correction',
    kind: GroupKind.foundation,
    counter: 2,
    members: ['correctRr'],
    deps: ['found.core'],
    files: [
      'lib/src/onehz/foundations/rr_correction.dart',
      'lib/src/onehz/foundations/rr_correction_kernel.dart',
    ],
  ),
  GroupDecl(
    id: 'found.baseline_ewma',
    kind: GroupKind.foundation,
    counter: 1,
    members: ['Baselines.foldHistory', 'Baselines.deviation'],
    api: ['mdc'],
    deps: ['found.core'],
    files: [
      'lib/src/onehz/foundations/baseline.dart',
      'lib/src/onehz/foundations/ewma_baselines.dart',
    ],
  ),
  GroupDecl(
    id: 'found.calibration',
    kind: GroupKind.foundation,
    counter: 1,
    members: ['calibrationFor'],
    api: ['unknownFamilyNote'],
    files: ['lib/src/onehz/device.dart'],
  ),
  GroupDecl(
    id: 'found.energy',
    kind: GroupKind.foundation,
    counter: 1,
    members: ['Calories.dailyEnergy'],
    api: ['Calories.minuteEnergy', 'Calories.estimateBoutCalories'],
    files: ['lib/src/onehz/workout/calories.dart'],
  ),
  GroupDecl(
    id: 'found.staging_helpers',
    kind: GroupKind.foundation,
    counter: 1,
    members: ['consolidateSleepStages'],
    deps: ['found.core'],
    files: [
      'lib/src/onehz/sleep/accounting.dart',
      'lib/src/onehz/sleep/stager.dart',
    ],
  ),
  GroupDecl(
    id: 'sleep.stage',
    kind: GroupKind.algorithm,
    counter: 2,
    members: ['segmentSleep', 'stageMinuteRanges', 'cardioStager'],
    api: [
      'resetCardioObservations',
      'takeCardioObservations',
      'detectSleepCycles',
      'sleepCyclesMetric',
      'hrLedSleepWindow',
      'zAngle',
      'habitualMidsleepSecFromHistory',
      'phillipsSri',
      'sleepDebt',
      'sleepNeed',
      'sleepPerformance',
      'recommendedBedtime',
      'recommendedWake',
    ],
    deps: [
      'found.core',
      'found.rr_correction',
      'found.staging_helpers',
      'found.calibration',
    ],
    files: [
      'lib/src/aggregate/aggregator.dart',
      'lib/src/aggregate/json_support.dart',
      'lib/src/aggregate/primitives.dart',
      'lib/src/onehz/clinical/hrv_jitter_evidence.dart',
      'lib/src/onehz/clinical/hrv_time.dart',
      'lib/src/onehz/clinical/hrv_time_aggregator.dart',
      'lib/src/onehz/clinical/rmssd_gate.dart',
      'lib/src/onehz/human/coaching.dart',
      'lib/src/onehz/human/sleep_regularity.dart',
      'lib/src/onehz/incremental_core.dart',
      'lib/src/onehz/sleep/advanced_stager.dart',
      'lib/src/onehz/sleep/band_offset.dart',
      'lib/src/onehz/sleep/cardio_row_cache.dart',
      'lib/src/onehz/sleep/cardio_stager.dart',
      'lib/src/onehz/sleep/cpc.dart',
      'lib/src/onehz/sleep/cycles.dart',
      'lib/src/onehz/sleep/epoch_rows.dart',
      'lib/src/onehz/sleep/hr_fallback.dart',
      'lib/src/onehz/sleep/hypnogram.dart',
      'lib/src/onehz/sleep/hypnogram_aggregator.dart',
      'lib/src/onehz/sleep/segment.dart',
      'lib/src/onehz/sleep/sri.dart',
      'lib/src/onehz/sleep/sri_aggregator.dart',
      'lib/src/onehz/sleep/stage_ranges.dart',
      'lib/src/onehz/sleep/van_hees.dart',
    ],
  ),
  GroupDecl(
    id: 'hrv.freq',
    kind: GroupKind.algorithm,
    counter: 2,
    members: ['hrvFreq'],
    api: [
      'nightHrvShape',
      'hrvTime',
      'nocturnalRmssd',
      'rrCoverage',
      'sleepSessionRmssdDetail',
    ],
    deps: ['found.core', 'found.rr_correction'],
    files: [
      'lib/src/aggregate/aggregator.dart',
      'lib/src/aggregate/json_support.dart',
      'lib/src/aggregate/primitives.dart',
      'lib/src/onehz/clinical/hrv_freq.dart',
      'lib/src/onehz/clinical/hrv_freq_stream.dart',
      'lib/src/onehz/clinical/hrv_jitter_evidence.dart',
      'lib/src/onehz/clinical/hrv_time.dart',
      'lib/src/onehz/clinical/hrv_time_aggregator.dart',
      'lib/src/onehz/clinical/rmssd_gate.dart',
      'lib/src/onehz/incremental_core.dart',
      'lib/src/onehz/sleep/night_hrv_shape.dart',
    ],
  ),
  GroupDecl(
    id: 'night.rhythm',
    kind: GroupKind.algorithm,
    counter: 2,
    members: ['rsaRespRate', 'cvhrApneaScreen', 'decelerationCapacity'],
    api: [
      'accelerationCapacity',
      'breathingRateVariability',
      'irregularBeatScreenDetailed',
      'prsaAggregator',
      'cosinor',
      'circadianNonparametric',
      'chronotype',
      'socialJetlag',
    ],
    deps: ['found.core', 'found.rr_correction'],
    files: [
      'lib/src/aggregate/aggregator.dart',
      'lib/src/aggregate/json_support.dart',
      'lib/src/aggregate/primitives.dart',
      'lib/src/onehz/clinical/cardiac_coherence.dart',
      'lib/src/onehz/clinical/cosinor.dart',
      'lib/src/onehz/clinical/cosinor_aggregator.dart',
      'lib/src/onehz/clinical/irregular_diagnostics.dart',
      'lib/src/onehz/clinical/irregular_rhythm.dart',
      'lib/src/onehz/clinical/irregular_window.dart',
      'lib/src/onehz/clinical/prsa.dart',
      'lib/src/onehz/clinical/prsa_aggregator.dart',
      'lib/src/onehz/foundations/baseline.dart',
      'lib/src/onehz/foundations/fusion.dart',
      'lib/src/onehz/human/circadian_lifestyle.dart',
      'lib/src/onehz/human/percentile_of_you.dart',
      'lib/src/onehz/incremental_core.dart',
      'lib/src/onehz/respiration/brv_trend.dart',
      'lib/src/onehz/respiration/cvhr_apnea.dart',
      'lib/src/onehz/respiration/relative_odi.dart',
      'lib/src/onehz/respiration/resp_rate.dart',
      'lib/src/onehz/sleep/circadian_np.dart',
      'lib/src/onehz/sleep/circadian_np_aggregator.dart',
      'lib/src/onehz/sleep/circadian_window.dart',
    ],
  ),
  GroupDecl(
    id: 'day.blocks',
    kind: GroupKind.algorithm,
    counter: 1,
    members: ['detectNaps', 'autoDetectWorkouts', 'positionSeries'],
    api: ['hrRecovery', 'AutoWorkoutDetector.motionPoints'],
    deps: ['found.core', 'sleep.stage', 'found.calibration'],
    files: [
      'lib/src/onehz/motion/orientation.dart',
      'lib/src/onehz/sleep/nap.dart',
      'lib/src/onehz/sleep/van_hees.dart',
      'lib/src/onehz/workout/auto_detect.dart',
      'lib/src/onehz/workout/hr_recovery.dart',
      'lib/src/onehz/workout/sport.dart',
    ],
  ),
  GroupDecl(
    id: 'readiness.stress_illness',
    kind: GroupKind.algorithm,
    counter: 1,
    members: ['readinessComposite', 'baevskyStressIndex', 'illnessCusum'],
    api: [
      'readinessLnRmssd',
      'glassBoxReadiness',
      'hrvInput',
      'respInput',
      'rhrInput',
      'tempInput',
      'nocturnalRhr',
      'cusumChangePoints',
      'multivariateAnomaly',
      'overreachingConjunction',
      'tempIllnessFlag',
    ],
    deps: [
      'found.core',
      'night.rhythm',
      'hrv.freq',
      'found.rr_correction',
      'found.baseline_ewma',
    ],
    files: [
      'lib/src/aggregate/aggregator.dart',
      'lib/src/aggregate/json_support.dart',
      'lib/src/aggregate/primitives.dart',
      'lib/src/onehz/clinical/cosinor.dart',
      'lib/src/onehz/clinical/cosinor_aggregator.dart',
      'lib/src/onehz/clinical/illness_cusum.dart',
      'lib/src/onehz/clinical/load_trimp.dart',
      'lib/src/onehz/clinical/load_trimp_aggregator.dart',
      'lib/src/onehz/clinical/nocturnal.dart',
      'lib/src/onehz/clinical/readiness_lnrmssd.dart',
      'lib/src/onehz/clinical/stress_si.dart',
      'lib/src/onehz/device.dart',
      'lib/src/onehz/human/overreaching_conjunction.dart',
      'lib/src/onehz/human/readiness_glassbox.dart',
      'lib/src/onehz/incremental_core.dart',
      'lib/src/onehz/wellness/anomaly.dart',
      'lib/src/onehz/wellness/changepoint.dart',
      'lib/src/onehz/wellness/readiness_composite.dart',
      'lib/src/onehz/wellness/temp_circadian.dart',
      'lib/src/onehz/wellness/temp_health.dart',
    ],
  ),
  GroupDecl(
    id: 'activity.load',
    kind: GroupKind.algorithm,
    counter: 2,
    members: ['banisterTrimp', 'dailyActiveMinutes', 'strainScore'],
    api: [
      'strainFromNetTrimp',
      'strainScoreFromSeries',
      'strainCurveFromSeries',
      'strainTarget',
      'ctlAtlTsb',
      'netTrimpAboveQuiet',
      'dailyQuietWakingHrr',
      'personalQuietWakingHrr',
      'dailyDynSummary',
      'personalDynFloorFromDailySummaries',
      'shouldRefreezeFloor',
      'calibrateGRef',
      'enmoSeries',
      'sessionHrCeiling',
      'HeartRateZones.timeInZone',
      'HeartRateZones.zonesFromMaxHr',
      'HeartRateZones.reserveZones',
    ],
    deps: [
      'found.core',
      'found.energy',
      'found.calibration',
      'found.baseline_ewma',
    ],
    files: [
      'lib/src/aggregate/aggregator.dart',
      'lib/src/aggregate/json_support.dart',
      'lib/src/aggregate/primitives.dart',
      'lib/src/onehz/clinical/load_trimp.dart',
      'lib/src/onehz/clinical/load_trimp_aggregator.dart',
      'lib/src/onehz/clinical/vo2max.dart',
      'lib/src/onehz/human/coaching.dart',
      'lib/src/onehz/incremental_core.dart',
      'lib/src/onehz/motion/energy_fusion.dart',
      'lib/src/onehz/motion/enmo.dart',
      'lib/src/onehz/motion/steps.dart',
      'lib/src/onehz/workout/hr_zones.dart',
      'lib/src/onehz/workout/observed_max_hr.dart',
      'lib/src/onehz/workout/time_in_zone_aggregator.dart',
    ],
  ),
  GroupDecl(
    id: 'body.spo2_temp_coverage',
    kind: GroupKind.algorithm,
    counter: 1,
    members: ['hrDip', 'nightlySkinTemp'],
    api: ['hrDipFromDayTotals'],
    deps: ['found.core', 'found.baseline_ewma', 'found.calibration'],
    files: [
      'lib/src/aggregate/aggregator.dart',
      'lib/src/aggregate/json_support.dart',
      'lib/src/onehz/clinical/cosinor.dart',
      'lib/src/onehz/clinical/cosinor_aggregator.dart',
      'lib/src/onehz/clinical/nocturnal.dart',
      'lib/src/onehz/device.dart',
      'lib/src/onehz/wellness/temp_circadian.dart',
    ],
  ),
  GroupDecl(
    id: 'human.insights',
    kind: GroupKind.algorithm,
    counter: 1,
    members: ['alertnessForecast', 'scanAssociations', 'alcoholNightFlag'],
    api: [
      'roughNight',
      'sessionMorningEffects',
      'weekdayEffect',
      'cycleLengthSeries',
    ],
    deps: ['found.core', 'found.baseline_ewma'],
    files: [
      'lib/src/onehz/human/alertness_forecast.dart',
      'lib/src/onehz/human/associations.dart',
      'lib/src/onehz/human/event_detection.dart',
      'lib/src/onehz/human/session_cost.dart',
      'lib/src/onehz/human/weekday_effect.dart',
      'lib/src/onehz/wellness/cycle_lengths.dart',
    ],
  ),
]);
