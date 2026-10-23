// cosinorAggregator (sufficient statistics) must agree with cosinor() for any
// series and any chunking or slicing, and obey the aggregator laws.
//
// Contract used here:
//  * TimedValues(tHours, y): equal-length Float64Lists (assert). Row r is the
//    sample (tHours[r], y[r]). copyRange returns copies; join concatenates.
//    TimedValues and cosinorAggregator are exported from
//    package:openstrap_analytics/aggregate.dart. No NaN handling is promised
//    or tested (cosinor() has none); a tHours/y length mismatch cannot occur.
//  * cosinorAggregator({periodHours = 24, minPoints = cosinorMinPoints}) is an
//    Aggregator<_, TimedValues, Metric<CosinorFit>>. Constructing it never
//    throws, also for periodHours <= 0 (then every run is absent).
//  * Absent exactly when cosinor() is absent: n < max(4, minPoints),
//    periodHours <= 0 ('too few points for cosinor'), or a singular design
//    (relative centered determinant <= 1e-12 of the diagonal product;
//    'singular cosinor design (insufficient phase coverage)').
//    Absent metrics carry the same tier, inputs_used and note.
//  * Present: mesor, amplitude, acrophaseRad within relTol 1e-9 (acrophaseRad
//    compared modulo 2 pi and with an absolute floor of 1e-9, because a phase
//    near 0 or +-pi has no meaningful relative error; for an amplitude that is
//    only rounding noise, below 1e-9 * max(1, |mesor|), the amplitude gets an
//    absolute floor of 1e-12 * max(1, |mesor|) and the phases are not compared);
//    acrophaseHours within
//    relTol 1e-9 of the period, modulo periodHours; periodHours equal; r2,
//    r2Adj, confidence absTol 1e-7; tier, inputs_used, note equal.
//  * Batch now runs the same aggregator. The near-singular fixture below
//    pins its relative gate; ordinary parity fixtures avoid that threshold.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:openstrap_analytics/aggregate.dart';
import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

import '../support/checkpoint_support.dart';
import '../support/aggregator_laws.dart';
import '../support/property.dart' show Rng;

const _twoPi = 2 * math.pi;

typedef _Agg = Aggregator<dynamic, TimedValues, Metric<CosinorFit>>;

TimedValues _tv(List<double> t, List<double> y) =>
    TimedValues(Float64List.fromList(t), Float64List.fromList(y));

/// Distance of [a] and [b] on a circle of circumference [period].
double _circ(double a, double b, double period) {
  var d = (a - b) % period;
  if (d < 0) d += period;
  return math.min(d, period - d);
}

/// True when a finite/non-finite mismatch (or two different non-finite values)
/// makes a tolerance comparison meaningless: NaN fails every `>` check, so
/// without this guard a NaN field would slip through as "equal".
bool _nonFiniteMismatch(double a, double b) {
  if (a.isFinite && b.isFinite) return false;
  if (a.isNaN && b.isNaN) return false;
  return a != b;
}

