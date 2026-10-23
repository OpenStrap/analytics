// timeInZoneAggregator must agree with HeartRateZones.timeInZone for the same
// (time-sorted) rows under any slicing or chunking, and obey the aggregator
// laws.
//
// Contract used here (docs: r6-time-in-zone.md):
//  * HrStream(Float64List tsMs, Float64List hr) is a Batch<HrStream>; rows are
//    sorted by tsMs; a row is valid when hr > 0 (as HrSample.valid).
//  * timeInZoneAggregator(zoneSet) is an
//    Aggregator<_, HrStream, TimeInHeartRateZone?>, all exported from
//    package:openstrap_analytics/aggregate.dart.
//  * The result is null exactly when HeartRateZones.timeInZone is null (the
//    sampleCadenceSeconds rule, including fewer than 2 rows). Otherwise every
//    zone's seconds and belowZone1 are within relTol 1e-12 / absTol 1e-9.
//  * The median m is bit-identical to sampleCadenceSeconds'. Pinned here by
//    streams whose only valid row is the LAST one: the only credit is the tail,
//    so the zone total is m, compared with == (a single add to 0.0 is exact).
//  * HOOK the implementer must add, exported from the same library:
//      int timeInZoneStateEntries(Object? state)
//    = total number of histogram entries (all histograms, all zones) held by a
//    state returned by agg.fold(...). Must not throw on agg.empty() (returns 0
//    or a small number).
//  * Duplicate-timestamp rows in the LARGE random streams carry the same hr as
//    the row they duplicate: the reference re-sorts with an unstable sort, so
//    tie order (and so which hr gets the fallback credit) is only defined for
//    streams of <= 32 rows. The hand-written duplicate case uses 5 rows with
//    differing hr.

import 'dart:typed_data';

import 'package:openstrap_analytics/aggregate.dart';
import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

import '../support/checkpoint_support.dart';
import '../support/aggregator_laws.dart';
import '../support/property.dart' show Rng;

typedef _Agg = Aggregator<dynamic, HrStream, TimeInHeartRateZone?>;

final HeartRateZoneSet _zones = HeartRateZones.zonesFromMaxHr(200);
final _Agg _agg = timeInZoneAggregator(_zones);

List<Object?> _fields(TimeInHeartRateZone? t) =>
    t == null ? [null] : [...t.seconds, t.belowZone1];

final _eq = fieldsEqual<TimeInHeartRateZone?>(_fields,
    relTol: 1e-12, absTol: 1e-9);

/// A raw stream: timestamps in ms and hr.
class _S {
  _S(this.ts, this.hr);
  final List<double> ts;
  final List<double> hr;
  int get n => ts.length;
  HrStream get stream =>
      HrStream(Float64List.fromList(ts), Float64List.fromList(hr));
  List<HrSample> get samples =>
      [for (var i = 0; i < n; i++) HrSample(ts[i], hr[i])];
  double? get cadence =>
      sampleCadenceSeconds([for (final t in ts) t / 1000.0]);
}

TimeInHeartRateZone? _want(_S s) =>
    HeartRateZones.timeInZone(s.samples, _zones);

void _same(TimeInHeartRateZone? got, TimeInHeartRateZone? want, String tag) {
  expect(_eq(got, want), isTrue,
      reason: '$tag\n got ${_fields(got)}\nwant ${_fields(want)}');
  expect(got == null, want == null, reason: '$tag null-ness');
}

/// Every way of evaluating the aggregator against the reference.
void _allPaths(_S s, List<int> b, String tag) {
  final want = _want(s);
  final st = s.stream;
  _same(_agg.run(st), want, '$tag whole');
  _same(runChunked(_agg, st, b), want, '$tag chunks $b');
  _same(runChunked(_agg, st, b, copy: true), want, '$tag copies $b');
  _same(runChunkedRight(_agg, st, b), want, '$tag right $b');
  _same(runSliced(_agg, st, b), want, '$tag sliced $b');
}

void _parity(_S s, String tag, Rng r) {
  for (var k = 0; k < 3; k++) {
    _allPaths(s, randomBounds(r, s.n), tag);
  }
  _allPaths(s, singletonBounds(s.n), '$tag singletons');
}

// ---- generators ------------------------------------------------------------

