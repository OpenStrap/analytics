// Long-run drift: thousands of incremental updates, compared with the batch
// oracle along the way. The shorter parity tests cannot show error that only
// builds up over a full night of appends or a long sliding window.
import 'dart:io';
import 'dart:math' as math;

import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';
import '../support/incremental_compare.dart';

double _rel(double? a, double? e) {
  if (a == null || e == null) return a == e ? 0 : double.infinity;
  final scale = e.abs();
  return scale < 1e-12 ? (a - e).abs() : (a - e).abs() / scale;
}

/// Logs the worst relative error seen, so the margin under the bound is
/// visible in the test output and not only pass/fail.
void _report(String label, double worst) =>
    stdout.writeln('[drift] $label worst relative error ${worst.toStringAsExponential(2)}');

/// A night of beats on absolute epoch seconds, the magnitude production
/// timestamps carry, with a slow drift and respiratory modulation.
({List<double> t, List<double> y}) _night(int beats, {int seed = 7}) {
  final rnd = math.Random(seed);
  final t = <double>[], y = <double>[];
  var clock = 1791028730.0;
  for (var i = 0; i < beats; i++) {
    final rr = 900 +
        120 * math.sin(i / 4000) +
        40 * math.sin(i * 2 * math.pi * .25 * .9) +
        rnd.nextDouble() * 30;
    clock += rr / 1000;
    if (i % 2311 == 2310) clock += 45; // an occasional dropout
    t.add(clock);
    y.add(rr);
  }
  return (t: t, y: y);
}

void main() {
  final frequencies = [for (var k = 0; k <= 40; k++) .0033 + k * .01];

  test('Lomb–Scargle over a full night of appends stays on the batch result',
      () {
    final night = _night(30000);
    var state = IncrementalLombScargle(frequencies);
    var worst = 0.0, worstAbsolute = 0.0;
    var n = 0;
    for (final checkpointAt in [500, 2000, 8000, 16000, 24000, 30000]) {
      while (n < checkpointAt) {
        n = math.min(checkpointAt, n + 13);
        state.sync(night.t.sublist(0, n), night.y.sublist(0, n));
      }
      final ts = night.t.sublist(0, n), ys = night.y.sublist(0, n);
      final actual = state.sync(ts, ys)!;
      // The oracle runs on times shifted by the first beat. The periodogram is
      // shift-invariant, and the shift is exact here (Sterbenz), but on raw
      // epoch seconds the batch's own trig arguments reach ~1e10 rad and lose
      // ~1e-6 relative; checked against an 80-bit reference, that batch error
      // is 4.6e-6 while shifted double precision is 3.8e-13.
      final shifted = [for (final x in ts) x - ts.first];
      final expected = lombScargle(shifted, ys, frequencies)!;
      final absolute = lombScargle(ts, ys, frequencies)!;
      for (var i = 0; i < expected.spectrum.length; i++) {
        final a = actual.spectrum[i].psd, e = expected.spectrum[i].psd;
        worst = math.max(worst, _rel(a, e));
        expect(_rel(a, e), lessThan(1e-9), reason: 'f=${frequencies[i]}');
        worstAbsolute =
            math.max(worstAbsolute, _rel(a, absolute.spectrum[i].psd));
        expect(_rel(a, absolute.spectrum[i].psd), lessThan(1e-5));
      }
      // A restored checkpoint must continue the same way.
      state = IncrementalLombScargle.fromJson(checkpoint(state.toJson()));
    }
    _report('lomb 30000 beats vs shifted batch', worst);
    _report('lomb 30000 beats vs epoch-time batch', worstAbsolute);
  });

  test('moments over a long sliding window with removals stay on two-pass',
      () {
    // Large offset, small spread: the case where naive sum-of-squares loses
    // every digit. 100 000 adds and 99 700 removals through a 300-value window.
    final rnd = math.Random(11);
    final window = <double>[];
    final state = RunningMoments();
    var worstMean = 0.0, worstSd = 0.0;
    for (var i = 0; i < 100000; i++) {
      final x = 1e6 + 50 * math.sin(i / 97) + rnd.nextDouble();
      window.add(x);
      state.add(x);
      if (window.length > 300) state.remove(window.removeAt(0));
      if (i % 997 == 0 || i == 99999) {
        worstMean = math.max(worstMean, _rel(state.mean, mean(window)));
        worstSd = math.max(worstSd, _rel(state.sampleSd, stddev(window)));
      }
    }
    _report('moments window mean', worstMean);
    _report('moments window sd', worstSd);
    expect(worstMean, lessThan(1e-9));
    expect(worstSd, lessThan(1e-9));
  });

  test('moments removed down to two values from a large set', () {
    final rnd = math.Random(3);
    final values = [
      for (var i = 0; i < 50000; i++) 800 + 100 * rnd.nextDouble()
    ];
    final state = RunningMoments();
    for (final x in values) {
      state.add(x);
    }
    var worstSd = 0.0;
    while (values.length > 2) {
      state.remove(values.removeLast());
      if (values.length % 1000 == 0 || values.length < 10) {
        worstSd = math.max(worstSd, _rel(state.sampleSd, stddev(values)));
      }
    }
    _report('moments shrink sd', worstSd);
    expect(worstSd, lessThan(1e-9));
  });
}
