// SLEEP — AdvancedSleepStager: session DETECTION (shared by every staging
// method below) + per-session STAGING, now delegating to [StagingMethod].
//
// Detection pipeline (unchanged by the 2026-07 staging swap below): the
// Cole–Kripke sleep/wake spine + the full session-detection guards (daytime
// #90, morning-stillness #531, 16h cap #547, off-wrist #500, sparse gravity
// #308).
//
// Per-session STAGING (the [StagingMethod] this file offers):
//   - [StagingMethod.cardio] (DEFAULT since 2026-07) — delegates to
//     `cardioStager` (cardio_stager.dart): a transparent, night-baseline-
//     relative HR+motion+RMSSD classifier with no dependency on a
//     respiration channel. Chosen after a head-to-head comparison against
//     v1/v2 on a clean fixture AND a realistic multi-phase/noisy synthetic
//     fixture: cardio matched the intended deep/REM proportions far more
//     closely (v1/v2 both badly under-called deep sleep — 0.8-2.3% of TST
//     vs cardio's 12.8%, vs a ~17% intended ground truth), and on a fixture
//     with NO genuine REM signature, cardio correctly reported 0% REM where
//     v1/v2 both hallucinated some. See git history / PR description for
//     the full numeric comparison.
//   - [StagingMethod.v1] — the original Stage-1 per-epoch features (30 s
//     epochs, 5-min window, DoG HR-variability σ=120/600, pooled-RR RMSSD/
//     SDNN, RR-derived-EDR breathing-variability) + Stage-2 percentile-band
//     classifier + Stage-3 median smoothing/physiology. NOT recommended for
//     production (see cardio comparison above) — kept for regression
//     coverage only. (A real 2026-07 bug in this path was fixed here too:
//     its REM detection depended on a raw respiration-ADC channel WHOOP 4
//     never provides, so it was silently always-dead in production; see
//     `_rrvFromRrSeries`. That fix is what makes this a fair v1 in the
//     comparison above, not evidence v1 should still be used.)
//   - [StagingMethod.v2] — the z-scored emission model + deep HR-flatness
//     gate + cycle prior + sticky 4×4 Viterbi HMM. Also NOT recommended
//     (see comparison above) — kept for regression coverage only.
//
// HONESTY: a wrist 4-class autonomic ESTIMATE, never PSG/EEG. tier ESTIMATE.
// Pure Dart, dart:math only.

import 'dart:math' as math;
import '../types.dart';
import '../util.dart';
import '../clinical/hrv_time.dart';
import 'cardio_stager.dart' show cardioStager;
import 'accounting.dart' show SleepStage;

/// Which per-session staging engine [AdvancedSleepStager] runs. See the file
/// header for the 2026-07 comparison behind this choice. Do not switch the
/// default back to [v1]/[v2] without redoing that comparison — the whole
/// reason cardio won is empirical, not architectural preference.
enum StagingMethod {
  /// DEFAULT. `cardioStager` — see cardio_stager.dart.
  cardio,

  /// Percentile-band classifier. Regression coverage only, not recommended.
  v1,

  /// z-scored HMM. Regression coverage only, not recommended.
  v2,
}

// ── Input sample types (HrTs / GravTs / RrTs / RespTs)

/// HR sample: [ts] unix SECONDS, [bpm].
class HrTs {
  final int ts;
  final double bpm;
  const HrTs(this.ts, this.bpm);
}

