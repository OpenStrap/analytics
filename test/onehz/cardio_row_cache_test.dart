// Exact cardio epoch-row cache (round 16) - RED until the implementation lands.
//
// Spec: openstrap-analytics.research/r16-row-cache.md. The contract is that a
// `CardioRowCache` passed as `rowCache:` to segmentSleep changes NOTHING about
// the output (bit-identical to no cache, every field), only how many epoch rows
// are recomputed.
//
// DECISIONS (pinned here; the implementer may not change the assertions):
//  * `CardioRowCache.fromJson` THROWS FormatException on malformed input and on
//    a missing / non-matching `version` field. It never returns a cache holding
//    guessed rows. (Callers that want "empty cache on failure" catch it.)
//  * `hits` / `misses` may be cumulative over the cache's life; the tests only
//    ever use deltas around one call.
//  * `CardioRowKey` exposes `startSec` (absolute epoch start, the session
//    clock) and `epochSec`. These two names are the only key members used here
//    (retainWhere predicates). Everything else about the key is opaque.
//  * Change detection is checked as: the changed sample forces at least one
//    miss, and every epoch whose full context (own epoch +- 150 s, plus one
//    epoch of slack for window edges) cannot contain it still hits.
//  * "Most epochs hit when only the end moved" = hits >= 80 % of the epochs the
//    first run staged that still lie inside the second session.
//
// Synthetic data: a few hours at 1 Hz for forced-window cases; ONE full night
// for the auto-detect case.

import 'dart:convert';
import 'dart:math' as math;

import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

const int t0 = 1700000000; // absolute seconds, record start

class Night {
  final List<AccelSample> accel;
  final List<double> hr;
  final List<double> rr;
  final List<double> rrTs;
  Night(this.accel, this.hr, this.rr, this.rrTs);

  /// Samples with absolute second in [a, b).
  Night slice(int a, int b) {
    final ai = <AccelSample>[];
    final hi = <double>[];
    for (var i = 0; i < accel.length; i++) {
      final s = accel[i].tsMs ~/ 1000;
      if (s >= a && s < b) {
        ai.add(accel[i]);
        hi.add(hr[i]);
      }
    }
    final r = <double>[], rt = <double>[];
    for (var i = 0; i < rr.length; i++) {
      final s = rrTs[i] ~/ 1000;
      if (s >= a && s < b) {
        r.add(rr[i]);
        rt.add(rrTs[i]);
      }
    }
    return Night(ai, hi, r, rt);
  }

  /// Drop accel+hr positions and/or RR beats whose absolute second is in a
  /// range (accel gaps are holes in the positional arrays, like real syncs).
  Night withGaps({
    List<(int, int)> accelGaps = const [],
    List<(int, int)> rrGaps = const [],
  }) {
    bool inAny(List<(int, int)> g, int s) =>
        g.any((r) => s >= r.$1 && s < r.$2);
    final ai = <AccelSample>[];
    final hi = <double>[];
    for (var i = 0; i < accel.length; i++) {
      if (inAny(accelGaps, accel[i].tsMs ~/ 1000)) continue;
      ai.add(accel[i]);
      hi.add(hr[i]);
    }
    final r = <double>[], rt = <double>[];
    for (var i = 0; i < rr.length; i++) {
      if (inAny(rrGaps, rrTs[i] ~/ 1000)) continue;
      r.add(rr[i]);
      rt.add(rrTs[i]);
    }
    return Night(ai, hi, r, rt);
  }

  Night copy() => Night(List.of(accel), List.of(hr), List.of(rr), List.of(rrTs));
}

