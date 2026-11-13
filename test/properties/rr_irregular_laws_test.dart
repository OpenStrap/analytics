// LAWS of the streaming RR cleaning and the irregular-rhythm screen (design 05,
// pilot cluster C2A, analytics side): `RrCorrector` (foundations/
// rr_correction_stream.dart), `IrregularScreenState` (clinical/
// irregular_rhythm_state.dart) and the diagnostics they report
// (`IrregularDiagnostics`, clinical/irregular_diagnostics.dart), alone and
// integrated the way the day pass uses them (corrector settles NN, the screen
// folds it, the corrector's provisional tail and counts are handed to
// `evaluateDetailed`).
//
//   L1   chunk invariance: any VALID chunking of the input (empty chunks and a
//        save/restore through real JSON text between chunks included) gives the
//        same checkpoint TEXT, the same settled output and the same snapshot as
//        one fold of the whole input. This is NOT a monoid claim (neither module
//        has a `combine`); it is a law of the append transition. The documented
//        refusals (mixing timestamped and timestamp-free folds, a non-finite RR
//        or timestamp, a length mismatch) are asserted as refusals that leave
//        the state unchanged.
//   L1b  streamed vs batch: at every checked seam `settled ++ snapshot` is
//        `correctRr` of the prefix bit for bit (the FROZEN reference copy for
//        short series, the production batch beyond the reference's budget), and
//        the screen is the batch screen: counts, flags, abstentions and the
//        diagnostics text exact; SD1 / SD2 / ratio within 1e-9 relative and
//        confidence within 1e-12 (running sums against a two-pass batch). The
//        window counts are checked against a window partition written HERE,
//        independently of `irregularWindowVerdict` (which both sides share).
//   L2   checkpoint round trip: `toJson` -> real JSON text -> `fromJson` ->
//        `toJson` is the same text, and the restored object reads what the live
//        one reads on an explicit projection and goes on identically.
//   L3   a checkpoint of another type or version, a truncated, padded or
//        inconsistent one, hostile counts, parts that disagree: refused whole
//        with a FormatException (never another error type, never a half-built
//        object). A mutation the reader cannot tell from a legal checkpoint
//        (one number changed) may be accepted, but then the object holds exactly
//        what was written: nothing is silently normalised.
//   L4   identity: an empty chunk leaves a checkpoint unchanged (the corrector
//        records NOTHING on a first empty fold, not even whether timestamps are
//        used), `evaluate*` never changes the state it reads, and the other
//        way round a refused fold leaves the state unchanged.
//   L5   conservation, integrated, provisional NN included: nn_in == rr_raw -
//        dropped; normal + corrected + dropped == beats; the windows cover the
//        kept NN (independent partition); flagged <= valid <= total <= kept; an
//        invalid window config gives NO window evidence and cannot flag; the
//        artifact fraction is a share of the beats the corrector saw, or ABSENT
//        (null, never 1.0) when it saw none (0fc5768).
//   W    the diagnostics wire (what edge persists): round trip through JSON
//        text, refusal of another version / unknown reason / malformed map, and
//        the "absent, not zero" rules for the cleaning counts.
//
// The laws describe the code at analytics 0fc57682, with upstream's screen
// rules since (f026a4e merge): a pair across a time hole is not successive, the
// beat gate and window validity count successive pairs (minBeats - 1), and the
// screen checkpoint is version 3 (it carries the previous beat's time). A failing law is first
// checked against the module's contract; only a violation of the intended
// contract is a bug, and a wrong oracle is fixed here, never in lib/.
//
// A series is a RECIPE (flavour, beats, seed, ...) expanded deterministically,
// so a failing input shrinks to a few readable integers, not to thousands of
// doubles. Beats are capped at 3,000 per series and the chunking at 6 split
// points. No clock is read.
//
// Replay a failure with the command in its report, e.g.
//   PROPERTY_SEED=<s> PROPERTY_CASE=<n> TZ=UTC dart test \
//     test/properties/rr_irregular_laws_test.dart --plain-name '<name>'

import 'dart:convert';
import 'dart:math' as math;

import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

import '../onehz/support/correct_rr_reference.dart';
import '../onehz/support/rr_compare.dart';
import '../support/fold_law_support.dart';
import '../support/law_registry.dart';
import '../support/property.dart';

final _laws = LawSet();

// ── the recipe of a beat series ─────────────────────────────────────────────

const _flavours = [
  'clean', // regular beats, a little jitter
  'mixed', // ectopic pairs, missed / extra beats, noise runs, dropouts
  'flagged', // irregularly irregular (AF-like) throughout
  'gappy', // a dropout every 90 beats
  'backwards', // a beat time that steps back now and then
  'artefact heavy', // many artefacts + one run of 120 (longer than the window)
  'flat', // constant RR: QD = 0, massive ties
  'outliers', // flat, with an outlier at the start, middle and end
  'edge gaps', // dropouts of exactly, one under and one over each re-anchor gap
  'hard limits', // 300 and 2000 exactly, then a too-long and a too-short beat
];
const int _nFlavours = 10;

/// 2025-10-09 08:53:20 UTC in ms: a whole second, as production stamps are.
const double _t0 = 1760000000000;

/// Corrector parameters: (alpha, windowBeats, minThresholdMs, reanchorGapMs).
/// Index 0 is the default. They travel in the checkpoint.
const List<(double, int, double, double)> _corrCfgs = [
  (5.2, 91, 100, 1000),
  (5.2, 31, 100, 1000),
  (4.0, 61, 100, 1000),
  (6.5, 91, 30, 400),
  (5.2, 4, 0, 1000),
  (5.2, 90, 100, 5000),
  (5.2, 1, 100, 1000), // a window of one beat: no look-ahead at all
  (5.2, 2, 100, 1000),
  (5.2, 3, 30, 400),
];

RrCorrector _newCorrector(int cfg) {
  final c = _corrCfgs[cfg];
  return RrCorrector(
    maxArtifactRun: null, // This harness pins the uncapped pipeline layout.
      alpha: c.$1, windowBeats: c.$2, minThresholdMs: c.$3, reanchorGapMs: c.$4);
}

class _Series {
  _Series(this.rr, this.ts);
  final List<double> rr, ts;
  int get n => rr.length;
}

final Map<(int, int, int), _Series> _seriesCache = {};

/// The beats of a recipe (cached: expansion is not the cost under test).
_Series _series(int flavour, int n, int seed) =>
    _seriesCache.putIfAbsent((flavour, n, seed), () {
      if (_seriesCache.length > 400) _seriesCache.clear();
      return _expandSeries(flavour, n, seed);
    });

_Series _expandSeries(int flavour, int n, int seed) {
  final r = Rng(seed * 7919 + flavour * 131 + 11);
  final rr = <double>[], ts = <double>[];
  var clock = _t0;
  void emit(double v) {
    final e = v.roundToDouble();
    clock += e;
    rr.add(e);
    // End-of-beat time quantised to whole seconds (rec_ts * 1000).
    ts.add(flavour == 8 ? clock : (clock / 1000).floorToDouble() * 1000);
  }

  var longRun = false;
  while (rr.length < n) {
    final i = rr.length;
    final v = 800 + 40 * math.sin(i / 70) + 12 * (r.nextDouble() - .5);
    switch (flavour) {
      case 1:
      case 5:
        final u = r.nextDouble();
        final heavy = flavour == 5;
        if (heavy && !longRun && i >= n ~/ 3 && n >= 240) {
          longRun = true;
          for (var k = 0; k < 120; k++) {
            emit(250 + r.nextInt(2100).toDouble());
          }
        } else if (u < (heavy ? .08 : .02) && i > 3) {
          emit(v * .6);
          emit(v * 1.4);
        } else if (u < (heavy ? .10 : .03)) {
          emit(v * 1.95);
        } else if (u < (heavy ? .12 : .04)) {
          emit(v * .5);
          emit(v * .5);
        } else if (u < (heavy ? .14 : .046)) {
          for (var k = 3 + r.nextInt(10); k > 0; k--) {
            emit(250 + r.nextInt(2100).toDouble());
          }
        } else if (!heavy && u < .051) {
          clock += 5000 + r.nextInt(300000);
          emit(v);
        } else {
          emit(v);
        }
      case 2:
        emit(420 + r.nextInt(700).toDouble());
      case 3:
        if (i % 90 == 89) clock += 5000 + r.nextInt(115000);
        emit(v);
      case 4:
        emit(v);
        if (i % 97 == 96) ts[ts.length - 1] -= 1000.0 * (1 + r.nextInt(3));
      case 6:
        emit(800);
      case 7:
        emit(i == 0 || i == n ~/ 2 || i == n - 1 ? 1300 : 800);
      case 9:
        // The edges of the plausible range, exactly, then one beat past each:
        // 300 and 2000 are plausible, 2500 and 250 are not.
        emit(i < 4 ? const [300.0, 2000.0, 2500.0, 250.0][i] : v);
      case 8:
        // The wall-clock step exceeds the beat by exactly the re-anchor gap of
        // one of the configs (400, 1000, 5000 ms), one ms under it, one over.
        emit(v);
        if (i % 12 == 11) {
          const gaps = [400.0, 399.0, 401.0, 1000.0, 999.0, 1001.0, 5000.0, 4999.0, 5001.0];
          clock += gaps[(i ~/ 12) % gaps.length];
          ts[ts.length - 1] = clock; // (exact milliseconds, not whole seconds)
        }
      default:
        emit(v);
    }
  }
  if (rr.length > n) {
    rr.removeRange(n, rr.length);
    ts.removeRange(n, ts.length);
  }
  return _Series(rr, ts);
}

// ── the recipe of a chunking ────────────────────────────────────────────────

/// (flavour, beats, seed, mode: 0 timestamps given, 1 none).
typedef _Rec = (int, int, int, int);

/// (splits, cut seed, restart mask, corrector config index).
typedef _Plan = (int, int, int, int);
typedef _Case = (_Rec, _Plan);

class _FlavourGen extends Gen<int> {
  @override
  int generate(Rng r, int size) => r.nextInt(_nFlavours);
  @override
  Iterable<int> shrink(int v) => G.intIn(0, _nFlavours - 1).shrink(v);
}

/// Beat counts: the shapes that matter (empty, under 3, the window edges 45 /
/// 91 and their neighbours), then growing with the case index up to [maxN].
class _NGen extends Gen<int> {
  _NGen(this.maxN);
  final int maxN;
  static const _pool = [
    0, 1, 2, 3, 4, 5, 10, 44, 45, 46, 47, 89, 90, 91, 92, 93, 94, 135, 136, //
    137, 181, 182, 183, 272, 273,
  ];
  @override
  int generate(Rng r, int size) {
    final p = r.nextDouble();
    if (p < .04) return 0;
    if (p < .29) {
      final ok = [for (final x in _pool) if (x <= maxN) x];
      return ok[r.nextInt(ok.length)];
    }
    if (p < .40) return r.intIn(math.min(500, maxN), maxN);
    final cap = math.max(120, maxN * size ~/ 100);
    if (p < .62) return r.intIn(0, math.min(cap, 400));
    return r.intIn(0, math.min(cap, maxN));
  }

  @override
  Iterable<int> shrink(int v) => G.intIn(0, maxN).shrink(v);
}

class _CutSeedGen extends Gen<int> {
  @override
  int generate(Rng r, int size) => r.nextInt(1 << 20);
  @override
  Iterable<int> shrink(int v) => G.intIn(0, 1 << 20).shrink(v);
}

Gen<_Case> _caseGen(int maxN) => G.pair(
      G.quad(_FlavourGen(), _NGen(maxN), G.intIn(0, 1 << 16), G.elements(const [0, 0, 0, 1])),
      G.quad(G.intIn(0, 6), _CutSeedGen(), G.intIn(0, 127),
          G.elements(const [0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8])),
    );

const _windowEdges = [0, 1, 2, 3, 44, 45, 46, 90, 91, 92, 93, 136, 137, 182, 183];

/// Chunk boundaries, half of the cuts on the edges of the corrector's windows
/// (the beats where classes and output settle).
List<int> _bounds(int n, int splits, int cutSeed) =>
    foldBounds(n, splits, cutSeed, special: _windowEdges);

// ── folding ─────────────────────────────────────────────────────────────────

String _text(RrCorrector c) => jsonEncode(c.toJson());

RrCorrector _restore(RrCorrector c) => RrCorrector.fromJson(
    (jsonDecode(jsonEncode(c.toJson())) as Map).cast<String, dynamic>());

List<double>? _tsSlice(_Series s, bool wall, int a, int b) =>
    wall ? s.ts.sublist(a, b) : null;

/// What a driven corrector handed out.
class _Run {
  RrCorrector c;
  final nn = <double>[], times = <double>[];
  final classes = <BeatClass>[];
  _Run(this.c);
}

void _foldInto(_Run run, _Series s, bool wall, int a, int b) {
  final out = run.c.fold(s.rr.sublist(a, b), tsMs: _tsSlice(s, wall, a, b));
  run.nn.addAll(out.nn);
  run.times.addAll(out.nnTimes);
  run.classes.addAll(out.classes);
}

/// Folds [s] in the chunks [bounds]; after chunk k the corrector is restored
/// through JSON text when bit k of [restart] is set. [seam] sees every seam
/// after the chunk (and the restore) with the end of the chunk.
_Run _drive(_Series s, bool wall, int cfg, List<int> bounds, int restart,
    {void Function(_Run run, int k, int at)? seam}) {
  final run = _Run(_newCorrector(cfg));
  for (var k = 0; k + 1 < bounds.length; k++) {
    _foldInto(run, s, wall, bounds[k], bounds[k + 1]);
    if ((restart >> (k % 7)) & 1 == 1) run.c = _restore(run.c);
    seam?.call(run, k, bounds[k + 1]);
  }
  return run;
}

void _sameSnapshot(RrSnapshot a, RrSnapshot b, String why) {
  expect(a.n, b.n, reason: 'n $why');
  expectBitIdentical(a.tailNn, b.tailNn, '$why tailNn');
  expectBitIdentical(a.tailNnTimes, b.tailNnTimes, '$why tailNnTimes');
  expectSameClasses(a.tailClasses, b.tailClasses, '$why tailClasses');
  expect(a.normalCount, b.normalCount, reason: 'normal $why');
  expect(a.droppedCount, b.droppedCount, reason: 'dropped $why');
  expect(a.correctedCount, b.correctedCount, reason: 'corrected $why');
  expect(a.settledBeats, b.settledBeats, reason: 'settled $why');
  expect(a.classifiedBeats, b.classifiedBeats, reason: 'classified $why');
  expect(sameBits(a.cleanFraction, b.cleanFraction), isTrue,
      reason: 'cleanFraction $why');
}

/// Case-level facts from the recipe alone (no fold), for the reach observers.
void _observeRr(_Case c, void Function(String) bump) {
  final (flavour, n, _, mode) = c.$1;
  final (splits, cutSeed, restart, cfg) = c.$2;
  bump('flavour: ${_flavours[flavour]}');
  if (n == 0) bump('beats: none');
  if (n > 0 && n < 3) bump('beats: under 3 (the short branch)');
  if (n >= 3 && n < 91) bump('beats: inside the window (3 to 90)');
  if (n >= 91) bump('beats: past the window (91 or more)');
  if (n >= 1000) bump('beats: 1000 or more');
  if (mode == 1) bump('no timestamps');
  if (cfg != 0) bump('non-default config');
  final b = _bounds(n, splits, cutSeed);
  if (b.length >= 4) bump('chunks: three or more');
  if (b.length >= 6) bump('chunks: five or more');
  if (hasEmptyChunk(b)) bump('an empty chunk');
  if (restart != 0 && b.length > 2) bump('a restore between chunks');
  if (b.any((x) => x == 91 || x == 92 || x == 45 || x == 46)) {
    bump('a cut on a window edge (45 / 46 / 91 / 92)');
  }
}