/// Gravity vector sample (g): [ts] unix seconds.
///
/// [valid] mirrors [AccelSample.valid]: false means the vector was never
/// decoded and is handed over as exact (0,0,0). That is NOT a measurement of
/// anything — a run of them is a perfectly constant vector, i.e. a wrist held
/// perfectly still, which is how 8 h of undecoded accel published a 100 %-
/// efficiency night. Every consumer below asks about [valid] explicitly rather
/// than comparing (0,0,0) against a threshold (same rule van_hees.dart states
/// for its z-angle).
class GravTs {
  final int ts;
  final double x;
  final double y;
  final double z;
  final bool valid;
  const GravTs(this.ts, this.x, this.y, this.z, {this.valid = true});
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

/// Advanced sleep stager — constants + the full V1/V2 algorithm.
class AdvancedSleepStager {
  // ── Stage-0 constants ───────────────────────────────────────────────────────
  /// Stillness threshold on the gravity vector, in **g per second**.
  ///
  /// It is applied to a CONSECUTIVE-SAMPLE delta, so as a bare `g` figure it
  /// silently meant "0.01 g between whatever two samples this device happened
  /// to send". A faster sensor moves less between samples and therefore read as
  /// motionless everywhere — a 50 Hz IMU staged an awake day as 16 h of sleep.
  /// The number is unchanged at 1 Hz, where g and g/s are the same value; every
  /// comparison now scales it by the measured cadence.
  static const double gravityStillThresholdGPerS = 0.01;
  static const int stillWindowMin = 15;
  static const double stillFraction = 0.70;
  static const int maxGapMin = 20;
  static const int mergeMin = 15;
  static const int minSleepMin = 60;
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
  /// Movement threshold on the gravity vector, in **g per second** — same
  /// consecutive-sample-delta trap as [gravityStillThresholdGPerS], same fix.
  static const double moveDeltaThresholdGPerS = 0.01;

  /// Coarsest cadence the gravity-delta thresholds above will score (s/sample).
  ///
  /// They are RATES, so the per-sample cut grows with the sampling interval —
  /// while |Δg| between two unit gravity vectors saturates at 2 g however long
  /// you wait. At 30 s the cut is 0.3 g, already a ~17° orientation change; by
  /// ~200 s it exceeds anything the sensor can produce and EVERY sample reads
  /// still, which would publish a coarse band's whole day as one unbroken sleep
  /// session. The rate model only holds while the interval is short against a
  /// postural change, and 30 s is also this file's own staging epoch ([epochS])
  /// — a delta spanning more than one epoch cannot inform a 30 s epoch grid.
  ///
  /// ponytail: one ceiling for both thresholds. Splitting them, or replacing
  /// the linear rate with a saturating angle model, needs data at those
  /// cadences that we do not have.
  static const double maxStillCadenceSec = epochS;
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

  // ── Cole–Kripke sleep/wake spine — KNOWN CATALOG DEVIATION (deliberate) ─────
  // docs/ALGORITHM_CATALOG_1HZ.md lists "Cole-Kripke / Sadeh / Oakley raw
  // coefficients on 1 Hz" under DO NOT SHIP, because the published weights were
  // calibrated against Actigraph zero-crossing / PIM counts and that count
  // calibration does not transfer to a 1 Hz gravity-delta surrogate (ZCM is
  // aliased away below Nyquist). We use the classic weights ANYWAY here, and it
  // is tolerated for three specific reasons:
  //   1. SPINE ONLY. `_coleKripke` output is used exclusively to locate sleep
  //      ONSET / FINAL-WAKE (`_onsetAndFinalWake`) and to pick the "sleep" epoch
  //      subset for the percentile bands — it never assigns a final stage label.
  //   2. CORRECTED DOWNSTREAM. The actual hypnogram comes from Stage 1-3
  //      (per-epoch HR/HRV/RR/resp features -> percentile classifier -> median
  //      smoothing -> `_reimposePhysiology`), which overrides the raw CK call,
  //      and physiology is reimposed after.
  //   3. RELATIVE, NOT ABSOLUTE. `_rescaleCounts` normalises by the epoch's
  //      sample count (via the measured cadence) and divides by
  //      `ckCountDivisor` and clips, so the spine reacts to WITHIN-NIGHT
  //      relative motion, not to an absolute count threshold the surrogate
  //      cannot honor — and not to how fast the device happens to sample.
  // The van Hees angle window remains the primary in-bed detector (the catalog's
  // sanctioned method); CK is a secondary within-window continuity spine. Do NOT
  // read CK output as a validated sleep/wake score. The catalog DO-NOT-SHIP line
  // cross-references this decision.
  static const List<double> ckWeights = [106, 54, 58, 76, 230, 74, 67];
  static const double ckScale = 0.001;
  static const int ckBack = 4;
  static const int ckFwd = 2;

