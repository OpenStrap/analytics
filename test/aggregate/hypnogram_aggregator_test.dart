// HypnogramAggregator parity: folding the sorted segments through the
// aggregator must reproduce AdvancedSleepStager.hypnogramMetrics exactly, for
// any input and any chunking.
//
// _referenceHypnogram is a FROZEN copy of the pre-aggregator implementation.
// Do not edit it when hypnogramMetrics is rewired to use the aggregator: the
// public function is checked against it so the rewire cannot drift.

import 'dart:math' as math;

import 'package:openstrap_analytics/aggregate.dart';
import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

import '../support/checkpoint_support.dart';
import '../support/aggregator_laws.dart';
import '../support/property.dart' show Rng;

// ── frozen reference ────────────────────────────────────────────────────────

HypnogramMetrics _referenceHypnogram(SleepSession session) {
  final segs = [...session.stages]..sort((a, b) => a.start.compareTo(b.start));
  final tib = math.max(0, session.end - session.start);
  final sleepSegs = segs
      .where((s) => s.stage == 'light' || s.stage == 'deep' || s.stage == 'rem')
      .toList();
  var tst = 0, deepS = 0, remS = 0, lightS = 0;
  for (final s in sleepSegs) {
    final d = s.end - s.start;
    tst += d;
    if (s.stage == 'deep') deepS += d;
    if (s.stage == 'rem') remS += d;
    if (s.stage == 'light') lightS += d;
  }
  int onset, sptEnd;
  int? sol;
  if (sleepSegs.isNotEmpty) {
    onset = sleepSegs.first.start;
    sptEnd = sleepSegs.last.end;
    sol = math.max(0, onset - session.start);
  } else {
    onset = session.end;
    sptEnd = session.end;
    sol = null;
  }
  final remSegs = sleepSegs.where((s) => s.stage == 'rem').toList();
  final remLatency =
      remSegs.isNotEmpty ? (remSegs.first.start - onset).toDouble() : double.nan;
  var waso = 0, disturbances = 0;
  for (final s in segs.where((s) => s.stage == 'wake')) {
    final w0 = math.max(s.start, onset);
    final w1 = math.min(s.end, sptEnd);
    if (w1 > w0) {
      waso += w1 - w0;
      disturbances++;
    }
  }
  final se = tib > 0 ? tst / tib : 0.0;
  double pct(int x) => tst > 0 ? x / tst * 100 : 0;
  return HypnogramMetrics(
    tibS: tib,
    tstS: tst,
    sptS: math.max(0, sptEnd - onset),
    solS: sol,
    remLatencyS: remLatency,
    wasoS: waso,
    efficiency: math.min(1.0, se),
    disturbances: disturbances,
    deepMin: deepS / 60,
    remMin: remS / 60,
    lightMin: lightS / 60,
    deepPct: pct(deepS),
    remPct: pct(remS),
    lightPct: pct(lightS),
  );
}

// ── helpers ─────────────────────────────────────────────────────────────────

SleepSession _session(int start, int end, List<StageSegment> stages) =>
    SleepSession(
        start: start,
        end: end,
        efficiency: 0,
        stages: stages,
        restingHr: null,
        avgHrv: null);

/// Stable sort by start. With at most 30 segments, the sort inside the
/// reference/public function (insertion sort below 32 elements) is stable too,
/// so re-sorting this list leaves it unchanged and ties stay in input order.
List<StageSegment> _sorted(List<StageSegment> xs) {
  final idx = [for (var i = 0; i < xs.length; i++) i];
  idx.sort((a, b) {
    final c = xs[a].start.compareTo(xs[b].start);
    return c != 0 ? c : a.compareTo(b);
  });
  return [for (final i in idx) xs[i]];
}

String _show(HypnogramMetrics m) => m.toJson().toString() +
    ' remLatencyS=${m.remLatencyS}';

/// Field by field, exactly: ints ==, doubles bit-identical (NaN == NaN).
void _expectSame(HypnogramMetrics got, HypnogramMetrics want, String tag) {
  void i(String n, int? a, int? b) => expect(a, b, reason: '$tag: $n');
  void d(String n, double a, double b) =>
      expect(a.toString(), b.toString(), reason: '$tag: $n ($a vs $b)');
  i('tibS', got.tibS, want.tibS);
  i('tstS', got.tstS, want.tstS);
  i('sptS', got.sptS, want.sptS);
  i('solS', got.solS, want.solS);
  d('remLatencyS', got.remLatencyS, want.remLatencyS);
  i('wasoS', got.wasoS, want.wasoS);
  d('efficiency', got.efficiency, want.efficiency);
  i('disturbances', got.disturbances, want.disturbances);
  d('deepMin', got.deepMin, want.deepMin);
  d('remMin', got.remMin, want.remMin);
  d('lightMin', got.lightMin, want.lightMin);
  d('deepPct', got.deepPct, want.deepPct);
  d('remPct', got.remPct, want.remPct);
  d('lightPct', got.lightPct, want.lightPct);
}