const Map<String, double> _rrShares = {
  'flavour: clean': .03,
  'flavour: mixed': .03,
  'flavour: flagged': .03,
  'flavour: gappy': .03,
  'flavour: backwards': .03,
  'flavour: artefact heavy': .03,
  'flavour: flat': .03,
  'flavour: outliers': .03,
  'flavour: edge gaps': .02,
  'flavour: hard limits': .02,
  'beats: none': .01,
  'beats: under 3 (the short branch)': .015,
  'beats: inside the window (3 to 90)': .1,
  'beats: past the window (91 or more)': .4,
  'no timestamps': .08,
  'non-default config': .2,
  'chunks: three or more': .4,
  'chunks: five or more': .15,
  'an empty chunk': .05,
  'a restore between chunks': .3,
  'a cut on a window edge (45 / 46 / 91 / 92)': .1,
};

// ── forced scenarios ────────────────────────────────────────────────────────

_Case _c(int flavour, int n,
        {int seed = 5,
        int mode = 0,
        int splits = 3,
        int cutSeed = 1,
        int restart = 0,
        int cfg = 0}) =>
    ((flavour, n, seed, mode), (splits, cutSeed, restart, cfg));

/// Thin, flat, artefact runs, boundaries (the window edges, exactly 3 beats and
/// exactly one window), timestamp-free, every config. Every law that takes a
/// recipe meets these first.
final List<_Case> _forced = [
  _c(0, 0), // no beats at all
  _c(0, 1), // one beat
  _c(0, 2, restart: 127), // two: the < 3 branch
  _c(0, 3, restart: 127), // exactly three
  _c(9, 1), // exactly 300 ms: plausible
  _c(9, 2, restart: 127), // 300 and 2000 exactly
  _c(9, 3, restart: 127), // and a too-long beat: the first main-path verdict
  _c(9, 4, restart: 127), // and a too-short one
  _c(9, 120, splits: 4, cutSeed: 28, restart: 127),
  _c(1, 5, splits: 6, restart: 127),
  _c(0, 44, splits: 4, cutSeed: 3), // under the half window
  _c(0, 46, splits: 5, cutSeed: 4), // the first beat whose window is complete
  _c(0, 90, splits: 3, cutSeed: 5), // one short of the first settled class
  _c(0, 91, splits: 3, cutSeed: 6), // exactly the first settled class
  _c(0, 92, splits: 3, cutSeed: 7),
  _c(6, 200, splits: 4, cutSeed: 8, restart: 127), // flat: QD = 0
  _c(7, 150, splits: 4, cutSeed: 9), // outlier at start / middle / end
  _c(7, 3), // the outlier is the first and the last beat
  _c(5, 400, splits: 6, cutSeed: 10, restart: 85), // artefacts + a 120 run
  _c(4, 300, splits: 5, cutSeed: 11, restart: 127), // a beat time steps back
  _c(3, 300, splits: 5, cutSeed: 12), // dropouts
  _c(1, 350, splits: 6, cutSeed: 13, mode: 1), // no timestamps
  _c(2, 400, splits: 6, cutSeed: 14, restart: 127), // irregularly irregular
  _c(1, 300, splits: 6, cutSeed: 15, cfg: 1),
  _c(1, 300, splits: 6, cutSeed: 16, cfg: 2, restart: 127),
  _c(1, 300, splits: 6, cutSeed: 17, cfg: 3, mode: 1),
  _c(1, 300, splits: 6, cutSeed: 18, cfg: 4, restart: 127), // window of 4 beats
  _c(5, 300, splits: 6, cutSeed: 19, cfg: 5), // an even window of 90
  _c(8, 300, splits: 5, cutSeed: 22, restart: 127), // dropouts exactly at the gap
  _c(8, 300, splits: 5, cutSeed: 23, cfg: 3, restart: 85), // gap 400
  _c(8, 300, splits: 5, cutSeed: 24, cfg: 5, restart: 127), // gap 5000
  _c(1, 200, splits: 6, cutSeed: 25, cfg: 6, restart: 127), // a window of one beat
  _c(5, 200, splits: 6, cutSeed: 26, cfg: 7), // two beats
  _c(1, 200, splits: 6, cutSeed: 27, cfg: 8, restart: 127), // three beats
  _c(1, 1200, splits: 6, cutSeed: 20, restart: 127), // past 1000 beats
  _c(1, 3000, splits: 6, cutSeed: 21, restart: 127), // the cap
];

/// A day with settled beats, artefacts and several windows: the base the
/// mutated-checkpoint law cuts its mutations from.
final _Case _l3Base = _forced.firstWhere(
    (c) => c.$1.$1 == 1 && c.$1.$2 >= 300 && c.$1.$4 == 0 && c.$2.$4 == 0);

// ── RC: the corrector ───────────────────────────────────────────────────────

String _tag(_Case c) {
  final ((f, n, seed, mode), (splits, cutSeed, restart, cfg)) = c;
  return '${_flavours[f]} n=$n seed=$seed ts=${mode == 0} splits=$splits '
      'cut=$cutSeed restart=$restart cfg=$cfg';
}

void _l1Corrector(_Case c) {
  final (rec, plan) = c;
  final (flavour, n, seed, mode) = rec;
  final (splits, cutSeed, restart, cfg) = plan;
  final s = _series(flavour, n, seed);
  final wall = mode == 0;
  final tag = _tag(c);
  final whole = _drive(s, wall, cfg, [0, n], 0);
  final bounds = _bounds(n, splits, cutSeed);
  final got = _drive(s, wall, cfg, bounds, restart);
  expect(_text(got.c), _text(whole.c),
      reason: '$tag bounds=$bounds: the checkpoint text is the same');
  expectBitIdentical(got.nn, whole.nn, '$tag settled nn');
  expectBitIdentical(got.times, whole.times, '$tag settled times');
  expectSameClasses(got.classes, whole.classes, '$tag settled classes');
  _sameSnapshot(got.c.snapshot(), whole.c.snapshot(), tag);
}


/// Largest series the frozen reference is run on in a property (it is the
/// expensive side: about 0.14 ms a beat). Beyond it the production batch is
/// the oracle: weaker (it shares the kernel with the stream), but pinned to the
/// reference by rr_correction_oracle_test.dart.
const int _refCap = 300;

RrCorrectionResult _oracle(_Series s, bool wall, int cfg, int at) {
  final p = _corrCfgs[cfg];
  final rr = s.rr.sublist(0, at), ts = wall ? s.ts.sublist(0, at) : null;
  return at <= _refCap
      ? correctRrReference(rr,
          rrTsMs: ts,
          alpha: p.$1,
          windowBeats: p.$2,
          minThresholdMs: p.$3,
          reanchorGapMs: p.$4)
      : correctRr(rr,
          rrTsMs: ts,
          alpha: p.$1,
          windowBeats: p.$2,
          minThresholdMs: p.$3,
          reanchorGapMs: p.$4);
}

void _expectOracleAt(_Run run, _Series s, bool wall, int cfg, int at, String why) {
  final want = _oracle(s, wall, cfg, at);
  if (at <= _refCap) {
    // The production batch is the oracle beyond the reference's budget; hold it
    // to the reference wherever both run, so that swap stays justified.
    final p = _corrCfgs[cfg];
    expectSameCorrection(
        correctRr(s.rr.sublist(0, at),
            rrTsMs: wall ? s.ts.sublist(0, at) : null,
            alpha: p.$1,
            windowBeats: p.$2,
            minThresholdMs: p.$3,
            reanchorGapMs: p.$4),
        want,
        '$why: production batch vs frozen reference');
  }
  final snap = run.c.snapshot();
  expect(snap.n, at, reason: 'snapshot.n $why');
  expect(snap.classifiedBeats, run.classes.length,
      reason: 'classifiedBeats == classes handed out $why');
  expect(snap.settledBeats, run.c.settledBeats, reason: 'settledBeats $why');
  expect(snap.settledBeats, lessThanOrEqualTo(snap.classifiedBeats),
      reason: 'output cannot settle before its class $why');
  expectBitIdentical([...run.nn, ...snap.tailNn], want.nn, '$why nn');
  expectBitIdentical(
      [...run.times, ...snap.tailNnTimes], want.nnTimesMs, '$why times');
  expectSameClasses([...run.classes, ...snap.tailClasses], want.classes, why);
  expect(snap.normalCount,
      want.classes.where((k) => k == BeatClass.normal).length,
      reason: 'normalCount $why');
  expect(snap.droppedCount, want.droppedCount, reason: 'dropped $why');
  expect(snap.correctedCount, want.correctedCount, reason: 'corrected $why');
  expect(sameBits(snap.cleanFraction, want.cleanFraction), isTrue,
      reason: 'cleanFraction ${snap.cleanFraction} vs ${want.cleanFraction} $why');
}

void _l1bCorrector(_Case c) {
  final (rec, plan) = c;
  final (flavour, n, seed, mode) = rec;
  final (splits, cutSeed, restart, cfg) = plan;
  final s = _series(flavour, n, seed);
  final wall = mode == 0;
  final tag = _tag(c);
  final bounds = _bounds(n, splits, cutSeed);
  final picks = pickSeams(bounds.length - 1);
  _drive(s, wall, cfg, bounds, restart, seam: (run, k, at) {
    if (picks.contains(k)) {
      _expectOracleAt(run, s, wall, cfg, at, '$tag seam $k at $at');
    }
  });
}

/// What a reader can see of a corrector, as text: its parameters, its settled
/// edge and its snapshot (every field).
String _projectCorrector(RrCorrector c) {
  final s = c.snapshot();
  return jsonEncode([
    c.alpha,
    c.windowBeats,
    c.minThresholdMs,
    c.reanchorGapMs,
    c.settledBeats,
    s.n,
    s.tailNn,
    s.tailNnTimes,
    [for (final k in s.tailClasses) k.index],
    s.normalCount,
    s.droppedCount,
    s.correctedCount,
    s.settledBeats,
    s.classifiedBeats,
    s.cleanFraction,
  ]);
}

void _l2Corrector(_Case c) {
  final (rec, plan) = c;
  final (flavour, n, seed, mode) = rec;
  final (splits, cutSeed, _, cfg) = plan;
  final s = _series(flavour, n, seed);
  final wall = mode == 0;
  final tag = _tag(c);
  final bounds = _bounds(n, splits, cutSeed);
  // Fold the first part, copy the state through JSON text, fold the rest into
  // both: the copy reads the same and goes on identically.
  final at = bounds.length > 2 ? bounds[1] : n ~/ 2;
  final live = _Run(_newCorrector(cfg));
  _foldInto(live, s, wall, 0, at);
  final text = _text(live.c);
  final map = (jsonDecode(text) as Map).cast<String, dynamic>();
  final back = _Run(RrCorrector.fromJson(map));
  expect(_text(back.c), text, reason: '$tag: write(read(b)) == b');
  expect(_projectCorrector(back.c), _projectCorrector(live.c),
      reason: '$tag: the restored one reads what the live one reads');
  // The restored object owns its state: the map it was read from is not shared.
  for (final k in ['rr', 't', 'd', 'fcls', 'lastNormals']) {
    (map[k] as List).clear();
  }
  expect(_text(back.c), text, reason: '$tag: not aliased to the map');
  final ownSettled = live.nn.length;
  _foldInto(live, s, wall, at, n);
  _foldInto(back, s, wall, at, n);
  expectBitIdentical(back.nn, live.nn.sublist(ownSettled), '$tag nn after restore');
  expectBitIdentical(back.times, live.times.sublist(ownSettled), '$tag times after restore');
  expectSameClasses(back.classes, live.classes.sublist(live.classes.length - back.classes.length), tag);
  expect(_text(back.c), _text(live.c), reason: '$tag: same checkpoint after the rest');
  expect(_projectCorrector(back.c), _projectCorrector(live.c), reason: tag);
}

// ── L3: mutated checkpoints ─────────────────────────────────────────────────

/// Applies mutation [m] to a copy of [src] (a decoded checkpoint). Returns the
/// mutated map and what it may do. The "must refuse" cases are the ones that
/// make the checkpoint contradict itself or its type; they are chosen from what
/// a reachable state can never look like, not from the reader's code.
(Map<String, dynamic>, Must) _mutateCorrector(Map<String, dynamic> src, Mut m) {
  final j = (deepCopy(src) as Map).cast<String, dynamic>();
  final (kind, a, b) = m;
  final keys = j.keys.toList();
  List l(String k) => j[k] as List;
  switch (kind % 11) {
    case 0:
      const versions = <Object?>[0, 1, 3, -1, 99, '2', null, true, 1 << 40, 'v2'];
      j['version'] = versions[a % versions.length];
      return (j, Must.refuse);
    case 1:
      const types = <Object?>['IrregularScreenState', 'Other', null, '', 'rrcorrector', 1];
      j['type'] = types[a % types.length];
      return (j, Must.refuse);
    case 2:
      // A key that every real checkpoint has, gone ('wall' may legally be null).
      final k = keys.where((k) => k != 'wall').toList()[a % (keys.length - 1)];
      j.remove(k);
      return (j, Must.refuse);
    case 3:
      // The wrong kind of value under a key.
      final k = keys.where((k) => k != 'wall').toList()[a % (keys.length - 1)];
      const junk = <Object?>['x', <String, Object?>{}, <Object?>[<Object?>[]]];
      j[k] = junk[b % junk.length];
      return (j, Must.refuse);
    case 4:
      // The buffered arrays disagree with each other or with n - off.
      final k = const ['rr', 't', 'd'][a % 3];
      final arr = l(k);
      switch (b % 3) {
        case 0:
          if (arr.isEmpty) {
            arr.add(1.0);
          } else {
            arr.removeLast();
          }
        case 1:
          arr.add(arr.isEmpty ? 1.0 : arr.last);
        default:
          arr.clear();
          if (j['n'] == j['off']) arr.add(1.0);
      }
      return (j, Must.refuse);
    case 5:
      // The counters contradict their own order  off <= ce <= c2 <= c1 <= n.
      switch (a % 6) {
        case 0:
          j['ce'] = (j['c2'] as int) + 1;
        case 1:
          j['c2'] = (j['c1'] as int) + 1;
        case 2:
          j['c1'] = (j['n'] as int) + 1;
        case 3:
          j['off'] = -1;
        case 4:
          j['n'] = (j['n'] as int) + 1 + b % 3;
        default:
          j['n'] = (j['n'] as int) - 1 - b % 3;
      }
      return (j, Must.refuse);
    case 6:
      // The class buffer: wrong length, or a class that is not one.
      final f = l('fcls');
      switch (a % 3) {
        case 0:
          f.add(0);
        case 1:
          if (f.isEmpty) {
            f.add(5);
          } else {
            f[b % f.length] = const [5, -1, 99, 1 << 40][b % 4];
          }
        default:
          if (f.isEmpty) {
            f.add(0);
          } else {
            f.removeLast();
          }
      }
      return (j, Must.refuse);
    case 7:
      // The carried state: more than two normals, a class that is not one.
      if (a.isEven) {
        l('lastNormals')
          ..add(800.0)
          ..add(801.0)
          ..add(802.0);
      } else {
        j['lastFinal'] = const [5, -1, 99, 1 << 40][b % 4];
      }
      return (j, Must.refuse);
    case 8:
      // Hostile sizes: the checkpoint says it holds far more than it does.
      const huge = <int>[1 << 40, 1 << 62, 0x7fffffffffffffff, -1];
      j[const ['n', 'off', 'c1', 'c2', 'ce'][a % 5]] = huge[b % huge.length];
      return (j, Must.refuse);
    case 9:
      // One number changed: the reader cannot tell it from a legal checkpoint.
      switch (a % 9) {
        case 0:
          if (l('rr').isNotEmpty) l('rr')[b % l('rr').length] = (l('rr')[b % l('rr').length] as num) + 1.0;
        case 1:
          if (l('t').isNotEmpty) l('t')[b % l('t').length] = (l('t')[b % l('t').length] as num) + 1.0;
        case 2:
          if (l('d').isNotEmpty) l('d')[b % l('d').length] = (l('d')[b % l('d').length] as num) + 1.0;
        case 3:
          j['alpha'] = (j['alpha'] as num) + 1.0;
        case 4:
          j['minThresholdMs'] = (j['minThresholdMs'] as num) + 1.0;
        case 5:
          j['reanchorGapMs'] = (j['reanchorGapMs'] as num) + 1.0;
        case 6:
          j['dropped'] = (j['dropped'] as int) + 1;
        case 7:
          j['normalFinal'] = (j['normalFinal'] as int) + 1;
        default:
          j['wall'] = !(j['wall'] as bool? ?? false);
      }
      return (j, Must.faithful);
    default:
      // A key this version does not know.
      j['futureField${a % 3}'] = const [1, 'x', <Object?>[1]][b % 3];
      return (j, Must.ignored);
  }
}

