// LAWS of the append-only beat streams behind the night's spectral and CVHR
// estimators: `RsaRespStream` (respiration/resp_rate.dart, checkpoint v2),
// `HrvFreqStream` (clinical/hrv_freq_stream.dart, v1) and `CvhrStream`
// (respiration/cvhr_apnea.dart, v1). Each folds settled NN with their beat
// times and answers `snapshot` with a provisional tail; the batch functions
// (`rsaRespRate`, `hrvFreq`, `cvhrApneaScreen`) are the reference.
//
//   L1   chunk invariance: any chunking of the folds (empty chunks and a
//        save/restore through real JSON text between chunks included) gives
//        the checkpoint TEXT of one fold of the whole input and the same
//        snapshot under every evaluation. A law of the append transition, not
//        a monoid claim (no stream has a `combine`).
//   L1b  streamed vs batch: at every checked seam `snapshot(tail)` is the
//        batch of settled ++ tail BIT FOR BIT (doubles compared by their
//        shortest round-trip text: NaN-ness and the sign of zero included),
//        notes, confidence and every value field; and the snapshot did not
//        write.
//   L2   checkpoint round trip: `toJson` -> real JSON text -> `fromJson` ->
//        `toJson` is the same text, the restored stream reads what the live
//        one reads, is not aliased to the map it came from, and goes on
//        identically.
//   L3   a checkpoint of another type or version (RsaRespStream version 1, the
//        span-based ceiling without gappy sub-windows, included), a missing or
//        mistyped part, parts that disagree in a way the reader checks:
//        refused whole with a FormatException, never another error type. A
//        number changed where the reader cannot tell: refused, or held exactly
//        as written. An unknown key: ignored.
//   L4   identity: an empty fold changes nothing (on a fresh stream it records
//        nothing), `snapshot` never writes, and a refused fold (lengths that
//        differ, a non-finite beat time, a time that steps back) leaves the
//        stream unchanged.
//   L5   conservation, from counts made HERE from the input: the stream counts
//        every folded beat once; RsaRespStream keeps exactly the sorted
//        multiset of the folded NN and has closed exactly the sub-windows the
//        documented walk has finished, and a reported rate rests on as many
//        sub-windows as that walk visits; HrvFreqStream's bands have used no
//        more segments than they have stepped over; CvhrStream's open stretch
//        holds exactly the beats since the last gap over maxGapSec.
//
// A failing law is first checked against the module's contract; a law that
// fails because the library breaks it is fixed in lib/ with a rationale.
//
// A series is a RECIPE (flavour, beats, seed) expanded deterministically.
// Replay a failure with the command in its report, e.g.
//   PROPERTY_SEED=<s> PROPERTY_CASE=<n> TZ=UTC dart test \
//     test/properties/welch_stream_laws_test.dart --plain-name '<name>'

import 'dart:convert';
import 'dart:math' as math;

import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

import '../support/fold_law_support.dart';
import '../support/law_registry.dart';
import '../support/property.dart';

final _laws = LawSet();

typedef Json = Map<String, dynamic>;

// ── the beats ───────────────────────────────────────────────────────────────

const _flavours = [
  'sleep', // ~57 bpm, breathing at 0.24 Hz, LF and VLF waves, a little noise
  'slow heart', // NN ~1420 ms: the RSA ceiling sits under the HF band
  'gappy', // a 40 s dropout every 400 beats, a 150 s one every 700
  'apnea', // +80 ms half-sine bumps, 20 s wide, every 45 s (CVHR cycles)
  'whole seconds', // beat times floored to whole seconds, ties included
  'outliers', // out-of-range NN (250 / 2600 ms) and an occasional NaN NN
];
const int _nFlavours = 6;

/// 2023-11-14 22:13:20 UTC in ms.
const double _t0 = 1.7e12;

class _Night {
  _Night(this.nn, this.t);
  final List<double> nn, t;
  int get n => nn.length;
}

final Map<(int, int, int), _Night> _cache = {};

_Night _night(int flavour, int n, int seed) =>
    _cache.putIfAbsent((flavour, n, seed), () {
      if (_cache.length > 300) _cache.clear();
      return _expand(flavour, n, seed);
    });

_Night _expand(int flavour, int n, int seed) {
  final r = Rng(seed * 7919 + flavour * 131 + 7);
  final phase = r.nextDouble() * 6.28;
  final nn = <double>[], t = <double>[];
  var clock = _t0;
  for (var i = 0; i < n; i++) {
    final s = (clock - _t0) / 1000;
    final noise = 6 * (r.nextDouble() - .5) * 2;
    final sleep = 1050 +
        60 * math.sin(s / 1500 + seed) +
        28 * math.sin(2 * math.pi * .24 * s + phase) +
        18 * math.sin(2 * math.pi * .1 * s) +
        22 * math.sin(2 * math.pi * .01 * s) +
        noise;
    var v = switch (flavour) {
      1 => 1420 + 30 * math.sin(2 * math.pi * .2 * s + phase) + noise,
      3 => 1000 +
          25 * math.sin(2 * math.pi * .25 * s + phase) +
          (s % 45 < 20 ? 80 * math.sin(math.pi * (s % 45) / 20) : 0) +
          noise,
      _ => sleep,
    };
    if (flavour == 5) {
      final u = r.nextDouble();
      if (u < .01) {
        v = double.nan;
      } else if (u < .03) {
        v = r.nextBool() ? 250 : 2600;
      }
    }
    v = v.isNaN ? v : v.roundToDouble();
    if (flavour == 2 && i > 0 && i % 400 == 0) clock += 40000;
    if (flavour == 2 && i > 0 && i % 700 == 0) clock += 150000;
    clock += v.isFinite ? v : 800;
    nn.add(v);
    t.add(flavour == 4 ? (clock / 1000).floorToDouble() * 1000 : clock);
  }
  return _Night(nn, t);
}

