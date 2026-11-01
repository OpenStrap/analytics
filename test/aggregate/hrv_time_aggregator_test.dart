// hrvTimeAggregator (assembled from lawful blocks) must agree with hrvTime()
// for any beat series and any chunking or slicing, and obey the laws.
//
// Contract used here:
//  * gapAware (default): every beat carries its time; originMs is the first
//    beat's time. run(beats) == hrvTime(nn, nnTimesMs: times).value.
//  * gapAware false: times are ignored (they may even be NaN); run(beats) ==
//    hrvTime(nn).value, so sdann / sdnnIndex are null and seams are not
//    skipped.
//  * hrvTime returns an absent Metric below 2 beats. The aggregator then
//    reports nBeats = the beat count and null for every other field.
//  * originMs is needed as soon as a beat is binned; without it that is a
//    StateError. Empty input with a null origin is fine.

import 'package:openstrap_analytics/aggregate.dart';
import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

import '../support/checkpoint_support.dart';
import '../support/aggregator_laws.dart';
import '../support/hrv_beats.dart';
import '../support/property.dart' show Rng;

Aggregator<dynamic, Beats, HrvTime> _agg(Beats beats, {bool gapAware = true}) =>
    hrvTimeAggregator(
        originMs: gapAware ? hrvOrigin(beats) : null, gapAware: gapAware);

/// Every way of evaluating [bounds] against [want]: left-nested chunks (as
/// ranges and as copies), right-nested chunks, and one state sliced.
void _expectAllPaths(Aggregator<dynamic, Beats, HrvTime> agg, Beats beats,
    List<int> bounds, HrvTime want, String tag) {
  expectHrvParity(runChunked(agg, beats, bounds), want, '$tag chunks $bounds');
  expectHrvParity(runChunked(agg, beats, bounds, copy: true), want,
      '$tag copies $bounds');
  expectHrvParity(
      runChunkedRight(agg, beats, bounds), want, '$tag right $bounds');
  expectHrvParity(runSliced(agg, beats, bounds), want, '$tag sliced $bounds');
}

/// [segments] runs of 12 beats alternating 860/800 ms, each starting at 860,
/// with a 5 s hole between runs. Inside a run the diffs alternate -60/+60 (diff
/// acf strongly negative). Run k ends with a -60 diff and run k+1 opens with a
/// -60 diff, so a lag pair formed across the hole would be (-60, -60), a
/// positive product that drags acf1 up.
Beats _alternatingRuns(int segments) {
  final out = <Beat>[];
  var t = hrvT0;
  for (var s = 0; s < segments; s++) {
    for (var i = 0; i < 12; i++) {
      final nn = i.isEven ? 860.0 : 800.0;
      t += nn + (s > 0 && i == 0 ? 5000 : 0);
      out.add((nnMs: nn, timeMs: t));
    }
  }
  return hrvBeats(out);
}

