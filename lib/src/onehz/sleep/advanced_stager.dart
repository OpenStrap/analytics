// SLEEP — AdvancedSleepStager (V1) + SleepStagerV2.
//
// 4-class wake/light/deep/rem stager: the Cole–Kripke sleep/wake spine, the
// full session-detection pipeline with all guards (daytime #90,
// morning-stillness #531, 16h cap #547, off-wrist #500, sparse gravity #308),
// Stage-1 per-epoch features (30 s epochs, 5-min window, DoG HR-variability
// σ=120/600, pooled-RR RMSSD/SDNN, resp peak detector), the Stage-2
// percentile-band classifier, and Stage-3 median smoothing + physiology.
//
// V2 (opt-in via `useV2`) replaces ONLY per-session staging with the z-scored
// emission model + deep HR-flatness gate + cycle prior + sticky 4×4 Viterbi HMM.
// Detection is identical to V1.
//
// HONESTY: a wrist 4-class autonomic ESTIMATE, never PSG/EEG. tier ESTIMATE.
// Pure Dart, dart:math only.

import 'dart:math' as math;
import '../types.dart';
import '../clinical/hrv_time.dart';

// ── Input sample types (HrTs / GravTs / RrTs / RespTs)

/// HR sample: [ts] unix SECONDS, [bpm].
class HrTs {
  final int ts;
  final double bpm;
  const HrTs(this.ts, this.bpm);
}

/// Gravity vector sample (g): [ts] unix seconds.
class GravTs {
  final int ts;
  final double x;
  final double y;
  final double z;
  const GravTs(this.ts, this.x, this.y, this.z);
}

/// RR interval: [ts] unix seconds, [rrMs].
class RrTs {
  final int ts;
  final double rrMs;
  const RrTs(this.ts, this.rrMs);
}

/// Raw respiration ADC sample: [ts] unix seconds.
class RespTs {
  final int ts;
  final double raw;
  const RespTs(this.ts, this.raw);
}

/// A scored stage span. [stage] ∈ {'wake','light','deep','rem'}.
class StageSegment {
  final int start;
  final int end;
  final String stage;
  const StageSegment(this.start, this.end, this.stage);
  Map<String, dynamic> toJson() => {'start': start, 'end': end, 'stage': stage};
}

/// One detected sleep session + its hypnogram.
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
  final int solS;
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

/// Advanced sleep stager — constants + the full V1/V2 algorithm.
class AdvancedSleepStager {
  // ── Stage-0 constants ───────────────────────────────────────────────────────
  static const double gravityStillThresholdG = 0.01;
  static const int stillWindowMin = 15;
  static const double stillFraction = 0.70;
  static const int maxGapMin = 20;
  static const int mergeMin = 15;
  static const int minSleepMin = 60;
  static const double defaultIntervalS = 60.0;
  static const int secondsPerDay = 86400;
  static const int minWindowSamples = 3;
  static const double hrSleepBaselineMult = 1.05;
  static const int hrRefineMinSamples = 30;
  static const int onsetPersistEpochs = 3;

  // Daytime guard (#90)
  static const int daytimeBandStartHour = 11;
  static const int daytimeBandEndHour = 20;
  static const int nightContinuationGapMin = 90;
  static const int daytimeMinSleepMin = 90;
  static const double daytimeRestingHRMult = 0.95;

  // In-bed cap (#547)
  static const int maxMainSleepSpanS = 16 * 60 * 60; // 57600

  // Morning-stillness (#531)
  static const int morningStillnessWindowMin = 180;
  static const double morningReonsetRestingHRMult = 0.90;
  static const int bandStateAsleep = 2;
  static const double morningReonsetBandAsleepFrac = 0.6;

  // Off-wrist (#500)
  static const int offWristHRGapMin = 20;
  static const double maxOffWristSleepFraction = 0.5;
  static const int hrDenseSpacingS = 600;

  // Sparse gravity (#308)
  static const double sparseGravitySpanFrac = 0.5;
  static const double hrSleepBandMult = hrSleepBaselineMult;
  static const int sparseBridgeGapMin = 90;

  // Stage 1-3
  static const double epochS = 30.0;
  static const double featureWindowS = 5 * 60.0;
  static const double ckCountDivisor = 100.0;
  static const double ckCountClip = 300.0;
  static const double moveDeltaThresholdG = 0.01;
  static const double hrDogSigma1S = 120.0;
  static const double hrDogSigma2S = 600.0;

  static const double stageHRLowPct = 25.0;
  static const double stageHRHighPct = 70.0;
  static const double stageHRVHighPct = 70.0;
  static const double stageHRVarHighPct = 65.0;
  static const double stageRRVHighPct = 65.0;
  static const double stageRRVLowPct = 50.0;
  static const double stageWakeMoveFrac = 0.15;
  static const double stageStillMoveFrac = 0.10;

  static const double cardiacSparseEpochFrac = 0.5;
  static const int smoothEpochs = 5;
  static const double noREMAfterOnsetMin = 15.0;
  static const double deepFirstFraction = 1.0 / 3.0;
  static const int fragmentMergeEpochs = 6;

  static const List<double> ckWeights = [106, 54, 58, 76, 230, 74, 67];
  static const double ckScale = 0.001;
  static const int ckBack = 4;
  static const int ckFwd = 2;

  // ── Public entry point ──────────────────────────────────────────────────────

  /// Detect + stage all sleep sessions over the supplied 1 Hz streams.
  ///
  /// [tzOffsetSec] local-time offset (seconds) for the daytime/morning guards.
  /// [useV2] selects the experimental z-score+Viterbi per-session staging path
  /// (default false → V1 percentile-band classifier); `useSleepStagerV2` [wristOff]/[bandSleepState] are optional auxiliary
  /// signals for the off-wrist / morning-stillness guards.
  static List<SleepSession> detectSleep(
    List<GravTs> gravity,
    List<HrTs> hr, {
    List<RrTs> rr = const [],
    List<RespTs> resp = const [],
    int tzOffsetSec = 0,
    bool useV2 = false,
    List<List<int>> wristOff = const [], // each [start,end]
    List<List<int>> bandSleepState = const [], // each [ts,state]
  }) {
    final grav = [...gravity]..sort((a, b) => a.ts.compareTo(b.ts));
    if (grav.length < 2) return const [];
    final hrS = [...hr]..sort((a, b) => a.ts.compareTo(b.ts));
    final rrS = [...rr]..sort((a, b) => a.ts.compareTo(b.ts));
    final respS = [...resp]..sort((a, b) => a.ts.compareTo(b.ts));

    final baseline = _hrBaseline(hrS);
    final sparse = _isGravitySparse(grav, hrS);

    final deltas = _gravityDeltas(grav);
    final flags = _classifyStill(grav, deltas);
    var runs = _buildRuns(grav, flags, sparse, hrS, baseline);
    runs = _mergePeriods(runs, mergeMin);
    runs = _bridgeSparseSleep(runs, sparse, hrS, baseline);

    const minSleepS = minSleepMin * 60;
    const continuationGapS = nightContinuationGapMin * 60;
    int? chainPrevEnd;
    var chainFromOvernight = false;
    final sessions = <SleepSession>[];

    for (final p in runs) {
      if (p.stage != 'sleep') continue;
      if ((p.end - p.start) <= minSleepS) continue; // strict > 60 min
      if ((p.end - p.start) > maxMainSleepSpanS) continue; // #547 drop
      if (!_confirmSleepWithHR(p, hrS, baseline)) continue;
      if (_offWristFraction(p, hrS, wristOff) >= maxOffWristSleepFraction) {
        continue; // #500, before night-tail exemption
      }

      final resting = _sessionRestingHR(p.start, p.end, hrS);
      final continuesChain = chainPrevEnd != null
          ? (p.start - chainPrevEnd <= continuationGapS)
          : false;
      final isNightTail = continuesChain && chainFromOvernight;
      final morningWakeEnd = chainFromOvernight ? chainPrevEnd : null;

      if (_isDaytimeCenter(p, tzOffsetSec) &&
          !_passesMorningStillnessGuard(
              p, resting, baseline, morningWakeEnd, bandSleepState) &&
          !isNightTail) {
        continue;
      }

      final stages = useV2
          ? _stageSessionV2(p.start, p.end, grav, hrS, rrS)
          : _stageSession(p.start, p.end, grav, hrS, rrS, respS);
      final eff = _efficiency(p.start, p.end, stages);
      final avgHrv = _sessionAvgHRV(p.start, p.end, rrS);
      sessions.add(SleepSession(
        start: p.start,
        end: p.end,
        efficiency: eff,
        stages: stages,
        restingHr: resting,
        avgHrv: avgHrv,
      ));

      if (!continuesChain) {
        chainFromOvernight = _isOvernightOnset(p.start, tzOffsetSec);
      }
      chainPrevEnd = p.end;
    }
    sessions.sort((a, b) => a.start.compareTo(b.start));
    return sessions;
  }