// ── exact text of an output ─────────────────────────────────────────────────

/// A double as its shortest round-trip text: equal text is equal bits up to
/// the NaN payload (NaN and -0.0 are spelled out).
String _d(double? x) => x == null ? 'null' : x.toString();

String _envelope(Metric m) =>
    '${m.present}|${_d(m.confidence)}|${m.tier}|${m.inputs_used}|${m.note}|'
    '${m.drivers}';

// ── one stream under the laws ───────────────────────────────────────────────

abstract class _Ops<S> {
  String get name;
  String get type;

  /// Constructor configurations (index 0 is the default) and evaluations.
  int get nCfg;
  int get nEv;

  S fresh(int cfg);
  void fold(S s, List<double> nn, List<double> t);
  Metric snapshot(S s, int ev, List<double> tailNn, List<double> tailT);
  Metric batch(List<double> nn, List<double> t, int cfg, int ev);
  String showValue(Object v);
  Json toJson(S s);
  S fromJson(Json j);

  /// Every version but the current one is refused.
  List<Object?> get badVersions;

  /// Breaks of a reachable checkpoint the reader checks: must be refused.
  List<void Function(Json)> get refuseMutations;

  /// Numbers the reader cannot tell from legal ones: refused or held exactly.
  List<void Function(Json)> get faithfulMutations;

  /// Whether a fold with a non-finite beat time is refused.
  bool get refusesNonFiniteTimes => true;

  /// Counts made from the input ([nn] / [t], everything folded so far).
  void conserved(Json cp, List<double> nn, List<double> t, int cfg, String why);

  /// The output as exact text.
  String show(Metric m) =>
      '${_envelope(m)}|${m.value == null ? '-' : showValue(m.value!)}';

  Map<String, double> get shares;
  void observe(_Case c, void Function(String) bump);
  List<_Case> get forced;
}

/// ((flavour, beats, seed, config), (splits, cut seed, restart mask, evaluation)).
typedef _Case = ((int, int, int, int), (int, int, int, int));

class _NGen extends Gen<int> {
  _NGen(this.maxN, this.pool);
  final int maxN;
  final List<int> pool;
  @override
  int generate(Rng r, int size) {
    final p = r.nextDouble();
    if (p < .07) return 0;
    if (p < .35) {
      final ok = [for (final x in pool) if (x <= maxN) x];
      return ok[r.nextInt(ok.length)];
    }
    if (p < .55) return r.intIn(math.min(700, maxN), maxN);
    return r.intIn(0, maxN);
  }

  @override
  Iterable<int> shrink(int v) => G.intIn(0, maxN).shrink(v);
}

Gen<_Case> _caseGen(_Ops ops, int maxN, List<int> pool) => G.pair(
      G.quad(G.intIn(0, _nFlavours - 1), _NGen(maxN, pool),
          G.intIn(0, 1 << 16), G.intIn(0, ops.nCfg - 1)),
      G.quad(G.intIn(0, 5), G.intIn(0, 1 << 20), G.intIn(0, 127),
          G.intIn(0, ops.nEv - 1)),
    );

String _tag(_Ops ops, _Case c) {
  final ((f, n, seed, cfg), (splits, cut, restart, ev)) = c;
  return '${ops.name} ${_flavours[f]} n=$n seed=$seed cfg=$cfg '
      'splits/cut=$splits/$cut restart=$restart ev=$ev';
}

/// Beat counts where the streams change behaviour: the batch minimums (16, 20,
/// 60) and the first spans that settle anything.
const _edges = [0, 1, 2, 15, 16, 17, 19, 20, 21, 59, 60, 61];

List<int> _boundsOf(_Case c) {
  final ((_, n, _, _), (splits, cut, _, _)) = c;
  return foldBounds(n, splits, cut, special: _edges);
}

S _restore<S>(_Ops<S> ops, S s) =>
    ops.fromJson((jsonDecode(jsonEncode(ops.toJson(s))) as Map).cast<String, dynamic>());

String _text<S>(_Ops<S> ops, S s) => jsonEncode(ops.toJson(s));

/// Folds [bounds] chunk by chunk, restoring through JSON text where [restart]
/// says, calling [seam] after each chunk.
S _drive<S>(_Ops<S> ops, _Night x, int cfg, List<int> bounds, int restart,
    [void Function(S s, int k, int at)? seam]) {
  var s = ops.fresh(cfg);
  for (var k = 0; k + 1 < bounds.length; k++) {
    ops.fold(s, x.nn.sublist(bounds[k], bounds[k + 1]),
        x.t.sublist(bounds[k], bounds[k + 1]));
    if ((restart >> (k % 7)) & 1 == 1) s = _restore(ops, s);
    seam?.call(s, k, bounds[k + 1]);
  }
  return s;
}

// ── the laws, written once ──────────────────────────────────────────────────

void _l1<S>(_Ops<S> ops, _Case c) {
  final ((f, n, seed, cfg), (_, _, restart, _)) = c;
  final x = _night(f, n, seed);
  final tag = _tag(ops, c);
  final whole = ops.fresh(cfg);
  ops.fold(whole, x.nn, x.t);
  final bounds = _boundsOf(c);
  final got = _drive(ops, x, cfg, bounds, restart);
  expect(_text(ops, got), _text(ops, whole),
      reason: '$tag bounds=$bounds: the checkpoint of one fold');
  for (var e = 0; e < ops.nEv; e++) {
    expect(ops.show(ops.snapshot(got, e, const [], const [])),
        ops.show(ops.snapshot(whole, e, const [], const [])),
        reason: '$tag: evaluation $e reads the same');
  }
}

