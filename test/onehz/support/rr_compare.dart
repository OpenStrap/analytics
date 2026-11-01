// Bit-for-bit comparison helpers for the RR correction oracle tests.
import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

/// `compareTo` is 0 only for the same double bit pattern in every case that
/// matters here (it tells -0.0 from 0.0 and treats NaN as equal to NaN), which
/// `==` does not.
bool sameBits(double a, double b) => a.compareTo(b) == 0;

/// Fails with the FIRST differing index instead of dumping two 96k-element
/// lists.
void expectBitIdentical(List<double> got, List<double> want, String why) {
  if (got.length != want.length) {
    fail('$why: length ${got.length} != ${want.length}');
  }
  for (var i = 0; i < got.length; i++) {
    if (!sameBits(got[i], want[i])) {
      fail('$why: index $i got ${got[i]} want ${want[i]}');
    }
  }
}

void expectSameClasses(List<BeatClass> got, List<BeatClass> want, String why) {
  if (got.length != want.length) {
    fail('$why: classes length ${got.length} != ${want.length}');
  }
  for (var i = 0; i < got.length; i++) {
    if (got[i] != want[i]) {
      fail('$why: class[$i] got ${got[i]} want ${want[i]}');
    }
  }
}

/// Everything a [RrCorrectionResult] carries.
void expectSameCorrection(
    RrCorrectionResult got, RrCorrectionResult want, String why) {
  expectBitIdentical(got.nn, want.nn, '$why nn');
  expectBitIdentical(got.nnTimesMs, want.nnTimesMs, '$why nnTimesMs');
  expectSameClasses(got.classes, want.classes, why);
  expect(sameBits(got.cleanFraction, want.cleanFraction), isTrue,
      reason: '$why cleanFraction ${got.cleanFraction} vs ${want.cleanFraction}');
  expect(got.droppedCount, want.droppedCount, reason: '$why droppedCount');
  expect(got.correctedCount, want.correctedCount, reason: '$why correctedCount');
}
