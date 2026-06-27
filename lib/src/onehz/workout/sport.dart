// sport.dart — the HYBRID sport-classifier seam.
//
// The workout detector labels every bout "detected" without sport typing.
// OpenStrap additionally has a motion-based HAR typer (Mannini 2013 +
// db10 wavelets), but that is currently TS-only and needs high-rate (~100 Hz)
// accel features that the 1 Hz bundle does not carry. This seam leaves a clean,
// typed drop-in point for the classifier the moment high-rate features are
// available.
//
// Contract: every detected bout is run through a [SportClassifier]; the default
// ([defaultSportClassifier]) returns "detected" (no sport typing). Supply
// your own to type the bout (e.g. "run" / "cycle" / "strength").

/// The default sport label emitted for every detected bout (no sport typing).
const String defaultSportLabel = 'detected';

/// A detected workout bout, the unit a classifier types. HR-derived fields are
/// always available; motion features may be null on a 1 Hz-only bundle.
class WorkoutBout {
  final int startSec;
  final int endSec;
  final double avgBpm;
  final double peakBpm;
  final double durationS;
  const WorkoutBout({
    required this.startSec,
    required this.endSec,
    required this.avgBpm,
    required this.peakBpm,
    required this.durationS,
  });
}

/// Lightweight motion-feature struct a future sport classifier can read.
///
/// On the 1 Hz substrate only an AMPLITUDE index is recoverable (Nyquist 0.5 Hz
/// < 1.4–2.5 Hz gait), so [meanIntensity] (mean L2 gravity-delta over the bout)
/// is the only cheap, honest feature populated here. [cadenceHz] / [enmo] are
/// reserved for when a high-rate foreground accel feed supplies them — left null
/// otherwise rather than fabricated.
class MotionFeatures {
  /// Mean per-second L2 gravity-delta over the bout (1 Hz amplitude index).
  final double meanIntensity;

  /// Dominant gait cadence (Hz), only from a high-rate feed; else null.
  final double? cadenceHz;

  /// Euclidean-norm-minus-one mean over the bout, only from high-rate; else null.
  final double? enmo;

  const MotionFeatures({
    required this.meanIntensity,
    this.cadenceHz,
    this.enmo,
  });
}

/// Types a bout to a sport label. [feats] is null on a 1 Hz-only bundle.
typedef SportClassifier = String Function(
    WorkoutBout bout, MotionFeatures? feats);

/// Default seam: every bout is "detected", no sport typing.
String defaultSportClassifier(WorkoutBout bout, MotionFeatures? feats) =>
    defaultSportLabel;