void _l1b<S>(_Ops<S> ops, _Case c) {
  final ((f, n, seed, cfg), (_, _, restart, ev)) = c;
  final x = _night(f, n, seed);
  final tag = _tag(ops, c);
  final bounds = _boundsOf(c);
  final picks = pickSeams(bounds.length - 1);
  _drive(ops, x, cfg, bounds, restart, (s, k, at) {
    if (!picks.contains(k)) return;
    // The tail is what a corrector would still hold provisional.
    final end = math.min(n, at + (at * 7 + k * 13) % 400);
    final before = _text(ops, s);
    final got = ops.snapshot(s, ev, x.nn.sublist(at, end), x.t.sublist(at, end));
    expect(_text(ops, s), before, reason: '$tag: snapshot reads, never writes');
    final want = ops.batch(x.nn.sublist(0, end), x.t.sublist(0, end), cfg, ev);
    expect(ops.show(got), ops.show(want),
        reason: '$tag seam $k at $at tail to $end: the batch, bit for bit');
  });
}

String _project<S>(_Ops<S> ops, S s) => [
      for (var e = 0; e < ops.nEv; e++) ops.show(ops.snapshot(s, e, const [], const [])),
    ].join('\n');

void _l2<S>(_Ops<S> ops, _Case c) {
  final ((f, n, seed, cfg), _) = c;
  final x = _night(f, n, seed);
  final tag = _tag(ops, c);
  final bounds = _boundsOf(c);
  final at = bounds.length > 2 ? bounds[1] : n ~/ 2;
  final live = ops.fresh(cfg);
  ops.fold(live, x.nn.sublist(0, at), x.t.sublist(0, at));
  final text = _text(ops, live);
  final map = (jsonDecode(text) as Map).cast<String, dynamic>();
  final back = ops.fromJson(map);
  expect(_text(ops, back), text, reason: '$tag: write(read(b)) == b');
  expect(_project(ops, back), _project(ops, live),
      reason: '$tag: the restored stream reads what the live one reads');
  for (final v in map.values) {
    if (v is List) v.clear();
  }
  expect(_text(ops, back), text, reason: '$tag: not aliased to the map');
  ops.fold(live, x.nn.sublist(at), x.t.sublist(at));
  ops.fold(back, x.nn.sublist(at), x.t.sublist(at));
  expect(_text(ops, back), _text(ops, live), reason: '$tag: goes on identically');
  expect(_project(ops, back), _project(ops, live), reason: tag);
}

(Json, Must) _mutate<S>(_Ops<S> ops, Json src, Mut m) {
  final j = (deepCopy(src) as Map).cast<String, dynamic>();
  final (kind, a, b) = m;
  final keys = j.keys.toList();
  switch (kind % 7) {
    case 0:
      j['version'] = ops.badVersions[a % ops.badVersions.length];
      return (j, Must.refuse);
    case 1:
      const types = <Object?>['Other', null, '', 1, 'IrregularScreenState'];
      j['type'] = types[a % types.length];
      return (j, Must.refuse);
    case 2:
      j.remove(keys[a % keys.length]);
      return (j, Must.refuse);
    case 3:
      const junk = <Object?>['x', <String, Object?>{}, <Object?>[<Object?>[]], true];
      j[keys[a % keys.length]] = junk[b % junk.length];
      return (j, Must.refuse);
    case 4:
      final before = jsonEncode(j);
      ops.refuseMutations[a % ops.refuseMutations.length](j);
      // A break that happens to be a no-op on this checkpoint is no break.
      return (j, jsonEncode(j) == before ? Must.faithful : Must.refuse);
    case 5:
      ops.faithfulMutations[a % ops.faithfulMutations.length](j);
      return (j, Must.faithful);
    default:
      j['futureField${a % 3}'] = const [1, 'x', <Object?>[1]][b % 3];
      return (j, Must.ignored);
  }
}

String _outcome<S>(_Ops<S> ops, Json j) {
  try {
    return 'accepted:${_text(ops, ops.fromJson((deepCopy(j) as Map).cast<String, dynamic>()))}';
  } on FormatException {
    return 'refused';
  } catch (e) {
    return 'WRONG ERROR TYPE: ${e.runtimeType}: $e';
  }
}

/// The checkpoint of one fold of a recipe (folding is not the cost under test).
final Map<String, String> _foldedText = {};

void _l3<S>(_Ops<S> ops, (_Case, Mut) arg) {
  final (c, m) = arg;
  final ((f, n, seed, cfg), _) = c;
  final tag = '${_tag(ops, c)} mutation=${m.$1 % 7}(${m.$2},${m.$3})';
  if (_foldedText.length > 300) _foldedText.clear();
  final text = _foldedText.putIfAbsent('${ops.name}|${c.$1}', () {
    final x = _night(f, n, seed);
    final s = ops.fresh(cfg);
    ops.fold(s, x.nn, x.t);
    return _text(ops, s);
  });
  final src = (jsonDecode(text) as Map).cast<String, dynamic>();
  final (bad, must) = _mutate(ops, src, m);
  expectMutationOutcome(
      _outcome(ops, bad), must, jsonEncode(bad), jsonEncode(src), tag);
}

