// Round 10: persistent aggregator states and versioned checkpoints.
//
// SHAPE DECISIONS (the spec left these open; the implementation follows them):
//
//  * Non-finite doubles are encoded as the strings 'NaN', 'Infinity' and
//    '-Infinity' (the same strings incremental_core.dart's _readDouble already
//    accepts). Finite doubles stay JSON numbers; -0.0 stays -0.0. Decoders
//    accept an int where a double is expected. A decoder rejects any other
//    string, bool, null, list or map in a double slot.
//  * Every map-shaped encoding writes every key it has, with null for an
//    absent value, and the decoder REQUIRES every key (a missing key is a
//    FormatException, not a default). Decoders throw FormatException (never
//    TypeError / RangeError / StateError) for any malformed input.
//  * ListBatch element codec: `RowCodec<A>(Object? Function(A) encode,
//    A Function(Object?) decode)` plus the named constructor
//    `ListBatch<A>.coded(List<A> rows, RowCodec<A> codec)`. A coded batch
//    keeps its codec through copyRange/join; `toJson()` is the JSON list of
//    encoded rows. `RowCodec<A>.batchFromJson(Object?)` returns a coded
//    ListBatch<A> (FormatException if the input is not a list; the row decode
//    function itself must throw FormatException on a bad row). A plain
//    `ListBatch(rows).toJson()` throws UnsupportedError.
//  * Every persistable batch type X (DoubleColumn, Beats, TimedValues,
//    HrStream, Epochs, EpochSeries) has `Object? toJson()` and a
//    `factory X.fromJson(Object? json)` (FormatException on malformed input).
//    The JSON must survive jsonEncode (so NaN/inf use the string encoding).
//  * First / Last / Lookback / Prefix take an optional NAMED parameter
//    `batchFromJson` (`B Function(Object?)`): First({batchFromJson}),
//    Last({batchFromJson}), Lookback(k, inner, {batchFromJson}),
//    Prefix(k, head, tail, {batchFromJson}). Persistable only when given
//    (and, for Lookback/Prefix, when the stored inner/tail is persistable;
//    Prefix keeps no head state, so the head does not matter).
//    Without batchFromJson, encodeState/decodeState throw UnsupportedError.
//  * GroupBy encodes a JSON map with the int keys as decimal strings; a key
//    that is not a decimal int is a FormatException.
//  * `both(a, b)` encodes its state as the two-element list [first, second];
//    any other length or type is a FormatException.
//  * Moments.encodeState is exactly RunningMoments.toJson (a map), and
//    Moments.decodeState is RunningMoments.fromJson behind a FormatException
//    guard.
//  * Aggregator defaults: persistable false; encodeState/decodeState throw
//    UnsupportedError; Batch.toJson throws UnsupportedError.
//  * The checkpoint envelope lives in lib/src/aggregate/checkpoint.dart and is
//    exported from package:openstrap_analytics/aggregate.dart.
//    encodeCheckpoint on a non-persistable aggregator throws UnsupportedError.

import 'dart:convert';
import 'dart:typed_data';

import 'package:openstrap_analytics/aggregate.dart';
import 'package:openstrap_analytics/onehz.dart' show RunningMoments;
import 'package:test/test.dart';

import '../support/aggregator_laws.dart';
import '../support/property.dart' show Rng;

const nan = double.nan;
const inf = double.infinity;

Object? wire(Object? x) => jsonDecode(jsonEncode(x));

bool close(double a, double b) =>
    a == b ||
    (a.isNaN && b.isNaN) ||
    (a - b).abs() <= 1e-9 * [1.0, a.abs(), b.abs()].reduce((x, y) => x > y ? x : y);

bool closeOpt(double? a, double? b) =>
    a == null || b == null ? a == b : close(a, b);

int bits(double x) => (ByteData(8)..setFloat64(0, x)).getInt64(0);

bool sameCol(DoubleColumn? a, DoubleColumn? b) {
  if (a == null || b == null) return a == b;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (!close(a.values[i], b.values[i])) return false;
  }
  return true;
}

/// Mixed columns: specials, NaN, infinities, signed zero, large and tiny.
List<DoubleColumn> allCases({bool finiteOnly = false, bool moderate = false}) {
  final r = Rng(0x10A);
  final specials = finiteOnly
      ? [-0.0, 0.0, 5e-324, 0.1 + 0.2, -123456.789]
      : moderate
          ? [-0.0, 0.0, 5e-324, 0.1 + 0.2, -123456.789]
          : [-0.0, 0.0, 5e-324, 0.1 + 0.2, 1.7976931348623157e308, -inf, inf];
  double draw() => r.nextBool(.2)
      ? specials[r.intIn(0, specials.length - 1)]
      : (r.nextDouble() - .5) * 2000;
  return [
    col([]),
    col([1]),
    col([-0.0]),
    if (!finiteOnly) col([nan, nan]),
    for (var i = 0; i < 24; i++)
      col([
        for (var n = r.intIn(0, 30); n > 0; n--)
          !finiteOnly && r.nextBool(.12) ? nan : draw()
      ]),
  ];
}