  // ── Public entry point ──────────────────────────────────────────────────────

  /// Detect + stage all sleep sessions over the supplied 1 Hz streams.
  ///
  /// [tzOffsetSec] local-time offset (seconds) for the daytime/morning guards.
  /// [method] selects the per-session staging engine — see [StagingMethod]
  /// and the file header for why [StagingMethod.cardio] is the default.
  /// [wristOff]/[bandSleepState] are optional auxiliary signals for the
  /// off-wrist / morning-stillness guards.
  static List<SleepSession> detectSleep(
    List<GravTs> gravity,
    List<HrTs> hr, {
    List<RrTs> rr = const [],
    List<RespTs> resp = const [],
    int tzOffsetSec = 0,
    int Function(int tsSec)? tzOffsetResolver,
    StagingMethod method = StagingMethod.cardio,
    List<List<int>> wristOff = const [], // each [start,end]
    List<List<int>> bandSleepState = const [], // each [ts,state]
  }) {
    // Resolve the local-time offset PER timestamp when a resolver is supplied
    // (DST-correct — an offset change inside the record window is honored);
    // otherwise fall back to the fixed [tzOffsetSec] (unchanged legacy behavior).
    int tzAt(int ts) => tzOffsetResolver?.call(ts) ?? tzOffsetSec;
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
    // The floor exemption is one-shot per chain: only the FIRST *short* tail
    // after the overnight block may bypass the 60-min floor. Without this a run
    // of short morning/daytime fragments would each re-qualify (continuesChain
    // stays true and chainFromOvernight never clears), chain-extending the window
    // well past the true wake. Note a >60-min continuation is accepted on its own
    // merit and does NOT consume the one-shot (it never needed the exemption), so
    // a genuine multi-fragment pre-dawn tail still reaches the true wake. Set only
    // when a short tail actually uses the exemption; cleared when a chain begins.
    var nightTailAccepted = false;
    final sessions = <SleepSession>[];

    for (final p in runs) {
      if (p.stage != 'sleep') continue;
      // Chain state must be known BEFORE the min-session floor: a night-tail
      // re-onset (still, HR-in-band, within nightContinuationGapMin of the main
      // overnight block) is genuine fragmented sleep even when shorter than the
      // 60-min standalone floor. Computing it here (was below the floor) lets the
      // floor exempt it — otherwise a pre-dawn arousal that splits off a <60-min
      // tail silently truncates the window at the arousal.
      final continuesChain = chainPrevEnd != null
          ? (p.start - chainPrevEnd <= continuationGapS)
          : false;
      final isNightTail =
          continuesChain && chainFromOvernight && !nightTailAccepted;
      // Min-session floor: standalone runs still need > 60 min (so daytime naps
      // and stray still-blocks stay excluded); ONLY the first SHORT night-tail
      // per chain is exempt (nightTailAccepted bounds it). The other gates below
      // (max-span, HR-confirm, off-wrist) still apply to night-tails.
      if ((p.end - p.start) <= minSleepS && !isNightTail) continue;
      if ((p.end - p.start) > maxMainSleepSpanS) continue; // #547 drop
      if (!_confirmSleepWithHR(p, hrS, baseline)) continue;
      if (_offWristFraction(p, hrS, wristOff) >= maxOffWristSleepFraction) {
        continue; // #500, before night-tail exemption
      }

      final resting = _sessionRestingHR(p.start, p.end, hrS);
      final morningWakeEnd = chainFromOvernight ? chainPrevEnd : null;

      if (_isDaytimeCenter(p, tzAt) &&
          !_passesMorningStillnessGuard(
              p, resting, baseline, morningWakeEnd, bandSleepState) &&
          !isNightTail) {
        continue;
      }

      final stages = switch (method) {
        StagingMethod.cardio => _stageSessionCardio(p.start, p.end, grav, hrS, rrS),
        StagingMethod.v2 => _stageSessionV2(p.start, p.end, grav, hrS, rrS),
        StagingMethod.v1 => _stageSession(p.start, p.end, grav, hrS, rrS, respS),
      };
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
        chainFromOvernight = _isOvernightOnset(p.start, tzAt);
        nightTailAccepted = false; // new chain re-arms the one-shot exemption
      } else if (isNightTail && (p.end - p.start) <= minSleepS) {
        // Consume the one-shot ONLY when a SHORT tail actually relied on the floor
        // exemption; a >60-min continuation passes the floor unaided and must not
        // burn the exemption (else a later genuine short tail is lost).
        nightTailAccepted = true;
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
  /// runs through the SAME per-[method] code the auto path uses (see
  /// [StagingMethod]), so the single-source invariant holds (only the WINDOW
  /// boundary is forced, never the staging math). Seconds with no data inside
  /// [startSec, endSec) simply stay unstaged (wake) — honest about gaps,
  /// never fabricated.
  static SleepSession stageWindow(
    int startSec,
    int endSec,
    List<GravTs> gravity,
    List<HrTs> hr, {
    List<RrTs> rr = const [],
    List<RespTs> resp = const [],
    StagingMethod method = StagingMethod.cardio,
  }) {
    final stages = switch (method) {
      StagingMethod.cardio => _stageSessionCardio(startSec, endSec, gravity, hr, rr),
      StagingMethod.v2 => _stageSessionV2(startSec, endSec, gravity, hr, rr),
      StagingMethod.v1 => _stageSession(startSec, endSec, gravity, hr, rr, resp),
    };
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
    StagingMethod method = StagingMethod.cardio,
  }) {
    const inputs = ['accel_1hz', 'hr_1hz', 'rr_ms'];
    final sessions = detectSleep(gravity, hr,
        rr: rr, resp: resp, tzOffsetSec: tzOffsetSec, method: method);
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
      note: '${method.name} 4-class sleep ESTIMATE '
          '(wake/light/deep/rem); wrist autonomic, never PSG',
    );
  }

