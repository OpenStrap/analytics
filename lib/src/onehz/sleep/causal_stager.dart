// SLEEP — CAUSAL (online) 3-class stager: wake | nrem | rem | absent.
//
// WHY THIS EXISTS. [cardioStager] is a RETROSPECTIVE night scorer: every
// feature window is centred on its epoch (so it reads 90-150 s of the future),
// the motion / HR / z-score baselines are whole-night, and three post-passes
// (mode filter, Webster rescore, bout consolidation) all look BOTH ways. None
// of that exists at 06:40 when something has to decide, right now, whether the
// sleeper is in REM. Re-running the retrospective stager every tick is not a
// causal stager either: its newest epochs would be scored on truncated windows
// and a baseline that is still moving. This file is the online counterpart,
// built from the SAME features, weights and cutoffs wherever those can be
// computed from the past alone:
//
//   same        motion (ENMO vs a local 1 g reference), HR mean / SD, SDNN,
//               R(k), LF/HF; the physiologic RR gate; the REM axis weights
//               (kRemWeight*, the measured DREAMT effect sizes); the shipped
//               REM cutoff (kDefaultRemScoreCut); the wake / atonia / HR-floor
//               rules; minHrCoverage; the 0.6 confidence ceiling.
//   made causal every centred window becomes a TRAILING window ending at the
//               epoch's end (300 s SDNN; 180 s R(k) and LF/HF — their full
//               lengths; 120 s for the 1 g reference, see [_gRefWinSec]; 90 min
//               for the local HR gates);
//               whole-night baselines become expanding baselines over what has
//               been seen so far (capped at [CausalStagerConfig.historyEpochs]).
//   dropped     Webster rescore and bout consolidation: both need the FUTURE
//               side of a bout. Nothing replaces them; a causal wake is
//               therefore not bridged the way the retrospective one is, and
//               [CausalStageObservation.runSec] says how long a stage has
//               persisted so the caller can demand persistence itself. The
//               3-epoch mode filter is replaced by a trailing 2-of-3 vote.
//   not carried the personal profile blend ([SleepUserProfile]) and the deep
//               overlay. This is wake / nrem / rem, per-night-local only.
//
// WHAT IT IS NOT. A wrist autonomic ESTIMATE (tier ESTIMATE), never
// polysomnography, never an EEG-defined stage, never a diagnosis. The offline
// stager scores kappa 0.13 against PSG on the held-out DREAMT split; this is
// a causal cousin of that stager with fewer smoothing passes, and agreement
// with the offline hypnogram is a consistency check, not an accuracy figure.
// `confidence` is EVIDENCE QUALITY (HR coverage, RR coverage), capped at
// [kMaxSleepConfidence] — it is not a probability that the stage is right.
//
// THE CONTRACT
//
//   CausalStager.observe(window, priorState) -> CausalStageObservation
//
//   * CAUSAL. Only samples stamped strictly before window.nowMs are read (a
//     sample stamped t describes [t, t+1 s)); the rest are counted and ignored. An epoch is staged only after it has fully closed,
//     and its features look backwards only.
//   * REPLAYABLE. Pure and deterministic: no clock, no randomness, no I/O, no
//     hash-order dependence. The caller supplies `nowMs`. The same sequence of
//     windows gives byte-identical observations and states.
//   * REPLACEMENT-TOLERANT. A window is authoritative for the time span it
//     covers, per channel: stored samples inside that span are replaced by the
//     window's. Re-sending a window, overlapping windows, and corrected
//     re-sends converge on the state a clean feed would have produced. Samples
//     older than 600 s behind the newest stored sample are IGNORED (counted in
//     trace['ignoredStale']): their features are frozen.
//   * SERIALISABLE. [CausalStagerState] is plain data (toJson/fromJson) and
//     bounded: ~15 min of raw samples plus [CausalStagerConfig.historyEpochs]
//     feature rows. It crosses an isolate boundary as-is.
//   * HONEST. It abstains, with a [CausalAbstention] reason, instead of
//     guessing: no / stale / regressing clock, off-skin, missing HR or accel,
//     thin coverage, or warm-up evidence too thin. An absent stage always has
//     confidence 0 and runSec 0, and a previous stage is never carried across
//     an abstention.
//
// INPUT CONTRACT. 1 Hz HR and accel (one sample per second bucket; whole-second
// windows) plus RR beats whose timestamps are the record second (`rr_ts_ms`).
// Start from `prior == null` at in-bed time: the API stages whatever it is
// given and has no sleep-onset detector, so feeding it the waking afternoon
// would build its baselines from waking physiology.
//
// LATENCY, stated plainly: a stage describes the newest CLOSED 30 s epoch, and
// its RR features are trailing 3-5 min windows whose centres sit 1.5-2.5 min
// behind it — the price of not looking ahead. See docs/CAUSAL_STAGER.md for the
// measured agreement and the false- / late-trigger behaviour.

import 'dart:math' as math;
import '../types.dart';
import '../util.dart';
import 'cardio_stager.dart'
    show
        cleanRrBeatsBetween,
        kDefaultRemScoreCut,
        kRemWeightHrSd,
        kRemWeightLfhf,
        kRemWeightRk,
        kRemWeightSdnn,
        minHrCoverage,
        remFeaturesFromBeats,
        weightedAxisScore;
import 'segment.dart' show kMaxSleepConfidence;