/// Null when [got] matches [want] per the spec tolerances, else why not.
String? _diff(Metric<CosinorFit> got, Metric<CosinorFit> want) {
  if (got.present != want.present) {
    return 'present ${got.present} vs ${want.present}';
  }
  if (got.tier != want.tier ||
      got.inputs_used.join(',') != want.inputs_used.join(',') ||
      got.note != want.note) {
    return 'metadata ${got.tier}/${got.inputs_used}/${got.note} vs '
        '${want.tier}/${want.inputs_used}/${want.note}';
  }
  if (_nonFiniteMismatch(got.confidence, want.confidence) ||
      (got.confidence - want.confidence).abs() > 1e-7) {
    return 'confidence ${got.confidence} vs ${want.confidence}';
  }
  final g = got.value, w = want.value;
  if (g == null || w == null) return null;
  for (final (name, a, b) in [
    ('mesor', g.mesor, w.mesor),
    ('amplitude', g.amplitude, w.amplitude),
    ('acrophaseRad', g.acrophaseRad, w.acrophaseRad),
    ('acrophaseHours', g.acrophaseHours, w.acrophaseHours),
    ('r2', g.r2, w.r2),
    ('r2Adj', g.r2Adj, w.r2Adj),
  ]) {
    if (_nonFiniteMismatch(a, b)) return '$name non-finite mismatch $a vs $b';
  }
  bool rel(double a, double b, [double floor = 0]) =>
      (a - b).abs() <= math.max(floor, 1e-9 * math.max(a.abs(), b.abs()));
  // A mesor near zero (data centred on 0) has no relative accuracy either:
  // its rounding scales with the amplitude, so it gets the same data-scale
  // floor.
  final scale = math.max(1.0, math.max(w.mesor.abs(), w.amplitude));
  if (!rel(g.mesor, w.mesor, 1e-12 * scale)) {
    return 'mesor ${g.mesor} vs ${w.mesor}';
  }
  // An amplitude that is pure rounding noise (constant data) has no relative
  // accuracy and no phase: compare it against a floor and skip the phases.
  final floor = 1e-12 * math.max(1, w.mesor.abs());
  if (!rel(g.amplitude, w.amplitude, floor)) {
    return 'amplitude ${g.amplitude} vs ${w.amplitude}';
  }
  final noPhase = w.amplitude < 1000 * floor && g.amplitude < 1000 * floor;
  if (!noPhase &&
      _circ(g.acrophaseRad, w.acrophaseRad, _twoPi) >
      1e-9 * math.max(1, w.acrophaseRad.abs())) {
    return 'acrophaseRad ${g.acrophaseRad} vs ${w.acrophaseRad}';
  }
  if (g.periodHours != w.periodHours) return 'periodHours';
  if (!noPhase &&
      _circ(g.acrophaseHours, w.acrophaseHours, w.periodHours) >
      1e-9 * w.periodHours) {
    return 'acrophaseHours ${g.acrophaseHours} vs ${w.acrophaseHours}';
  }
  if ((g.r2 - w.r2).abs() > 1e-7) return 'r2 ${g.r2} vs ${w.r2}';
  if ((g.r2Adj - w.r2Adj).abs() > 1e-7) {
    return 'r2Adj ${g.r2Adj} vs ${w.r2Adj}';
  }
  return null;
}

bool _eq(Metric<CosinorFit> a, Metric<CosinorFit> b) => _diff(a, b) == null;

void _same(Metric<CosinorFit> got, Metric<CosinorFit> want, String tag) {
  expect(_diff(got, want), isNull, reason: tag);
}

Metric<CosinorFit> _want(TimedValues d, double period, int minPoints) =>
    cosinor(d.tHours, d.y, periodHours: period, minPoints: minPoints);

void _allPaths(_Agg a, TimedValues d, List<int> b, Metric<CosinorFit> want,
    String tag) {
  _same(runChunked(a, d, b), want, '$tag chunks $b');
  _same(runChunked(a, d, b, copy: true), want, '$tag copies $b');
  _same(runChunkedRight(a, d, b), want, '$tag right $b');
  _same(runSliced(a, d, b), want, '$tag sliced $b');
}

/// [n] samples: y = mesor + amp cos(w (t - peak)) + noise. Times are a regular
/// grid of [step] hours from [t0] with jitter [jitter] (hours).
TimedValues _series(Rng r, int n,
    {double period = 24,
    double mesor = 33,
    double amp = .3,
    double noise = 0,
    double peak = 15.5,
    double t0 = 0,
    double step = .25,
    double jitter = 0}) {
  final w = _twoPi / period;
  final t = <double>[], y = <double>[];
  for (var i = 0; i < n; i++) {
    final ti = t0 + i * step + (jitter == 0 ? 0 : (r.nextDouble() - .5) * jitter);
    t.add(ti);
    y.add(mesor +
        amp * math.cos(w * (ti - peak)) +
        (noise == 0 ? 0 : (r.nextDouble() - .5) * 2 * noise));
  }
  return _tv(t, y);
}

void _parity(String tag, TimedValues d,
    {double period = 24, int minPoints = cosinorMinPoints, int seed = 1}) {
  final want = _want(d, period, minPoints);
  final a = cosinorAggregator(periodHours: period, minPoints: minPoints);
  _same(a.run(d), want, '$tag whole');
  final r = Rng(seed);
  for (var k = 0; k < 3; k++) {
    _allPaths(a, d, randomBounds(r, d.length), want, tag);
  }
  _allPaths(a, d, singletonBounds(d.length), want, '$tag singletons');
}

TimedValues _lawSeries(Rng r, int i) {
  final n = r.intIn(0, 40);
  return _series(r, n,
      amp: [.3, 2.0][i % 2],
      noise: [.02, .3, 1e-6][i % 3],
      // Cover about one to two periods so the design is well conditioned.
      step: 24 * (1 + r.nextDouble()) / math.max(n, 1),
      jitter: .3,
      peak: r.nextDouble() * 24);
}