  /// Stage a KNOWN in-bed window into a single [SleepSession] WITHOUT running
  /// detection — for a manual / user-confirmed sleep window (no auto window was
  /// found, or the user corrected it). Deliberately bypasses EVERY detection
  /// gate (the 3 h minimum, daytime-center guard, HR confirmation, off-wrist
  /// fraction): the window is asserted by the human, so we do not re-litigate
  /// whether it is sleep — we only label the stages within it. Staging itself
  /// runs through the SAME [_stageSession]/[_stageSessionV2] code the auto path
  /// uses, so the single-source invariant holds (only the WINDOW boundary is
  /// forced, never the staging math). Seconds with no data inside [startSec,
  /// endSec) simply stay unstaged (wake) — honest about gaps, never fabricated.
  static SleepSession stageWindow(
    int startSec,
    int endSec,
    List<GravTs> gravity,
    List<HrTs> hr, {
    List<RrTs> rr = const [],
    List<RespTs> resp = const [],
    bool useV2 = false,
  }) {
    final stages = useV2
        ? _stageSessionV2(startSec, endSec, gravity, hr, rr)
        : _stageSession(startSec, endSec, gravity, hr, rr, resp);
    return SleepSession(
      start: startSec,
      end: endSec,
      efficiency: _efficiency(startSec, endSec, stages),
      stages: stages,
      restingHr: _sessionRestingHR(startSec, endSec, hr),
      avgHrv: _sessionAvgHRV(startSec, endSec, rr),
    );
  }

  /// Convenience: the MAIN sleep (longest TST session) as a [Metric], with its
  /// AASM metrics + 4-class hypnogram. Absent when no qualifying sleep.
  static Metric<SleepSession> mainSleep(
    List<GravTs> gravity,
    List<HrTs> hr, {
    List<RrTs> rr = const [],
    List<RespTs> resp = const [],
    int tzOffsetSec = 0,
    bool useV2 = false,
  }) {
    const inputs = ['accel_1hz', 'hr_1hz', 'rr_ms'];
    final sessions = detectSleep(gravity, hr,
        rr: rr, resp: resp, tzOffsetSec: tzOffsetSec, useV2: useV2);
    if (sessions.isEmpty) {
      return const Metric<SleepSession>.absent(
        tier: Tier.estimate,
        inputs_used: inputs,
        note: 'no qualifying sleep detected',
      );
    }
    // Pick the session with the most total sleep time.
    SleepSession best = sessions.first;
    var bestTst = hypnogramMetrics(best).tstS;
    for (final s in sessions.skip(1)) {
      final t = hypnogramMetrics(s).tstS;
      if (t > bestTst) {
        bestTst = t;
        best = s;
      }
    }
    return Metric<SleepSession>(
      value: best,
      confidence: 0.5,
      tier: Tier.estimate,
      inputs_used: inputs,
      note: '${useV2 ? "V2" : "V1"} 4-class sleep ESTIMATE '
          '(wake/light/deep/rem); wrist autonomic, never PSG',
    );
  }

  // ── Stage-0 helpers ─────────────────────────────────────────────────────────

  static List<double> _gravityDeltas(List<GravTs> g) {
    final n = g.length;
    final out = List<double>.filled(n, 0);
    for (var i = 1; i < n; i++) {
      final dx = g[i - 1].x - g[i].x;
      final dy = g[i - 1].y - g[i].y;
      final dz = g[i - 1].z - g[i].z;
      out[i] = math.sqrt(dx * dx + dy * dy + dz * dz);
    }
    return out;
  }

  static double _medianIntervalS(List<int> times) {
    if (times.length < 2) return defaultIntervalS;
    final gaps = <int>[];
    for (var i = 0; i < times.length - 1; i++) {
      final g = times[i + 1] - times[i];
      if (g > 0 && g < 300) gaps.add(g);
    }
    if (gaps.isEmpty) return 60;
    gaps.sort();
    return math.max(gaps[gaps.length ~/ 2].toDouble(), 1.0);
  }

  static int _windowSize(List<int> times) {
    final interval = _medianIntervalS(times);
    return math.max(minWindowSamples, ((stillWindowMin * 60) / interval).toInt());
  }

  static double _largestGapS(List<int> times) {
    if (times.length < 2) return 0;
    var m = 0;
    for (var i = 0; i < times.length - 1; i++) {
      final g = times[i + 1] - times[i];
      if (g > m) m = g;
    }
    return m.toDouble();
  }

  static bool _isGravitySparse(List<GravTs> grav, List<HrTs> hr) {
    if (grav.length < 2 || hr.length < 2) return false;
    final hrSpan = hr.last.ts - hr.first.ts;
    if (hrSpan <= 0) return false;
    final gravSpan = grav.last.ts - grav.first.ts;
    if (gravSpan < sparseGravitySpanFrac * hrSpan) return true;
    return _largestGapS([for (final g in grav) g.ts]) > maxGapMin * 60;
  }

  static double? _hrBaseline(List<HrTs> hr) {
    if (hr.isEmpty) return null;
    return _median([for (final h in hr) h.bpm]);
  }

  static bool _hrSleepBandAcross(int a, int b, List<HrTs> hr, double? baseline) {
    if (baseline == null) return false;
    final seg = [for (final h in hr) if (h.ts > a && h.ts <= b) h.bpm];
    if (seg.isEmpty) return false;
    final meanHr = seg.reduce((x, y) => x + y) / seg.length;
    return meanHr <= baseline * hrSleepBandMult;
  }

  static List<bool> _classifyStill(List<GravTs> grav, List<double> deltas) {
    final n = grav.length;
    if (n < 2) return List<bool>.filled(n, false);
    final half = _windowSize([for (final g in grav) g.ts]) ~/ 2;
    final stillPrefix = List<int>.filled(n + 1, 0);
    for (var i = 0; i < n; i++) {
      stillPrefix[i + 1] =
          stillPrefix[i] + (deltas[i] < gravityStillThresholdG ? 1 : 0);
    }
    final flags = List<bool>.filled(n, false);
    for (var i = 0; i < n; i++) {
      final lo = math.max(0, i - half);
      final hi = math.min(n, i + half + 1);
      final stillCount = stillPrefix[hi] - stillPrefix[lo];
      flags[i] = (stillCount / (hi - lo)) >= stillFraction;
    }
    return flags;
  }

  static List<_Period> _buildRuns(List<GravTs> grav, List<bool> flags,
      bool sparse, List<HrTs> hr, double? baseline) {
    final n = grav.length;
    if (n == 0) return const [];
    final times = [for (final g in grav) g.ts];
    const maxGapS = maxGapMin * 60;
    final periods = <_Period>[];
    var runStart = 0;
    for (var i = 1; i <= n; i++) {
      final atEnd = i == n;
      bool close;
      if (atEnd) {
        close = true;
      } else {
        final classChanged = flags[i] != flags[runStart];
        var gapExceeded = (times[i] - times[i - 1]) > maxGapS;
        if (sparse &&
            gapExceeded &&
            !classChanged &&
            flags[runStart] &&
            _hrSleepBandAcross(times[i - 1], times[i], hr, baseline)) {
          gapExceeded = false;
        }
        close = classChanged || gapExceeded;
      }
      if (close) {
        periods.add(_Period(
          flags[runStart] ? 'sleep' : 'active',
          times[runStart],
          times[i - 1],
        ));
        runStart = i;
      }
    }
    return periods;
  }

