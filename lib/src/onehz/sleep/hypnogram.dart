/// A scored stage span. [stage] is normally 'wake', 'light', 'deep', or 'rem'.
class StageSegment {
  final int start;
  final int end;
  final String stage;
  const StageSegment(this.start, this.end, this.stage);
  Map<String, dynamic> toJson() => {'start': start, 'end': end, 'stage': stage};
}

/// One detected sleep session and its hypnogram.
class SleepSession {
  final int start;
  final int end;
  final double efficiency; // [0,1]
  final List<StageSegment> stages;
  final int? restingHr; // lowest 5-min rolling-mean HR (bpm)
  final double? avgHrv; // mean RMSSD over 5-min windows (ms)
  const SleepSession({
    required this.start,
    required this.end,
    required this.efficiency,
    required this.stages,
    required this.restingHr,
    required this.avgHrv,
  });
}

/// AASM-style hypnogram metrics over a session.
class HypnogramMetrics {
  final int tibS;
  final int tstS;
  final int sptS;
  /// Sleep-onset latency (s). NULL when NOTHING staged as sleep — reporting
  /// the whole time in bed as "time to fall asleep" alongside TST 0 is a
  /// fabricated measurement, not an abstention.
  final int? solS;
  final double remLatencyS; // NaN if no REM
  final int wasoS;
  final double efficiency; // [0,1]
  final int disturbances;
  final double deepMin;
  final double remMin;
  final double lightMin;
  final double deepPct;
  final double remPct;
  final double lightPct;
  const HypnogramMetrics({
    required this.tibS,
    required this.tstS,
    required this.sptS,
    required this.solS,
    required this.remLatencyS,
    required this.wasoS,
    required this.efficiency,
    required this.disturbances,
    required this.deepMin,
    required this.remMin,
    required this.lightMin,
    required this.deepPct,
    required this.remPct,
    required this.lightPct,
  });
  Map<String, dynamic> toJson() => {
        'tib_s': tibS,
        'tst_s': tstS,
        'spt_s': sptS,
        'sol_s': solS,
        'rem_latency_s': remLatencyS.isNaN ? null : remLatencyS,
        'waso_s': wasoS,
        'efficiency': efficiency,
        'disturbances': disturbances,
        'deep_min': deepMin,
        'rem_min': remMin,
        'light_min': lightMin,
        'deep_pct': deepPct,
        'rem_pct': remPct,
        'light_pct': lightPct,
      };
}
