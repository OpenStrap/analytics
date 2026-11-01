// PROPERTY HARNESS — seeded, shrinking, replayable property tests.
//
// Port of the edge harness (edge test/support/property.dart, design 05 pilot):
// same generators, seeds, replay and budget rules, on package:test only (this
// package is pure Dart). Keep the two in step; the RNG is pinned to reference
// outputs in property_test.dart so a replay command means the same thing in
// both repos.
//
// In-house on purpose (design 05, section 3): no dependency, fully
// deterministic, and every failure prints what is needed to replay it.
//
//   forAll('no two icons overlap', G.listOf(item, maxLen: 60), (items) {
//     ... expect(...) ...
//   }, examples: [...forced scenarios...]);
//
// How a run is built
//  • SEED. Each property has its own seed, derived from its NAME (so adding or
//    reordering properties never changes another property's inputs).
//    PROPERTY_SEED overrides it for every property in the run.
//  • CASES. Case `i` draws from its own generator stream `caseSeed(seed, i)` and
//    a size that depends on `i` only, so PROPERTY_CASE=i replays exactly that
//    input whatever the iteration count. Default 200 cases; PROPERTY_ITERATIONS
//    overrides it (and scales the wall budget with it).
//  • FORCED SCENARIOS. `examples` always run first, in order, before any
//    generated case. They are never shrunk (they are explicit). Replay one with
//    PROPERTY_CASE=forced:<index>.
//  • FAILURE. The first failing input is shrunk (bounded by `shrinkLimit` body
//    runs) and printed with seed, case, generator version and a one-line replay
//    command. Shrinkers are domain-preserving: a candidate is always something
//    the generator itself could have produced.
//  • BUDGET. A property that takes longer than its wall budget (default 2 s)
//    fails. Shrinking counts against the same budget: when it runs out the
//    best failing input so far is reported, marked "over budget (shrinking)". The budget is the ONLY
//    use of a real clock; it is injectable for the harness's own tests.
//
// GENERATOR VERSION. A seed only means something for the generator that drew
// it. When a property's generator changes shape, bump its `genVersion`; the
// report prints it so an old replay command is recognised as stale.
//
// Environment: PROPERTY_SEED, PROPERTY_CASE, PROPERTY_ITERATIONS,
// PROPERTY_BUDGET_MS (fixes the budget, no scaling).

import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:test/test.dart';

// ── randomness ──────────────────────────────────────────────────────────────

/// True on dart2js, where `1` and `1.0` are the same value.
const bool _onJs = identical(1, 1.0);

/// splitmix64 (Steele, Lea, Flood; the public-domain reference generator):
/// tiny, fast, and identical on every Dart VM version (unlike `dart:math`
/// Random, whose stream is not promised to be stable). The first outputs for
/// seeds 0 and 1234567 are pinned in property_test.dart against values computed
/// independently.
///
/// ASSUMPTION: a Dart VM `int` is a 64-bit two's-complement integer whose `+`
/// and `*` wrap, and `>>>` is a logical shift. That is what the arithmetic
/// below relies on. This harness is VM-only and must not be compiled for the
/// web (ints are doubles there); the constructor refuses to run on JS.
class Rng {
  Rng(int seed) : _s = seed {
    if (_onJs) {
      throw UnsupportedError('test/support/property.dart needs 64-bit VM ints');
    }
  }
  int _s;

  static const int _gamma = 0x9E3779B97F4A7C15;

  static int mix(int x) {
    var z = x;
    z = (z ^ (z >>> 30)) * 0xBF58476D1CE4E5B9;
    z = (z ^ (z >>> 27)) * 0x94D049BB133111EB;
    return z ^ (z >>> 31);
  }

  int _next() {
    _s += _gamma;
    return mix(_s);
  }

  /// The next raw 64-bit output (a signed Dart int; same bits as the
  /// reference's unsigned value).
  int next64() => _next();

  /// A uniform int in `[0, bound)`. `bound` must be in `1 .. 2^53`.
  int nextInt(int bound) {
    assert(bound > 0 && bound <= (1 << 53), 'bound out of range: $bound');
    return (_next() >>> 1) % bound;
  }

  /// A uniform int in `[min, max]`, both inclusive.
  int intIn(int min, int max) {
    assert(min <= max);
    return min + nextInt(max - min + 1);
  }