String _checkpointOutcome(Map<String, dynamic> j) {
  try {
    final c = RrCorrector.fromJson((deepCopy(j) as Map).cast<String, dynamic>());
    return 'accepted:${jsonEncode(c.toJson())}';
  } on FormatException {
    return 'refused';
  } catch (e) {
    return 'WRONG ERROR TYPE: ${e.runtimeType}: $e';
  }
}

final Gen<Mut> _mutGen = mutGen(11);

void _l3Corrector((_Case, Mut) arg) {
  final (c, m) = arg;
  final (rec, plan) = c;
  final (flavour, n, seed, mode) = rec;
  final cfg = plan.$4;
  final s = _series(flavour, n, seed);
  final tag = '${_tag(c)} mutation=${m.$1 % 11}(${m.$2},${m.$3})';
  final run = _drive(s, mode == 0, cfg, [0, n], 0);
  final src = (jsonDecode(_text(run.c)) as Map).cast<String, dynamic>();
  final (bad, must) = _mutateCorrector(src, m);
  expectMutationOutcome(_checkpointOutcome(bad), must, jsonEncode(bad),
      jsonEncode(src), tag);
}

// ── L4 / refusals ───────────────────────────────────────────────────────────

void _l4Corrector(_Case c) {
  final (rec, plan) = c;
  final (flavour, n, seed, mode) = rec;
  final (_, _, _, cfg) = plan;
  final s = _series(flavour, n, seed);
  final wall = mode == 0;
  final tag = _tag(c);
  // Identity: an empty chunk, with or without timestamps, at the start (before
  // anything records the mode), in the middle and at the end.
  final fresh = _text(_newCorrector(cfg));
  for (final withTs in [true, false]) {
    final f = _newCorrector(cfg);
    final out = f.fold(const [], tsMs: withTs ? const [] : null);
    expect(out.nn, isEmpty, reason: tag);
    expect(out.nnTimes, isEmpty, reason: tag);
    expect(out.classes, isEmpty, reason: tag);
    expect(_text(f), fresh,
        reason: '$tag: an empty first fold records nothing (not even the mode)');
  }
  final cut = n ~/ 2;
  final run = _Run(_newCorrector(cfg));
  // An empty fold before the first beat must not decide whether timestamps are
  // used: the series still folds in either mode and reads as if it never ran.
  run.c.fold(const [], tsMs: wall ? null : const []);
  _foldInto(run, s, wall, 0, cut);
  final before = _text(run.c);
  for (final withTs in [true, false]) {
    final out = run.c.fold(const [], tsMs: withTs ? const [] : null);
    expect(out.nn.length + out.nnTimes.length + out.classes.length, 0, reason: tag);
    expect(_text(run.c), before, reason: '$tag: an empty chunk is the identity');
  }
  // snapshot() reads and changes nothing.
  final one = _projectCorrector(run.c);
  expect(_text(run.c), before, reason: '$tag: snapshot() is read-only');
  expect(_projectCorrector(run.c), one, reason: '$tag: twice is equal');
  // Refusals leave the state exactly as it was.
  if (cut > 0) {
    final good = s.rr.sublist(cut, math.min(n, cut + 3));
    final goodTs = s.ts.sublist(cut, math.min(n, cut + 3));
    if (good.isNotEmpty) {
      // The other mode.
      expect(() => run.c.fold(good, tsMs: wall ? null : goodTs), throwsStateError,
          reason: '$tag: timestamps on every fold or on none');
      expect(_text(run.c), before, reason: '$tag: unchanged by the mixed fold');
      // A length mismatch (timestamps on).
      if (wall) {
        expect(() => run.c.fold(good, tsMs: goodTs.sublist(0, goodTs.length - 1)),
            throwsArgumentError, reason: tag);
        expect(_text(run.c), before, reason: '$tag: unchanged by the mismatch');
      }
      // A non-finite value AFTER good beats in the same chunk must not stick.
      for (final bad in [double.nan, double.infinity, double.negativeInfinity]) {
        final rr = [...good, bad], ts = [...goodTs, goodTs.last + 1000];
        expect(() => run.c.fold(rr, tsMs: wall ? ts : null), throwsArgumentError,
            reason: '$tag: non-finite RR $bad');
        expect(_text(run.c), before, reason: '$tag: unchanged by $bad');
        if (wall) {
          final badTs = [...goodTs, bad];
          expect(() => run.c.fold([...good, 800], tsMs: badTs), throwsArgumentError,
              reason: '$tag: non-finite timestamp $bad');
          expect(_text(run.c), before, reason: '$tag: unchanged by timestamp $bad');
        }
      }
    }
  }
}

// ── L5: conservation ────────────────────────────────────────────────────────

void _checkConserved(RrSnapshot snap, _Run run, int cfg, String why) {
  final n = snap.n;
  // The class of a beat is final once the window two thresholds deep (2h beats
  // each side) is in the data (header of rr_correction_stream.dart); under 3
  // beats nothing is.
  final h = _corrCfgs[cfg].$2 ~/ 2;
  expect(snap.classifiedBeats, n < 3 ? 0 : math.max(0, n - 2 * h),
      reason: 'classes settle exactly 2h beats behind the newest $why');
  final nnTotal = run.nn.length + snap.tailNn.length;
  expect(nnTotal, n - snap.droppedCount,
      reason: 'nn_in == rr_raw - dropped $why');
  expect(snap.normalCount + snap.correctedCount + snap.droppedCount, n,
      reason: 'every beat is kept, corrected or dropped, once $why');
  expect(snap.droppedCount >= 0 && snap.correctedCount >= 0, isTrue, reason: why);
  expect(run.classes.length + snap.tailClasses.length, n,
      reason: 'a class for every beat $why');
  final normals = [...run.classes, ...snap.tailClasses]
      .where((k) => k == BeatClass.normal)
      .length;
  expect(snap.normalCount, normals, reason: 'normal count is the class count $why');
  expect(snap.settledBeats <= snap.classifiedBeats && snap.classifiedBeats <= n,
      isTrue,
      reason: 'settled <= classified <= folded $why');
  expect(snap.cleanFraction, n == 0 ? 0.0 : snap.normalCount / n,
      reason: 'cleanFraction is a share of the beats, 0 on none, never NaN $why');
  expect(snap.cleanFraction >= 0 && snap.cleanFraction <= 1, isTrue, reason: why);
  expect(run.nn.length, run.times.length, reason: why);
  expect(snap.tailNn.length, snap.tailNnTimes.length, reason: why);
  final all = [...run.times, ...snap.tailNnTimes];
  for (var i = 1; i < all.length; i++) {
    if (all[i] < all[i - 1]) {
      fail('beat times never run backwards, whatever the stamps do: '
          '${all[i - 1]} then ${all[i]} at $i $why');
    }
  }
}

void _l5Corrector(_Case c) {
  final (rec, plan) = c;
  final (flavour, n, seed, mode) = rec;
  final (splits, cutSeed, restart, cfg) = plan;
  final s = _series(flavour, n, seed);
  final tag = _tag(c);
  final bounds = _bounds(n, splits, cutSeed);
  _drive(s, mode == 0, cfg, bounds, restart, seam: (run, k, at) {
    _checkConserved(run.c.snapshot(), run, cfg, '$tag seam $k at $at');
  });
}

// ── SC: the screen state, folding a corrected NN series directly ────────────

const _nnFlavours = [
  'sinus', // regular, slow drift
  'af', // irregularly irregular throughout
  'blocks', // blocks of AF and sinus, 5 to 30 minutes
  'flat', // constant
  'two point', // alternating 800 / 1000
  'sinus + gaps', // sinus with dropouts (time jumps)
  'af heavy', // AF in most blocks
  'range edges', // 300 and 2000 exactly (kept), 299 and 2001 (not), then calm beats
];
const int _nNnFlavours = 8;

/// (out-of-range share, NaN share) of the entries.
const List<(double, double)> _salts = [(0, 0), (.02, 0), (.2, .02), (0, .02)];

class _Nn {
  _Nn(this.nn, this.t);
  final List<double> nn, t;
  int get n => nn.length;
}

final Map<(int, int, int, int), _Nn> _nnCache = {};

_Nn _nnSeries(int flavour, int n, int seed, int salt) =>
    _nnCache.putIfAbsent((flavour, n, seed, salt), () {
      if (_nnCache.length > 400) _nnCache.clear();
      return _expandNn(flavour, n, seed, salt);
    });

_Nn _expandNn(int flavour, int n, int seed, int salt) {
  final r = Rng(seed * 104729 + flavour * 31 + salt + 3);
  final (outShare, nanShare) = _salts[salt];
  final nn = <double>[], t = <double>[];
  var clock = 0.0;
  var af = false;
  var left = 0;
  for (var i = 0; i < n; i++) {
    if (--left <= 0) {
      af = switch (flavour) {
        1 => true,
        2 => r.nextBool(.4),
        6 => r.nextBool(.8),
        _ => false,
      };
      left = 300 + r.nextInt(2000);
    }
    var v = switch (flavour) {
      3 => 800.0,
      4 => i.isEven ? 800.0 : 1000.0,
      7 => const [300.0, 2000.0, 299.0, 2001.0, 800.0, 1000.0, 850.0][i % 7],
      _ => af
          ? (420 + r.nextInt(700)).toDouble()
          : (850 + 40 * math.sin(i / 90) + 25 * (r.nextDouble() - .5)).roundToDouble(),
    };
    var step = v;
    final u = r.nextDouble();
    if (u < nanShare) {
      v = double.nan;
      step = 800;
    } else if (u < nanShare + outShare) {
      v = r.nextBool() ? 2500 : 250;
      step = v;
    }
    if (flavour == 5 && i % 211 == 210) clock += 40000 + r.nextInt(300000);
    clock += step;
    nn.add(v);
    t.add(clock);
  }
  return _Nn(nn, t);
}

/// (flavour, beats, seed, salt).
typedef _NnRec = (int, int, int, int);

/// Screen parameters: (sd1sd2Flag, pnnThresholdMs, pnnFlagPct, windowMinutes,
/// minWindowBeats, sustainedFraction). The last five are invalid window
/// configs: the batch fails CLOSED on them and the state keeps no windows.
const List<(double, double, double, double, int, double)> _scCfgs = [
  (.70, 70, 30, 5, 40, .5),
  (.70, 70, 30, 1, 10, .5),
  (.50, 50, 20, 2, 2, 0.0),
  (.70, 70, 30, 5, 40, 1.0),
  (.70, 70, 30, 0, 40, .5), // invalid: no window length
  (.70, 70, 30, 5, 1, .5), // invalid: windows of fewer than 2 beats
  (.70, 70, 30, 5, 40, 1.5), // invalid: a fraction above 1
  (.70, 70, 30, -5, 40, -.1), // invalid: two at once
  (.90, 100, 60, 10, 100, .25),
];
bool _scCfgValid(int i) {
  final c = _scCfgs[i];
  return c.$4 > 0 && c.$5 >= 2 && c.$6 >= 0 && c.$6 <= 1;
}

IrregularScreenState _newState(int cfg) {
  final c = _scCfgs[cfg];
  return IrregularScreenState(
      sd1sd2Flag: c.$1,
      pnnThresholdMs: c.$2,
      pnnFlagPct: c.$3,
      windowMinutes: c.$4,
      minWindowBeats: c.$5,
      sustainedFraction: c.$6);
}

/// What `evaluateDetailed` is asked: (minBeats, maxArtifact, artifactFraction,
/// cleaning: 0 none, 1 raw=beats+3, 2 raw=0).
const List<(int, double, double, int)> _evals = [
  (500, .30, 0.0, 1),
  (10, .30, 0.0, 1),
  (40, .30, .07, 0),
  (100, .05, .31, 1),
  (2, 1.0, 1.0, 1),
  (20, .30, .29, 0),
  (1, .30, 0.0, 2),
  (30, .30, .30, 1), // the artifact gate is strict: exactly the maximum passes
];

RrCleaningCounts? _cleaningFor(int kind, int beats) => switch (kind) {
      0 => null,
      1 => RrCleaningCounts(raw: beats + 3, corrected: 2, dropped: 3),
      _ => const RrCleaningCounts(raw: 0, corrected: 0, dropped: 0),
    };

IrregularScreenResult _evaluate(IrregularScreenState st, int ev,
    {List<double> tailNn = const [], List<double> tailT = const [], int beats = 0}) {
  final e = _evals[ev];
  return st.evaluateDetailed(tailNn, tailT,
      artifactFraction: e.$3,
      minBeats: e.$1,
      maxArtifact: e.$2,
      cleaning: _cleaningFor(e.$4, beats));
}

IrregularScreenResult _batchScreenOf(List<double> nn, List<double> t, int cfg, int ev) {
  final c = _scCfgs[cfg];
  final e = _evals[ev];
  return irregularBeatScreenDetailed(nn,
      nnTimesMs: t,
      artifactFraction: e.$3,
      minBeats: e.$1,
      maxArtifact: e.$2,
      sd1sd2Flag: c.$1,
      pnnThresholdMs: c.$2,
      pnnFlagPct: c.$3,
      windowMinutes: c.$4,
      minWindowBeats: c.$5,
      sustainedFraction: c.$6,
      cleaning: _cleaningFor(e.$4, nn.length));
}

String _stext(IrregularScreenState s) => jsonEncode(s.toJson());

IrregularScreenState _srestore(IrregularScreenState s) =>
    IrregularScreenState.fromJson(
        (jsonDecode(jsonEncode(s.toJson())) as Map).cast<String, dynamic>());

void _close(double got, double want, String why, {double rel = 1e-9}) {
  final tol = rel * math.max(1.0, want.abs());
  if (!((got - want).abs() <= tol)) {
    fail('$why: got $got want $want (tolerance $tol)');
  }
}

/// Whether input beat [i] and the one before it form a successive pair, from
/// the documented rule alone: both kept (300..2000 ms), neighbours in the input
/// and, when beat times are given, no time hole between them (the elapsed time
/// is at most the interval, +0.5 ms of rounding; a NaN time is never within).
bool _successive(List<double> nn, List<double>? t, int i) {
  bool kept(double v) => v >= 300 && v <= 2000;
  return i > 0 &&
      kept(nn[i]) &&
      kept(nn[i - 1]) &&
      (t == null || t[i] - t[i - 1] <= nn[i] + 0.5);
}

