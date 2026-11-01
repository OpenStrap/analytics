// Performance guard for `correctRr`.
//
// Today every beat sorts five 91-element windows, so one call over a 23 h day
// (~96k beats) takes ~18 s on a loaded desktop and the app pays it on every
// derive pass. Sliding sorted windows give the same output in ~0.56 s (see
// test/onehz/rr_correction_oracle_test.dart for the bit-identical guard).
//
// The budgets are ~5x the rewrite's measured time, so a loaded CI host does not
// flake, and far below today's implementation, so this FAILS until the rewrite
// lands. Timing is wall clock around ONE call, JIT warm-up included.
import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

import 'support/rr_synth.dart';

const _dayBudget = Duration(seconds: 3); // rewrite: 0.56 s; today: ~18 s
const _nightBudget = Duration(seconds: 1); // rewrite: 0.19 s; today: ~7 s

void main() {
  test('23 h day (~96k beats) corrects within ${_dayBudget.inSeconds} s', () {
    // 5 h synthetic + the real 8.9 h night + 9 h synthetic = 96,712 beats.
    final s = realShapedDay();
    expect(s.length, inInclusiveRange(90000, 100000));
    final sw = Stopwatch()..start();
    final out = correctRr(s.rr, rrTsMs: s.ts);
    sw.stop();
    // ignore: avoid_print
    print('correctRr: ${s.length} beats in ${sw.elapsedMilliseconds} ms');
    // Not a stub result: the call really processed the series.
    expect(out.classes.length, s.length);
    expect(sw.elapsed, lessThan(_dayBudget),
        reason: '${sw.elapsedMilliseconds} ms for ${s.length} beats');
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('real 8.9 h night (~32k beats) corrects within '
      '${_nightBudget.inSeconds} s', () {
    final s = realNightRr();
    expect(s, isNotNull, reason: 'real night fixture missing');
    final sw = Stopwatch()..start();
    final out = correctRr(s!.rr, rrTsMs: s.ts);
    sw.stop();
    // ignore: avoid_print
    print('correctRr: ${s.length} beats in ${sw.elapsedMilliseconds} ms');
    expect(out.classes.length, s.length);
    expect(sw.elapsed, lessThan(_nightBudget),
        reason: '${sw.elapsedMilliseconds} ms for ${s.length} beats');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