/// For every split: decode(wire(encode(fold [0,k)))) continued by combine and
/// by addSlice must agree with the one-pass result, as must the full state.
void expectResumes<S, B extends Batch<B>, R>(
    Aggregator<S, B, R> agg, List<B> cases, bool Function(R, R) eq) {
  expect(agg.persistable, isTrue);
  S rt(S s) => agg.decodeState(wire(agg.encodeState(s)));
  for (var c = 0; c < cases.length; c++) {
    final b = cases[c];
    final n = b.length;
    final want = agg.run(b);
    expect(eq(agg.finish(rt(agg.fold(b))), want), isTrue,
        reason: 'full state, case $c');
    expect(eq(agg.finish(rt(agg.empty())), agg.finish(agg.empty())), isTrue,
        reason: 'empty state');
    for (var k = 0; k <= n; k++) {
      final viaCombine =
          agg.finish(agg.combine(rt(agg.fold(b, 0, k)), agg.fold(b, k, n)));
      expect(eq(viaCombine, want), isTrue, reason: 'combine, case $c split $k');
      final viaAdd = agg.finish(agg.addSlice(rt(agg.fold(b, 0, k)), b, k, n));
      expect(eq(viaAdd, want), isTrue, reason: 'addSlice, case $c split $k');
      final viaLeft =
          agg.finish(agg.combine(agg.fold(b, 0, k), rt(agg.fold(b, k, n))));
      expect(eq(viaLeft, want), isTrue, reason: 'right restored, case $c split $k');
    }
  }
}

/// Variants of a JSON value with one thing broken. Lists keep their length
/// (shorter lists are legitimate for variable-length encodings).
Iterable<Object?> mutants(Object? node, {bool removeKeys = true}) sync* {
  const repls = <Object?>['zzz', true, {'bogus': 1}];
  if (node is Map) {
    for (final key in node.keys) {
      if (removeKeys) yield {...node}..remove(key);
      for (final r in repls) {
        yield {...node, key: r};
      }
      for (final v in mutants(node[key], removeKeys: removeKeys)) {
        yield {...node, key: v};
      }
    }
  } else if (node is List) {
    for (var i = 0; i < node.length; i++) {
      for (final r in repls) {
        yield [...node]..[i] = r;
      }
      for (final v in mutants(node[i], removeKeys: removeKeys)) {
        yield [...node]..[i] = v;
      }
    }
  }
}

void expectMalformed<S, B extends Batch<B>, R>(
    Aggregator<S, B, R> agg, Iterable<Object?> payloads) {
  var n = 0;
  for (final p in payloads) {
    n++;
    expect(() => agg.decodeState(p), throwsFormatException,
        reason: 'payload ${jsonEncode(p)}');
  }
  expect(n, greaterThan(0));
}

/// Mutants of a real mid-stream encoding plus generic junk.
void expectRejectsDamage<S, B extends Batch<B>, R>(
    Aggregator<S, B, R> agg, B batch,
    {bool removeKeys = true, List<Object?> junk = const []}) {
  final valid = wire(agg.encodeState(agg.fold(batch, 0, batch.length ~/ 2)));
  expectMalformed(
      agg, [...mutants(valid, removeKeys: removeKeys), null, 'zzz', true, ...junk]);
}

Float64List _values(DoubleColumn b) => b.values;
Float64List _rowsAsDoubles(ListBatch<int> b) =>
    Float64List.fromList([for (final r in b.rows) r.toDouble()]);

/// Test-defined persistable aggregator: for each length-k window, adds the
/// first element. State is a plain finite double.
class _WindowFirst extends Aggregator<double, DoubleColumn, double> {
  const _WindowFirst(this.k);
  final int k;
  @override
  double empty() => 0;
  @override
  double addSlice(double s, DoubleColumn b, int start, int end) {
    for (var i = start + k - 1; i < end; i++) {
      s += b.values[i - k + 1];
    }
    return s;
  }

  @override
  double combine(double l, double r) => l + r;
  @override
  double finish(double s) => s;
  @override
  bool get persistable => true;
  @override
  Object? encodeState(double s) => s;
  @override
  double decodeState(Object? json) {
    if (json is! num) throw const FormatException('number expected');
    return json.toDouble();
  }
}

/// No persistence at all.
class _Plain extends Aggregator<int, DoubleColumn, int> {
  const _Plain();
  @override
  int empty() => 0;
  @override
  int addSlice(int s, DoubleColumn b, int start, int end) => s + end - start;
  @override
  int combine(int l, int r) => l + r;
  @override
  int finish(int s) => s;
}

typedef _IB = ListBatch<int>;

final _intCodec = RowCodec<int>((v) => v, (o) {
  if (o is! int) throw const FormatException('int expected');
  return o;
});

_IB _ib(List<int> rows) => ListBatch<int>.coded(rows, _intCodec);

/// Sums rows and counts them; finish mixes both, so losing either shows.
/// With [dropCount] the codec silently forgets the count.
class _SumCount extends Aggregator<List<int>, _IB, int> {
  const _SumCount({this.dropCount = false, this.persists = true});
  final bool dropCount;
  final bool persists;
  @override
  List<int> empty() => [0, 0];
  @override
  List<int> addSlice(List<int> s, _IB b, int start, int end) {
    for (var i = start; i < end; i++) {
      s[0] += b.rows[i];
    }
    s[1] += end - start;
    return s;
  }

  @override
  List<int> combine(List<int> l, List<int> r) =>
      [l[0] + r[0], l[1] + r[1]];
  @override
  int finish(List<int> s) => s[0] * 1000 + s[1];
  @override
  bool get persistable => persists;
  @override
  Object? encodeState(List<int> s) => dropCount ? [s[0]] : [s[0], s[1]];
  @override
  List<int> decodeState(Object? json) {
    if (json is! List || json.isEmpty || json.first is! int) {
      throw const FormatException('bad');
    }
    return [json.first as int, dropCount ? 0 : json[1] as int];
  }
}

