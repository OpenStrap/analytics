// Boundary / refusal-path oracle tests that RR-correction-driven data rarely
// reaches: beats landing EXACTLY on bin edges, the jitter gate (RMSSD refused),
// thin input => absent exactly where the oracle is.
import 'dart:math' as math;

import 'package:openstrap_analytics/onehz.dart'
    hide RrCorrector, RrSettled, RrSnapshot, IrregularScreenState;
import 'package:test/test.dart';

import '../../tool/incremental/hrv_incr.dart';
import '../../tool/incremental/oracle_util.dart';
import '../../tool/incremental/resp_incr.dart';
import 'support.dart';

({List<double> nn, List<double> t}) _nn(int n,
    {double step = 1000, double noise = 0, int seed = 1, double start = 0}) {
  final r = math.Random(seed);
  final nn = <double>[], t = <double>[];
  var clock = start;
  for (var i = 0; i < n; i++) {
    final v = (step + 60 * math.sin(i * 0.21) + noise * (r.nextDouble() - .5))
        .roundToDouble();
    clock += v;
    nn.add(v);
    t.add(clock);
  }
  return (nn: nn, t: t);
}

/// Equal null-ness and within 1e-9 relative (the aggregator's stated
/// tolerance; hrvTime now runs hrvTimeAggregator).
void _near9(double? got, double? want, String reason) {
  expect(got == null, want == null, reason: reason);
  if (got != null && want != null) {
    expect(got, closeTo(want, 1e-9 * want.abs()), reason: reason);
  }
}

