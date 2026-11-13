// Self-tests of the property harness (test/support/property.dart).
//
// The harness decides whether the property suites can be trusted, so its own
// guarantees are pinned here: deterministic and independent seeds, replay of a
// single case, forced examples first, domain-preserving bounded shrinking, the
// failure report (seed, case, input, generator version, replay command) and
// the per-property wall budget.

import 'dart:math' as math;

import 'package:test/test.dart';

import 'property.dart';

/// Runs [gen] through the harness with a body that records every input and
/// never fails. Returns the recorded inputs (forced examples first).
List<T> _inputs<T>(Gen<T> gen,
    {String name = 'rec',
    int cases = 30,
    List<T> examples = const [],
    int? seed,
    String? caseOnly}) {
  final seen = <T>[];
  final r = runProperty<T>(
    name: name,
    gen: gen,
    body: seen.add,
    examples: examples,
    config: PropertyConfig(seed: seed, cases: cases, caseOnly: caseOnly),
  );
  expect(r.passed, isTrue, reason: r.failure?.report);
  return seen;
}

PropertyFailure _fails<T>(Gen<T> gen, bool Function(T) holds,
    {List<T> examples = const [],
    int cases = 200,
    int shrinkLimit = 300,
    String name = 'p',
    int seed = 7,
    String? caseOnly,
    String? testFile}) {
  final r = runProperty<T>(
    name: name,
    gen: gen,
    body: (v) {
      if (!holds(v)) throw StateError('does not hold: $v');
    },
    examples: examples,
    config: PropertyConfig(
        seed: seed,
        cases: cases,
        shrinkLimit: shrinkLimit,
        caseOnly: caseOnly,
        testFile: testFile),
  );
  expect(r.passed, isFalse, reason: 'the property should have failed');
  return r.failure!;
}

