// Affine, Ewma and Prefix (spec: research/r7-ewma.md).
//
// Decisions the implementation follows:
//  * `const Affine(double scale, double offset)`, positional; identity is
//    `Affine(1, 0)`; `apply(x) = scale * x + offset`;
//    `a.then(b)` = b after a = (b.scale*a.scale, b.scale*a.offset + b.offset).
//  * `Ewma<B>(col, lambda)` is an Aggregator<_, B, Affine>, positional args.
//    Its Affine maps the running value c to the value after all rows:
//    one row x is c -> (1 - lambda) * c + lambda * x. NaN rows are skipped
//    (identity). No rows (or only NaN rows) finish as Affine(1, 0).
//  * `Prefix(k, head, tail)` (type args inferred) is an
//    Aggregator<_, B, (R1, R2)>. Head sees rows [0, k) of the whole input via
//    head.run on stored rows (so head.combine is never called), tail sees rows
//    [k, n) in order. k = 0 gives head an empty batch. The stored prefix is a
//    copy: mutating the source column after folding changes nothing.

import 'package:openstrap_analytics/aggregate.dart';
import 'package:test/test.dart';

import '../support/aggregator_laws.dart';
import '../support/property.dart' show Rng;

const nan = double.nan;

List<Object?> _aff(Affine a) => [a.scale, a.offset];
final _affEq = fieldsEqual<Affine>(_aff, relTol: 1e-12, absTol: 1e-15);


Ewma<DoubleColumn> _ewma(double lambda) =>
    Ewma<DoubleColumn>((b) => b.values, lambda);

/// Reference: apply x_i one by one to the running value, skipping NaN.
double _loop(double seed, List<double> xs, double lambda) {
  var c = seed;
  for (final x in xs) {
    if (x.isNaN) continue;
    c = c + lambda * (x - c);
  }
  return c;
}

void _expectAffine(Affine got, Affine want, String tag) => expect(
    _affEq(got, want), isTrue,
    reason: '$tag got ${_aff(got)} want ${_aff(want)}');

typedef _Rows = List<double>;

/// Records every row it is shown, in order. Head variant never combines.
class _Rec extends Aggregator<_Rows, DoubleColumn, _Rows> {
  const _Rec({this.combinable = true});
  final bool combinable;
  @override
  _Rows empty() => <double>[];
  @override
  _Rows addSlice(_Rows s, DoubleColumn b, int start, int end) =>
      s..addAll([for (var i = start; i < end; i++) b.values[i]]);
  @override
  _Rows combine(_Rows l, _Rows r) {
    if (!combinable) throw StateError('head.combine must not be called');
    return l..addAll(r);
  }

  @override
  _Rows finish(_Rows s) => List<double>.of(s);
}

DoubleColumn _iota(int n) => col([for (var i = 0; i < n; i++) i * 1.0]);

void _is(Object? got, Object? want, {String? reason}) =>
    expect(got.toString(), want.toString(), reason: reason);

bool _str(Object? a, Object? b) => a.toString() == b.toString();

