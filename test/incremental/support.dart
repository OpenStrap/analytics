import 'package:openstrap_analytics/onehz.dart'
    hide RrCorrector, RrSettled, RrSnapshot, IrregularScreenState;
import 'package:test/test.dart';

/// Max-error recorder for approximate fields.
class Err {
  double maxAbs = 0, maxRel = 0;
  int n = 0;
  void add(double? a, double? b) {
    if (a == null || b == null) {
      expect(a, b);
      return;
    }
    n++;
    final d = (a - b).abs();
    if (d > maxAbs) maxAbs = d;
    final rel = b == 0 ? d : d / b.abs();
    if (rel > maxRel) maxRel = rel;
  }

  @override
  String toString() => 'n=$n maxAbs=${maxAbs.toStringAsExponential(2)} maxRel=${maxRel.toStringAsExponential(2)}';
}

void sameEnvelope<T>(Metric<T> a, Metric<T> b, {String? why, bool exactConf = true}) {
  expect(a.present, b.present, reason: 'present $why');
  expect(a.tier, b.tier, reason: 'tier $why');
  expect(a.inputs_used, b.inputs_used, reason: 'inputs $why');
  expect(a.note, b.note, reason: 'note $why');
  if (exactConf) expect(a.confidence, b.confidence, reason: 'conf $why');
}
