// LAWS — per-stage minute ranges (D27 revised). RED: new API.
//
// See test/onehz/stage_minute_ranges_test.dart for the contract and the API.
// These laws hold for any night the stager could produce:
//   L1 bounds:    0 ≤ lo ≤ point ≤ hi ≤ window per stage; Σlo ≤ window ≤ Σhi;
//                 deep and light sit inside nrem (lo and hi both).
//   L2 coverage:  covering more epochs never widens a range (lo never falls,
//                 hi never rises), whatever the newly covered epochs say.
//   L3 clear:     every epoch covered and every score clear of the margin ⇒
//                 lo == hi == point for every stage.
//
// Run: dart test test/properties/stage_minute_ranges_laws_test.dart

import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

import '../support/law_registry.dart';
import '../support/property.dart';

const double _margin = 0.2;
const double _remCut = kDefaultRemScoreCut;
const double _deepCut = kDefaultDeepScoreCut;

/// One generated epoch: label index (0 none, 1 wake, 2 light, 3 deep, 4 rem),
/// (remScore, deepScore), and a coverage level: 0 uncovered in both nights of
/// L2, 1 uncovered in A but covered in B, 2 covered in both.
typedef _Ep = (int, (double?, double?), int);

final Gen<double> _score = G.doubleIn(-3, 3, boundaries: [
  _remCut,
  _remCut - _margin,
  _remCut + _margin,
  _deepCut,
  _deepCut - _margin,
  _deepCut + _margin,
]);

final Gen<_Ep> _ep = G.triple(
  G.intIn(0, 4, origin: 2),
  G.pair(G.nullable(_score, nullProbability: .15),
      G.nullable(_score, nullProbability: .15)),
  G.intIn(0, 2, origin: 2),
);

final Gen<List<_Ep>> _night =
    _SometimesAllCovered(G.listOf(_ep, minLen: 1, maxLen: 240));

/// Per-epoch coverage is drawn independently, so a night of any length is
/// almost never covered end to end. A fifth of the nights are forced fully
/// covered so L1 meets that case (it is the shape a good night has).
class _SometimesAllCovered extends Gen<List<_Ep>> {
  _SometimesAllCovered(this.inner);
  final Gen<List<_Ep>> inner;

  @override
  List<_Ep> generate(Rng r, int size) {
    final n = inner.generate(r, size);
    if (!r.nextBool(.2)) return n;
    return [for (final (l, s, _) in n) (l, s, 2)];
  }

  @override
  Iterable<List<_Ep>> shrink(List<_Ep> v) => inner.shrink(v);

  @override
  String show(List<_Ep> v) => inner.show(v);
}

StageEpochEvidence _evidence(_Ep e, {required bool covered}) {
  final (label, (rem, deep), _) = e;
  final SleepStage? stage = switch (label) {
    1 => SleepStage.wake,
    2 || 3 => SleepStage.nrem,
    4 => SleepStage.rem,
    _ => null,
  };
  return StageEpochEvidence(
    stage: stage,
    deep: label == 3,
    covered: covered,
    remScore: stage == SleepStage.wake ? null : rem,
    deepScore: stage == SleepStage.wake ? null : deep,
  );
}

List<StageEpochEvidence> _nightA(List<_Ep> n) =>
    [for (final e in n) _evidence(e, covered: e.$3 == 2)];
List<StageEpochEvidence> _nightB(List<_Ep> n) =>
    [for (final e in n) _evidence(e, covered: e.$3 >= 1)];

/// The stager's own labelled minutes per display stage.
Map<String, double> _points(List<StageEpochEvidence> ev) {
  final p = {'wake': 0.0, 'light': 0.0, 'deep': 0.0, 'rem': 0.0, 'nrem': 0.0};
  for (final e in ev) {
    switch (e.stage) {
      case SleepStage.wake:
        p['wake'] = p['wake']! + .5;
      case SleepStage.nrem:
        p[e.deep ? 'deep' : 'light'] = p[e.deep ? 'deep' : 'light']! + .5;
        p['nrem'] = p['nrem']! + .5;
      case SleepStage.rem:
        p['rem'] = p['rem']! + .5;
      case null:
        break;
    }
  }
  return p;
}

Map<String, MinuteRange> _byName(StageMinuteRanges r) => {
      'wake': r.wake,
      'light': r.light,
      'deep': r.deep,
      'rem': r.rem,
      'nrem': r.nrem,
    };

bool _near(double? s, double cut) => s != null && (s - cut).abs() < _margin;