void main() {
  group('rng', () {
    test('the same seed gives the same sequence, another seed another', () {
      List<int> draw(int seed) {
        final r = Rng(seed);
        return [for (var i = 0; i < 20; i++) r.nextInt(1 << 20)];
      }

      expect(draw(5), draw(5));
      expect(draw(5), isNot(draw(6)));
    });

    test('intIn is inclusive, nextDouble is in [0, 1), nextBool honours p', () {
      final r = Rng(42);
      final ints = {for (var i = 0; i < 400; i++) r.intIn(-2, 2)};
      expect(ints, {-2, -1, 0, 1, 2});
      for (var i = 0; i < 400; i++) {
        final d = r.nextDouble();
        expect(d >= 0 && d < 1, isTrue);
      }
      expect(r.intIn(3, 3), 3);
      expect([for (var i = 0; i < 50; i++) r.nextBool(0)], everyElement(false));
      expect([for (var i = 0; i < 50; i++) r.nextBool(1)], everyElement(true));
    });

    test('next64 is SplitMix64: the first outputs match the reference values',
        () {
      // Computed independently with python3, masking every step to 64 bits:
      //   s = (s + 0x9E3779B97F4A7C15) & M
      //   z = ((s ^ (s >> 30)) * 0xBF58476D1CE4E5B9) & M
      //   z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & M;  out = z ^ (z >> 31)
      // Seed 0 starts 0xE220A8397B1DCDAF, the published SplitMix64 test value.
      // Dart's signed int holds the same 64 bits, so compare as hex.
      String hex(int v) =>
          (v >>> 32).toRadixString(16).padLeft(8, '0') +
          (v & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0');
      final z = Rng(0);
      expect([for (var i = 0; i < 5; i++) hex(z.next64())], [
        'e220a8397b1dcdaf',
        '6e789e6aa1b965f4',
        '06c45d188009454f',
        'f88bb8a8724c81ec',
        '1b39896a51a8749b',
      ]);
      final k = Rng(1234567);
      expect([for (var i = 0; i < 5; i++) hex(k.next64())], [
        '599ed017fb08fc85',
        '2c73f08458540fa5',
        '883ebce5a3f27c77',
        '3fbef740e9177b3f',
        'e3b8346708cb5ecd',
      ]);
    });

    test('the stream is pinned: a replay command stays valid across SDKs', () {
      final r = Rng(1);
      expect([for (var i = 0; i < 5; i++) r.nextInt(1000)],
          [232, 259, 295, 117, 380]);
      expect(Rng(1).nextDouble(), 0.5665615751722809);
      expect(seedFor('a law'), 1308619236);
      expect(caseSeed(9, 3), 136612318154068);
    });

    test('draws are spread: a long run touches every bucket of 16', () {
      final r = Rng(1);
      final buckets = {for (var i = 0; i < 2000; i++) r.nextInt(16)};
      expect(buckets.length, 16);
    });
  });

  group('rng ranges', () {
    forAll<(int, int)>(
        'rng draws stay in range: nextInt(bound) in [0, bound), nextDouble in [0, 1)',
        G.pair(
            G.intIn(-(1 << 40), 1 << 40),
            G.intIn(0, 9)),
        (arg) {
      final (seed, pick) = arg;
      const bounds = [1, 2, 3, 7, 1000, 1 << 20, (1 << 53) - 1, 1 << 53];
      final r = Rng(seed);
      for (var i = 0; i < 40; i++) {
        final b = bounds[(pick + i) % bounds.length];
        final n = r.nextInt(b);
        expect(n >= 0 && n < b, isTrue, reason: 'nextInt($b) = $n');
        final d = r.nextDouble();
        expect(d >= 0 && d < 1, isTrue, reason: 'nextDouble() = $d');
        final k = r.intIn(0, b - 1);
        expect(k >= 0 && k < b, isTrue, reason: 'intIn(0, ${b - 1}) = $k');
      }
      expect(Rng(seed).nextInt(1), 0);
    }, examples: const [(0, 0), (-1, 7), (1 << 40, 3)]);
  });

  group('seeds', () {
    test('seedFor is stable per name and differs between names', () {
      expect(seedFor('a law'), seedFor('a law'));
      expect(seedFor('a law'), isNot(seedFor('another law')));
    });

    test('case seeds are independent of each other and of the run length', () {
      expect(caseSeed(9, 3), caseSeed(9, 3));
      expect(caseSeed(9, 3), isNot(caseSeed(9, 4)));
      expect(caseSeed(9, 3), isNot(caseSeed(10, 3)));
    });

    test('two properties with different names draw different inputs', () {
      final gen = G.listOf(G.intIn(0, 1 << 20), maxLen: 8);
      expect(_inputs(gen, name: 'one', cases: 5),
          isNot(_inputs(gen, name: 'two', cases: 5)));
    });

    test('the same property is reproduced exactly', () {
      final gen = G.pair(G.intIn(-50, 50), G.doubleIn(0, 1));
      expect(_inputs(gen, cases: 40), _inputs(gen, cases: 40));
    });
  });

  group('config from the environment', () {
    test('defaults: 200 cases, 2 s, no seed, no single case', () {
      final c = PropertyConfig.fromEnvironment(const {});
      expect(c.cases, 200);
      expect(c.budget, const Duration(seconds: 2));
      expect(c.seed, isNull);
      expect(c.caseOnly, isNull);
    });

    test('PROPERTY_SEED, PROPERTY_CASE and PROPERTY_ITERATIONS override', () {
      final c = PropertyConfig.fromEnvironment(const {
        'PROPERTY_SEED': '12345',
        'PROPERTY_CASE': '17',
        'PROPERTY_ITERATIONS': '1000',
      }, testFile: 'test/x_test.dart');
      expect(c.seed, 12345);
      expect(c.caseOnly, '17');
      expect(c.cases, 1000);
      expect(c.testFile, 'test/x_test.dart');
    });

    test('raising the iterations scales the wall budget with them', () {
      final c =
          PropertyConfig.fromEnvironment(const {'PROPERTY_ITERATIONS': '1000'});
      expect(c.budget, const Duration(seconds: 10));
      final fixed = PropertyConfig.fromEnvironment(const {
        'PROPERTY_ITERATIONS': '1000',
        'PROPERTY_BUDGET_MS': '3000',
      });
      expect(fixed.budget, const Duration(milliseconds: 3000));
    });

    test('a malformed number is loud, not ignored', () {
      expect(() => PropertyConfig.fromEnvironment(const {'PROPERTY_SEED': 'x'}),
          throwsFormatException);
      expect(
          () => PropertyConfig.fromEnvironment(
              const {'PROPERTY_ITERATIONS': '0'}),
          throwsFormatException);
    });
  });

  group('running', () {
    test('runs exactly the configured number of cases', () {
      final r = runProperty<int>(
        name: 'n',
        gen: G.intIn(0, 9),
        body: (_) {},
        config: const PropertyConfig(cases: 37),
      );
      expect(r.passed, isTrue);
      expect(r.casesRun, 37);
      expect(r.forcedRun, 0);
    });

    test('forced examples run first, in order, then the generated cases', () {
      final seen = _inputs(G.intIn(100, 200),
          examples: [5, 6, 7], cases: 10);
      expect(seen.take(3), [5, 6, 7]);
      expect(seen.length, 13);
      final r = runProperty<int>(
          name: 'f',
          gen: G.intIn(0, 9),
          body: (_) {},
          examples: [1, 2],
          config: const PropertyConfig(cases: 4));
      expect((r.forcedRun, r.casesRun), (2, 4));
    });

    test('generated cases stay inside the generator, even the first ones', () {
      final seen = _inputs(G.intIn(-3, 11), cases: 200);
      expect(seen.every((v) => v >= -3 && v <= 11), isTrue);
    });

    test('a single case replays exactly the input it had in the full run', () {
      final gen = G.pair(G.intIn(-1000, 1000), G.listOf(G.boolean(), maxLen: 9));
      final all = _inputs(gen, cases: 60, seed: 99);
      for (final k in [0, 1, 17, 59]) {
        expect(
            _inputs(gen, cases: 60, seed: 99, caseOnly: '$k')
                .map(gen.show)
                .toList(),
            [gen.show(all[k])],
            reason: 'case $k');
      }
    });

    test('a case replays the same whatever the iteration count', () {
      final gen = G.listOf(G.intIn(0, 1 << 20), maxLen: 30);
      final short = _inputs(gen, cases: 25, seed: 3);
      final long = _inputs(gen, cases: 80, seed: 3);
      expect(long.take(25), short);
    });

    test('a forced example replays by its forced id, generated cases skip it',
        () {
      final seen = _inputs(G.intIn(100, 200),
          examples: [5, 6, 7], cases: 10, caseOnly: 'forced:1');
      expect(seen, [6]);
      final one = _inputs(G.intIn(100, 200),
          examples: [5, 6, 7], cases: 10, seed: 1, caseOnly: '2');
      expect(one.length, 1);
      expect(one.single, inInclusiveRange(100, 200));
    });

    test('a replay of a case beyond the run length still runs that case', () {
      final seen = _inputs(G.intIn(0, 9), cases: 5, caseOnly: '40');
      expect(seen.length, 1);
    });

    test('a body that completes normally is passed, whatever it returns', () {
      final r = runProperty<int>(
          name: 'ret', gen: G.intIn(0, 3), body: (_) => 5 as dynamic);
      expect(r.passed, isTrue);
    });
  });

  group('failure report', () {
    test('names the seed, case, shrunk input, generator version, replay', () {
      final f = _fails(G.intIn(0, 1000), (v) => v < 50,
          name: 'ints stay small', seed: 4242, testFile: 'test/x_test.dart');
      expect(f.kind, FailureKind.counterexample);
      expect(f.seed, 4242);
      expect(f.input, '50');
      expect(f.caseId, matches(RegExp(r'^\d+$')));
      expect(f.error, contains('does not hold'));
      expect(
          f.replay,
          'PROPERTY_SEED=4242 PROPERTY_CASE=${f.caseId} '
          "dart test test/x_test.dart --plain-name 'ints stay small'");
      for (final s in [
        'ints stay small',
        'seed: 4242',
        'case: ${f.caseId}',
        'generator: g1',
        'shrink limit: 300',
        'input',
        '50',
        f.replay,
      ]) {
        expect(f.report, contains(s));
      }
    });

    test('the generator version is whatever the property declares', () {
      final r = runProperty<int>(
          name: 'v',
          gen: G.intIn(0, 9),
          body: (_) => throw StateError('x'),
          genVersion: 'layout-gen/3',
          config: const PropertyConfig(seed: 1));
      expect(r.failure!.report, contains('generator: layout-gen/3'));
    });

    test('a quote in the name is escaped in the replay command', () {
      final f = _fails(G.intIn(0, 9), (_) => false, name: "it's a law");
      expect(f.replay, contains(r"--plain-name 'it'\''s a law'"));
    });

    test('an unknown test file is a visible placeholder, not omitted', () {
      final f = _fails(G.intIn(0, 9), (_) => false);
      expect(f.replay, contains('dart test <test file>'));
    });

    test('the replay command reproduces the failure', () {
      final gen = G.listOf(G.intIn(0, 99), maxLen: 25);
      final f = _fails(gen, (l) => l.length < 20, seed: 11);
      final again =
          _fails(gen, (l) => l.length < 20, seed: 11, caseOnly: f.caseId);
      expect(again.input, f.input);
      expect(again.caseId, f.caseId);
    });

    test('is deterministic: the same run produces the same report', () {
      final gen = G.pair(G.intIn(0, 500), G.doubleIn(0, 1));
      String report() => _fails(gen, (p) => p.$1 < 400).report;
      expect(report(), report());
    });

    test('a thrown TestFailure keeps its message', () {
      final r = runProperty<int>(
          name: 'tf',
          gen: G.intIn(0, 3),
          body: (v) => expect(v, 99, reason: 'my reason'),
          config: const PropertyConfig(seed: 1));
      expect(r.failure!.error, contains('my reason'));
    });

    test('a failing forced example is reported as forced, not shrunk', () {
      final f = _fails(G.intIn(0, 1000), (v) => v != 777, examples: [3, 777]);
      expect(f.kind, FailureKind.forcedExample);
      expect(f.caseId, 'forced:1');
      expect(f.input, '777');
      expect(f.shrinkSteps, 0);
      expect(f.replay, contains('PROPERTY_CASE=forced:1'));
    });

    test('a generator that throws is reported as a generator failure', () {
      final r = runProperty<int>(
          name: 'g',
          gen: _Boom(),
          body: (_) {},
          config: const PropertyConfig(seed: 1, cases: 3));
      expect(r.failure!.kind, FailureKind.generator);
      expect(r.failure!.report, contains('boom'));
    });
  });

  group('shrinking ints', () {
    test('finds the smallest failing int above zero', () {
      expect(_fails(G.intIn(0, 1000), (v) => v < 50).input, '50');
    });

    test('shrinks negatives toward zero', () {
      expect(_fails(G.intIn(-100, 100), (v) => v > -7).input, '-7');
    });

    test('shrinks toward the bound nearest zero when zero is out of range',
        () {
      expect(_fails(G.intIn(10, 100), (_) => false).input, '10');
      expect(_fails(G.intIn(-100, -10), (_) => false).input, '-10');
    });

    test('an explicit origin is the shrink target', () {
      expect(_fails(G.intIn(0, 100, origin: 60), (_) => false).input, '60');
    });

    test('never leaves the generator domain', () {
      final tried = <int>[];
      runProperty<int>(
          name: 'dom',
          gen: G.intIn(13, 91),
          body: (v) {
            tried.add(v);
            if (v > 20) throw StateError('x');
          },
          config: const PropertyConfig(seed: 5));
      expect(tried.every((v) => v >= 13 && v <= 91), isTrue);
    });

    test('a boolean shrinks to false', () {
      expect(_fails(G.boolean(), (_) => false).input, 'false');
    });

    test('elements shrink toward the earlier ones', () {
      expect(
          _fails(G.elements(['a', 'b', 'c', 'd']), (v) => v == 'a').input, 'b');
    });
  });

  group('shrinking doubles', () {
    test('reaches zero or the nearest bound when everything fails', () {
      expect(_fails(G.doubleIn(-5, 5), (_) => false).input, '0.0');
      expect(_fails(G.doubleIn(5, 10), (_) => false).input, '5.0');
    });

    test('lands just above a threshold, not far from it', () {
      final f = _fails(G.doubleIn(0, 100), (v) => v < 3.5);
      final v = double.parse(f.input);
      expect(v, inInclusiveRange(3.5, 5));
    });

    test('generation reaches the declared boundaries exactly', () {
      final seen = _inputs(
          G.doubleIn(-10, 10, boundaries: const [-10, 10, 0, 1e-9]),
          cases: 200);
      expect(seen, containsAll([-10.0, 10.0, 0.0, 1e-9]));
      expect(seen.every((v) => v >= -10 && v <= 10), isTrue);
    });

    test('specials (NaN, infinities) appear when declared, never otherwise',
        () {
      final withSpecials = _inputs(
          G.doubleIn(0, 1, specials: const [double.nan, double.infinity]),
          cases: 200);
      expect(withSpecials.any((v) => v.isNaN), isTrue);
      expect(withSpecials.any((v) => v == double.infinity), isTrue);
      final plain = _inputs(G.doubleIn(0, 1), cases: 200);
      expect(plain.every((v) => v.isFinite && v >= 0 && v <= 1), isTrue);
    });

    test('a failing special shrinks to a simple finite value if that fails too',
        () {
      expect(
          _fails(G.doubleIn(0, 1, specials: const [double.nan]), (_) => false)
              .input,
          '0.0');
    });

    test('shrink candidates stay in range, differ from the value, are bounded',
        () {
      final g = G.doubleIn(-3, 100, boundaries: const [50]);
      for (final v in [99.5, -2.25, 0.0, 3.0, 50.0, -3.0, 1e-12]) {
        final c = g.shrink(v).toList();
        expect(c.length, lessThanOrEqualTo(40), reason: '$v');
        for (final x in c) {
          expect(x >= -3 && x <= 100, isTrue, reason: '$v -> $x');
          expect(x, isNot(v), reason: '$v -> $x');
        }
      }
      expect(g.shrink(0.0), isEmpty, reason: 'the origin is already simplest');
    });

    test('following the closest candidate always terminates', () {
      final g = G.doubleIn(-3, 100);
      var v = 87.123456;
      var steps = 0;
      while (true) {
        final c = g.shrink(v).toList();
        if (c.isEmpty) break;
        v = c.last;
        expect(++steps, lessThan(200), reason: 'stuck at $v');
      }
      expect(v, 0);
    });

    test('int shrink candidates: origin first, in range, never the value', () {
      final g = G.intIn(-20, 40);
      for (final v in [-20, -1, 0, 1, 7, 40]) {
        final c = g.shrink(v).toList();
        if (v == 0) {
          expect(c, isEmpty);
          continue;
        }
        expect(c.first, 0);
        expect(c.every((x) => x >= -20 && x <= 40 && x != v), isTrue);
        expect(c.length, lessThanOrEqualTo(12));
      }
    });
  });

  group('shrinking lists, tuples, nullables', () {
    test('a list shrinks to the shortest failing length of zeros', () {
      final f = _fails(G.listOf(G.intIn(0, 9), maxLen: 20), (l) => l.length < 3);
      expect(f.input, '[0, 0, 0]');
    });

    test('a list keeps the one element that matters', () {
      final f = _fails(
          G.listOf(G.intIn(0, 20), maxLen: 20), (l) => !l.any((e) => e >= 5));
      expect(f.input, '[5]');
    });

    test('a list never goes under its minimum or over its cap', () {
      final lens = <int>[];
      runProperty<List<int>>(
          name: 'len',
          gen: G.listOf(G.intIn(0, 9), minLen: 2, maxLen: 7),
          body: (l) {
            lens.add(l.length);
            throw StateError('always');
          },
          config: const PropertyConfig(seed: 3));
      expect(lens.every((n) => n >= 2 && n <= 7), isTrue);
      expect(_fails(G.listOf(G.intIn(0, 9), minLen: 2, maxLen: 7), (_) => false)
          .input, '[0, 0]');
    });

    test('the size cap holds across all generated cases', () {
      final seen = _inputs(G.listOf(G.boolean(), maxLen: 60), cases: 200);
      expect(seen.map((l) => l.length).reduce(math.max), 60,
          reason: 'the cap itself is reached');
      expect(seen.every((l) => l.length <= 60), isTrue);
    });

    test('tuple components shrink TOGETHER when only a joint step still fails',
        () {
      // Fails only while a and b are within 3 of each other and a >= 5: moving
      // ONE component far breaks the closeness, so only a joint step makes
      // progress.
      final f = _fails(G.pair(G.intIn(0, 1000), G.intIn(0, 1000)),
          (p) => !((p.$1 - p.$2).abs() <= 3 && p.$1 >= 5),
          cases: 2000, seed: 5);
      final nums = RegExp(r'\d+').allMatches(f.input).map((m) => int.parse(m[0]!));
      final (a, b) = (nums.first, nums.last);
      expect((a - b).abs(), lessThanOrEqualTo(3));
      expect(a, lessThanOrEqualTo(12), reason: f.input);
    });

    test('a triple and a quad shrink every component', () {
      expect(
          _fails(G.triple(G.intIn(0, 9), G.intIn(-9, 9), G.boolean()),
                  (_) => false)
              .input,
          '(0, 0, false)');
      expect(
          _fails(
                  G.quad(G.intIn(0, 9), G.doubleIn(0, 1), G.boolean(),
                      G.elements(const ['x', 'y'])),
                  (_) => false)
              .input,
          '(0, 0.0, false, x)');
    });

    test('a nullable shrinks to null first', () {
      expect(_fails(G.nullable(G.intIn(5, 9)), (_) => false).input, 'null');
      expect(
          _fails(G.nullable(G.intIn(5, 9), nullProbability: 0),
                  (v) => v == null || v < 7)
              .input,
          '7');
    });

    test('a list and an int inside a tuple each shrink to their own minimum',
        () {
      final f = _fails(
          G.pair(G.listOf(G.intIn(0, 9), minLen: 1, maxLen: 12), G.intIn(0, 11)),
          (p) => !(p.$1.length >= 6 && p.$2 >= 4));
      expect(f.input, '([0, 0, 0, 0, 0, 0], 4)');
    });
  });

  group('shrink bound', () {
    test('the shrink limit caps the extra body runs', () {
      var calls = 0;
      final r = runProperty<List<int>>(
          name: 'limit',
          gen: G.listOf(G.intIn(0, 1000), minLen: 40, maxLen: 50),
          body: (_) {
            calls++;
            throw StateError('always');
          },
          config: const PropertyConfig(seed: 3, shrinkLimit: 5));
      expect(r.passed, isFalse);
      expect(calls, lessThanOrEqualTo(1 + 5));
      expect(r.failure!.shrinkSteps, lessThanOrEqualTo(5));
      expect(r.failure!.report, contains('shrink limit: 5'));
    });

    test('with a limit of zero the original input is reported', () {
      final f = _fails(G.intIn(500, 1000), (_) => false, shrinkLimit: 0);
      expect(f.shrinkSteps, 0);
      expect(int.parse(f.input), inInclusiveRange(500, 1000));
    });

    test('the report shows the original input when shrinking changed it', () {
      final f = _fails(G.intIn(0, 1000), (v) => v < 50, seed: 8);
      expect(f.report, contains('original input'));
      final z = _fails(G.intIn(0, 1000), (_) => false, examples: [0]);
      expect(z.report, isNot(contains('original input')));
    });
  });

  group('wall budget', () {
    test('PROPERTY_BUDGET_MS is the hard limit over a property\'s looser default',
        () {
      // A law registers a 5 s in-test guard (headroom for a loaded parallel
      // suite); the serial acceptance run sets PROPERTY_BUDGET_MS=2000 and
      // that must be what fails a property, not the 5 s default.
      final c = PropertyConfig.fromEnvironment(
        const {'PROPERTY_BUDGET_MS': '2000'},
        defaultBudget: const Duration(seconds: 5),
      );
      expect(c.budget, const Duration(milliseconds: 2000));
      var ticks = 0;
      final r = runProperty<int>(
        name: 'serial acceptance',
        gen: G.intIn(0, 9),
        body: (_) {},
        config: c,
        // 1 s per reading: over 2 s on the third, well inside the 5 s default.
        elapsed: () => Duration(seconds: ticks++),
      );
      expect(r.failure!.kind, FailureKind.budget);
      expect(r.failure!.report, contains('2000 ms'));
    });

    test('a property over its budget fails, naming budget and cases run', () {
      var ticks = 0;
      final r = runProperty<int>(
        name: 'slow',
        gen: G.intIn(0, 9),
        body: (_) {},
        config: const PropertyConfig(seed: 1, cases: 200),
        elapsed: () => Duration(milliseconds: 500 * ticks++),
      );
      expect(r.failure!.kind, FailureKind.budget);
      expect(r.casesRun, lessThan(200));
      expect(r.failure!.report, contains('2000 ms'));
      expect(r.failure!.report, contains('budget'));
    });

    test('shrinking counts against the budget and reports the best so far', () {
      // The clock reads past the budget after the 6th reading: the failure at
      // case 0 is found, shrinking gets a few attempts, then stops.
      var reads = 0;
      final r = runProperty<List<int>>(
        name: 'slow shrink',
        gen: G.listOf(G.intIn(0, 1000), minLen: 40, maxLen: 50),
        body: (_) => throw StateError('always'),
        config: const PropertyConfig(seed: 1),
        elapsed: () => Duration(milliseconds: 500 * reads++),
      );
      final f = r.failure!;
      expect(f.kind, FailureKind.counterexample);
      expect(f.shrinkOverBudget, isTrue);
      expect(f.report, contains('over budget (shrinking)'));
      expect(f.shrinkSteps, lessThanOrEqualTo(6),
          reason: 'unbudgeted, this shrink takes dozens of runs');
      // The best-so-far input is still a valid, failing input of the domain.
      final len = RegExp(', ').allMatches(f.input).length + 1;
      expect(len, inInclusiveRange(40, 50));
    });

    test('shrinking inside the budget is not marked', () {
      final r = runProperty<int>(
        name: 'quick shrink',
        gen: G.intIn(500, 1000),
        body: (_) => throw StateError('always'),
        config: const PropertyConfig(seed: 1),
        elapsed: () => const Duration(milliseconds: 1),
      );
      expect(r.failure!.shrinkOverBudget, isFalse);
      expect(r.failure!.report, isNot(contains('over budget')));
      expect(r.failure!.input, '500');
    });

    test('a single-case replay keeps shrinking whatever the clock says', () {
      final r = runProperty<int>(
        name: 'replay shrink',
        gen: G.intIn(500, 1000),
        body: (_) => throw StateError('always'),
        config: const PropertyConfig(seed: 1, caseOnly: '0'),
        elapsed: () => const Duration(hours: 1),
      );
      expect(r.failure!.shrinkOverBudget, isFalse);
      expect(r.failure!.input, '500');
    });

    test('a property inside its budget passes', () {
      final r = runProperty<int>(
        name: 'fast',
        gen: G.intIn(0, 9),
        body: (_) {},
        config: const PropertyConfig(seed: 1, cases: 20),
        elapsed: () => const Duration(milliseconds: 5),
      );
      expect(r.passed, isTrue);
    });

    test('a counterexample is reported before the budget', () {
      final r = runProperty<int>(
        name: 'both',
        gen: G.intIn(0, 9),
        body: (_) => throw StateError('x'),
        config: const PropertyConfig(seed: 1),
        elapsed: () => const Duration(hours: 1),
      );
      expect(r.failure!.kind, FailureKind.counterexample);
    });

    test('the default clock is a real stopwatch', () {
      final r = runProperty<int>(
        name: 'spin',
        gen: G.intIn(0, 9),
        body: (_) {
          final sw = Stopwatch()..start();
          while (sw.elapsedMilliseconds < 4) {}
        },
        config: const PropertyConfig(
            seed: 1, cases: 50, budget: Duration(milliseconds: 1)),
      );
      expect(r.failure?.kind, FailureKind.budget);
    });

    test('a single-case replay is not held to the budget', () {
      final r = runProperty<int>(
        name: 'replay',
        gen: G.intIn(0, 9),
        body: (_) {},
        config: const PropertyConfig(seed: 1, caseOnly: '3'),
        elapsed: () => const Duration(hours: 1),
      );
      expect(r.passed, isTrue);
    });
  });

  group('forAll', () {
    var ran = 0;
    forAll<int>('self: forAll runs examples and generated cases',
        G.intIn(0, 100), (v) {
      ran++;
      expect(v >= 0 && v <= 100, isTrue);
    }, examples: const [0, 100], cases: 25);

    test('forAll ran its forced examples plus its cases', () {
      expect(ran, anyOf(0, 27),
          reason: '0 when this test alone is selected by name');
    });

    forAll<(int, int)>('self: addition commutes', G.pair(G.intIn(-99, 99), G.intIn(-99, 99)),
        (p) => expect(p.$1 + p.$2, p.$2 + p.$1));
  });
}

class _Boom extends Gen<int> {
  @override
  int generate(Rng r, int size) => throw StateError('boom');
  @override
  Iterable<int> shrink(int v) => const [];
}
