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
//   1. van Hees z-angle immobility (`immobilityMask`). An angle is
//      orientation-invariant, so it does not inherit the ~13% spread in |accel|
//      across static wrist postures that makes magnitude-based stillness
//      false-positive on a merely resting arm.
//      NOT the nocturnal spine's stillness test — this used to claim it was.
//      `AdvancedSleepStager` uses `_gravityDeltas`, the norm of the DIFFERENCE
//      between successive gravity vectors. Both are orientation-CHANGE
//      detectors and neither is the |accel| magnitude test van_hees.dart argues
//      against, but they are different features over different windows and the
//      two detectors have never been shown to agree on real nights.
//   2. Enumerate EVERY immobility bout (the nocturnal path keeps only the
//      longest), bridging brief arousals.
//   3. Reject hard: off-wrist, charging/workout spans, the main sleep window,
//      and bouts built on seconds the band never measured (`minNapAccelCoverage`).
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

/// A bout needs a DECODED gravity vector on at least this fraction of its
/// wall-clock seconds. Mirrors `kMinAccelCoverageForVanHees` in the edge, which
/// guards the nocturnal path the same way — but the gate belongs HERE so no
/// caller can forget it.
///
/// It is a CONTRACT, not a live fix: `stillAt` already refuses an unmeasured
/// second, and a bout can only absorb unmeasured time through a bridge, which
/// is capped at [napBridgeSec] between runs of at least the sustained window —
/// so today's arithmetic cannot get coverage below ~50% anyway. Encoded here so
/// a future change to either bound cannot silently reopen the hole.
const double minNapAccelCoverage = 0.5;

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
  //
  // It breaks at an UNMEASURED second too, and that falls out of the primitive:
  // `deltaDeg` is NaN wherever gravity was not decoded (see [immobilityMask]),
  // and `NaN < thr` is false. A second the band never measured therefore fails
  // the still test outright instead of contributing the constant 0.0° of an
  // exact (0,0,0) sample — which is what emitted a 50-minute decode gap as a
  // nap at the 0.85 confidence cap.
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

  // The AWAKE HR baseline pool: every second that is not the main sleep and not
  // a bout we have already DEFERRED as unfinished.
  //
  // SEDENTARY WAKE STAYS IN THIS POOL, and that is the whole point. Excluding
  // every detected bout — which is what "neither the main sleep nor ANY bout"
  // did — removes all of the day's still time, so what survives is the
  // AMBULATORY HR median, not an awake baseline. The gate `medHr > baseline *
  // napRestingHrMult` is then cleared by any motionless awake stretch whose HR
  // sits more than 5% below walking HR: desk work, reading, driving, a sofa.
  // Measured, not argued: a synthetic day of 8 x (6 min walking @ 96 bpm, 25
  // min motionless @ 72 bpm) reported EIGHT naps totalling 199 minutes, each at
  // confidence 0.85 — the cap — where nobody had napped. A 10% contrast (76 vs
  // 84 bpm) did the same. Keeping the still seconds puts the median at 72, and
  // 0.95 x 72 = 68.4 < 72 rejects all eight. The exclusion WAS the bug.
  //
  // Two exclusions are still right, and they are the two the original change
  // was actually reaching for:
  //   * the CANDIDATE's own low-HR seconds, or the gate grades a bout against a
  //     median it is itself dragging down — self-suppressing, and the quieter
  //     the sleep the lower the bar it has to beat. That is per-candidate, so
  //     it is done inside the loop below, not here.
  //   * any UNFINISHED bout. The nap window deliberately runs hours past
  //     midnight, so the first hours of tonight's sleep sit in this record;
  //     they are sleep, not sedentary wake, and they belong in no baseline.
  final deferredSec = List<bool>.filled(n, false);
  for (var b = 0; b < bouts.length; b++) {
    if (!unfinished[b]) continue;
    for (var k = bouts[b][0]; k < bouts[b][1]; k++) {
      deferredSec[k] = true;
    }
  }
  // Indices, not values: each candidate has to subtract ITSELF from this pool.
  final awakeIdx = <int>[];
  for (var k = 0; k < n; k++) {
    if (hr[k] <= 0 || deferredSec[k]) continue;
    if (mainSleep != null && k >= mainSleep.start && k < mainSleep.end)
      continue;
    awakeIdx.add(k);
  }
  if (awakeIdx.length < minAwakeHrSamples) {
    return Metric<List<NapWindow>>.absent(
      tier: Tier.estimate,
      inputs_used: inputs,
      note: 'not enough awake daytime HR to set a baseline '
          '(${awakeIdx.length}s, need ${minAwakeHrSamples}s) — '
          'cannot corroborate stillness as sleep',
    );
  }

  final naps = <NapWindow>[];
  var deferred = 0, unverifiable = 0, offWrist = 0, awakeStill = 0;
  // Every rejection path increments one of these and reports it in `skipped`.
  // A silent `continue` turns "your 7-hour still block is too long to be a nap"
  // into a bare "no qualifying nap", which tells the caller nothing about why.
  var outOfRange = 0, inMainSleep = 0, noBaseline = 0, unobserved = 0;

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

    if (mainSleep != null && start < mainSleep.end && end > mainSleep.start) {
      inMainSleep++;
      continue;
    }

    // Wall-clock accel coverage — the seconds inside the bout the band actually
    // measured gravity for, over the bout's elapsed span (so a recording hole
    // counts against it exactly as an invalid sample does).
    var accelSec = 0;
    for (var k = start; k < end; k++) {
      if (series[k].valid) accelSec++;
    }
    if (accelSec / tib < minNapAccelCoverage) {
      unobserved++;
      continue;
    }

    final offFrac = _overlapFraction(aStart, aEnd, wristOff);
    final exFrac = _overlapFraction(aStart, aEnd, exclude);
    if (offFrac >= maxNapOffWristFraction || exFrac >= maxNapOffWristFraction) {
      offWrist++;
      continue;
    }

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

    // PER-CANDIDATE baseline: the day's awake pool minus THIS bout. A bout must
    // not be graded against a median it is itself pulling down — see the pool
    // construction above for why only the candidate and the deferred bouts come
    // out, and not every still block in the day.
    final awakeHr = <double>[];
    for (final k in awakeIdx) {
      if (k >= start && k < end) continue;
      awakeHr.add(hr[k]);
    }
    if (awakeHr.length < minAwakeHrSamples) {
      // The day had enough awake HR, but not once this candidate is removed —
      // so THIS bout cannot be corroborated, while others still may be. Abstain
      // for it rather than judging it against a median built from a handful of
      // seconds. Counted separately from `unverifiable` because it is the one
      // rejection that makes the DAY's verdict incomplete: see the check after
      // the loop.
      noBaseline++;
      continue;
    }
    final baseline = median(awakeHr)!;
    if (baseline <= 0) {
      noBaseline++;
      continue;
    }

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

  // A still block we could not RULE OUT is not the same as a day with no nap.
  // If nothing was emitted and at least one candidate went unjudged for want of
  // an awake baseline, the day's verdict is unknown — say so, rather than
  // returning an empty list that every caller reads as "judged, none". This is
  // the day-level abstain that used to fall out of the whole-day baseline check
  // before it became per-candidate.
  if (naps.isEmpty && noBaseline > 0) {
    return Metric<List<NapWindow>>.absent(
      tier: Tier.estimate,
      inputs_used: inputs,
      note: 'not enough awake daytime HR to set a baseline for '
          '$noBaseline still block(s) (need ${minAwakeHrSamples}s outside the '
          'block itself) — cannot corroborate stillness as sleep',
    );
  }

  final skipped = <String>[
    if (deferred > 0) '$deferred deferred (record ends mid-bout)',
    if (noBaseline > 0) '$noBaseline without an awake HR baseline',
    if (outOfRange > 0) '$outOfRange outside 15 min–6 h',
    if (inMainSleep > 0) '$inMainSleep inside the main sleep window',
    if (unobserved > 0) '$unobserved with accel coverage <50% (unmeasured)',
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