// Published staging basis inherited from cardioStager(): Long 2016; Fonseca
// 2015/2018. This unpublished past-only adaptation is an internal rule,
// ESTIMATE with low
// confidence; trailing windows and baselines intentionally differ from
// retrospective staging.
/// Epoch length (s). Fixed: every cutoff inherited from [cardioStager] is
/// specified at 30 s.
const int kCausalEpochSec = 30;

// Trailing window lengths (s). The RR windows keep the FULL length of the
// centred windows in cardio_stager.dart (RMSSD/SDNN ±150 s, R(k)/LF-HF ±90 s).
//
// The 1 g reference is the one place the full length does NOT carry over. The
// retrospective reference is a 330 s window CENTRED on the epoch, so after a
// static posture change it adapts as soon as the epoch reaches the change (it
// reads the future half). A trailing window of the same length has to wait
// until MORE THAN HALF of it is the new posture, i.e. 150 s of every posture
// change reads as "motion" — and a few consecutive big-move epochs are what the
// wake gate calls awake. That is the same posture artifact cardio_stager.dart's
// header describes, re-created by causality. A shorter trailing reference
// adapts in half its length while still being longer than the movement bouts
// it must not absorb. 120 s was picked from {300, 180, 120, 90} s by replaying
// the one in-tree night (test/onehz/fixtures; `tool/causal_stager_validate.dart`):
// wake over-call vs the offline stager fell 104 -> 83 -> 62 -> 52 min and kappa
// rose .305 -> .335 -> .369 -> .372. It is the one number in this file chosen
// on data, on a single night: treat the validation as optimistic by that much.
const int _gRefWinSec = 120;
const int _sdnnWinSec = 300;
const int _remWinSec = 180;

/// Local HR gate window, epochs (90 min — one ultradian cycle; the retrospective
/// stager uses ±180 epochs, the causal one only the past half).
const int _hrWinEpochs = 180;

/// Raw samples retained in the state (s). Must cover the longest feature
/// lookback ([_sdnnWinSec]) plus [_replaceHorizonSec].
const int _rawRetainSec = 900;

/// Samples this far behind the newest stored sample or older are ignored: a
/// row older than this has lost part of its lookback and is frozen.
const int _replaceHorizonSec = _rawRetainSec - _sdnnWinSec;

/// Persisted-state schema version. Bump on any change to the state JSON.
const int kCausalStateVersion = 1;

/// What the causal stager can say. [absent] always comes with an
/// [CausalAbstention] and zero confidence.
enum CausalStage { wake, nrem, rem, absent }

/// Why the stager declined to name a stage. Checked roughly in declaration
/// order; [lowCoverage] is also raised for thin recent history once the
/// warm-up count is met.
enum CausalAbstention {
  /// `nowMs` is earlier than a time already observed, or not finite. State is
  /// returned untouched: acting on it would mean reading the future.
  clockRegressed,

  /// No sample of any kind has ever been received.
  noEvidence,

  /// Nothing at all arrived within [CausalStagerConfig.maxEvidenceAgeSec] of
  /// `nowMs` (disconnect, strap out of range, delivery stalled).
  staleEvidence,

  /// The newest closed epoch is mostly `hr == 0` (off-skin). Never read as
  /// bradycardia.
  offWrist,

  /// No valid HR in the newest closed epoch (absent, NaN or negative).
  missingHr,

  /// No valid accel in the newest closed epoch. HR is checked first, so an
  /// epoch with neither reports [missingHr].
  missingAccel,

  /// HR or accel covers under [minHrCoverage] of the epoch's seconds, or the
  /// recent history is mostly unusable.
  lowCoverage,

  /// Fewer than [CausalStagerConfig.warmupEpochs] usable epochs seen so far;
  /// the baselines would be built on nothing. `note` reads
  /// `warmup:have=H,need=N`.
  warmup,
}

/// Tunables. Carried inside [CausalStagerState] so a persisted state keeps the
/// settings it was built with.
class CausalStagerConfig {
  /// Usable epochs required before any stage is named. 40 = 20 min.
  /// An engineering floor (enough epochs for the robust-z baselines and the
  /// local HR gates to exist), not a physiological claim.
  final int warmupEpochs;

  /// Nothing received for longer than this ⇒ [CausalAbstention.staleEvidence].
  final double maxEvidenceAgeSec;

  /// Feature rows kept, which is also the span of the expanding baselines
  /// (360 epochs = 3 h).
  final int historyEpochs;

  /// REM decision cutoff on the weighted robust-z REM score. Defaults to the
  /// shipped [kDefaultRemScoreCut]; exposed for calibration tooling only.
  final double remScoreCut;

  const CausalStagerConfig({
    this.warmupEpochs = 40,
    this.maxEvidenceAgeSec = 120,
    this.historyEpochs = 360,
    this.remScoreCut = kDefaultRemScoreCut,
  })  : assert(warmupEpochs > 0),
        assert(historyEpochs >= warmupEpochs),
        assert(maxEvidenceAgeSec > 0);

  static const CausalStagerConfig defaults = CausalStagerConfig();

  Map<String, dynamic> toJson() => {
        'warmup_epochs': warmupEpochs,
        'max_evidence_age_sec': maxEvidenceAgeSec,
        'history_epochs': historyEpochs,
        'rem_score_cut': remScoreCut,
      };

  static CausalStagerConfig? fromJson(Object? j) {
    if (j is! Map) return null;
    final w = j['warmup_epochs'], a = j['max_evidence_age_sec'];
    final h = j['history_epochs'], c = j['rem_score_cut'];
    if (w is! num || a is! num || h is! num || c is! num) return null;
    if (w <= 0 || h < w || a <= 0 || !c.isFinite) return null;
    return CausalStagerConfig(
      warmupEpochs: w.toInt(),
      maxEvidenceAgeSec: a.toDouble(),
      historyEpochs: h.toInt(),
      remScoreCut: c.toDouble(),
    );
  }
}