  static List<_Period> _mergePeriods(List<_Period> periods, int mergeMinutes) {
    final thresholdS = mergeMinutes * 60;
    final pending = [...periods];
    final merged = <_Period>[];
    var i = 0;
    while (i < pending.length) {
      final current = pending[i];
      final tooShort = (current.end - current.start) < thresholdS;
      if (!tooShort) {
        merged.add(current);
        i += 1;
        continue;
      }
      final hasPrev = i > 0 && merged.isNotEmpty;
      final hasNext = i + 1 < pending.length;
      final bridgesSame =
          hasPrev && hasNext && pending[i - 1].stage == pending[i + 1].stage;
      if (bridgesSame) {
        final prev = merged.removeLast();
        merged.add(_Period(prev.stage, prev.start, pending[i + 1].end));
        i += 2;
      } else if (hasNext) {
        pending[i + 1] =
            _Period(pending[i + 1].stage, current.start, pending[i + 1].end);
        i += 1;
      } else if (hasPrev) {
        final prev = merged.removeLast();
        merged.add(_Period(prev.stage, prev.start, current.end));
        i += 1;
      } else {
        i += 1;
      }
    }
    return merged;
  }

  static List<_Period> _bridgeSparseSleep(
      List<_Period> periods, bool sparse, List<HrTs> hr, double? baseline) {
    if (!sparse || periods.isEmpty) return periods;
    const bridgeGapS = sparseBridgeGapMin * 60;
    final out = <_Period>[];
    for (final p in periods) {
      if (out.isNotEmpty && out.last.stage == 'sleep' && p.stage == 'sleep') {
        final gap = p.start - out.last.end;
        if (gap >= 0 &&
            gap <= bridgeGapS &&
            _hrSleepBandAcross(out.last.end, p.start, hr, baseline)) {
          out[out.length - 1] = _Period('sleep', out.last.start, p.end);
          continue;
        }
      }
      out.add(p);
    }
    return out;
  }

  // ── HR refinement / guards ──────────────────────────────────────────────────

  static List<HrTs> _rowsBetween(List<HrTs> rows, int start, int end) =>
      [for (final r in rows) if (r.ts >= start && r.ts <= end) r];

  static bool _confirmSleepWithHR(_Period p, List<HrTs> hr, double? baseline) {
    if (baseline == null) return true;
    final seg = _rowsBetween(hr, p.start, p.end);
    if (seg.length < hrRefineMinSamples) return true;
    final meanHr = seg.map((r) => r.bpm).reduce((a, b) => a + b) / seg.length;
    return meanHr <= baseline * hrSleepBaselineMult;
  }

  static int _secOfDay(int local) => ((local % secondsPerDay) + secondsPerDay) % secondsPerDay;

  static bool _isDaytimeCenter(_Period p, int tz) {
    final center = p.start + (p.end - p.start) ~/ 2;
    final hour = _secOfDay(center + tz) ~/ 3600;
    return hour >= daytimeBandStartHour && hour < daytimeBandEndHour;
  }

  static bool _isOvernightOnset(int start, int tz) {
    final hour = _secOfDay(start + tz) ~/ 3600;
    return !(hour >= daytimeBandStartHour && hour < daytimeBandEndHour);
  }

  static bool _passesDaytimeGuard(_Period p, int? restingHR, double? baseline) {
    if ((p.end - p.start) < daytimeMinSleepMin * 60) return false;
    if (baseline == null || restingHR == null) return false;
    return restingHR <= baseline * daytimeRestingHRMult;
  }

  static bool _bandStateConfirmsAsleep(_Period p, List<List<int>> bandSleepState) {
    final inBlock =
        [for (final b in bandSleepState) if (b[0] >= p.start && b[0] <= p.end) b];
    if (inBlock.isEmpty) return false;
    final asleep = inBlock.where((b) => b[1] == bandStateAsleep).length;
    return asleep / inBlock.length >= morningReonsetBandAsleepFrac;
  }

  static bool _passesMorningStillnessGuard(_Period p, int? restingHR,
      double? baseline, int? morningWakeEnd, List<List<int>> bandSleepState) {
    if (morningWakeEnd == null ||
        p.start < morningWakeEnd ||
        (p.start - morningWakeEnd) > morningStillnessWindowMin * 60) {
      return _passesDaytimeGuard(p, restingHR, baseline);
    }
    if (!_passesDaytimeGuard(p, restingHR, baseline)) return false;
    if (_bandStateConfirmsAsleep(p, bandSleepState)) return true;
    if (baseline == null || restingHR == null) return false;
    return restingHR <= baseline * morningReonsetRestingHRMult;
  }

  // Off-wrist (#500)
  static List<List<int>> _offWristHRGapSpans(_Period p, List<HrTs> hr) {
    if (hr.isEmpty || p.end <= p.start) return const [];
    final sortedAll = [...hr]..sort((a, b) => a.ts.compareTo(b.ts));
    final streamSpan = sortedAll.last.ts - sortedAll.first.ts;
    if (streamSpan >= hrDenseSpacingS && hr.length < streamSpan ~/ hrDenseSpacingS) {
      return const [];
    }
    const gapS = offWristHRGapMin * 60;
    final seg = _rowsBetween(hr, p.start, p.end)
      ..sort((a, b) => a.ts.compareTo(b.ts));
    if (seg.isEmpty) {
      return (p.end - p.start) >= gapS
          ? [
              [p.start, p.end]
            ]
          : const [];
    }
    final spans = <List<int>>[];
    if (seg.first.ts - p.start >= gapS) spans.add([p.start, seg.first.ts]);
    for (var i = 1; i < seg.length; i++) {
      if (seg[i].ts - seg[i - 1].ts >= gapS) spans.add([seg[i - 1].ts, seg[i].ts]);
    }
    if (p.end - seg.last.ts >= gapS) spans.add([seg.last.ts, p.end]);
    return spans;
  }

  static double _offWristFraction(_Period p, List<HrTs> hr, List<List<int>> wristOff) {
    final dur = p.end - p.start;
    if (dur <= 0) return 0;
    final spans = [..._offWristHRGapSpans(p, hr)];
    for (final w in wristOff) {
      final s = math.max(w[0], p.start);
      final e = math.min(w[1], p.end);
      if (e > s) spans.add([s, e]);
    }
    if (spans.isEmpty) return 0;
    spans.sort((a, b) => a[0].compareTo(b[0]));
    var covered = 0;
    var curStart = spans[0][0];
    var curEnd = spans[0][1];
    for (final sp in spans.skip(1)) {
      if (sp[0] <= curEnd) {
        curEnd = math.max(curEnd, sp[1]);
      } else {
        covered += curEnd - curStart;
        curStart = sp[0];
        curEnd = sp[1];
      }
    }
    covered += curEnd - curStart;
    return covered / dur;
  }

  static double _efficiency(int start, int end, List<StageSegment> stages) {
    final inBed = end - start;
    if (inBed <= 0) return 0;
    var wake = 0;
    for (final s in stages) {
      if (s.stage == 'wake') wake += s.end - s.start;
    }
    final asleep = math.max(0, inBed - wake);
    return math.min(1.0, asleep / inBed);
  }

  static int? _sessionRestingHR(int start, int end, List<HrTs> hr) {
    final seg = _rowsBetween(hr, start, end);
    if (seg.isEmpty) return null;
    const windowS = 300;
    var t = start;
    final means = <double>[];
    while (t < end) {
      final win = [for (final r in seg) if (r.ts >= t && r.ts < t + windowS) r.bpm];
      if (win.isNotEmpty) means.add(win.reduce((a, b) => a + b) / win.length);
      t += windowS;
    }
    if (means.isNotEmpty) return means.reduce(math.min).round();
    final all = seg.map((r) => r.bpm).reduce((a, b) => a + b) / seg.length;
    return all.round();
  }

  static double? _sessionAvgHRV(int start, int end, List<RrTs> rr) {
    if (start <= 0 || end <= start || rr.isEmpty) return null;
    final rrMs = <double>[for (final r in rr) r.rrMs];
    final rrTsMs = <double>[for (final r in rr) r.ts * 1000.0];
    final metric = sleepSessionWindowedRmssd(
      rrMs,
      rrTsMs,
      startSec: start,
      endSec: end,
    );
    return metric.present ? metric.value : null;
  }

  // ── Epoch grid ──────────────────────────────────────────────────────────────