void _l4<S>(_Ops<S> ops, _Case c) {
  final ((f, n, seed, cfg), (_, _, _, ev)) = c;
  final x = _night(f, n, seed);
  final tag = _tag(ops, c);
  final freshText = _text(ops, ops.fresh(cfg));
  final empty = ops.fresh(cfg);
  ops.fold(empty, const [], const []);
  expect(_text(ops, empty), freshText, reason: '$tag: an empty first fold records nothing');
  final cut = n ~/ 2;
  final s = ops.fresh(cfg);
  ops.fold(s, x.nn.sublist(0, cut), x.t.sublist(0, cut));
  final before = _text(ops, s);
  ops.fold(s, const [], const []);
  expect(_text(ops, s), before, reason: '$tag: an empty fold is the identity');
  final one = ops.show(ops.snapshot(s, ev, const [], const []));
  final end = math.min(n, cut + 50);
  ops.snapshot(s, ev, x.nn.sublist(cut, end), x.t.sublist(cut, end));
  expect(_text(ops, s), before, reason: '$tag: snapshot never writes');
  expect(ops.show(ops.snapshot(s, ev, const [], const [])), one,
      reason: '$tag: twice is equal');
  // Refused folds change nothing.
  void refused(String what, void Function() call, Matcher throws) {
    expect(call, throws, reason: '$tag: $what is refused');
    expect(_text(ops, s), before, reason: '$tag: $what leaves the stream unchanged');
  }

  refused('lengths that differ',
      () => ops.fold(s, const [800.0, 810.0], [_t0 + 9e9]), throwsArgumentError);
  if (ops.refusesNonFiniteTimes) {
    final last = cut == 0 ? _t0 : x.t[cut - 1];
    for (final bad in [double.nan, double.infinity]) {
      refused('a beat time of $bad',
          () => ops.fold(s, const [800.0, 810.0], [last + 800, bad]),
          throwsArgumentError);
    }
  }
  if (cut > 0) {
    refused('a time that steps back',
        () => ops.fold(s, const [800.0], [x.t[cut - 1] - 1000]), throwsStateError);
  }
}

void _l5<S>(_Ops<S> ops, _Case c) {
  final ((f, n, seed, cfg), (_, _, restart, _)) = c;
  final x = _night(f, n, seed);
  final tag = _tag(ops, c);
  _drive(ops, x, cfg, _boundsOf(c), restart, (s, k, at) {
    final cp = (jsonDecode(_text(ops, s)) as Map).cast<String, dynamic>();
    expect(cp['n'], at, reason: '$tag at $at: every folded beat counted once');
    ops.conserved(cp, x.nn.sublist(0, at), x.t.sublist(0, at), cfg, '$tag at $at');
  });
}

Map<String, double> _sharesOf(_Ops ops) => {
      for (final f in _flavours) 'flavour: $f': .05,
      'beats: under 20': .02,
      'beats: past 700': .25,
      'config: not the default': ops.nCfg > 1 ? .2 : 0,
      'chunks: three or more': .3,
      'an empty chunk': .03,
      'a restore between chunks': .2,
      for (var e = 0; e < ops.nEv; e++) 'evaluation: $e': .04,
    }..removeWhere((_, v) => v == 0);

void _observe(_Ops ops, _Case c, void Function(String) bump) {
  final ((f, n, _, cfg), (_, _, restart, ev)) = c;
  bump('flavour: ${_flavours[f]}');
  if (n > 0 && n < 20) bump('beats: under 20');
  if (n > 700) bump('beats: past 700');
  if (cfg != 0) bump('config: not the default');
  final b = _boundsOf(c);
  if (b.length >= 4) bump('chunks: three or more');
  if (hasEmptyChunk(b)) bump('an empty chunk');
  if (restart != 0 && b.length > 2) bump('a restore between chunks');
  bump('evaluation: $ev');
  ops.observe(c, bump);
}

void _register<S>(_Ops<S> ops, {int maxN = 1200, int cases = 60}) {
  const pool = [0, 1, 15, 16, 19, 20, 59, 60, 61, 300, 700, 1200];
  final shares = {..._sharesOf(ops), ...ops.shares};
  final reach = Reach<_Case>(shares, (c, bump) => _observe(ops, c, bump));
  final noEval = Reach<_Case>({
    for (final e in shares.entries)
      if (!e.key.startsWith('evaluation: ')) e.key: e.value
  }, (c, bump) => _observe(ops, c, bump));
  group(ops.name, () {
    _laws.law<_Case>(
      'L1 ${ops.name}: any chunking, empty chunks and restores included, gives '
      'the checkpoint text and every snapshot of one fold',
      _caseGen(ops, maxN, pool),
      (c) => _l1(ops, c),
      examples: ops.forced,
      cases: cases,
      reach: noEval,
    );
    _laws.law<_Case>(
      'L1b ${ops.name}: snapshot(tail) at a seam is the batch of settled ++ '
      'tail, bit for bit',
      _caseGen(ops, maxN, pool),
      (c) => _l1b(ops, c),
      examples: ops.forced,
      cases: cases,
      reach: reach,
    );
    _laws.law<_Case>(
      'L2 ${ops.name}: write(read(b)) == b, the restored stream reads the same '
      'and goes on identically',
      _caseGen(ops, maxN, pool),
      (c) => _l2(ops, c),
      examples: ops.forced,
      cases: cases,
      reach: noEval,
    );
    _laws.law<(_Case, Mut)>(
      'L3 ${ops.name}: another version or type, a missing, mistyped or '
      'inconsistent part is refused whole; a changed number is held exactly',
      G.pair(_caseGen(ops, 1200, pool), mutGen(7)),
      (arg) => _l3(ops, arg),
      examples: [
        for (var i = 0; i < ops.forced.length; i++)
          for (var k = 0; k < 7; k++) (ops.forced[i], (k, 3 * i + k, 5 * i + 2 * k)),
        for (var a = 0; a < ops.badVersions.length; a++) (ops.forced.last, (0, a, 0)),
        for (var a = 0; a < 40; a++) (ops.forced.last, (2, a, 0)),
        for (var a = 0; a < ops.refuseMutations.length; a++) (ops.forced.last, (4, a, 0)),
        for (var a = 0; a < ops.faithfulMutations.length; a++) (ops.forced.last, (5, a, 0)),
      ],
      cases: 100,
      reach: Reach<(_Case, Mut)>({
        for (var k = 0; k < 7; k++) 'kind: $k': .05,
      }, (arg, bump) => bump('kind: ${arg.$2.$1 % 7}')),
    );
    _laws.law<_Case>(
      'L4 ${ops.name}: an empty fold is the identity, snapshot never writes, a '
      'refused fold leaves the stream unchanged',
      _caseGen(ops, maxN, pool),
      (c) => _l4(ops, c),
      examples: ops.forced,
      cases: cases,
      reach: reach,
    );
    _laws.law<_Case>(
      'L5 ${ops.name}: every folded beat is counted once, and what the stream '
      'kept and closed is what the input says',
      _caseGen(ops, maxN, pool),
      (c) => _l5(ops, c),
      examples: ops.forced,
      cases: cases,
      reach: noEval,
    );
  });
}