/// One call's worth of new (or re-sent) samples plus the decision time.
///
/// Whole-second windows. Samples may overlap earlier windows (a re-send): see
/// the replacement rule in the file header. Timestamps are absolute epoch ms,
/// the same clock as [nowMs].
class CausalSampleWindow {
  /// Decision time (absolute epoch ms), supplied by the caller — this package
  /// has no clock. Samples stamped at or after it are ignored (a sample
  /// stamped t describes the second [t, t+1 s), which is not over yet).
  final double nowMs;
  final List<HrSample> hr; // hr == 0 is off-skin
  final List<AccelSample> accel;
  final RrSeries rr; // tsMs = record second in ms; rrMs = interval

  CausalSampleWindow({
    required this.nowMs,
    this.hr = const [],
    this.accel = const [],
    RrSeries? rr,
  }) : rr = rr ?? RrSeries(const <double>[], const <double>[]);
}

/// One closed 30 s epoch's features. Plain data.
///
/// `null` means "not measurable", never zero. [label] is the raw (unsmoothed)
/// stage decided when the epoch closed, from baselines built on epochs up to
/// and including this one — null when the epoch was unusable or the stager was
/// still warming up.
class CausalEpochRow {
  /// Absolute index: floor(startMs / 30000).
  final int epoch;
  final int hrN; // seconds with valid on-skin HR (> 0)
  final int hrOffN; // seconds with hr == 0
  final int accelN; // seconds with valid accel
  final double? motion; // mean ENMO vs trailing 1 g reference (g)
  final double? hr; // mean valid HR (bpm)
  final double? hrSd; // SD of valid HR (bpm); null under 2 samples
  final double? sdnn; // ms, trailing 300 s; null under 5 clean beats
  final double? rk; // mean |ΔIHR| (bpm), trailing 180 s; null under 16 beats
  final double? lfhf; // trailing 180 s; null under 16 beats
  final CausalStage? label;

  const CausalEpochRow({
    required this.epoch,
    required this.hrN,
    required this.hrOffN,
    required this.accelN,
    this.motion,
    this.hr,
    this.hrSd,
    this.sdnn,
    this.rk,
    this.lfhf,
    this.label,
  });

  /// Seconds of valid HR / accel needed for the epoch to count.
  static final int minSeconds = (minHrCoverage * kCausalEpochSec).ceil();

  bool get offWrist => hrOffN > 0 && hrOffN >= hrN;
  bool get usable =>
      !offWrist && hrN >= minSeconds && accelN >= minSeconds && hr != null;

  CausalEpochRow withLabel(CausalStage? l) => CausalEpochRow(
        epoch: epoch,
        hrN: hrN,
        hrOffN: hrOffN,
        accelN: accelN,
        motion: motion,
        hr: hr,
        hrSd: hrSd,
        sdnn: sdnn,
        rk: rk,
        lfhf: lfhf,
        label: l,
      );

  List<Object?> toJson() =>
      [epoch, hrN, hrOffN, accelN, motion, hr, hrSd, sdnn, rk, lfhf, label?.index];

  static CausalEpochRow? fromJson(Object? j) {
    if (j is! List || j.length != 11) return null;
    for (var i = 0; i < 4; i++) {
      if (j[i] is! num) return null;
    }
    double? d(Object? v) => v == null ? null : (v is num ? v.toDouble() : double.nan);
    final vals = [for (var i = 4; i < 10; i++) d(j[i])];
    if (vals.any((v) => v != null && !v.isFinite)) return null;
    final li = j[10];
    if (li != null && (li is! int || li < 0 || li > 2)) return null;
    return CausalEpochRow(
      epoch: (j[0] as num).toInt(),
      hrN: (j[1] as num).toInt(),
      hrOffN: (j[2] as num).toInt(),
      accelN: (j[3] as num).toInt(),
      motion: vals[0],
      hr: vals[1],
      hrSd: vals[2],
      sdnn: vals[3],
      rk: vals[4],
      lfhf: vals[5],
      label: li == null ? null : CausalStage.values[li as int],
    );
  }
}

/// The carried state. Plain data: JSON-serialisable and isolate-sendable.
///
/// Treat every list as immutable. Raw tails are columns:
///   hr    [second, bpm]            accel [second, x, y, z]   (valid only)
///   rr    [ts_ms, rr_ms]
class CausalStagerState {
  final CausalStagerConfig config;

  /// Latest `nowMs` observed; a smaller `nowMs` is a clock regression.
  final double? lastNowMs;

  /// Latest second carrying valid on-skin HR AND valid accel, if ever.
  final int? lastUsableSec;
  final List<List<double>> hrTail;
  final List<List<double>> accelTail;
  final List<List<double>> rrTail;
  final List<CausalEpochRow> rows; // ascending by epoch, closed epochs only

  const CausalStagerState({
    required this.config,
    this.lastNowMs,
    this.lastUsableSec,
    this.hrTail = const [],
    this.accelTail = const [],
    this.rrTail = const [],
    this.rows = const [],
  });

  /// A fresh state — what `observe(window, null)` starts from.
  factory CausalStagerState.initial(
          [CausalStagerConfig config = CausalStagerConfig.defaults]) =>
      CausalStagerState(config: config);