/// head minutes active, still minutes asleep, tail minutes active.
Night genNight(int seed,
    {int headMin = 40, int stillMin = 150, int tailMin = 30, int start = t0}) {
  final rnd = math.Random(seed);
  final headS = headMin * 60, stillS = stillMin * 60, tailS = tailMin * 60;
  final n = headS + stillS + tailS;
  final accel = <AccelSample>[];
  final hr = <double>[];
  final rr = <double>[];
  final rrTs = <double>[];
  var hrBase = 50.0;
  var moveLeft = 0;
  var zBase = 1.0;
  for (var i = 0; i < n; i++) {
    final ts = (start + i) * 1000.0;
    final active = i < headS || i >= headS + stillS;
    double x, y = 0, z;
    double h;
    if (active) {
      x = i.isEven ? 0.0 : 0.25;
      z = 0.97;
      h = 76 + (rnd.nextDouble() - 0.5) * 6;
    } else {
      if (rnd.nextInt(900) == 0) zBase = 0.97 + rnd.nextDouble() * 0.06;
      if (moveLeft == 0 && rnd.nextInt(600) == 0) moveLeft = 5 + rnd.nextInt(30);
      x = (rnd.nextDouble() - 0.5) * 0.002;
      z = zBase + (rnd.nextDouble() - 0.5) * 0.002;
      if (moveLeft > 0) {
        x += rnd.nextDouble() * 0.3;
        y += rnd.nextDouble() * 0.2;
        moveLeft--;
      }
      if (rnd.nextInt(1500) == 0) hrBase = 47 + rnd.nextDouble() * 10;
      h = hrBase +
          3 * math.sin(2 * math.pi * i / 5400.0) +
          (rnd.nextDouble() - 0.5) * 3 +
          (moveLeft > 0 ? 10 : 0);
    }
    accel.add(AccelSample(ts, x, y, z));
    hr.add(h);
    final nb = (h / 60).round();
    for (var b = 0; b < nb; b++) {
      rr.add(60000.0 / h +
          (rnd.nextDouble() - 0.5) * 50 +
          35 * math.sin(2 * math.pi * i / 25.0));
      rrTs.add(ts);
    }
  }
  return Night(accel, hr, rr, rrTs);
}

SleepSegmentation stage(Night d,
    {CardioRowCache? cache, int? onset, int? offset}) {
  return segmentSleep(
    d.accel,
    d.hr,
    rrMs: d.rr,
    rrTsMs: d.rrTs,
    tzOffsetSec: 0,
    forcedWindow: onset == null || offset == null
        ? null
        : (onsetSec: onset, offsetSec: offset),
    rowCache: cache,
  );
}

String fingerprint(SleepSegmentation s) => jsonEncode({
      'json': s.toJson(),
      'stages': s.stages.map((e) => e.toString()).toList(),
      'stages4': s.stages4,
      'conf': s.confidence.toString(),
      'eff': s.efficiencyPct.toString(),
    });

/// Runs [stage] with [cache], returns (output, hitsDelta, missesDelta).
({SleepSegmentation out, int hits, int misses}) staged(Night d,
    CardioRowCache cache, {int? onset, int? offset}) {
  final h0 = cache.hits, m0 = cache.misses;
  final out = stage(d, cache: cache, onset: onset, offset: offset);
  return (out: out, hits: cache.hits - h0, misses: cache.misses - m0);
}

CardioRowCache copyOf(CardioRowCache c) =>
    CardioRowCache.fromJson(
        jsonDecode(jsonEncode(c.toJson())) as Map<String, dynamic>);

void expectIdentical(SleepSegmentation a, SleepSegmentation b, String ctx) {
  expect(fingerprint(a), fingerprint(b), reason: ctx);
}

