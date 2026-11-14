// EpochRows: the gravity reference of a run that another run follows is read up
// to the batch staging boundary (whole epochs), not to the run's carry tail.
import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

import 'support/causal_night.dart' show kT0Ms;

void main() {
  // Run 1: seconds 0..999 (coverage runs 60 s past the last sample, to 1060).
  // Run 2 starts at 1100. Batch staging cuts run 1 to whole epochs (1050), so
  // the reference of the epoch at 900 s is the median over [750, 1050): 150 ones
  // and 150 twos, 1.5, and its motion is 2 - 1.5 = 0.5. Reading to 1060 gave
  // 150 ones and 160 twos: reference 2, motion 0.
  // # catches: the sub-epoch carry tail of a non-last run entering the
  // reference window.
  for (final cached in [false, true]) {
    test('a non-last run is cut to whole epochs for the reference '
        '(${cached ? 'with' : 'without'} a row cache)', () {
      final hr = <HrSample>[];
      final accel = <AccelSample>[];
      void second(int s, double mag) {
        final ts = kT0Ms + s * 1000.0;
        hr.add(HrSample(ts, 60));
        accel.add(AccelSample(ts, 0, 0, mag));
      }

      for (var s = 0; s < 1000; s++) {
        second(s, s < 900 ? 1.0 : 2.0);
      }
      for (var s = 1100; s < 1500; s++) {
        second(s, 1.0);
      }
      final er = EpochRows(
          rowCache: cached ? CardioRowCache() : null, anchorMs: kT0Ms.toInt());
      er.fold(hr: hr, accel: accel, rrMs: const [], rrTsMs: const []);
      final rows = er.allRows();
      final row = rows.firstWhere((r) => r.startMs == kT0Ms + 900000.0);
      expect(row.motion, closeTo(0.5, 1e-9));
    });
  }
}