  /// Newest stored second across all channels, if any.
  int? get newestSec {
    int? m;
    void up(num v) {
      final s = v.floor();
      if (m == null || s > m!) m = s;
    }

    if (hrTail.isNotEmpty) up(hrTail.last[0]);
    if (accelTail.isNotEmpty) up(accelTail.last[0]);
    if (rrTail.isNotEmpty) up(rrTail.last[0] / 1000.0);
    return m;
  }

  Map<String, dynamic> toJson() => {
        'v': kCausalStateVersion,
        'cfg': config.toJson(),
        'last_now_ms': lastNowMs,
        'last_usable_sec': lastUsableSec,
        'hr': hrTail,
        'accel': accelTail,
        'rr': rrTail,
        'rows': [for (final r in rows) r.toJson()],
      };

  /// Null for anything that is not a current-version state this class wrote —
  /// the caller starts fresh (which only costs a warm-up), it never gets a
  /// guessed-at state.
  static CausalStagerState? fromJson(Object? j) {
    if (j is! Map || j['v'] != kCausalStateVersion) return null;
    final cfg = CausalStagerConfig.fromJson(j['cfg']);
    if (cfg == null) return null;
    final now = j['last_now_ms'], usable = j['last_usable_sec'];
    if (now != null && (now is! num || !now.isFinite)) return null;
    if (usable != null && usable is! num) return null;
    List<List<double>>? cols(Object? v, int width) {
      if (v is! List) return null;
      final out = <List<double>>[];
      for (final e in v) {
        if (e is! List || e.length != width) return null;
        final r = <double>[];
        for (final x in e) {
          if (x is! num || !x.isFinite) return null;
          r.add(x.toDouble());
        }
        out.add(r);
      }
      return out;
    }

    final hr = cols(j['hr'], 2), ac = cols(j['accel'], 4), rr = cols(j['rr'], 2);
    final rowsJ = j['rows'];
    if (hr == null || ac == null || rr == null || rowsJ is! List) return null;
    final rows = <CausalEpochRow>[];
    for (final r in rowsJ) {
      final row = CausalEpochRow.fromJson(r);
      if (row == null) return null;
      rows.add(row);
    }
    return CausalStagerState(
      config: cfg,
      lastNowMs: (now as num?)?.toDouble(),
      lastUsableSec: (usable as num?)?.toInt(),
      hrTail: hr,
      accelTail: ac,
      rrTail: rr,
      rows: rows,
    );
  }
}

/// One answer. [nextState] must be passed to the next call.
class CausalStageObservation {
  /// The stage of the newest CLOSED 30 s epoch, or [CausalStage.absent].
  final CausalStage stage;

  /// Evidence quality in [0.15, kMaxSleepConfidence] when staged, exactly 0
  /// when absent. Not a probability of being right.
  final double confidence;

  /// ms between `nowMs` and the end of the newest second that carried valid
  /// on-skin HR and valid accel; null when there never was one. Present even
  /// when absent — it is the staleness the caller should log.
  final double? evidenceAgeMs;

  final CausalStagerState nextState;

  /// Non-null exactly when [stage] is [CausalStage.absent].
  final CausalAbstention? abstentionReason;

  /// Start (absolute ms) of the epoch [stage] describes; null if none.
  final double? epochStartMs;

  /// How long [stage] has held, in seconds (whole epochs, trailing 2-of-3
  /// vote). 0 when absent. A caller wanting a "stable REM candidate" should
  /// threshold this; `remEpisodeMinMin` (5 min) is the retrospective stager's
  /// shortest credible REM bout.
  final double runSec;

  /// `warmup:have=H,need=N` while warming up; null otherwise.
  final String? note;

  /// Plain-data decision trace (features, thresholds, counters) for logging.
  final Map<String, Object?> trace;

  const CausalStageObservation({
    required this.stage,
    required this.confidence,
    required this.evidenceAgeMs,
    required this.nextState,
    required this.abstentionReason,
    required this.epochStartMs,
    required this.runSec,
    required this.note,
    required this.trace,
  });

  /// The observation without the state (persist [nextState] separately).
  Map<String, dynamic> toJson() => {
        'stage': stage.name,
        'confidence': round6(confidence) ?? 0.0,
        'evidence_age_ms': evidenceAgeMs,
        'abstention_reason': abstentionReason?.name,
        'epoch_start_ms': epochStartMs,
        'run_sec': runSec,
        if (note != null) 'note': note,
        'trace': trace,
      };
}