List<Object?> _fields(HypnogramMetrics m) => [
      m.tibS, m.tstS, m.sptS, m.solS, m.remLatencyS, m.wasoS, m.efficiency,
      m.disturbances, m.deepMin, m.remMin, m.lightMin, m.deepPct, m.remPct,
      m.lightPct,
    ];

typedef _Agg = Aggregator<dynamic, ListBatch<StageSegment>, HypnogramMetrics>;

ListBatch<StageSegment> _batch(List<StageSegment> xs) => ListBatch(xs);

/// Whole run, then every chunked / sliced evaluation of [bounds], against [want].
void _expectAllPaths(_Agg agg, List<StageSegment> sorted, List<int> bounds,
    HypnogramMetrics want, String tag) {
  final b = _batch(sorted);
  _expectSame(runChunked(agg, b, bounds), want, '$tag chunks $bounds');
  _expectSame(runChunked(agg, b, bounds, copy: true), want,
      '$tag copied chunks $bounds');
  _expectSame(runChunkedRight(agg, b, bounds), want, '$tag right $bounds');
  _expectSame(runSliced(agg, b, bounds), want, '$tag sliced $bounds');
}

const _stages = [
  'wake', 'light', 'deep', 'rem', 'wake', 'light', 'deep', 'rem', //
  'unknown', 'REM', '', 'Wake',
];

/// A messy session: random bounds (sometimes end < start), up to [maxSegs]
/// segments placed anywhere (before, inside, after the session), random
/// durations (sometimes zero or negative), overlaps, unknown stage strings.
({int start, int end, List<StageSegment> segs}) _messy(Rng r, int maxSegs) {
  final start = r.intIn(-500, 1500);
  final len = r.nextBool(.05) ? r.intIn(-50, 0) : r.intIn(0, 3000);
  final end = start + len;
  final n = r.intIn(0, maxSegs);
  final segs = <StageSegment>[];
  for (var k = 0; k < n; k++) {
    final s = r.intIn(start - 300, end + 300);
    final d = r.nextBool(.05) ? r.intIn(-30, 0) : r.intIn(0, 600);
    segs.add(StageSegment(s, s + d, _stages[r.nextInt(_stages.length)]));
  }
  return (start: start, end: end, segs: segs);
}

/// A clean contiguous night starting at [start]: segments back to back.
({int start, int end, List<StageSegment> segs}) _tidy(Rng r) {
  final start = r.intIn(0, 1000);
  var t = start + r.intIn(0, 120);
  final segs = <StageSegment>[];
  final n = r.intIn(1, 28);
  const names = ['wake', 'light', 'deep', 'rem', 'light', 'rem', 'wake'];
  for (var k = 0; k < n; k++) {
    final d = r.intIn(30, 900);
    segs.add(StageSegment(t, t + d, names[r.nextInt(names.length)]));
    t += d;
  }
  return (start: start, end: t + r.intIn(0, 200), segs: segs);
}

