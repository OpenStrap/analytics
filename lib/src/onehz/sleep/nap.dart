// SLEEP — daytime nap detection.
//
// WHY THIS IS NOT `AdvancedSleepStager.detectSleep`
// -------------------------------------------------
// The nocturnal detector rejects naps ON PURPOSE. `minSleepMin = 60` exists so
// "daytime naps and stray still-blocks stay excluded" (advanced_stager.dart),
// and any period centred 11:00–20:00 local must additionally clear
// `daytimeMinSleepMin = 90` plus a resting-HR dip. Those gates are load-bearing
// for NIGHT accuracy, so they are not loosened here. Naps get their own
// detector instead, run strictly on the complement of the main sleep window.
//
// METHOD
//   1. van Hees z-angle immobility (`immobilityMask`) — the SAME primitive the
//      nocturnal spine uses. An angle is orientation-invariant, so it does not
//      inherit the ~13% spread in |accel| across static wrist postures that
//      makes magnitude-based stillness false-positive on a merely resting arm.
//   2. Enumerate EVERY immobility bout (the nocturnal path keeps only the
//      longest), bridging brief arousals.
//   3. Reject hard: off-wrist, charging/workout spans, the main sleep window.
//   4. Require an autonomic signature — median HR inside the bout at or below
//      `napRestingHrMult` × the DAYTIME-AWAKE HR baseline. Stillness alone is
//      also desk work, reading and a car passenger seat.
//   5. Abstain rather than guess when HR coverage inside a bout is too thin.
//
// HONESTY CEILING. This is an ESTIMATE from a 1 Hz wrist gravity vector plus
// opportunistic HR, never PSG. It reports WHETHER and HOW LONG, and makes no
// sleep-stage claim: a 30-minute nap contains no complete sleep cycle, and the
// daytime HR duty cycle will not support a 4-class partition. Time asleep and
// time in bed are reported separately and are never conflated.
//
// NO TIMEZONE DEPENDENCE, by construction. Corroboration is physiological (an
// HR dip against the user's own awake baseline), not clock-based, so a nap does
// not appear or vanish with the machine's local offset.

import '../types.dart';
import '../util.dart';
import 'van_hees.dart';

/// An index range [start, end) into the day's arrays marking the MAIN
/// nocturnal sleep, so [detectNaps] can carve it out.
class SleepWindowSpan {
  final int start;
  final int end;
  const SleepWindowSpan(this.start, this.end);
}

/// One detected daytime sleep episode. [startSec]/[endSec] are seconds
/// RELATIVE to the first supplied sample.
class NapWindow {
  final int startSec;
  final int endSec;

  /// Time in bed — the full span of the bout, brief arousals included.
  final int tibSec;

  /// Time asleep — seconds within the bout showing no wrist movement.
  /// Always <= [tibSec]. This, never [tibSec], is the sleep-need credit.
  final int tstSec;

  /// How sure we are this was sleep, in [0.2, 0.85]. Composed from HR
  /// coverage, the depth of the HR dip, the still fraction, and whether
  /// wrist-on telemetry corroborated it. NOT sleep efficiency.
  final double confidence;

  const NapWindow({
    required this.startSec,
    required this.endSec,
    required this.tibSec,
    required this.tstSec,
    required this.confidence,
  });

  /// Fraction of the bout actually spent asleep, in [0, 1].
  double get efficiency => tibSec <= 0 ? 0 : tstSec / tibSec;

  Map<String, dynamic> toJson() => {
        'start_sec': startSec,
        'end_sec': endSec,
        'tib_sec': tibSec,
        'tst_sec': tstSec,
        'efficiency': round6(efficiency),
        'confidence': round6(confidence),
      };
}

/// Shortest episode reported as a nap. Below this it is rest, not sleep.
const int minNapSec = 15 * 60;

/// Longest episode still called a nap. Wide enough to keep genuine biphasic /
/// split / shift-work second sleep, which is too long to be a nap but also
/// loses to the main-sleep pick and would otherwise vanish from every output.
const int maxNapSec = 6 * 3600;

/// Brief arousals bridged inside one nap. Far shorter than the nocturnal
/// 30-minute bridge, so two genuinely separate naps do not merge into one.
const int napBridgeSec = 5 * 60;

/// Median HR inside a nap must sit at or below this multiple of the user's
/// daytime-awake baseline. Matches the nocturnal daytime guard's constant.
const double napRestingHrMult = 0.95;

/// A bout needs HR on at least this fraction of its seconds to be judged at
/// all. Below it we abstain — daytime HR is opportunistic on this device.
const double minNapHrCoverage = 0.5;