  static _EpochGrid _buildEpochGrid(
      int start, int end, List<GravTs> gSeg, List<HrTs> hSeg, List<RrTs> rSeg, List<RespTs> respSeg) {
    if (end <= start) {
      return _EpochGrid([start.toDouble()], 0, [], [], [], [], [], []);
    }
    final nEpochs = math.max(1, ((end - start) / epochS).ceil());
    final edges = <double>[for (var i = 0; i <= nEpochs; i++) start + i * epochS];
    edges[nEpochs] = math.max(edges[nEpochs], end.toDouble());

    int? idx(int ts) {
      if (ts < start || ts >= end) {
        if (ts == end) return nEpochs - 1;
        return null;
      }
      final i = ((ts - start) / epochS).toInt();
      return math.min(i, nEpochs - 1);
    }

    final counts = List<double>.filled(nEpochs, 0);
    final gravN = List<int>.filled(nEpochs, 0);
    final moveN = List<int>.filled(nEpochs, 0);
    final hrSum = List<double>.filled(nEpochs, 0);
    final hrCnt = List<int>.filled(nEpochs, 0);
    final rrBuckets = List<List<double>>.generate(nEpochs, (_) => <double>[]);
    final respBuckets = List<List<double>>.generate(nEpochs, (_) => <double>[]);

    // gravity deltas over the segment.
    final gDeltas = _gravityDeltas(gSeg);
    for (var k = 0; k < gSeg.length; k++) {
      final i = idx(gSeg[k].ts);
      if (i == null) continue;
      counts[i] += gDeltas[k];
      gravN[i] += 1;
      if (gDeltas[k] >= moveDeltaThresholdG) moveN[i] += 1;
    }
    for (final h in hSeg) {
      final i = idx(h.ts);
      if (i == null) continue;
      hrSum[i] += h.bpm;
      hrCnt[i] += 1;
    }
    for (final r in rSeg) {
      final i = idx(r.ts);
      if (i == null) continue;
      rrBuckets[i].add(r.rrMs);
    }
    for (final r in respSeg) {
      final i = idx(r.ts);
      if (i == null) continue;
      respBuckets[i].add(r.raw);
    }

    final hr = List<double>.filled(nEpochs, double.nan);
    final moveFrac = List<double>.filled(nEpochs, 1.0);
    for (var i = 0; i < nEpochs; i++) {
      if (hrCnt[i] > 0) hr[i] = hrSum[i] / hrCnt[i];
      moveFrac[i] = gravN[i] > 0 ? moveN[i] / gravN[i] : 1.0;
    }
    return _EpochGrid(edges, nEpochs, counts, hr, moveFrac, rrBuckets, respBuckets,
        _coleKripke(_rescaleCounts(counts)));
  }

  static List<double> _rescaleCounts(List<double> counts) =>
      [for (final c in counts) math.min(c / ckCountDivisor, ckCountClip)];

  static List<bool> _coleKripke(List<double> rescaled) {
    final n = rescaled.length;
    final flags = List<bool>.filled(n, false);
    for (var i = 0; i < n; i++) {
      var si = 0.0;
      for (var k = 0; k < ckWeights.length; k++) {
        final j = i - ckBack + k;
        final a = (j >= 0 && j < n) ? rescaled[j] : 0.0;
        si += ckWeights[k] * a;
      }
      si *= ckScale;
      flags[i] = si < 1.0;
    }
    return flags;
  }

  static List<int> _onsetAndFinalWake(List<bool> ckFlags) {
    final n = ckFlags.length;
    if (n == 0) return [0, 0];
    var run = 0;
    int? onset;
    for (var i = 0; i < n; i++) {
      run = ckFlags[i] ? run + 1 : 0;
      if (run >= onsetPersistEpochs) {
        onset = i - onsetPersistEpochs + 1;
        break;
      }
    }
    int? finalWake;
    for (var i = n - 1; i >= 0; i--) {
      if (ckFlags[i]) {
        finalWake = i;
        break;
      }
    }
    var o = onset ?? 0;
    var f = finalWake ?? (n - 1);
    if (f < o) f = n - 1;
    return [o, f];
  }

  // ── DoG HR variability ──────────────────────────────────────────────────────

  static List<double> _gaussianKernel(double sigmaS, {double dtS = 30}) {
    final sigma = math.max(sigmaS / dtS, 1e-6);
    final radius = math.max(1, (3 * sigma).ceil());
    final k = <double>[
      for (var x = -radius; x <= radius; x++) math.exp(-0.5 * (x / sigma) * (x / sigma))
    ];
    final sum = k.reduce((a, b) => a + b);
    return [for (final v in k) v / sum];
  }

  static List<double> _convolveReflect(List<double> x, List<double> kernel) {
    final r = kernel.length ~/ 2;
    if (r == 0 || x.length <= r) return x;
    final padded = <double>[];
    for (var i = 0; i < r; i++) {
      padded.add(x[r - i]);
    }
    padded.addAll(x);
    for (var i = 0; i < r; i++) {
      padded.add(x[x.length - 2 - i]);
    }
    final m = kernel.length;
    final out = <double>[];
    for (var i = 0; i <= padded.length - m; i++) {
      var acc = 0.0;
      for (var j = 0; j < m; j++) {
        acc += padded[i + j] * kernel[m - 1 - j];
      }
      out.add(acc);
      if (out.length == x.length) break;
    }
    return out;
  }

  static List<double> _dogHRVariability(List<double> hrPerEpoch) {
    final n = hrPerEpoch.length;
    if (n == 0) return const [];
    final maskIdx = [for (var i = 0; i < n; i++) if (!hrPerEpoch[i].isNaN) i];
    if (maskIdx.isEmpty) return List<double>.filled(n, 0);
    final filled = List<double>.filled(n, 0);
    for (var i = 0; i < n; i++) {
      if (!hrPerEpoch[i].isNaN) {
        filled[i] = hrPerEpoch[i];
      } else if (i <= maskIdx.first) {
        filled[i] = hrPerEpoch[maskIdx.first];
      } else if (i >= maskIdx.last) {
        filled[i] = hrPerEpoch[maskIdx.last];
      } else {
        var lo = maskIdx.first, hi = maskIdx.last;
        for (final m in maskIdx) {
          if (m <= i) lo = m;
          if (m >= i) {
            hi = m;
            break;
          }
        }
        if (hi == lo) {
          filled[i] = hrPerEpoch[lo];
        } else {
          filled[i] = hrPerEpoch[lo] +
              (i - lo) / (hi - lo) * (hrPerEpoch[hi] - hrPerEpoch[lo]);
        }
      }
    }
    final k1 = _gaussianKernel(hrDogSigma1S);
    final k2 = _gaussianKernel(hrDogSigma2S);
    final g1 = _convolveReflect(filled, k1);
    final g2 = _convolveReflect(filled, k2);
    return [for (var i = 0; i < n; i++) g1[i] - g2[i]];
  }

  // ── Stage-1 feature extraction ──────────────────────────────────────────────

  static List<_EpochFeatures> _extractFeatures(
      _EpochGrid grid, int start, int onsetIdx, int finalWakeIdx) {
    final n = grid.nEpochs;
    final dogHR = _dogHRVariability(grid.hr);
    final halfW = (featureWindowS / epochS / 2).round();
    final span = math.max(1, finalWakeIdx - onsetIdx);
    final out = <_EpochFeatures>[];
    for (var i = 0; i < n; i++) {
      final lo = math.max(0, i - halfW);
      final hi = math.min(n, i + halfW + 1);
      final winDog = dogHR.isEmpty ? <double>[0.0] : dogHR.sublist(lo, hi);
      final hrVar = winDog.length >= 2 ? _populationStd(winDog) : double.nan;

      final winRR = <double>[];
      final winResp = <double>[];
      for (var j = lo; j < hi; j++) {
        winRR.addAll(grid.rrBuckets[j]);
        winResp.addAll(grid.respBuckets[j]);
      }
      final filteredRR = _rangeFilter(winRR);
      final rmssd =
          filteredRR.length >= 5 ? (_rmssdRaw(filteredRR) ?? double.nan) : double.nan;
      final sdnn =
          filteredRR.length >= 5 ? (_sdnnRaw(filteredRR) ?? double.nan) : double.nan;
      final rr = _respRateAndRRV(winResp);
      final clock = _clampD((i - onsetIdx) / span, 0, 1);
      final ckSleep = i < grid.ckFlags.length ? grid.ckFlags[i] : true;
      out.add(_EpochFeatures(
        index: i,
        midTs: (grid.edges[i] + grid.edges[i + 1]) / 2,
        moveFrac: grid.moveFrac[i],
        ckSleep: ckSleep,
        hr: grid.hr[i],
        hrVar: hrVar,
        rmssd: rmssd,
        sdnn: sdnn,
        respRate: rr[0],
        rrv: rr[1],
        clock: clock,
      ));
    }
    return out;
  }