void main() {
  group('Affine', () {
    test('apply, identity and then', () {
      const a = Affine(2, 3);
      const b = Affine(5, -1);
      expect(a.apply(4), 11);
      expect(const Affine(1, 0).apply(7.5), 7.5);
      final ab = a.then(b); // b after a
      expect(ab.scale, 10);
      expect(ab.offset, 5 * 3 + -1);
      for (final x in [-3.0, 0.0, 1.5, 100.0]) {
        expect(ab.apply(x), b.apply(a.apply(x)));
      }
      _expectAffine(const Affine(1, 0).then(a), a, 'id.then(a)');
      _expectAffine(a.then(const Affine(1, 0)), a, 'a.then(id)');
    });

    test('then is associative (seeded)', () {
      final r = Rng(0xAF1);
      Affine rnd() => Affine((r.nextDouble() - .5) * 4, (r.nextDouble() - .5) * 100);
      for (var t = 0; t < 100; t++) {
        final a = rnd(), b = rnd(), c = rnd();
        _expectAffine(a.then(b).then(c), a.then(b.then(c)), 't$t');
      }
    });
  });

  group('Ewma', () {
    test('one row: (1 - lambda) c + lambda x', () {
      final f = _ewma(0.25).run(col([8]));
      expect(f.scale, closeTo(0.75, 1e-15));
      expect(f.offset, closeTo(2, 1e-15));
      expect(f.apply(4), closeTo(0.75 * 4 + 2, 1e-15));
    });

    test('no rows, and only NaN rows, are the identity', () {
      final e = _ewma(0.1);
      _expectAffine(e.run(col([])), const Affine(1, 0), 'empty');
      _expectAffine(e.finish(e.empty()), const Affine(1, 0), 'empty state');
      _expectAffine(e.run(col([nan, nan, nan])), const Affine(1, 0), 'nans');
    });

    test('values equal a direct loop (seeded, several lambdas)', () {
      final r = Rng(0xE111);
      for (final lambda in [0.5, 1 - 0.9, 0.02, 0.1331, 1.0, 0.0]) {
        final e = _ewma(lambda);
        for (var t = 0; t < 40; t++) {
          final n = r.intIn(0, 30);
          final xs = [
            for (var i = 0; i < n; i++)
              r.nextBool(.2) ? nan : (r.nextDouble() - .3) * 500
          ];
          final seed = (r.nextDouble() - .5) * 300;
          final got = e.run(col(xs)).apply(seed);
          final want = _loop(seed, xs, lambda);
          expect(got, closeTo(want, 1e-12 * (1 + want.abs())),
              reason: 'lambda=$lambda t=$t');
        }
      }
    });

    test('NaN rows are skipped, not decayed', () {
      final e = _ewma(0.3);
      final a = e.run(col([10, nan, 20, nan, nan, 5]));
      final b = e.run(col([10, 20, 5]));
      _expectAffine(a, b, 'nan vs removed');
    });

    test('combine is left.then(right): chunking does not matter', () {
      final r = Rng(0xE112);
      final e = _ewma(0.07);
      for (var t = 0; t < 60; t++) {
        final n = r.intIn(0, 60);
        final c = col([
          for (var i = 0; i < n; i++) r.nextBool(.1) ? nan : r.nextDouble() * 400
        ]);
        final want = e.run(c);
        final b = randomBounds(r, n);
        _expectAffine(runChunked(e, c, b), want, 'chunked $b');
        _expectAffine(runChunked(e, c, b, copy: true), want, 'copy $b');
        _expectAffine(runChunkedRight(e, c, b), want, 'right $b');
        _expectAffine(runSliced(e, c, b), want, 'sliced $b');
        _expectAffine(runChunked(e, c, singletonBounds(n)), want, 'single');
      }
    });

    test('is lawful', () {
      expectLawful(_ewma(0.05), randomColumns(0xE113, nanP: .2, maxLen: 40),
          equals: _affEq);
    });
  });

  group('Prefix', () {
    for (final k in [0, 1, 3, 7]) {
      group('k = $k', () {
        final p = Prefix(k, const _Rec(combinable: false), const _Rec());

        (List<double>, List<double>) want(int n) => (
              [for (var i = 0; i < n && i < k; i++) i * 1.0],
              [for (var i = k; i < n; i++) i * 1.0],
            );

        test('head sees exactly rows [0, k), tail rows [k, n), inputs of '
            'every length', () {
          for (var n = 0; n <= 20; n++) {
            _is(p.run(_iota(n)), want(n), reason: 'n=$n');
          }
        });

        test('every single and double cut, all four evaluation paths', () {
          for (final n in [0, 1, k, k + 1, 12]) {
            final c = _iota(n);
            for (var a = 0; a <= n; a++) {
              for (var b = a; b <= n; b++) {
                final bd = [0, a, b, n];
                _is(runChunked(p, c, bd), want(n), reason: 'chunk $bd');
                _is(runChunked(p, c, bd, copy: true), want(n),
                    reason: 'copy $bd');
                _is(runChunkedRight(p, c, bd), want(n), reason: 'right $bd');
                _is(runSliced(p, c, bd), want(n), reason: 'sliced $bd');
              }
            }
          }
        });

        test('random chunkings and slicings, empty chunks included', () {
          final r = Rng(0x9F00 + k);
          for (var t = 0; t < 80; t++) {
            final n = r.intIn(0, 40);
            final c = _iota(n);
            final b = randomBounds(r, n);
            _is(runChunked(p, c, b), want(n), reason: 'chunk $b n=$n');
            _is(runChunked(p, c, b, copy: true), want(n), reason: 'copy');
            _is(runChunkedRight(p, c, b), want(n), reason: 'right $b n=$n');
            _is(runSliced(p, c, b), want(n), reason: 'sliced $b n=$n');
            final s = singletonBounds(n);
            _is(runChunked(p, c, s), want(n), reason: 'singletons');
            _is(runChunkedRight(p, c, s), want(n), reason: 'right singles');
            _is(runSliced(p, c, s), want(n), reason: 'sliced singles');
          }
        });

        test('is lawful with a recording head and tail', () {
          expectLawful(p, [for (var n = 0; n <= 14; n++) _iota(n), _iota(40)],
              equals: _str);
        });

        test('is lawful with Count and Sum', () {
          final eq = fieldsEqual<(int, double)>((x) => [x.$1, x.$2],
              relTol: 1e-12, absTol: 1e-9);
          expectLawful(
              Prefix(k, Count<DoubleColumn>(), Sum<DoubleColumn>((b) => b.values)),
              randomColumns(0x9F10 + k, nanP: .2),
              equals: eq);
          final eq2 = fieldsEqual<(double, int)>((x) => [x.$1, x.$2],
              relTol: 1e-12, absTol: 1e-9);
          expectLawful(
              Prefix(k, Sum<DoubleColumn>((b) => b.values), Count<DoubleColumn>()),
              randomColumns(0x9F20 + k, nanP: .2),
              equals: eq2);
        });
      });
    }

    test('k = 3: seams of one-row chunks fill the prefix then the tail', () {
      final p = Prefix(3, const _Rec(combinable: false), const _Rec());
      final c = _iota(6);
      var s = p.fold(c, 0, 1);
      s = p.combine(s, p.fold(c, 1, 2));
      _is(p.finish(s), (<double>[0, 1], <double>[]));
      s = p.combine(s, p.fold(c, 2, 3));
      s = p.combine(s, p.fold(c, 3, 4));
      _is(p.finish(s), (<double>[0, 1, 2], <double>[3]));
      // A right chunk bigger than the room left in the left prefix.
      final r = p.combine(p.fold(c, 0, 2), p.fold(c, 2, 6));
      _is(p.finish(r), (<double>[0, 1, 2], <double>[3, 4, 5]));
      // Empty left, empty right.
      _is(p.finish(p.combine(p.empty(), p.fold(c, 0, 6))), (<double>[0, 1, 2], <double>[3, 4, 5]));
      _is(p.finish(p.combine(p.fold(c, 0, 6), p.empty())), (<double>[0, 1, 2], <double>[3, 4, 5]));
    });

    test('the stored prefix is a copy of the rows', () {
      final p = Prefix(3, const _Rec(combinable: false), const _Rec());
      final c = _iota(6);
      final s = p.fold(c, 0, 6);
      final s2 = p.fold(c, 0, 2);
      for (var i = 0; i < 6; i++) {
        c.values[i] = -99;
      }
      _is(p.finish(s), (<double>[0, 1, 2], <double>[3, 4, 5]));
      _is(p.finish(s2), (<double>[0, 1], <double>[]));
    });

    test('composes with Ewma as the tail: mean seed, then decay', () {
      final p = Prefix(
          4, Sum<DoubleColumn>((b) => b.values), _ewma(0.2));
      final r = Rng(0x9F30);
      for (var t = 0; t < 40; t++) {
        final n = r.intIn(0, 30);
        final xs = [for (var i = 0; i < n; i++) r.nextDouble() * 300];
        final c = col(xs);
        final b = randomBounds(r, n);
        final (sum, f) = runChunked(p, c, b);
        final head = n < 4 ? n : 4;
        expect(sum, closeTo(xs.take(head).fold(0.0, (a, x) => a + x), 1e-9));
        final seed = 50.0;
        final got = f.apply(seed);
        final want = _loop(seed, xs.skip(4).toList(), 0.2);
        expect(got, closeTo(want, 1e-9 * (1 + want.abs())), reason: 't$t $b');
      }
    });
  });
}