_Case _c(int flavour, int n,
        {int seed = 3, int cfg = 0, int splits = 4, int cut = 1, int restart = 0, int ev = 0}) =>
    ((flavour, n, seed, cfg), (splits, cut, restart, ev));

// ═════════════════════════════════════════════════════════════════════════════
// RsaRespStream
// ═════════════════════════════════════════════════════════════════════════════

/// (artifactFraction, tolBrpm, minConsensus, maxArtifact).
const List<(double, double, double, double)> _rsaEvals = [
  (.02, 2.0, .5, .30),
  (0.0, 2.0, .5, .30),
  (.31, 2.0, .5, .30), // over the artifact gate
  (.30, 2.0, .5, .30), // exactly at it: passes
  (.10, 1.0, .7, .30), // a tighter agreement test
  (.05, 3.0, .3, .50),
];

/// The sub-window starts of the batch walk over [t] (seconds), and the
/// segment length it uses.
(int, double) _rsaWalk(List<double> tSec) {
  final span = tSec.last - tSec.first;
  var segSec = rsaSegmentSec;
  if (span < 2 * segSec) segSec = span / 2;
  var k = 0;
  for (var i = 0;; i++) {
    final s = tSec.first + i * (segSec / 2);
    if (s + segSec > tSec.last + 1e-9) break;
    k++;
  }
  return (k, segSec);
}

class _RsaOps extends _Ops<RsaRespStream> {
  @override
  String get name => 'RsaRespStream';
  @override
  String get type => 'RsaRespStream';
  @override
  int get nCfg => 1;
  @override
  int get nEv => _rsaEvals.length;
  @override
  RsaRespStream fresh(int cfg) => RsaRespStream();
  @override
  void fold(RsaRespStream s, List<double> nn, List<double> t) => s.fold(nn, t);
  @override
  Metric snapshot(RsaRespStream s, int ev, List<double> tailNn, List<double> tailT) {
    final e = _rsaEvals[ev];
    return s.snapshot(
        tailNnMs: tailNn,
        tailNnTimesMs: tailT,
        artifactFraction: e.$1,
        tolBrpm: e.$2,
        minConsensus: e.$3,
        maxArtifact: e.$4);
  }

  @override
  Metric batch(List<double> nn, List<double> t, int cfg, int ev) {
    final e = _rsaEvals[ev];
    return rsaRespRate(nn, t,
        artifactFraction: e.$1, tolBrpm: e.$2, minConsensus: e.$3, maxArtifact: e.$4);
  }

  @override
  String showValue(Object v) {
    final r = v as RespEstimate;
    return '${_d(r.brpm)}|${_d(r.peakHz)}|${_d(r.power)}|${r.source}|'
        '${r.usableSubwindows}|${r.subwindows}';
  }

  @override
  Json toJson(RsaRespStream s) => s.toJson();
  @override
  RsaRespStream fromJson(Json j) => RsaRespStream.fromJson(j);

  @override
  List<Object?> get badVersions =>
      const [1, 0, 3, -1, '2', null, true, 2.5, 1 << 40];

  @override
  List<void Function(Json)> get refuseMutations => [
        (j) => (j['nn'] as List).add(800.0), // nn and times disagree
        (j) => (j['sorted'] as List).add(800.0), // more sorted values than beats
        (j) {
          final s = j['sorted'] as List;
          if (s.length >= 2 && s.first != s.last) {
            j['sorted'] = s.reversed.toList(); // not sorted
          }
        },
        (j) {
          if ((j['n'] as int) > 0) j['first'] = null; // beats without a start
        },
        (j) {
          if ((j['n'] as int) == 0) j['first'] = 0.0; // a start without beats
        },
        (j) => (j['closed'] as List).add({
              'kind': 5, // no such sub-window outcome
              'brpm': null,
              'peakHz': null,
              'power': null,
              'ceiling': null
            }),
        (j) => (j['closed'] as List).add({
              'kind': 0, // a usable peak without its numbers
              'brpm': null,
              'peakHz': null,
              'power': null,
              'ceiling': null
            }),
        (j) => (j['closed'] as List).add({
              'kind': 1, // at the ceiling, without the ceiling
              'brpm': null,
              'peakHz': null,
              'power': null,
              'ceiling': null
            }),
        (j) {
          final t = j['times'] as List;
          if (t.length >= 2 && t.first != t.last) {
            j['times'] = t.reversed.toList(); // times that step back
          }
        },
      ];

  @override
  List<void Function(Json)> get faithfulMutations => [
        (j) {
          for (final c in j['closed'] as List) {
            final m = c as Map;
            if (m['kind'] == 0) {
              m['brpm'] = (m['brpm'] as num) + 1.0;
              return;
            }
          }
        },
        (j) {
          if (j['nextStart'] != null) j['nextStart'] = (j['nextStart'] as num) + 1.0;
        },
        (j) {
          final nn = j['nn'] as List;
          if (nn.isNotEmpty && nn[0] is num) nn[0] = (nn[0] as num) + 1.0;
        },
        (j) => (j['closed'] as List).add({
              'kind': 3, // one more thin sub-window
              'brpm': null,
              'peakHz': null,
              'power': null,
              'ceiling': null
            }),
      ];