  /// (rate, rrv) from raw 1 Hz resp ADC, dtS=1.0.
  static List<double> _respRateAndRRV(List<double> respRaw, {double dtS = 1.0}) {
    if (respRaw.length < 8) return [double.nan, double.nan];
    final mean = respRaw.reduce((a, b) => a + b) / respRaw.length;
    final x = [for (final v in respRaw) v - mean];
    if (x.every((v) => v.abs() < 1e-12)) return [double.nan, double.nan];
    final std = _populationStd(x);
    if (std <= 0) return [double.nan, double.nan];
    final minDistance = math.max(2, (2.0 / dtS).round());
    final peaks = _findPeaks(x, minDistance, 0.0);
    if (peaks.length < 3) return [double.nan, double.nan];
    final intervals = <double>[];
    for (var i = 1; i < peaks.length; i++) {
      final iv = (peaks[i] - peaks[i - 1]) * dtS;
      if (iv >= 1.5 && iv <= 12.0) intervals.add(iv);
    }
    if (intervals.length < 2) return [double.nan, double.nan];
    final rate = 60 / _median(intervals)!;
    final rrv = _populationStd(intervals);
    return [rate, rrv];
  }

  static List<int> _findPeaks(List<double> x, int distance, double height) {
    final n = x.length;
    if (n < 3) return const [];
    final candidates = <int>[];
    var i = 1;
    while (i < n - 1) {
      if (x[i] > x[i - 1] && x[i] >= height) {
        var j = i;
        while (j + 1 < n && x[j + 1] == x[i]) {
          j++;
        }
        if (j + 1 < n && x[j + 1] < x[i]) {
          candidates.add((i + j) ~/ 2);
        }
        i = j + 1;
      } else {
        i += 1;
      }
    }
    if (distance <= 1 || candidates.isEmpty) return candidates;
    final byHeight = [...candidates]
      ..sort((a, b) {
        if (x[a] != x[b]) return x[b].compareTo(x[a]);
        return a.compareTo(b);
      });
    final keep = {for (final c in candidates) c: true};
    for (final p in byHeight) {
      if (!keep[p]!) continue;
      for (final q in candidates) {
        if (q == p || !keep[q]!) continue;
        if ((q - p).abs() < distance) keep[q] = false;
      }
    }
    return [for (final c in candidates) if (keep[c]!) c];
  }

  // ── Stage-2 classifier ──────────────────────────────────────────────────────

  static List<String> _classifyEpochs(List<_EpochFeatures> features) {
    final anyCk = features.any((f) => f.ckSleep);
    final sleepFeats = anyCk ? features.where((f) => f.ckSleep).toList() : features;
    final hrLo = _pct([for (final f in sleepFeats) f.hr], stageHRLowPct);
    final hrHi = _pct([for (final f in sleepFeats) f.hr], stageHRHighPct);
    final rmssdHi = _pct([for (final f in sleepFeats) f.rmssd], stageHRVHighPct);
    final hrvarHi = _pct([for (final f in sleepFeats) f.hrVar], stageHRVarHighPct);
    final rrvHi = _pct([for (final f in sleepFeats) f.rrv], stageRRVHighPct);
    final rrvLo = _pct([for (final f in sleepFeats) f.rrv], stageRRVLowPct);
    final cardiacSparse = _isCardiacSparse(sleepFeats);
    return [
      for (final f in features)
        _classifyOne(f, hrLo, hrHi, rmssdHi, hrvarHi, rrvHi, rrvLo, cardiacSparse)
    ];
  }

  static double? _pct(List<double> values, double pct) {
    final finite = [for (final v in values) if (v.isFinite) v];
    if (finite.isEmpty) return null;
    finite.sort();
    return _percentileSorted(finite, pct);
  }

  static bool _isCardiacSparse(List<_EpochFeatures> sleepFeats) {
    if (sleepFeats.isEmpty) return false;
    final missing = sleepFeats.where((f) => !f.rmssd.isFinite).length;
    return missing >= cardiacSparseEpochFrac * sleepFeats.length;
  }

  static String _classifyOne(_EpochFeatures f, double? hrLo, double? hrHi,
      double? rmssdHi, double? hrvarHi, double? rrvHi, double? rrvLo, bool cardiacSparse) {
    final hasHR = f.hr.isFinite;
    final hrLow = hasHR && hrLo != null && f.hr <= hrLo;
    final hrHigh = hasHR && hrHi != null && f.hr >= hrHi;
    final parasympOK = (!f.rmssd.isFinite) || (rmssdHi != null && f.rmssd >= rmssdHi);
    final hrvarHigh = f.hrVar.isFinite && hrvarHi != null && f.hrVar >= hrvarHi;
    final cardiacActivated = hrHigh || hrvarHigh;
    final cardiacActivatedForWake = cardiacSparse ? hrHigh : cardiacActivated;
    final rrvIrregular = f.rrv.isFinite && rrvHi != null && f.rrv >= rrvHi;
    final rrvRegular = (!f.rrv.isFinite) || (rrvLo != null && f.rrv <= rrvLo);
    final still = f.moveFrac <= stageStillMoveFrac;
    final moving = f.moveFrac >= stageWakeMoveFrac;

    if (moving && (cardiacActivatedForWake || !hasHR)) return 'wake';
    if (still && parasympOK && hrLow && rrvRegular) return 'deep';
    if (still && cardiacActivated && rrvIrregular) return 'rem';
    if (still && hrHigh && hrvarHigh && !f.rrv.isFinite) return 'rem';
    return 'light';
  }

  // ── Stage-3 post-processing ─────────────────────────────────────────────────

  static List<String> _smoothLabels(List<String> labels, {int window = smoothEpochs}) {
    final n = labels.length;
    if (n == 0 || window <= 1) return labels;
    var w = window;
    if (w.isEven) w += 1;
    final half = w ~/ 2;
    final out = List<String>.from(labels);
    for (var i = 0; i < n; i++) {
      final lo = math.max(0, i - half);
      final hi = math.min(n, i + half + 1);
      final counts = <String, int>{};
      final order = <String>[];
      for (var k = lo; k < hi; k++) {
        final s = labels[k];
        if (!counts.containsKey(s)) order.add(s);
        counts[s] = (counts[s] ?? 0) + 1;
      }
      final best = counts.values.reduce(math.max);
      final winners = [for (final s in order) if (counts[s] == best) s];
      out[i] = winners.contains(labels[i]) ? labels[i] : winners.first;
    }
    return out;
  }

  static List<String> _reimposePhysiology(
      List<String> labels, List<_EpochFeatures> features, int onsetIdx, int finalWakeIdx) {
    final noREMEpochs = (noREMAfterOnsetMin * 60 / epochS).round();
    final hasEarlyDeep = () {
      for (var i = 0; i < labels.length; i++) {
        if (labels[i] == 'deep' && features[i].clock <= deepFirstFraction) return true;
      }
      return false;
    }();
    final out = List<String>.from(labels);
    for (var i = 0; i < labels.length; i++) {
      if (i < onsetIdx || i > finalWakeIdx) continue;
      final f = features[i];
      if (out[i] == 'rem' && (i - onsetIdx) < noREMEpochs) out[i] = 'light';
      if (out[i] == 'deep' && f.clock > deepFirstFraction && hasEarlyDeep) {
        out[i] = 'light';
      }
    }
    return out;
  }