void main() {
  // Shared 3.7 h record for the forced-window cases: 40 min head, 150 min
  // still, 30 min tail. Window = the still part plus margins.
  final base = genNight(7, headMin: 5, stillMin: 60, tailMin: 10);
  final total = base.accel.length;
  final winA0 = t0 + 600, winA1 = t0 + total - 600;

  test('sanity: the synthetic record stages without a cache', () {
    final s = stage(base, onset: winA0, offset: winA1);
    expect(s.present, isTrue);
    expect(s.stages4.length, winA1 - winA0);
  });

  group('with cache == without cache', () {
    test('forced window, cold cache, then warm cache', () {
      final ref = stage(base, onset: winA0, offset: winA1);
      final cache = CardioRowCache();
      final cold = staged(base, cache, onset: winA0, offset: winA1);
      expectIdentical(cold.out, ref, 'cold');
      expect(cold.hits, 0);
      expect(cold.misses, greaterThan(100));
      expect(cache.length, cold.misses);
      final warm = staged(base, cache, onset: winA0, offset: winA1);
      expectIdentical(warm.out, ref, 'warm');
      expect(warm.misses, 0);
      expect(warm.hits, cold.misses);
    });

    test('RR gaps and accel gaps', () {
      final d = base.withGaps(
        rrGaps: [(t0 + 1500, t0 + 1900), (t0 + 2000, t0 + 2100)],
        accelGaps: [(t0 + 2800, t0 + 2890), (t0 + 3300, t0 + 3310)],
      );
      final ref = stage(d, onset: winA0, offset: winA1);
      final cache = CardioRowCache();
      expectIdentical(
          staged(d, cache, onset: winA0, offset: winA1).out, ref, 'cold');
      final warm = staged(d, cache, onset: winA0, offset: winA1);
      expectIdentical(warm.out, ref, 'warm');
      expect(warm.misses, 0);
    });

    test('no RR at all', () {
      final d = Night(base.accel, base.hr, const [], const []);
      final ref = stage(d, onset: winA0, offset: winA1);
      final cache = CardioRowCache();
      expectIdentical(
          staged(d, cache, onset: winA0, offset: winA1).out, ref, 'cold');
      expectIdentical(
          staged(d, cache, onset: winA0, offset: winA1).out, ref, 'warm');
    });

    test('short sessions (under 3 epochs, a few epochs, ragged length)', () {
      for (final len in [60, 100, 301, 905]) {
        final a = t0 + 1800, b = a + len;
        final ref = stage(base, onset: a, offset: b);
        final cache = CardioRowCache();
        expectIdentical(
            staged(base, cache, onset: a, offset: b).out, ref, 'cold $len');
        expectIdentical(
            staged(base, cache, onset: a, offset: b).out, ref, 'warm $len');
      }
    });

    test('a cache full of rows from a DIFFERENT night never leaks in', () {
      final other = genNight(99);
      final cache = CardioRowCache();
      staged(other, cache, onset: winA0, offset: winA1);
      expect(cache.length, greaterThan(100));
      final ref = stage(base, onset: winA0, offset: winA1);
      final r = staged(base, cache, onset: winA0, offset: winA1);
      expectIdentical(r.out, ref, 'same clock, other data');
      // Same timestamps, different values: essentially nothing may hit.
      expect(r.hits, lessThan(r.misses ~/ 10 + 1));
    });

    test('auto-detect path on one full night, with and without appended data',
        () {
      final night = genNight(11, headMin: 40, stillMin: 200, tailMin: 30);
      final nightEnd = t0 + night.accel.length;
      final ref = stage(night);
      expect(ref.present, isTrue, reason: 'synthetic night must qualify');
      final cache = CardioRowCache();
      final cold = staged(night, cache);
      expectIdentical(cold.out, ref, 'cold');
      expect(cold.misses, greaterThan(300));
      final warm = staged(night, cache);
      expectIdentical(warm.out, ref, 'warm');
      expect(warm.misses, 0);

      // Same night plus 15 min of new data appended after the session.
      // Build "appended" by concatenation (15 min of new data after the end).
      final extra = genNight(12, headMin: 15, stillMin: 0, tailMin: 0,
          start: nightEnd);
      final appended = Night(
        [...night.accel, ...extra.accel],
        [...night.hr, ...extra.hr],
        [...night.rr, ...extra.rr],
        [...night.rrTs, ...extra.rrTs],
      );
      final ref2 = stage(appended);
      final app = staged(appended, cache);
      expectIdentical(app.out, ref2, 'appended');
      expect(app.hits, greaterThan(0));
      expect(app.hits, greaterThanOrEqualTo((cold.misses * 0.8).floor()));
    });
  });

  group('reuse across windows', () {
    test('same data in a window whose arrays start 1 h earlier', () {
      // Edge stages D then D+1 windows over overlapping record ranges.
      final cache = CardioRowCache();
      final early = base.slice(t0 + 20 * 60, t0 + total); // array starts later
      final first = staged(early, cache, onset: winA0 + 600, offset: winA1);
      expectIdentical(first.out,
          stage(early, onset: winA0 + 600, offset: winA1), 'first');
      final second = staged(base, cache, onset: winA0 + 600, offset: winA1);
      expectIdentical(second.out,
          stage(base, onset: winA0 + 600, offset: winA1), 'second');
      expect(second.hits, greaterThan(0));
    });

    test('session start moved by k*30 s', () {
      for (final k in [1, 5, 20]) {
        final cache = CardioRowCache();
        final first = staged(base, cache, onset: winA0, offset: winA1);
        final staged1 = first.misses;
        final newOnset = winA0 + k * 30;
        final alive = copyOf(cache)
          ..retainWhere((key) => key.startSec >= newOnset);
        final second = staged(base, cache, onset: newOnset, offset: winA1);
        expectIdentical(second.out,
            stage(base, onset: newOnset, offset: winA1), 'start +$k');
        expect(second.hits, greaterThan(0));
        expect(second.hits, greaterThanOrEqualTo((alive.length * 0.8).floor()),
            reason: 'k=$k of $staged1 first-run rows');
      }
    });

    test('session start moved by a non-multiple of the epoch (grid shifts)',
        () {
      final cache = CardioRowCache();
      staged(base, cache, onset: winA0, offset: winA1);
      final r = staged(base, cache, onset: winA0 + 7, offset: winA1);
      expectIdentical(r.out, stage(base, onset: winA0 + 7, offset: winA1),
          'start +7 s');
    });

    test('only the end moved (earlier and later): most epochs hit', () {
      for (final delta in [-1200, -90, 600]) {
        final cache = CardioRowCache();
        staged(base, cache, onset: winA0, offset: winA1);
        final newEnd = winA1 + delta;
        final alive = copyOf(cache)
          ..retainWhere((key) => key.startSec + key.epochSec <= newEnd);
        final second = staged(base, cache, onset: winA0, offset: newEnd);
        expectIdentical(second.out,
            stage(base, onset: winA0, offset: newEnd), 'end $delta');
        expect(second.hits, greaterThanOrEqualTo((alive.length * 0.8).floor()),
            reason: 'end moved by $delta s');
        expect(second.hits, greaterThan(0));
      }
    });

    test('extra data appended after the session (forced window unchanged)', () {
      final extra = genNight(5, headMin: 20, stillMin: 0, tailMin: 0,
          start: t0 + total);
      final more = Night(
        [...base.accel, ...extra.accel],
        [...base.hr, ...extra.hr],
        [...base.rr, ...extra.rr],
        [...base.rrTs, ...extra.rrTs],
      );
      final cache = CardioRowCache();
      final first = staged(base, cache, onset: winA0, offset: winA1);
      final second = staged(more, cache, onset: winA0, offset: winA1);
      expectIdentical(second.out,
          stage(more, onset: winA0, offset: winA1), 'appended');
      expect(second.misses, 0);
      expect(second.hits, first.misses);
    });
  });

  group('change detection', () {
    // Context of an epoch: own 30 s, +-150 s (accel median, RR). One more epoch
    // of slack either side for window edges, so at most 13 rows may be dirty.
    const maxDirty = 13;

    Future<void> mutate(String name, Night Function(Night) f, int atSec) async {
      test(name, () {
        final cache = CardioRowCache();
        final first = staged(base, cache, onset: winA0, offset: winA1);
        final d = f(base.copy());
        final second = staged(d, cache, onset: winA0, offset: winA1);
        expectIdentical(second.out,
            stage(d, onset: winA0, offset: winA1), name);
        expect(second.misses, greaterThanOrEqualTo(1));
        expect(second.misses, lessThanOrEqualTo(maxDirty), reason: name);
        expect(second.hits, first.misses - second.misses);
      });
    }

    const mid = 2400; // seconds into the record, deep inside the window

    mutate('one HR sample', (d) {
      d.hr[mid] += 11;
      return d;
    }, mid);

    mutate('one accel sample', (d) {
      final a = d.accel[mid];
      d.accel[mid] = AccelSample(a.tsMs, a.x + 0.4, a.y, a.z);
      return d;
    }, mid);

    mutate('one RR beat value', (d) {
      final i = d.rrTs.indexWhere((t) => t >= (t0 + mid) * 1000.0);
      d.rr[i] += 23;
      return d;
    }, mid);

    mutate('one RR beat removed', (d) {
      final i = d.rrTs.indexWhere((t) => t >= (t0 + mid) * 1000.0);
      d.rr.removeAt(i);
      d.rrTs.removeAt(i);
      return d;
    }, mid);

    test('sample at the very start of the window only dirties near rows', () {
      final cache = CardioRowCache();
      final first = staged(base, cache, onset: winA0, offset: winA1);
      final d = base.copy();
      final i = winA0 - t0 + 3;
      d.hr[i] += 9;
      final second = staged(d, cache, onset: winA0, offset: winA1);
      expectIdentical(
          second.out, stage(d, onset: winA0, offset: winA1), 'edge');
      expect(second.misses, inInclusiveRange(1, maxDirty));
      expect(second.hits, first.misses - second.misses);
    });
  });

  group('json round trip', () {
    test('populated cache -> json text -> cache: identical staging, all hits',
        () {
      final cache = CardioRowCache();
      final cold = staged(base, cache, onset: winA0, offset: winA1);
      final text = jsonEncode(cache.toJson());
      final back = CardioRowCache.fromJson(
          jsonDecode(text) as Map<String, dynamic>);
      expect(back.length, cache.length);
      expect(jsonEncode(back.toJson()), text, reason: 'lossless, stable');
      final warm = staged(base, back, onset: winA0, offset: winA1);
      expectIdentical(warm.out, cold.out, 'revived');
      expect(warm.misses, 0);
      expect(warm.hits, cold.misses);
    });

    test('toJson is deterministic across independent runs', () {
      final a = CardioRowCache(), b = CardioRowCache();
      staged(base, a, onset: winA0, offset: winA1);
      staged(base.copy(), b, onset: winA0, offset: winA1);
      expect(jsonEncode(a.toJson()), jsonEncode(b.toJson()));
    });

    test('empty cache round trips', () {
      final e = CardioRowCache.fromJson(
          jsonDecode(jsonEncode(CardioRowCache().toJson()))
              as Map<String, dynamic>);
      expect(e.length, 0);
    });

    test('wrong or missing version throws FormatException', () {
      final cache = CardioRowCache();
      staged(base, cache, onset: winA0, offset: winA0 + 1800);
      final good = jsonDecode(jsonEncode(cache.toJson())) as Map<String, dynamic>;
      expect(good.containsKey('version'), isTrue);
      for (final v in <Object?>[null, 'x', -1, 0, 9999, good['version'] is int ? (good['version'] as int) + 1 : 2]) {
        final bad = Map<String, dynamic>.of(good)..['version'] = v;
        expect(() => CardioRowCache.fromJson(bad),
            throwsA(isA<FormatException>()),
            reason: 'version=$v');
      }
      final noVersion = Map<String, dynamic>.of(good)..remove('version');
      expect(() => CardioRowCache.fromJson(noVersion),
          throwsA(isA<FormatException>()));
    });

    test('malformed payloads throw FormatException, never wrong rows', () {
      final cache = CardioRowCache();
      staged(base, cache, onset: winA0, offset: winA0 + 1800);
      final good = jsonDecode(jsonEncode(cache.toJson())) as Map<String, dynamic>;
      expect(() => CardioRowCache.fromJson(<String, dynamic>{}),
          throwsA(isA<FormatException>()));
      for (final k in good.keys.where((k) => k != 'version')) {
        final bad = Map<String, dynamic>.of(good)..[k] = 'garbage';
        expect(() => CardioRowCache.fromJson(bad),
            throwsA(isA<FormatException>()),
            reason: 'key $k replaced by a string');
        final v = good[k];
        if (v is List && v.isNotEmpty) {
          final badFirst = Map<String, dynamic>.of(good)
            ..[k] = ['garbage', ...v.skip(1)];
          expect(() => CardioRowCache.fromJson(badFirst),
              throwsA(isA<FormatException>()),
              reason: 'key $k first element garbage');
          final truncated = Map<String, dynamic>.of(good)
            ..[k] = v.sublist(0, v.length - 1);
          // A shorter list is either rejected or yields strictly fewer rows
          // (a parallel-array layout MUST reject); it must never add rows.
          try {
            final c = CardioRowCache.fromJson(truncated);
            expect(c.length, lessThanOrEqualTo(cache.length));
          } on FormatException {
            // acceptable
          }
        }
      }
    });
  });

  group('retainWhere and merge', () {
    test('retainWhere prunes, kept rows still hit, dropped rows miss', () {
      final cache = CardioRowCache();
      final first = staged(base, cache, onset: winA0, offset: winA1);
      final n = cache.length;
      final cut = winA0 + 1800;
      cache.retainWhere((k) => k.startSec < cut);
      expect(cache.length, lessThan(n));
      expect(cache.length, greaterThan(0));
      final second = staged(base, cache, onset: winA0, offset: winA1);
      expectIdentical(second.out, first.out, 'pruned');
      expect(second.hits, greaterThan(0));
      expect(second.misses, greaterThan(0));
      expect(second.hits + second.misses, first.misses);
      cache.retainWhere((_) => false);
      expect(cache.length, 0);
    });

    test('merge unions two caches; merged cache hits both windows', () {
      final a = CardioRowCache(), b = CardioRowCache();
      final midS = winA0 + 1800;
      final ra = staged(base, a, onset: winA0, offset: midS);
      final rb = staged(base, b, onset: midS, offset: winA1);
      // Wall-clock rows whose context is shared by both windows have the
      // same key, including a row at the seam. Union must deduplicate them.
      final unionKeys = {
        for (final cache in [a, b])
          for (final row in cache.toJson()['rows'] as List)
            '${row['startSec']}:${row['epochSec']}:${row['fingerprint']}',
      };
      a.merge(b);
      expect(a.length, unionKeys.length);
      expect(a.length, lessThanOrEqualTo(ra.misses + rb.misses));
      final w1 = staged(base, a, onset: winA0, offset: midS);
      final w2 = staged(base, a, onset: midS, offset: winA1);
      expect(w1.misses, 0);
      expect(w2.misses, 0);
      expectIdentical(w1.out, stage(base, onset: winA0, offset: midS), 'w1');
      expectIdentical(w2.out, stage(base, onset: midS, offset: winA1), 'w2');
    });

    test('merging a copy of itself changes nothing', () {
      final a = CardioRowCache();
      staged(base, a, onset: winA0, offset: winA0 + 1800);
      final n = a.length;
      a.merge(copyOf(a));
      expect(a.length, n);
    });
  });
}
