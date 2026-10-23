// SLEEP — per-stage minute RANGES.
//
// The cardio stager gives each epoch one label. This file turns those labels
// into a [lo, hi] range of minutes per stage, so a caller can show how much of
// each stage figure the evidence actually pins down.
//
// WHAT THE RANGE IS. An honest BOUND, not a statistical confidence interval.
// The stager has no per-epoch posteriors: it compares two weighted robust-z
// scores against fixed cutoffs ([kDefaultRemScoreCut], [kDefaultDeepScoreCut])
// and reports a night confidence from coverage. So the only per-epoch evidence
// is "which side of the cutoff, and how far". The range counts:
//   lo[s] = epochs that can only be s: HR-covered, labelled s, and every score
//           that decided the label at least `margin` from its cutoff;
//   hi[s] = lo[s] + epochs that could still be s: uncovered or unlabelled
//           epochs (any stage), and asleep epochs with a score inside the
//           margin (REM score: REM and its NREM substage; deep score: light
//           and deep).
// Owner decision (2026-10-19): a fully covered night has lo == hi only where
// every score is clear of its cutoff. Nothing here moves the stager's label.

import 'accounting.dart' show SleepStage;
import 'cardio_stager.dart'
    show CardioStagerResult, kDefaultDeepScoreCut, kDefaultRemScoreCut;

// Internal rule, ESTIMATE with low confidence, derived from cardioStager() score
// cutoffs. Long 2016 / Fonseca 2015/2018 supports the underlying staging family,
// not the unpublished margin or bounds. This is not a confidence interval.
/// How far (in stage-score units) a score must sit from its cutoff before the
/// label it decided counts as clear.
///
/// The scores are weighted means of robust z, and the shipped cutoffs were
/// chosen on an 11-night sweep with a 0.1 grid (see the table above
/// [kDefaultRemScoreCut]). One grid step moves median %REM by about 5 points
/// and %Deep by about 3, and the sweep cannot rank cutoffs finer than that.
/// So a score within 0.1 of its cutoff would flip under a neighbouring cutoff
/// the calibration could not tell apart from the shipped one. That is the only
/// precision we can justify; it is NOT a measured per-epoch error rate.
const double kStageScoreMargin = 0.1;

/// One epoch's staging evidence, as [stageMinuteRanges] reads it.
class StageEpochEvidence {
  /// The final label; null when the epoch has no label at all.
  final SleepStage? stage;

  /// Deep flag (meaningful only when [stage] is NREM).
  final bool deep;

  /// The epoch carried at least one valid HR sample.
  final bool covered;

  /// The REM and deep scores that decided the label; null when not scored.
  final double? remScore;
  final double? deepScore;

  const StageEpochEvidence({
    this.stage,
    this.deep = false,
    this.covered = true,
    this.remScore,
    this.deepScore,
  });
}

/// A [lo, hi] range of minutes.
class MinuteRange {
  final double lo, hi;
  const MinuteRange(this.lo, this.hi);

  Map<String, double> toJson() => {'lo': lo, 'hi': hi};
}

/// Per-stage minute ranges over a staged window of [windowMin] minutes.
/// [nrem] is light ∪ deep.
class StageMinuteRanges {
  final MinuteRange wake, light, deep, rem, nrem;
  final double windowMin;

  const StageMinuteRanges({
    required this.wake,
    required this.light,
    required this.deep,
    required this.rem,
    required this.nrem,
    required this.windowMin,
  });

  /// The four display stages as `{lo, hi}`.
  Map<String, Map<String, double>> toJson() => {
        'wake': wake.toJson(),
        'light': light.toJson(),
        'deep': deep.toJson(),
        'rem': rem.toJson(),
      };
}

extension CardioStagerEvidence on CardioStagerResult {
  /// One entry per final epoch: the final label and deep flag, whether the
  /// epoch had valid HR, and the scores the classify loop computed for it.
  /// Empty when the stager abstained.
  List<StageEpochEvidence> get epochEvidence {
    final stages = base.stages;
    return [
      for (var e = 0; e < stages.length; e++)
        StageEpochEvidence(
          stage: stages[e],
          deep: e < deepFlag.length && deepFlag[e],
          // A result built without coverage cannot vouch for any epoch.
          covered: e < hrCovered.length && hrCovered[e],
          remScore: e < remScores.length ? remScores[e] : null,
          deepScore: e < deepScores.length ? deepScores[e] : null,
        ),
    ];
  }
}

const int _wake = 1, _light = 2, _deep = 4, _rem = 8;
const int _any = _wake | _light | _deep | _rem;
const int _nremSet = _light | _deep;

/// Per-stage minute ranges for [epochs] ([epochSec] seconds each). Null when
/// there are no epochs. See the file header for the rule.
StageMinuteRanges? stageMinuteRanges(
  List<StageEpochEvidence>? epochs, {
  int epochSec = 30,
  double remScoreCut = kDefaultRemScoreCut,
  double deepScoreCut = kDefaultDeepScoreCut,
  double margin = kStageScoreMargin,
}) {
  if (epochs == null || epochs.isEmpty) return null;
  // Written as an open interval on `cut ± margin` so a score of exactly
  // `cut + margin` compares equal to the bound and counts as clear.
  bool near(double? s, double cut) =>
      s != null && s > cut - margin && s < cut + margin;

  final lo = <int, int>{_wake: 0, _light: 0, _deep: 0, _rem: 0, _nremSet: 0};
  final hi = <int, int>{_wake: 0, _light: 0, _deep: 0, _rem: 0, _nremSet: 0};
  for (final ep in epochs) {
    final int can; // bitset of stages this epoch could be
    if (!ep.covered || ep.stage == null) {
      can = _any;
    } else if (ep.stage == SleepStage.wake) {
      can = _wake;
    } else {
      final deepNear = near(ep.deepScore, deepScoreCut);
      final int sub;
      if (deepNear) {
        sub = _nremSet;
      } else if (ep.stage == SleepStage.nrem) {
        sub = ep.deep ? _deep : _light;
      } else {
        // A REM epoch's NREM neighbour is the substage its deep score points to.
        final ds = ep.deepScore;
        sub = (ds != null && ds > deepScoreCut) ? _deep : _light;
      }
      final remNear = near(ep.remScore, remScoreCut);
      can = remNear
          ? (_rem | sub)
          : (ep.stage == SleepStage.rem ? _rem : sub);
    }
    for (final s in const [_wake, _light, _deep, _rem]) {
      if (can & s != 0) hi[s] = hi[s]! + 1;
      if (can == s) lo[s] = lo[s]! + 1;
    }
    if (can & _nremSet != 0) hi[_nremSet] = hi[_nremSet]! + 1;
    if (can & ~_nremSet == 0) lo[_nremSet] = lo[_nremSet]! + 1;
  }
  final m = epochSec / 60.0;
  MinuteRange r(int s) => MinuteRange(lo[s]! * m, hi[s]! * m);
  return StageMinuteRanges(
    wake: r(_wake),
    light: r(_light),
    deep: r(_deep),
    rem: r(_rem),
    nrem: r(_nremSet),
    windowMin: epochs.length * m,
  );
}
