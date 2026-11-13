// Pieces the fold-law files share (design 05, pilot cluster C2A): chunk
// boundaries, the mutation outcome vocabulary, and fixed-length int-vector
// generators (a recipe is a handful of ints, so a failing input shrinks to a
// few readable numbers instead of thousands of doubles).

import 'dart:convert';
import 'dart:math' as math;

import 'package:test/test.dart';

import 'property.dart';

/// Chunk boundaries `[0, ...cuts, n]`. Cuts may repeat or sit on 0 / n, which
/// makes empty chunks; half of them are placed on [special] positions (the
/// edges of a module's windows), the rest uniformly.
List<int> foldBounds(int n, int splits, int cutSeed,
    {List<int> special = const [0, 1, 2, 3]}) {
  final r = Rng(cutSeed + 17);
  final cuts = <int>[];
  for (var k = 0; k < splits; k++) {
    final v = r.nextBool(.5)
        ? (r.nextBool(.2) ? n - 1 + r.nextInt(2) : special[r.nextInt(special.length)])
        : r.intIn(0, n);
    cuts.add(v.clamp(0, n));
  }
  cuts.sort();
  return [0, ...cuts, n];
}

bool hasEmptyChunk(List<int> b) {
  for (var k = 0; k + 1 < b.length; k++) {
    if (b[k + 1] == b[k]) return true;
  }
  return false;
}

/// The seams a law checks against an expensive reference or batch parity check: first, middle, last.
Set<int> pickSeams(int seams) =>
    {0, seams ~/ 2, seams - 1}..removeWhere((k) => k < 0);

/// What a mutated checkpoint is allowed to do.
enum Must {
  /// Refused with a FormatException, nothing else.
  refuse,

  /// Refused, or accepted holding exactly what was written.
  faithful,

  /// Refused, or accepted as the ORIGINAL (the change is ignored).
  ignored,
}

/// (kind, a, b): which mutation, and two parameters.
typedef Mut = (int, int, int);

Object? deepCopy(Object? o) => jsonDecode(jsonEncode(o));

/// Checks one outcome of reading a mutated checkpoint: [outcome] is `refused`,
/// `accepted:<text of what was read>` or `WRONG ERROR TYPE...`.
void expectMutationOutcome(String outcome, Must must, String faithfulText,
    String originalText, String tag) {
  expect(outcome, isNot(startsWith('WRONG')), reason: '$tag: only FormatException');
  switch (must) {
    case Must.refuse:
      expect(outcome, 'refused', reason: '$tag: refused whole');
    case Must.faithful:
      if (outcome != 'refused') {
        expect(outcome, 'accepted:$faithfulText',
            reason: '$tag: accepted means exactly what was written');
      }
    case Must.ignored:
      if (outcome != 'refused') {
        expect(outcome, 'accepted:$originalText',
            reason: '$tag: an unknown key is ignored, nothing else moves');
      }
  }
}

class MutKindGen extends Gen<int> {
  MutKindGen(this.kinds);
  final int kinds;
  @override
  int generate(Rng r, int size) => r.nextInt(kinds);
  @override
  Iterable<int> shrink(int v) => G.intIn(0, kinds - 1).shrink(v);
}

Gen<Mut> mutGen(int kinds) =>
    G.triple(MutKindGen(kinds), G.intIn(0, 1 << 20), G.intIn(0, 1 << 20));

/// A size: the interesting small values first, then growing with the case
/// index up to [maxN] (cost: a property has two seconds).
class SizeGen extends Gen<int> {
  SizeGen(this.maxN, {this.pool = const [0, 1, 2, 3, 4, 5, 10]});
  final int maxN;
  final List<int> pool;
  @override
  int generate(Rng r, int size) {
    final p = r.nextDouble();
    if (p < .04) return 0;
    if (p < .29) {
      final ok = [for (final x in pool) if (x <= maxN) x];
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

/// A fixed-length vector of ints, each slot with its own generator, each
/// shrunk on its own.
class IntsGen extends Gen<List<int>> {
  IntsGen(this.slots);
  final List<Gen<int>> slots;
  @override
  List<int> generate(Rng r, int size) => [for (final g in slots) g.generate(r, size)];
  @override
  Iterable<List<int>> shrink(List<int> v) sync* {
    for (var i = 0; i < slots.length; i++) {
      for (final c in slots[i].shrink(v[i])) {
        yield [...v.sublist(0, i), c, ...v.sublist(i + 1)];
      }
    }
  }

  @override
  String show(List<int> v) => '$v';
}
