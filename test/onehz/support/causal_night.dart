// Deterministic synthetic 1 Hz nights for the causal-stager tests.
//
// Not a physiological simulator — just three separable regimes so the tests can
// check that the causal stager sees what is there:
//   nrem : low, steady HR; quiet RR; still wrist
//   rem  : slightly higher HR, jittery instantaneous HR, wide RR spread; still
//   wake : high HR; bursts of wrist motion
// RR beats carry the SAME second-quantised timestamps the device produces
// (`rr_ts_ms = rec_ts * 1000`, so several beats tie on one second).

import 'dart:math' as math;
import 'package:openstrap_analytics/onehz.dart';

/// 30-s-aligned absolute start (1_700_000_010_000 / 30_000 is an integer).
const double kT0Ms = 1700000010000;

class SynthNight {
  final double t0Ms;
  final List<HrSample> hr;
  final List<AccelSample> accel;
  final List<double> rrTsMs;
  final List<double> rrMs;

  /// Ground-truth regime per second ('nrem' | 'rem' | 'wake').
  final List<String> truth;
  const SynthNight(
      this.t0Ms, this.hr, this.accel, this.rrTsMs, this.rrMs, this.truth);
  int get seconds => truth.length;
}

class _Rng {
  int _s;
  _Rng(int seed) : _s = seed == 0 ? 0x9E3779B9 : seed;
  double next() {
    _s ^= (_s << 13) & 0xFFFFFFFF;
    _s ^= _s >> 17;
    _s ^= (_s << 5) & 0xFFFFFFFF;
    _s &= 0xFFFFFFFF;
    return _s / 4294967296.0;
  }

  double gauss() {
    var a = 0.0;
    for (var i = 0; i < 12; i++) {
      a += next();
    }
    return a - 6.0;
  }
}

SynthNight synthNight(List<(String, int)> segments,
    {int seed = 11, double t0Ms = kT0Ms}) {
  final rng = _Rng(seed);
  final hr = <HrSample>[];
  final accel = <AccelSample>[];
  final rrTs = <double>[];
  final rr = <double>[];
  final truth = <String>[];
  var beatClockMs = 0.0; // ms since t0, the next beat's time
  var sec = 0;
  for (final (kind, len) in segments) {
    for (var k = 0; k < len; k++, sec++) {
      final base = switch (kind) { 'rem' => 59.0, 'wake' => 80.0, _ => 54.0 };
      final hrSd = switch (kind) { 'rem' => 3.2, 'wake' => 2.0, _ => 0.9 };
      final rrSd = switch (kind) { 'rem' => 55.0, 'wake' => 25.0, _ => 14.0 };
      final bpm = (base + hrSd * rng.gauss()).roundToDouble();
      final ts = t0Ms + sec * 1000.0;
      hr.add(HrSample(ts, bpm));
      // posture drifts every 20 min (a static change, not motion)
      final posture = (sec ~/ 1200) % 3;
      final g = switch (posture) {
        0 => const [0.30, 0.80, 0.50],
        1 => const [0.70, 0.20, 0.68],
        _ => const [-0.20, 0.55, 0.81],
      };
      final gn = math.sqrt(g[0] * g[0] + g[1] * g[1] + g[2] * g[2]);
      var burst = 0.0;
      if (kind == 'wake' && rng.next() < 0.35) burst = 0.25 + 0.2 * rng.next();
      accel.add(AccelSample(
        ts,
        g[0] / gn + 0.0015 * rng.gauss() + burst,
        g[1] / gn + 0.0015 * rng.gauss(),
        g[2] / gn + 0.0015 * rng.gauss(),
      ));
      // beats whose start falls inside this second
      while (beatClockMs < (sec + 1) * 1000.0) {
        final inst = 60000.0 / math.max(35.0, bpm);
        final v = (inst + rrSd * rng.gauss()).clamp(380.0, 1900.0).toDouble();
        if (beatClockMs >= sec * 1000.0) {
          rrTs.add(ts);
          rr.add(v.roundToDouble());
        }
        beatClockMs += v;
      }
      truth.add(kind);
    }
  }
  return SynthNight(t0Ms, hr, accel, rrTs, rr, truth);
}

/// A window of the night: samples with `lo <= second < hi` (seconds since t0),
/// decision time `nowSec`. `hi` may exceed `nowSec` to carry FUTURE samples.
CausalSampleWindow windowOf(SynthNight n, int loSec, int hiSec,
    {int? nowSec, bool hrOn = true, bool accelOn = true, bool rrOn = true}) {
  final hiC = math.min(hiSec, n.seconds);
  final loC = math.max(0, loSec);
  final loMs = n.t0Ms + loC * 1000.0, hiMs = n.t0Ms + hiC * 1000.0;
  final rrIdx = <int>[
    for (var i = 0; i < n.rrTsMs.length; i++)
      if (n.rrTsMs[i] >= loMs && n.rrTsMs[i] < hiMs) i
  ];
  return CausalSampleWindow(
    nowMs: n.t0Ms + (nowSec ?? hiSec) * 1000.0,
    hr: hrOn ? n.hr.sublist(loC, hiC) : const [],
    accel: accelOn ? n.accel.sublist(loC, hiC) : const [],
    rr: rrOn
        ? RrSeries([for (final i in rrIdx) n.rrTsMs[i]],
            [for (final i in rrIdx) n.rrMs[i]])
        : RrSeries(const <double>[], const <double>[]),
  );
}

/// A reasonably realistic ~3 h night used by most tests.
List<(String, int)> standardNight() => [
      ('nrem', 35 * 60),
      ('rem', 12 * 60),
      ('nrem', 40 * 60),
      ('wake', 6 * 60),
      ('nrem', 30 * 60),
      ('rem', 15 * 60),
      ('nrem', 25 * 60),
    ];