void main() {
  group('named series', () {
    final named = <String, Beats>{
      'no beats': hrvBeats([]),
      'one beat': hrvBeats([(nnMs: 800.0, timeMs: hrvT0 + 800)]),
      'two beats': hrvSeries(Rng(1), 2, 0),
      'three beats': hrvSeries(Rng(2), 3, 0),
      '30 beats (29 diffs, acf1 absent)': hrvSeries(Rng(3), 30, 0, gapP: 0),
      '31 beats (30 diffs, acf1 present)': hrvSeries(Rng(4), 31, 0, gapP: 0),
      '60 smooth beats, no gaps': hrvSeries(Rng(5), 60, 0, gapP: 0),
      '300 white-noise beats (jitter floor nulls rmssd and pnn50)':
          hrvSeries(Rng(6), 300, 1, gapP: 0),
      'constant 1000 ms, 400 beats (zero variance, bin edge at beat 300)':
          hrvConstant(400, 1000),
      'constant 2000 ms, 400 beats (3 bins)': hrvConstant(400, 2000),
      'slow beats spanning many bins': hrvSeries(Rng(7), 380, 2, gapP: .02),
      'many holes': hrvSeries(Rng(8), 200, 0, gapP: .3),
      'alternating runs': _alternatingRuns(4),
      'RSA at a slow heart, exempt from the jitter floor':
          hrvSeries(Rng(61), 900, 3, gapP: 0),
      'RSA at a slow heart with holes': hrvSeries(Rng(62), 1500, 3, gapP: .004),
      'refused, published from a breathing line steady in Hz':
          hrvSeries(Rng(63), 4000, 4, gapP: 0),
      'a hole of several bins': hrvBeats([
        for (var i = 0; i < 40; i++)
          (nnMs: 800.0, timeMs: hrvT0 + (i + 1) * 800.0),
        (nnMs: 900.0, timeMs: hrvT0 + 40 * 800 + 900000),
        (nnMs: 910.0, timeMs: hrvT0 + 40 * 800 + 900910),
        (nnMs: 905.0, timeMs: hrvT0 + 40 * 800 + 901815),
      ]),
    };

    named.forEach((name, beats) {
      test('$name: gap aware matches hrvTime', () {
        final want = hrvExpected(beats, gapAware: true);
        final a = _agg(beats);
        expectHrvParity(a.run(beats), want, name);
        final r = Rng(name.hashCode & 0xffff);
        for (var t = 0; t < 3; t++) {
          _expectAllPaths(a, beats, randomBounds(r, beats.length), want, name);
        }
      });
      test('$name: gapAware false matches hrvTime without times', () {
        final want = hrvExpected(beats, gapAware: false);
        final a = _agg(beats, gapAware: false);
        expectHrvParity(a.run(beats), want, name);
        final r = Rng(name.hashCode & 0xfffe);
        _expectAllPaths(a, beats, randomBounds(r, beats.length), want, name);
      });
    });

    test('fewer than two beats: nBeats set, everything else null', () {
      for (final n in [0, 1]) {
        final beats = hrvSeries(Rng(n), n, 0);
        for (final ga in [true, false]) {
          final v = _agg(beats, gapAware: ga).run(beats);
          expect(v.nBeats, n);
          expect(hrvFields(v), everyElement(isNull));
        }
      }
    });

    test('hand-worked: nn 800, 810, 790 contiguous', () {
      final beats = hrvBeats([
        (nnMs: 800.0, timeMs: 1000.0),
        (nnMs: 810.0, timeMs: 1810.0),
        (nnMs: 790.0, timeMs: 2600.0),
      ]);
      final v = hrvTimeAggregator(originMs: 1000.0).run(beats);
      expect(v.nBeats, 3);
      // diffs 10, -20 -> rmssd sqrt((100+400)/2)
      expect(v.rmssd, closeTo(15.811388300841896, 1e-9));
      expect(v.pnn50, 0.0);
      expect(v.sdnn, closeTo(10.0, 1e-9));
      expect(v.diffAcf1, isNull); // fewer than 30 diffs
      expect(v.sdann, isNull); // a single 5-minute segment
      expect(v.sdnnIndex, isNull);
    });
  });

  group('below the jitter floor (the batch reads the difference runs)', () {
    test('the series reach the paths they name', () {
      final exempt = hrvTime(
          hrvSeries(Rng(61), 900, 3, gapP: 0).nnMs.toList(),
          nnTimesMs: hrvSeries(Rng(61), 900, 3, gapP: 0).timeMs.toList());
      expect(exempt.value!.diffAcf1, lessThan(kNnDiffAcf1Floor));
      expect(exempt.value!.rmssd, isNotNull);
      expect(exempt.note, startsWith('PRV not ECG-HRV'));
      final b = hrvSeries(Rng(63), 4000, 4, gapP: 0);
      final fallback = hrvTime(b.nnMs.toList(), nnTimesMs: b.timeMs.toList());
      expect(fallback.value!.diffAcf1, lessThan(kNnDiffAcf1Floor));
      expect(fallback.value!.rmssd, isNotNull);
      expect(fallback.note, contains('breathing line steady in Hz'));
      // Without times the same series is refused (no windows to fall back on).
      expect(hrvTime(b.nnMs.toList()).value!.rmssd, isNull);
    });

    test('random slow-heart and breathing-line series: whole, chunked, sliced',
        () {
      final r = Rng(0x5C14);
      for (var t = 0; t < 16; t++) {
        final mode = 3 + t % 2;
        final n = mode == 3 ? r.intIn(600, 1600) : r.intIn(3800, 4400);
        final beats = hrvSeries(r, n, mode, gapP: r.nextBool() ? 0 : .003);
        for (final ga in [true, false]) {
          final want = hrvExpected(beats, gapAware: ga);
          final a = _agg(beats, gapAware: ga);
          expectHrvParity(a.run(beats), want, 'case $t n=$n ga=$ga whole');
          _expectAllPaths(
              a, beats, randomBounds(r, n), want, 'case $t n=$n ga=$ga');
        }
      }
    });
  });

  group('random parity (seeded)', () {
    test('gap aware: whole series, chunked, sliced', () {
      final r = Rng(0x5C11);
      for (var t = 0; t < 40; t++) {
        final n = r.nextBool(.1) ? r.intIn(0, 3) : r.intIn(0, 400);
        final beats =
            hrvSeries(r, n, r.intIn(0, 2), gapP: r.nextBool() ? .02 : .15);
        final want = hrvExpected(beats, gapAware: true);
        final a = _agg(beats);
        expectHrvParity(a.run(beats), want, 'case $t n=$n whole');
        for (var c = 0; c < 2; c++) {
          _expectAllPaths(a, beats, randomBounds(r, n), want, 'case $t n=$n');
        }
      }
    });

    test('gapAware false (times present but ignored)', () {
      final r = Rng(0x5C12);
      for (var t = 0; t < 30; t++) {
        final n = r.intIn(0, 300);
        final beats = hrvSeries(r, n, r.intIn(0, 1));
        final want = hrvExpected(beats, gapAware: false);
        final a = _agg(beats, gapAware: false);
        expectHrvParity(a.run(beats), want, 'case $t whole');
        _expectAllPaths(a, beats, randomBounds(r, n), want, 'case $t');
      }
    });

    test('gapAware false with no times at all (NaN times)', () {
      final r = Rng(0x5C13);
      for (var t = 0; t < 20; t++) {
        final n = r.intIn(0, 250);
        final beats = hrvSeries(r, n, r.intIn(0, 1), withTimes: false);
        final want = hrvExpected(beats, gapAware: false);
        final a = hrvTimeAggregator(gapAware: false);
        _expectAllPaths(a, beats, randomBounds(r, n), want, 'case $t');
      }
    });

    test('every single split point (combine and slicing) of a series with '
        'holes and several bins', () {
      final beats = hrvSeries(Rng(31), 120, 2, gapP: .1);
      final want = hrvExpected(beats, gapAware: true);
      final a = _agg(beats);
      for (var k = 0; k <= beats.length; k++) {
        final s = a.combine(
            a.fold(beats, 0, k), a.fold(beats, k, beats.length));
        expectHrvParity(a.finish(s), want, 'split at $k');
        expectHrvParity(runSliced(a, beats, [0, k, beats.length]), want,
            'sliced at $k');
      }
    });

    test('splits on and around a 5-minute bin edge', () {
      final beats = hrvConstant(400, 1000);
      final want = hrvExpected(beats, gapAware: true);
      final a = _agg(beats);
      for (final k in [1, 2, 298, 299, 300, 301, 399]) {
        final s = a.combine(a.fold(beats, 0, k), a.fold(beats, k, 400));
        expectHrvParity(a.finish(s), want, 'split at $k');
        expectHrvParity(runSliced(a, beats, [0, k, 400]), want, 'sliced $k');
      }
    });

    test('one beat per chunk and per slice', () {
      final beats = hrvSeries(Rng(41), 80, 0, gapP: .1);
      final want = hrvExpected(beats, gapAware: true);
      final a = _agg(beats);
      final b = singletonBounds(beats.length);
      expectHrvParity(runChunked(a, beats, b), want, 'singleton chunks');
      expectHrvParity(runChunked(a, beats, b, copy: true), want, 'copies');
      expectHrvParity(runSliced(a, beats, b), want, 'singleton slices');
    });
  });

  group('gaps and lags', () {
    test('lag pairs are not formed across a gap', () {
      final beats = _alternatingRuns(4); // 44 diffs, seams dropped
      final want = hrvExpected(beats, gapAware: true);
      expect(want.diffAcf1, isNotNull);
      // The scenario discriminates: bridging the gap (ignoring times) moves acf1.
      final bridged = hrvExpected(beats, gapAware: false);
      expect((bridged.diffAcf1! - want.diffAcf1!).abs(), greaterThan(.02));
      final a = _agg(beats);
      expect(a.run(beats).diffAcf1, closeTo(want.diffAcf1!, 1e-9));
      // And in chunks and slices cut on and around the seams.
      for (final k in [11, 12, 13, 23, 24, 25, 35, 36, 37]) {
        final bounds = [0, k, beats.length];
        final s = a.combine(a.fold(beats, 0, k), a.fold(beats, k, beats.length));
        expect(a.finish(s).diffAcf1, closeTo(want.diffAcf1!, 1e-9),
            reason: 'split at $k');
        expect(runSliced(a, beats, bounds).diffAcf1, closeTo(want.diffAcf1!, 1e-9),
            reason: 'sliced at $k');
        expect(runChunked(a, beats, bounds, copy: true).diffAcf1,
            closeTo(want.diffAcf1!, 1e-9),
            reason: 'copies at $k');
      }
      // Three-way cuts that put whole runs apart.
      for (final b in [
        [0, 12, 24, 36, 48],
        [0, 11, 13, 25, 48],
        [0, 12, 12, 13, 36, 47, 48],
      ]) {
        _expectAllPaths(a, beats, b, want, 'runs');
      }
    });

    test('the hole rule: nn + 0.5 ms is contiguous, nn + 1.0 ms is a hole', () {
      // diffs +100 then -30: contiguous keeps both (pNN50 50 %); a hole drops
      // the -30 (pNN50 100 %).
      final edge = hrvBeats([
        (nnMs: 800.0, timeMs: 1000.0),
        (nnMs: 900.0, timeMs: 1900.5), // dt 900.5 = nn + 0.5
        (nnMs: 870.0, timeMs: 2771.0), // dt 870.5 = nn + 0.5
      ]);
      final hole = hrvBeats([
        (nnMs: 800.0, timeMs: 1000.0),
        (nnMs: 900.0, timeMs: 1900.5),
        (nnMs: 870.0, timeMs: 2772.0), // dt 871.5 > nn + 0.5
      ]);
      final a = hrvTimeAggregator(originMs: 1000.0);
      expect(a.run(edge).pnn50, 50.0);
      expect(a.run(hole).pnn50, 100.0);
      expect(a.run(edge).nBeats, 3);
      expect(a.run(hole).nBeats, 3);
      // The same across every cut, because the gap check reads times at the seam.
      for (final bounds in [
        [0, 1, 3],
        [0, 2, 3],
        [0, 1, 2, 3],
        [0, 0, 1, 1, 3, 3]
      ]) {
        expect(runChunked(a, edge, bounds).pnn50, 50.0, reason: 'edge $bounds');
        expect(runSliced(a, edge, bounds).pnn50, 50.0, reason: 'edge $bounds');
        expect(runChunked(a, hole, bounds, copy: true).pnn50, 100.0,
            reason: 'hole $bounds');
        expect(runSliced(a, hole, bounds).pnn50, 100.0, reason: 'hole $bounds');
      }
    });

    test('a contiguous seam with a hole in the gapAware false case is bridged',
        () {
      final hole = hrvBeats([
        (nnMs: 800.0, timeMs: 1000.0),
        (nnMs: 900.0, timeMs: 1900.5),
        (nnMs: 870.0, timeMs: 2772.0),
      ]);
      final a = hrvTimeAggregator(gapAware: false);
      expect(a.run(hole).pnn50, 50.0); // times ignored: both diffs count
      expect(a.run(hole).sdann, isNull);
      expect(a.run(hole).sdnnIndex, isNull);
    });
  });

  group('origin', () {
    test('a binned beat without an origin is a StateError', () {
      final beats = hrvSeries(Rng(51), 20, 0, gapP: 0);
      final a = hrvTimeAggregator(); // gapAware, no origin
      expect(() => a.run(beats), throwsStateError);
      expect(() => runChunked(a, beats, [0, 7, 20]), throwsStateError);
      expect(() => runSliced(a, beats, [0, 7, 20]), throwsStateError);
      expect(() => a.run(hrvBeats([(nnMs: 800.0, timeMs: hrvT0 + 800)])),
          throwsStateError);
    });

    test('empty input with a null origin is fine', () {
      final a = hrvTimeAggregator();
      final v = a.run(hrvBeats([]));
      expect(v.nBeats, 0);
      expect(hrvFields(v), everyElement(isNull));
      expect(a.finish(a.empty()).nBeats, 0);
      expect(a.finish(a.combine(a.empty(), a.empty())).nBeats, 0);
      expect(a.finish(a.fold(hrvSeries(Rng(52), 5, 0), 2, 2)).nBeats, 0);
    });

    test('gapAware false never needs an origin', () {
      final beats = hrvSeries(Rng(53), 50, 0);
      final v = hrvTimeAggregator(gapAware: false).run(beats);
      expect(v.nBeats, 50);
    });
  });

  test('persistable: a mid-stream checkpoint resumes to the one-pass result', () {
    final b = hrvSeries(Rng(0xC0DE), 90, 1, gapP: .08);
    expectCheckpointResumes(hrvTimeAggregator(originMs: hrvOrigin(b)), b,
        equals: hrvEqAll);
  });

  group('laws', () {
    List<Beats> cases(int seed, {int count = 8, int maxN = 120}) {
      final r = Rng(seed);
      return [
        hrvBeats([]),
        hrvSeries(Rng(seed), 1, 0),
        for (var i = 0; i < count; i++)
          hrvSeries(r, r.intIn(0, maxN), r.intIn(0, 2), gapP: .08),
      ];
    }

    test('below the jitter floor, gap aware and not, is lawful', () {
      final r = Rng(0x5D05);
      final group = [
        hrvSeries(Rng(61), 900, 3, gapP: 0),
        hrvSeries(r, 1200, 3, gapP: .004),
        hrvSeries(Rng(63), 4000, 4, gapP: 0),
      ];
      // These series are thousands of beats long (the exemption needs 20 Welch
      // segments in a run, the fallback 12 five-minute windows), so the split
      // and associativity laws are checked at 10 split points, not 64.
      for (final c in group) {
        for (final agg in [
          hrvTimeAggregator(originMs: hrvOrigin(c)),
          hrvTimeAggregator(gapAware: false),
        ]) {
          final v = checkLaws(agg, [c], equals: hrvEqAll, maxSplits: 10);
          expect(v, isEmpty,
              reason: v.map((x) => '${x.law}: ${x.detail}').join('\n'));
        }
      }
    });

    test('gap aware is lawful (cases grouped by origin)', () {
      final byOrigin = <double?, List<Beats>>{};
      for (final c in cases(0x5D01)) {
        (byOrigin[hrvOrigin(c)] ??= []).add(c);
      }
      byOrigin.forEach((origin, group) {
        expectLawful(hrvTimeAggregator(originMs: origin), group,
            equals: hrvEqAll);
      });
    });

    test('gap aware with a shared origin is lawful', () {
      final shifted = [for (final c in cases(0x5D02)) hrvShifted(c, 5000.0)];
      expectLawful(hrvTimeAggregator(originMs: 5000.0), shifted,
          equals: hrvEqAll);
    });

    test('gapAware false is lawful', () {
      expectLawful(hrvTimeAggregator(gapAware: false), cases(0x5D03),
          equals: hrvEqAll);
    });

    test('alternating runs are lawful at every split', () {
      final beats = _alternatingRuns(4);
      expectLawful(hrvTimeAggregator(originMs: hrvOrigin(beats)), [beats],
          equals: hrvEqAll);
    });
  });

  group('numerical stability', () {
    // The review's series: a steady 5 ms/beat ramp with a tiny odd-beat bump.
    // Diffs are ~5 +- 1e-8, so raw sums of d and d^2 cancel catastrophically
    // for the lag-1 autocorrelation; centred statistics do not.
    Beats ramp(double bump) => hrvBeats([
          for (var i = 0; i <= 100; i++)
            (nnMs: 800.0 + 5 * i + (i.isOdd ? bump : 0.0), timeMs: null),
        ]);

    test('1e-8 perturbation: acf1 within 1e-6 of hrvTime, same RMSSD nullness',
        () {
      final beats = ramp(1e-8);
      final want = hrvTime(beats.nnMs.toList()).value!;
      final got = hrvTimeAggregator(gapAware: false).run(beats);
      expect(want.diffAcf1, isNotNull);
      expect(got.diffAcf1, isNotNull, reason: 'aggregator acf1 is null');
      expect((got.diffAcf1! - want.diffAcf1!).abs(), lessThan(1e-6),
          reason: 'acf1 ${got.diffAcf1} vs ${want.diffAcf1}');
      expect(got.rmssd == null, want.rmssd == null,
          reason: 'rmssd ${got.rmssd} vs ${want.rmssd}');
    });

    test('1e-4 perturbation: whole vs split at 50 agree to 1e-9', () {
      final beats = ramp(1e-4);
      final agg = hrvTimeAggregator(gapAware: false);
      final whole = agg.run(beats);
      expect(whole.diffAcf1, isNotNull);
      for (final copy in [false, true]) {
        final split = runChunked(agg, beats, [0, 50, beats.length], copy: copy);
        expect(split.diffAcf1, isNotNull);
        expect((split.diffAcf1! - whole.diffAcf1!).abs(), lessThan(1e-9),
            reason: 'copy=$copy split ${split.diffAcf1} whole ${whole.diffAcf1}');
        expect(split.rmssd == null, whole.rmssd == null);
      }
    });
  });

  group('checkpoint relationships (beat counts across the children)', () {
    final beats = hrvSeries(Rng(0x4A7), 60, 1, gapP: .08);
    final agg = hrvTimeAggregator(originMs: hrvOrigin(beats));
    // State (version 2): [core, evidence]; core is [[diffs, lags], [levels,
    // bins]]; diffs and lags are Lookback states ({length, first, last,
    // inner}); levels is a Moments map and bins is {fiveMinuteBin: Moments};
    // evidence is the jitter-gate evidence map.
    List core(Object? s) => (s as List)[0] as List;
    Map diffs(Object? s) => (core(s)[0] as List)[0] as Map;
    Map lags(Object? s) => (core(s)[0] as List)[1] as Map;
    Map levels(Object? s) => (core(s)[1] as List)[0] as Map;
    Map bins(Object? s) => (core(s)[1] as List)[1] as Map;
    Map evidence(Object? s) => (s as List)[1] as Map;

    test('both lookbacks must have seen the same number of beats', () {
      expectDamagedCheckpointRefused(agg, beats, (s) {
        lags(s)['length'] = 61;
        return s;
      });
    });
    test('more level samples than beats is refused', () {
      expectDamagedCheckpointRefused(agg, beats, (s) {
        levels(s)['count'] = 70;
        return s;
      });
    });
    test('five-minute bin counts must add up to the level count', () {
      expectDamagedCheckpointRefused(agg, beats, (s) {
        final first = bins(s).values.first as Map;
        first['count'] = (first['count'] as int) + 1;
        return s;
      });
    });
    test('more successive differences than beat pairs is refused', () {
      expectDamagedCheckpointRefused(agg, beats, (s) {
        final inner = diffs(s)['inner'] as Map;
        inner['pairs'] = 60;
        inner['over50'] = 0;
        return s;
      });
    });
    test('more lag pairs than beat triples is refused', () {
      expectDamagedCheckpointRefused(agg, beats, (s) {
        (lags(s)['inner'] as Map)['pairs'] = 59;
        return s;
      });
    });
    test('a version 1 checkpoint (no jitter evidence) is refused whole', () {
      expectDamagedCheckpointRefused(agg, beats, (s) => core(s));
    });
    test('evidence of another type or version is refused', () {
      expectDamagedCheckpointRefused(agg, beats, (s) {
        evidence(s)['version'] = 2;
        return s;
      });
      expectDamagedCheckpointRefused(agg, beats, (s) {
        evidence(s)['type'] = 'Other';
        return s;
      });
    });
    test('evidence counting other beats or differences than the core', () {
      expectDamagedCheckpointRefused(agg, beats, (s) {
        evidence(s)['n'] = (evidence(s)['n'] as int) - 1;
        return s;
      });
      expectDamagedCheckpointRefused(agg, beats, (s) {
        evidence(s)['nd'] = (evidence(s)['nd'] as int) - 1;
        return s;
      });
    });
    test('evidence whose parts disagree is refused', () {
      for (final damage in <void Function(Map)>[
        (e) => (e['head'] as Map)['len'] = ((e['head'] as Map)['len'] as int) + 1,
        (e) => (e['head'] as Map)['anchored'] = true,
        (e) => (e['head'] as Map)['phases'] = <Object?>[],
        (e) => ((e['head'] as Map)['cnt'] as List)[0] = 9999,
        (e) => (e['wins'] as List).removeLast(),
        (e) => e['headRun'] = null,
        (e) => e['winNd'] = (e['nd'] as int) + 1,
      ]) {
        expectDamagedCheckpointRefused(agg, beats, (s) {
          damage(evidence(s));
          return s;
        });
      }
    });
    test('a consistent checkpoint restores', () {
      expect(
          decodeCheckpoint<dynamic>(agg, checkpointOf(agg, beats),
              kind: 'test', version: 1),
          isNotNull);
    });
  });
}
