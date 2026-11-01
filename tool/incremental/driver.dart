// Test/bench driver: RR stream -> RrCorrector -> per-fold callback with the
// SETTLED NN delta and the PROVISIONAL tail, so downstream states can be
// folded exactly the way the app would (settled in, tail evaluated on a copy).
import 'oracle_util.dart';
import 'rr_stream.dart';
import 'synth.dart';

class FoldStep {
  final int fold;
  final int n; // raw beats folded so far
  final RrSettled settled; // newly settled NN
  final RrSnapshot snap; // provisional tail + totals
  FoldStep(this.fold, this.n, this.settled, this.snap);
  double get artifactFraction =>
      (1.0 - snap.cleanFraction).clamp(0.0, 1.0).toDouble();
}

void driveRr(RrData s, List<int> cuts, void Function(FoldStep) onFold,
    {bool restart = false, int restartEvery = 1}) {
  var c = RrCorrector();
  var from = 0;
  for (var k = 0; k < cuts.length; k++) {
    final to = cuts[k];
    final st = c.fold(s.rr.sublist(from, to), tsMs: s.ts.sublist(from, to));
    final snap = c.snapshot();
    onFold(FoldStep(k, to, st, snap));
    if (restart && k % restartEvery == 0) {
      c = RrCorrector.fromJson(jsonRoundTrip(c.toJson()));
    }
    from = to;
  }
}