void main() {
  test('tiny phase coverage returns an absent metric, not a fabricated fit', () {
    // Distinct finite times, clustered around phase pi/4. The two centered
    // design columns become nearly collinear despite enough observations.
    final t = [for (var i = 0; i < 16; i++) 3.0 + i * 1e-6];
    final y = [for (var i = 0; i < t.length; i++) 60.0 + i * 0.01];
    final batch = _tv(t, y);
    final agg = cosinorAggregator();
    final left = agg.addSlice(agg.empty(), batch, 0, 8);
    final right = agg.addSlice(agg.empty(), batch, 8, batch.length);
    for (final result in [agg.run(batch),
      agg.finish(agg.combine(left, right)), cosinor(t, y)]) {
      expect(result.value, isNull);
      expect(result.present, isFalse);
      expect(result.confidence, 0);
      expect(result.tier, Tier.high);
      expect(result.inputs_used, ['signal_timeseries']);
      expect(result.note,
          'singular cosinor design (insufficient phase coverage)');
    }
  });

  group('TimedValues batch', () {
    final d = _tv([0, 1, 2, 3, 4], [10, 11, 12, 13, 14]);
    test('length, copyRange, join', () {
      expect(d.length, 5);
      final c = d.copyRange(1, 4);
      expect(c.tHours, [1.0, 2.0, 3.0]);
      expect(c.y, [11.0, 12.0, 13.0]);
      final j = d.copyRange(0, 2).join(d.copyRange(2, 5));
      expect(j.tHours, d.tHours);
      expect(j.y, d.y);
      expect(d.copyRange(2, 2).length, 0);
    });
    test('copies are independent of the source and of the join inputs', () {
      final c = d.copyRange(0, 3);
      d.y[0] = -1;
      d.tHours[1] = -1;
      expect(c.y[0], 10.0);
      expect(c.tHours[1], 1.0);
      final left = _tv([0, 1], [1, 2]), right = _tv([2], [3]);
      final j = left.join(right);
      left.y[0] = 99;
      right.tHours[0] = 99;
      expect(j.y, [1.0, 2.0, 3.0]);
      expect(j.tHours, [0.0, 1.0, 2.0]);
    });
  });

  group('absent cases', () {
    final good = _series(Rng(1), 48);

    test('too few points, default minPoints 8', () {
      for (var n = 0; n <= 10; n++) {
        final d = _series(Rng(n), n, noise: .1, step: .7);
        final want = _want(d, 24, cosinorMinPoints);
        expect(want.present, n >= 8, reason: 'n=$n');
        _parity('n=$n', d, seed: n);
      }
      final m = cosinorAggregator().run(_series(Rng(1), 7, noise: .1));
      expect(m.present, isFalse);
      expect(m.note, 'too few points for cosinor');
      expect(m.confidence, 0);
    });
    test('minPoints is honoured: larger, and smaller than 4 is floored to 4',
        () {
      for (final mp in [2, 4, 5, 12, 40]) {
        for (var n = 0; n <= 14; n++) {
          final d = _series(Rng(n), n, noise: .1, step: .7);
          _parity('mp=$mp n=$n', d, minPoints: mp, seed: n + mp);
        }
      }
      expect(cosinorAggregator(minPoints: 12)
          .run(_series(Rng(1), 11, noise: .1, step: .7)).present, isFalse);
      expect(cosinorAggregator(minPoints: 2)
          .run(_series(Rng(1), 3, noise: .1, step: 5)).present, isFalse);
      expect(cosinorAggregator(minPoints: 2)
          .run(_series(Rng(1), 4, noise: .1, step: 5)).present, isTrue);
    });
    test('periodHours <= 0 is absent, and building the aggregator is fine', () {
      for (final p in [0.0, -24.0, -1e-9]) {
        final want = _want(good, p, cosinorMinPoints);
        expect(want.present, isFalse);
        final a = cosinorAggregator(periodHours: p);
        _same(a.run(good), want, 'period $p');
        _same(a.run(good.copyRange(0, 3)), _want(good.copyRange(0, 3), p, 8),
            'period $p short');
        _allPaths(a, good, [0, 10, 10, 30, 48], want, 'period $p');
      }
    });
    test('empty batch and empty state are absent', () {
      final a = cosinorAggregator();
      final want = _want(_tv([], []), 24, cosinorMinPoints);
      _same(a.run(_tv([], [])), want, 'empty');
      _same(a.finish(a.empty()), want, 'empty state');
    });
    test('singular design: every sample at the same phase', () {
      // Whole periods apart, so cos/sin are the same at every row.
      final d = _tv([for (var i = 0; i < 20; i++) 24.0 * i],
          [for (var i = 0; i < 20; i++) 33 + .1 * (i % 3)]);
      final want = _want(d, 24, 8);
      expect(want.present, isFalse);
      expect(want.note, contains('singular'));
      _parity('same phase (multiples of the period)', d);
      final same = _tv(List.filled(12, 7.5), [for (var i = 0; i < 12; i++) 30.0 + i]);
      expect(_want(same, 24, 8).present, isFalse);
      _parity('all at one time', same);
    });
    test('singular note and metadata match', () {
      final d = _tv(List.filled(10, 3.0), [for (var i = 0; i < 10; i++) i * 1.0]);
      final m = cosinorAggregator().run(d);
      expect(m.present, isFalse);
      expect(m.note, 'singular cosinor design (insufficient phase coverage)');
      expect(m.confidence, 0);
    });
  });

  group('values', () {
    test('noise-free 33 +- 0.3 recovers the parameters', () {
      final d = _series(Rng(1), 96, peak: 15.5);
      final m = cosinorAggregator().run(d);
      final v = m.value!;
      expect(v.mesor, closeTo(33, 1e-9));
      expect(v.amplitude, closeTo(.3, 1e-9));
      expect(v.acrophaseHours, closeTo(15.5, 1e-7));
      expect(v.r2, closeTo(1, 1e-7));
      expect(v.r2Adj, closeTo(1, 1e-7));
      expect(v.periodHours, 24.0);
      expect(m.confidence, closeTo(.95, 1e-7));
    });
    test('hand-worked: y = 10 + 2 cos(2 pi t / 24) on a 3-hour grid', () {
      final t = [for (var i = 0; i < 16; i++) 3.0 * i];
      final y = [for (final x in t) 10 + 2 * math.cos(_twoPi * x / 24)];
      final v = cosinorAggregator().run(_tv(t, y)).value!;
      expect(v.mesor, closeTo(10, 1e-9));
      expect(v.amplitude, closeTo(2, 1e-9));
      expect(v.acrophaseRad, closeTo(0, 1e-9));
      expect(_circ(v.acrophaseHours, 0, 24), lessThan(1e-7));
    });
    test('period 12 and a custom period are carried through', () {
      final d = _series(Rng(2), 80, period: 12, peak: 4, step: .3);
      final v = cosinorAggregator(periodHours: 12).run(d).value!;
      expect(v.periodHours, 12.0);
      expect(v.acrophaseHours, closeTo(4, 1e-6));
      expect(v.amplitude, closeTo(.3, 1e-9));
    });
  });

  group('parity on named series', () {
    final named = <String, (TimedValues, double)>{
      'mesor 33 amp 0.3 exact, 24 h': (_series(Rng(1), 96), 24),
      'mesor 33 amp 0.3 exact, 12 h': (_series(Rng(2), 96, period: 12), 12),
      'mesor 33 amp 0.3, noise 0.01': (
        _series(Rng(3), 200, noise: .01, jitter: .1),
        24
      ),
      'mesor 33 amp 0.3, noise 0.3 (noisy)': (
        _series(Rng(4), 200, noise: .3, jitter: .1),
        24
      ),
      'mesor 33 amp 0.3, noise 2 (almost nothing)': (
        _series(Rng(5), 120, noise: 2),
        24
      ),
      'mesor 200 amp 0.01 exact': (
        _series(Rng(6), 150, mesor: 200, amp: .01),
        24
      ),
      'mesor 1000 amp 0.5 noisy': (
        _series(Rng(7), 150, mesor: 1000, amp: .5, noise: .2, jitter: .2),
        24
      ),
      'zero amplitude, tiny noise': (
        _series(Rng(8), 100, amp: 0, noise: .05),
        24
      ),
      'near-perfect, amp 20': (_series(Rng(9), 100, mesor: 60, amp: 20), 24),
      'near-perfect with 1e-6 noise': (
        _series(Rng(10), 100, noise: 1e-6, jitter: .05),
        24
      ),
      'hours since epoch (large t)': (
        _series(Rng(11), 100, t0: 480000, noise: .02),
        24
      ),
      'negative t': (_series(Rng(12), 100, t0: -500, noise: .02), 24),
      'exactly 8 points': (_series(Rng(13), 8, step: 3, noise: .1), 24),
      'peak at 0 h': (_series(Rng(14), 96, peak: 0, noise: .02), 24),
      'peak at 23.9 h': (_series(Rng(15), 96, peak: 23.9, noise: .02), 24),
      'period 12, noisy': (
        _series(Rng(16), 120, period: 12, noise: .2, amp: .6),
        12
      ),
      'period 24 data fitted at 12': (
        _series(Rng(17), 120, noise: .05, amp: 1),
        12
      ),
      'period 8': (_series(Rng(18), 90, period: 8, noise: .05, step: .5), 8),
      'irregular times over 3 days': (
        _series(Rng(19), 60, step: 1.2, jitter: 1, noise: .05, amp: 1),
        24
      ),
    };
    var seed = 0;
    named.forEach((name, c) {
      final s = ++seed;
      test(name, () {
        final want = _want(c.$1, c.$2, cosinorMinPoints);
        expect(want.present, isTrue, reason: 'fixture should be fittable');
        _parity(name, c.$1, period: c.$2, seed: s);
      });
    });

    test('the clamps agree: ssRes rounding must not leave r2 outside 0..1', () {
      final d = _series(Rng(30), 200, mesor: 500, amp: .05);
      _parity('r2 clamp', d);
      final v = cosinorAggregator().run(d).value!;
      expect(v.r2, inInclusiveRange(0, 1));
      expect(v.r2Adj, inInclusiveRange(0, 1));
    });
    test('constant y: ssTot is 0, r2 is 0 as in cosinor()', () {
      final d = _series(Rng(31), 40, amp: 0, noise: 0);
      final want = _want(d, 24, 8);
      expect(want.present, isTrue);
      expect(want.value!.r2, 0.0);
      _parity('constant', d);
    });
  });

  group('random parity (seeded)', () {
    test('random shape, period, size; whole, chunked, sliced', () {
      final r = Rng(0xC051);
      var checked = 0;
      for (var t = 0; t < 60; t++) {
        final period = [24.0, 12.0, 24.0, 8.0, 36.0][r.intIn(0, 4)];
        final n = r.nextBool(.15) ? r.intIn(0, 9) : r.intIn(10, 220);
        final mesor = [0.0, 33.0, 33.0, 120.0, -15.0][r.intIn(0, 4)];
        final amp = r.nextBool(.15) ? 0.0 : [.3, 1.0, 12.0][r.intIn(0, 2)];
        // Noise-free flat data and 1e-6 noise on a flat series have no
        // meaningful phase; keep them for series that have an amplitude.
        final noise = amp == 0
            ? [.02, .3, 1.5][r.intIn(0, 2)]
            : [0.0, 1e-6, .02, .3, 1.5][r.intIn(0, 4)];
        final d = _series(r, n,
            period: period,
            mesor: mesor,
            amp: amp,
            noise: noise,
            peak: r.nextDouble() * period,
            t0: r.nextBool(.2) ? 1e5 * r.nextDouble() : 0,
            // 0.6 to 3 periods of coverage, so the design is well conditioned.
            step: period * (.6 + r.nextDouble() * 2.4) / math.max(n, 1),
            jitter: r.nextBool() ? 0 : .5);
        final mp = r.nextBool(.7) ? cosinorMinPoints : r.intIn(2, 30);
        _parity('t$t n=$n P=$period mesor=$mesor amp=$amp noise=$noise', d,
            period: period, minPoints: mp, seed: t);
        checked++;
      }
      expect(checked, 60);
    });
  });

  test('persistable: a mid-stream checkpoint resumes to the one-pass result', () {
    final b = _lawSeries(Rng(0xC0DE), 3);
    expectCheckpointResumes(cosinorAggregator(), b, equals: _eq);
  });

  group('lawful', () {
    final r = Rng(0xC052);
    final cases = <TimedValues>[
      _tv([], []),
      _tv([1], [2]),
      _tv([1, 2], [2, 3]),
      for (var i = 0; i < 12; i++)
        _lawSeries(r, i),
    ];
    test('default period', () {
      expectLawful(cosinorAggregator(), cases, equals: _eq);
    });
    test('period 12, minPoints 5', () {
      expectLawful(cosinorAggregator(periodHours: 12, minPoints: 5), cases,
          equals: _eq);
    });
    test('periodHours 0 (always absent)', () {
      expectLawful(cosinorAggregator(periodHours: 0), cases, equals: _eq);
    });
  });

  group('_diff comparator', () {
    final base = cosinor(_series(Rng(1), 48, noise: .05).tHours,
        _series(Rng(1), 48, noise: .05).y);
    Metric<CosinorFit> with_(
            {double? mesor,
            double? amplitude,
            double? rad,
            double? hours,
            double? r2,
            double? r2Adj,
            double? confidence}) =>
        Metric<CosinorFit>(
          value: CosinorFit(
            mesor: mesor ?? base.value!.mesor,
            amplitude: amplitude ?? base.value!.amplitude,
            acrophaseRad: rad ?? base.value!.acrophaseRad,
            acrophaseHours: hours ?? base.value!.acrophaseHours,
            periodHours: base.value!.periodHours,
            r2: r2 ?? base.value!.r2,
            r2Adj: r2Adj ?? base.value!.r2Adj,
          ),
          confidence: confidence ?? base.confidence,
          tier: base.tier,
          inputs_used: base.inputs_used,
          note: base.note,
        );

    test('identical metrics are equal', () {
      expect(_diff(with_(), base), isNull);
    });
    test('r2 replaced by NaN is reported', () {
      expect(_diff(with_(r2: double.nan), base), isNotNull);
      expect(_diff(base, with_(r2: double.nan)), isNotNull);
    });
    test('every field turned NaN or infinite is reported', () {
      for (final bad in [double.nan, double.infinity]) {
        expect(_diff(with_(r2Adj: bad), base), isNotNull, reason: 'r2Adj $bad');
        expect(_diff(with_(confidence: bad), base), isNotNull,
            reason: 'confidence $bad');
        expect(_diff(with_(rad: bad), base), isNotNull, reason: 'rad $bad');
        expect(_diff(with_(hours: bad), base), isNotNull, reason: 'hours $bad');
        expect(_diff(with_(mesor: bad), base), isNotNull, reason: 'mesor $bad');
        expect(_diff(with_(amplitude: bad), base), isNotNull,
            reason: 'amplitude $bad');
      }
    });
  });

  group('narrow phase coverage', () {
    // 16 samples in 0.15 h of a 24 h period: the (c, s) design is almost
    // collinear. cosinor()'s own 3x3 solve is not trustworthy here, so these
    // tests make NO parity claim against cosinor(); they only demand that the
    // aggregator agrees with itself across chunking.
    TimedValues narrow(int n, {double step = .01}) {
      final w = _twoPi / 24;
      final t = [for (var i = 0; i < n; i++) step * i];
      return _tv(t, [
        for (final ti in t) 33 + .3 * math.cos(w * ti) + .1 * math.sin(w * ti)
      ]);
    }

    bool relClose(double a, double b, double tol) =>
        (a - b).abs() <= tol * math.max(a.abs(), b.abs());

    test('whole vs split at 8 agree to 1e-9 relative (review case)', () {
      final d = narrow(16);
      final a = cosinorAggregator();
      final whole = a.run(d);
      for (final split in [
        runChunked(a, d, [0, 8, 16]),
        runChunked(a, d, [0, 8, 16], copy: true),
        runChunkedRight(a, d, [0, 8, 16]),
      ]) {
        expect(split.present, whole.present,
            reason: 'present ${split.present} vs ${whole.present}');
        if (!whole.present) continue;
        final g = split.value!, w = whole.value!;
        expect(relClose(g.amplitude, w.amplitude, 1e-9), isTrue,
            reason: 'amplitude ${g.amplitude} vs ${w.amplitude}');
        expect(relClose(g.mesor, w.mesor, 1e-9), isTrue,
            reason: 'mesor ${g.mesor} vs ${w.mesor}');
      }
    });

    test('every single split point of the review case agrees', () {
      final d = narrow(16);
      final a = cosinorAggregator();
      final whole = a.run(d);
      for (var k = 1; k < 16; k++) {
        final split = runChunked(a, d, [0, k, 16]);
        expect(split.present, whole.present, reason: 'split $k presence');
        if (!whole.present) continue;
        expect(
            relClose(split.value!.amplitude, whole.value!.amplitude, 1e-9),
            isTrue,
            reason: 'split $k amplitude '
                '${split.value!.amplitude} vs ${whole.value!.amplitude}');
        expect(relClose(split.value!.mesor, whole.value!.mesor, 1e-9), isTrue,
            reason: 'split $k mesor');
      }
    });

    test('narrow-coverage cases are lawful', () {
      expectLawful(cosinorAggregator(), [
        _tv([], []),
        narrow(16),
        narrow(24),
        narrow(16, step: .02),
        narrow(20, step: .005),
      ], equals: _eq);
    });
  });
}