  @override
  void conserved(Json cp, List<double> nn, List<double> t, int cfg, String why) {
    // The sorted multiset of every folded NN, in double.compareTo order.
    final sorted = [...nn]..sort();
    expect(jsonEncode(cp['sorted']),
        jsonEncode([for (final v in sorted) v.isFinite ? v : v.toString()]),
        reason: 'the sorted NN are every folded NN once $why');
    // Closed sub-windows: the starts first + i*150 s whose window ends before
    // the last beat (by more than 1e-9 s), once the span reaches 600 s.
    final closed = (cp['closed'] as List).length;
    var want = 0;
    if (t.isNotEmpty) {
      final first = t.first / 1000, last = t.last / 1000;
      if (last - first >= 2 * rsaSegmentSec) {
        while (first + want * (rsaSegmentSec / 2) + rsaSegmentSec < last - 1e-9) {
          want++;
        }
      }
    }
    expect(closed, want, reason: 'closed sub-windows $why');
    // A reported rate rests on the sub-windows the batch walk visits.
    final m = snapshot(fromJson(cp), 1, const [], const []);
    if (m.present) {
      final r = m.value as RespEstimate;
      final (k, _) = _rsaWalk([for (final x in t) x / 1000]);
      expect(r.subwindows, k, reason: 'sub-windows tried $why');
      expect(r.usableSubwindows! >= 3 && r.usableSubwindows! <= k, isTrue,
          reason: 'usable sub-windows $why');
    }
  }

  @override
  Map<String, double> get shares => {
        'a rate': .05,
        'withheld below the HF band': .02,
        'a gap that empties a sub-window': .01,
      };

  @override
  void observe(_Case c, void Function(String) bump) {
    final ((f, n, _, _), _) = c;
    if (n > 700 && (f == 0 || f == 4)) bump('a rate');
    if (n > 30 && f == 1) bump('withheld below the HF band');
    if (n > 750 && f == 2) bump('a gap that empties a sub-window');
  }

  @override
  List<_Case> get forced => [
        _c(0, 0),
        _c(0, 19, ev: 1),
        _c(0, 20, ev: 1),
        _c(0, 700, splits: 5, cut: 2, restart: 85),
        _c(0, 1600, splits: 6, cut: 3, restart: 127, ev: 1),
        _c(1, 900, ev: 1), // withheld: the ceiling is under the band
        _c(2, 1600, splits: 6, cut: 4, restart: 42, ev: 1), // gappy
        _c(4, 1800, splits: 5, cut: 5, ev: 4), // whole seconds
        _c(5, 1500, splits: 4, cut: 6, restart: 3, ev: 5), // outliers and NaN
        _c(3, 1500, ev: 2), // over the artifact gate
        _c(0, 1500, splits: 6, cut: 7, ev: 3), // exactly at it
      ];
}

// ═════════════════════════════════════════════════════════════════════════════
// HrvFreqStream
// ═════════════════════════════════════════════════════════════════════════════

const _oversamples = [4.0, 2.0, 8.0];

/// (artifactFraction, hfArtifactGate).
const List<(double, double)> _hrvEvals = [
  (.02, .15),
  (.20, .15), // HF gated
  (.15, .15), // exactly at the gate: not gated
  (0.0, .05),
];

/// Band lower edges: the segment of a band is 10 / lo seconds.
const _bandLo = [0.0003, 0.003, 0.04, 0.15];

class _HrvOps extends _Ops<HrvFreqStream> {
  @override
  String get name => 'HrvFreqStream';
  @override
  String get type => 'HrvFreqStream';
  @override
  int get nCfg => _oversamples.length;
  @override
  int get nEv => _hrvEvals.length;
  @override
  HrvFreqStream fresh(int cfg) => HrvFreqStream(oversample: _oversamples[cfg]);
  @override
  void fold(HrvFreqStream s, List<double> nn, List<double> t) => s.fold(nn, t);
  @override
  Metric snapshot(HrvFreqStream s, int ev, List<double> tailNn, List<double> tailT) {
    final e = _hrvEvals[ev];
    return s.snapshot(
        tailNnMs: tailNn,
        tailNnTimesMs: tailT,
        artifactFraction: e.$1,
        hfArtifactGate: e.$2);
  }

  @override
  Metric batch(List<double> nn, List<double> t, int cfg, int ev) {
    final e = _hrvEvals[ev];
    return hrvFreq(nn, t,
        artifactFraction: e.$1, hfArtifactGate: e.$2, oversample: _oversamples[cfg]);
  }

  @override
  String showValue(Object v) {
    final h = v as HrvFreq;
    return [
      for (final x in [h.ulf, h.vlf, h.lf, h.hf, h.total, h.lfhf, h.nuLf, h.nuHf]) _d(x),
      h.totalBands,
      h.hfGated,
    ].join('|');
  }

  @override
  Json toJson(HrvFreqStream s) => s.toJson();
  @override
  HrvFreqStream fromJson(Json j) => HrvFreqStream.fromJson(j);

  @override
  List<Object?> get badVersions => const [0, 2, -1, '1', null, true, 1.5, 1 << 40];