  // ── Stage-0 helpers ─────────────────────────────────────────────────────────

  /// |Δ gravity| vs the previous sample (index 0 is 0 by definition). NaN when
  /// EITHER endpoint is invalid — the arm may have moved across the gap and the
  /// record cannot say. Every comparison against NaN is false, so
  /// [_classifyStill]'s `deltas[i] < threshold` degrades to "not still", never
  /// to "perfectly still" (van Hees' `deltaDeg` contract, same reasoning).
  static List<double> _gravityDeltas(List<GravTs> g) {
    final n = g.length;
    final out = List<double>.filled(n, 0);
    for (var i = 1; i < n; i++) {
      if (!g[i].valid || !g[i - 1].valid) {
        out[i] = double.nan;
        continue;
      }
      final dx = g[i - 1].x - g[i].x;
      final dy = g[i - 1].y - g[i].y;
      final dz = g[i - 1].z - g[i].z;
      out[i] = math.sqrt(dx * dx + dy * dy + dz * dz);
    }
    return out;
  }

  /// Still-window length in SAMPLES for a measured cadence [interval] (s).
  /// The cadence itself comes from [sampleCadenceSeconds], which ABSTAINS
  /// rather than falling back — this used to fall back to 60 s, which turned a
  /// device we cannot read into a confident 5-sample window.
  static int _windowSize(double interval) =>
      math.max(minWindowSamples, ((stillWindowMin * 60) / interval).toInt());

  static double _largestGapS(List<int> times) {
    if (times.length < 2) return 0;
    var m = 0;
    for (var i = 0; i < times.length - 1; i++) {
      final g = times[i + 1] - times[i];
      if (g > m) m = g;
    }
    return m.toDouble();
  }