  /// A uniform double in `[0, 1)`.
  double nextDouble() => (_next() >>> 11) / 9007199254740992.0;

  /// True with probability [p].
  bool nextBool([double p = .5]) => nextDouble() < p;
}

/// The default seed of the property called [name] (32-bit FNV-1a).
int seedFor(String name) {
  var h = 0x811C9DC5;
  for (final u in name.codeUnits) {
    h = ((h ^ u) * 0x01000193) & 0xFFFFFFFF;
  }
  return h;
}

/// The generator stream of case [index] of a property seeded [seed]. Depends on
/// nothing else, so one case can be replayed alone.
int caseSeed(int seed, int index) =>
    Rng.mix(Rng.mix(seed) + index * 0x9E3779B97F4A7C15) & 0x7FFFFFFFFFFF;

// ── generators ──────────────────────────────────────────────────────────────

/// Draws values and shrinks them. [shrink] must only return values this
/// generator could itself have produced (domain-preserving), none equal to the
/// input, simplest first, and finitely many per call.
abstract class Gen<T> {
  const Gen();

  /// A value; [size] grows 10..100 across the cases of a run.
  T generate(Rng r, int size);

  /// Simpler candidates than [v], simplest first. May be lazy.
  Iterable<T> shrink(T v);

  /// A readable, copy-pasteable rendering for the failure report.
  String show(T v) => '$v';
}

class _IntGen extends Gen<int> {
  _IntGen(this.min, this.max, int? origin)
      : origin = (origin ?? 0).clamp(min, max).toInt() {
    assert(min <= max && max - min < (1 << 53));
  }
  final int min, max, origin;

  @override
  int generate(Rng r, int size) {
    final p = r.nextDouble();
    if (p < .06) return min;
    if (p < .12) return max;
    if (p < .16) return origin;
    return r.intIn(min, max);
  }

  @override
  Iterable<int> shrink(int v) sync* {
    if (v == origin) return;
    yield origin;
    final d = v - origin;
    var step = d ~/ 2;
    final seen = <int>{origin};
    while (step != 0) {
      final c = v - step;
      if (seen.add(c)) yield c;
      step ~/= 2;
    }
    final one = v - d.sign;
    if (seen.add(one) && one != v) yield one;
  }
}

class _DoubleGen extends Gen<double> {
  _DoubleGen(this.min, this.max, this.boundaries, this.specials, double? origin,
      this.integerBias)
      : origin = (origin ?? 0).clamp(min, max).toDouble() {
    assert(min.isFinite && max.isFinite && min <= max);
  }
  final double min, max, origin, integerBias;
  final List<double> boundaries, specials;

  List<double> get _pool => [
        min,
        max,
        if (origin != min && origin != max) origin,
        for (final b in boundaries)
          if (b >= min && b <= max) b,
      ];

  @override
  double generate(Rng r, int size) {
    final p = r.nextDouble();
    if (specials.isNotEmpty && p < .08) {
      return specials[r.nextInt(specials.length)];
    }
    if (p < .08 + .17) {
      final pool = _pool;
      return pool[r.nextInt(pool.length)];
    }
    var v = min + r.nextDouble() * (max - min);
    if (r.nextBool(integerBias)) v = v.roundToDouble();
    return v.clamp(min, max).toDouble();
  }

  @override
  Iterable<double> shrink(double v) sync* {
    if (!v.isFinite) {
      yield origin; // a special shrinks to the simplest finite value
      return;
    }
    if (v == origin) return;
    final d = v - origin;
    if (d.abs() < 1e-6) {
      yield origin;
      return;
    }
    final seen = <double>{v};
    Iterable<double> cand() sync* {
      yield origin;
      for (final b in _pool) {
        if ((b - origin).abs() < d.abs()) yield b;
      }
      yield v.truncateToDouble();
      yield v - d / 2;
      yield v - d / 4;
      yield v - d / 8;
    }

    for (final c in cand()) {
      if (c >= min && c <= max && seen.add(c)) yield c;
    }
  }
}

class _BoolGen extends Gen<bool> {
  @override
  bool generate(Rng r, int size) => r.nextBool();
  @override
  Iterable<bool> shrink(bool v) => v ? const [false] : const [];
}