/// A bout overlapping off-wrist or excluded (charging / workout) spans by at
/// least this fraction is discarded. A charging band is perfectly still.
const double maxNapOffWristFraction = 0.5;

/// Two sleep bouts closer together than this belong to ONE sleep episode with
/// an awakening in it, not two naps — the nocturnal detector uses the same idea
/// (`nightContinuationGapMin`). Only used to propagate DEFERRAL backwards: if
/// the record ends mid-sleep, every bout chained to that unfinished one is also
/// unfinished. Without it, a five-minute 01:50 awakening splits tonight's sleep
/// and the leading fragment gets emitted as a multi-hour "nap" for the day that
/// is ending — the exact phantom the deferral exists to prevent.
const int napChainGapSec = 60 * 60;

/// Minimum awake HR samples needed to define a baseline. Below this the day is
/// not judged at all: a threshold set by a handful of samples is not a
/// baseline, and every nap decision hangs off it.
const int minAwakeHrSamples = 10 * 60;

/// Detect daytime naps in a 1 Hz day.
///
/// [accel] gravity vectors and [hr] heart rate, same time base and length.
/// [mainSleep] index range of the nocturnal sleep to carve out. [wristOff] and
/// [exclude] are `[startSec, endSec]` spans in ABSOLUTE epoch seconds
/// (matching `AdvancedSleepStager`'s convention) for off-wrist and for
/// charging/workout periods respectively.
///
/// Returns [Metric.absent] only when the day cannot be judged at all (too
/// little data, or no awake HR to build a baseline from). A day that WAS
/// judged and held no nap returns an empty list — those two are different
/// answers and must not be collapsed.
Metric<List<NapWindow>> detectNaps(
  List<AccelSample> accel,
  List<double> hr, {
  SleepWindowSpan? mainSleep,
  List<List<int>> wristOff = const [],
  List<List<int>> exclude = const [],
}) {
  const inputs = ['accel_1hz', 'hr_1hz'];
  final n = accel.length < hr.length ? accel.length : hr.length;
  if (n < minNapSec) {
    return const Metric<List<NapWindow>>.absent(
      tier: Tier.estimate,
      inputs_used: inputs,
      note: 'too little data for nap detection (need ≥15 min)',
    );
  }

  final series = accel.length == n ? accel : accel.sublist(0, n);
  final mask = immobilityMask(series);
  final win = mask.sustainedSec;
  final thr = mask.thresholdDeg;

  final baseSec = series.first.tsMs ~/ 1000;
  int absAt(int idx) => series[idx].tsMs ~/ 1000;

  // Work from the per-second STILL predicate, not from `mask.immobile`.
  //
  // `immobile` marks the second that STARTS a sustained-still window, so its
  // run ends a full `sustainedSec` before the block physically does. Building
  // bouts on those marks both under-reports every nap by that margin AND
  // inflates the apparent gap between two halves of one nap by the same
  // amount, so a 2-minute arousal reads as a 7-minute one and splits the nap.
  // Enumerating real still runs and applying the sustained-inactivity rule to
  // each run's LENGTH is the same van Hees criterion without the artifact.
  //
  // A run also BREAKS at a recording discontinuity. The substrate is a
  // positional array, not a uniform grid: pruning and sync gaps leave holes, so
  // two samples an hour apart can be adjacent indices. Joining them would read
  // an unobserved hour as unbroken stillness and count it as sleep.
  bool stillAt(int k) =>
      mask.deltaDeg[k] < thr && (k == 0 || absAt(k) - absAt(k - 1) == 1);

  final runs = <List<int>>[];
  var i = 0;
  while (i < n) {
    if (!stillAt(i)) {
      i++;
      continue;
    }
    var j = i;
    while (j < n && stillAt(j)) {
      j++;
    }
    // van Hees sustained-inactivity, measured in ELAPSED SECONDS rather than
    // sample count so a gappy run cannot qualify on fewer real seconds.
    if (absAt(j - 1) + 1 - absAt(i) >= win) runs.add([i, j]);
    i = j;
  }

  // Bridge brief arousals between qualifying runs into a single episode — on
  // the wall clock, again because index distance is not elapsed time.
  final bouts = <List<int>>[];
  for (final r in runs) {
    if (bouts.isNotEmpty &&
        absAt(r[0]) - (absAt(bouts.last[1] - 1) + 1) < napBridgeSec) {
      bouts.last[1] = r[1];
    } else {
      bouts.add([r[0], r[1]]);
    }
  }

  // Which bouts are unfinished, walking BACKWARD from the record end.
  //
  // A bout running past the last sample has no knowable end. Crucially, so does
  // any bout CHAINED to it: a five-minute awakening at 01:50 splits tonight's
  // sleep into two bouts, and only the trailing one touches the array end. A
  // rule that checked just `end >= n` would leave the leading multi-hour
  // fragment to be emitted as today's "nap" and then counted a second time as
  // tomorrow's main sleep, which is precisely the double-count the deferral is
  // here to stop.
  final unfinished = List<bool>.filled(bouts.length, false);
  for (var b = bouts.length - 1; b >= 0; b--) {
    if (bouts[b][1] >= n) {
      unfinished[b] = true;
      continue;
    }
    if (b + 1 < bouts.length &&
        unfinished[b + 1] &&
        absAt(bouts[b + 1][0]) - (absAt(bouts[b][1] - 1) + 1) <
            napChainGapSec) {
      unfinished[b] = true;
    }
  }

  // The AWAKE HR baseline: seconds that are neither the main sleep nor ANY
  // detected sleep bout. Excluding only `mainSleep` was not enough — it left
  // the candidate bout's own low-HR seconds in the median it is then judged
  // against, and on this device the nap window deliberately extends hours past
  // midnight, so the first hours of tonight's sleep were dragging the bar down
  // too. Both make the gate self-suppressing: the quieter the sleep, the lower
  // the threshold it has to beat.
  final inBout = List<bool>.filled(n, false);
  for (final b in bouts) {
    for (var k = b[0]; k < b[1]; k++) {
      inBout[k] = true;
    }
  }
  final awake = <double>[];
  for (var k = 0; k < n; k++) {
    if (hr[k] <= 0 || inBout[k]) continue;
    if (mainSleep != null && k >= mainSleep.start && k < mainSleep.end) continue;
    awake.add(hr[k]);
  }
  if (awake.length < minAwakeHrSamples) {
    return Metric<List<NapWindow>>.absent(
      tier: Tier.estimate,
      inputs_used: inputs,
      note: 'not enough awake daytime HR to set a baseline '
          '(${awake.length}s, need ${minAwakeHrSamples}s) — '
          'cannot corroborate stillness as sleep',
    );
  }
  final baseline = median(awake)!;
  if (baseline <= 0) {
    return const Metric<List<NapWindow>>.absent(
      tier: Tier.estimate,
      inputs_used: inputs,
      note: 'no usable awake daytime HR baseline',
    );
  }

  final naps = <NapWindow>[];
  var deferred = 0, unverifiable = 0, offWrist = 0, awakeStill = 0;
  // Every rejection path increments one of these and reports it in `skipped`.
  // A silent `continue` turns "your 7-hour still block is too long to be a nap"
  // into a bare "no qualifying nap", which tells the caller nothing about why.
  var outOfRange = 0, inMainSleep = 0;

  for (var bi = 0; bi < bouts.length; bi++) {
    final start = bouts[bi][0], end = bouts[bi][1];

    // Never finalize an unfinished bout (see `unfinished` above): the record
    // cannot say when it ended, so emitting it risks writing the first hours of
    // tonight's sleep as today's nap and counting the same minutes twice.
    if (unfinished[bi]) {
      deferred++;
      continue;
    }

    // In bed is WALL-CLOCK elapsed time, not sample count. Across a recording
    // hole those differ, and the reported start/end are wall-clock — a
    // sample-count duration would silently disagree with its own bounds.
    final aStart = absAt(start);
    final aEnd = absAt(end - 1) + 1;
    final tib = aEnd - aStart;
    if (tib < minNapSec || tib > maxNapSec) {
      outOfRange++;
      continue;
    }

    if (mainSleep != null &&
        start < mainSleep.end &&
        end > mainSleep.start) {
      inMainSleep++;
      continue;
    }

    final offFrac = _overlapFraction(aStart, aEnd, wristOff);
    final exFrac = _overlapFraction(aStart, aEnd, exclude);
    if (offFrac >= maxNapOffWristFraction ||
        exFrac >= maxNapOffWristFraction) {
      offWrist++;
      continue;
    }

    // NOT `inBout` — that name belongs to the whole-day boolean baseline mask
    // above, and shadowing it here would silently hand the HR list to any later
    // edit that reaches for the mask inside this loop.
    final boutHr = <double>[];
    for (var k = start; k < end; k++) {
      if (hr[k] > 0) boutHr.add(hr[k]);
    }
    final coverage = boutHr.length / tib;
    if (coverage < minNapHrCoverage) {
      unverifiable++;
      continue;
    }
    final medHr = median(boutHr)!;
    if (medHr > baseline * napRestingHrMult) {
      awakeStill++;
      continue;
    }

    // Time ASLEEP is the still seconds inside the episode; the bridged arousal
    // is time in bed but not time asleep. This distinction is the whole point:
    // the sleep-need credit must be TST, and crediting TIB systematically
    // over-credits and under-recommends sleep.
    var tst = 0;
    for (var k = start; k < end; k++) {
      if (stillAt(k)) tst++;
    }

    // Confidence, NOT efficiency. A 20% dip below the awake baseline earns
    // full marks on that axis; the rest rewards evidence, not sleep quality.
    // Capped at 0.85 — this is a wrist estimate and never becomes a fact.
    final dipScore = clamp((baseline - medHr) / (baseline * 0.20), 0, 1);
    final stillScore = tib <= 0 ? 0.0 : tst / tib;
    // Wear corroboration for THIS bout, not for the day. A day-global
    // `wristOff.isNotEmpty` flag rewarded every nap on a day the band happened
    // to come off at some unrelated hour, and gave nothing to a clean nap on a
    // day it never came off — backwards on both counts. This scores how much of
    // THIS bout is contradicted by an off-body span: none → full marks.
    final worstOff = offFrac > exFrac ? offFrac : exFrac;
    final corroborated = clamp(1 - worstOff / maxNapOffWristFraction, 0, 1);
    final conf = clamp(
      0.20 +
          0.30 * dipScore +
          0.25 * coverage +
          0.15 * stillScore +
          0.10 * corroborated,
      0.2,
      0.85,
    );

    naps.add(NapWindow(
      startSec: aStart - baseSec,
      endSec: aEnd - baseSec,
      tibSec: tib,
      tstSec: tst,
      confidence: conf,
    ));
  }

  final skipped = <String>[
    if (deferred > 0) '$deferred deferred (record ends mid-bout)',
    if (outOfRange > 0) '$outOfRange outside 15 min–6 h',
    if (inMainSleep > 0) '$inMainSleep inside the main sleep window',
    if (unverifiable > 0) '$unverifiable unverifiable (HR coverage <50%)',
    if (offWrist > 0) '$offWrist off-wrist/excluded',
    if (awakeStill > 0) '$awakeStill still but no HR dip',
  ];
  final tail = skipped.isEmpty ? '' : '; skipped: ${skipped.join(', ')}';

  return Metric<List<NapWindow>>(
    value: naps,
    confidence: naps.isEmpty
        ? 0.3
        : naps.map((x) => x.confidence).reduce((a, b) => a + b) / naps.length,
    tier: Tier.estimate,
    inputs_used: inputs,
    note: naps.isEmpty
        ? 'no qualifying nap (15 min–6 h, HR-corroborated) outside the main '
            'sleep window$tail'
        : '${naps.length} nap(s) via van Hees z-angle immobility + an HR dip '
            'vs the awake daytime baseline; wrist ESTIMATE, not PSG, and no '
            'sleep-stage claim$tail',
  );
}

