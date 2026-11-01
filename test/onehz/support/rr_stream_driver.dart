// Driver + oracle comparison for the streaming RrCorrector tests.
import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

import 'correct_rr_reference.dart';
import 'rr_chunking.dart';
import 'rr_compare.dart';

export 'rr_chunking.dart';

/// Accumulates everything a corrector has SETTLED, the way the app will hold it
/// between derive passes, and can save/restore the corrector at any boundary.
class RrStreamRun {
  RrCorrector c;
  final nn = <double>[];
  final nnTimes = <double>[];
  final classes = <BeatClass>[];
  int folded = 0;
  int restarts = 0;

  RrStreamRun([RrCorrector? corrector]) : c = corrector ?? RrCorrector();

  RrStreamRun.params(
      {double alpha = 5.2,
      int win = 91,
      double floor = 100,
      double reanchor = 1000})
      : c = RrCorrector(
            alpha: alpha,
            windowBeats: win,
            minThresholdMs: floor,
            reanchorGapMs: reanchor);

  RrSettled fold(List<double> rr, List<double>? ts) {
    final s = c.fold(rr, tsMs: ts);
    nn.addAll(s.nn);
    nnTimes.addAll(s.nnTimes);
    classes.addAll(s.classes);
    folded += rr.length;
    return s;
  }

  /// Save to text and restore into a NEW corrector.
  void restart() {
    c = RrCorrector.fromJson(jsonRoundTrip(c.toJson()));
    restarts++;
  }

  /// `settled ++ tail` over the first [n] beats equals the frozen `correctRr`
  /// on exactly those beats: nn, times, per-beat classes, counts, cleanFraction.
  void expectMatchesOracle(List<double> rr, List<double>? ts, int n,
      {double alpha = 5.2,
      int win = 91,
      double floor = 100,
      double reanchor = 1000,
      String why = ''}) {
    expect(folded, n, reason: 'driver folded $why');
    final want = correctRrReference(rr.sublist(0, n),
        rrTsMs: ts?.sublist(0, n),
        alpha: alpha,
        windowBeats: win,
        minThresholdMs: floor,
        reanchorGapMs: reanchor);
    final snap = c.snapshot();
    expect(snap.n, n, reason: 'snapshot.n $why');
    expect(snap.classifiedBeats, classes.length,
        reason: 'classifiedBeats == classes handed out $why');
    expect(snap.settledBeats, c.settledBeats, reason: 'settledBeats $why');
    expect(snap.settledBeats, lessThanOrEqualTo(snap.classifiedBeats),
        reason: 'output cannot settle before its class $why');
    expect(snap.tailClasses.length, n - snap.classifiedBeats,
        reason: 'tailClasses covers [classifiedBeats, n) $why');
    expectBitIdentical([...nn, ...snap.tailNn], want.nn, '$why nn');
    expectBitIdentical(
        [...nnTimes, ...snap.tailNnTimes], want.nnTimesMs, '$why nnTimes');
    expectSameClasses(
        [...classes, ...snap.tailClasses], want.classes, '$why classes');
    expect(snap.normalCount,
        want.classes.where((k) => k == BeatClass.normal).length,
        reason: 'normalCount $why');
    expect(snap.droppedCount, want.droppedCount, reason: 'dropped $why');
    expect(snap.correctedCount, want.correctedCount, reason: 'corrected $why');
    expect(sameBits(snap.cleanFraction, want.cleanFraction), isTrue,
        reason: 'cleanFraction ${snap.cleanFraction} vs ${want.cleanFraction} '
            '$why');
  }

  /// Settled output is FINAL: it is a prefix of what the oracle says about the
  /// WHOLE series, not just about the prefix seen so far. [full] is the oracle
  /// run once over everything.
  void expectSettledIsPrefixOf(RrCorrectionResult full, String why) {
    expect(nn.length, lessThanOrEqualTo(full.nn.length), reason: '$why nn len');
    expectBitIdentical(nn, full.nn.sublist(0, nn.length), '$why settled nn');
    expectBitIdentical(
        nnTimes, full.nnTimesMs.sublist(0, nnTimes.length), '$why settled t');
    expect(classes.length, lessThanOrEqualTo(full.classes.length));
    expectSameClasses(
        classes, full.classes.sublist(0, classes.length), '$why settled cls');
  }
}
