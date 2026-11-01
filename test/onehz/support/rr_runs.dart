// Test support: clean RR series with long artifact runs, for the cap tests.
// Integer RR, timestamps = exact running sums (every clock value is an integer,
// so comparisons can be bit-exact). Seeded (property.dart's Rng).
import 'dart:math' as math;

import '../../support/property.dart' show Rng;

const rrRunsT0 = 1.7e12;

class RunSeries {
  final List<double> rr, ts;
  RunSeries(this.rr, this.ts);
}

/// Clean integer RR (RSA-like wobble), timestamps the exact running sum.
List<double> cleanRr(Rng r, int n) => [
      for (var i = 0; i < n; i++)
        (850 + 40 * math.sin(i * 0.7) + 25 * math.sin(i * 0.13) + r.intIn(-15, 15))
            .roundToDouble()
    ];

RunSeries rrSeries(List<double> rr) {
  var t = rrRunsT0;
  return RunSeries(rr, [for (final v in rr) t += v]);
}

/// Segments of [segLens] clean beats separated by runs of 3000 ms beats
/// ([runLens]); returns the series and each run's [start, end). With [nearRun],
/// one short (extra-like) beat sits 20 beats before and 20 after every run.
(RunSeries, List<(int, int)>) withRuns(int seed, List<int> segLens, List<int> runLens,
    {bool nearRun = false}) {
  final r = Rng(seed);
  final rr = <double>[];
  final runs = <(int, int)>[];
  for (var k = 0; k < segLens.length; k++) {
    final seg = cleanRr(r, segLens[k]);
    if (nearRun) {
      if (k > 0) seg[20] = (seg[20] * 0.55).roundToDouble();
      if (k < runLens.length) seg[seg.length - 20] = (seg[seg.length - 20] * 0.55).roundToDouble();
    }
    rr.addAll(seg);
    if (k < runLens.length) {
      final a = rr.length;
      // The last two values rise (2500, 3000), so the dRR spike on the normal
      // beat that follows has the opposite sign and the compensatory-pair rule
      // takes that beat back as normal: the run is exactly the junk beats.
      rr.addAll(List.filled(runLens[k], 3000.0));
      rr[rr.length - 2] = 2500.0;
      runs.add((a, rr.length));
    }
  }
  return (rrSeries(rr), runs);
}