/// The kept beats of [nn] (300..2000 ms) and the successive differences taken
/// only between two successive beats (see [_successive]), from the documented
/// rule alone.
({List<double> kept, List<double> diffs}) _keptAndDiffs(
    List<double> nn, List<double>? t) {
  bool kept(double v) => v >= 300 && v <= 2000;
  return (
    kept: [for (final v in nn) if (kept(v)) v],
    diffs: [
      for (var i = 1; i < nn.length; i++)
        if (_successive(nn, t, i)) nn[i] - nn[i - 1]
    ],
  );
}

/// The successive pairs the screen gates on (its minimum is minBeats - 1).
int _pairsOf(List<double> nn, List<double>? t) => _keptAndDiffs(nn, t).diffs.length;

/// Whether SD2 is numerically zero for [nn]: 2*SDNN^2 - SD1^2 is within 1e-9 of
/// its own scale of nothing (an exactly two-valued alternating series is the
/// plain case). There the sign of float noise decides "no long-term
/// variability" versus a tiny SD2 and a ratio of 1e8, and running sums and a
/// two-pass batch legitimately disagree. Computed independently, from the
/// documented rule.
bool _sd2Degenerate(List<double> nn, List<double>? t) {
  final k = _keptAndDiffs(nn, t);
  final sdnn = _sd(k.kept), sdsd = _sd(k.diffs);
  if (sdnn == null || sdsd == null || sdnn == 0) return false;
  final v = 2 * sdnn * sdnn - sdsd * sdsd / 2;
  return v.abs() <= 1e-9 * 2 * sdnn * sdnn;
}

/// A reported SD2 is "numerically zero" when sd2^2 is within the same 1e-9 of
/// the scale 2*SDNN^2 (= sd1^2 + sd2^2) that [_sd2Degenerate] uses. The bound
/// is the float noise of the cancellation 2*SDNN^2 - SD1^2: two sums of squares
/// of the same magnitude differ by a few ulps (about 1e-15 relative, times a
/// factor that grows with the beat count, well under 1e-12 at the 3,000 beats
/// the generators cap at), so 1e-9 leaves a margin of more than 1e3 and
/// still rejects any SD2 that is a real fraction of SD1.
void _expectNumericallyZeroSd2(IrregularRhythm r, String why) {
  expect(r.sd2.isFinite && r.sd2 >= 0, isTrue, reason: 'sd2 finite, >= 0 $why');
  expect(r.sd2 * r.sd2 <= 1e-9 * (r.sd1 * r.sd1 + r.sd2 * r.sd2), isTrue,
      reason: 'a reported SD2 where the other side abstains is numerically '
          'zero (sd1 ${r.sd1}, sd2 ${r.sd2}) $why');
}

/// Counts, flags, abstentions, notes and the diagnostics text exact; SD1 / SD2 /
/// ratio within 1e-9 relative, confidence within 1e-12 (running sums against a
/// two-pass batch).
///
/// Pass [nn] (the beats the screen saw) to allow the one ambiguity of a
/// numerically zero SD2 (see [_sd2Degenerate]): the two sides may disagree on
/// whether SD2 is zero. That exempts ONLY the SD2 presence and what hangs on
/// it: SD2 and the ratio (both sides, when both report: each only has to be
/// numerically zero), and, when exactly one side reports, the note and the
/// flag, because the abstaining side has nothing to compare them with.
/// Everything else is still held: tier, inputs, every diagnostics field but the
/// abstention reason, SD1 (against an independent value when only one side
/// reports), the beat count, pNN and confidence (each against an independent
/// value when only one side reports, so [pnnThresholdMs] and the screen's
/// [artifactFraction] are passed along with [nn]). When
/// exactly one side reports, the other must abstain with
/// `noLongTermVariability` and the reported SD2 must be numerically zero.
void _sameScreen(IrregularScreenResult got, IrregularScreenResult want, String why,
    {List<double>? nn,
    List<double>? t,
    double? pnnThresholdMs,
    double? artifactFraction}) {
  assert(nn == null || (pnnThresholdMs != null && artifactFraction != null),
      'the independent values need the pNN threshold and the artifact fraction');
  final g = got.metric, w = want.metric;
  final degenerate = nn != null && _sd2Degenerate(nn, t);
  final ambiguous = degenerate && g.present != w.present;
  String diagText(IrregularScreenResult r, {bool noAbstain = false}) {
    final j = r.diagnostics.toJson();
    if (noAbstain) j['abstain'] = null;
    return jsonEncode(j);
  }

  expect(g.tier, w.tier, reason: 'tier $why');
  expect(g.inputs_used, w.inputs_used, reason: 'inputs $why');
  expect(diagText(got, noAbstain: ambiguous), diagText(want, noAbstain: ambiguous),
      reason: 'diagnostics$why${ambiguous ? " (but the abstention reason)" : ""}');
  if (ambiguous) {
    final rep = g.present ? got : want, abs = g.present ? want : got;
    expect(abs.diagnostics.abstain, IrregularAbstain.noLongTermVariability,
        reason: 'the only disagreement allowed at a numerically zero SD2 $why');
    expect(rep.diagnostics.abstain, isNull, reason: 'a reported screen did not abstain $why');
    expect(abs.metric.value, isNull, reason: 'absent => no value $why');
    expect(abs.metric.confidence, 0, reason: 'absent => confidence 0 $why');
    final v = rep.metric.value!;
    _expectNumericallyZeroSd2(v, why);
    final k = _keptAndDiffs(nn, t);
    expect(v.nBeats, k.kept.length, reason: 'nBeats $why');
    expect(v.nBeats, rep.diagnostics.nnKept, reason: 'nBeats is the kept count $why');
    _close(v.sd1, _sd(k.diffs)! / math.sqrt2, 'sd1 against the independent value $why');
    // pNN and confidence do not depend on SD2: held to their documented values.
    final over = k.diffs.where((d) => d.abs() > pnnThresholdMs!).length;
    expect(v.pnnPct, k.diffs.isEmpty ? 0.0 : 100.0 * over / k.diffs.length,
        reason: 'pnn against the independent value $why');
    _close(rep.metric.confidence,
        (k.kept.length / 5000.0 * (1 - artifactFraction!)).clamp(0.2, 0.9),
        'confidence against the independent value $why',
        rel: 1e-12);
    return;
  }
  expect(g.present, w.present, reason: 'present $why');
  expect(g.note, w.note, reason: 'note $why');
  if (!w.present) {
    expect(g.value, isNull, reason: 'absent => no value $why');
    expect(g.confidence, 0, reason: 'absent => confidence 0 $why');
    return;
  }
  final a = g.value!, b = w.value!;
  expect(a.flag, b.flag, reason: 'flag $why');
  expect(a.nBeats, b.nBeats, reason: 'nBeats $why');
  expect(a.pnnPct, b.pnnPct, reason: 'pnn $why');
  _close(a.sd1, b.sd1, 'sd1 $why');
  if (degenerate) {
    // Both report: SD2 and the ratio are float noise around zero on both sides.
    _expectNumericallyZeroSd2(a, why);
    _expectNumericallyZeroSd2(b, why);
  } else {
    _close(a.sd2, b.sd2, 'sd2 $why');
    _close(a.sd1sd2, b.sd1sd2, 'sd1sd2 $why');
  }
  _close(g.confidence, w.confidence, 'confidence $why', rel: 1e-12);
}

// The independent window oracle: written from the documented rule, not from
// `irregularWindowVerdict` (which the batch and the stream share).

double? _sd(List<double> x) {
  if (x.length < 2) return null;
  final m = x.reduce((a, b) => a + b) / x.length;
  var ss = 0.0;
  for (final v in x) {
    ss += (v - m) * (v - m);
  }
  return math.sqrt(ss / (x.length - 1));
}

/// Verdict of one closed window of kept beats: null when it holds fewer than
/// [minBeats] - 1 successive differences (validity counts pairs, not beats);
/// else whether SD1/SD2 and pNNx both clear their flag lines. A difference is
/// taken only between two successive beats (never across a skipped beat or a
/// time hole).
bool? _refVerdict(List<double> v, List<bool> adj, double flag, double pnnMs,
    double pnnPct, int minBeats) {
  final d = <double>[
    for (var i = 1; i < v.length; i++)
      if (adj[i]) v[i] - v[i - 1]
  ];
  if (d.length < minBeats - 1) return null;
  final sdsd = _sd(d), sdnn = _sd(v);
  if (sdsd == null || sdnn == null) return false;
  final sd1 = sdsd / math.sqrt2;
  final q = 2 * sdnn * sdnn - sd1 * sd1;
  final sd2 = q > 0 ? math.sqrt(q) : 0.0;
  if (sd2 <= 0) return false;
  final over = d.where((x) => x.abs() > pnnMs).length;
  return sd1 / sd2 >= flag && 100.0 * over / d.length >= pnnPct;
}

typedef _RefWindows = ({
  int total,
  int valid,
  int flagged,
  int openBeats,
  IrregularOpenWindow open,
  int kept,
  int nIn
});

/// The windows of [nn] / [t] (the whole input, kept or not) under screen
/// config [cfg]: a window opens on its first kept beat and closes when a kept
/// beat is a full window later; the sizes cover the kept beats exactly once.
_RefWindows _refWindows(List<double> nn, List<double> t, int cfg) {
  final c = _scCfgs[cfg];
  final windowMs = c.$4 * 60000;
  final sizes = <int>[];
  final verdicts = <bool?>[];
  var vals = <double>[], adj = <bool>[];
  double? start;
  var kept = 0;
  void close() {
    if (vals.isEmpty) return;
    sizes.add(vals.length);
    verdicts.add(_refVerdict(vals, adj, c.$1, c.$2, c.$3, c.$5));
    vals = [];
    adj = [];
  }

  for (var i = 0; i < nn.length; i++) {
    final isKept = nn[i] >= 300 && nn[i] <= 2000;
    if (isKept) {
      kept++;
      start ??= t[i];
      if (t[i] - start >= windowMs) {
        close();
        start = t[i];
      }
      vals.add(nn[i]);
      adj.add(_successive(nn, t, i));
    }
  }
  close();
  expect(sizes.fold<int>(0, (a, b) => a + b), kept,
      reason: 'the windows cover the kept NN exactly once');
  final valid = verdicts.where((v) => v != null).length;
  return (
    total: sizes.length,
    valid: valid,
    flagged: verdicts.where((v) => v == true).length,
    openBeats: sizes.isEmpty ? 0 : sizes.last,
    open: sizes.isEmpty
        ? IrregularOpenWindow.none
        : verdicts.last == null
            ? IrregularOpenWindow.thin
            : verdicts.last!
                ? IrregularOpenWindow.flagged
                : IrregularOpenWindow.unflagged,
    kept: kept,
    nIn: nn.length,
  );
}

/// The diagnostics' beat and window evidence against the independent oracle.
void _expectEvidence(IrregularScreenResult res, List<double> nn, List<double> t,
    int cfg, String why) {
  final dg = res.diagnostics;
  final ref = _refWindows(nn, t, cfg);
  expect(dg.nnIn, ref.nIn, reason: 'nn_in is every entry handed in $why');
  expect(dg.nnKept, ref.kept, reason: 'nn_kept is the in-range ones $why');
  final w = dg.windows;
  if (!_scCfgValid(cfg)) {
    expect(w, isNull, reason: 'an invalid config gives no window evidence $why');
    if (res.metric.present) {
      expect(res.metric.value!.flag, isFalse, reason: 'and cannot flag $why');
    }
    return;
  }
  expect(w, isNotNull, reason: 'a valid config counts windows $why');
  expect(w!.total, ref.total, reason: 'windows total $why');
  expect(w.valid, ref.valid, reason: 'windows valid $why');
  expect(w.flagged, ref.flagged, reason: 'windows flagged $why');
  expect(w.openBeats, ref.openBeats, reason: 'open window beats $why');
  expect(w.open, ref.open, reason: 'open window label $why');
  expect(w.flagged >= 0 && w.flagged <= w.valid && w.valid <= w.total, isTrue,
      reason: 'flagged <= valid <= total $why');
  expect(w.total <= dg.nnKept, isTrue, reason: 'total <= kept $why');
  expect(w.total == 0, dg.nnKept == 0, reason: 'no windows <=> no kept NN $why');
  expect(w.valid * _scCfgs[cfg].$5 <= dg.nnKept, isTrue,
      reason: 'valid windows are full $why');
  expect(w.sustainedObserved, w.valid == 0 ? isNull : w.flagged / w.valid,
      reason: 'flagged / valid, absent (not 0) when no window is valid $why');
  final m = res.metric;
  if (m.present && m.value!.flag) {
    expect(w.valid > 0 && w.flagged >= _scCfgs[cfg].$6 * w.valid, isTrue,
        reason: 'a flag is backed by enough flagged windows $why');
  }
  expect(m.present, dg.abstain == null, reason: 'present <=> not abstained $why');
}

typedef _NnCase = ((int, int, int, int), (int, int, int, int));

/// ((flavour, beats, seed, salt), (cfg, splits + cut seed, restart mask,
/// evaluation)).
Gen<_NnCase> _nnCaseGen(int maxN) => G.pair(
      G.quad(G.intIn(0, _nNnFlavours - 1), _NGen(maxN), G.intIn(0, 1 << 16),
          G.elements(const [0, 0, 1, 2, 3])),
      G.quad(G.intIn(0, _scCfgs.length - 1), G.intIn(0, 6 * (1 << 20) + (1 << 20)),
          G.intIn(0, 127), G.intIn(0, _evals.length - 1)),
    );

String _nnTag(_NnCase c) {
  final ((f, n, seed, salt), (cfg, sc, restart, ev)) = c;
  return '${_nnFlavours[f]} n=$n seed=$seed salt=$salt cfg=$cfg '
      'splits/cut=${sc ~/ (1 << 20)}/${sc % (1 << 20)} restart=$restart eval=$ev';
}

List<int> _nnBounds(_NnCase c) {
  final n = c.$1.$2;
  final sc = c.$2.$2;
  return _bounds(n, sc ~/ (1 << 20), sc % (1 << 20));
}

void _observeNn(_NnCase c, void Function(String) bump) {
  final ((f, n, _, salt), (cfg, _, restart, ev)) = c;
  bump('flavour: ${_nnFlavours[f]}');
  if (n == 0) bump('beats: none');
  if (n >= 1 && n < 40) bump('beats: under a thin window');
  if (n >= 500) bump('beats: 500 or more');
  if (n >= 1500) bump('beats: 1500 or more');
  if (salt >= 1) bump('out-of-range entries');
  if (salt >= 2) bump('NaN entries');
  bump(_scCfgValid(cfg) ? 'config: valid' : 'config: invalid');
  if (cfg != 0) bump('config: not the default');
  final b = _nnBounds(c);
  if (b.length >= 4) bump('chunks: three or more');
  if (hasEmptyChunk(b)) bump('an empty chunk');
  if (restart != 0 && b.length > 2) bump('a restore between chunks');
  bump('evaluation: $ev');
}

const Map<String, double> _nnShares = {
  'flavour: sinus': .03,
  'flavour: af': .03,
  'flavour: blocks': .03,
  'flavour: flat': .03,
  'flavour: two point': .03,
  'flavour: sinus + gaps': .03,
  'flavour: af heavy': .03,
  'flavour: range edges': .03,
  'beats: under a thin window': .05,
  'beats: 500 or more': .08,
  'out-of-range entries': .3,
  'NaN entries': .2,
  'config: valid': .4,
  'config: invalid': .15,
  'config: not the default': .4,
  'chunks: three or more': .4,
  'an empty chunk': .05,
  'a restore between chunks': .3,
  'evaluation: 0': .03,
  'evaluation: 1': .03,
  'evaluation: 2': .03,
  'evaluation: 3': .03,
  'evaluation: 4': .03,
  'evaluation: 5': .03,
  'evaluation: 6': .03,
  'evaluation: 7': .03,
};