/// The causal stager. See the file header for the contract.
abstract final class CausalStager {
  /// Fold [window] into [priorState] (null = start of night) and name the stage
  /// of the newest closed epoch, or abstain.
  static CausalStageObservation observe(
      CausalSampleWindow window, CausalStagerState? priorState) {
    final st = priorState ?? CausalStagerState.initial();
    final cfg = st.config;
    final now = window.nowMs;

    // 0. Clock. Going backwards would mean answering about a time the state has
    //    already moved past; an unusable clock cannot age anything.
    if (!now.isFinite || (st.lastNowMs != null && now < st.lastNowMs!)) {
      return _absent(st, CausalAbstention.clockRegressed);
    }

    // 1. Merge (causal filter, span replacement) -----------------------------
    final m = _merge(st, window);

    // 2. Feature rows ---------------------------------------------------------
    final newest = m.newestSec;
    final kLatest = newest == null ? -1 : ((newest + 1) ~/ kCausalEpochSec) - 1;
    final rows = _rebuildRows(st, cfg, m, kLatest);

    // 3. Bookkeeping that goes into the next state ----------------------------
    final usableSec = m.latestUsableSec ?? st.lastUsableSec;
    final keepFromSec = (newest ?? 0) - _rawRetainSec;
    final next = CausalStagerState(
      config: cfg,
      lastNowMs: now,
      lastUsableSec: usableSec,
      hrTail: [
        for (final e in m.hr) if (e[0] >= keepFromSec) e
      ],
      accelTail: [
        for (final e in m.accel) if (e[0] >= keepFromSec) e
      ],
      rrTail: [
        for (final e in m.rr) if (e[0] >= keepFromSec * 1000.0) e
      ],
      rows: rows,
    );

    final ageMs = usableSec == null
        ? null
        : math.max(0.0, now - (usableSec + 1) * 1000.0);
    final trace = <String, Object?>{
      'ignoredFuture': m.ignoredFuture,
      'ignoredStale': m.ignoredStale,
      'rows': rows.length,
    };

    CausalStageObservation no(CausalAbstention why,
            {String? note, CausalEpochRow? row}) =>
        _mk(next, why, ageMs, trace, note: note, row: row);

    // 4. Reasons to abstain, most fundamental first ---------------------------
    if (newest == null) return no(CausalAbstention.noEvidence);
    if (now - (newest + 1) * 1000.0 > cfg.maxEvidenceAgeSec * 1000.0) {
      return no(CausalAbstention.staleEvidence);
    }
    final byEpoch = {for (final r in rows) r.epoch: r};
    final usableCount = rows.where((r) => r.usable).length;
    if (kLatest < 0) {
      return no(CausalAbstention.warmup,
          note: _warmNote(0, cfg.warmupEpochs));
    }
    final row = byEpoch[kLatest];
    trace['epoch'] = kLatest;
    if (row == null) return no(CausalAbstention.missingHr);
    trace['hrN'] = row.hrN;
    trace['hrOffN'] = row.hrOffN;
    trace['accelN'] = row.accelN;
    if (row.offWrist) return no(CausalAbstention.offWrist, row: row);
    if (row.hrN == 0) return no(CausalAbstention.missingHr, row: row);
    if (row.accelN == 0) return no(CausalAbstention.missingAccel, row: row);
    if (!row.usable) return no(CausalAbstention.lowCoverage, row: row);
    trace['usableRows'] = usableCount;
    if (usableCount < cfg.warmupEpochs) {
      return no(CausalAbstention.warmup,
          note: _warmNote(usableCount, cfg.warmupEpochs), row: row);
    }
    final firstEpoch = rows.first.epoch;
    final from = math.max(firstEpoch, kLatest - cfg.warmupEpochs + 1);
    final span = kLatest - from + 1;
    var recentUsable = 0, recentRr = 0;
    for (var e = from; e <= kLatest; e++) {
      final r = byEpoch[e];
      if (r != null && r.usable) {
        recentUsable++;
        if (r.sdnn != null) recentRr++;
      }
    }
    if (recentUsable / span < minHrCoverage) {
      return no(CausalAbstention.lowCoverage, row: row);
    }

    // 5. Stage: trailing 2-of-3 vote over the labels decided at close time ----
    CausalStage? voted(int e) {
      final here = byEpoch[e]?.label;
      if (here == null) return null;
      final counts = <CausalStage, int>{here: 1};
      for (final d in const [1, 2]) {
        final l = byEpoch[e - d]?.label;
        if (l != null) counts[l] = (counts[l] ?? 0) + 1;
      }
      var best = here;
      for (final en in counts.entries) {
        if (en.value > counts[best]!) best = en.key;
      }
      return best; // a tie keeps the newest label
    }

    final stage = voted(kLatest);
    if (stage == null) {
      // Warm and usable, but the label was never decided (e.g. the epoch
      // closed before warm-up completed and nothing has rebuilt it).
      return no(CausalAbstention.warmup,
          note: _warmNote(usableCount, cfg.warmupEpochs), row: row);
    }
    var run = 1;
    while (voted(kLatest - run) == stage) {
      run++;
    }

    final hrCov = recentUsable / span;
    final rrCov = recentRr / span;
    final conf =
        ((0.35 + 0.25 * rrCov) * hrCov).clamp(0.15, kMaxSleepConfidence);
    trace['raw'] = row.label?.name;
    trace['motion'] = row.motion;
    trace['hr'] = row.hr;
    trace['hrSd'] = row.hrSd;
    trace['sdnn'] = row.sdnn;
    trace['rk'] = row.rk;
    trace['lfhf'] = row.lfhf;
    trace['hrCoverage'] = hrCov;
    trace['rrCoverage'] = rrCov;
    final why = _explain(rows, kLatest, cfg);
    if (why != null) trace.addAll(why);

    return CausalStageObservation(
      stage: stage,
      confidence: conf.toDouble(),
      evidenceAgeMs: ageMs,
      nextState: next,
      abstentionReason: null,
      epochStartMs: kLatest * kCausalEpochSec * 1000.0,
      runSec: run * kCausalEpochSec.toDouble(),
      note: null,
      trace: trace,
    );
  }

  static String _warmNote(int have, int need) => 'warmup:have=$have,need=$need';

  static CausalStageObservation _mk(CausalStagerState next,
      CausalAbstention why, double? ageMs, Map<String, Object?> trace,
      {String? note, CausalEpochRow? row}) {
    return CausalStageObservation(
      stage: CausalStage.absent,
      confidence: 0,
      evidenceAgeMs: ageMs,
      nextState: next,
      abstentionReason: why,
      epochStartMs:
          row == null ? null : row.epoch * kCausalEpochSec * 1000.0,
      runSec: 0,
      note: note,
      trace: trace,
    );
  }