  // ponytail: invalid samples still count toward gravity span/gaps here, so a
  // record padded with undecoded rows reads as DENSE and the HR-only sparse
  // bridging below stays off. That errs toward under-reporting sleep (the safe
  // side, and the reason it is left alone) but can split a genuinely sparse
  // night that also holds undecoded rows. Filter `valid` here too if that shows
  // up on real records.
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
    // No measurable cadence — or one past [maxStillCadenceSec], where the g/s
    // cut stops discriminating — ⇒ nothing is asserted still ⇒ no runs ⇒ no
    // sessions ⇒ `mainSleep` is absent. The honest chain already exists; this
    // just enters it instead of staging on a 60 s guess.
    final cadence =
        sampleCadenceSeconds([for (final g in grav) g.ts.toDouble()]);
    if (cadence == null || cadence > maxStillCadenceSec) {
      return List<bool>.filled(n, false);
    }
    final window = _windowSize(cadence);
    final half = window ~/ 2;
    // g/s × the seconds this delta actually spans. Identical at 1 Hz.
    final stillCut = gravityStillThresholdGPerS * cadence;
    final stillPrefix = List<int>.filled(n + 1, 0);
    for (var i = 0; i < n; i++) {
      stillPrefix[i + 1] = stillPrefix[i] + (deltas[i] < stillCut ? 1 : 0);
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

  static bool _isDaytimeCenter(_Period p, int Function(int) tzAt) {
    final center = p.start + (p.end - p.start) ~/ 2;
    final hour = _secOfDay(center + tzAt(center)) ~/ 3600;
    return hour >= daytimeBandStartHour && hour < daytimeBandEndHour;
  }

  static bool _isOvernightOnset(int start, int Function(int) tzAt) {
    final hour = _secOfDay(start + tzAt(start)) ~/ 3600;
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

    // gravity deltas over the segment. Both the per-sample move test and the
    // Cole-Kripke count need the CADENCE: a delta spans one sampling interval,
    // and `counts` is a SUM of them per epoch, so its magnitude is pure cadence
    // (30 terms per epoch at 1 Hz, 6 at 5 s) before it means anything about
    // movement. Absent a measurable cadence there is no motion evidence at all
    // — leave `counts` at 0, `gravN` at 0 (⇒ `moveFrac` 1.0, "moving", which is
    // this grid's existing conservative default) and hand Cole-Kripke nothing.
    final cadence =
        sampleCadenceSeconds([for (final g in gSeg) g.ts.toDouble()]);
    final cadenceOk = cadence != null && cadence <= maxStillCadenceSec;
    if (cadenceOk) {
      final moveCut = moveDeltaThresholdGPerS * cadence;
      final gDeltas = _gravityDeltas(gSeg);
      for (var k = 0; k < gSeg.length; k++) {
        final i = idx(gSeg[k].ts);
        if (i == null) continue;
        counts[i] += gDeltas[k];
        gravN[i] += 1;
        if (gDeltas[k] >= moveCut) moveN[i] += 1;
      }
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
    // No cadence ⇒ no motion evidence ⇒ no sleep asserted. `counts` would be
    // all-zero here, and an all-zero Cole-Kripke score is `si < 1` on every
    // epoch, i.e. SLEEP everywhere — the exact fabrication the abstain exists
    // to avoid, so it is spelled out rather than left to the arithmetic.
    final ckFlags = !cadenceOk
        ? List<bool>.filled(nEpochs, false)
        : _coleKripke(_rescaleCounts(counts));
    return _EpochGrid(edges, nEpochs, counts, hr, moveFrac, rrBuckets,
        respBuckets, ckFlags);
  }

  /// Per-epoch gravity-delta SUM → the Cole-Kripke count surrogate.
  ///
  /// NO CADENCE FACTOR, on purpose — the sum is already cadence-invariant
  /// under this file's own rate model (`gravityStillThresholdGPerS`,
  /// `moveDeltaThresholdGPerS`: a per-sample delta grows linearly with the
  /// sampling interval for the same physical movement). A 30 s epoch holds 30
  /// terms of size `d` at 1 Hz and 6 terms of size `5d` at 5 s cadence — both
  /// sums equal `30d`. Multiplying by `cadenceSec` here used to inflate the
  /// 5 s-cadence count 5x relative to 1 Hz, which shifted `_coleKripke`'s
  /// `si < 1.0` decision (and therefore `_onsetAndFinalWake`) on exactly the
  /// non-WHOOP bands this rate model exists to support. The 1 Hz path is
  /// unaffected either way (`cadenceSec == 1`), which is why the defect was
  /// invisible until now.
  static List<double> _rescaleCounts(List<double> counts) => [
        for (final c in counts) math.min(c / ckCountDivisor, ckCountClip)
      ];

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
      // BUG FIX (2026-07): `winResp` is fed from `resp:`/`RespTs`, a raw 1 Hz
      // respiration-ADC channel — but the WHOOP 4 R24 record has no such
      // channel (an early candidate field was dropped as constant/mirror
      // during protocol hardware validation), and no real production caller
      // of `detectSleep`/`stageWindow` has ever supplied one. `winResp` was
      // therefore ALWAYS empty in production, `_respRateAndRRV` always
      // returned [NaN, NaN], `f.rrv` was always NaN, and the PRIMARY REM rule
      // below (`cardiacActivated && rrvIrregular`) could never fire — every
      // real night silently fell back to the much narrower secondary REM rule
      // (`hrHigh && hrvarHigh` simultaneously), collapsing most non-deep
      // sleep into the 'light' catch-all. Prefer the real ADC path when
      // (someday) supplied; otherwise derive respiration the way ECG-derived-
      // respiration (EDR) methods do when no dedicated sensor exists: RSA
      // (respiratory sinus arrhythmia) modulates the RR series itself at the
      // breathing frequency, so beat-indexed RR magnitude carries the same
      // signal a raw resp channel would (cf. Bailón et al. 2006, "The
      // Integral Pulse Frequency Modulation Model..."; the same principle
      // `respiration/resp_rate.dart`'s `rsaRespRate` exploits spectrally —
      // this is the cheap, per-epoch-affordable time-domain analogue).
      final rr = winResp.length >= 8
          ? _respRateAndRRV(winResp)
          : _rrvFromRrSeries(filteredRR);
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

  /// (rate, rrv) derived from the RR-interval series itself — an ECG-derived-
  /// respiration (EDR) time-domain estimate for when there is no dedicated
  /// respiration channel (see the call-site comment in [_extractFeatures] for
  /// why that is always true in production today). RSA modulates successive
  /// RR magnitudes at the breathing frequency, so mean-centering the
  /// (already range-filtered) RR series and peak-counting it is the same
  /// technique [_respRateAndRRV] applies to a raw resp channel, just applied
  /// to RR magnitude instead of raw ADC — beat times are reconstructed by
  /// cumulative-summing the RR values (ms), same technique
  /// `foundations/rr_correction.dart`'s `nnTimesMs` uses.
  static List<double> _rrvFromRrSeries(List<double> rrMs) {
    if (rrMs.length < 8) return [double.nan, double.nan];
    final times = List<double>.filled(rrMs.length + 1, 0);
    for (var i = 0; i < rrMs.length; i++) {
      times[i + 1] = times[i] + rrMs[i];
    }
    final mean = rrMs.reduce((a, b) => a + b) / rrMs.length;
    final x = [for (final v in rrMs) v - mean];
    if (x.every((v) => v.abs() < 1e-9)) return [double.nan, double.nan];
    final std = _populationStd(x);
    if (std <= 0) return [double.nan, double.nan];
    // Peaks must be >=2 beats apart — a beat-to-beat RR series has ~1 sample
    // per beat, so a distance-1 peak would just be beat-to-beat noise, not a
    // breath cycle.
    final peaks = _findPeaks(x, 2, 0.0);
    if (peaks.length < 3) return [double.nan, double.nan];
    final intervalsS = <double>[];
    for (var i = 1; i < peaks.length; i++) {
      final iv = (times[peaks[i]] - times[peaks[i - 1]]) / 1000.0;
      if (iv >= 1.5 && iv <= 12.0) intervalsS.add(iv);
    }
    if (intervalsS.length < 2) return [double.nan, double.nan];
    final rate = 60 / _median(intervalsS)!;
    final rrv = _populationStd(intervalsS);
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
    // Fallback REM path for the rare epoch where rrv itself couldn't be
    // computed (too few RR beats in this specific 5-min window — e.g. a
    // brief PPG-contact dropout) even though rrv IS generally available this
    // session. Before the rrv fix above, rrv was ALWAYS non-finite in
    // production, so this branch used to be the ONLY route to 'rem' and was
    // deliberately narrowed (hrHigh AND hrvarHigh) to avoid over-calling it.
    // Now that the primary rrv-gated rule above actually fires on real
    // nights, this is a genuine rare-gap fallback, not the load-bearing
    // path — loosened to the same cardiacActivated (hrHigh OR hrvarHigh)
    // signal used for wake/the primary REM rule, instead of doubly requiring
    // both simultaneously while data is already thin for this epoch.
    if (still && cardiacActivated && !f.rrv.isFinite) return 'rem';
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

  /// Longest accelerometer dropout (s) the dense-array build will carry the
  /// last-known gravity vector across.
  ///
  /// A carry-forward is honest for a BRIEF dropout (a missed 1 Hz sample is far
  /// more likely than a real posture change, and ENMO off a stale-but-still
  /// vector reads "no movement" rather than fabricating motion). UNBOUNDED it
  /// is fabrication in the opposite direction: hours with no accelerometer at
  /// all become a perfectly still — i.e. perfectly asleep — stretch, so a
  /// forced 8 h window holding 2 h of data scored TST 8 h / efficiency 100%.
  ///
  /// 60 s = two staging epochs, and the shortest wake bout the Webster/
  /// Cole-Kripke continuity rules treat as bridgeable (Webster et al. 1982;
  /// Cole et al. 1992) — i.e. the finest resolution at which this pipeline
  /// claims to separate sleep from wake. A carry-forward bounded by it can
  /// therefore never manufacture a scorable sleep bout on its own. Seconds past
  /// the bound are UNSTAGED: they are left out of staging entirely and reported
  /// as wake.
  static const int maxAccelCarryForwardSec = 60;

  /// DEFAULT staging path — delegates to `cardioStager` (cardio_stager.dart).
  /// See the file header for why this is the default. `cardioStager` expects
  /// per-SECOND-indexed [AccelSample]/HR arrays (index i == second i from
  /// [start]), not the sparse timestamped [GravTs]/[HrTs] lists this file
  /// otherwise uses — so this builds that dense array explicitly: accel gaps
  /// carry the last-known vector forward for at most
  /// [maxAccelCarryForwardSec]; HR gaps fill with 0, which `cardioStager`
  /// already documents as its own "off-skin" contract — no fabrication either
  /// way.
  ///
  /// HONESTY: seconds with no usable accelerometer are NOT staged. The window
  /// is split at those gaps and each contiguous usable RUN is staged on its own
  /// (so a dropout cannot pollute the neighbouring run's night baselines
  /// either); the gap seconds, runs too short to stage, and a window where
  /// `cardioStager` itself abstains all come back as WAKE — the "stay unstaged"
  /// contract [stageWindow] documents. They must NEVER come back as 'light',
  /// which is what a zero-data window used to report for its entire length.
  static List<StageSegment> _stageSessionCardio(int start, int end,
      List<GravTs> grav, List<HrTs> hr, List<RrTs> rr) {
    final span = end - start;
    if (span <= 0) return const <StageSegment>[];
    final epSec = epochS.round();
    final minStageableSec = 3 * epSec;
    if (span < minStageableSec) return [StageSegment(start, end, 'wake')];

    // Invalid samples are NOT samples: they must not seed `usable`, and they
    // must not become the source of a carry-forward. A second with only an
    // undecoded vector falls through to the same unstaged→WAKE path as a
    // second with no row at all (cardioStager itself never reads
    // [AccelSample.valid], so it can only be protected here).
    final gByTs = <int, GravTs>{
      for (final g in grav)
        if (g.valid && g.ts >= start && g.ts < end) g.ts: g
    };
    final hByTs = <int, HrTs>{for (final h in hr) if (h.ts >= start && h.ts < end) h.ts: h};
    final accel = List<AccelSample>.filled(
        span, AccelSample(start * 1000.0, 0, 0, 1.0));
    final hr1hz = List<double>.filled(span, 0.0);
    // usable[i] — second i has a real accel sample or a BOUNDED carry-forward.
    final usable = List<bool>.filled(span, false);
    var lastRealIdx = -1;
    for (var i = 0; i < span; i++) {
      final ts = start + i;
      final g = gByTs[ts];
      if (g != null) {
        accel[i] = AccelSample(ts * 1000.0, g.x, g.y, g.z);
        lastRealIdx = i;
        usable[i] = true;
      } else if (lastRealIdx >= 0 && (i - lastRealIdx) <= maxAccelCarryForwardSec) {
        // Bounded carry-forward — see [maxAccelCarryForwardSec]. The TIMESTAMP
        // is this second's, not the stale sample's: cardioStager centres its RR
        // windows on `accel[mid].tsMs`, so copying the old sample wholesale
        // mis-centred every RMSSD/LF-HF window inside a gap.
        final p = accel[i - 1];
        accel[i] = AccelSample(ts * 1000.0, p.x, p.y, p.z);
        usable[i] = true;
      }
      hr1hz[i] = hByTs[ts]?.bpm ?? 0.0; // 0 = off-skin, cardioStager's own contract.
    }

    final rSeg = [for (final r in rr) if (r.ts >= start && r.ts < end) r];
    final rrMs = [for (final r in rSeg) r.rrMs];
    final rrTsMs = [for (final r in rSeg) r.ts * 1000.0];

    // Everything not staged below stays 'wake' — the honest default.
    final perSec = List<String>.filled(span, 'wake');
    var i = 0;
    while (i < span) {
      if (!usable[i]) {
        i++;
        continue;
      }
      var j = i;
      while (j < span && usable[j]) {
        j++;
      }
      if ((j - i) >= minStageableSec) {
        final result = cardioStager(
          hr1hz.sublist(i, j),
          accel.sublist(i, j),
          rrMs: rrMs,
          rrTsMs: rrTsMs,
        );
        final nEpoch = result.base.stages.length;
        for (var e = 0; e < nEpoch; e++) {
          final label = switch (result.base.stages[e]) {
            SleepStage.wake => 'wake',
            SleepStage.rem => 'rem',
            SleepStage.nrem => (e < result.deepFlag.length && result.deepFlag[e])
                ? 'deep'
                : 'light',
          };
          final lo = i + e * epSec;
          // The last epoch absorbs the run's sub-epoch remainder, exactly as
          // [_buildSegments] extends the final segment to the window end.
          final hi = e == nEpoch - 1 ? j : math.min(j, lo + epSec);
          for (var k = lo; k < hi; k++) {
            perSec[k] = label;
          }
        }
      }
      i = j;
    }

    // Coalesce the per-second labels into contiguous [StageSegment]s tiling
    // [start, end) — same segment semantics [_buildSegments] produces.
    final segments = <StageSegment>[];
    var k = 0;
    while (k < span) {
      var m = k;
      while (m < span && perSec[m] == perSec[k]) {
        m++;
      }
      segments.add(StageSegment(start + k, start + m, perSec[k]));
      k = m;
    }
    return segments;
  }

  static List<StageSegment> _stageSession(int start, int end, List<GravTs> grav,
      List<HrTs> hr, List<RrTs> rr, List<RespTs> resp) {
    final gSeg = [
      for (final g in grav)
        if (g.valid && g.ts >= start && g.ts <= end) g
    ];
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
    final gravW = [
      for (final g in grav)
        if (g.valid && g.ts >= lo && g.ts < hi) g
    ];
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
    int onset, sptEnd;
    int? sol;
    if (sleepSegs.isNotEmpty) {
      onset = sleepSegs.first.start;
      sptEnd = sleepSegs.last.end;
      sol = math.max(0, onset - session.start);
    } else {
      onset = session.end;
      sptEnd = session.end;
      sol = null; // never observed sleep — no latency to report
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