void main() {
  // Named scenarios, each with the sorted segments.
  final scenarios = <String, ({int start, int end, List<StageSegment> segs})>{
    'empty stages': (start: 0, end: 1000, segs: []),
    'empty stages, zero-length session': (start: 50, end: 50, segs: []),
    'inverted session bounds': (
      start: 100,
      end: 40,
      segs: [StageSegment(100, 200, 'light')]
    ),
    'only wake': (
      start: 0,
      end: 600,
      segs: [StageSegment(0, 300, 'wake'), StageSegment(300, 600, 'wake')]
    ),
    'no sleep, only unknown stages': (
      start: 0,
      end: 600,
      segs: [StageSegment(0, 300, 'unknown'), StageSegment(300, 600, 'asleep')]
    ),
    'wake before onset': (
      start: 0,
      end: 1000,
      segs: [
        StageSegment(0, 200, 'wake'),
        StageSegment(200, 500, 'light'),
        StageSegment(500, 900, 'rem'),
      ]
    ),
    'wake after last sleep': (
      start: 0,
      end: 1000,
      segs: [
        StageSegment(0, 400, 'light'),
        StageSegment(400, 600, 'deep'),
        StageSegment(600, 1000, 'wake'),
      ]
    ),
    'wake straddling onset and spt end': (
      start: 0,
      end: 1000,
      segs: [
        StageSegment(0, 300, 'wake'),
        StageSegment(100, 250, 'light'),
        StageSegment(250, 500, 'wake'),
        StageSegment(500, 700, 'rem'),
        StageSegment(650, 900, 'wake'),
      ]
    ),
    'wake in the middle of the night': (
      start: 0,
      end: 3000,
      segs: [
        StageSegment(0, 600, 'light'),
        StageSegment(600, 700, 'wake'),
        StageSegment(700, 1500, 'deep'),
        StageSegment(1500, 1560, 'wake'),
        StageSegment(1560, 2400, 'rem'),
        StageSegment(2400, 3000, 'wake'),
      ]
    ),
    'rem only': (
      start: 10,
      end: 700,
      segs: [StageSegment(100, 400, 'rem')]
    ),
    'single light segment': (
      start: 0,
      end: 3600,
      segs: [StageSegment(0, 3600, 'light')]
    ),
    'tst exceeds time in bed (overlap)': (
      start: 0,
      end: 100,
      segs: [StageSegment(0, 100, 'light'), StageSegment(0, 100, 'deep')]
    ),
    'overlapping sleep segments': (
      start: 0,
      end: 1000,
      segs: [
        StageSegment(0, 500, 'light'),
        StageSegment(200, 800, 'rem'),
        StageSegment(300, 400, 'wake'),
      ]
    ),
    'zero and negative length segments': (
      start: 0,
      end: 500,
      segs: [
        StageSegment(10, 10, 'light'),
        StageSegment(20, 5, 'rem'),
        StageSegment(30, 30, 'wake'),
        StageSegment(40, 400, 'deep'),
      ]
    ),
    'segments entirely outside the session': (
      start: 1000,
      end: 2000,
      segs: [StageSegment(0, 100, 'light'), StageSegment(3000, 3100, 'rem')]
    ),
    'tied starts keep input order': (
      start: 0,
      end: 500,
      segs: [
        StageSegment(10, 100, 'wake'),
        StageSegment(10, 200, 'light'),
        StageSegment(10, 50, 'rem'),
        StageSegment(10, 300, 'wake'),
      ]
    ),
    'case-sensitive stage names': (
      start: 0,
      end: 500,
      segs: [StageSegment(0, 100, 'Light'), StageSegment(100, 200, 'REM')]
    ),
  };

  List<List<int>> allBounds(int n) => [
        [0, n],
        for (var k = 0; k <= n; k++) [0, k, n],
        [0, 0, 0, n, n],
        if (n >= 3) [0, 1, 2, n],
        if (n >= 3) [0, 1, 1, n - 1, n],
      ];

  group('named scenarios', () {
    scenarios.forEach((name, sc) {
      test('$name: aggregator == frozen reference == public function', () {
        final sorted = _sorted(sc.segs);
        final session = _session(sc.start, sc.end, sc.segs);
        final want = _referenceHypnogram(session);
        final _Agg agg = HypnogramAggregator(sc.start, sc.end);
        _expectSame(agg.runList(sorted), want, 'run vs reference');
        _expectSame(AdvancedSleepStager.hypnogramMetrics(session), want,
            'public vs reference');
        _expectSame(agg.runList(sorted),
            AdvancedSleepStager.hypnogramMetrics(session), 'run vs public');
        for (final b in allBounds(sorted.length)) {
          _expectAllPaths(agg, sorted, b, want, name);
        }
      });
    });

    test('no sleep: solS is null and remLatency is NaN', () {
      final m = HypnogramAggregator(0, 600)
          .runList([const StageSegment(0, 600, 'wake')]);
      expect(m.solS, isNull);
      expect(m.remLatencyS.isNaN, isTrue);
      expect(m.tstS, 0);
      expect(m.sptS, 0);
      expect(m.wasoS, 0);
      expect(m.efficiency, 0.0);
    });

    test('a known night, worked by hand', () {
      // 0-100 wake, 100-400 light, 400-500 wake, 500-700 rem, 700-800 wake.
      final m = HypnogramAggregator(0, 800).runList(const [
        StageSegment(0, 100, 'wake'),
        StageSegment(100, 400, 'light'),
        StageSegment(400, 500, 'wake'),
        StageSegment(500, 700, 'rem'),
        StageSegment(700, 800, 'wake'),
      ]);
      expect(m.tibS, 800);
      expect(m.tstS, 500);
      expect(m.sptS, 600);
      expect(m.solS, 100);
      expect(m.remLatencyS, 400.0);
      expect(m.wasoS, 100);
      expect(m.disturbances, 1);
      expect(m.efficiency, 500 / 800);
      expect(m.lightMin, 300 / 60);
      expect(m.remMin, 200 / 60);
      expect(m.deepMin, 0.0);
      expect(m.remPct, 200 / 500 * 100);
    });
  });

  group('random parity (seeded)', () {
    test('messy input: unchunked, both references', () {
      final r = Rng(0xA11CE);
      for (var t = 0; t < 120; t++) {
        final g = _messy(r, 30);
        final session = _session(g.start, g.end, g.segs);
        final want = _referenceHypnogram(session);
        final got = HypnogramAggregator(g.start, g.end).runList(_sorted(g.segs));
        _expectSame(got, want, 'case $t ${_show(want)}');
        _expectSame(AdvancedSleepStager.hypnogramMetrics(session), want,
            'public, case $t');
      }
    });

    test('tidy nights: unchunked, both references', () {
      final r = Rng(0xB0B);
      for (var t = 0; t < 60; t++) {
        final g = _tidy(r);
        final session = _session(g.start, g.end, g.segs);
        final want = _referenceHypnogram(session);
        _expectSame(HypnogramAggregator(g.start, g.end).runList(_sorted(g.segs)),
            want, 'case $t');
        _expectSame(AdvancedSleepStager.hypnogramMetrics(session), want,
            'public, case $t');
      }
    });

    test('random chunkings and slicings, every evaluation path', () {
      final r = Rng(0xC0DE);
      for (var t = 0; t < 150; t++) {
        final g = t.isEven ? _messy(r, 30) : _tidy(r);
        final sorted = _sorted(g.segs);
        final want = _referenceHypnogram(_session(g.start, g.end, g.segs));
        final _Agg agg = HypnogramAggregator(g.start, g.end);
        for (var c = 0; c < 4; c++) {
          _expectAllPaths(agg, sorted, randomBounds(r, sorted.length), want,
              'case $t');
        }
      }
    });

    test('combine order: right-nested equals left-nested', () {
      final r = Rng(0xD00D);
      for (var t = 0; t < 40; t++) {
        final g = _messy(r, 30);
        final sorted = _sorted(g.segs);
        final want = _referenceHypnogram(_session(g.start, g.end, g.segs));
        final _Agg agg = HypnogramAggregator(g.start, g.end);
        final b = randomBounds(r, sorted.length);
        _expectSame(runChunkedRight(agg, _batch(sorted), b), want,
            'case $t right-nested $b');
        _expectSame(runChunked(agg, _batch(sorted), b), want,
            'case $t left-nested $b');
      }
    });
  });

  test('persistable: a mid-stream checkpoint resumes to the one-pass result', () {
    final g = _tidy(Rng(0xC0DE));
    expectCheckpointResumes(
        HypnogramAggregator(g.start, g.end), _batch(_sorted(g.segs)),
        equals: fieldsEqual<HypnogramMetrics>(_fields));
  });

  group('laws', () {
    test('lawful on messy and tidy sorted inputs (exact equality)', () {
      final r = Rng(0xFACE);
      // The session bounds are an instance property, so one instance per
      // session; the laws hold per instance.
      for (var t = 0; t < 12; t++) {
        final g = t.isEven ? _messy(r, 30) : _tidy(r);
        final sorted = _sorted(g.segs);
        final cases = <ListBatch<StageSegment>>[
          _batch([]),
          if (sorted.isNotEmpty) _batch([sorted.first]),
          _batch(sorted),
          _batch(sorted.sublist(0, sorted.length ~/ 2)),
          _batch(sorted.sublist(sorted.length ~/ 2)),
        ];
        expectLawful(HypnogramAggregator(g.start, g.end), cases,
            equals: fieldsEqual<HypnogramMetrics>(_fields));
      }
    });

    test('finish does not mutate: finishing twice and then adding more', () {
      final _Agg agg = HypnogramAggregator(0, 1000);
      const segs = [
        StageSegment(0, 100, 'wake'),
        StageSegment(100, 300, 'light'),
        StageSegment(300, 400, 'wake'),
        StageSegment(400, 600, 'rem'),
      ];
      final batch = _batch(segs);
      var s = agg.fold(batch, 0, 3);
      final a = agg.finish(s), b = agg.finish(s);
      _expectSame(a, b, 'twice');
      s = agg.addSlice(s, batch, 3, 4);
      _expectSame(agg.finish(s), agg.runList(segs), 'continued');
    });
  });
}
