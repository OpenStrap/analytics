// Internal rule for SD1/SD2, pNNx thresholds and sustained-window voting.
// Task Force 1996 supports successive-difference HRV components, not this
// classifier or its SD1/SD2 thresholds; see hrv_time.dart.
// Internal irregular-rhythm screen, ESTIMATE with low confidence. Batch and
// stream share irregularWindowVerdict(); centered moments reorder floating-point
// sums, while exact counters preserve window evidence. Shared adjacency excludes
// timestamp-gap pairs. Diagnostics account for evidence without adding a
// clinical estimator.
// CLINICAL — the evidence behind an irregular-rhythm screen verdict.
//
// What it is for: `irregularBeatScreen` computes the beat counts, the cleaning
// counts and the per-5-minute-window counts on its way to a flag, then throws
// them away. A reader who sees "flagged" or "not screened" cannot tell why.
// [IrregularDiagnostics] keeps them, for a screen that RAN and for one that
// ABSTAINED (an abstention carries the counts that caused it).
//
// Absent stays absent: an input the caller did not give is null, never 0. The
// batch call and the streaming `IrregularScreenState` must produce the same
// diagnostics for the same beats, however chunked or restored.

import '../types.dart';
import 'irregular_rhythm.dart';

/// What the RR corrector did before the screen saw the beats. Only the caller
/// has it (the screen sees the corrected NN), so it is handed in; batch passes
/// the fields of `RrCorrectionResult`, streaming those of `RrSnapshot`.
class RrCleaningCounts {
  /// Beats fed to the corrector.
  final int raw;

  /// Isolated artifacts replaced by the spline.
  final int corrected;

  /// Beats dropped (part of a multi-beat run, or with no anchors to correct from).
  final int dropped;
  const RrCleaningCounts({
    required this.raw,
    required this.corrected,
    required this.dropped,
  });
}

/// The artifact fraction to record as evidence: [fraction], or null when
/// [cleaning] says the corrector saw no beats (no denominator).
double? diagnosticArtifactFraction(double fraction, RrCleaningCounts? cleaning) =>
    cleaning != null && cleaning.raw == 0 ? null : fraction;

/// Why a screen produced no value. Wire names (toJson): `too_few_beats`,
/// `artifact`, `no_successive_pairs`, `no_long_term_variability`.
enum IrregularAbstain {
  tooFewBeats,
  artifact,
  noSuccessivePairs,
  noLongTermVariability,
}

/// The final window of the series. A series always ends mid-window, so the last
/// window is OPEN; it is counted, not silently dropped. Wire names: `none`
/// (no beats at all), `thin` (fewer than minWindowBeats, excluded from the
/// valid count), `unflagged` (valid, not flagged), `flagged` (valid, flagged).
enum IrregularOpenWindow { none, thin, unflagged, flagged }

/// The thresholds the verdict was made against.
class IrregularThresholds {
  final int minBeats;
  final double maxArtifact;
  final double sd1sd2Flag;
  final double pnnThresholdMs;
  final double pnnFlagPct;
  final double windowMinutes;
  final int minWindowBeats;
  final double sustainedFraction;
  const IrregularThresholds({
    required this.minBeats,
    required this.maxArtifact,
    required this.sd1sd2Flag,
    required this.pnnThresholdMs,
    required this.pnnFlagPct,
    required this.windowMinutes,
    required this.minWindowBeats,
    required this.sustainedFraction,
  });
}

/// Per-window counts. Totals INCLUDE the open window; [open] says what it was.
class IrregularWindowCounts {
  /// Windows with at least one clean beat (a window opens on a beat).
  final int total;

  /// Windows with at least minWindowBeats beats (the ones that vote).
  final int valid;

  /// Valid windows where both SD1/SD2 and pNNx cleared their flag lines.
  final int flagged;

  /// The final window: its beat count and what became of it.
  final int openBeats;
  final IrregularOpenWindow open;
  const IrregularWindowCounts({
    required this.total,
    required this.valid,
    required this.flagged,
    required this.openBeats,
    required this.open,
  });

  /// flagged / valid, null (never 0 or NaN) when no window is valid.
  double? get sustainedObserved => valid == 0 ? null : flagged / valid;
}

class IrregularDiagnostics {
  /// Null when the screen ran and produced a value.
  final IrregularAbstain? abstain;

  /// Beats fed to the corrector / corrected / dropped. Null when the caller did
  /// not hand [RrCleaningCounts] in (unknown, not zero).
  final int? rrRaw, corrected, dropped;

  /// NN entries handed to the screen (NaN and out-of-range included) and the
  /// ones inside [300, 2000] ms that it used (== `IrregularRhythm.nBeats`).
  final int nnIn, nnKept;

  /// The artifact fraction handed in (0 when none was). Null when the corrector
  /// was handed no beats ([RrCleaningCounts.raw] == 0): a share of nothing has
  /// no value, and the `1 - cleanFraction` of an empty series (1.0) would read
  /// as "every beat is an artifact". The verdict gate still reads the fraction
  /// the caller passed; only this evidence field is absent.
  final double? artifactFraction;

