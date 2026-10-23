// checkConversion: correct aggregators pass; each deliberately broken one is
// caught on the path that names its defect (and not on the paths it gets right).

import 'package:openstrap_analytics/aggregate.dart';
import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

import '../support/aggregator_laws.dart';
import '../support/property.dart' show Rng;

typedef _B = ListBatch<int>;

int _sliceSum(_B b, int start, int end) {
  var t = 0;
  for (var i = start; i < end; i++) {
    t += b.rows[i];
  }
  return t;
}

int _refSum(_B b) {
  var t = 0;
  for (final x in b.rows) {
    t += x;
  }
  return t;
}

/// A correct sum over int rows.
class _Sum extends Aggregator<int, _B, int> {
  const _Sum();
  @override
  int empty() => 0;
  @override
  int addSlice(int s, _B b, int start, int end) => s + _sliceSum(b, start, end);
  @override
  int combine(int left, int right) => left + right;
  @override
  int finish(int s) => s;
}

/// combine drops the right side: wrong only when chunks were combined.
class _DropRight extends _Sum {
  const _DropRight();
  @override
  int combine(int left, int right) => left;
}

/// addSlice restarts from the slice, so a second addSlice onto a state that
/// already holds data loses it. Only the 'sliced' path adds twice to one state.
class _IgnoresState extends _Sum {
  const _IgnoresState();
  @override
  int addSlice(int s, _B b, int start, int end) => _sliceSum(b, start, end);
}

/// State: [sum, chunks]. combine is right only when the right side is a single
/// chunk (it drops a multi-chunk right side), so left-to-right combining works
/// and right-nested combining does not.
class _LeftOnly extends Aggregator<List<int>, _B, int> {
  const _LeftOnly();
  @override
  List<int> empty() => [0, 0];
  @override
  List<int> addSlice(List<int> s, _B b, int start, int end) =>
      [s[0] + _sliceSum(b, start, end), s[1] + (s[1] == 0 ? 1 : 0)];
  @override
  List<int> combine(List<int> l, List<int> r) =>
      r[1] > 1 ? [l[0], l[1] + r[1]] : [l[0] + r[0], l[1] + r[1]];
  @override
  int finish(List<int> s) => s[0];
}

/// Keeps the FIRST batch it was shown plus index ranges into it, and reads the
/// rows only in finish (clamped, so a foreign batch cannot throw). Over one
/// batch this is a correct sum. Chunks cut out with copyRange are separate
/// batches with their own indexing, so the ranges of later chunks are read from
/// the first chunk's storage: wrong values. Only the 'copies' path differs.
class _Aliasing extends Aggregator<_AliasState, _B, int> {
  const _Aliasing();
  @override
  _AliasState empty() => _AliasState(null, []);
  @override
  _AliasState addSlice(_AliasState s, _B b, int start, int end) {
    s.ranges.add([start, end]);
    return _AliasState(s.source ?? b, s.ranges);
  }

  @override
  _AliasState combine(_AliasState l, _AliasState r) =>
      _AliasState(l.source ?? r.source, [...l.ranges, ...r.ranges]);

  @override
  int finish(_AliasState s) {
    final src = s.source;
    if (src == null) return 0;
    var t = 0;
    for (final r in s.ranges) {
      for (var i = r[0]; i < r[1] && i < src.length; i++) {
        t += src.rows[i];
      }
    }
    return t;
  }
}

class _AliasState {
  _AliasState(this.source, this.ranges);
  final _B? source;
  final List<List<int>> ranges;
}

/// Sum of (row - origin); origin comes from the case via build.
class _SumFrom extends Aggregator<int, _B, int> {
  const _SumFrom(this.origin);
  final int origin;
  @override
  int empty() => 0;
  @override
  int addSlice(int s, _B b, int start, int end) =>
      s + _sliceSum(b, start, end) - origin * (end - start);
  @override
  int combine(int left, int right) => left + right;
  @override
  int finish(int s) => s;
}

int _originOf(_B b) => b.rows.isEmpty ? 0 : b.rows.first;

Set<String> _paths(List<ConversionFailure> fs) => {for (final f in fs) f.path};

