// RED: the RR "sandwich" (combined bump, chunk A2 + A3).
//
// Contract (lib/src/onehz/foundations/rr_sandwich.dart):
//   RrSandwich<S, R>(inner, {maxArtifactRun = kMaxArtifactRun, ...}) is an
//   Aggregator over RawRr (raw RR ms + beat timestamps). It corrects with the
//   capped Lipponen-Tarvainen rule and feeds the settled NN (nnMs) into
//   `inner`, each with the ABSOLUTE raw timestamp (`rrTsMs`) of the input beat
//   it came from (`nnSourceIndex`): the beat itself, or for a spline-corrected
//   beat that beat's own timestamp. Not correctRr's relative clock, so a seam
//   needs no clock translation.
//
//   * ANY chunking (random cuts, one-beat chunks, empty chunks, chunks as
//     ranges or as copies, combined left- or right-nested, or one state sliced)
//     finishes to exactly what one pass gives, and that is the capped
//     `correctRr` over all the beats: nn bit for bit, paired with the absolute
//     timestamps of the source beats.
//   * It obeys the aggregator laws (identity, split, associativity, singletons,
//     slicing, finishPure, roundTrip) and checkpoints/resumes mid-stream.
//   * Its state is bounded: it keeps a raw head and tail, not the series, so an
//     endless artifact run does not grow it.
//   * A3: the night HRV time-domain and PRSA aggregators fed through it agree
//     with the batch functions run on capped correctRr's NN, within their
//     documented tolerances (1e-9).
//
// Data are integer RR with whole-second timestamps (synthRr: dropouts, ectopy,
// missed and extra beats, noise runs) and cleanly built long-run series
// (support/rr_runs.dart), so every clock value is an integer and "exactly" is
// attainable across chunk seams.
import 'dart:convert';
import 'dart:typed_data';

import 'package:openstrap_analytics/aggregate.dart';
import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

import '../onehz/support/rr_compare.dart';
import '../onehz/support/rr_runs.dart';
import '../onehz/support/rr_synth.dart';
import '../support/aggregator_laws.dart';
import '../support/checkpoint_support.dart';
import '../support/hrv_beats.dart';
import '../support/property.dart';

/// Test inner: keeps every NN and its time (unbounded on purpose; the point is
/// to see exactly what the sandwich hands down).
class _Acc {
  final nn = <double>[], t = <double>[];
}

class _Collect extends Aggregator<_Acc, Beats, Beats> {
  @override
  _Acc empty() => _Acc();
  @override
  _Acc addSlice(_Acc s, Beats b, int start, int end) {
    for (var i = start; i < end; i++) {
      s.nn.add(b.nnMs[i]);
      s.t.add(b.timeMs[i]);
    }
    return s;
  }

  @override
  _Acc combine(_Acc l, _Acc r) {
    l.nn.addAll(r.nn);
    l.t.addAll(r.t);
    return l;
  }

  @override
  Beats finish(_Acc s) => Beats(Float64List.fromList(s.nn), Float64List.fromList(s.t));

  @override
  bool get persistable => true;
  @override
  Object? encodeState(_Acc s) => {'nn': s.nn, 't': s.t};
  @override
  _Acc decodeState(Object? json) {
    final m = json as Map;
    return _Acc()
      ..nn.addAll([for (final v in m['nn'] as List) (v as num).toDouble()])
      ..t.addAll([for (final v in m['t'] as List) (v as num).toDouble()]);
  }
}

RrSandwich<_Acc, Beats> _sandwich({int? maxArtifactRun = kMaxArtifactRun}) =>
    RrSandwich<_Acc, Beats>(_Collect(), maxArtifactRun: maxArtifactRun);

bool _sameBeats(Beats a, Beats b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a.nnMs[i].compareTo(b.nnMs[i]) != 0 ||
        a.timeMs[i].compareTo(b.timeMs[i]) != 0) {
      return false;
    }
  }
  return true;
}

typedef RrSeriesLike = ({List<double> rr, List<double> ts});

/// The oracle: capped (or [cap]ped) correctRr's NN, each paired with the
/// ABSOLUTE timestamp of the input beat it came from.
({List<double> nn, List<double> t}) _oracle(RrSeriesLike s,
    {int? cap = kMaxArtifactRun}) {
  final c = correctRr(s.rr, rrTsMs: s.ts, maxArtifactRun: cap);
  return (nn: c.nn, t: [for (final i in c.nnSourceIndex) s.ts[i]]);
}