  static CausalStageObservation _absent(
      CausalStagerState st, CausalAbstention why) {
    return CausalStageObservation(
      stage: CausalStage.absent,
      confidence: 0,
      evidenceAgeMs: null,
      nextState: st,
      abstentionReason: why,
      epochStartMs: null,
      runSec: 0,
      note: null,
      trace: {
        'ignoredFuture': 0,
        'ignoredStale': 0,
        'rows': st.rows.length,
      },
    );
  }
}

// ── Merge ────────────────────────────────────────────────────────────────────

class _Merged {
  final List<List<double>> hr; // [sec, bpm], ascending by sec
  final List<List<double>> accel; // [sec, x, y, z]
  final List<List<double>> rr; // [ts, rr], ascending by ts
  final int ignoredFuture;
  final int ignoredStale;
  final int? dirtyFromSec; // earliest second touched by the window
  final int? newestSec;
  final int? latestUsableSec;
  const _Merged(this.hr, this.accel, this.rr, this.ignoredFuture,
      this.ignoredStale, this.dirtyFromSec, this.newestSec,
      this.latestUsableSec);
}

int _secOf(double tsMs) => (tsMs / 1000.0).floor();

_Merged _merge(CausalStagerState st, CausalSampleWindow w) {
  final now = w.nowMs;
  final prevNewest = st.newestSec;
  // Anything this far behind (or more) the newest stored sample has frozen
  // features: ignore it rather than half-apply it.
  final staleBeforeMs = prevNewest == null
      ? double.negativeInfinity
      : (prevNewest - _replaceHorizonSec) * 1000.0;
  var future = 0, stale = 0;

  // Time-acceptance, shared by all channels.
  bool accept(double ts) {
    if (!ts.isFinite) return false;
    if (ts >= now) {
      future++;
      return false;
    }
    if (ts < staleBeforeMs) {
      stale++;
      return false;
    }
    return true;
  }

  int? dirty;
  void touch(int sec) {
    if (dirty == null || sec < dirty!) dirty = sec;
  }

  // HR: window span replaces stored span; last duplicate second wins.
  final hrIn = <int, double>{};
  int? hrLo, hrHi;
  for (final s in w.hr) {
    if (!accept(s.tsMs)) continue;
    final sec = _secOf(s.tsMs);
    hrLo = hrLo == null ? sec : math.min(hrLo, sec);
    hrHi = hrHi == null ? sec : math.max(hrHi, sec);
    if (s.hr.isFinite && s.hr >= 0) {
      hrIn[sec] = s.hr;
    } else {
      hrIn.remove(sec); // an unusable sample is a missing one
    }
  }
  final hr = _spliceSec(st.hrTail, hrLo, hrHi, {
    for (final e in hrIn.entries) e.key: [e.key.toDouble(), e.value]
  });
  if (hrLo != null) touch(hrLo);

  // Accel.
  final acIn = <int, List<double>>{};
  int? acLo, acHi;
  for (final a in w.accel) {
    if (!accept(a.tsMs)) continue;
    final sec = _secOf(a.tsMs);
    acLo = acLo == null ? sec : math.min(acLo, sec);
    acHi = acHi == null ? sec : math.max(acHi, sec);
    if (a.valid && a.x.isFinite && a.y.isFinite && a.z.isFinite) {
      acIn[sec] = [sec.toDouble(), a.x, a.y, a.z];
    } else {
      acIn.remove(sec);
    }
  }
  final accel = _spliceSec(st.accelTail, acLo, acHi, acIn);
  if (acLo != null) touch(acLo);

  // RR: ties on a second are normal, so no per-key upsert — the window's span
  // replaces the stored span wholesale.
  final n = math.min(w.rr.tsMs.length, w.rr.rrMs.length);
  final rrIn = <List<double>>[];
  double? rrLo, rrHi;
  for (var i = 0; i < n; i++) {
    final ts = w.rr.tsMs[i];
    if (!accept(ts)) continue;
    rrLo = rrLo == null ? ts : math.min(rrLo, ts);
    rrHi = rrHi == null ? ts : math.max(rrHi, ts);
    final v = w.rr.rrMs[i];
    if (v.isFinite && v > 0) rrIn.add([ts, v]);
  }
  // Stable by timestamp; ties keep window order.
  final order = List<int>.generate(rrIn.length, (i) => i)
    ..sort((a, b) {
      final c = rrIn[a][0].compareTo(rrIn[b][0]);
      return c != 0 ? c : a.compareTo(b);
    });
  final rr = <List<double>>[];
  if (rrLo == null) {
    rr.addAll(st.rrTail);
  } else {
    for (final e in st.rrTail) {
      if (e[0] < rrLo) rr.add(e);
    }
    for (final i in order) {
      rr.add(rrIn[i]);
    }
    for (final e in st.rrTail) {
      if (e[0] > rrHi!) rr.add(e);
    }
    touch(_secOf(rrLo));
  }

  int? newest;
  void up(int s) {
    if (newest == null || s > newest!) newest = s;
  }

  if (hr.isNotEmpty) up(hr.last[0].toInt());
  if (accel.isNotEmpty) up(accel.last[0].toInt());
  if (rr.isNotEmpty) up(_secOf(rr.last[0]));

  // Newest second with valid on-skin HR AND valid accel.
  int? usable;
  {
    final hrBy = {for (final e in hr) e[0].toInt(): e[1]};
    for (var i = accel.length - 1; i >= 0; i--) {
      final sec = accel[i][0].toInt();
      final bpm = hrBy[sec];
      if (bpm != null && bpm > 0) {
        usable = sec;
        break;
      }
    }
  }
  return _Merged(hr, accel, rr, future, stale, dirty, newest, usable);
}