/// A bpm that hits every zone, the boundaries exactly, off-skin and above max.
double _bpm(Rng r) {
  final k = r.nextDouble();
  if (k < .08) return 0;
  if (k < .30) {
    final z = _zones.zones[r.intIn(0, 4)];
    return r.nextBool() ? z.lower : z.upper;
  }
  if (k < .38) return 205 + r.nextDouble() * 30; // above zone 5
  if (k < .46) return 30 + r.nextDouble() * 60; // below zone 1
  return 90 + r.nextDouble() * 110;
}

/// [n] rows at nominal [stepMs] with [jitterMs] jitter, a [dropP] chance of a
/// long [dropMs] gap, a [dupP] chance of a repeated timestamp (same hr, see
/// the header), an [offP] chance of an off-skin row.
_S _gen(Rng r, int n,
    {double stepMs = 1000,
    int jitterMs = 20,
    double dropP = 0,
    double dropMs = 600000,
    double dupP = 0,
    double offP = 0,
    bool fractional = false}) {
  final ts = <double>[];
  final hr = <double>[];
  var t = 1.7e12 + r.intIn(0, 999999);
  for (var i = 0; i < n; i++) {
    if (i > 0 && r.nextBool(dupP)) {
      ts.add(ts.last);
      hr.add(hr.last);
      continue;
    }
    if (i > 0) {
      t += r.nextBool(dropP)
          ? dropMs
          : stepMs + r.intIn(-jitterMs, jitterMs) +
              (fractional ? r.nextDouble() : 0);
    }
    ts.add(t);
    hr.add(r.nextBool(offP) ? 0 : _bpm(r));
  }
  return _S(ts, hr);
}

/// The input families of the spec, by name.
Map<String, _S Function(Rng, int)> _families() => {
      '1 Hz jitter': (r, n) => _gen(r, n),
      '1 Hz fractional ms': (r, n) => _gen(r, n, fractional: true),
      'dropouts': (r, n) => _gen(r, n, dropP: .05),
      'duplicate timestamps': (r, n) => _gen(r, n, dupP: .15),
      'off-skin rows': (r, n) => _gen(r, n, offP: .3),
      'slow 5 s device': (r, n) => _gen(r, n, stepMs: 5000, jitterMs: 100),
      'dropouts + dups + off-skin': (r, n) =>
          _gen(r, n, dropP: .05, dupP: .1, offP: .15, fractional: true),
      'cadence > 300 s': (r, n) => _gen(r, n, stepMs: 400000, jitterMs: 1000),
      'fails the mode rule': (r, n) {
        // Gaps cycle 1 s, 4 s, 10 s: median 4 s, only a third within 2x.
        if (n == 0) return _S([], []);
        final ts = <double>[1.7e12];
        for (var i = 1; i < n; i++) {
          ts.add(ts.last + const [1000.0, 4000.0, 10000.0][i % 3]);
        }
        return _S(ts, [for (var i = 0; i < n; i++) _bpm(r)]);
      },
    };