void _expectIsCorrectRr(Beats got, RrSeriesLike s, String why,
    {int? cap = kMaxArtifactRun}) {
  final want = _oracle(s, cap: cap);
  expectBitIdentical(got.nnMs, want.nn, '$why nn');
  expectBitIdentical(got.timeMs, want.t, '$why absolute times');
}

RawRr _raw(RrSeriesLike s) => RawRr.of(s.rr, s.ts);

RrSeriesLike _synth(int seed, double hours,
    {double noise = 0.5, double gaps = 12}) {
  final d = synthRr(SynthConfig(
      seed: seed,
      hours: hours,
      ectopicPerMin: 2,
      missedPerMin: 1,
      extraPerMin: 1,
      noiseRunPerMin: noise,
      gapPerHour: gaps));
  return (rr: d.rr, ts: d.ts);
}

RrSeriesLike _runs(int seed, List<int> segs, List<int> runs, {bool near = true}) {
  final (s, _) = withRuns(seed, segs, runs, nearRun: near);
  return (rr: s.rr, ts: s.ts);
}

void main() {
  final cases = <String, RrSeriesLike>{
    'synthetic, dirty': _synth(23, 0.1),
    'synthetic, calm, with dropouts': _synth(5, 0.1, noise: 0.05, gaps: 30),
    'one 40-beat run': _runs(7, [200, 200], [40]),
    'two long runs': _runs(8, [120, 120, 120], [33, 45]),
  };

  group('single pass = capped correctRr', () {
    for (final e in cases.entries) {
      test(e.key, () {
        final agg = _sandwich();
        _expectIsCorrectRr(agg.run(_raw(e.value)), e.value, e.key);
      });
    }

    test('empty and tiny inputs', () {
      for (final n in [0, 1, 2, 3, 5]) {
        final s = _synth(3, 0.05);
        final part = (rr: s.rr.sublist(0, n), ts: s.ts.sublist(0, n));
        _expectIsCorrectRr(_sandwich().run(_raw(part)), part, 'n=$n');
      }
    });

    test('maxArtifactRun: null is the uncapped corrector', () {
      final s = _runs(9, [150, 150], [40]);
      final got = _sandwich(maxArtifactRun: null).run(_raw(s));
      _expectIsCorrectRr(got, s, 'uncapped', cap: null);
    });
  });

  group('any chunking = one pass', () {
    forAll('random cuts (empty and one-beat chunks included), every path',
        G.intIn(1, 100000), (seed) {
      final s = _synth(seed, 0.07);
      final batch = _raw(s);
      final want = _oracle(s);
      final agg = _sandwich();
      final r = Rng(seed);
      for (var k = 0; k < 3; k++) {
        final bounds = randomBounds(r, batch.length);
        for (final (name, got) in [
          ('chunked', runChunked(agg, batch, bounds)),
          ('copies', runChunked(agg, batch, bounds, copy: true)),
          ('right', runChunkedRight(agg, batch, bounds)),
          ('sliced', runSliced(agg, batch, bounds)),
        ]) {
          expectBitIdentical(got.nnMs, want.nn, '$name $bounds nn');
          expectBitIdentical(got.timeMs, want.t, '$name $bounds t');
        }
      }
    }, cases: 25, budget: const Duration(seconds: 90));

    test('one-beat chunks, combined left and right', () {
      final s = _synth(31, 0.05);
      final batch = _raw(s);
      final agg = _sandwich();
      _expectIsCorrectRr(
          runChunked(agg, batch, singletonBounds(batch.length)), s, 'left');
      _expectIsCorrectRr(
          runChunkedRight(agg, batch, singletonBounds(batch.length)), s, 'right');
    });

    test('cuts inside, at the edges of and across a long artifact run', () {
      final (s, runs) = withRuns(41, [150, 150], [50], nearRun: true);
      final batch = RawRr.of(s.rr, s.ts);
      final (a, b) = runs.single;
      final agg = _sandwich();
      for (final cuts in [
        [a - 1, a, a + 1],
        [a + 10, a + 20, a + 33, a + 34],
        [b - 1, b, b + 1],
        [a - 60, a + 25, b + 60],
        [a + 1, a + 2, a + 3, a + 4, b - 2, b - 1],
      ]) {
        final bounds = [0, ...cuts, batch.length];
        final want = _oracle((rr: s.rr, ts: s.ts));
        for (final got in [
          runChunked(agg, batch, bounds),
          runChunkedRight(agg, batch, bounds),
          runSliced(agg, batch, bounds),
        ]) {
          expectBitIdentical(got.nnMs, want.nn, 'cuts $cuts nn');
          expectBitIdentical(got.timeMs, want.t, 'cuts $cuts t');
        }
      }
    });

    test('a cut at every beat of a dropout seam (the clock re-anchors)', () {
      final original = _synth(51, 0.06, gaps: 60);
      // A dropout rate is probabilistic; this seed currently draws none.
      // Insert a definite two-minute hole so this seam test always runs.
      final at = original.rr.length ~/ 2;
      final s = (rr: original.rr, ts: [
        for (var i = 0; i < original.ts.length; i++)
          original.ts[i] + (i >= at ? 120000 : 0),
      ]);
      final batch = _raw(s);
      final agg = _sandwich();
      final want = _oracle(s);
      var seams = 0;
      for (var i = 1; i < s.rr.length; i++) {
        if ((s.ts[i] - s.ts[i - 1]) - s.rr[i] > 1000) {
          seams++;
          final got = runChunked(agg, batch, [0, i - 1, i, i + 1, batch.length]);
          expectBitIdentical(got.timeMs, want.t, 'seam at $i t');
          expectBitIdentical(got.nnMs, want.nn, 'seam at $i nn');
        }
      }
      expect(seams, greaterThan(0), reason: 'the series must have dropouts');
    });
  });

  // Series much longer than the sandwich's head + tail windows, so most beats
  // are settled into `inner` and a seam is re-corrected from the windows alone.
  group('long series (settled middle in play)', () {
    final long = <String, RrSeriesLike>{
      'synthetic, dirty, long': _synth(11, 0.7),
      'synthetic, calm, long, dropouts': _synth(12, 2.0, noise: 0.05, gaps: 30),
      'runs over the cap, long': _runs(13, [700, 700, 700], [40, 50]),
    };

    for (final e in long.entries) {
      test('${e.key}: random cuts, every path', () {
        final batch = _raw(e.value);
        expect(batch.length, greaterThan(1200), reason: 'longer than the windows');
        final want = _oracle(e.value);
        final agg = _sandwich();
        _expectIsCorrectRr(agg.run(batch), e.value, 'one pass');
        final r = Rng(e.key.length);
        for (var k = 0; k < 4; k++) {
          final bounds = randomBounds(r, batch.length);
          for (final (name, got) in [
            ('chunked', runChunked(agg, batch, bounds)),
            ('copies', runChunked(agg, batch, bounds, copy: true)),
            ('right', runChunkedRight(agg, batch, bounds)),
            ('sliced', runSliced(agg, batch, bounds)),
          ]) {
            expectBitIdentical(got.nnMs, want.nn, '$name $bounds nn');
            expectBitIdentical(got.timeMs, want.t, '$name $bounds t');
          }
        }
      });
    }

    forAll('dense artifacts (ectopy, runs, dropouts), random cuts',
        G.intIn(1, 100000), (seed) {
      final s = _synth(seed, 0.5, noise: 1.5, gaps: 20);
      final batch = _raw(s);
      final want = _oracle(s);
      final agg = _sandwich();
      final bounds = randomBounds(Rng(seed), batch.length);
      final got = runChunked(agg, batch, bounds);
      expectBitIdentical(got.nnMs, want.nn, 'seed $seed $bounds nn');
      expectBitIdentical(got.timeMs, want.t, 'seed $seed $bounds t');
    }, cases: 12, budget: const Duration(seconds: 90));

    test('even chunks of many sizes, left and right', () {
      final s = long['synthetic, dirty, long']!;
      final batch = _raw(s);
      final agg = _sandwich();
      for (final size in [7, 100, 283, 284, 285, 560, 561, 1000]) {
        final bounds = [
          for (var i = 0; i < batch.length; i += size) i,
          batch.length,
        ];
        _expectIsCorrectRr(runChunked(agg, batch, bounds), s, 'size $size left');
        _expectIsCorrectRr(
            runChunkedRight(agg, batch, bounds), s, 'size $size right');
      }
    });

    test('one-beat chunks over a long series', () {
      final s = long['runs over the cap, long']!;
      final batch = _raw(s);
      final agg = _sandwich();
      _expectIsCorrectRr(
          runChunked(agg, batch, singletonBounds(batch.length)), s, 'left');
      _expectIsCorrectRr(runSliced(agg, batch, singletonBounds(batch.length)),
          s, 'sliced');
    });

    test('state size does not grow with the series', () {
      // a bounded inner (Count), so only the sandwich's own windows are sized
      final agg = RrSandwich<int, int>(const Count<Beats>());
      int chars(RrSeriesLike s) =>
          jsonEncode(agg.encodeState(agg.fold(_raw(s)))).length;
      final small = _synth(14, 1.4), big = _synth(14, 2.8);
      expect(big.rr.length, greaterThan(small.rr.length * 1.5));
      expect(chars(big), lessThan(chars(small) * 1.1 + 200));
    });
  });

  group('laws and persistence', () {
    final lawCases = <RawRr>[
      RawRr.of([], []),
      RawRr.of([800], [1.7e12]),
      _raw((rr: _synth(3, 0.05).rr.sublist(0, 3), ts: _synth(3, 0.05).ts.sublist(0, 3))),
      _raw(_synth(4, 0.04)),
      _raw(_runs(5, [100, 100], [36])),
      _raw(_runs(6, [300, 300], [36])),
    ];

    test('identity, split, associativity, singletons, slicing, finishPure, '
        'roundTrip', () {
      expectLawful<RrSandwichState<_Acc>, RawRr, Beats>(_sandwich(), lawCases,
          equals: _sameBeats);
    });

    test('is persistable', () {
      expect(_sandwich().persistable, isTrue);
    });

    test('checkpoints and resumes mid-stream (through JSON text)', () {
      final s = _runs(61, [160, 160], [45]);
      final batch = _raw(s);
      expectCheckpointResumes<RrSandwichState<_Acc>, RawRr, Beats>(
          _sandwich(), batch,
          equals: _sameBeats);
      final agg = _sandwich();
      final a = 160;
      for (final k in [0, 1, 50, a - 1, a + 1, a + 20, a + 33, a + 45, batch.length - 1, batch.length]) {
        final env = jsonDecode(jsonEncode(encodeCheckpoint(
            agg, agg.fold(batch, 0, k),
            kind: 'rr', version: 1)));
        final back = decodeCheckpoint<RrSandwichState<_Acc>>(agg, env,
            kind: 'rr', version: 1);
        expect(back, isNotNull, reason: 'restores at $k');
        final got = agg.finish(agg.addSlice(back!, batch, k, batch.length));
        _expectIsCorrectRr(got, s, 'resumed at $k');
      }
    });

    test('a checkpoint of the wrong kind or version is refused (null)', () {
      final agg = _sandwich();
      final batch = _raw(_synth(3, 0.05));
      final env = jsonDecode(jsonEncode(encodeCheckpoint(
          agg, agg.fold(batch, 0, 40),
          kind: 'rr', version: 1)));
      expect(decodeCheckpoint<RrSandwichState<_Acc>>(agg, env, kind: 'rr', version: 2),
          isNull);
      expect(decodeCheckpoint<RrSandwichState<_Acc>>(agg, {...env as Map, 'state': 'junk'},
          kind: 'rr', version: 1), isNull);
    });

    test('state is bounded: 10,000 artifact beats do not grow it', () {
      final r = Rng(71);
      final clean = cleanRr(r, 300);
      final rr = [...clean, ...List.filled(10000, 3000.0), ...cleanRr(r, 300)];
      final s = rrSeries(rr);
      final batch = RawRr.of(s.rr, s.ts);
      // Count: a bounded inner, so only the sandwich's own state is measured.
      final agg = RrSandwich<int, int>(const Count<Beats>());
      final mid = agg.fold(batch, 0, 300 + 10000);
      final text = jsonEncode(agg.encodeState(mid));
      expect(text.length, lessThan(80000), reason: 'state chars inside the run');
      final end = agg.finish(agg.addSlice(mid, batch, 10300, batch.length));
      final want = correctRr(s.rr, rrTsMs: s.ts);
      expect(end, want.nn.length);
      // combining two halves of the run keeps it bounded too
      final left = agg.fold(batch, 0, 5300), right = agg.fold(batch, 5300, batch.length);
      final merged = agg.combine(left, right);
      expect(jsonEncode(agg.encodeState(merged)).length, lessThan(80000));
      expect(agg.finish(merged), want.nn.length);
    });
  });

  group('A3: night aggregators fed through the sandwich', () {
    // The reference: capped correctRr's NN into the batch function.
    HrvTime hrvRef(RrSeriesLike s) {
      final o = _oracle(s);
      return hrvExpected(Beats(Float64List.fromList(o.nn), Float64List.fromList(o.t)),
          gapAware: true);
    }

    double? originOf(RrSeriesLike s) {
      final o = _oracle(s);
      return o.t.isEmpty ? null : o.t.first;
    }

    for (final e in cases.entries) {
      test('hrvTimeAggregator, ${e.key}', () {
        final batch = _raw(e.value);
        final agg = RrSandwich<dynamic, HrvTime>(
            hrvTimeAggregator(originMs: originOf(e.value)));
        final want = hrvRef(e.value);
        expectHrvParity(agg.run(batch), want, 'one pass');
        final r = Rng(e.key.length);
        for (var k = 0; k < 4; k++) {
          final bounds = randomBounds(r, batch.length);
          expectHrvParity(runChunked(agg, batch, bounds), want, 'chunks $bounds');
          expectHrvParity(runChunkedRight(agg, batch, bounds), want, 'right $bounds');
          expectHrvParity(runSliced(agg, batch, bounds), want, 'sliced $bounds');
        }
      });
    }

    List<Object?> exact(Metric<PrsaResult> m) => [
          m.present, m.tier, m.inputs_used.join(','), m.note,
          m.value?.anchors, m.value?.kind, m.value?.profile.length,
        ];
    List<Object?> near(Metric<PrsaResult> m) =>
        [m.value?.capacity, ...?m.value?.profile];
    bool same(Metric<PrsaResult> a, Metric<PrsaResult> b) =>
        fieldsEqual<Metric<PrsaResult>>(exact)(a, b) &&
        fieldsEqual<Metric<PrsaResult>>(near, relTol: 1e-9, absTol: 1e-9)(a, b) &&
        (a.confidence - b.confidence).abs() <= 1e-12;

    for (final dec in [true, false]) {
      for (final e in cases.entries) {
        test('prsaAggregator ${dec ? 'DC' : 'AC'}, ${e.key}', () {
          final batch = _raw(e.value);
          final agg = RrSandwich<dynamic, Metric<PrsaResult>>(
              NnColumn<dynamic, Metric<PrsaResult>>(
                  prsaAggregator(deceleration: dec)));
          final nn = correctRr(e.value.rr, rrTsMs: e.value.ts).nn;
          final want =
              dec ? decelerationCapacity(nn) : accelerationCapacity(nn);
          expect(same(agg.run(batch), want), isTrue, reason: 'one pass');
          final r = Rng(e.key.length + 1);
          for (var k = 0; k < 4; k++) {
            final bounds = randomBounds(r, batch.length);
            expect(same(runChunked(agg, batch, bounds), want), isTrue,
                reason: 'chunks $bounds');
            expect(same(runChunkedRight(agg, batch, bounds), want), isTrue,
                reason: 'right $bounds');
          }
        });
      }
    }

    // Series longer than the windows: the settled middle is in play.
    for (final e in {
      'synthetic, dirty, long': _synth(11, 0.7),
      'runs over the cap, long': _runs(13, [700, 700, 700], [40, 50]),
    }.entries) {
      test('hrvTimeAggregator and prsaAggregator, ${e.key}', () {
        final batch = _raw(e.value);
        expect(batch.length, greaterThan(1200));
        final hrv = RrSandwich<dynamic, HrvTime>(
            hrvTimeAggregator(originMs: originOf(e.value)));
        final prsa = RrSandwich<dynamic, Metric<PrsaResult>>(
            NnColumn<dynamic, Metric<PrsaResult>>(
                prsaAggregator(deceleration: true)));
        final wantPrsa = decelerationCapacity(_oracle(e.value).nn);
        final r = Rng(e.key.length + 2);
        final wantHrv = hrvRef(e.value);
        for (var k = 0; k < 3; k++) {
          final bounds = randomBounds(r, batch.length);
          expectHrvParity(runChunked(hrv, batch, bounds), wantHrv, 'hrv $bounds');
          expectHrvParity(
              runChunkedRight(hrv, batch, bounds), wantHrv, 'hrv right $bounds');
          expect(same(runChunked(prsa, batch, bounds), wantPrsa), isTrue,
              reason: 'prsa $bounds');
          expect(same(runChunkedRight(prsa, batch, bounds), wantPrsa), isTrue,
              reason: 'prsa right $bounds');
        }
      });
    }

    test('the sandwiched aggregators checkpoint and resume', () {
      final s = cases['one 40-beat run']!;
      final batch = _raw(s);
      final hrv = RrSandwich<dynamic, HrvTime>(
          hrvTimeAggregator(originMs: originOf(s)));
      expect(hrv.persistable, isTrue);
      expectCheckpointResumes<RrSandwichState<dynamic>, RawRr, HrvTime>(hrv, batch,
          equals: (a, b) => hrvEqAll(a, b));
      final prsa = RrSandwich<dynamic, Metric<PrsaResult>>(
          NnColumn<dynamic, Metric<PrsaResult>>(prsaAggregator(deceleration: true)));
      expect(prsa.persistable, isTrue);
    });
  });
}