/// Replace the stored entries with `lo <= sec <= hi` by [incoming]; keep the
/// rest; result ascending by second.
List<List<double>> _spliceSec(
    List<List<double>> stored, int? lo, int? hi, Map<int, List<double>> incoming) {
  if (lo == null) return stored;
  final out = <List<double>>[
    for (final e in stored) if (e[0] < lo) e
  ];
  final keys = incoming.keys.toList()..sort();
  for (final k in keys) {
    out.add(incoming[k]!);
  }
  for (final e in stored) {
    if (e[0] > hi!) out.add(e);
  }
  return out;
}

// ── Feature rows ─────────────────────────────────────────────────────────────

List<CausalEpochRow> _rebuildRows(
    CausalStagerState st, CausalStagerConfig cfg, _Merged m, int kLatest) {
  final oldestKept = kLatest - cfg.historyEpochs + 1;
  final byEpoch = <int, CausalEpochRow>{
    for (final r in st.rows)
      if (r.epoch >= oldestKept && r.epoch <= kLatest) r.epoch: r
  };
  final dirty = m.dirtyFromSec;
  if (dirty != null && kLatest >= 0) {
    final kLo = math.max((dirty / kCausalEpochSec).floor(), math.max(0, oldestKept));
    if (kLo <= kLatest) {
      final hrBy = {for (final e in m.hr) e[0].toInt(): e[1]};
      final acBy = {for (final e in m.accel) e[0].toInt(): e};
      final rrTs = [for (final e in m.rr) e[0]];
      final rrV = [for (final e in m.rr) e[1]];
      final gRefMag = <int, double>{
        for (final e in acBy.entries)
          e.key: math.sqrt(e.value[1] * e.value[1] +
              e.value[2] * e.value[2] +
              e.value[3] * e.value[3])
      };
      for (var k = kLo; k <= kLatest; k++) {
        final row = _buildRow(k, hrBy, gRefMag, rrTs, rrV);
        if (row == null) {
          byEpoch.remove(k);
        } else {
          byEpoch[k] = row;
        }
      }
      // Decide labels in epoch order, each on baselines built from rows up to
      // and including its own epoch — never later ones.
      for (var k = kLo; k <= kLatest; k++) {
        final row = byEpoch[k];
        if (row == null) continue;
        final d = _decide(byEpoch, k, cfg);
        byEpoch[k] = row.withLabel(d?.stage);
      }
    }
  }
  final keys = byEpoch.keys.toList()..sort();
  return [for (final k in keys) byEpoch[k]!];
}

CausalEpochRow? _buildRow(int k, Map<int, double> hrBy,
    Map<int, double> mag, List<double> rrTs, List<double> rrV) {
  final s0 = k * kCausalEpochSec;
  final hrVals = <double>[];
  var off = 0;
  var anyHr = false;
  for (var s = s0; s < s0 + kCausalEpochSec; s++) {
    final b = hrBy[s];
    if (b == null) continue;
    anyHr = true;
    if (b > 0) {
      hrVals.add(b);
    } else {
      off++;
    }
  }
  final epochMags = <double>[
    for (var s = s0; s < s0 + kCausalEpochSec; s++)
      if (mag[s] != null) mag[s]!
  ];
  if (!anyHr && epochMags.isEmpty) return null;

  // Motion: ENMO against the trailing 300 s median of |a| (the causal form of
  // the retrospective stager's centred local 1 g reference).
  double? motion;
  if (epochMags.isNotEmpty) {
    final ref = <double>[
      for (var s = s0 + kCausalEpochSec - _gRefWinSec;
          s < s0 + kCausalEpochSec;
          s++)
        if (mag[s] != null) mag[s]!
    ];
    final g = median(ref) ?? 1.0;
    var sum = 0.0;
    for (final v in epochMags) {
      final d = v - g;
      sum += d > 0 ? d : 0.0;
    }
    motion = sum / epochMags.length;
  }

  // RR: trailing windows ending at the epoch's last millisecond (a beat stamped
  // at the next second boundary belongs to the next epoch).
  final endMs = (s0 + kCausalEpochSec) * 1000.0 - 1e-3;
  double? sdnn, rk, lfhf;
  if (rrTs.isNotEmpty) {
    final w300 = cleanRrBeatsBetween(rrV, rrTs, endMs - _sdnnWinSec * 1000.0, endMs);
    if (w300.beats.length >= 5) sdnn = stddev(w300.beats);
    final w180 = cleanRrBeatsBetween(rrV, rrTs, endMs - _remWinSec * 1000.0, endMs);
    final rem = remFeaturesFromBeats(w180.beats, w180.tsSec, w180.seam);
    rk = rem.rk;
    lfhf = rem.lfhf;
  }

  return CausalEpochRow(
    epoch: k,
    hrN: hrVals.length,
    hrOffN: off,
    accelN: epochMags.length,
    motion: motion,
    hr: hrVals.isEmpty ? null : mean(hrVals),
    hrSd: hrVals.length >= 2 ? stddev(hrVals) : null,
    sdnn: sdnn,
    rk: rk,
    lfhf: lfhf,
  );
}