class _ElementsGen<T> extends Gen<T> {
  _ElementsGen(this.values) {
    assert(values.isNotEmpty);
  }
  final List<T> values;
  @override
  T generate(Rng r, int size) => values[r.nextInt(values.length)];
  @override
  Iterable<T> shrink(T v) {
    final i = values.indexOf(v);
    return i <= 0 ? const [] : values.take(i);
  }
}

class _ListGen<T> extends Gen<List<T>> {
  _ListGen(this.elem, this.minLen, this.maxLen) {
    assert(minLen >= 0 && minLen <= maxLen);
  }
  final Gen<T> elem;
  final int minLen, maxLen;

  @override
  List<T> generate(Rng r, int size) {
    final cap = minLen + ((maxLen - minLen) * (size + 1) / 101).ceil();
    final p = r.nextDouble();
    final n = p < .08
        ? minLen
        : p < .16
            ? maxLen
            : r.intIn(minLen, math.max(minLen, cap));
    return [for (var i = 0; i < n; i++) elem.generate(r, size)];
  }

  @override
  Iterable<List<T>> shrink(List<T> v) sync* {
    // Shorter first: drop chunks, big to small.
    if (v.length > minLen) {
      for (var chunk = math.max(1, v.length ~/ 2); chunk >= 1; chunk ~/= 2) {
        if (v.length - chunk < minLen) continue;
        for (var at = 0; at + chunk <= v.length; at += chunk) {
          yield [...v.sublist(0, at), ...v.sublist(at + chunk)];
        }
      }
    }
    // Then simpler elements, in place.
    for (var i = 0; i < v.length; i++) {
      for (final e in elem.shrink(v[i])) {
        yield [...v.sublist(0, i), e, ...v.sublist(i + 1)];
      }
    }
  }

  @override
  String show(List<T> v) => '[${v.map(elem.show).join(', ')}]';
}

class _NullableGen<T> extends Gen<T?> {
  _NullableGen(this.inner, this.nullProbability);
  final Gen<T> inner;
  final double nullProbability;
  @override
  T? generate(Rng r, int size) =>
      r.nextBool(nullProbability) ? null : inner.generate(r, size);
  @override
  Iterable<T?> shrink(T? v) sync* {
    if (v == null) return;
    yield null;
    yield* inner.shrink(v);
  }

  @override
  String show(T? v) => v == null ? 'null' : inner.show(v);
}

/// Candidate lists of the components of a tuple, shrunk SEPARATELY and then
/// TOGETHER (the k-th simpler candidate of every component at once), so a law
/// that only fails on correlated components (a == b) still shrinks.
Iterable<List<Object?>> _shrinkTuple(
    List<Gen<Object?>> gens, List<Object?> v) sync* {
  final cands = [
    for (var i = 0; i < gens.length; i++) gens[i].shrink(v[i]).take(12).toList()
  ];
  // Joint steps first: they make the biggest strides and are the only ones
  // that work when the components are correlated.
  final joint = cands.map((c) => c.length).reduce(math.min);
  for (var k = 0; k < joint; k++) {
    yield [for (final c in cands) c[k]];
  }
  for (var i = 0; i < gens.length; i++) {
    for (final c in gens[i].shrink(v[i])) {
      yield [...v.sublist(0, i), c, ...v.sublist(i + 1)];
    }
  }
}

class _TupleGen<R> extends Gen<R> {
  _TupleGen(this.gens, this.build, this.parts);
  final List<Gen<Object?>> gens;
  final R Function(List<Object?>) build;
  final List<Object?> Function(R) parts;

  @override
  R generate(Rng r, int size) =>
      build([for (final g in gens) g.generate(r, size)]);
  @override
  Iterable<R> shrink(R v) => _shrinkTuple(gens, parts(v)).map(build);
  @override
  String show(R v) {
    final p = parts(v);
    return '(${[for (var i = 0; i < gens.length; i++) gens[i].show(p[i])].join(', ')})';
  }
}

/// The generator constructors.
abstract final class G {
  /// An int in `[min, max]`; shrinks toward [origin] (default: zero, or the
  /// bound nearest zero).
  static Gen<int> intIn(int min, int max, {int? origin}) =>
      _IntGen(min, max, origin);