void main() {
  group('non-persistable defaults', () {
    test('an aggregator that overrides nothing is not persistable', () {
      const a = _Plain();
      expect(a.persistable, isFalse);
      expect(() => a.encodeState(0), throwsUnsupportedError);
      expect(() => a.decodeState(0), throwsUnsupportedError);
    });
    test('plain ListBatch and Batch.toJson throw UnsupportedError', () {
      expect(() => ListBatch<int>([1, 2]).toJson(), throwsUnsupportedError);
    });
  });

  group('persistable flags', () {
    final sum = Sum<DoubleColumn>(_values);
    test('every primitive block is persistable', () {
      expect(const Count<DoubleColumn>().persistable, isTrue);
      expect(CountFinite<DoubleColumn>(_values).persistable, isTrue);
      expect(CountWhere<DoubleColumn>(_values, (v) => v > 0).persistable, isTrue);
      expect(sum.persistable, isTrue);
      expect(SumOf<DoubleColumn>(_values, (v) => v * 2).persistable, isTrue);
      expect(SumSq<DoubleColumn>(_values).persistable, isTrue);
      expect(Min<DoubleColumn>(_values).persistable, isTrue);
      expect(Max<DoubleColumn>(_values).persistable, isTrue);
      expect(Moments<DoubleColumn>(_values).persistable, isTrue);
      expect(Ewma<DoubleColumn>(_values, .3).persistable, isTrue);
    });
    test('First/Last/Lookback/Prefix are persistable only with batchFromJson',
        () {
      expect(First<DoubleColumn>().persistable, isFalse);
      expect(Last<DoubleColumn>().persistable, isFalse);
      expect(
          First<DoubleColumn>(batchFromJson: DoubleColumn.fromJson).persistable,
          isTrue);
      expect(
          Last<DoubleColumn>(batchFromJson: DoubleColumn.fromJson).persistable,
          isTrue);
      expect(Lookback<DoubleColumn, double, double>(3, const _WindowFirst(3))
          .persistable, isFalse);
      expect(
          Lookback<DoubleColumn, double, double>(3, const _WindowFirst(3),
                  batchFromJson: DoubleColumn.fromJson)
              .persistable,
          isTrue);
      expect(
          Prefix<DoubleColumn, int, int, double, double>(
                  2, const Count<DoubleColumn>(), const _WindowFirst(1))
              .persistable,
          isFalse);
      expect(
          Prefix<DoubleColumn, int, int, double, double>(
                  2, const Count<DoubleColumn>(), _WindowFirst(1),
                  batchFromJson: DoubleColumn.fromJson)
              .persistable,
          isTrue);
      expect(() => First<DoubleColumn>().encodeState(First<DoubleColumn>().empty()),
          throwsUnsupportedError);
    });
    test('a composite with a non-persistable child is not persistable', () {
      const plain = _Plain();
      expect(both(sum, plain).persistable, isFalse);
      expect(both(plain, sum).persistable, isFalse);
      expect(both(sum, Count<DoubleColumn>()).persistable, isTrue);
      expect(plain.map((r) => r).persistable, isFalse);
      expect(sum.map((r) => r).persistable, isTrue);
      expect(GroupBy<DoubleColumn, int, int>((b, i) => 0, plain).persistable,
          isFalse);
      expect(
          GroupBy<DoubleColumn, int, int>((b, i) => 0, const Count()).persistable,
          isTrue);
      expect(
          Lookback<DoubleColumn, int, int>(2, plain,
                  batchFromJson: DoubleColumn.fromJson)
              .persistable,
          isFalse);
      expect(
          Prefix<DoubleColumn, int, int, int, int>(2, plain, plain,
                  batchFromJson: DoubleColumn.fromJson)
              .persistable,
          isFalse);
      expect(() => both(sum, plain).encodeState(both(sum, plain).empty()),
          throwsUnsupportedError);
    });
  });

  group('double encoding', () {
    final agg = SumSq<DoubleColumn>(_values);
    test('non-finite doubles are the documented strings', () {
      expect(agg.encodeState(nan), 'NaN');
      expect(agg.encodeState(inf), 'Infinity');
      expect(agg.encodeState(-inf), '-Infinity');
      expect(agg.decodeState('NaN'), isNaN);
      expect(agg.decodeState('Infinity'), inf);
      expect(agg.decodeState('-Infinity'), -inf);
    });
    test('finite doubles round-trip bit-exactly through JSON text', () {
      final r = Rng(7);
      final xs = <double>[
        0.0, -0.0, 5e-324, -5e-324, 2.2250738585072014e-308,
        1.7976931348623157e308, -1.7976931348623157e308, 0.1 + 0.2, 1 / 3,
        9007199254740993.0, 123456789.123456789,
        for (var i = 0; i < 200; i++)
          (r.nextDouble() - .5) * (i.isEven ? 1e-300 : 1e300),
      ];
      for (final x in xs) {
        final back = agg.decodeState(wire(agg.encodeState(x)));
        expect(bits(back), bits(x), reason: '$x');
      }
      expect(agg.decodeState(wire(agg.encodeState(-0.0))).isNegative, isTrue);
    });
    test('NaN and infinities survive jsonEncode (no JsonUnsupportedObjectError)',
        () {
      for (final x in [nan, inf, -inf]) {
        final text = jsonEncode(agg.encodeState(x));
        final back = agg.decodeState(jsonDecode(text));
        expect(bits(back) == bits(x) || (x.isNaN && back.isNaN), isTrue);
      }
    });
    test('an int is accepted where a double is expected', () {
      final v = agg.decodeState(3);
      expect(v, 3.0);
      expect(v, isA<double>());
      expect(agg.decodeState(0), 0.0);
    });
    test('malformed doubles', () {
      expectMalformed(agg, [
        null, 'zzz', 'nan', 'inf', 'Infinit', '', '1.5', true, false, [], [1],
        {}, {'v': 1}
      ]);
    });
    test('Min / Max state is a nullable double', () {
      final mn = Min<DoubleColumn>(_values);
      final mx = Max<DoubleColumn>(_values);
      expect(mn.encodeState(null), isNull);
      expect(mn.decodeState(null), isNull);
      expect(mx.decodeState(null), isNull);
      expect(mn.encodeState(-inf), '-Infinity');
      expect(mx.encodeState(inf), 'Infinity');
      expect(mn.decodeState(wire(mn.encodeState(-0.0)))!.isNegative, isTrue);
      expectMalformed(mn, ['zzz', true, [], {}, 'nan']);
      expectMalformed(mx, ['zzz', true, [], {}, 'nan']);
    });
  });

  group('counts', () {
    final cs = <Aggregator<int, DoubleColumn, int>>[
      const Count<DoubleColumn>(),
      CountFinite<DoubleColumn>(_values),
      CountWhere<DoubleColumn>(_values, (v) => v > 0),
    ];
    for (final (i, a) in cs.indexed) {
      test('block $i round-trips on every split', () {
        expectResumes(a, allCases(), (x, y) => x == y);
      });
      test('block $i large ints are exact', () {
        for (final big in [9007199254740993, 1 << 62, 9223372036854775807, 0]) {
          expect(a.decodeState(wire(a.encodeState(big))), big);
        }
      });
      test('block $i malformed', () {
        expectMalformed(a, [
          null, 'x', '5', 1.5, 2.0, -1, true, [], [1], {}, {'count': 1}, nan.toString()
        ]);
      });
    }
  });

  group('sums', () {
    final aggs = <String, Aggregator<dynamic, DoubleColumn, double>>{
      'Sum': Sum<DoubleColumn>(_values),
      'SumOf': SumOf<DoubleColumn>(_values, (v) => v * 2 - 1),
      'SumSq': SumSq<DoubleColumn>(_values),
    };
    aggs.forEach((name, a) {
      test('$name round-trips on every split (moderate finite values)', () {
        expectResumes(a, allCases(moderate: true), close);
      });
      test('$name keeps +/-inf, NaN-from-cancellation and signed zero', () {
        expectResumes(a, [
          col([1, inf, 2]),
          col([-inf, 4]),
          col([inf, -inf]),
          col([-0.0]),
          col([nan, 3, nan]),
        ], close);
      });
      test('$name empty state', () {
        expect(a.finish(a.decodeState(wire(a.encodeState(a.empty())))), 0.0);
      });
      test('$name malformed', () {
        expectMalformed(a, [null, 'zzz', true, [], {}, 'nan']);
      });
    });
    test('compensation survives the round trip', () {
      final a = Sum<DoubleColumn>(_values);
      final b = col([1e16, 1.0, -1e16, 1.0, 1e-3, 1e16, 1.0, -1e16]);
      final whole = a.run(b);
      final half = a.fold(b, 0, 4);
      final back = a.decodeState(wire(a.encodeState(half)));
      expect(a.finish(a.addSlice(back, b, 4, 8)), whole);
    });
    test('Sum and SumOf damaged mid-stream encodings are rejected', () {
      final b = col([1.5, 2.5, 1e-9, 4, 5]);
      expectRejectsDamage(Sum<DoubleColumn>(_values), b);
      expectRejectsDamage(SumOf<DoubleColumn>(_values, (v) => v), b);
    });
  });

  group('min / max', () {
    test('round trip on every split', () {
      expectResumes(Min<DoubleColumn>(_values), allCases(), closeOpt);
      expectResumes(Max<DoubleColumn>(_values), allCases(), closeOpt);
    });
    test('infinite extrema and empty', () {
      expectResumes(Min<DoubleColumn>(_values), [col([3, -inf, 1]), col([])], closeOpt);
      expectResumes(Max<DoubleColumn>(_values), [col([3, inf, 1]), col([nan])], closeOpt);
    });
  });

  group('moments', () {
    final a = Moments<DoubleColumn>(_values);
    bool eq(RunningMoments x, RunningMoments y) =>
        x.count == y.count &&
        closeOpt(x.mean, y.mean) &&
        closeOpt(x.sampleSd, y.sampleSd) &&
        closeOpt(x.populationSd, y.populationSd);
    test('round trip on every split', () {
      expectResumes(a, allCases(finiteOnly: true), eq);
    });
    test('the encoding is RunningMoments.toJson', () {
      final s = a.fold(col([1, 2, 4, 8]));
      expect(a.encodeState(s), s.toJson());
      expect(a.encodeState(a.empty()), RunningMoments().toJson());
    });
    group('reachable non-finite moments (finite input overflowing m2)', () {
      final over = col([1e155, -1e155]); // squared deviation overflows to inf
      test('the state reaches Infinity from finite input', () {
        expect(a.fold(over).populationSd, double.infinity);
      });
      test('review case: encodeState survives jsonEncode and decodes back', () {
        final state = a.fold(over);
        late final String text;
        expect(() => text = jsonEncode(a.encodeState(state)), returnsNormally);
        final back = a.decodeState(jsonDecode(text));
        expect(back.count, 2);
        expect(back.mean, state.mean);
        expect(back.sampleSd, double.infinity);
        expect(eq(a.finish(back), a.finish(state)), isTrue);
      });
      test('the non-finite m2 uses the shared string encoding', () {
        final json = wire(a.encodeState(a.fold(over))) as Map;
        expect(json['m2'], 'Infinity');
        expect(json['count'], 2);
      });
      // Split invariance once m2 has overflowed is out of domain (Welford's
      // merge of an infinite m2 is not defined to match the one-pass fold);
      // what must hold is that the reachable state round-trips, tested above.
      test('a non-finite m2 is accepted only in the encoded string form', () {
        final good = Map<String, Object?>.of(
            wire(a.encodeState(a.fold(over))) as Map<String, Object?>);
        expect(() => a.decodeState({...good, 'm2': 'Infinity'}),
            returnsNormally);
        for (final bad in [
          'NaN', '-Infinity', 'inf', 'infinity', null, true, [], {},
        ]) {
          expect(() => a.decodeState({...good, 'm2': bad}),
              throwsFormatException,
              reason: 'm2 ${jsonEncode(bad)}');
        }
      });
      test('count and invariants are still validated with an infinite m2', () {
        final good = Map<String, Object?>.of(
            wire(a.encodeState(a.fold(over))) as Map<String, Object?>);
        expectMalformed(a, [
          {...good, 'count': 1}, // one row cannot have spread
          {...good, 'count': 0}, // nor none
          {...good, 'count': -2},
          {...good, 'count': 1.5},
          {...good, 'origin': 'NaN'},
          {...good, 'origin': 'Infinity'},
          {...good, 'meanOffset': 'NaN'},
          {...good, 'version': 2},
        ]);
      });
    });

    test('malformed and inconsistent', () {
      final good = Map<String, Object?>.of(
          wire(a.encodeState(a.fold(col([1, 2, 4])))) as Map<String, Object?>);
      expectMalformed(a, [
        null, 'zzz', 3, true, [], {},
        ...mutants(good),
        {...good, 'count': -1},
        {...good, 'count': 1.5},
        {...good, 'version': 2},
        {...good, 'type': 'IntHistogram'},
        {...good, 'm2': -1.0},
        {...good, 'count': 0}, // origin/m2 non-zero with count 0
        {...good, 'count': 1}, // one row but m2 non-zero
        {...good, 'origin': 'NaN'},
      ]);
    });
  });

  group('first / last', () {
    final r = Rng(21);
    final cases = [
      col([]),
      col([nan]),
      col([-0.0, 1, 2]),
      col([inf, nan, -inf, 4]),
      for (var i = 0; i < 6; i++)
        col([for (var n = r.intIn(0, 9); n > 0; n--) r.nextDouble()]),
    ];
    test('DoubleColumn batches (state holds a one-row copy)', () {
      expectResumes(First<DoubleColumn>(batchFromJson: DoubleColumn.fromJson),
          cases, sameCol);
      expectResumes(Last<DoubleColumn>(batchFromJson: DoubleColumn.fromJson),
          cases, sameCol);
    });
    test('coded ListBatch<int> batches', () {
      bool eq(_IB? a, _IB? b) =>
          a == null || b == null ? a == b : a.rows.join(',') == b.rows.join(',');
      final cs = [_ib([]), _ib([7]), _ib([1, 2, 3, 4]), _ib([-5, 9])];
      expectResumes(First<_IB>(batchFromJson: _intCodec.batchFromJson), cs, eq);
      expectResumes(Last<_IB>(batchFromJson: _intCodec.batchFromJson), cs, eq);
    });
    test('malformed', () {
      final f = First<DoubleColumn>(batchFromJson: DoubleColumn.fromJson);
      final l = Last<DoubleColumn>(batchFromJson: DoubleColumn.fromJson);
      for (final a in [f, l]) {
        expectRejectsDamage(a, col([1, 2, 3, 4]));
        expectMalformed(a, [3, [], [1, 2], 'NaN']);
      }
    });
  });

  group('group by', () {
    _IB ints(List<int> r) => _ib(r);
    int key(_IB b, int i) => b.rows[i] ~/ 10;
    final counts = GroupBy<_IB, int, int>(key, const Count<_IB>());
    final sums = GroupBy<_IB, dynamic, double>(
        key, Sum<_IB>(_rowsAsDoubles));
    final cases = [
      ints([]),
      ints([5]),
      ints([1, 2, 11, 12, 13, 1, 2, -15, -16, 25]),
      ints([for (var i = 0; i < 60; i++) (i * 7919) % 97 - 30]),
      ints([1 << 40, 1 << 40, -(1 << 40), 3]),
    ];
    test('round trip on every split (Count and Sum inner)', () {
      expectResumes(counts, cases, (a, b) => a.toString() == b.toString());
      expectResumes(
          sums,
          cases,
          (a, b) =>
              a.length == b.length &&
              a.keys.every((k) => b.containsKey(k) && close(a[k]!, b[k]!)));
    });
    test('int keys are encoded as strings, huge and negative keys survive', () {
      final big = GroupBy<_IB, int, int>(
          (b, i) => b.rows[i], const Count<_IB>());
      final s = big.fold(ints([1 << 62, -7, -(1 << 62), 0, 9223372036854775807]));
      final enc = big.encodeState(s) as Map;
      expect(enc.keys.every((k) => k is String), isTrue);
      final back = big.decodeState(wire(enc));
      expect(back.keys.toSet(),
          {1 << 62, -7, -(1 << 62), 0, 9223372036854775807});
    });
    test('empty state is an empty map', () {
      expect(counts.encodeState(counts.empty()), <String, Object?>{});
      expect(counts.decodeState(<String, Object?>{}), isEmpty);
    });
    test('malformed', () {
      expectMalformed(counts, [
        null, 'zzz', 3, true, [], [1],
        {'abc': 1}, {'1.5': 1}, {'': 1}, {'1': 'x'}, {'1': 1.5}, {'1': -1},
        {'1': null}, {'1': {}},
      ]);
      final valid = wire(counts.encodeState(counts.fold(cases[2]))) as Map;
      expectMalformed(counts, mutants(valid, removeKeys: false));
    });
  });

  group('lookback', () {
    DoubleColumn iota(int n) => col([for (var i = 0; i < n; i++) i * 1.5 + .25]);
    for (final k in [1, 2, 3, 5]) {
      final lb = Lookback<DoubleColumn, double, double>(k, _WindowFirst(k),
          batchFromJson: DoubleColumn.fromJson);
      test('k=$k resumes mid-stream (edges and inner state restored)', () {
        expectResumes(lb, [for (final n in [0, 1, 2, 4, 5, 6, 13]) iota(n)],
            close);
      });
      test('k=$k damaged encodings are rejected', () {
        expectRejectsDamage(lb, iota(9));
        expectRejectsDamage(lb, iota(1));
      });
    }
    test('a resumed seam equals the unbroken run for random cuts', () {
      final r = Rng(5);
      final lb = Lookback<DoubleColumn, double, double>(4, const _WindowFirst(4),
          batchFromJson: DoubleColumn.fromJson);
      final b = col([for (var i = 0; i < 80; i++) r.nextDouble()]);
      var s = lb.empty();
      var at = 0;
      while (at < 80) {
        final to = (at + r.intIn(0, 9)).clamp(0, 80);
        s = lb.decodeState(wire(lb.encodeState(lb.addSlice(s, b, at, to))));
        at = to;
      }
      expect(close(lb.finish(s), lb.run(b)), isTrue);
    });
    test('without batchFromJson encode/decode throw UnsupportedError', () {
      final lb = Lookback<DoubleColumn, double, double>(3, const _WindowFirst(3));
      expect(() => lb.encodeState(lb.empty()), throwsUnsupportedError);
      expect(() => lb.decodeState(null), throwsUnsupportedError);
    });
  });

  group('prefix', () {
    for (final k in [0, 1, 2, 5]) {
      final p = Prefix<DoubleColumn, int, int, double, double>(
          k, const Count<DoubleColumn>(), const _WindowFirst(1),
          batchFromJson: DoubleColumn.fromJson);
      bool eq((int, double) a, (int, double) b) => a.$1 == b.$1 && close(a.$2, b.$2);
      test('k=$k resumes mid-stream', () {
        expectResumes(p, [for (final n in [0, 1, 2, 3, 4, 7, 12]) col([for (var i = 0; i < n; i++) i * 2.5 - 3])],
            eq);
      });
      test('k=$k damaged encodings are rejected', () {
        expectRejectsDamage(p, col([for (var i = 0; i < 12; i++) i * 1.5]));
        expectRejectsDamage(p, col([1, 2]));
      });
    }
  });

  group('ewma', () {
    final a = Ewma<DoubleColumn>(_values, .3);
    bool eq(Affine x, Affine y) => close(x.scale, y.scale) && close(x.offset, y.offset);
    test('round trip on every split', () {
      expectResumes(a, allCases(moderate: true), eq);
    });
    test('identity and non-finite maps survive', () {
      expectResumes(a, [col([]), col([nan, nan]), col([inf, 1]), col([-0.0])], eq);
      final id = a.decodeState(wire(a.encodeState(a.empty())));
      expect(a.finish(id).scale, 1.0);
      expect(a.finish(id).offset, 0.0);
    });
    test('malformed', () {
      expectRejectsDamage(a, col([1, 2, 3, 4]));
      expectMalformed(a, [3, [], {}]);
    });
  });

  group('both and map', () {
    final sum = Sum<DoubleColumn>(_values);
    final pair = both(const Count<DoubleColumn>(), sum);
    test('both round trips on every split', () {
      expectResumes(pair, allCases(moderate: true),
          ((int, double) a, (int, double) b) => a.$1 == b.$1 && close(a.$2, b.$2));
    });
    test('both state is a two-element list', () {
      final enc = pair.encodeState(pair.fold(col([1, 2, 3])));
      expect(enc, isA<List>());
      expect((enc as List).length, 2);
      expect(enc.first, 3);
    });
    test('both malformed', () {
      final valid = wire(pair.encodeState(pair.fold(col([1, 2, 3])))) as List;
      expectMalformed(pair, [
        null, 'zzz', 3, true, {}, [], [1], [1, 2, 3], [valid[0]],
        ['x', valid[1]], [valid[0], 'x'], [-1, valid[1]],
        ...mutants(valid, removeKeys: false),
      ]);
    });
    test('map delegates to the inner codec', () {
      final m = const Count<DoubleColumn>().map((c) => c.toString());
      expect(m.persistable, isTrue);
      expect(m.encodeState(42), const Count<DoubleColumn>().encodeState(42));
      expect(m.decodeState(wire(m.encodeState(42))), 42);
      expectResumes(m, allCases(), (a, b) => a == b);
      expectMalformed(m, [null, 'x', -1, 1.5]);
    });
  });

  group('batch codecs', () {
    test('DoubleColumn round-trips non-finite and signed-zero values', () {
      final b = col([nan, inf, -inf, -0.0, 0.0, 5e-324, 0.1 + 0.2, 1e308]);
      final back = DoubleColumn.fromJson(wire(b.toJson()));
      expect(back.length, b.length);
      for (var i = 0; i < b.length; i++) {
        expect(bits(back.values[i]) == bits(b.values[i]) ||
            (b.values[i].isNaN && back.values[i].isNaN), isTrue, reason: '$i');
      }
      expect(DoubleColumn.fromJson(wire(col([]).toJson())).length, 0);
    });
    test('DoubleColumn accepts ints and rejects junk', () {
      expect(DoubleColumn.fromJson([1, 2.5, 'NaN']).values[0], 1.0);
      for (final bad in [
        null, 'zzz', 3, true, {}, {'v': []}, [true], ['zzz'], [null], [[]], ['nan']
      ]) {
        expect(() => DoubleColumn.fromJson(bad), throwsFormatException,
            reason: jsonEncode(bad));
      }
    });
    test('coded ListBatch keeps its codec through copyRange and join', () {
      final b = _ib([1, 2, 3, 4]);
      expect(b.toJson(), [1, 2, 3, 4]);
      expect(b.copyRange(1, 3).toJson(), [2, 3]);
      expect(b.copyRange(0, 1).join(b.copyRange(2, 4)).toJson(), [1, 3, 4]);
      final back = _intCodec.batchFromJson(wire(b.toJson()));
      expect(back.rows, [1, 2, 3, 4]);
      expect(back.toJson(), [1, 2, 3, 4]);
      expect(_intCodec.batchFromJson([]).rows, isEmpty);
    });
    test('coded ListBatch rejects malformed input', () {
      for (final bad in [null, 'zzz', 3, {}, true, [1, 'x'], [null], [1.5]]) {
        expect(() => _intCodec.batchFromJson(bad), throwsFormatException,
            reason: jsonEncode(bad));
      }
    });

    final specials = Float64List.fromList([nan, inf, -inf, -0.0, 0.0, 1e-310, 2.5]);
    Float64List sp(int n) => Float64List.fromList(
        [for (var i = 0; i < n; i++) specials[i % specials.length]]);
    bool same(Float64List a, Float64List b) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (!(bits(a[i]) == bits(b[i]) || (a[i].isNaN && b[i].isNaN))) return false;
      }
      return true;
    }

    test('Beats', () {
      for (final n in [0, 1, 7]) {
        final b = Beats(sp(n), sp(n + 3).sublist(3));
        final back = Beats.fromJson(wire(b.toJson()));
        expect(same(back.nnMs, b.nnMs) && same(back.timeMs, b.timeMs), isTrue);
      }
    });
    test('TimedValues', () {
      final b = TimedValues(sp(7), sp(7).sublist(0, 7));
      final back = TimedValues.fromJson(wire(b.toJson()));
      expect(same(back.tHours, b.tHours) && same(back.y, b.y), isTrue);
    });
    test('HrStream', () {
      final b = HrStream(sp(7), sp(7));
      final back = HrStream.fromJson(wire(b.toJson()));
      expect(same(back.tsMs, b.tsMs) && same(back.hr, b.hr), isTrue);
    });
    test('EpochSeries keeps firstIndex', () {
      final b = EpochSeries(sp(7), firstIndex: 1440);
      final back = EpochSeries.fromJson(wire(b.toJson()));
      expect(same(back.x, b.x), isTrue);
      expect(back.firstIndex, 1440);
      expect(EpochSeries.fromJson(wire(EpochSeries(sp(0)).toJson())).length, 0);
    });
    test('Epochs keeps the mask (or its absence) and firstIndex', () {
      final plain = Epochs(Uint8List.fromList([1, 0, 1, 1]), firstIndex: 96);
      final p = Epochs.fromJson(wire(plain.toJson()));
      expect(p.asleep, [1, 0, 1, 1]);
      expect(p.valid, isNull);
      expect(p.firstIndex, 96);
      final masked = Epochs(Uint8List.fromList([1, 0, 1]),
          valid: Uint8List.fromList([1, 1, 0]));
      final m = Epochs.fromJson(wire(masked.toJson()));
      expect(m.asleep, [1, 0, 1]);
      expect(m.valid, [1, 1, 0]);
      expect(m.firstIndex, 0);
      expect(Epochs.fromJson(wire(Epochs(Uint8List(0)).toJson())).length, 0);
    });

    test('malformed batch payloads and mismatched columns', () {
      final beats = Beats(sp(4), sp(4));
      final tv = TimedValues(sp(4), sp(4));
      final hr = HrStream(sp(4), sp(4));
      final es = EpochSeries(sp(4), firstIndex: 3);
      final ep = Epochs(Uint8List.fromList([1, 0, 1]),
          valid: Uint8List.fromList([1, 1, 0]), firstIndex: 5);
      final epPlain = Epochs(Uint8List.fromList([1, 0, 1]), firstIndex: 5);
      final cases = <(String, Object? Function(), Object? Function(Object?))>[
        ('Beats', beats.toJson, Beats.fromJson),
        ('TimedValues', tv.toJson, TimedValues.fromJson),
        ('HrStream', hr.toJson, HrStream.fromJson),
        ('EpochSeries', es.toJson, EpochSeries.fromJson),
        ('Epochs', ep.toJson, Epochs.fromJson),
        ('Epochs (no mask)', epPlain.toJson, Epochs.fromJson),
      ];
      for (final (name, toJson, from) in cases) {
        final valid = wire(toJson());
        for (final bad in [null, 'zzz', 3, true, [], {}, ...mutants(valid)]) {
          expect(() => from(bad), throwsFormatException,
              reason: '$name ${jsonEncode(bad)}');
        }
      }
      // Two-column batches: shortening one column is an inconsistency.
      for (final (name, toJson, from) in cases.where(
          (c) => c.$1 != 'EpochSeries' && c.$1 != 'Epochs (no mask)')) {
        final valid = wire(toJson()) as Map;
        for (final key in valid.keys.where((k) => valid[k] is List)) {
          final cut = {
            ...valid,
            key: (valid[key] as List).sublist(0, (valid[key] as List).length - 1)
          };
          expect(() => from(cut), throwsFormatException, reason: '$name $key');
        }
      }
    });
  });

  group('roundTrip law (harness self-test)', () {
    final cases = [
      _ib([]),
      _ib([4]),
      _ib([1, 2, 3, 4, 5]),
      _ib([9, 8, 7]),
    ];
    Set<String> laws(List<LawViolation> v) => {for (final x in v) x.law};

    test('a faithful codec has no violations', () {
      expect(checkLaws(const _SumCount(), cases), isEmpty);
    });
    test('a codec that drops a field is caught as exactly {roundTrip}', () {
      final v = checkLaws(const _SumCount(dropCount: true), cases);
      expect(laws(v), {'roundTrip'});
      expect(v.every((x) => x.detail.isNotEmpty), isTrue);
    });
    test('a non-persistable aggregator is not asked to round trip', () {
      expect(checkLaws(const _SumCount(dropCount: true, persists: false), cases),
          isEmpty);
    });
    test('checkConversion reports it as law:roundTrip', () {
      final f = checkConversion<List<int>, _IB, int>(
          (_) => const _SumCount(dropCount: true),
          cases,
          (b) => b.rows.fold(0, (s, x) => s + x) * 1000 + b.length);
      expect({for (final x in f) x.path}, {'law:roundTrip'});
    });
    test('expectLawful fails for the lossy codec and passes for the good one',
        () {
      expectLawful(const _SumCount(), cases);
      expect(() => expectLawful(const _SumCount(dropCount: true), cases),
          throwsA(isA<TestFailure>()));
    });
    test('the built-in blocks pass the new law', () {
      expect(checkLaws(Sum<DoubleColumn>(_values), allCases(moderate: true), equals: close), isEmpty);
      expect(checkLaws(const Count<DoubleColumn>(), allCases()), isEmpty);
    });
  });

  group('checkpoint envelope', () {
    final sum = Sum<DoubleColumn>(_values);
    final b = col([1.5, nan, 2.25, 1e-3, 4]);
    test('encodes kind, version and state', () {
      final env = encodeCheckpoint(const Count<DoubleColumn>(), 5,
          kind: 'k', version: 2);
      expect(env, {'kind': 'k', 'version': 2, 'state': 5});
    });
    test('resume through JSON text continues to the one-pass result', () {
      final env = encodeCheckpoint(sum, sum.fold(b, 0, 2),
          kind: 'sum', version: 1);
      final state = decodeCheckpoint<dynamic>(sum, wire(env),
          kind: 'sum', version: 1);
      expect(state, isNotNull);
      expect(close(sum.finish(sum.addSlice(state, b, 2, 5)), sum.run(b)), isTrue);
    });
    test('a non-finite state still encodes to JSON text', () {
      final a = SumSq<DoubleColumn>(_values);
      final env = encodeCheckpoint(a, inf, kind: 'x', version: 1);
      expect(decodeCheckpoint<double>(a, wire(env), kind: 'x', version: 1), inf);
    });
    test('kind or version mismatch refuses with null', () {
      final env = wire(encodeCheckpoint(sum, sum.fold(b), kind: 'a', version: 3));
      expect(decodeCheckpoint<dynamic>(sum, env, kind: 'b', version: 3), isNull);
      expect(decodeCheckpoint<dynamic>(sum, env, kind: 'a', version: 2), isNull);
      expect(decodeCheckpoint<dynamic>(sum, env, kind: 'a', version: 4), isNull);
      expect(decodeCheckpoint<dynamic>(sum, env, kind: 'a', version: 3), isNotNull);
    });
    test('malformed state or envelope refuses with null, never throws', () {
      const c = Count<DoubleColumn>();
      Map<String, Object?> env(Object? state) =>
          {'kind': 'k', 'version': 1, 'state': state};
      for (final bad in [
        env('zzz'), env(-1), env(1.5), env(null), env([]),
        {'kind': 'k', 'version': 1},
        {'kind': 'k', 'state': 1},
        {'version': 1, 'state': 1},
        {'kind': 7, 'version': 1, 'state': 1},
        {'kind': 'k', 'version': '1', 'state': 1},
        {'kind': 'k', 'version': 1.0, 'state': 1},
        {'kind': 'k', 'version': null, 'state': 1},
        null, 'zzz', 3, true, [], [1, 2, 3], <String, Object?>{},
      ]) {
        expect(decodeCheckpoint<int>(c, bad, kind: 'k', version: 1), isNull,
            reason: jsonEncode(bad));
      }
      expect(decodeCheckpoint<int>(c, env(4), kind: 'k', version: 1), 4);
    });
    test('a damaged nested state refuses rather than guessing', () {
      final lb = Lookback<DoubleColumn, double, double>(3, const _WindowFirst(3),
          batchFromJson: DoubleColumn.fromJson);
      final data = col([for (var i = 0; i < 9; i++) i * 1.0]);
      final good = wire(encodeCheckpoint(lb, lb.fold(data, 0, 5),
          kind: 'lb', version: 1)) as Map;
      expect(decodeCheckpoint<dynamic>(lb, good, kind: 'lb', version: 1), isNotNull);
      for (final m in mutants(good['state'])) {
        expect(
            decodeCheckpoint<dynamic>(lb, {...good, 'state': m},
                kind: 'lb', version: 1),
            isNull,
            reason: jsonEncode(m));
      }
    });
    test('a non-persistable aggregator cannot be checkpointed', () {
      expect(() => encodeCheckpoint(const _Plain(), 0, kind: 'k', version: 1),
          throwsUnsupportedError);
    });
  });
}
