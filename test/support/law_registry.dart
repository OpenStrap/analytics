// LAW REGISTRY — every law states which situations its default cases must
// reach, and one test per file measures that (design 05, generator reach).
//
// A property that never meets the situation it claims to cover is a green test
// that checks nothing. So each law is registered with a [Reach]: named
// situations, each with a share of the law's default case count it must reach,
// and an observer that names the situations of one input WITHOUT running the
// code under test (the situations come from the generator's model). The reach
// test re-draws the law's default cases (the forced examples are not counted:
// they are the part that is hand-placed) and fails when a share is not met.
//
// PROPERTY_REACH_REPORT=1 prints what each law reached, to retune the shares
// after a generator change.
//
//   final laws = LawSet();
//   laws.law<T>('L1 ...', gen, body, reach: Reach<T>({...}, observe));
//   laws.registerReachTest();   // once, last in main()

import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:test/test.dart';

import 'property.dart';

/// What a law's default cases must reach.
class Reach<T> {
  const Reach(this.shares, this.observe);

  /// Situation name -> share of the default case count it must reach
  /// (need = max(1, floor(cases * share))).
  final Map<String, double> shares;

  /// Names the situations of one input by calling `bump('name')`.
  final void Function(T arg, void Function(String) bump) observe;
}

class _Registered {
  _Registered(this.name, this.cases, this.shares, this.measure);
  final String name;
  final int cases;
  final Map<String, double> shares;
  final Map<String, int> Function() measure;
}

class LawSet {
  final List<_Registered> _registry = [];

  /// Number of registered laws.
  int get length => _registry.length;

  /// Registers [name] as a property (forced [examples] first, then [cases]
  /// generated ones) and records its reach.
  void law<T>(
    String name,
    Gen<T> gen,
    void Function(T) body, {
    required Reach<T> reach,
    List<T> examples = const [],
    int cases = 30,
    String genVersion = 'g1',
    Duration? budget,
    Object? skip,
  }) {
    _registry.add(_Registered(name, cases, reach.shares, () {
      final got = <String, int>{for (final k in reach.shares.keys) k: 0};
      final r = runProperty<T>(
        name: name,
        gen: gen,
        config: PropertyConfig(
            cases: cases,
            // A generous guard, but PROPERTY_BUDGET_MS (the serial acceptance
            // run) is the hard limit here too: drawing a law's cases is cheap.
            budget: Duration(
                milliseconds: int.tryParse(
                        Platform.environment['PROPERTY_BUDGET_MS'] ?? '') ??
                    60000)),
        body: (v) => reach.observe(v, (k) => got[k] = (got[k] ?? 0) + 1),
        genVersion: genVersion,
      );
      if (!r.passed) fail(r.failure!.report);
      return got;
    }));
    forAll<T>(name, gen, body,
        examples: examples,
        cases: cases,
        genVersion: genVersion,
        // The spec's cap is 2 s per property, measured serially on the dev
        // desktop. The in-test guard that fails a runaway has 2.5x headroom on
        // top, so a suite running 12 test files at once does not trip it.
        // PROPERTY_BUDGET_MS replaces it as the HARD limit (see
        // PropertyConfig.fromEnvironment): the acceptance run is
        //   PROPERTY_BUDGET_MS=2000 dart test -j 1 test/properties/
        // and any property over 2 s there fails the run.
        budget: budget ?? const Duration(seconds: 5),
        skip: skip);
  }

  /// The test that every law's default cases reach what the law claims.
  void registerReachTest() {
    group('generator reach', () {
      test('every law sees every situation in its default cases', () {
        expect(_registry, isNotEmpty);
        final weak = <String>[];
        for (final law in _registry) {
          final got = law.measure();
          if (Platform.environment.containsKey('PROPERTY_REACH_REPORT')) {
            // ignore: avoid_print
            print('REACH ${law.name.split(' ').first}/${law.cases} cases: '
                '${got.entries.map((e) => "${e.key}=${e.value}").join("; ")}');
          }
          for (final e in law.shares.entries) {
            final need = math.max(1, (law.cases * e.value).floor());
            if (got[e.key]! < need) {
              weak.add('"${law.name}": ${e.key} in ${got[e.key]} of '
                  '${law.cases} cases, need $need');
            }
          }
        }
        expect(weak, isEmpty, reason: weak.join('\n'));
      });
    });
  }
}