  static List<String> _mergeFragments(List<String> labels,
      {int thresholdEpochs = fragmentMergeEpochs}) {
    int depth(String s) => s == 'deep' ? 3 : (s == 'rem' ? 2 : (s == 'light' ? 1 : 0));
    final n = labels.length;
    if (n == 0 || thresholdEpochs <= 1) return labels;
    // Collapse to runs.
    var runs = <List<dynamic>>[]; // [stage, len]
    {
      var i = 0;
      while (i < n) {
        var j = i;
        while (j < n && labels[j] == labels[i]) {
          j++;
        }
        runs.add([labels[i], j - i]);
        i = j;
      }
    }
    if (runs.length < 2) return labels;
    final merged = <List<dynamic>>[];
    var i = 0;
    while (i < runs.length) {
      final cur = runs[i];
      final curLen = cur[1] as int;
      if (curLen >= thresholdEpochs) {
        merged.add([cur[0], curLen]);
        i += 1;
        continue;
      }
      final hasPrev = merged.isNotEmpty;
      final hasNext = i + 1 < runs.length;
      if (hasPrev && hasNext && merged.last[0] == runs[i + 1][0]) {
        merged.last[1] = (merged.last[1] as int) + curLen + (runs[i + 1][1] as int);
        i += 2;
      } else if (hasPrev && hasNext) {
        final prev = merged.last;
        final next = runs[i + 1];
        final prevLen = prev[1] as int, nextLen = next[1] as int;
        String winner;
        if (prevLen > nextLen) {
          winner = prev[0] as String;
        } else if (nextLen > prevLen) {
          winner = next[0] as String;
        } else {
          winner = depth(prev[0] as String) <= depth(next[0] as String)
              ? prev[0] as String
              : next[0] as String;
        }
        if (winner == prev[0]) {
          merged.last[1] = prevLen + curLen;
          i += 1;
        } else {
          runs[i + 1] = [next[0], nextLen + curLen];
          i += 1;
        }
      } else if (hasNext) {
        runs[i + 1] = [runs[i + 1][0], (runs[i + 1][1] as int) + curLen];
        i += 1;
      } else if (hasPrev) {
        merged.last[1] = (merged.last[1] as int) + curLen;
        i += 1;
      } else {
        merged.add([cur[0], curLen]);
        i += 1;
      }
    }
    final out = <String>[];
    for (final r in merged) {
      for (var k = 0; k < (r[1] as int); k++) {
        out.add(r[0] as String);
      }
    }
    // Length should match n.
    return out;
  }

  static List<StageSegment> _stageSession(int start, int end, List<GravTs> grav,
      List<HrTs> hr, List<RrTs> rr, List<RespTs> resp) {
    final gSeg = [for (final g in grav) if (g.ts >= start && g.ts <= end) g];
    if (gSeg.length < 2) return [StageSegment(start, end, 'light')];
    final hSeg = _rowsBetween(hr, start, end);
    final rSeg = [for (final r in rr) if (r.ts >= start && r.ts <= end) r];
    final respSeg = [for (final r in resp) if (r.ts >= start && r.ts <= end) r];
    final grid = _buildEpochGrid(start, end, gSeg, hSeg, rSeg, respSeg);
    if (grid.nEpochs == 0) return [StageSegment(start, end, 'light')];
    final ow = _onsetAndFinalWake(grid.ckFlags);
    final onsetIdx = ow[0], finalWakeIdx = ow[1];
    final feats = _extractFeatures(grid, start, onsetIdx, finalWakeIdx);
    var labels = _classifyEpochs(feats);
    labels = _smoothLabels(labels);
    labels = _reimposePhysiology(labels, feats, onsetIdx, finalWakeIdx);
    labels = _mergeFragments(labels);
    for (var i = 0; i < labels.length; i++) {
      if (i < onsetIdx || i > finalWakeIdx) labels[i] = 'wake';
    }
    return _buildSegments(labels, grid, end);
  }

  static List<StageSegment> _buildSegments(
      List<String> labels, _EpochGrid grid, int end) {
    final segments = <StageSegment>[];
    for (var i = 0; i < labels.length; i++) {
      final stage = labels[i];
      final segStart = grid.edges[i].round();
      final segEnd = grid.edges[i + 1].round();
      if (segments.isNotEmpty && segments.last.stage == stage) {
        segments[segments.length - 1] =
            StageSegment(segments.last.start, segEnd, stage);
      } else {
        segments.add(StageSegment(segStart, segEnd, stage));
      }
    }
    if (segments.isNotEmpty) {
      segments[segments.length - 1] =
          StageSegment(segments.last.start, end, segments.last.stage);
    }
    return segments;
  }

  // ══════════════════════════════════════════════════════════════════════════
  // V2 — z-scored emission + deep gate + cycle prior + Viterbi HMM.
  // ══════════════════════════════════════════════════════════════════════════

  static const List<String> _v2StageNames = ['deep', 'rem', 'light', 'awake'];
  static const int _v2PadLo = 330;
  static const int _v2PadHi = 390;
  static const double _v2DeepGateThresh = 0.20;
  static const double _v2DeepGateSlope = 5.0;
  static const double _v2JerkFloorMoveMult = 38.0;
  static const double _v2JerkFloorGateMult = 55.0;
  static const double _v2MotionGateBoost = 2.0;
  static const double _v2RespWeight = 0.6;

  static Map<String, double> _v2BaseLogPrior() => {
        'light': math.log(0.50),
        'deep': math.log(0.18),
        'rem': math.log(0.22),
        'awake': math.log(0.10),
      };

  // Transition matrix (from → to). EXACT.
  static const Map<String, Map<String, double>> _v2Transition = {
    'deep': {'deep': 0.90, 'rem': 0.005, 'light': 0.09, 'awake': 0.005},
    'rem': {'deep': 0.005, 'rem': 0.88, 'light': 0.10, 'awake': 0.015},
    'light': {'deep': 0.06, 'rem': 0.06, 'light': 0.85, 'awake': 0.03},
    'awake': {'deep': 0.01, 'rem': 0.02, 'light': 0.27, 'awake': 0.70},
  };

  static Map<String, double> _v2CyclePrior(double c) => {
        'deep': 1.2 * math.max(0, 1 - c / 0.55),
        'rem': 1.0 * c - (c < 0.12 ? 3.0 : 0.0),
        'light': 0.0,
        'awake': 0.0,
      };

  static List<StageSegment> _stageSessionV2(
      int start, int end, List<GravTs> grav, List<HrTs> hr, List<RrTs> rr) {
    final lo = start - _v2PadLo, hi = end + _v2PadHi;
    final gravW = [for (final g in grav) if (g.ts >= lo && g.ts < hi) g];
    final hrW = [for (final h in hr) if (h.ts >= lo && h.ts < hi) h];
    final rrW = [for (final r in rr) if (r.ts >= lo && r.ts < hi) r];
    final feats = _v2Features(start, end, gravW, hrW, rrW);
    if (feats.isEmpty) return [StageSegment(start, end, 'light')];
    final labels = _v2StageEpochs(feats);
    final segments = <StageSegment>[];
    for (var i = 0; i < feats.length; i++) {
      final stage = labels[i] == 'awake' ? 'wake' : labels[i];
      final segStart = i == 0 ? start : feats[i].start;
      final segEnd = i == feats.length - 1 ? end : feats[i + 1].start;
      if (segments.isNotEmpty && segments.last.stage == stage) {
        segments[segments.length - 1] =
            StageSegment(segments.last.start, segEnd, stage);
      } else {
        segments.add(StageSegment(segStart, segEnd, stage));
      }
    }
    return segments;
  }