void main() {
  final cases = randomIntBatches(8, count: 24, maxLen: 30);

  List<ConversionFailure> check(Aggregator<dynamic, _B, int> agg,
          {int Function(_B)? reference, bool laws = true, int seed = 0}) =>
      checkConversion<dynamic, _B, int>((_) => agg, cases, reference ?? _refSum,
          laws: laws, seed: seed);

  group('correct aggregators pass', () {
    test('Sum against a reference loop', () {
      expectConversion<int, _B, int>((_) => const _Sum(), cases, _refSum);
      expect(check(const _Sum()), isEmpty);
    });

    test('hypnogram aggregator against hypnogramMetrics', () {
      final r = Rng(5);
      const stages = ['wake', 'light', 'deep', 'rem'];
      final batches = <ListBatch<StageSegment>>[];
      for (var c = 0; c < 6; c++) {
        final n = c == 0 ? 0 : r.intIn(1, 14);
        var t = r.intIn(0, 60);
        final segs = <StageSegment>[];
        for (var i = 0; i < n; i++) {
          final d = r.intIn(1, 120);
          segs.add(StageSegment(t, t + d, stages[r.intIn(0, 3)]));
          t += d + r.intIn(0, 20);
        }
        batches.add(ListBatch(segs));
      }
      expectConversion<dynamic, ListBatch<StageSegment>, HypnogramMetrics>(
        (_) => HypnogramAggregator(0, 3000),
        batches,
        (b) => AdvancedSleepStager.hypnogramMetrics(SleepSession(
            start: 0,
            end: 3000,
            efficiency: 0,
            stages: b.rows,
            restingHr: null,
            avgHrv: null)),
        equals: fieldsEqual<HypnogramMetrics>((m) => [
              m.tibS, m.tstS, m.sptS, m.solS, m.remLatencyS, m.wasoS,
              m.efficiency, m.disturbances, m.deepMin, m.remMin, m.lightMin,
              m.deepPct, m.remPct, m.lightPct,
            ]),
      );
    });
  });

  group('broken aggregators are caught on the right path', () {
    test('combine drops right: chunked and law:split, not whole', () {
      final p = _paths(check(const _DropRight()));
      expect(p, containsAll(['chunked', 'law:split']));
      expect(p, isNot(contains('whole')));
    });

    test('state aliasing the input: copies fails, whole passes', () {
      final p = _paths(check(const _Aliasing()));
      expect(p, contains('copies'));
      expect(p, isNot(contains('whole')));
      expect(p, isNot(contains('chunked')));
      expect(p, isNot(contains('sliced')));
    });

    test('addSlice ignoring its state: sliced and law:slicing', () {
      final p = _paths(check(const _IgnoresState()));
      expect(p, containsAll(['sliced', 'law:slicing']));
      expect(p, isNot(contains('whole')));
      expect(p, isNot(contains('chunked')));
    });

    test('right-nested combine broken: chunkedRight, not chunked', () {
      final p = _paths(check(const _LeftOnly(), laws: false));
      expect(p, contains('chunkedRight'));
      expect(p, isNot(contains('whole')));
      expect(p, isNot(contains('chunked')));
    });

    test('wrong reference everywhere: whole fails on every case', () {
      final fs = check(const _Sum(), reference: (b) => _refSum(b) + 1);
      final whole = fs.where((f) => f.path == 'whole');
      expect({for (final f in whole) f.caseIndex},
          {for (var i = 0; i < cases.length; i++) i});
    });

    test('failures carry a detail string', () {
      final fs = check(const _DropRight());
      expect(fs, isNotEmpty);
      expect(fs.every((f) => f.detail.isNotEmpty), isTrue);
    });
  });

  group('build is context-indexed', () {
    test('per-case parameter comes from build(input)', () {
      final seen = <_B>[];
      expectConversion<int, _B, int>((input) {
        seen.add(input);
        return _SumFrom(_originOf(input));
      }, cases, (b) => _refSum(b) - _originOf(b) * b.length);
      expect(seen, isNotEmpty);
      expect(seen.toSet(), containsAll(cases));
    });

    test('a build that ignores the case is caught', () {
      final fs = checkConversion<int, _B, int>((_) => const _SumFrom(0), cases,
          (b) => _refSum(b) - _originOf(b) * b.length);
      expect(_paths(fs), contains('whole'));
    });
  });

  group('determinism and options', () {
    test('same seed gives identical failures', () {
      String show(List<ConversionFailure> fs) =>
          fs.map((f) => '${f.path}|${f.caseIndex}|${f.detail}').join('\n');
      expect(show(check(const _Aliasing(), seed: 3)),
          show(check(const _Aliasing(), seed: 3)));
      expect(show(check(const _DropRight(), seed: 3)),
          show(check(const _DropRight(), seed: 3)));
    });

    test('laws: false skips law paths', () {
      expect(_paths(check(const _DropRight())).any((p) => p.startsWith('law:')),
          isTrue);
      expect(
          _paths(check(const _DropRight(), laws: false))
              .any((p) => p.startsWith('law:')),
          isFalse);
    });
  });
}