void main() {
  test('night shape: beats exactly on 30-min edges, incl. last beat on an edge', () {
    // 1000 ms steps from 0 => beat times are multiples of 1000, bins at 1.8e6
    for (final lastOnEdge in [false, true]) {
      final n = 1800 * 4 + (lastOnEdge ? 0 : 777);
      final nn = <double>[], t = <double>[];
      for (var i = 1; i <= n; i++) {
        nn.add(1000.0 + (i % 17) * 3);
        t.add(i * 1000.0); // beat i ends at i*1000 ms
      }
      // make t0 = t[0] = 1000 => edges at 1000 + k*1.8e6
      for (final chunk in [1, 37, 900, 5000]) {
        final st = NightShapeState();
        for (var a = 0; a < n; a += chunk) {
          final b = math.min(n, a + chunk);
          st.fold(nn.sublist(a, b), t.sublist(a, b));
          final want = nightHrvShape(nn.sublist(0, b), t.sublist(0, b));
          final got = st.evaluate(const [], const []);
          sameEnvelope(got, want, why: 'edge n=$b chunk=$chunk');
          if (want.present) {
            expect(got.value!.toJson(), want.value!.toJson(), reason: 'n=$b');
          }
        }
      }
    }
  });

  test('night shape: dropout makes empty bins (holes) and a gap straddles a bin', () {
    final a = _nn(2500, seed: 3);
    final b = _nn(2500, seed: 4, start: a.t.last + 3 * 3600 * 1000.0); // 3 h gap
    final nn = [...a.nn, ...b.nn], t = [...a.t, ...b.t];
    final st = NightShapeState();
    final r = math.Random(7);
    var at = 0;
    for (final cut in randomCuts(r, nn.length, sizes: [50, 700, 3000])) {
      st.fold(nn.sublist(at, cut), t.sublist(at, cut));
      at = cut;
      final want = nightHrvShape(nn.sublist(0, cut), t.sublist(0, cut));
      final got = st.evaluate(const [], const []);
      sameEnvelope(got, want, why: 'cut=$cut');
      if (want.present) expect(got.value!.toJson(), want.value!.toJson());
    }
  });

  test('hrvTime: jitter gate refuses RMSSD/pNN50 exactly like the oracle', () {
    final x = _nn(3000, noise: 260, seed: 5); // near-white successive diffs
    final want0 = hrvTime(x.nn, nnTimesMs: x.t);
    expect(want0.value!.rmssd, isNull, reason: 'fixture must trip the gate');
    for (final chunk in [1, 29, 30, 31, 600]) {
      final acc = HrvTimeAcc();
      for (var a = 0; a < x.nn.length; a += chunk) {
        final b = math.min(x.nn.length, a + chunk);
        acc.fold(x.nn.sublist(a, b), x.t.sublist(a, b));
        final want = hrvTime(x.nn.sublist(0, b), nnTimesMs: x.t.sublist(0, b));
        final got = acc.evaluate(const [], const []);
        expect(got.present, want.present);
        if (!want.present) continue;
        expect(got.value!.rmssd, want.value!.rmssd, reason: 'b=$b');
        expect(got.value!.pnn50, want.value!.pnn50, reason: 'b=$b');
        // 1e-9 relative: hrvTime now runs hrvTimeAggregator (was exact).
        _near9(got.value!.sdann, want.value!.sdann, 'sdann b=$b');
        _near9(got.value!.sdnnIndex, want.value!.sdnnIndex, 'sdnnIndex b=$b');
        expect(got.value!.nBeats, want.value!.nBeats);
        expect(got.note, want.note, reason: 'b=$b');
      }
    }
  });

  test('hrvTime: gaps (seams) between runs, thin series', () {
    final a = _nn(400, seed: 8), b = _nn(400, seed: 9, start: 5000000);
    final nn = [...a.nn, ...b.nn], t = [...a.t, ...b.t];
    final acc = HrvTimeAcc();
    for (var n = 0; n <= nn.length; n += (n < 40 ? 1 : 97)) {
      final acc2 = HrvTimeAcc()..fold(nn.sublist(0, n), t.sublist(0, n));
      final want = hrvTime(nn.sublist(0, n), nnTimesMs: t.sublist(0, n));
      final got = acc2.evaluate(const [], const []);
      expect(got.present, want.present, reason: 'n=$n');
      if (want.present) {
        expect(got.value!.rmssd, want.value!.rmssd, reason: 'n=$n');
        expect(got.value!.pnn50, want.value!.pnn50);
        expect(got.value!.diffAcf1 == null, want.value!.diffAcf1 == null);
      }
    }
    expect(acc.n, 0);
  });

  test('rsa: absent when oracle abstains (slow HR => ceiling below HF band)', () {
    // 1500 ms beats: Nyquist 0.333 Hz < 0.40 => oracle refuses; so must we.
    final x = _nn(900, step: 1500, noise: 10, seed: 2);
    final st = RsaWelchState();
    var at = 0;
    for (final cut in [200, 205, 500, 900]) {
      st.fold(x.nn.sublist(at, cut), x.t.sublist(at, cut));
      at = cut;
      final want = rsaRespRate(x.nn.sublist(0, cut), x.t.sublist(0, cut),
          artifactFraction: 0.05);
      final got = st.evaluate(const [], const [], artifactFraction: 0.05);
      sameEnvelope(got, want, why: 'cut=$cut');
      expect(got.value?.brpm, want.value?.brpm);
    }
  });

  test('rsa: artifact gate, thin (<20 beats), spans just below/at 600 s', () {
    final x = _nn(1500, step: 800, noise: 30, seed: 6);
    for (final af in [0.0, 0.31]) {
      final st = RsaWelchState();
      var at = 0;
      for (final cut in [10, 19, 20, 400, 749, 750, 751, 752, 900, 1500]) {
        st.fold(x.nn.sublist(at, cut), x.t.sublist(at, cut));
        at = cut;
        final want = rsaRespRate(x.nn.sublist(0, cut), x.t.sublist(0, cut),
            artifactFraction: af);
        final got = st.evaluate(const [], const [], artifactFraction: af);
        sameEnvelope(got, want, why: 'cut=$cut af=$af');
        expect(got.value?.brpm, want.value?.brpm, reason: 'cut=$cut');
      }
    }
  });

  // Under the ACF floor hrvTime reads the difference runs: a respiratory line
  // exempts the night, a refused one may publish from a breathing line
  // steady in Hz. HrvTimeAcc carries the library's mergeable evidence for both.
  for (final (name, mode, n) in [
    ('exempt (RSA at a slow heart)', 3, 1200),
    ('breathing line steady in Hz', 4, 4200),
  ]) {
    test('hrvTime below the floor: $name, chunks + restarts', () {
      final r = math.Random(mode);
      final nn = <double>[], t = <double>[];
      var clock = 1e6;
      for (var i = 0; i < n; i++) {
        final s = (clock - 1e6) / 1000;
        final v = mode == 3
            ? 1350 + 80 * math.sin(2 * math.pi * s / 3600) +
                40 * math.sin(2 * math.pi * .3 * s) + 3 * (r.nextDouble() - .5)
            : 900 + 400 * s / 9000 + 10 * math.sin(2 * math.pi * .25 * s) +
                40 * (r.nextDouble() - .5);
        clock += v;
        nn.add(v);
        t.add(clock);
      }
      final whole = hrvTime(nn, nnTimesMs: t);
      expect(whole.value!.diffAcf1, lessThan(kNnDiffAcf1Floor));
      expect(whole.value!.rmssd, isNotNull, reason: 'the batch publishes');
      var acc = HrvTimeAcc();
      var at = 0;
      for (final cut in randomCuts(math.Random(9), n, sizes: [37, 400, 1300])) {
        acc.fold(nn.sublist(at, cut), t.sublist(at, cut));
        acc = HrvTimeAcc.fromJson(jsonRoundTrip(acc.toJson()));
        at = cut;
        final want = hrvTime(nn.sublist(0, cut), nnTimesMs: t.sublist(0, cut));
        final got = acc.evaluate(const [], const []);
        expect(got.note, want.note, reason: 'cut=$cut');
        expect(got.value!.rmssd == null, want.value!.rmssd == null, reason: 'cut=$cut');
        if (want.value!.rmssd != null) {
          expect((got.value!.rmssd! - want.value!.rmssd!).abs(),
              lessThan(1e-9 * want.value!.rmssd!), reason: 'cut=$cut');
        }
      }
    });
  }
}
