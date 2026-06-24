// openstrap-analytics — public surface (Dart 1:1 port).
library openstrap_analytics;

export 'src/types.dart';
export 'src/util.dart'
    show resolveMaxHr, MaxHrResult, percentile, median, clamp, mean, stddev, linregSlope, round;

export 'src/resting.dart' show calcRestingHR, SleepWindow, RestingHrResult;
export 'src/strain.dart' show calcStrain, StrainResult;
export 'src/zones.dart' show calcHrZones, HrZonesResult;
export 'src/calories.dart' show calcCalories, CaloriesResult;
export 'src/sleep.dart'
    show
        calcSleep,
        calcSleepPeriods,
        sleepAwakeMask,
        stageHypnogram,
        NightHypnogram,
        SleepResult,
        SleepPeriod,
        SleepPeriodsResult;
export 'src/cycles.dart'
    show detectSleepCycles, SleepCycle, SleepCyclesResult, RrMinute;
export 'src/cycle.dart' show calcCycle, CycleResult;
export 'src/regularity.dart' show calcSleepRegularity, SleepRegularityResult;
export 'src/sessions.dart' show detectSessions, SessionResult;
export 'src/recovery.dart'
    show calcHrRecovery, calcRecovery, HrRecoveryResult, RecoveryResult;
export 'src/hrv.dart'
    show
        timeDomainHrv,
        freqDomainHrv,
        baevskyStressIndex,
        cleanRr,
        calcHrvStability,
        calcIrregular,
        calcDaytimeHrv,
        VLF_BAND,
        LF_BAND,
        HF_BAND,
        TimeDomainHrv,
        FreqDomainHrv,
        BaevskyResult,
        DaytimeHrvResult,
        HrvStabilityResult,
        IrregularResult,
        RrByMinute;
export 'src/trends.dart'
    show calcLoad, calcFitnessTrend, LoadResult, FitnessTrendResult;
export 'src/fitness.dart'
    show
        calcVo2Max,
        calcFitnessModel,
        calcMonotony,
        Vo2MaxResult,
        FitnessModelResult,
        MonotonyResult;
export 'src/steps.dart' show calcSteps, pedometer, STEP_PARAMS, StepParams;
export 'src/har.dart'
    show
        extractHarFeatures,
        extractHarFeaturesFromSmv,
        classifyActivityWindow,
        segmentWorkout,
        dwtDetailEnergies,
        DB10_LO,
        HarFeatures,
        ClassVote,
        WorkoutSegment,
        SegmentResult,
        ClassifyResult;
export 'src/circadian.dart'
    show calcCircadian, stageSleep, CircadianOpts, SleepStaging, CircadianResult, StageMinute;
export 'src/wake.dart'
    show
        detectWakeState,
        peekRecentState,
        coleKripke,
        cardiac,
        inactivity,
        hrvArousal,
        DEFAULT_VOTERS,
        WakeContext,
        WakeState,
        Voter,
        NamedVoter;
export 'src/readiness_index.dart'
    show calcReadinessIndex, ReadinessInputs, ReadinessIndexResult;
export 'src/readiness.dart'
    show calcAnomaly, AnomalyInputs, AnomalyResult;
export 'src/illness.dart'
    show calcIllness, IllnessToday, IllnessHistory, IllnessResult;
export 'src/baselines.dart' show calcBaselines, BaselinesResult;
export 'src/coach.dart'
    show
        buildCoach,
        CoachInputs,
        CoachOutput,
        Suggestion,
        Contributor,
        Why,
        CoachReadinessComponents,
        CoachAnomaly,
        StrainTarget;
export 'src/stress.dart' show calcStress, StressResult;
export 'src/spo2.dart'
    show calcSpo2Index, calcDesaturation, Spo2Result, DesaturationResult;
export 'src/arousal.dart' show calcSleepStress, SleepStressResult;
export 'src/restlessness.dart' show calcRestlessness, RestlessnessResult;
export 'src/nocturnal.dart' show calcNocturnalHeart, NocturnalResult;
export 'src/notify.dart'
    show
        buildNotifications,
        NotifyInputs,
        AppNotification,
        NotifyCoachTop,
        NotifyBodyAlert,
        NotifyStreaks;