  /// A double in `[min, max]` (finite). [boundaries] are drawn deliberately;
  /// [specials] (NaN, infinities) are drawn occasionally and shrink to
  /// [origin]. [integerBias] is the share of draws snapped to whole numbers
  /// (ties and exact thresholds are where the interesting laws bend).
  static Gen<double> doubleIn(double min, double max,
          {List<double> boundaries = const [],
          List<double> specials = const [],
          double? origin,
          double integerBias = .25}) =>
      _DoubleGen(min, max, boundaries, specials, origin, integerBias);

  static Gen<bool> boolean() => _BoolGen();

  /// One of [values]; shrinks toward the earlier ones.
  static Gen<T> elements<T>(List<T> values) => _ElementsGen(values);

  /// A list of `minLen .. maxLen` elements (the cap is a hard bound).
  static Gen<List<T>> listOf<T>(Gen<T> elem,
          {int minLen = 0, required int maxLen}) =>
      _ListGen(elem, minLen, maxLen);

  static Gen<T?> nullable<T>(Gen<T> inner, {double nullProbability = .25}) =>
      _NullableGen(inner, nullProbability);

  static Gen<(A, B)> pair<A, B>(Gen<A> a, Gen<B> b) => _TupleGen(
      [a, b], (p) => (p[0] as A, p[1] as B), (r) => [r.$1, r.$2]);

  static Gen<(A, B, C)> triple<A, B, C>(Gen<A> a, Gen<B> b, Gen<C> c) =>
      _TupleGen([a, b, c], (p) => (p[0] as A, p[1] as B, p[2] as C),
          (r) => [r.$1, r.$2, r.$3]);

  static Gen<(A, B, C, D)> quad<A, B, C, D>(
          Gen<A> a, Gen<B> b, Gen<C> c, Gen<D> d) =>
      _TupleGen(
          [a, b, c, d],
          (p) => (p[0] as A, p[1] as B, p[2] as C, p[3] as D),
          (r) => [r.$1, r.$2, r.$3, r.$4]);
}

// ── configuration and result ────────────────────────────────────────────────

class PropertyConfig {
  const PropertyConfig({
    this.seed,
    this.cases = 200,
    this.caseOnly,
    this.budget = const Duration(seconds: 2),
    this.shrinkLimit = 300,
    this.testFile,
  });

  /// Reads PROPERTY_SEED / PROPERTY_CASE / PROPERTY_ITERATIONS /
  /// PROPERTY_BUDGET_MS from [env]. A malformed value throws: a typo must not
  /// silently run the default.
  factory PropertyConfig.fromEnvironment(
    Map<String, String> env, {
    String? testFile,
    int? seed,
    int defaultCases = 200,
    Duration defaultBudget = const Duration(seconds: 2),
    int shrinkLimit = 300,
  }) {
    int? number(String key, {int min = 0}) {
      final raw = env[key];
      if (raw == null || raw.isEmpty) return null;
      final n = int.tryParse(raw);
      if (n == null || n < min) {
        throw FormatException('$key must be an integer >= $min', raw);
      }
      return n;
    }

    final envSeed = number('PROPERTY_SEED', min: -(1 << 62));
    final iterations = number('PROPERTY_ITERATIONS', min: 1);
    final budgetMs = number('PROPERTY_BUDGET_MS', min: 1);
    final caseRaw = env['PROPERTY_CASE'];
    if (caseRaw != null &&
        caseRaw.isNotEmpty &&
        !RegExp(r'^(forced:)?\d+$').hasMatch(caseRaw)) {
      throw FormatException('PROPERTY_CASE must be N or forced:N', caseRaw);
    }
    final cases = iterations ?? defaultCases;
    final scale = math.max(1.0, cases / defaultCases);
    return PropertyConfig(
      seed: envSeed ?? seed,
      cases: cases,
      caseOnly: caseRaw == null || caseRaw.isEmpty ? null : caseRaw,
      budget: budgetMs != null
          ? Duration(milliseconds: budgetMs)
          : iterations != null
              ? Duration(
                  milliseconds: (defaultBudget.inMilliseconds * scale).round())
              : defaultBudget,
      shrinkLimit: shrinkLimit,
      testFile: testFile,
    );
  }

  /// null: derived from the property name.
  final int? seed;
  final int cases;

  /// Replay only this case: `N` or `forced:N`. null: the whole run.
  final String? caseOnly;
  final Duration budget;

  /// Most body runs spent shrinking one failure.
  final int shrinkLimit;

  /// Repo-relative path printed in the replay command.
  final String? testFile;
}

enum FailureKind { counterexample, forcedExample, budget, generator }