  static List<_V2Epoch> _v2Features(
      int start, int end, List<GravTs> grav, List<HrTs> hr, List<RrTs> rr) {
    if (end <= start) return const [];
    final span = math.max(1, end - start).toDouble();

    // per-second aggregation
    final secHRsum = <int, double>{};
    final secHRcnt = <int, int>{};
    final secGx = <int, double>{}, secGy = <int, double>{}, secGz = <int, double>{};
    final secGcnt = <int, int>{};
    final rrBy = <int, List<double>>{};
    for (final h in hr) {
      secHRsum[h.ts] = (secHRsum[h.ts] ?? 0) + h.bpm;
      secHRcnt[h.ts] = (secHRcnt[h.ts] ?? 0) + 1;
    }
    for (final g in grav) {
      secGx[g.ts] = (secGx[g.ts] ?? 0) + g.x;
      secGy[g.ts] = (secGy[g.ts] ?? 0) + g.y;
      secGz[g.ts] = (secGz[g.ts] ?? 0) + g.z;
      secGcnt[g.ts] = (secGcnt[g.ts] ?? 0) + 1;
    }
    for (final r in rr) {
      (rrBy[r.ts] ??= []).add(r.rrMs);
    }
    double? secHR(int s) => secHRcnt.containsKey(s) ? secHRsum[s]! / secHRcnt[s]! : null;
    List<double>? secG(int s) => secGcnt.containsKey(s)
        ? [secGx[s]! / secGcnt[s]!, secGy[s]! / secGcnt[s]!, secGz[s]! / secGcnt[s]!]
        : null;

    // prefix sums over per-second HR grid for O(1) std windows
    if (secHRcnt.isEmpty) {
      // no HR — still build epochs, hr/hrVar/hrFlat null
    }
    final hrKeys = secHRcnt.keys.toList();
    final gridLo = hrKeys.isEmpty ? 0 : hrKeys.reduce(math.min);
    final gridHi = hrKeys.isEmpty ? -1 : hrKeys.reduce(math.max);
    final size = gridHi >= gridLo ? (gridHi - gridLo + 2) : 1;
    final pCnt = List<int>.filled(size, 0);
    final pSum = List<double>.filled(size, 0);
    final pSq = List<double>.filled(size, 0);
    if (gridHi >= gridLo) {
      for (var i = gridLo; i <= gridHi; i++) {
        final idx = i - gridLo;
        final v = secHR(i);
        pCnt[idx + 1] = pCnt[idx] + (v != null ? 1 : 0);
        pSum[idx + 1] = pSum[idx] + (v ?? 0);
        pSq[idx + 1] = pSq[idx] + (v != null ? v * v : 0);
      }
    }
    double? stdOfSeconds(int lo, int hi) {
      if (gridHi < gridLo) return null;
      final a = math.max(lo, gridLo) - gridLo;
      final b = math.min(hi, gridHi + 1) - gridLo;
      if (b <= a) return null;
      final cnt = pCnt[b] - pCnt[a];
      if (cnt < 2) return null;
      final n = cnt.toDouble();
      final sv = pSum[b] - pSum[a];
      final sq = pSq[b] - pSq[a];
      final m = sv / n;
      final variance = (sq - 2 * m * sv + n * m * m) / n;
      return math.sqrt(math.max(variance, 0));
    }

    // PASS 1
    final firstE = ((start + 29) ~/ 30) * 30;
    final raws = <_V2Raw>[];
    final allJerks = <double>[];
    var e = firstE;
    while (e < end) {
      final hrs = <double>[];
      final gseq = <List<double>>[];
      for (var s = e; s < e + 30; s++) {
        final v = secHR(s);
        if (v != null) hrs.add(v);
        final g = secG(s);
        if (g != null) gseq.add(g);
      }
      if (hrs.isEmpty && gseq.isEmpty) {
        e += 30;
        continue;
      }
      final jerks = <double>[];
      for (var i = 1; i < gseq.length; i++) {
        final dx = gseq[i - 1][0] - gseq[i][0];
        final dy = gseq[i - 1][1] - gseq[i][1];
        final dz = gseq[i - 1][2] - gseq[i][2];
        jerks.add(math.sqrt(dx * dx + dy * dy + dz * dz));
      }
      allJerks.addAll(jerks);
      final jerkMax = jerks.isEmpty ? 0.0 : jerks.reduce(math.max);
      final hrMean = hrs.isEmpty ? null : hrs.reduce((a, b) => a + b) / hrs.length;
      final hrVar = stdOfSeconds(e - 150, e + 30 + 150);
      final hrFlat11 = stdOfSeconds(e - 330, e + 30 + 360);
      final beats = <List<double>>[];
      for (var s = e - 90; s < e + 120; s++) {
        final list = rrBy[s];
        if (list != null) {
          for (final v in list) {
            beats.add([s.toDouble(), _clampD(v, 300, 2000)]);
          }
        }
      }
      beats.sort((a, b) {
        if (a[0] != b[0]) return a[0].compareTo(b[0]);
        return a[1].compareTo(b[1]);
      });
      final respReg = _v2RespRegularity(beats);
      raws.add(_V2Raw(
        start: e,
        hr: hrMean,
        hrVar: hrVar,
        hrFlat11: hrFlat11,
        jerks: jerks,
        gapSec: math.max(1, gseq.length - 1),
        jerkMax: jerkMax,
        respReg: respReg,
        clock: (e + 15 - start) / span,
      ));
      e += 30;
    }

    // jerkScale = median of all per-second jerks (lower-avg median for even n).
    double jerkScale;
    if (allJerks.isEmpty) {
      jerkScale = 1e-6;
    } else {
      final s = [...allJerks]..sort();
      final nn = s.length;
      jerkScale = nn.isOdd ? s[nn ~/ 2] : 0.5 * (s[nn ~/ 2 - 1] + s[nn ~/ 2]);
    }
    final moveThr = jerkScale * _v2JerkFloorMoveMult;

    // PASS 2
    final feats = <_V2Epoch>[];
    for (final r in raws) {
      final moves = r.jerks.where((j) => j > moveThr).length;
      feats.add(_V2Epoch(
        start: r.start,
        hr: r.hr,
        hrVar: r.hrVar,
        hrFlat11: r.hrFlat11,
        moveFrac: moves / r.gapSec,
        jerkMax: r.jerkMax,
        respReg: r.respReg,
        clock: r.clock,
        jerkScale: jerkScale,
      ));
    }
    return feats;
  }

  static double? _v2RespRegularity(List<List<double>> beats) {
    if (beats.length < 12) return null;
    final t0 = beats.first[0], tN = beats.last[0];
    if (tN <= t0) return null;
    final n = ((tN - t0) / 0.25 - 1e-9).ceil();
    if (n < 16) return null;
    final y = List<double>.filled(n, 0);
    var seg = 0;
    for (var i = 0; i < n; i++) {
      final t = t0 + 0.25 * i;
      while (seg < beats.length - 2 && beats[seg + 1][0] < t) {
        seg++;
      }
      final ta = beats[seg][0], tb = beats[seg + 1][0];
      final va = beats[seg][1], vb = beats[seg + 1][1];
      y[i] = tb <= ta ? va : va + _clampD((t - ta) / (tb - ta), 0, 1) * (vb - va);
    }
    final mean = y.reduce((a, b) => a + b) / n;
    for (var i = 0; i < n; i++) {
      y[i] -= mean;
    }
    final kLo = (0.15 * 0.25 * n).ceil();
    final kHi = (0.40 * 0.25 * n).floor();
    if (kHi < kLo || kLo < 0) return null;
    var maxP = 0.0, sumP = 0.0;
    for (var k = kLo; k <= kHi; k++) {
      final w = -2 * math.pi * k / n;
      var re = 0.0, im = 0.0;
      for (var j = 0; j < n; j++) {
        re += y[j] * math.cos(w * j);
        im += y[j] * math.sin(w * j);
      }
      final p = re * re + im * im;
      sumP += p;
      if (p > maxP) maxP = p;
    }
    if (sumP == 0) return null;
    return maxP / sumP;
  }

  static List<String> _v2StageEpochs(List<_V2Epoch> feats) {
    if (feats.isEmpty) return const [];
    double Function(double?) zfun(List<double?> vals) {
      final present = [for (final v in vals) if (v != null) v];
      if (present.isEmpty) return (_) => 0;
      final m = present.reduce((a, b) => a + b) / present.length;
      var sd0 = 0.0;
      for (final v in present) {
        sd0 += (v - m) * (v - m);
      }
      sd0 = math.sqrt(sd0 / present.length);
      final sd = sd0 == 0 ? 1.0 : sd0;
      return (v) => v == null ? 0 : (v - m) / sd;
    }

    final zhr = zfun([for (final f in feats) f.hr]);
    final zhv = zfun([for (final f in feats) f.hrVar]);
    final zmv = zfun([for (final f in feats) f.moveFrac]);
    final zrg = zfun([for (final f in feats) f.respReg]);

    final fsorted = [for (final f in feats) if (f.hrFlat11 != null) f.hrFlat11!]..sort();
    double fpct(double? v) {
      if (v == null || fsorted.isEmpty) return 0.5;
      // bisect_right
      var loi = 0, hii = fsorted.length;
      while (loi < hii) {
        final mid = (loi + hii) ~/ 2;
        if (fsorted[mid] <= v) {
          loi = mid + 1;
        } else {
          hii = mid;
        }
      }
      return loi / fsorted.length;
    }

    final base = _v2BaseLogPrior();
    final seq = <Map<String, double>>[];
    for (final f in feats) {
      final zhrv = zhr(f.hr);
      final zhvv = zhv(f.hrVar);
      final zmvv = zmv(f.moveFrac);
      final gate = _v2DeepGateSlope * math.max(0, fpct(f.hrFlat11) - _v2DeepGateThresh);
      final em = <String, double>{
        'deep': -1.4 * zhvv - 0.2 * zhrv - 0.3 * zmvv - gate + base['deep']!,
        'rem': 0.6 * zhvv - 0.6 * zmvv + 0.4 * zhrv + base['rem']!,
        'light': base['light']!,
        'awake': 1.0 * zmvv + 0.8 * zhvv + 0.4 * zhrv + base['awake']!,
      };
      final pr = _v2CyclePrior(f.clock);
      for (final s in _v2StageNames) {
        em[s] = em[s]! + pr[s]!;
      }
      if (f.jerkMax > f.jerkScale * _v2JerkFloorGateMult) {
        em['awake'] = em['awake']! + _v2MotionGateBoost;
      }
      if (f.respReg != null) {
        final z = zrg(f.respReg);
        em['deep'] = em['deep']! + _v2RespWeight * z;
        em['rem'] = em['rem']! - _v2RespWeight * z;
      }
      seq.add(em);
    }
    return _v2Viterbi(seq);
  }