_NnCase _n(int flavour, int n,
        {int seed = 5,
        int salt = 0,
        int cfg = 0,
        int splits = 3,
        int cut = 1,
        int restart = 0,
        int ev = 1}) =>
    ((flavour, n, seed, salt), (cfg, splits * (1 << 20) + cut, restart, ev));

final List<_NnCase> _nnForced = [
  _n(0, 0, ev: 0), // nothing folded
  _n(0, 0, ev: 6), // nothing folded, zero beats seen by the corrector
  _n(0, 1),
  _n(0, 2),
  _n(0, 39, splits: 4, cfg: 1, ev: 1), // one beat short of a thin window of 40
  _n(0, 40, splits: 4, cfg: 0, ev: 1), // exactly the minimum window
  _n(0, 41, splits: 4, cfg: 0, ev: 1),
  _n(0, 2, cfg: 2, ev: 4), // minimum window of 2 beats, minimum beats 2
  _n(0, 3, cfg: 2, ev: 4), // exactly two successive differences
  _n(1, 3, cfg: 2, ev: 4),
  _n(1, 4, cfg: 2, ev: 4),
  _n(7, 200, cfg: 1, ev: 1, splits: 5, restart: 127), // the edges of the kept range
  _n(7, 7, cfg: 2, ev: 4, splits: 3), // exactly one period
  _n(3, 300, cfg: 0, ev: 1, splits: 5, restart: 127), // flat: SD2 = 0
  _n(4, 300, cfg: 2, ev: 1, splits: 5, restart: 127), // two point
  _n(1, 900, cfg: 0, ev: 1, splits: 6, cut: 3, restart: 127), // AF: flags
  _n(6, 1500, cfg: 1, ev: 1, splits: 6, cut: 4, restart: 127), // AF heavy, short windows
  _n(2, 1200, cfg: 0, ev: 0, splits: 6, cut: 5), // blocks, default minimum 500
  _n(0, 800, salt: 2, cfg: 3, ev: 5, splits: 6, cut: 6, restart: 85), // out-of-range + NaN
  _n(1, 400, salt: 3, cfg: 2, ev: 7, splits: 4, cut: 7, restart: 127), // NaN, artifact exactly at the maximum
  _n(5, 900, cfg: 1, ev: 3, splits: 6, cut: 8), // gaps; artifact fraction over the maximum
  _n(1, 600, cfg: 4, ev: 1, splits: 3, cut: 9), // invalid: no window length
  _n(1, 600, cfg: 5, ev: 1, splits: 3, cut: 10), // invalid: windows of 1 beat
  _n(1, 600, cfg: 6, ev: 1, splits: 3, cut: 11), // invalid: fraction 1.5
  _n(1, 600, cfg: 7, ev: 1, splits: 3, cut: 12), // invalid: two at once
  _n(2, 700, cfg: 8, ev: 2, splits: 5, cut: 13), // wide thresholds
  _n(0, 3000, cfg: 0, ev: 0, splits: 6, cut: 14, restart: 127), // the cap, default minimum
  _n(1, 3000, cfg: 1, ev: 1, splits: 6, cut: 15, restart: 127),
];

/// Days with an open window, completed windows and counts worth contradicting:
/// the base the mutated-checkpoint law cuts its mutations from.
final List<_NnCase> _nnL3 = _nnForced
    .where((c) => c.$1.$2 >= 600 && _scCfgValid(c.$2.$1))
    .take(3)
    .toList();

/// Window edge hit EXACTLY: a kept beat a full window after the window's first
/// closes it (>=). Hand-built, so it does not depend on a generator reaching it.
({List<double> nn, List<double> t}) _edgeSeries() {
  final nn = <double>[], t = <double>[];
  // 60 beats at 5000 ms: the 61st lands exactly 300000 ms after the first.
  for (var i = 0; i < 62; i++) {
    nn.add(800.0 + (i % 7) * 11);
    t.add(10000.0 + i * 5000);
  }
  return (nn: nn, t: t);
}

void _foldChunks(IrregularScreenState Function() make, _Nn s, List<int> bounds,
    int restart, void Function(IrregularScreenState st, int k, int at)? seam,
    {IrregularScreenState? into}) {
  var st = into ?? make();
  for (var k = 0; k + 1 < bounds.length; k++) {
    st.fold(s.nn.sublist(bounds[k], bounds[k + 1]), s.t.sublist(bounds[k], bounds[k + 1]));
    if ((restart >> (k % 7)) & 1 == 1) st = _srestore(st);
    seam?.call(st, k, bounds[k + 1]);
  }
}

void _scL1(_NnCase c) {
  final ((f, n, seed, salt), (cfg, _, restart, ev)) = c;
  final s = _nnSeries(f, n, seed, salt);
  final tag = _nnTag(c);
  final bounds = _nnBounds(c);
  final whole = _newState(cfg)..fold(s.nn, s.t);
  late IrregularScreenState got;
  var st = _newState(cfg);
  for (var k = 0; k + 1 < bounds.length; k++) {
    st.fold(s.nn.sublist(bounds[k], bounds[k + 1]), s.t.sublist(bounds[k], bounds[k + 1]));
    if ((restart >> (k % 7)) & 1 == 1) st = _srestore(st);
  }
  got = st;
  expect(_stext(got), _stext(whole), reason: '$tag bounds=$bounds: same checkpoint text');
  for (var e = 0; e < _evals.length; e++) {
    expect(jsonEncode(_evaluate(got, e, beats: n).toJson()),
        jsonEncode(_evaluate(whole, e, beats: n).toJson()),
        reason: '$tag: evaluation $e reads the same');
  }
}

/// An evaluation with a provisional tail equals the state after folding it.
void _scL1b(_NnCase c) {
  final ((f, n, seed, salt), (cfg, _, restart, ev)) = c;
  final s = _nnSeries(f, n, seed, salt);
  final tag = _nnTag(c);
  final bounds = _nnBounds(c);
  final picks = pickSeams(bounds.length - 1);
  _foldChunks(() => _newState(cfg), s, bounds, restart, (st, k, at) {
    if (!picks.contains(k)) return;
    // The tail is what a corrector would still hold provisional: some of the
    // beats after the seam.
    final tailEnd = math.min(n, at + (at * 7 + k * 13) % 97);
    final tailNn = s.nn.sublist(at, tailEnd), tailT = s.t.sublist(at, tailEnd);
    final before = _stext(st);
    final got = _evaluate(st, ev, tailNn: tailNn, tailT: tailT, beats: tailEnd);
    expect(_stext(st), before, reason: '$tag: evaluate reads, never writes');
    final want = _batchScreenOf(s.nn.sublist(0, tailEnd), s.t.sublist(0, tailEnd), cfg, ev);
    final why = '$tag seam $k at $at tail to $tailEnd';
    _sameScreen(got, want, why,
        nn: s.nn.sublist(0, tailEnd),
        t: s.t.sublist(0, tailEnd),
        pnnThresholdMs: _scCfgs[cfg].$2,
        artifactFraction: _evals[ev].$3);
    _expectEvidence(got, s.nn.sublist(0, tailEnd), s.t.sublist(0, tailEnd), cfg, why);
  });
}

String _projectScreen(IrregularScreenState st, int beats) => jsonEncode([
      for (var e = 0; e < _evals.length; e++) _evaluate(st, e, beats: beats).toJson(),
      _evaluate(st, 0, tailNn: const [800, 810, 790], tailT: const [1e12, 1e12 + 810, 1e12 + 1600], beats: beats).toJson(),
    ]);

void _scL2(_NnCase c) {
  final ((f, n, seed, salt), (cfg, _, restart, _)) = c;
  final s = _nnSeries(f, n, seed, salt);
  final tag = _nnTag(c);
  final bounds = _nnBounds(c);
  final at = bounds.length > 2 ? bounds[1] : n ~/ 2;
  final live = _newState(cfg)..fold(s.nn.sublist(0, at), s.t.sublist(0, at));
  final text = _stext(live);
  final map = (jsonDecode(text) as Map).cast<String, dynamic>();
  final back = IrregularScreenState.fromJson(map);
  expect(_stext(back), text, reason: '$tag: write(read(b)) == b');
  expect(_projectScreen(back, at), _projectScreen(live, at),
      reason: '$tag: the restored one reads what the live one reads');
  // Its parameters travel with it: a restored state is not re-owned by whoever
  // reads it (the thresholds it reports are the ones it was built with).
  final c0 = _scCfgs[cfg];
  expect(back.windowMinutes, c0.$4, reason: tag);
  expect(back.minWindowBeats, c0.$5, reason: tag);
  expect(back.sustainedFraction, c0.$6, reason: tag);
  expect(back.sd1sd2Flag, c0.$1, reason: tag);
  // Not aliased to the map it came from.
  (map['bk'] as List).clear();
  (map['bkAdj'] as List).clear();
  expect(_stext(back), text, reason: '$tag: not aliased to the map');
  live.fold(s.nn.sublist(at), s.t.sublist(at));
  back.fold(s.nn.sublist(at), s.t.sublist(at));
  expect(_stext(back), _stext(live), reason: '$tag: same checkpoint after the rest');
  expect(_projectScreen(back, n), _projectScreen(live, n), reason: tag);
}

(Map<String, dynamic>, Must) _mutateScreen(Map<String, dynamic> src, Mut m) {
  final j = (deepCopy(src) as Map).cast<String, dynamic>();
  final (kind, a, b) = m;
  final keys = j.keys.toList();
  List l(String k) => j[k] as List;
  switch (kind % 11) {
    case 0:
      // Version 1 (before the diagnostics counters) and version 2 (before the
      // previous beat's time) are REFUSED, not restored with state they never
      // kept; so is everything else but 3.
      const versions = <Object?>[0, 1, 2, -1, 99, '3', null, true, 1 << 40];
      j['version'] = versions[a % versions.length];
      return (j, Must.refuse);
    case 1:
      const types = <Object?>['RrCorrector', 'Other', null, '', 'irregularscreenstate', 2];
      j['type'] = types[a % types.length];
      return (j, Must.refuse);
    case 2:
      final k = keys.where((k) => k != 'winStart').toList()[a % (keys.length - 1)];
      j.remove(k);
      return (j, Must.refuse);
    case 3:
      final k = keys.where((k) => k != 'winStart').toList()[a % (keys.length - 1)];
      const junk = <Object?>['x', <String, Object?>{}, <Object?>[<Object?>[]]];
      j[k] = junk[b % junk.length];
      return (j, Must.refuse);
    case 4:
      // The open window's beats and their neighbour flags disagree.
      if (b.isEven) {
        l('bkAdj').add(1);
      } else if (l('bk').isEmpty) {
        l('bk').add(800.0);
      } else {
        l('bk').removeLast();
      }
      return (j, Must.refuse);
    case 5:
      // Counts that contradict each other: more kept than seen, more valid
      // windows than windows, more flagged than valid, more over than diffs.
      switch (a % 5) {
        case 0:
          j['nKept'] = (j['nIn'] as int) + 1;
        case 1:
          j['total'] = (j['valid'] as int) - 1;
        case 2:
          j['flagged'] = (j['valid'] as int) + 1;
        case 3:
          j['over'] = (j['dN'] as int) + 1;
        default:
          j['nIn'] = (j['nKept'] as int) - 1;
      }
      return (j, Must.refuse);
    case 6:
      // Negative counts.
      j[const ['nIn', 'nKept', 'dN', 'lN', 'over', 'flagged'][a % 6]] = -1 - b % 5;
      return (j, Must.refuse);
    case 7:
      // The neighbour flags are not flags. (Integers other than 0 / 1 are the
      // reader's one leniency, see the skipped finding below.)
      const notFlags = <Object?>['x', null, 1.5, true, <Object?>[]];
      if (l('bkAdj').isEmpty) {
        l('bkAdj').add(notFlags[a % notFlags.length]);
        l('bk').add(800.0);
      } else {
        l('bkAdj')[b % l('bkAdj').length] = notFlags[a % notFlags.length];
      }
      return (j, Must.refuse);
    case 8:
      // Hostile sizes, and parts that disagree in ways the reader does not
      // cross-check (the skipped FINDING below): refused, or exactly what was
      // written.
      const huge = <int>[1 << 40, 1 << 62, 0x7fffffffffffffff];
      switch (a % 8) {
        case 0:
          j['nIn'] = huge[b % huge.length];
        case 1:
          j['nKept'] = (j['nIn'] as int);
          j['lN'] = (j['lN'] as int) + 1; // levels seen != kept beats
        case 2:
          j['dN'] = huge[b % huge.length]; // more differences than beats
        case 3:
          j['lN'] = huge[b % huge.length];
        case 4:
          j['total'] = (j['nKept'] as int) + 1 + b % 5; // more windows than beats
        case 5:
          j['valid'] = huge[b % huge.length];
          j['total'] = huge[b % huge.length];
        case 6:
          j['over'] = (j['dN'] as int); // every difference over the threshold
        default:
          l('bk').addAll(List<double>.filled(1 + b % 3, 800.0));
          l('bkAdj').addAll(List<int>.filled(1 + b % 3, 1));
      }
      return (j, Must.faithful);
    case 9:
      // One number changed: the reader cannot tell it from a legal checkpoint.
      switch (a % 9) {
        case 0:
          j['dMean'] = (j['dMean'] as num) + 1.0;
        case 1:
          j['lM2'] = (j['lM2'] as num) + 1.0;
        case 2:
          j['prevV'] = (j['prevV'] as num) + 1.0;
        case 3:
          j['prevKept'] = !(j['prevKept'] as bool);
        case 4:
          j['pnnFlagPct'] = (j['pnnFlagPct'] as num) + 1.0;
        case 5:
          j['sd1sd2Flag'] = (j['sd1sd2Flag'] as num) + 0.1;
        case 6:
          j['winStart'] = ((j['winStart'] as num?) ?? 0) + 1.0;
        case 7:
          j['prevT'] = ((j['prevT'] as num?) ?? 0) + 1.0;
        default:
          if (l('bk').isNotEmpty) l('bk')[b % l('bk').length] = (l('bk')[b % l('bk').length] as num) + 1.0;
      }
      return (j, Must.faithful);
    default:
      j['futureField${a % 3}'] = const [1, 'x', <Object?>[1]][b % 3];
      return (j, Must.ignored);
  }
}

String _screenCheckpointOutcome(Map<String, dynamic> j) {
  try {
    final s = IrregularScreenState.fromJson((deepCopy(j) as Map).cast<String, dynamic>());
    return 'accepted:${jsonEncode(s.toJson())}';
  } on FormatException {
    return 'refused';
  } catch (e) {
    return 'WRONG ERROR TYPE: ${e.runtimeType}: $e';
  }
}

void _scL3((_NnCase, Mut) arg) {
  final (c, m) = arg;
  final ((f, n, seed, salt), (cfg, _, _, _)) = c;
  final tag = '${_nnTag(c)} mutation=${m.$1 % 11}(${m.$2},${m.$3})';
  final s = _nnSeries(f, n, seed, salt);
  final st = _newState(cfg)..fold(s.nn, s.t);
  final src = (jsonDecode(_stext(st)) as Map).cast<String, dynamic>();
  final (bad, must) = _mutateScreen(src, m);
  expectMutationOutcome(_screenCheckpointOutcome(bad), must, jsonEncode(bad),
      jsonEncode(src), tag);
}

