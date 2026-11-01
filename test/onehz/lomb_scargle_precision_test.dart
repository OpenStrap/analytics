// Batch Lomb–Scargle on absolute epoch seconds. Trig arguments `w * t` reach
// ~1e10 rad when `t` is ~1.8e9 s, where a double's spacing is ~1e-6 rad, so the
// periodogram used to carry ~1e-6 relative error that depends on the clock, not
// the data. `lombScargle` now measures time from the first sample.
import 'dart:math' as math;

import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

const _epoch = 1791028730.0;

/// A night of beats. Times are multiples of 1/1024 s, so adding [_epoch] (a
/// whole number of seconds) is EXACT in a double: the epoch series and the
/// rebased series have identical differences, bit for bit.
({List<double> t, List<double> y}) _beats(int n, {int seed = 5}) {
  final rnd = math.Random(seed);
  final t = <double>[], y = <double>[];
  var k = 0;
  for (var i = 0; i < n; i++) {
    final rr = 900 +
        90 * math.sin(i / 300) +
        45 * math.sin(i * 2 * math.pi * .25 * .9) +
        rnd.nextDouble() * 30;
    k += (rr / 1000 * 1024).round();
    t.add(k / 1024);
    y.add(rr);
  }
  return (t: t, y: y);
}

double _worstRel(LombScargle a, LombScargle b) {
  expect(a.spectrum.length, b.spectrum.length);
  var worst = 0.0;
  for (var i = 0; i < a.spectrum.length; i++) {
    final e = b.spectrum[i].psd;
    final d = (a.spectrum[i].psd - e).abs();
    worst = math.max(worst, e == 0 ? d : d / e.abs());
  }
  return worst;
}

/// The same algorithm with every sum Kahan-compensated and time measured from
/// the first sample. It shares no code with `lombScargle`, so it checks the
/// shift and the summation, not just self-consistency.
LombScargle _kahanReference(List<double> t, List<double> y, List<double> f) {
  double ksum(Iterable<double> xs) {
    var s = 0.0, c = 0.0;
    for (final x in xs) {
      final v = x - c;
      final u = s + v;
      c = (u - s) - v;
      s = u;
    }
    return s;
  }

  final n = t.length;
  final ts = [for (final v in t) v - t.first];
  final my = ksum(y) / n;
  final yc = [for (final v in y) v - my];
  final span = ts.reduce(math.max) - ts.reduce(math.min);
  final scale = 2.0 * span / (n - 1);
  final out = <LsPoint>[];
  for (final hz in f) {
    final w = 2 * math.pi * hz;
    final tau = math.atan2(ksum([for (final v in ts) math.sin(2 * w * v)]),
            ksum([for (final v in ts) math.cos(2 * w * v)])) /
        (2 * w);
    final c = [for (final v in ts) math.cos(w * (v - tau))];
    final s = [for (final v in ts) math.sin(w * (v - tau))];
    final cNum = ksum([for (var i = 0; i < n; i++) yc[i] * c[i]]);
    final sNum = ksum([for (var i = 0; i < n; i++) yc[i] * s[i]]);
    final cDen = ksum([for (final v in c) v * v]);
    final sDen = ksum([for (final v in s) v * v]);
    out.add(LsPoint(hz, 0.5 * (cNum * cNum / cDen + sNum * sNum / sDen) * scale));
  }
  return LombScargle(out);
}

void main() {
  final grid = freqGrid(0.0033, 0.4, 120);

  test('epoch seconds and rebased seconds give the same spectrum', () {
    final b = _beats(1200);
    final epoch = [for (final v in b.t) v + _epoch];
    expect(epoch[17] - epoch[3], b.t[17] - b.t[3], reason: 'offset is exact');
    final a = lombScargle(epoch, b.y, grid)!;
    final r = lombScargle(b.t, b.y, grid)!;
    expect(_worstRel(a, r), lessThan(1e-11));
  });

  test('epoch-second spectrum matches a compensated, shifted reference', () {
    final b = _beats(1200, seed: 9);
    final epoch = [for (final v in b.t) v + _epoch];
    final a = lombScargle(epoch, b.y, grid)!;
    expect(_worstRel(a, _kahanReference(epoch, b.y, grid)), lessThan(1e-11));
  });

  test('the shift is the first sample, so any time origin gives the same', () {
    final b = _beats(400, seed: 2);
    final base = lombScargle(b.t, b.y, grid)!;
    for (final offset in [-1000.0, 3600.0, 1e6, 1.5e9]) {
      final moved = lombScargle([for (final v in b.t) v + offset], b.y, grid)!;
      expect(_worstRel(moved, base), lessThan(1e-11), reason: 'offset $offset');
    }
  });

  test('incremental state agrees with batch on epoch seconds, far inside 1e-8',
      () {
    final b = _beats(900, seed: 4);
    final epoch = [for (final v in b.t) v + _epoch];
    final state = IncrementalLombScargle(grid);
    for (final n in [10, 100, 450, 900]) {
      final inc = state.sync(epoch.sublist(0, n), b.y.sublist(0, n))!;
      final batch = lombScargle(epoch.sublist(0, n), b.y.sublist(0, n), grid)!;
      expect(_worstRel(inc, batch), lessThan(1e-9), reason: 'n=$n');
    }
  });
}