// ── Decision (the retrospective stager's rules, on expanding baselines) ──────

class _Decision {
  final CausalStage stage;
  final double? remScore;
  final double hrArousal, hrP25, hrMed;
  final bool bigMove;
  const _Decision(this.stage, this.remScore, this.hrArousal, this.hrP25,
      this.hrMed, this.bigMove);
}

/// Decide epoch [k] using only usable rows with epoch in (k - historyEpochs, k].
/// Null when [k] is unusable or fewer than `warmupEpochs` usable rows exist.
_Decision? _decide(
    Map<int, CausalEpochRow> byEpoch, int k, CausalStagerConfig cfg) {
  final row = byEpoch[k];
  if (row == null || !row.usable) return null;
  final base = <CausalEpochRow>[
    for (var e = k - cfg.historyEpochs + 1; e <= k; e++)
      if (byEpoch[e] != null && byEpoch[e]!.usable) byEpoch[e]!
  ];
  if (base.length < cfg.warmupEpochs) return null;

  // Motion thresholds: whole-window scalars (as offline: only the absolute
  // magnitude references needed to be local). MAD 0 ⇒ the motion axis abstains.
  final motSample = [for (final r in base) r.motion!];
  final motMed = median(motSample) ?? 0;
  final motMadRaw = mad(motSample) ?? 0;
  final motUsable = motMadRaw > 0 && motMadRaw.isFinite;
  final motMad = motUsable ? motMadRaw : 0.0;
  final stillCut = motMed + 1.5 * motMad;
  final bigMoveCut = motMed + 5.0 * motMad;
  bool still(CausalEpochRow r) => !motUsable || r.motion! <= stillCut;
  bool bigMove(CausalEpochRow r) => motUsable && r.motion! > bigMoveCut;

  final sleepHr = <double>[
    for (final r in base)
      if (still(r)) r.hr!
  ];
  final hrAll = [for (final r in base) r.hr!];
  final hrMedGlobal = median(sleepHr) ?? mean(hrAll)!;

  // Local trailing HR gates (retrospective: ±180 epochs; causal: past 180).
  final win = <double>[
    for (final r in base)
      if (r.epoch >= k - _hrWinEpochs && still(r)) r.hr!
  ];
  final sd = stddev(win); // before the sort: float sums are order-dependent
  win.sort();
  final m = percentileSorted(win, 50);
  double hrMed = hrMedGlobal, hrArousal = hrMedGlobal + 6.0, hrP25 = hrMedGlobal;
  if (m != null) {
    hrMed = m;
    hrArousal = m + math.max(6.0, (sd ?? 6));
    hrP25 = percentileSorted(win, 25) ?? m;
  }

  final hr = row.hr!;
  final big = bigMove(row);
  final prev = byEpoch[k - 1];
  final bigPrev = prev != null && prev.usable && bigMove(prev);
  final hrUp = hr >= hrArousal;
  final bigMoveWake = big && (hr >= hrMed || bigPrev);
  if (hrUp || bigMoveWake) {
    return _Decision(CausalStage.wake, null, hrArousal, hrP25, hrMed, big);
  }

  // REM: weighted robust-z score over the axes measurable this epoch.
  final sleepRk = [for (final r in base) if (still(r) && r.rk != null) r.rk!];
  final sleepSdnn = [for (final r in base) if (still(r) && r.sdnn != null) r.sdnn!];
  final sleepLfhf = [for (final r in base) if (still(r) && r.lfhf != null) r.lfhf!];
  final sleepHrSd = [
    for (final r in base)
      if (still(r) && r.hrSd != null && r.hrSd! > 0) r.hrSd!
  ];
  final rkZ = (sleepRk.length >= 4 && row.rk != null)
      ? RobustScale.of(sleepRk)?.z(row.rk!)
      : null;
  final sdnnZ = (sleepSdnn.length >= 4 && row.sdnn != null)
      ? RobustScale.of(sleepSdnn)?.z(row.sdnn!)
      : null;
  final lfhfZ = (sleepLfhf.length >= 4 && row.lfhf != null)
      ? RobustScale.of(sleepLfhf)?.z(row.lfhf!)
      : null;
  final hrSdZ = (sleepHrSd.length >= 4 && row.hrSd != null && row.hrSd! > 0)
      ? RobustScale.of(sleepHrSd)?.z(row.hrSd!)
      : null;
  final remScore = weightedAxisScore([
    (rkZ, kRemWeightRk),
    (sdnnZ, kRemWeightSdnn),
    (hrSdZ, kRemWeightHrSd),
    (lfhfZ, kRemWeightLfhf),
  ]);
  final atonia = !big;
  final hrTowardWake = hr >= hrP25;
  final isRem =
      remScore != null && remScore > cfg.remScoreCut && atonia && hrTowardWake;
  return _Decision(isRem ? CausalStage.rem : CausalStage.nrem, remScore,
      hrArousal, hrP25, hrMed, big);
}

/// Trace fields for the newest epoch's decision, recomputed (not stored).
Map<String, Object?>? _explain(
    List<CausalEpochRow> rows, int k, CausalStagerConfig cfg) {
  final byEpoch = {for (final r in rows) r.epoch: r};
  final d = _decide(byEpoch, k, cfg);
  if (d == null) return null;
  return {
    'remScore': d.remScore,
    'remCut': cfg.remScoreCut,
    'hrArousal': d.hrArousal,
    'hrP25': d.hrP25,
    'hrMedLocal': d.hrMed,
    'bigMove': d.bigMove,
  };
}