void _scL4(_NnCase c) {
  final ((f, n, seed, salt), (cfg, _, _, ev)) = c;
  final s = _nnSeries(f, n, seed, salt);
  final tag = _nnTag(c);
  final fresh = _stext(_newState(cfg));
  // An empty fold on a fresh state records nothing.
  final empty = _newState(cfg)..fold(const [], const []);
  expect(_stext(empty), fresh, reason: '$tag: an empty first fold records nothing');
  final cut = n ~/ 2;
  final st = _newState(cfg)..fold(s.nn.sublist(0, cut), s.t.sublist(0, cut));
  final before = _stext(st);
  st.fold(const [], const []);
  expect(_stext(st), before, reason: '$tag: an empty fold is the identity');
  // evaluate reads and never writes, with or without a tail, twice equal.
  final one = _evaluate(st, ev, beats: cut);
  expect(_stext(st), before, reason: '$tag: evaluate is read-only');
  final tail = s.nn.sublist(cut, math.min(n, cut + 20));
  final tailT = s.t.sublist(cut, math.min(n, cut + 20));
  _evaluate(st, ev, tailNn: tail, tailT: tailT, beats: cut + tail.length);
  expect(_stext(st), before, reason: '$tag: and with a tail');
  expect(jsonEncode(_evaluate(st, ev, beats: cut).toJson()), jsonEncode(one.toJson()),
      reason: '$tag: twice is equal');
  // Refusal: lengths that disagree change nothing.
  expect(() => st.fold([800, 810], const [1.0]), throwsArgumentError, reason: tag);
  expect(() => st.fold(const [], [1.0]), throwsArgumentError, reason: tag);
  expect(_stext(st), before, reason: '$tag: a refused fold leaves the state unchanged');
}

void _scL5(_NnCase c) {
  final ((f, n, seed, salt), (cfg, _, restart, ev)) = c;
  final s = _nnSeries(f, n, seed, salt);
  final tag = _nnTag(c);
  final bounds = _nnBounds(c);
  _foldChunks(() => _newState(cfg), s, bounds, restart, (st, k, at) {
    final res = _evaluate(st, ev, beats: at);
    final why = '$tag seam $k at $at';
    final dg = res.diagnostics;
    final inRange = [for (final v in s.nn.sublist(0, at)) if (v >= 300 && v <= 2000) v];
    expect(dg.nnIn, at, reason: 'nn_in is every entry folded $why');
    expect(dg.nnKept, inRange.length, reason: 'nn_kept is the in-range ones $why');
    expect(dg.nnKept <= dg.nnIn, isTrue, reason: why);
    _expectEvidence(res, s.nn.sublist(0, at), s.t.sublist(0, at), cfg, why);
    final m = res.metric;
    // The beat gate counts successive pairs (minBeats - 1 of them), not beats:
    // too few pairs abstains, and nothing past that gate does.
    final pairs = _pairsOf(s.nn.sublist(0, at), s.t.sublist(0, at));
    final enoughPairs = pairs >= dg.thresholds.minBeats - 1;
    expect(dg.abstain == IrregularAbstain.tooFewBeats, !enoughPairs,
        reason: 'too few beats <=> fewer than minBeats - 1 pairs ($pairs) $why');
    if (m.present) {
      expect(m.value!.nBeats, dg.nnKept, reason: 'nBeats == nn_kept $why');
      expect(dg.nnKept >= dg.thresholds.minBeats, isTrue, reason: 'min beats $why');
    }
    if (dg.abstain == IrregularAbstain.artifact) {
      expect(enoughPairs, isTrue, reason: why);
      expect(dg.nnKept >= dg.thresholds.minBeats, isTrue, reason: why);
      expect(_evals[ev].$3 > dg.thresholds.maxArtifact, isTrue, reason: why);
    }
  });
}

// ── IP: the corrector and the screen together, as the day pass runs them ─────

/// (a beat series and its chunking, screen config index, evaluation index).
typedef _IpCase = (_Case, int, int);

Gen<_IpCase> _ipGen(int maxN) => G.triple(_caseGen(maxN),
    G.intIn(0, _scCfgs.length - 1), G.intIn(0, _evals.length - 1));

String _ipTag(_IpCase c) => '${_tag(c.$1)} screen=${c.$2} eval=${c.$3}';

void _observeIp(_IpCase c, void Function(String) bump) {
  _observeRr(c.$1, bump);
  final (flavour, n, _, _) = c.$1.$1;
  bump(_scCfgValid(c.$2) ? 'config: valid' : 'config: invalid');
  if (c.$2 != 0) bump('config: not the default');
  bump('evaluation: ${c.$3}');
  if (flavour == 2 && n >= 600) bump('a long irregularly irregular day');
}

const Map<String, double> _ipShares = {
  ..._rrShares,
  'config: valid': .4,
  'config: invalid': .1,
  'config: not the default': .4,
  'evaluation: 0': .02,
  'evaluation: 1': .02,
  'evaluation: 2': .02,
  'evaluation: 3': .02,
  'evaluation: 4': .02,
  'evaluation: 5': .02,
  'evaluation: 6': .02,
  'evaluation: 7': .02,
  'a long irregularly irregular day': .02,
};

/// What the day pass computes at a seam: the corrector's provisional tail and
/// counts handed to the screen state.
IrregularScreenResult _ipStream(RrCorrector corr, IrregularScreenState st, int ev) {
  final snap = corr.snapshot();
  final e = _evals[ev];
  return st.evaluateDetailed(snap.tailNn, snap.tailNnTimes,
      artifactFraction: (1.0 - snap.cleanFraction).clamp(0.0, 1.0),
      minBeats: e.$1,
      maxArtifact: e.$2,
      cleaning: RrCleaningCounts(
          raw: snap.n, corrected: snap.correctedCount, dropped: snap.droppedCount));
}

void _ipBody(_IpCase arg) {
  final (c, scr, ev) = arg;
  final ((flavour, n, seed, mode), (splits, cutSeed, restart, cfg)) = c;
  final s = _series(flavour, n, seed);
  final wall = mode == 0;
  final tag = _ipTag(arg);
  final bounds = _bounds(n, splits, cutSeed);
  final picks = pickSeams(bounds.length - 1);
  var corr = _newCorrector(cfg);
  var st = _newState(scr);
  for (var k = 0; k + 1 < bounds.length; k++) {
    final settled = corr.fold(s.rr.sublist(bounds[k], bounds[k + 1]),
        tsMs: _tsSlice(s, wall, bounds[k], bounds[k + 1]));
    st.fold(settled.nn, settled.nnTimes);
    if ((restart >> (k % 7)) & 1 == 1) {
      corr = _restore(corr);
      st = _srestore(st);
    }
    if (!picks.contains(k)) continue;
    final at = bounds[k + 1];
    final why = '$tag seam $k at $at';
    final got = _ipStream(corr, st, ev);
    final want = _oracle(s, wall, cfg, at);
    final e = _evals[ev];
    final cs = _scCfgs[scr];
    final batch = irregularBeatScreenDetailed(want.nn,
        nnTimesMs: want.nnTimesMs,
        artifactFraction: (1.0 - want.cleanFraction).clamp(0.0, 1.0),
        minBeats: e.$1,
        maxArtifact: e.$2,
        sd1sd2Flag: cs.$1,
        pnnThresholdMs: cs.$2,
        pnnFlagPct: cs.$3,
        windowMinutes: cs.$4,
        minWindowBeats: cs.$5,
        sustainedFraction: cs.$6,
        cleaning: RrCleaningCounts(
            raw: at, corrected: want.correctedCount, dropped: want.droppedCount));
    _sameScreen(got, batch, why,
        nn: want.nn,
        t: want.nnTimesMs,
        pnnThresholdMs: cs.$2,
        artifactFraction: (1.0 - want.cleanFraction).clamp(0.0, 1.0));
    // L5, integrated: the corrector's counts are the screen's evidence.
    final dg = got.diagnostics;
    expect(dg.rrRaw, at, reason: 'rr_raw is every beat the corrector saw $why');
    expect(dg.dropped, want.droppedCount, reason: 'dropped $why');
    expect(dg.corrected, want.correctedCount, reason: 'corrected $why');
    expect(dg.nnIn, at - dg.dropped!, reason: 'nn_in == rr_raw - dropped $why');
    expect(dg.corrected! + dg.dropped! <= at, isTrue, reason: why);
    expect(dg.nnKept <= dg.nnIn, isTrue, reason: 'kept <= in $why');
    if (at == 0) {
      expect(dg.artifactFraction, isNull,
          reason: 'a share of no beats is absent, not 1.0 $why');
    } else {
      expect(dg.artifactFraction, (1.0 - want.cleanFraction).clamp(0.0, 1.0),
          reason: 'artifact fraction $why');
    }
    if (dg.abstain == IrregularAbstain.artifact) {
      // The gate reads the fraction handed in. With nothing seen (and a pair
      // gate of zero) that is 1 - cleanFraction of no beats, while the
      // diagnostics report the share as absent, not 1.0 (0fc5768).
      final handed = (1.0 - want.cleanFraction).clamp(0.0, 1.0);
      expect(handed > dg.thresholds.maxArtifact, isTrue, reason: why);
      if (at != 0) {
        expect(dg.artifactFraction! > dg.thresholds.maxArtifact, isTrue, reason: why);
      }
    }
    _expectEvidence(got, want.nn, want.nnTimesMs, scr, why);
  }
}

// ── W: the diagnostics wire ─────────────────────────────────────────────────

const List<double> _fractions = [0.0, .07, .30, .31, 1.0, .5];

/// (flavour, beats, seed) of a small NN series, screen config, evaluation, and
/// the artifact fraction index handed in.
typedef _WireCase = (_NnRec, int, int, int);

Gen<_WireCase> _wireGen() => G.quad(
    G.quad(G.intIn(0, _nNnFlavours - 1), _NGen(300), G.intIn(0, 1 << 12),
        G.elements(const [0, 1, 2, 3])),
    G.intIn(0, _scCfgs.length - 1),
    G.intIn(0, _evals.length - 1),
    G.intIn(0, _fractions.length - 1));

IrregularScreenResult _wireResult(_WireCase c) {
  final ((f, n, seed, salt), cfg, ev, fr) = c;
  final s = _nnSeries(f, n, seed, salt);
  final e = _evals[ev];
  final cs = _scCfgs[cfg];
  return irregularBeatScreenDetailed(s.nn,
      nnTimesMs: s.t,
      artifactFraction: _fractions[fr],
      minBeats: math.min(e.$1, 30),
      maxArtifact: e.$2,
      sd1sd2Flag: cs.$1,
      pnnThresholdMs: cs.$2,
      pnnFlagPct: cs.$3,
      windowMinutes: cs.$4,
      minWindowBeats: cs.$5,
      sustainedFraction: cs.$6,
      cleaning: _cleaningFor(e.$4, n));
}

/// Every field a reader of the diagnostics can see.
String _projectDiagnostics(IrregularDiagnostics d) {
  final w = d.windows, t = d.thresholds;
  return jsonEncode([
    d.abstain?.index,
    d.rrRaw,
    d.corrected,
    d.dropped,
    d.nnIn,
    d.nnKept,
    d.artifactFraction,
    w == null
        ? null
        : [w.total, w.valid, w.flagged, w.openBeats, w.open.index, w.sustainedObserved],
    [
      t.minBeats,
      t.maxArtifact,
      t.sd1sd2Flag,
      t.pnnThresholdMs,
      t.pnnFlagPct,
      t.windowMinutes,
      t.minWindowBeats,
      t.sustainedFraction
    ],
  ]);
}

void _wL2(_WireCase c) {
  final res = _wireResult(c);
  final text = jsonEncode(res.diagnostics.toJson());
  final back = IrregularDiagnostics.fromJson(
      (jsonDecode(text) as Map).cast<String, dynamic>());
  expect(jsonEncode(back.toJson()), text, reason: 'write(read(b)) == b');
  expect(_projectDiagnostics(back), _projectDiagnostics(res.diagnostics),
      reason: 'the restored evidence reads what the live one reads');
  // The envelope edge persists: the old metric keys, unchanged, and one more.
  final env = res.toJson();
  final old = res.metric.toJson((v) => v.toJson());
  for (final k in old.keys) {
    expect(jsonEncode(env[k]), jsonEncode(old[k]), reason: 'envelope key $k');
  }
  expect(env.keys.toSet(), {...old.keys, 'diagnostics'});
  expect(jsonEncode(env['diagnostics']), text);
  // Absent stays absent on the wire: an unknown count or window is JSON null.
  final beats = (jsonDecode(text) as Map)['beats'] as Map;
  expect(beats['rr_raw'], res.diagnostics.rrRaw);
  expect(beats['artifact_fraction'], res.diagnostics.artifactFraction);
  expect((jsonDecode(text) as Map)['windows'] == null, res.diagnostics.windows == null);
}

(Map<String, dynamic>, Must) _mutateWire(Map<String, dynamic> src, Mut m) {
  final j = (deepCopy(src) as Map).cast<String, dynamic>();
  final (kind, a, b) = m;
  Map sec(String k) => j[k] as Map;
  switch (kind % 8) {
    case 0:
      const versions = <Object?>[0, 2, 3, -1, 99, '1', null, true, 1 << 40];
      j['version'] = versions[a % versions.length];
      return (j, Must.refuse);
    case 1:
      const names = <Object?>['unknown', '', 'tooFewBeats', 'TOO_FEW_BEATS', 3, <Object?>[]];
      j['abstain'] = names[a % names.length];
      return (j, Must.refuse);
    case 2:
      j.remove(const ['beats', 'thresholds', 'version'][a % 3]);
      return (j, Must.refuse);
    case 3:
      final k = const ['beats', 'thresholds'][a % 2];
      const junk = <Object?>['x', <Object?>[], 1, null];
      j[k] = junk[b % junk.length];
      return (j, Must.refuse);
    case 4:
      // A field of the wrong kind inside a section.
      final keys = [...sec('beats').keys.where((k) => k == 'nn_in' || k == 'nn_kept')];
      final tk = sec('thresholds').keys.toList();
      if (a.isEven) {
        sec('beats')[keys[b % keys.length]] = const ['x', null, 1.5, <Object?>[]][a % 4];
      } else {
        sec('thresholds')[tk[b % tk.length]] = const ['x', null, <Object?>[]][a % 3];
      }
      return (j, Must.refuse);
    case 5:
      // The open window named something that is not one.
      if (j['windows'] == null) {
        j['windows'] = {
          'total': 1,
          'valid': 1,
          'flagged': 0,
          'sustained_observed': 0.0,
          'open_beats': 1,
          'open': 'bogus'
        };
      } else {
        sec('windows')['open'] = const ['bogus', '', 'FLAGGED', 3, null][a % 5];
      }
      return (j, Must.refuse);
    case 6:
      // Numbers changed, or parts that disagree about the evidence: the wire
      // is evidence, not a state, and carries no cross-check (the skipped
      // FINDING below): refused, or exactly what was written.
      switch (a % 6) {
        case 0:
          sec('beats')['nn_kept'] = (sec('beats')['nn_kept'] as int) + 1 + b % 5;
        case 1:
          sec('beats')['nn_in'] = (sec('beats')['nn_in'] as int) + 1;
        case 2:
          sec('thresholds')['max_artifact'] = (sec('thresholds')['max_artifact'] as num) + .1;
        case 3:
          sec('beats')['artifact_fraction'] = 1.0;
        case 4:
          if (j['windows'] != null) {
            sec('windows')['flagged'] = (sec('windows')['valid'] as int) + 1 + b % 3;
          }
        default:
          if (j['windows'] != null) sec('windows')['total'] = 0;
      }
      // `sustained_observed` is derived (flagged / valid) and written afresh;
      // keep the mutated text consistent with that.
      final w = j['windows'] as Map?;
      if (w != null) {
        w['sustained_observed'] = (w['valid'] as int) == 0
            ? null
            : (w['flagged'] as int) / (w['valid'] as int);
      }
      return (j, Must.faithful);
    default:
      if (a % 4 == 3 && j['windows'] != null) {
        // The derived figure is not read: whatever it says, the reader writes
        // flagged / valid back.
        sec('windows')['sustained_observed'] = 0.123456;
      } else {
        j['futureField${a % 3}'] = const [1, 'x', <Object?>[1]][b % 3];
      }
      return (j, Must.ignored);
  }
}