  /// Null when windows were not evaluated: no beat times (or a length that does
  /// not match the beats), or a window config that fails closed.
  final IrregularWindowCounts? windows;
  final IrregularThresholds thresholds;

  const IrregularDiagnostics({
    required this.abstain,
    required this.rrRaw,
    required this.corrected,
    required this.dropped,
    required this.nnIn,
    required this.nnKept,
    required this.artifactFraction,
    required this.windows,
    required this.thresholds,
  });

  static const _abstainWire = {
    IrregularAbstain.tooFewBeats: 'too_few_beats',
    IrregularAbstain.artifact: 'artifact',
    IrregularAbstain.noSuccessivePairs: 'no_successive_pairs',
    IrregularAbstain.noLongTermVariability: 'no_long_term_variability',
  };

  /// Wire shape (version 1); see test/onehz/irregular_diagnostics_test.dart.
  /// Doubles are written as they are held, so a JSON text round trip is exact.
  Map<String, dynamic> toJson() => {
        'version': 1,
        'abstain': abstain == null ? null : _abstainWire[abstain],
        'beats': {
          'rr_raw': rrRaw,
          'nn_in': nnIn,
          'nn_kept': nnKept,
          'corrected': corrected,
          'dropped': dropped,
          'artifact_fraction': artifactFraction,
        },
        'windows': windows == null
            ? null
            : {
                'total': windows!.total,
                'valid': windows!.valid,
                'flagged': windows!.flagged,
                'sustained_observed': windows!.sustainedObserved,
                'open_beats': windows!.openBeats,
                'open': windows!.open.name,
              },
        'thresholds': {
          'min_beats': thresholds.minBeats,
          'max_artifact': thresholds.maxArtifact,
          'sd1sd2_flag': thresholds.sd1sd2Flag,
          'pnn_threshold_ms': thresholds.pnnThresholdMs,
          'pnn_flag_pct': thresholds.pnnFlagPct,
          'window_minutes': thresholds.windowMinutes,
          'min_window_beats': thresholds.minWindowBeats,
          'sustained_fraction': thresholds.sustainedFraction,
        },
      };

  /// Throws [FormatException] on a map of another version or a malformed one.
  factory IrregularDiagnostics.fromJson(Map<String, dynamic> json) {
    try {
      return _restore(json);
    } on FormatException {
      rethrow;
    } catch (e) {
      throw FormatException('malformed IrregularDiagnostics: $e');
    }
  }

  static IrregularDiagnostics _restore(Map<String, dynamic> j) {
    if (j['version'] != 1) {
      throw FormatException('unsupported IrregularDiagnostics version ${j['version']}');
    }
    final b = j['beats'] as Map, th = j['thresholds'] as Map;
    final w = j['windows'] as Map?;
    final a = j['abstain'] as String?;
    IrregularAbstain? abstain;
    if (a != null) {
      final hit = _abstainWire.entries.where((e) => e.value == a);
      if (hit.isEmpty) throw FormatException('unknown abstain reason $a');
      abstain = hit.first.key;
    }
    double d(Map m, String k) => (m[k] as num).toDouble();
    return IrregularDiagnostics(
      abstain: abstain,
      rrRaw: b['rr_raw'] as int?,
      corrected: b['corrected'] as int?,
      dropped: b['dropped'] as int?,
      nnIn: b['nn_in'] as int,
      nnKept: b['nn_kept'] as int,
      artifactFraction:
          b['artifact_fraction'] == null ? null : d(b, 'artifact_fraction'),
      windows: w == null
          ? null
          : IrregularWindowCounts(
              total: w['total'] as int,
              valid: w['valid'] as int,
              flagged: w['flagged'] as int,
              openBeats: w['open_beats'] as int,
              open: IrregularOpenWindow.values.byName(w['open'] as String),
            ),
      thresholds: IrregularThresholds(
        minBeats: th['min_beats'] as int,
        maxArtifact: d(th, 'max_artifact'),
        sd1sd2Flag: d(th, 'sd1sd2_flag'),
        pnnThresholdMs: d(th, 'pnn_threshold_ms'),
        pnnFlagPct: d(th, 'pnn_flag_pct'),
        windowMinutes: d(th, 'window_minutes'),
        minWindowBeats: th['min_window_beats'] as int,
        sustainedFraction: d(th, 'sustained_fraction'),
      ),
    );
  }
}

/// A screen verdict and the evidence behind it.
class IrregularScreenResult {
  final Metric<IrregularRhythm> metric;
  final IrregularDiagnostics diagnostics;
  const IrregularScreenResult(this.metric, this.diagnostics);

  /// `metric.toJson((v) => v.toJson())` plus a `diagnostics` key: the envelope
  /// edge persists. The existing keys are unchanged.
  Map<String, dynamic> toJson() => {
        ...metric.toJson((v) => v.toJson()),
        'diagnostics': diagnostics.toJson(),
      };
}
