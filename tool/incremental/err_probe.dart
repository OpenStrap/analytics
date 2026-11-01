// Max abs/rel error of the Welford-based fields (irregular SD1/SD2, hrvTime SDNN)
// over many random prefixes. dart run tool/incremental/err_probe.dart
import 'dart:math' as math;
import 'package:openstrap_analytics/onehz.dart'
    hide RrCorrector, RrSettled, RrSnapshot, IrregularScreenState;
import 'hrv_incr.dart';
import 'synth.dart';

void main() {
  final s = realNightRr()!;
  final o = correctRr(s.rr, rrTsMs: s.ts);
  var maxRelSdnn = 0.0, maxRelSd1 = 0.0, maxRelSd2 = 0.0, maxAcf = 0.0;
  var checks = 0;
  final r = math.Random(1);
  final acc = HrvTimeAcc();
  final irr = IrregularScreenState();
  var at = 0;
  while (at < o.nn.length) {
    final to = math.min(o.nn.length, at + 1 + r.nextInt(2500));
    acc.fold(o.nn.sublist(at, to), o.nnTimesMs.sublist(at, to));
    irr.fold(o.nn.sublist(at, to), o.nnTimesMs.sublist(at, to));
    at = to;
    if (to < 600) continue;
    final nn = o.nn.sublist(0, to), t = o.nnTimesMs.sublist(0, to);
    final w = hrvTime(nn, nnTimesMs: t);
    final g = acc.evaluate(const [], const []);
    maxRelSdnn = math.max(maxRelSdnn, (g.value!.sdnn! - w.value!.sdnn!).abs() / w.value!.sdnn!);
    maxAcf = math.max(maxAcf, (g.value!.diffAcf1! - w.value!.diffAcf1!).abs());
    final wi = irregularBeatScreen(nn, nnTimesMs: t);
    final gi = irr.evaluate(const [], const []);
    if (wi.present) {
      maxRelSd1 = math.max(maxRelSd1, (gi.value!.sd1 - wi.value!.sd1).abs() / wi.value!.sd1);
      maxRelSd2 = math.max(maxRelSd2, (gi.value!.sd2 - wi.value!.sd2).abs() / wi.value!.sd2);
    }
    checks++;
  }
  print('checks=$checks  hrvTime sdnn maxRel=$maxRelSdnn  acf1 maxAbs=$maxAcf  '
      'irregular sd1 maxRel=$maxRelSd1 sd2 maxRel=$maxRelSd2');
}