  @override
  List<void Function(Json)> get refuseMutations => [
        (j) => (j['nn'] as List).add(800.0), // nn and times disagree
        (j) => (j['bands'] as List).removeLast(), // three bands
        (j) => j['oversample'] = 0.0,
        (j) => j['oversample'] = -4.0,
        (j) {
          if ((j['n'] as int) > 0) j['last'] = null;
        },
        (j) {
          if ((j['n'] as int) == 0) j['first'] = 0.0;
        },
        (j) => ((j['bands'] as List).first as Map)['count'] = -1,
        (j) {
          final t = j['times'] as List;
          if (t.length >= 2 && t.first != t.last) j['times'] = t.reversed.toList();
        },
      ];

  @override
  List<void Function(Json)> get faithfulMutations => [
        (j) {
          final b = (j['bands'] as List)[2] as Map;
          b['sum'] = (b['sum'] as num) + 1.0;
        },
        (j) {
          final b = (j['bands'] as List)[3] as Map;
          b['count'] = (b['count'] as int) + 1;
        },
        (j) {
          final b = (j['bands'] as List)[1] as Map;
          b['nextStart'] = (b['nextStart'] as num) + 1.0;
        },
        (j) => j['oversample'] = 3.0,
      ];

  @override
  void conserved(Json cp, List<double> nn, List<double> t, int cfg, String why) {
    // A band has used at most the segments it has stepped over, and has stepped
    // only over segments that end by the last beat.
    final bands = cp['bands'] as List;
    for (var i = 0; i < 4; i++) {
      final b = bands[i] as Map;
      final count = b['count'] as int;
      if (t.isEmpty) {
        expect(count, 0, reason: 'no beats, no segments $why');
        continue;
      }
      final segSec = 10.0 / _bandLo[i];
      final first = t.first / 1000, last = t.last / 1000;
      var stepped = 0;
      for (var s = first; s + segSec <= last; s += segSec / 2) {
        stepped++;
      }
      final next = (b['nextStart'] as num).toDouble();
      var walked = 0;
      for (var s = first; s < next; s += segSec / 2) {
        walked++;
      }
      expect(walked, stepped, reason: 'band $i stepped over every ended segment $why');
      expect(count <= stepped, isTrue, reason: 'band $i used segments $why');
    }
  }

  @override
  Map<String, double> get shares => {
        'LF and HF resolved': .05,
        'gated HF': .02,
      };

  @override
  void observe(_Case c, void Function(String) bump) {
    final ((f, n, _, _), (_, _, _, ev)) = c;
    if (n > 700 && f != 5) bump('LF and HF resolved');
    if (n > 700 && ev == 1) bump('gated HF');
  }

  @override
  List<_Case> get forced => [
        _c(0, 0),
        _c(0, 15, ev: 1),
        _c(0, 16, ev: 1),
        _c(0, 700, splits: 5, cut: 2, restart: 85),
        _c(0, 1600, splits: 6, cut: 3, restart: 127, cfg: 1),
        _c(2, 1600, splits: 6, cut: 4, restart: 42, cfg: 2, ev: 1), // gappy, gated
        _c(4, 1800, splits: 5, cut: 5, ev: 2), // whole seconds, at the gate
        _c(5, 1500, splits: 4, cut: 6, restart: 3, ev: 3), // outliers and NaN
        _c(1, 1500, ev: 0),
        _c(3, 1500, splits: 6, cut: 7, ev: 0),
      ];
}

// ═════════════════════════════════════════════════════════════════════════════
// CvhrStream
// ═════════════════════════════════════════════════════════════════════════════

/// (minWidthSec, maxWidthSec, depthWidthRatioMin, envWindowSec, maxGapSec).
const List<(double, double, double, double, double)> _cvhrCfgs = [
  (10, 120, .7, 130, 30),
  (5, 60, .5, 90, 10),
  (10, 120, 1.2, 200, 60),
];

/// (artifactFraction, maxArtifact).
const List<(double, double)> _cvhrEvals = [
  (.02, .30),
  (.31, .30), // over the gate
  (.30, .30), // exactly at it
  (0.0, .10),
];

class _CvhrOps extends _Ops<CvhrStream> {
  @override
  String get name => 'CvhrStream';
  @override
  String get type => 'CvhrStream';
  @override
  int get nCfg => _cvhrCfgs.length;
  @override
  int get nEv => _cvhrEvals.length;
  @override
  CvhrStream fresh(int cfg) {
    final c = _cvhrCfgs[cfg];
    return CvhrStream(
        minWidthSec: c.$1,
        maxWidthSec: c.$2,
        depthWidthRatioMin: c.$3,
        envWindowSec: c.$4,
        maxGapSec: c.$5);
  }

  @override
  void fold(CvhrStream s, List<double> nn, List<double> t) => s.fold(nn, t);
  @override
  Metric snapshot(CvhrStream s, int ev, List<double> tailNn, List<double> tailT) {
    final e = _cvhrEvals[ev];
    return s.snapshot(
        tailNnMs: tailNn, tailNnTimesMs: tailT, artifactFraction: e.$1, maxArtifact: e.$2);
  }

  @override
  Metric batch(List<double> nn, List<double> t, int cfg, int ev) {
    final c = _cvhrCfgs[cfg];
    final e = _cvhrEvals[ev];
    return cvhrApneaScreen(nn, t,
        artifactFraction: e.$1,
        maxArtifact: e.$2,
        minWidthSec: c.$1,
        maxWidthSec: c.$2,
        depthWidthRatioMin: c.$3,
        envWindowSec: c.$4,
        maxGapSec: c.$5);
  }

  @override
  String showValue(Object v) {
    final r = v as CvhrResult;
    return '${r.cycleCount}|${_d(r.cvhrPerHour)}|${_d(r.analyzedHours)}|'
        '${_d(r.meanDepthMs)}|${_d(r.meanWidthSec)}|'
        '${r.depthQuartilesMs?.map(_d).toList()}|${r.widthQuartilesSec?.map(_d).toList()}';
  }

