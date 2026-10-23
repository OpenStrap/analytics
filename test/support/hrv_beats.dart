// Shared HRV test helpers: Beats builders, beat-series generators and the
// hrvTime parity check.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:openstrap_analytics/aggregate.dart';
import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

import 'property.dart' show Rng;

typedef Beat = ({double nnMs, double? timeMs});

const double hrvT0 = 1000000.0;
const double hrvTol = 1e-9;

List<Object?> hrvFields(HrvTime v) =>
    [v.rmssd, v.sdnn, v.sdann, v.sdnnIndex, v.pnn50, v.diffAcf1];

final hrvEqAll = fieldsEqual<HrvTime>((v) => [...hrvFields(v), v.nBeats],
    relTol: hrvTol, absTol: hrvTol);

/// Beats from records. A null time becomes NaN (missing double).
Beats hrvBeats(List<Beat> xs) => Beats(
      Float64List.fromList([for (final b in xs) b.nnMs]),
      Float64List.fromList([for (final b in xs) b.timeMs ?? double.nan]),
    );

/// The beat time of the first row, or null for an empty batch. This is the
/// origin the tests give the aggregator.
double? hrvOrigin(Beats b) => b.length == 0 ? null : b.timeMs[0];

/// [b] with every time moved so the first beat sits at [origin].
Beats hrvShifted(Beats b, double origin) {
  if (b.length == 0) return b;
  final d = origin - b.timeMs[0];
  return Beats(Float64List.fromList(b.nnMs),
      Float64List.fromList([for (final t in b.timeMs) t + d]));
}

/// What hrvTime says, mapped to the aggregator's expectation.
HrvTime hrvExpected(Beats beats, {required bool gapAware}) {
  final nn = beats.nnMs.toList();
  final times = [for (final t in beats.timeMs) t.isNaN ? 0.0 : t];
  final m = hrvTime(nn, nnTimesMs: gapAware ? times : null);
  return m.value ?? HrvTime(nBeats: beats.length);
}

void expectHrvParity(HrvTime got, HrvTime want, String tag) {
  expect(got.nBeats, want.nBeats, reason: '$tag: nBeats');
  for (final (name, a, b) in [
    ('rmssd', got.rmssd, want.rmssd),
    ('sdnn', got.sdnn, want.sdnn),
    ('sdann', got.sdann, want.sdann),
    ('sdnnIndex', got.sdnnIndex, want.sdnnIndex),
    ('pnn50', got.pnn50, want.pnn50),
    ('diffAcf1', got.diffAcf1, want.diffAcf1),
  ]) {
    expect(a == null, b == null, reason: '$tag: $name null-ness ($a vs $b)');
    if (a != null && b != null) {
      expect((a - b).abs() <= hrvTol + hrvTol * b.abs(), isTrue,
          reason: '$tag: $name $a vs $b');
    }
  }
}

/// Builds a beat series with times. Values are multiples of 0.5 so the gap
/// rule's float arithmetic is exact in both implementations.
///  mode 0: smooth (random walk), mode 1: white noise (jittery, so the
///  RMSSD/pNN50 floor nulls them), mode 2: slow beats (spans several 5-minute
///  bins in few beats).
///  Below the jitter floor, where hrvTime reads the difference runs:
///  mode 3: RSA at a slow heart, ~44 bpm breathing at 0.3 Hz with a drifting
///  heart rate (ACF1 ~ -0.8, but a respiratory line on a low floor exempts
///  it once the runs hold 20 Welch segments); mode 4: a heart rate drifting
///  from ~67 to ~46 bpm under heavy beat-time jitter with a weak breathing
///  line at 0.25 Hz (refused, then published from the 5-min windows on the
///  line steady in Hz once there are 12 of them, ~1 h).
/// [gapP] is the chance a beat is preceded by a hole; [withTimes] false leaves
/// every time NaN.
Beats hrvSeries(Rng r, int n, int mode,
    {double gapP = .05, bool withTimes = true}) {
  final out = <Beat>[];
  var t = hrvT0;
  var nn = mode == 2 ? 1700.0 : 800.0;
  for (var i = 0; i < n; i++) {
    final s = (t - hrvT0) / 1000;
    switch (mode) {
      case 3:
        nn = (2 *
                    (1350 +
                        80 * math.sin(2 * math.pi * s / 3600) +
                        40 * math.sin(2 * math.pi * .3 * s) +
                        3 * (r.nextDouble() - .5)))
                .roundToDouble() /
            2;
      case 4:
        nn = (2 *
                    (900 +
                        400 * s / 9000 +
                        10 * math.sin(2 * math.pi * .25 * s) +
                        40 * (r.nextDouble() - .5)))
                .roundToDouble() /
            2;
      case 1:
        nn = 600 + r.intIn(0, 800) / 1.0;
      case 2:
        nn = (nn + r.intIn(-60, 60)).clamp(1200, 2000).toDouble();
      default:
        nn = (nn + r.intIn(-40, 40)).clamp(450, 1300).toDouble();
    }
    if (mode < 3 && r.nextBool(.04)) nn += r.intIn(40, 200); // an occasional big step
    var extra = 0.0;
    if (i > 0) {
      final p = r.nextDouble();
      if (p < gapP) {
        // a hole; sometimes a whole 5-minute bin or more
        extra = r.nextBool(.15)
            ? r.intIn(300000, 700000).toDouble()
            : r.intIn(600, 30000).toDouble();
      } else if (mode < 3 && p < gapP + .04) {
        extra = [0.5, 1.0, 0.0][r.nextInt(3)]; // right at the 0.5 ms tolerance
      }
    }
    t += nn + extra;
    out.add((nnMs: nn, timeMs: withTimes ? t : null));
  }
  return hrvBeats(out);
}

/// Contiguous series with exact constant nn (acf1 undefined: zero variance).
Beats hrvConstant(int n, double nn) =>
    hrvBeats([for (var i = 1; i <= n; i++) (nnMs: nn, timeMs: hrvT0 + i * nn)]);