/// Fraction of [start, end) covered by ANY of [spans] (absolute seconds).
///
/// The union, not the sum. Adding each span's clipped length independently
/// double-counts a second that two spans both cover, which can push the result
/// past 1.0 and reject a bout that is only half contradicted. The band's own
/// toggle events do not currently produce overlapping spans, so this is a
/// contract guarantee for every caller rather than a fix for a live symptom —
/// but the doc above has always promised a union and the arithmetic did not.
double _overlapFraction(int start, int end, List<List<int>> spans) {
  final dur = end - start;
  if (dur <= 0 || spans.isEmpty) return 0;
  final clipped = <List<int>>[];
  for (final s in spans) {
    if (s.length < 2) continue;
    final lo = s[0] > start ? s[0] : start;
    final hi = s[1] < end ? s[1] : end;
    if (hi > lo) clipped.add([lo, hi]);
  }
  if (clipped.isEmpty) return 0;
  clipped.sort((a, b) => a[0].compareTo(b[0]));
  var covered = 0;
  var runLo = clipped.first[0], runHi = clipped.first[1];
  for (var i = 1; i < clipped.length; i++) {
    final s = clipped[i];
    if (s[0] <= runHi) {
      // Overlapping or adjacent — extend the open run instead of counting twice.
      if (s[1] > runHi) runHi = s[1];
    } else {
      covered += runHi - runLo;
      runLo = s[0];
      runHi = s[1];
    }
  }
  covered += runHi - runLo;
  return covered / dur;
}