String _wireOutcome(Map<String, dynamic> j) {
  try {
    final d = IrregularDiagnostics.fromJson(
        (deepCopy(j) as Map).cast<String, dynamic>());
    return 'accepted:${jsonEncode(d.toJson())}';
  } on FormatException {
    return 'refused';
  } catch (e) {
    return 'WRONG ERROR TYPE: ${e.runtimeType}: $e';
  }
}

void _wL3((_WireCase, Mut) arg) {
  final (c, m) = arg;
  final tag = 'wire ${c.$1} cfg=${c.$2} eval=${c.$3} frac=${c.$4} '
      'mutation=${m.$1 % 8}(${m.$2},${m.$3})';
  final src = (jsonDecode(jsonEncode(_wireResult(c).diagnostics.toJson())) as Map)
      .cast<String, dynamic>();
  final (bad, must) = _mutateWire(src, m);
  expectMutationOutcome(_wireOutcome(bad), must, jsonEncode(bad), jsonEncode(src), tag);
}

/// The "absent, not zero" rules (0fc5768): cleaning counts are null when the
/// caller gave none; the artifact fraction is null when the corrector saw no
/// beats (a share of nothing; the 1.0 of `1 - cleanFraction` of an empty series
/// would read as every beat being an artifact), the fraction handed in
/// otherwise. The verdict gate still reads the fraction handed in. The batch
/// and the stream agree.
void _wAbsent(_WireCase c) {
  final ((f, n, seed, salt), cfg, ev, fr) = c;
  final s = _nnSeries(f, n, seed, salt);
  final e = _evals[ev];
  final fraction = _fractions[fr];
  final cleaning = _cleaningFor(e.$4, n);
  final tag = 'n=$n flavour=${_nnFlavours[f]} cleaning=${e.$4} fraction=$fraction';
  final batch = _batchScreenOf(s.nn, s.t, cfg, ev);
  final st = _newState(cfg)..fold(s.nn, s.t);
  final stream = st.evaluateDetailed(const [], const [],
      artifactFraction: e.$3, minBeats: e.$1, maxArtifact: e.$2, cleaning: cleaning);
  for (final r in [batch, stream]) {
    final d = r.diagnostics;
    expect(d.rrRaw, cleaning?.raw, reason: '$tag: rr_raw is absent without counts');
    expect(d.corrected, cleaning?.corrected, reason: tag);
    expect(d.dropped, cleaning?.dropped, reason: tag);
    final noBeats = cleaning != null && cleaning.raw == 0;
    expect(d.artifactFraction, noBeats ? isNull : e.$3,
        reason: '$tag: the artifact fraction of no beats is absent, not ${e.$3}');
    final wire = d.toJson()['beats'] as Map;
    expect(wire['artifact_fraction'], d.artifactFraction, reason: tag);
    // The gate still reads the fraction handed in.
    // Past the pair gate (minBeats - 1 successive pairs), the artifact gate
    // comes next.
    if (_pairsOf(s.nn, s.t) >= e.$1 - 1 && e.$3 > e.$2) {
      expect(d.abstain, IrregularAbstain.artifact, reason: '$tag: gate');
    }
    if (d.abstain == IrregularAbstain.artifact) {
      expect(e.$3 > e.$2, isTrue, reason: '$tag: gate');
    }
  }
  // And a screen that ran with no beats counted is still not 1.0.
  // (fraction is also drawn directly: see the wire cases below.)
  expect(fraction, _fractions[fr]);
  final aj = jsonEncode(batch.diagnostics.toJson()), bj = jsonEncode(stream.diagnostics.toJson());
  if (n > 0 || cleaning == null) {
    // Same beats in: the same evidence from both sides, abstention included
    // (but at a numerically zero SD2, see _sd2Degenerate, the reason may differ).
    String noReason(String t) =>
        jsonEncode((jsonDecode(t) as Map)..['abstain'] = null);
    if (_sd2Degenerate(s.nn, s.t)) {
      // Only the abstention reason may differ, and only between "reported" and
      // "no long-term variability".
      expect(noReason(bj), noReason(aj), reason: '$tag: batch and stream agree');
      final ba = batch.diagnostics.abstain, sa = stream.diagnostics.abstain;
      if (ba != sa) {
        expect({ba, sa}, {null, IrregularAbstain.noLongTermVariability},
            reason: '$tag: the only reason change allowed at a zero SD2');
      }
    } else {
      expect(bj, aj, reason: '$tag: batch and stream agree');
    }
  }
}