class PropertyFailure {
  const PropertyFailure({
    required this.kind,
    required this.seed,
    required this.caseId,
    required this.input,
    required this.error,
    required this.replay,
    required this.shrinkSteps,
    required this.report,
    this.shrinkOverBudget = false,
  });
  final FailureKind kind;
  final int seed;

  /// `17` for a generated case, `forced:1` for an explicit example.
  final String caseId;

  /// The (shrunk) failing input, as the generator shows it.
  final String input;
  final String error;
  final String replay;

  /// Body runs spent shrinking.
  final int shrinkSteps;
  final String report;

  /// Shrinking stopped because the property's wall budget ran out; [input] is
  /// the best (smallest) failing input found so far, not necessarily minimal.
  final bool shrinkOverBudget;
}

class PropertyResult {
  const PropertyResult(
      {required this.casesRun, required this.forcedRun, this.failure});
  final int casesRun;
  final int forcedRun;
  final PropertyFailure? failure;
  bool get passed => failure == null;
}

// ── running ─────────────────────────────────────────────────────────────────

String _errorText(Object e, StackTrace st) {
  final msg = e.toString();
  final text = msg.length > 900 ? '${msg.substring(0, 900)}...' : msg;
  if (e is TestFailure) return text;
  // A non-assertion error (RangeError, StateError, ...) needs its origin.
  final frames = st.toString().split('\n').where((l) => l.isNotEmpty).take(6);
  return '$text\n    ${frames.join('\n    ')}';
}

/// Runs the property and returns the outcome; never throws for a failing body.
/// [forAll] is the test-registering wrapper.
PropertyResult runProperty<T>({
  required String name,
  required Gen<T> gen,
  required void Function(T) body,
  List<T> examples = const [],
  PropertyConfig config = const PropertyConfig(),
  String genVersion = 'g1',
  Duration Function()? elapsed,
}) {
  final seed = config.seed ?? seedFor(name);
  late final Duration Function() clock;
  if (elapsed != null) {
    clock = elapsed;
  } else {
    final sw = Stopwatch()..start();
    clock = () => sw.elapsed;
  }

  String? attempt(T v) {
    try {
      body(v);
      return null;
    } catch (e, st) {
      return _errorText(e, st);
    }
  }

  String replayFor(String? caseId) =>
      'PROPERTY_SEED=$seed ${caseId == null ? '' : 'PROPERTY_CASE=$caseId '}'
      'dart test '
      "${config.testFile ?? '<test file>'} "
      "--plain-name '${name.replaceAll("'", r"'\''")}'";

  PropertyFailure fail(FailureKind kind, String caseId, String input,
      String error,
      {int shrinkSteps = 0,
      int accepted = 0,
      String? original,
      bool overBudget = false}) {
    final replay = replayFor(kind == FailureKind.budget ? null : caseId);
    final b = StringBuffer()
      ..writeln('Property "$name" FAILED (${kind.name})')
      ..writeln('  seed: $seed   case: $caseId   generator: $genVersion'
          '   shrink limit: ${config.shrinkLimit}');
    if (kind == FailureKind.budget) {
      b.writeln('  $error');
    } else {
      b.writeln(shrinkSteps > 0
          ? '  input (shrunk: $accepted accepted of $shrinkSteps tried): $input'
          : '  input: $input');
      if (overBudget) {
        b.writeln('  over budget (shrinking): stopped after ${config.budget.inMilliseconds} '
            'ms; this is the best failing input so far, not necessarily minimal');
      }
      if (original != null && original != input) {
        b.writeln('  original input: $original');
      }
      b.writeln('  error: $error');
    }
    b.writeln('  replay: $replay');
    return PropertyFailure(
        kind: kind,
        seed: seed,
        caseId: caseId,
        input: input,
        error: error,
        replay: replay,
        shrinkSteps: shrinkSteps,
        report: b.toString(),
        shrinkOverBudget: overBudget);
  }

  PropertyFailure shrunk(String caseId, T original, String error) {
    var cur = original;
    var err = error;
    var tried = 0, accepted = 0;
    var overBudget = false;
    try {
      outer:
      while (true) {
        var progressed = false;
        for (final c in gen.shrink(cur)) {
          if (tried >= config.shrinkLimit) break outer;
          // The wall budget covers shrinking too (a replay is exempt).
          if (config.caseOnly == null && clock() > config.budget) {
            overBudget = true;
            break outer;
          }
          tried++;
          final e = attempt(c);
          if (e != null) {
            cur = c;
            err = e;
            accepted++;
            progressed = true;
            break;
          }
        }
        if (!progressed) break;
      }
    } catch (_) {
      // A shrinker that throws ends shrinking; the best input so far stands.
    }
    return fail(FailureKind.counterexample, caseId, gen.show(cur), err,
        shrinkSteps: tried,
        accepted: accepted,
        original: gen.show(original),
        overBudget: overBudget);
  }

  PropertyResult done(int cases, int forced, [PropertyFailure? f]) =>
      PropertyResult(casesRun: cases, forcedRun: forced, failure: f);

  // One generated case; returns a failure or null.
  PropertyFailure? runCase(int i) {
    final T input;
    try {
      input = gen.generate(Rng(caseSeed(seed, i)), math.min(100, 10 + i));
    } catch (e, st) {
      return fail(FailureKind.generator, '$i', '<generator threw>',
          _errorText(e, st));
    }
    final e = attempt(input);
    return e == null ? null : shrunk('$i', input, e);
  }

  PropertyFailure? runForced(int i) {
    final e = attempt(examples[i]);
    return e == null
        ? null
        : fail(FailureKind.forcedExample, 'forced:$i', gen.show(examples[i]), e);
  }

  final only = config.caseOnly;
  if (only != null) {
    if (only.startsWith('forced:')) {
      final i = int.parse(only.substring(7));
      if (i >= examples.length) {
        throw StateError('PROPERTY_CASE=$only: only ${examples.length} forced '
            'examples in "$name"');
      }
      return done(0, 1, runForced(i));
    }
    return done(1, 0, runCase(int.parse(only)));
  }

  PropertyFailure? overBudget(int cases, int forced) => clock() > config.budget
      ? fail(
          FailureKind.budget,
          'n/a',
          '',
          'wall budget ${config.budget.inMilliseconds} ms exceeded after '
              '$cases cases + $forced forced examples '
              '(${clock().inMilliseconds} ms)')
      : null;

  var forcedRun = 0, casesRun = 0;
  for (var i = 0; i < examples.length; i++) {
    final f = runForced(i);
    forcedRun++;
    if (f != null) return done(casesRun, forcedRun, f);
    final b = overBudget(casesRun, forcedRun);
    if (b != null) return done(casesRun, forcedRun, b);
  }
  for (var i = 0; i < config.cases; i++) {
    final f = runCase(i);
    casesRun++;
    if (f != null) return done(casesRun, forcedRun, f);
    final b = overBudget(casesRun, forcedRun);
    if (b != null) return done(casesRun, forcedRun, b);
  }
  return done(casesRun, forcedRun);
}