  static List<String> _v2Viterbi(List<Map<String, double>> emSeq) {
    if (emSeq.isEmpty) return const [];
    final logT = {
      for (final from in _v2StageNames)
        from: {for (final to in _v2StageNames) to: math.log(_v2Transition[from]![to]!)}
    };
    var v = Map<String, double>.from(emSeq[0]);
    final back = <Map<String, String>>[];
    for (var t = 1; t < emSeq.length; t++) {
      final newV = <String, double>{};
      final bp = <String, String>{};
      for (final s in _v2StageNames) {
        var bestPrev = _v2StageNames[0];
        var bestVal = v[bestPrev]! + logT[bestPrev]![s]!;
        for (final p in _v2StageNames.skip(1)) {
          final val = v[p]! + logT[p]![s]!;
          if (val > bestVal) {
            bestVal = val;
            bestPrev = p;
          }
        }
        newV[s] = bestVal + emSeq[t][s]!;
        bp[s] = bestPrev;
      }
      v = newV;
      back.add(bp);
    }
    var last = _v2StageNames[0];
    var lastV = v[last]!;
    for (final s in _v2StageNames.skip(1)) {
      if (v[s]! > lastV) {
        lastV = v[s]!;
        last = s;
      }
    }
    final path = <String>[last];
    for (final bp in back.reversed) {
      last = bp[last]!;
      path.add(last);
    }
    return path.reversed.toList();
  }

  // ── AASM hypnogram metrics ──────────────────────────────────────────────────

  static HypnogramMetrics hypnogramMetrics(SleepSession session) {
    final segs = [...session.stages]..sort((a, b) => a.start.compareTo(b.start));
    final tib = math.max(0, session.end - session.start);
    final sleepSegs = segs
        .where((s) => s.stage == 'light' || s.stage == 'deep' || s.stage == 'rem')
        .toList();
    var tst = 0, deepS = 0, remS = 0, lightS = 0;
    for (final s in sleepSegs) {
      final d = s.end - s.start;
      tst += d;
      if (s.stage == 'deep') deepS += d;
      if (s.stage == 'rem') remS += d;
      if (s.stage == 'light') lightS += d;
    }
    int onset, sptEnd, sol;
    if (sleepSegs.isNotEmpty) {
      onset = sleepSegs.first.start;
      sptEnd = sleepSegs.last.end;
      sol = math.max(0, onset - session.start);
    } else {
      onset = session.end;
      sptEnd = session.end;
      sol = tib;
    }
    final remSegs = sleepSegs.where((s) => s.stage == 'rem').toList();
    final remLatency =
        remSegs.isNotEmpty ? (remSegs.first.start - onset).toDouble() : double.nan;
    var waso = 0, disturbances = 0;
    for (final s in segs.where((s) => s.stage == 'wake')) {
      final w0 = math.max(s.start, onset);
      final w1 = math.min(s.end, sptEnd);
      if (w1 > w0) {
        waso += w1 - w0;
        disturbances++;
      }
    }
    final se = tib > 0 ? tst / tib : 0.0;
    double pct(int x) => tst > 0 ? x / tst * 100 : 0;
    return HypnogramMetrics(
      tibS: tib,
      tstS: tst,
      sptS: math.max(0, sptEnd - onset),
      solS: sol,
      remLatencyS: remLatency,
      wasoS: waso,
      efficiency: math.min(1.0, se),
      disturbances: disturbances,
      deepMin: deepS / 60,
      remMin: remS / 60,
      lightMin: lightS / 60,
      deepPct: pct(deepS),
      remPct: pct(remS),
      lightPct: pct(lightS),
    );
  }

  // ── shared math (population std, percentile) ──────────────────────────────

  static const double _rrMinMs = 300, _rrMaxMs = 2000;

  static List<double> _rangeFilter(List<double> rr) =>
      [for (final v in rr) if (v >= _rrMinMs && v <= _rrMaxMs) v];

  static double? _rmssdRaw(List<double> nn) {
    if (nn.length < 2) return null;
    var sumSq = 0.0;
    for (var i = 1; i < nn.length; i++) {
      final d = nn[i] - nn[i - 1];
      sumSq += d * d;
    }
    return math.sqrt(sumSq / (nn.length - 1));
  }

  static double? _sdnnRaw(List<double> nn) {
    if (nn.length < 2) return null;
    final mean = nn.reduce((a, b) => a + b) / nn.length;
    var ss = 0.0;
    for (final v in nn) {
      ss += (v - mean) * (v - mean);
    }
    return math.sqrt(ss / (nn.length - 1));
  }

  static double? _median(List<double> values) {
    if (values.isEmpty) return null;
    final s = [...values]..sort();
    final n = s.length;
    if (n.isOdd) return s[n ~/ 2];
    return (s[n ~/ 2 - 1] + s[n ~/ 2]) / 2.0;
  }

  static double _populationStd(List<double> xs) {
    if (xs.isEmpty) return 0;
    final m = xs.reduce((a, b) => a + b) / xs.length;
    var ss = 0.0;
    for (final v in xs) {
      ss += (v - m) * (v - m);
    }
    return math.sqrt(ss / xs.length);
  }

  /// numpy-style linear-interp percentile of an ALREADY-SORTED list.
  static double _percentileSorted(List<double> sortedValues, double pct) {
    final n = sortedValues.length;
    if (n == 0) return 0;
    if (n == 1) return sortedValues[0];
    final position = (pct / 100.0) * (n - 1);
    final lower = position.toInt();
    final upper = math.min(lower + 1, n - 1);
    final frac = position - lower;
    return sortedValues[lower] + frac * (sortedValues[upper] - sortedValues[lower]);
  }

  static double _clampD(double x, double lo, double hi) =>
      math.max(lo, math.min(hi, x));
}

// ── private structs ────────────────────────────────────────────────────────

class _Period {
  final String stage;
  final int start;
  final int end;
  const _Period(this.stage, this.start, this.end);
}

class _EpochGrid {
  final List<double> edges;
  final int nEpochs;
  final List<double> counts;
  final List<double> hr;
  final List<double> moveFrac;
  final List<List<double>> rrBuckets;
  final List<List<double>> respBuckets;
  final List<bool> ckFlags;
  const _EpochGrid(this.edges, this.nEpochs, this.counts, this.hr, this.moveFrac,
      this.rrBuckets, this.respBuckets,
      [this.ckFlags = const []]);
}

class _EpochFeatures {
  final int index;
  final double midTs;
  final double moveFrac;
  final bool ckSleep;
  final double hr;
  final double hrVar;
  final double rmssd;
  final double sdnn;
  final double respRate;
  final double rrv;
  final double clock;
  const _EpochFeatures({
    required this.index,
    required this.midTs,
    required this.moveFrac,
    required this.ckSleep,
    required this.hr,
    required this.hrVar,
    required this.rmssd,
    required this.sdnn,
    required this.respRate,
    required this.rrv,
    required this.clock,
  });
}

class _V2Raw {
  final int start;
  final double? hr;
  final double? hrVar;
  final double? hrFlat11;
  final List<double> jerks;
  final int gapSec;
  final double jerkMax;
  final double? respReg;
  final double clock;
  const _V2Raw({
    required this.start,
    required this.hr,
    required this.hrVar,
    required this.hrFlat11,
    required this.jerks,
    required this.gapSec,
    required this.jerkMax,
    required this.respReg,
    required this.clock,
  });
}

class _V2Epoch {
  final int start;
  final double? hr;
  final double? hrVar;
  final double? hrFlat11;
  final double moveFrac;
  final double jerkMax;
  final double? respReg;
  final double clock;
  final double jerkScale;
  const _V2Epoch({
    required this.start,
    required this.hr,
    required this.hrVar,
    required this.hrFlat11,
    required this.moveFrac,
    required this.jerkMax,
    required this.respReg,
    required this.clock,
    required this.jerkScale,
  });
}