  @override
  Json toJson(CvhrStream s) => s.toJson();
  @override
  CvhrStream fromJson(Json j) => CvhrStream.fromJson(j);

  @override
  List<Object?> get badVersions => const [0, 2, -1, '1', null, true, 1.5, 1 << 40];

  @override
  List<void Function(Json)> get refuseMutations => [
        (j) => (j['rawNn'] as List).add(800.0), // rawNn and rawTimes disagree
        (j) => (j['exc'] as List).add(0.0), // exc and base disagree
        (j) => j['openCount'] = (j['n'] as int) + 1, // more open beats than beats
        (j) {
          if ((j['n'] as int) > 0) j['openStart'] = null;
        },
        (j) {
          if ((j['n'] as int) == 0) j['first'] = 0.0;
        },
        (j) => j['maxGapSec'] = 'Infinity',
        (j) => (j['closed'] as List).add({
              'hours': -1.0, // negative observed hours
              'depths': <double>[],
              'widths': <double>[]
            }),
        (j) => (j['closed'] as List).add({
              'hours': 1.0, // depths and widths disagree
              'depths': [1.0],
              'widths': <double>[]
            }),
      ];

  @override
  List<void Function(Json)> get faithfulMutations => [
        (j) {
          final g = j['grid'] as List;
          if (g.isNotEmpty) g[0] = (g[0] as num) + 1.0;
        },
        (j) => (j['closed'] as List).add({
              'hours': 0.5,
              'depths': [12.0],
              'widths': [20.0]
            }),
        (j) => j['envWindowSec'] = (j['envWindowSec'] as num) + 2.0,
      ];

  @override
  void conserved(Json cp, List<double> nn, List<double> t, int cfg, String why) {
    // The open stretch holds exactly the beats since the last gap longer than
    // maxGapSec (all of them when there is none).
    final gap = _cvhrCfgs[cfg].$5;
    var open = 0;
    for (var i = 0; i < t.length; i++) {
      if (i > 0 && t[i] / 1000 - t[i - 1] / 1000 > gap) open = 0;
      open++;
    }
    expect(cp['openCount'], open, reason: 'beats of the open stretch $why');
    // Closed stretches observe no more hours than the input spans.
    var hours = 0.0;
    for (final c in cp['closed'] as List) {
      hours += ((c as Map)['hours'] as num).toDouble();
    }
    final span = t.isEmpty ? 0.0 : (t.last - t.first) / 3.6e6;
    expect(hours <= span + 1e-9, isTrue, reason: 'closed hours within the span $why');
  }

  @override
  Map<String, double> get shares => {
        'cycles to find': .02,
        'several stretches': .03,
      };

  @override
  void observe(_Case c, void Function(String) bump) {
    final ((f, n, _, _), _) = c;
    if (n > 300 && f == 3) bump('cycles to find');
    if (n > 400 && f == 2) bump('several stretches');
  }

  @override
  List<_Case> get forced => [
        _c(0, 0),
        _c(3, 59, ev: 0),
        _c(3, 60, ev: 0),
        _c(3, 700, splits: 5, cut: 2, restart: 85),
        _c(3, 1600, splits: 6, cut: 3, restart: 127, cfg: 1),
        _c(2, 1600, splits: 6, cut: 4, restart: 42, cfg: 2), // gappy
        _c(4, 1800, splits: 5, cut: 5, ev: 2), // whole seconds, at the gate
        _c(5, 1500, splits: 4, cut: 6, restart: 3, ev: 3), // outliers and NaN
        _c(3, 1500, ev: 1), // over the gate
        _c(0, 1500, splits: 6, cut: 7),
      ];
}

void main() {
  _register(_RsaOps());
  _register(_HrvOps());
  _register(_CvhrOps());

  group('the forced cases say what they claim', () {
    test('RSA: a rate, a withheld slow heart, gappy sub-windows', () {
      final ops = _RsaOps();
      final notes = <String>[];
      var rate = false;
      for (final c in ops.forced) {
        final ((f, n, seed, cfg), (_, _, _, ev)) = c;
        final x = _night(f, n, seed);
        final m = ops.batch(x.nn, x.t, cfg, ev);
        if (m.present) rate = true;
        notes.add(m.note ?? '');
      }
      expect(rate, isTrue, reason: 'a rate among the forced nights');
      expect(notes.any((s) => s.startsWith('sleeping heart rate')), isTrue,
          reason: 'a night withheld below the HF band');
      expect(notes.any((s) => s.contains('artifact fraction')), isTrue);
    });

    test('HrvFreq: resolved bands, a gated HF', () {
      final ops = _HrvOps();
      var resolved = false, gated = false;
      for (final c in ops.forced) {
        final ((f, n, seed, cfg), (_, _, _, ev)) = c;
        final x = _night(f, n, seed);
        final m = ops.batch(x.nn, x.t, cfg, ev);
        final v = m.value as HrvFreq?;
        if (v != null && v.lf != null && v.hf != null) resolved = true;
        if (v != null && v.hfGated) gated = true;
      }
      expect(resolved, isTrue);
      expect(gated, isTrue);
    });

    test('CVHR: cycles found, an artifact abstention', () {
      final ops = _CvhrOps();
      var cycles = false, gate = false;
      for (final c in ops.forced) {
        final ((f, n, seed, cfg), (_, _, _, ev)) = c;
        final x = _night(f, n, seed);
        final m = ops.batch(x.nn, x.t, cfg, ev);
        if (m.present && (m.value as CvhrResult).cycleCount > 0) cycles = true;
        if (!m.present && (m.note ?? '').contains('artifact fraction')) gate = true;
      }
      expect(cycles, isTrue);
      expect(gate, isTrue);
    });
  });

  _laws.registerReachTest();
}