void main() {
  group('RC the corrector', () {
    _laws.law<_Case>(
      'L1 RrCorrector: any chunking, empty chunks and restores included, '
      'gives the checkpoint text, settled output and snapshot of one fold',
      _caseGen(3000),
      _l1Corrector,
      examples: _forced,
      cases: 60,
      reach: Reach<_Case>(_rrShares, _observeRr),
    );
    _laws.law<_Case>(
      'L1b RrCorrector: at the seams, settled ++ snapshot is correctRr of the '
      'prefix, bit for bit (frozen reference up to $_refCap beats)',
      _caseGen(1500),
      _l1bCorrector,
      examples: [for (final c in _forced) if (c.$1.$2 <= 450) c],
      cases: 8,
      reach: Reach<_Case>({
        for (final e in _rrShares.entries)
          if (!e.key.startsWith('flavour: ') &&
              !const {
            'beats: 1000 or more',
            'chunks: five or more',
            'beats: none',
            'beats: under 3 (the short branch)',
            'flavour: flagged',
            'beats: past the window (91 or more)',
          }.contains(e.key))
            e.key: e.value
      }, _observeRr),
    );
    _laws.law<_Case>(
      'L2 RrCorrector: write(read(b)) == b, the restored one reads the same '
      'and goes on identically',
      _caseGen(1500),
      _l2Corrector,
      examples: _forced,
      cases: 50,
      reach: Reach<_Case>(_rrShares, _observeRr),
    );
    _laws.law<(_Case, Mut)>(
      'L3 RrCorrector: a mutated checkpoint is refused whole or holds exactly '
      'what was written',
      G.pair(_caseGen(600), _mutGen),
      _l3Corrector,
      examples: [
        for (var i = 0; i < 11 * 4; i++)
          (_forced[const [3, 8, 13, 16, 20, 17, 11][i % 7] + (i % 3 == 0 ? 0 : 0)], (i % 11, i ~/ 11, 7 + i)),
        for (var k = 0; k < 11; k++) (_l3Base, (k, k, 0)),
        for (var a = 0; a < 10; a++) (_l3Base, (0, a, 0)),
        for (var a = 0; a < 5; a++) for (var b = 0; b < 4; b++) (_l3Base, (8, a, b)),
      ],
      cases: 200,
      reach: Reach<(_Case, Mut)>({
        for (var k = 0; k < 11; k++) 'kind: $k': .02,
        'a state with settled beats': .3,
        'an empty state': .008,
      }, (arg, bump) {
        bump('kind: ${arg.$2.$1 % 11}');
        final n = arg.$1.$1.$2;
        if (n >= 91) bump('a state with settled beats');
        if (n == 0) bump('an empty state');
      }),
    );
    _laws.law<_Case>(
      'L4 RrCorrector: an empty chunk is the identity and records nothing; a '
      'refused fold leaves the state unchanged; snapshot() reads only',
      _caseGen(800),
      _l4Corrector,
      examples: _forced,
      cases: 150,
      reach: Reach<_Case>(_rrShares, _observeRr),
    );
    _laws.law<_Case>(
      'L5 RrCorrector: beats are conserved (nn_in == rr_raw - dropped, normal + '
      'corrected + dropped == beats), classes cover every beat, times never run '
      'backwards',
      _caseGen(3000),
      _l5Corrector,
      examples: _forced,
      cases: 40,
      reach: Reach<_Case>(_rrShares, _observeRr),
    );
  });

  group('SC the screen state', () {
    final shares = _nnShares;
    _laws.law<_NnCase>(
      'L1 IrregularScreenState: any chunking, empty chunks and restores '
      'included, gives the checkpoint text and every evaluation of one fold',
      _nnCaseGen(3000),
      _scL1,
      examples: _nnForced,
      cases: 200,
      reach: Reach<_NnCase>(shares, _observeNn),
    );
    _laws.law<_NnCase>(
      'L1b IrregularScreenState: evaluate(tail) is the batch screen of settled '
      '++ tail; the window counts are an independent partition\'s',
      _nnCaseGen(1500),
      _scL1b,
      examples: [for (final c in _nnForced) if (c.$1.$2 <= 1500) c],
      cases: 150,
      reach: Reach<_NnCase>({
        for (final e in shares.entries)
          if (!const {'beats: 1500 or more', 'beats: 500 or more'}.contains(e.key))
            e.key: e.value
      }, _observeNn),
    );
    _laws.law<_NnCase>(
      'L2 IrregularScreenState: write(read(b)) == b, the restored one reads the '
      'same, keeps its own parameters and goes on identically',
      _nnCaseGen(1500),
      _scL2,
      examples: _nnForced,
      cases: 200,
      reach: Reach<_NnCase>(shares, _observeNn),
    );
    _laws.law<(_NnCase, Mut)>(
      'L3 IrregularScreenState: a version 1 or otherwise mutated checkpoint is '
      'refused whole or holds exactly what was written',
      G.pair(_nnCaseGen(600), _mutGen),
      _scL3,
      examples: [
        for (var k = 0; k < 11; k++)
          for (var a = 0; a < 3; a++) (_nnL3[a], (k, a + k, 3 * k + a)),
        for (var a = 0; a < 9; a++) (_nnL3[0], (0, a, 0)),
        // Every key but winStart removed in turn (prevT included: a version 3
        // checkpoint without it is refused, not read as an unknown time).
        for (var a = 0; a < 25; a++) (_nnL3[0], (2, a, 0)),
        (_nnL3[0], (9, 7, 0)), // prevT changed: held exactly
      ],
      cases: 200,
      reach: Reach<(_NnCase, Mut)>({
        for (var k = 0; k < 11; k++) 'kind: $k': .02,
        'a state with an open window': .3,
      }, (arg, bump) {
        bump('kind: ${arg.$2.$1 % 11}');
        if (arg.$1.$1.$2 >= 40) bump('a state with an open window');
      }),
    );
    _laws.law<_NnCase>(
      'L4 IrregularScreenState: an empty fold is the identity, evaluate never '
      'writes, a refused fold leaves the state unchanged',
      _nnCaseGen(800),
      _scL4,
      examples: _nnForced,
      cases: 200,
      reach: Reach<_NnCase>(shares, _observeNn),
    );
    _laws.law<_NnCase>(
      'L5 IrregularScreenState: nn_in/nn_kept count the input, the windows '
      'cover the kept NN, flagged <= valid <= total, an invalid config has no '
      'windows and cannot flag',
      _nnCaseGen(3000),
      _scL5,
      examples: _nnForced,
      cases: 150,
      reach: Reach<_NnCase>(shares, _observeNn),
    );
    test('a kept beat a full window after the first closes the window (>=)', () {
      final e = _edgeSeries();
      // 62 beats: the 61st sits exactly 300000 ms after the first.
      final st = IrregularScreenState(minWindowBeats: 2)..fold(e.nn, e.t);
      final res = st.evaluateDetailed(const [], const [], minBeats: 1);
      expect(res.diagnostics.windows!.total, 2, reason: 'closed AT the edge');
      expect(res.diagnostics.windows!.openBeats, 2);
      final ref = _refWindows(e.nn, e.t, 0);
      expect(ref.total, 2);
      // One millisecond short of the edge: still one window.
      final t2 = [...e.t]..[60] -= 1;
      final st2 = IrregularScreenState(minWindowBeats: 2)..fold(e.nn, t2);
      expect(st2.evaluateDetailed(const [], const [], minBeats: 1).diagnostics.windows!.total, 2,
          reason: 'beat 62 is past the edge anyway');
      final t3 = [...e.t.sublist(0, 61)]..[60] -= 1;
      final st3 = IrregularScreenState(minWindowBeats: 2)..fold(e.nn.sublist(0, 61), t3);
      expect(st3.evaluateDetailed(const [], const [], minBeats: 1).diagnostics.windows!.total, 1,
          reason: 'one millisecond short of a full window: still open');
    });
  });

  group('IP the corrector and the screen together', () {
    _laws.law<_IpCase>(
      'L1b+L5 corrector -> screen: at the seams the diagnostics are the batch '
      'diagnostics over the corrected prefix, and the beats are conserved',
      _ipGen(1200),
      _ipBody,
      examples: [
        for (var i = 0; i < _forced.length; i++)
          if (_forced[i].$1.$2 <= 450 && i % 2 == 0) (_forced[i], const [0, 1, 2, 3, 4, 8, 5, 6, 7][i % 9], const [0, 1, 2, 3, 4, 5, 6, 7][i % 8]),
        // The flagged day under the default screen, and the same under each
        // window config, at 500 beats and over.
        (_c(2, 450, splits: 4, cutSeed: 31, restart: 127), 0, 1),
        (_c(2, 450, splits: 4, cutSeed: 32, restart: 127), 1, 1),
        (_c(2, 450, splits: 4, cutSeed: 33), 2, 1),
        (_c(2, 450, splits: 4, cutSeed: 34), 3, 1),
        (_c(2, 450, splits: 4, cutSeed: 35), 4, 1),
        (_c(2, 450, splits: 4, cutSeed: 36), 5, 1),
        (_c(2, 450, splits: 4, cutSeed: 37), 6, 1),
        (_c(2, 450, splits: 4, cutSeed: 38), 7, 1),
        (_c(2, 450, splits: 4, cutSeed: 39), 8, 1),
        (_c(2, 600, splits: 3, cutSeed: 40), 0, 0), // default minimum of 500
        (_c(0, 0), 0, 6), // no beats, nothing seen by the corrector
        (_c(0, 0, mode: 1), 1, 1),
      ],
      cases: 8,
      reach: Reach<_IpCase>({
        for (final e in _ipShares.entries)
          if (!e.key.startsWith('flavour: ') &&
              !const {
            'beats: 1000 or more',
            'chunks: five or more',
            'beats: none',
            'beats: under 3 (the short branch)',
            'flavour: flagged',
            'a long irregularly irregular day',
            'no timestamps',
            'config: invalid',
            'evaluation: 0',
            'evaluation: 1',
            'evaluation: 2',
            'evaluation: 3',
            'evaluation: 4',
            'evaluation: 5',
            'evaluation: 6',
            'evaluation: 7',
          }.contains(e.key))
            e.key: e.value
      }, _observeIp),
    );
  });

  group('W the diagnostics wire', () {
    final reach = Reach<_WireCase>({
      'abstained': .1,
      'ran': .05,
      'no cleaning counts': .1,
      'zero beats seen': .02,
      'windows present': .3,
      'windows absent (invalid config)': .05,
    }, (c, bump) {
      final ((f, n, _, _), cfg, ev, _) = c;
      bump(n >= math.min(_evals[ev].$1, 30) && n >= 1 ? 'ran' : 'abstained');
      if (_evals[ev].$4 == 0) bump('no cleaning counts');
      if (_evals[ev].$4 == 2) bump('zero beats seen');
      bump(_scCfgValid(cfg) ? 'windows present' : 'windows absent (invalid config)');
    });
    final forcedWire = <_WireCase>[
      ((0, 0, 1, 0), 0, 6, 4), // zero beats, corrector saw none, fraction 1.0
      ((0, 0, 1, 0), 0, 0, 4), // zero beats, counts say 3
      ((0, 0, 1, 0), 0, 2, 4), // zero beats, no counts at all
      ((1, 200, 1, 0), 0, 1, 1),
      ((1, 300, 2, 0), 2, 4, 0),
      ((2, 300, 3, 0), 1, 7, 2), // artifact fraction exactly at the maximum
      ((2, 300, 3, 0), 1, 3, 3), // and just over it
      ((3, 100, 1, 0), 0, 1, 0), // flat
      ((4, 100, 1, 0), 2, 1, 0), // two point
      ((0, 50, 1, 2), 4, 1, 0), // invalid window config
      ((0, 50, 1, 0), 0, 1, 0), // exactly the minimum windows
      ((5, 280, 1, 3), 3, 5, 1),
    ];
    _laws.law<_WireCase>(
      'W-L2 IrregularDiagnostics: write(read(b)) == b through JSON text, the '
      'restored evidence reads the same, the envelope keeps the old keys',
      _wireGen(),
      _wL2,
      examples: forcedWire,
      cases: 200,
      reach: reach,
    );
    _laws.law<(_WireCase, Mut)>(
      'W-L3 IrregularDiagnostics: another version, an unknown reason, a missing '
      'or malformed section is refused whole; changed numbers are held exactly',
      G.pair(_wireGen(), _mutGen),
      _wL3,
      examples: [
        for (var k = 0; k < 8; k++)
          for (var i = 0; i < 3; i++) (forcedWire[3 + i], (k, 5 * k + i, 2 * k + i)),
        for (var a = 0; a < 9; a++) (forcedWire[3], (0, a, 0)),
        for (var a = 0; a < 6; a++) (forcedWire[3], (1, a, 0)),
        for (var a = 0; a < 6; a++) (forcedWire[3], (6, a, 0)),
        for (var a = 0; a < 5; a++) (forcedWire[9], (5, a, 0)),
      ],
      cases: 200,
      reach: Reach<(_WireCase, Mut)>({
        for (var k = 0; k < 8; k++) 'kind: $k': .03,
      }, (arg, bump) => bump('kind: ${arg.$2.$1 % 8}')),
    );
    _laws.law<_WireCase>(
      'W-L5 diagnostics: cleaning counts are absent unless given, the artifact '
      'fraction is absent when the corrector saw no beats and kept otherwise; '
      'batch and stream agree (0fc5768)',
      _wireGen(),
      _wAbsent,
      examples: forcedWire,
      cases: 200,
      reach: reach,
    );
  });

  group('RC accepted-checkpoint continuation', () {
    test('a checkpoint the reader accepts with a nonzero first difference goes '
        'on from it: the second beat can be the recovery of the first', () {
      // A writer stores d[0] = 0, but the reader takes any finite difference.
      // Resumed from d[0] = -200, beat 1 (+200 against beat 0) is a recovery
      // from beat 0's jump, and is demoted to normal; with d[0] = 0 it is not.
      // (If the reader is ever hardened to refuse a nonzero d[0], this becomes
      // the refusal test.)
      List<BeatClass> classesAfter(double d0) {
        final c = RrCorrector(windowBeats: 1, maxArtifactRun: null)..fold([600]);
        final j = (jsonDecode(jsonEncode(c.toJson())) as Map).cast<String, dynamic>();
        (j['d'] as List)[0] = d0;
        return RrCorrector.fromJson(j).fold([800, 800]).classes;
      }

      expect(classesAfter(-200.0),
          [BeatClass.ectopic, BeatClass.normal, BeatClass.normal]);
      expect(classesAfter(0.0), isNot(classesAfter(-200.0)),
          reason: 'the stored difference is what decides it');
    });
  });

  group('the forced scenarios say what they claim', () {
    test('every abstention reason, every open-window label, a flag and the '
        'absent artifact fraction are met by hand-built series, and the stream '
        'agrees with the batch on each', () {
      // (nn, minBeats, artifact fraction, maxArtifact) -> the reason, known by hand.
      List<double> sinus(int n) => [for (var i = 0; i < n; i++) 800.0 + (i % 9) * 13];
      List<double> af(int n) =>
          [for (var i = 0; i < n; i++) (i % 2 == 0 ? 450.0 : 1100.0) + (i % 5) * 7];
      // A [holeEvery] > 0 puts a 10 s dropout before every holeEvery-th beat.
      List<double> times(List<double> nn, int holeEvery) {
        var t = 0.0;
        var i = 0;
        return [
          for (final v in nn)
            t += (v >= 300 && v <= 2000 ? v : 800) +
                (holeEvery > 0 && i++ % holeEvery == holeEvery - 1 ? 10000 : 0)
        ];
      }

      final cases = <(String, List<double>, int, double, IrregularAbstain?, int)>[
        ('too few beats', sinus(30), 40, 0.0, IrregularAbstain.tooFewBeats, 0),
        // 60 beats, but a dropout before every second one leaves 29 pairs:
        // the gate counts successive pairs (39 needed), not beats.
        ('enough beats, too few successive pairs', sinus(60), 40, 0.0,
            IrregularAbstain.tooFewBeats, 2),
        // Zero pairs clear a gate of minBeats - 1 = 0, and then there is no
        // difference to build the Poincare plot from.
        ('nothing at all', const [], 1, 0.0, IrregularAbstain.noSuccessivePairs, 0),
        ('too noisy', sinus(60), 40, .31, IrregularAbstain.artifact, 0),
        ('exactly at the artifact maximum', sinus(60), 40, .30, null, 0),
        ('exactly the minimum beats', sinus(40), 40, 0.0, null, 0),
        // Two kept beats that are not neighbours: no difference exists.
        ('no successive pair', const [800, 5000, 810], 1, 0.0,
            IrregularAbstain.noSuccessivePairs, 0),
        // Two kept neighbours with a dropout between them: not successive.
        ('no successive pair across a time hole', const [800, 810], 1, 0.0,
            IrregularAbstain.noSuccessivePairs, 1),
        ('no long-term variability', List<double>.filled(60, 800), 40, 0.0,
            IrregularAbstain.noLongTermVariability, 0),
        ('irregularly irregular', af(200), 40, 0.0, null, 0),
      ];
      final opens = <IrregularOpenWindow>{};
      var flagged = false;
      for (final (name, nn, minBeats, fraction, reason, holeEvery) in cases) {
        final t = times(nn, holeEvery);
        final batch = irregularBeatScreenDetailed(nn,
            nnTimesMs: t, minBeats: minBeats, artifactFraction: fraction);
        final st = IrregularScreenState()..fold(nn, t);
        final stream = st.evaluateDetailed(const [], const [],
            minBeats: minBeats, artifactFraction: fraction);
        expect(batch.diagnostics.abstain, reason, reason: '$name: batch');
        _sameScreen(stream, batch, name);
        final w = batch.diagnostics.windows;
        if (w != null) opens.add(w.open);
        if (batch.metric.present && batch.metric.value!.flag) flagged = true;
      }
      expect(flagged, isTrue, reason: 'a flagged day');
      expect(opens, {
        IrregularOpenWindow.none,
        IrregularOpenWindow.thin,
        IrregularOpenWindow.unflagged,
        IrregularOpenWindow.flagged,
      }, reason: 'every open-window label');
    });

    test('the forced corrector days are thin, flat, artefact-heavy, boundary, '
        'timestamp-free and past one window', () {
      bool any(bool Function(_Case c, _Series s) f) => _forced.any((c) =>
          f(c, _series(c.$1.$1, c.$1.$2, c.$1.$3)));
      for (final n in [0, 1, 2, 3, 44, 46, 90, 91, 92]) {
        expect(any((c, s) => s.n == n), isTrue, reason: '$n beats');
      }
      expect(any((c, s) => c.$1.$4 == 1), isTrue, reason: 'no timestamps');
      for (var cfg = 0; cfg < _corrCfgs.length; cfg++) {
        expect(any((c, s) => c.$2.$4 == cfg), isTrue, reason: 'config $cfg');
      }
      // Flat: QD = 0, everything ties. Outliers at the first and last beat.
      expect(any((c, s) => _flavours[c.$1.$1] == 'flat' && s.rr.toSet().length == 1),
          isTrue);
      expect(
          any((c, s) =>
              _flavours[c.$1.$1] == 'outliers' &&
              s.n >= 3 &&
              s.rr.first == 1300 &&
              s.rr.last == 1300),
          isTrue);
      // A run of artefacts longer than the window: dropped, never corrected.
      expect(
          any((c, s) =>
              _flavours[c.$1.$1] == 'artefact heavy' &&
              correctRr(s.rr, rrTsMs: s.ts).droppedCount >= 20),
          isTrue,
          reason: 'artefacts that are dropped, not corrected (a run of 120 garbage beats is longer than the corrector window)');
      // A beat time that steps back, a dropout.
      expect(
          any((c, s) {
            if (_flavours[c.$1.$1] != 'backwards') return false;
            for (var i = 1; i < s.n; i++) {
              if (s.ts[i] < s.ts[i - 1]) return true;
            }
            return false;
          }),
          isTrue,
          reason: 'beat times that step backwards');
      expect(
          any((c, s) {
            if (_flavours[c.$1.$1] != 'gappy') return false;
            for (var i = 1; i < s.n; i++) {
              if (s.ts[i] - s.ts[i - 1] > 5000) return true;
            }
            return false;
          }),
          isTrue,
          reason: 'a dropout');
    });

    test('the forced integrated days reach a flag, a thin open window, a valid '
        'one and the abstentions', () {
      final reasons = <IrregularAbstain?>{};
      final opens = <IrregularOpenWindow>{};
      var flagged = false, noBeatsAbsent = false;
      for (final c in _nnForced) {
        final ((f, n, seed, salt), (cfg, _, _, ev)) = c;
        final s = _nnSeries(f, n, seed, salt);
        final res = _evaluate(_newState(cfg)..fold(s.nn, s.t), ev, beats: n);
        reasons.add(res.diagnostics.abstain);
        final w = res.diagnostics.windows;
        if (w != null) opens.add(w.open);
        if (res.metric.present && res.metric.value!.flag) flagged = true;
        if (n == 0 && _evals[ev].$4 == 2 && res.diagnostics.artifactFraction == null) {
          noBeatsAbsent = true;
        }
      }
      expect(reasons, containsAll([
        null,
        IrregularAbstain.tooFewBeats,
        IrregularAbstain.artifact,
        IrregularAbstain.noLongTermVariability,
      ]));
      expect(opens, containsAll([
        IrregularOpenWindow.none,
        IrregularOpenWindow.thin,
        IrregularOpenWindow.unflagged,
      ]));
      expect(flagged, isTrue, reason: 'a flagged screen among the forced days');
      expect(noBeatsAbsent, isTrue, reason: 'zero beats: the fraction is absent');
    });
  });

  group('FINDINGS (skipped: suspected gaps against the documented contract)', () {
    test('IrregularScreenState.fromJson bounds differences and closed windows', () {
      final nn = [for (var i = 0; i < 300; i++) 800.0 + (i % 7) * 11];
      final t = [for (var i = 0; i < 300; i++) 10000.0 + i * 1000];
      final st = IrregularScreenState()..fold(nn, t);
      Map<String, dynamic> fresh() =>
          (jsonDecode(jsonEncode(st.toJson())) as Map).cast<String, dynamic>();
      final good = fresh();
      expect((good['bk'] as List).length, 300);
      expect(IrregularScreenState.fromJson(good).toJson(), good);

      for (final (field, value) in [('dN', 300), ('total', 1)]) {
        final bad = fresh()..[field] = value;
        expect(() => IrregularScreenState.fromJson(bad), throwsFormatException,
            reason: '$field: $value');
      }
    });

    test('IrregularScreenState.fromJson refuses a checkpoint whose parts '
        'contradict each other', () {
      final nn = [for (var i = 0; i < 300; i++) 800.0 + (i % 7) * 11];
      final t = [for (var i = 0; i < 300; i++) 10000.0 + i * 1000];
      final st = IrregularScreenState()..fold(nn, t);
      Map<String, dynamic> fresh() =>
          (jsonDecode(jsonEncode(st.toJson())) as Map).cast<String, dynamic>();
      final bad = <String, void Function(Map<String, dynamic>)>{
        'levels seen != kept beats': (j) => j['lN'] = 5,
        'more differences than beats': (j) => j['dN'] = 1 << 40,
        'more windows than beats': (j) => j['total'] = 1 << 40,
        'a neighbour flag that is not 0 / 1': (j) => (j['bkAdj'] as List)[0] = 2,
        'a negative neighbour flag': (j) => (j['bkAdj'] as List)[0] = -1,
        'an open window without a start': (j) => j['winStart'] = null,
      };
      for (final e in bad.entries) {
        final j = fresh();
        e.value(j);
        expect(() => IrregularScreenState.fromJson(j), throwsFormatException,
            reason: e.key);
      }
    });

    test('RrCorrector.fromJson bounds counters by their pipeline stages', () {
      final short = RrCorrector(maxArtifactRun: null)..fold([800.0, 800.0, 800.0]);
      Map<String, dynamic> shortJson() =>
          (jsonDecode(jsonEncode(short.toJson())) as Map).cast<String, dynamic>();
      final shortCheckpoint = shortJson();
      expect(shortCheckpoint['n'], 3);
      expect(shortCheckpoint['c2'], 0);
      expect(shortCheckpoint['ce'], 0);
      expect(RrCorrector.fromJson(shortCheckpoint).toJson(), shortCheckpoint);
      for (final (field, value) in [
        ('normalFinal', 1),
        ('dropped', 1),
        ('corrected', 1),
      ]) {
        final bad = shortJson()..[field] = value;
        expect(() => RrCorrector.fromJson(bad), throwsFormatException,
            reason: '$field: $value');
      }

      final long = RrCorrector(maxArtifactRun: null)..fold([for (var i = 0; i < 300; i++) 800.0]);
      final longCheckpoint =
          (jsonDecode(jsonEncode(long.toJson())) as Map).cast<String, dynamic>();
      final c2 = longCheckpoint['c2'] as int;
      final ce = longCheckpoint['ce'] as int;
      expect(c2, greaterThan(0));
      expect(ce, greaterThan(0));
      expect(longCheckpoint['off'], greaterThan(0));
      expect(RrCorrector.fromJson(longCheckpoint).toJson(), longCheckpoint);
      final tooManyOutcomes = {
        ...longCheckpoint,
        'dropped': ce,
        'corrected': 1,
      };
      expect(() => RrCorrector.fromJson(tooManyOutcomes), throwsFormatException,
          reason: 'dropped + corrected exceeds ce');
    });

    test('RrCorrector.fromJson refuses a checkpoint whose counters are '
        'impossible', () {
      final c = RrCorrector(maxArtifactRun: null)
        ..fold([for (var i = 0; i < 300; i++) 800.0 + (i % 7) * 11],
            tsMs: [for (var i = 0; i < 300; i++) 1.76e12 + i * 1000]);
      Map<String, dynamic> fresh() =>
          (jsonDecode(jsonEncode(c.toJson())) as Map).cast<String, dynamic>();
      final bad = <String, void Function(Map<String, dynamic>)>{
        'beats folded but timestamp mode unknown': (j) => j['wall'] = null,
        'negative dropped count': (j) => j['dropped'] = -5,
        'more dropped than beats': (j) => j['dropped'] = 1 << 40,
        'negative corrected count': (j) => j['corrected'] = -1,
        'more normal beats than classified': (j) => j['normalFinal'] = 1 << 40,
      };
      for (final e in bad.entries) {
        final j = fresh();
        e.value(j);
        expect(() => RrCorrector.fromJson(j), throwsFormatException, reason: e.key);
      }
      expect(() => RrCorrector.fromJson({...fresh(), 'alpha': -1.0}), returnsNormally);
    });
  });

  _laws.registerReachTest();
}