void main() {
  group('hand-worked', () {
    test('one row, empty: null', () {
      expect(_agg.run(HrStream(Float64List(0), Float64List(0))), isNull);
      expect(_agg.run(_S([5000], [120]).stream), isNull);
      expect(_want(_S([5000], [120])), isNull);
      expect(_agg.finish(_agg.empty()), isNull);
    });
    test('two rows: the tail gets m', () {
      final s = _S([0, 1000], [110, 130]);
      final want = _want(s)!;
      final got = _agg.run(s.stream)!;
      _same(got, want, 'two rows');
      expect(got.secondsInZone(1), closeTo(1, 1e-12));
      expect(got.secondsInZone(2), closeTo(1, 1e-12));
    });
    test('two rows, equal timestamps: no positive gap, null', () {
      final s = _S([1000, 1000], [110, 130]);
      expect(_want(s), isNull);
      expect(_agg.run(s.stream), isNull);
    });
    test('five regular rows, one per zone', () {
      final s = _S([0, 60000, 120000, 180000, 240000],
          [110, 130, 150, 170, 190]);
      final got = _agg.run(s.stream)!;
      for (var z = 1; z <= 5; z++) {
        expect(got.secondsInZone(z), closeTo(60, 1e-9));
      }
      expect(got.belowZone1, 0);
    });
    test('long gap is capped at m; duplicate (gap 0) gets m', () {
      final s = _S([0, 1000, 2000, 2000, 700000], [130, 150, 190, 130, 190]);
      _same(_agg.run(s.stream), _want(s), 'capped');
      for (final b in [
        [0, 5],
        [0, 2, 3, 5],
        [0, 1, 1, 4, 5],
        [0, 3, 4, 4, 5]
      ]) {
        _same(runChunked(_agg, s.stream, b), _want(s), 'chunks $b');
        _same(runSliced(_agg, s.stream, b), _want(s), 'sliced $b');
      }
    });
    test('zone boundaries: exactly lower / upper, above zone 5, below zone 1',
        () {
      final hr = <double>[
        for (final z in _zones.zones) ...[z.lower, z.upper],
        _zones.maxHr + 40,
        _zones.zones.first.lower - 0.5,
        0,
      ];
      final s = _S([for (var i = 0; i < hr.length; i++) i * 1000.0], hr);
      final want = _want(s)!;
      _same(_agg.run(s.stream), want, 'boundaries');
      expect(want.belowZone1, greaterThan(0));
      expect(want.seconds[4], greaterThan(0));
      for (final b in [
        [0, hr.length],
        [0, 1, 2, 5, hr.length],
        [0, 4, 4, hr.length]
      ]) {
        _same(runChunked(_agg, s.stream, b), want, 'chunks $b');
        _same(runSliced(_agg, s.stream, b), want, 'sliced $b');
      }
    });
  });

  group('null exactly when the reference is null', () {
    test('> 300 s cadence', () {
      final s = _gen(Rng(1), 12, stepMs: 400000, jitterMs: 1000);
      expect(_want(s), isNull);
      _parity(s, '>300', Rng(2));
      expect(_agg.run(s.stream), isNull);
    });
    test('stream failing the mode rule', () {
      final s = _families()['fails the mode rule']!(Rng(3), 30);
      expect(_want(s), isNull);
      _parity(s, 'mode', Rng(4));
      expect(_agg.run(s.stream), isNull);
    });
    test('exactly 300 s cadence is accepted, 301 s is not', () {
      final ok = _S([for (var i = 0; i < 6; i++) i * 300000.0],
          [100, 120, 140, 160, 180, 100]);
      final no = _S([for (var i = 0; i < 6; i++) i * 301000.0],
          [100, 120, 140, 160, 180, 100]);
      expect(_want(ok), isNotNull);
      expect(_want(no), isNull);
      _parity(ok, '300', Rng(5));
      _parity(no, '301', Rng(6));
    });
    test('all timestamps identical: null', () {
      final s = _S([5, 5, 5, 5], [100, 100, 100, 100]);
      expect(_want(s), isNull);
      _parity(s, 'dups', Rng(7));
    });
  });

  group('random parity (seeded)', () {
    var fam = 0;
    _families().forEach((name, make) {
      final seed = 0x7a11 + fam++;
      test(name, () {
        final r = Rng(seed);
        var nonNull = 0;
        for (var t = 0; t < 14; t++) {
          final n = r.nextBool(.2) ? r.intIn(0, 4) : r.intIn(5, 160);
          final s = make(r, n);
          if (_want(s) != null) nonNull++;
          _parity(s, '$name t$t n=$n', r);
        }
        if (!name.contains('>') && !name.contains('mode')) {
          expect(nonNull, greaterThan(5), reason: 'generator too degenerate');
        }
      });
    });

    test('one-row and two-row chunks of a long stream', () {
      final r = Rng(0x51);
      final s = _gen(r, 90, dropP: .05, offP: .1, fractional: true);
      for (final b in [
        [0, 1, 2, 90],
        [0, 88, 89, 90],
        [0, 45, 45, 45, 90],
        [0, 0, 90, 90],
      ]) {
        _allPaths(s, b, 'edge $b');
      }
    });
  });

  group('cadence median is bit-identical to sampleCadenceSeconds', () {
    // Only the last row is valid, so the sole credit is the tail: the zone
    // total is exactly m (0.0 + m), compared with == on the double.
    double total(TimeInHeartRateZone t) =>
        t.seconds.fold<double>(t.belowZone1, (a, b) => a + b);

    _S tailOnly(Rng r, int n, {bool fractional = true, double step = 1000}) {
      final s = _gen(r, n,
          stepMs: step, jitterMs: 37, dropP: .05, fractional: fractional);
      for (var i = 0; i < n - 1; i++) {
        s.hr[i] = 0;
      }
      s.hr[n - 1] = 140;
      return s;
    }

    test('tail seconds == sampleCadenceSeconds, random streams and cuts', () {
      final r = Rng(0xb17);
      var checked = 0;
      for (var t = 0; t < 40; t++) {
        // Both even and odd gap counts (interpolated and exact medians).
        final n = 2 + r.intIn(0, 120);
        final s = tailOnly(r, n, step: r.nextBool() ? 1000 : 5000);
        final m = s.cadence;
        if (m == null) continue;
        checked++;
        final st = s.stream;
        final b = randomBounds(r, n);
        expect(total(_agg.run(st)!) == m, isTrue,
            reason: 't$t whole ${total(_agg.run(st)!)} vs $m');
        expect(total(runChunked(_agg, st, b)!) == m, isTrue,
            reason: 't$t chunks $b');
        expect(total(runChunked(_agg, st, b, copy: true)!) == m, isTrue,
            reason: 't$t copies $b');
        expect(total(runChunkedRight(_agg, st, b)!) == m, isTrue,
            reason: 't$t right $b');
        expect(total(runSliced(_agg, st, b)!) == m, isTrue,
            reason: 't$t sliced $b');
      }
      expect(checked, greaterThan(25));
    });

    test('even gap count: the interpolated median, odd: the middle gap', () {
      // gaps 1,2 -> 1.5 ; gaps 1,2,3 -> 2 (all inside the mode window).
      final even = _S([0, 1000, 3000], [0, 0, 150]);
      expect(total(_agg.run(even.stream)!) == 1.5, isTrue);
      final odd = _S([0, 1000, 3000, 6000], [0, 0, 0, 150]);
      expect(total(_agg.run(odd.stream)!) == 2.0, isTrue);
      expect(even.cadence, 1.5);
      expect(odd.cadence, 2.0);
    });
  });

  group('state size', () {
    test('10,000 rows at 1 Hz with +-20 ms jitter: < 400 histogram entries',
        () {
      final r = Rng(0x5eed);
      final s = _gen(r, 10000);
      final entries = timeInZoneStateEntries(_agg.fold(s.stream));
      expect(entries, lessThan(400));
      expect(entries, greaterThan(0));
      _same(_agg.run(s.stream), _want(s), 'big');
    });
    test('does not grow with rows: 40,000 rows, 7 chunks combined', () {
      final r = Rng(0x5eee);
      final s = _gen(r, 40000);
      final st = s.stream;
      final b = [0, 5000, 5001, 12000, 20000, 20000, 33333, 40000];
      var acc = _agg.fold(st, b[0], b[1]);
      for (var k = 1; k + 1 < b.length; k++) {
        acc = _agg.combine(acc, _agg.fold(st, b[k], b[k + 1]));
      }
      expect(timeInZoneStateEntries(acc), lessThan(400));
      _same(_agg.finish(acc), _want(s), 'combined');
    });
    test('empty state is tiny', () {
      expect(timeInZoneStateEntries(_agg.empty()), lessThan(10));
    });
  });

  test('persistable: a mid-stream checkpoint resumes to the one-pass result', () {
    expectCheckpointResumes(_agg, _gen(Rng(0xC0DE), 45, dropP: .1, offP: .2).stream,
        equals: _eq);
  });

  group('lawful', () {
    final r = Rng(0x1a3);
    final cases = <HrStream>[
      HrStream(Float64List(0), Float64List(0)),
      _S([1000], [120]).stream,
      _S([0, 1000], [120, 0]).stream,
      _S([0, 1000], [0, 150]).stream,
      _S([0, 0], [100, 100]).stream,
      _gen(r, 30).stream,
      _gen(r, 45, dropP: .1, offP: .2).stream,
      _gen(r, 45, dupP: .2, fractional: true).stream,
      _gen(r, 25, stepMs: 5000, jitterMs: 100).stream,
      _families()['fails the mode rule']!(r, 25).stream,
      for (var i = 0; i < 15; i++) _gen(r, r.intIn(0, 40), offP: .1).stream,
    ];
    test('every law holds', () => expectLawful(_agg, cases, equals: _eq));
  });

  group('checkpoint histograms are consistent with the stored rows', () {
    // Three rows one second apart at 150 bpm: two pairs, one tail.
    final three = _S([0, 1000, 2000], [150, 150, 150]).stream;
    // One row: no pairs, only a tail.
    final one = _S([5000], [150]).stream;
    // Two rows: one pair.
    final two = _S([0, 1000], [150, 150]).stream;

    // State: {windows: {length, first, last, inner: {cadence, credits}},
    //         hasTail, tailTimestampMs, tailHr}. Histograms are [[gap, n], ..].
    Map inner(Object? s) => ((s as Map)['windows'] as Map)['inner'] as Map;
    List cadence(Object? s) => inner(s)['cadence'] as List;
    List credits(Object? s) => inner(s)['credits'] as List;
    // The (single) non-empty credit histogram.
    List credit(Object? s) =>
        credits(s).cast<List>().firstWhere((h) => h.isNotEmpty);

    void refuses(HrStream batch, void Function(Object? s) damage,
        [String? why]) {
      expectDamagedCheckpointRefused(_agg, batch, (s) {
        damage(s);
        return s;
      }, reason: why);
    }

    test('a good checkpoint has the shape these tests damage', () {
      final s = checkpointOf(_agg, three)['state'];
      expect(cadence(s), [
        [1.0, 2]
      ]);
      expect(credit(s), [
        [1.0, 2]
      ]);
    });

    test('review case: histogram multiplicities inflated past the pairs', () {
      refuses(two, (s) => cadence(s)[0][1] = 300);
      refuses(two, (s) => credit(s)[0][1] = 300);
      refuses(three, (s) => cadence(s)[0][1] = 3);
      refuses(three, (s) => credit(s)[0][1] = 3);
    });
    test('credits spread over several zones still sum to at most the pairs',
        () {
      refuses(three, (s) {
        // Two pairs exist; 1 + 2 credits across two zones is three.
        final h = credit(s);
        final other = credits(s).cast<List>().firstWhere((x) => x.isEmpty);
        h[0][1] = 2;
        other.add([1.0, 1]);
      });
    });
    test('totals at exactly the pairs are accepted', () {
      for (final batch in [two, three]) {
        final good = checkpointOf(_agg, batch);
        expect(decodeCheckpoint<dynamic>(_agg, good, kind: 'test', version: 1),
            isNotNull);
      }
    });
    test('counts whose sum overflows an int are refused', () {
      refuses(three, (s) {
        cadence(s)
          ..[0][1] = 0x7fffffffffffffff
          ..add([2.0, 5]);
      });
      refuses(three, (s) {
        credit(s)
          ..[0][1] = 0x7fffffffffffffff
          ..add([2.0, 5]);
      });
    });
    test('a histogram with one row behind it must be empty (no pairs)', () {
      refuses(one, (s) => cadence(s).add([1.0, 1]));
      refuses(one, (s) => credits(s)[0].add([1.0, 1]));
      final empty = HrStream(Float64List(0), Float64List(0));
      expect(decodeCheckpoint<dynamic>(
          _agg, checkpointOf(_agg, empty), kind: 'test', version: 1),
          isNotNull);
    });

    test('review case: cadence [["NaN", 2]] is refused', () {
      refuses(three, (s) => cadence(s)
        ..clear()
        ..add(['NaN', 2]));
    });
    test('cadence keys must be finite and positive', () {
      for (final key in ['NaN', 'Infinity', '-Infinity', 0.0, -1.0, -0.5]) {
        refuses(three, (s) => cadence(s)[0][0] = key, 'cadence key $key');
      }
    });
    test('credit keys must be finite; zero and negative are fine', () {
      for (final key in ['NaN', 'Infinity', '-Infinity']) {
        refuses(three, (s) => credit(s)[0][0] = key, 'credit key $key');
      }
      // A zero or negative gap credits one cadence (the fallback), so these
      // are reachable from non-monotonic timestamps and must still restore.
      final back = _S([2000, 1000], [150, 150]).stream; // gap -1 s
      final dup = _S([1000, 1000], [150, 150]).stream; // gap 0
      for (final batch in [back, dup]) {
        final good = checkpointOf(_agg, batch);
        expect(decodeCheckpoint<dynamic>(_agg, good, kind: 'test', version: 1),
            isNotNull);
      }
    });

    test('the tail exists exactly when there are rows', () {
      refuses(three, (s) => (s as Map)['hasTail'] = false);
      refuses(two, (s) => (s as Map)['hasTail'] = false);
      refuses(one, (s) => (s as Map)['hasTail'] = false);
      final empty = HrStream(Float64List(0), Float64List(0));
      refuses(empty, (s) => (s as Map)['hasTail'] = true);
    });
  });
}