String? _callerTestFile() {
  final m = RegExp(r'test/[\w/.\-]+\.dart');
  for (final line in StackTrace.current.toString().split('\n')) {
    final hit = m.firstMatch(line)?.group(0);
    if (hit != null && !RegExp(r'support/(property|law_registry)\.dart$').hasMatch(hit)) {
      return hit;
    }
  }
  return null;
}

/// Registers one `test` that checks [body] on [examples] (forced, first) and on
/// generated cases. Replay with the command in the failure report.
///
/// [cases], [budget] and [seed] are this property's defaults; the PROPERTY_*
/// environment wins. [skip] is for a law that currently fails because of a
/// suspected bug: say which in the reason.
void forAll<T>(
  String name,
  Gen<T> gen,
  void Function(T) body, {
  List<T> examples = const [],
  int? cases,
  int? seed,
  Duration? budget,
  int? shrinkLimit,
  String genVersion = 'g1',
  Object? skip,
}) {
  final file = _callerTestFile();
  test(name, () {
    final config = PropertyConfig.fromEnvironment(
      Platform.environment,
      testFile: file,
      seed: seed,
      defaultCases: cases ?? 200,
      defaultBudget: budget ?? const Duration(seconds: 2),
      shrinkLimit: shrinkLimit ?? 300,
    );
    final r = runProperty<T>(
        name: name,
        gen: gen,
        body: body,
        examples: examples,
        config: config,
        genVersion: genVersion);
    if (!r.passed) fail(r.failure!.report);
  }, skip: skip);
}