void _observe(List<_Ep> n, void Function(String) bump) {
  if (n.any((e) => e.$3 == 0)) bump('uncovered epoch');
  if (n.any((e) => e.$3 == 1)) bump('newly covered epoch');
  if (n.every((e) => e.$3 == 2)) bump('all covered');
  if (n.any((e) => e.$1 == 0)) bump('unlabelled epoch');
  if (n.any((e) => e.$1 == 1)) bump('wake');
  if (n.any((e) => e.$1 == 3)) bump('deep');
  if (n.any((e) => e.$1 == 4)) bump('rem');
  if (n.any((e) => e.$1 >= 2 && _near(e.$2.$1, _remCut))) bump('near rem cut');
  if (n.any((e) => e.$1 >= 2 && _near(e.$2.$2, _deepCut))) {
    bump('near deep cut');
  }
}

/// L3's input: the same night with every epoch covered, labelled, and both
/// scores pushed clear of their cutoffs.
List<StageEpochEvidence> _clear(List<_Ep> n) => [
      for (final (label, (rem, deep), _) in n)
        _evidence((
          label == 0 ? 2 : label,
          (_clearOf(rem, _remCut), _clearOf(deep, _deepCut)),
          2,
        ), covered: true)
    ];

double? _clearOf(double? s, double cut) {
  if (s == null || !_near(s, cut)) return s;
  return s >= cut ? cut + _margin : cut - _margin;
}

void main() {
  final laws = LawSet();
  final reach = Reach<List<_Ep>>({
    'uncovered epoch': .5,
    'newly covered epoch': .5,
    'all covered': .02,
    'unlabelled epoch': .3,
    'wake': .5,
    'deep': .5,
    'rem': .5,
    'near rem cut': .3,
    'near deep cut': .3,
  }, _observe);

  laws.law<List<_Ep>>('L1 ranges bracket the point and the window', _night,
      (n) {
    for (final ev in [_nightA(n), _nightB(n)]) {
      final r = stageMinuteRanges(ev, margin: _margin)!;
      final window = ev.length * .5;
      expect(r.windowMin, closeTo(window, 1e-9));
      final pts = _points(ev);
      var sumLo = 0.0, sumHi = 0.0;
      _byName(r).forEach((name, range) {
        expect(range.lo, greaterThanOrEqualTo(0), reason: '$name lo ≥ 0');
        expect(range.hi, lessThanOrEqualTo(window + 1e-9),
            reason: '$name hi ≤ window');
        expect(range.lo, lessThanOrEqualTo(pts[name]! + 1e-9),
            reason: '$name lo ≤ point');
        expect(range.hi, greaterThanOrEqualTo(pts[name]! - 1e-9),
            reason: '$name point ≤ hi');
        if (name != 'nrem') {
          sumLo += range.lo;
          sumHi += range.hi;
        }
      });
      expect(sumLo, lessThanOrEqualTo(window + 1e-9), reason: 'Σlo ≤ window');
      expect(sumHi, greaterThanOrEqualTo(window - 1e-9),
          reason: 'window ≤ Σhi');
      for (final sub in [r.deep, r.light]) {
        expect(sub.lo, lessThanOrEqualTo(r.nrem.lo + 1e-9));
        expect(sub.hi, lessThanOrEqualTo(r.nrem.hi + 1e-9));
      }
    }
  }, reach: reach, examples: [
    [(0, (null, null), 0)],
    [(4, (_remCut + .01, null), 2), (3, (null, _deepCut - .01), 2)],
  ]);

  laws.law<List<_Ep>>('L2 more coverage never widens a range', _night, (n) {
    final a = _byName(stageMinuteRanges(_nightA(n), margin: _margin)!);
    final b = _byName(stageMinuteRanges(_nightB(n), margin: _margin)!);
    for (final k in a.keys) {
      expect(b[k]!.lo, greaterThanOrEqualTo(a[k]!.lo - 1e-9),
          reason: '$k lo fell with more coverage');
      expect(b[k]!.hi, lessThanOrEqualTo(a[k]!.hi + 1e-9),
          reason: '$k hi rose with more coverage');
    }
  }, reach: reach, examples: [
    [(1, (null, null), 1), (2, (-1, -1), 0)],
  ]);

  laws.law<List<_Ep>>('L3 covered and clear ⇒ lo == hi == point', _night,
      (n) {
    final ev = _clear(n);
    final r = stageMinuteRanges(ev, margin: _margin)!;
    final pts = _points(ev);
    _byName(r).forEach((name, range) {
      expect(range.lo, closeTo(pts[name]!, 1e-9), reason: '$name lo');
      expect(range.hi, closeTo(pts[name]!, 1e-9), reason: '$name hi');
    });
  }, reach: reach);

  laws.registerReachTest();
}
