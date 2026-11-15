import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

void main() {
  test('cache retains null values and distinguishes changed list order', () {
    final cache = CalculationCache();
    var calls = 0;
    Object? calculate() {
      calls++;
      return null;
    }

    expect(cache.evaluate('nullable', [1, 2, null], calculate), isNull);
    expect(cache.evaluate('nullable', [1, 2, null], calculate), isNull);
    expect(calls, 1);
    expect(cache.evaluate('nullable', [2, 1, null], calculate), isNull);
    expect(calls, 2);
    expect(cache.computations, 2);
    expect(cache.hits, 1);
  });
  test('cache protects typed lists while retaining their return type', () {
    final cache = CalculationCache();
    final original = <double>[1.25, 3.5];
    final first = cache.evaluate<List<double>>('list', 1, () => original);
    first.add(9);
    original[0] = 8;
    final next = cache.evaluate<List<double>>('list', 1, () => [100.0]);
    expect(next, [1.25, 3.5]);
    next.clear();
    expect(cache.evaluate<List<double>>('list', 1, () => [100.0]), [1.25, 3.5]);
  });
  test(
      'cache snapshots nested dependencies and deep compares maps, null and NaN',
      () {
    final cache = CalculationCache();
    final dependency = <String, Object?>{
      'hr': <Object?>[
        70.0,
        null,
        double.nan,
        <String, Object?>{'day': 1}
      ],
      'profile': <String, Object?>{'sex': 'female', 'weight': 61.0},
    };
    var calls = 0;
    int calculate() => ++calls;
    expect(cache.evaluate('load', dependency, calculate), 1);
    expect(
        cache.evaluate(
            'load',
            {
              'profile': {'weight': 61.0, 'sex': 'female'},
              'hr': [
                70.0,
                null,
                double.nan,
                {'day': 1}
              ],
            },
            calculate),
        1);
    expect(calls, 1);
    expect(cache.computations, 1);
    expect(cache.hits, 1);
    (dependency['hr'] as List)[0] = 71.0;
    expect(cache.evaluate('load', dependency, calculate), 2);
    ((dependency['hr'] as List)[3] as Map)['day'] = 2;
    expect(cache.evaluate('load', dependency, calculate), 3);
    (dependency['profile'] as Map)['sex'] = 'male';
    expect(cache.evaluate('load', dependency, calculate), 4);
    expect(cache.evaluate('load', dependency, calculate), 4);
    expect(cache.computations, 4);
    expect(cache.hits, 2);
  });
  test('cache protects mutable values on first return and subsequent hits', () {
    final cache = CalculationCache();
    final produced = <String, dynamic>{
      'nested': [
        {'value': 7}
      ],
      'values': [1, 2]
    };
    Map<String, dynamic> calculate() => produced;
    final first = cache.evaluate('nested', [1], calculate);
    (first['nested'][0] as Map)['value'] = 999;
    (produced['values'] as List).add(3);
    final second = cache.evaluate('nested', [1], calculate);
    expect(second, {
      'nested': [
        {'value': 7}
      ],
      'values': [1, 2]
    });
    (second['values'] as List).clear();
    expect(cache.evaluate('nested', [1], calculate), {
      'nested': [
        {'value': 7}
      ],
      'values': [1, 2]
    });
    expect(cache.computations, 1);
    expect(cache.hits, 2);
  });
  test(
      'cache exceptions preserve prior dependencies and do not count as computations',
      () {
    final cache = CalculationCache();
    expect(cache.evaluate('load', [1], () => 7), 7);
    expect(
        () => cache.evaluate<int>('load', [2], () => throw StateError('bad')),
        throwsStateError);
    expect(cache.computations, 1);
    expect(cache.hits, 0);
    expect(cache.evaluate('load', [1], () => 99), 7);
    expect(cache.evaluate('load', [2], () => 8), 8);
    expect(cache.computations, 2);
    expect(cache.hits, 1);
    expect(
        () => cache.evaluate<int>('load', [2], () => throw StateError('bad'),
            full: true),
        throwsStateError);
    expect(cache.evaluate('load', [2], () => 99), 8);
    expect(cache.computations, 2);
  });
  for (final mode in CalculationMode.values) {
    test('cache mode $mode controls full bypass', () {
      expect(mode.canReuse, mode == CalculationMode.periodicAwake);
      final cache = CalculationCache();
      var calls = 0;
      int calculate() => ++calls;
      expect(cache.evaluate('load', null, calculate, full: !mode.canReuse), 1);
      expect(cache.evaluate('load', null, calculate, full: !mode.canReuse),
          mode.canReuse ? 1 : 2);
      expect(cache.computations, mode.canReuse ? 1 : 2);
      expect(cache.hits, mode.canReuse ? 1 : 0);
    });
  }
  test('cache keys are isolated, full compute refreshes, clear discards values',
      () {
    final cache = CalculationCache();
    var calls = 0;
    int calculate() => ++calls;
    expect(cache.evaluate('a', null, calculate), 1);
    expect(cache.evaluate('b', null, calculate), 2);
    expect(cache.evaluate('a', null, calculate, full: true), 3);
    expect(cache.evaluate('a', null, calculate), 3);
    cache.clear();
    expect(cache.evaluate('a', null, calculate), 4);
    expect(calls, 4);
  });
  test('cache defaults to bounded 128 entries', () {
    final cache = CalculationCache();
    var calls = 0;
    for (var i = 0; i < 129; i++) {
      cache.evaluate('metric-$i', null, () => ++calls);
    }
    for (var i = 0; i < 129; i++) {
      cache.evaluate('metric-$i', null, () => ++calls);
    }
    expect(calls, greaterThan(129),
        reason: 'at least one old key must be evicted');
    expect(cache.computations, calls);
  });
  for (final capacity in [1, 3, 7]) {
    test('cache bounded capacity=$capacity does not retain every entry', () {
      final cache = CalculationCache(maxEntries: capacity);
      var calls = 0;
      for (var i = 0; i < capacity + 1; i++) {
        cache.evaluate('metric-$i', [i], () => ++calls);
      }
      for (var i = 0; i < capacity + 1; i++) {
        cache.evaluate('metric-$i', [i], () => ++calls);
      }
      expect(calls, greaterThan(capacity + 1));
    });
  }
  test('cache handles typed immutable results without encoding them as JSON',
      () {
    final cache = CalculationCache();
    const result = Metric<double>(
        value: 7, confidence: .7, tier: Tier.estimate, inputs_used: ['hr']);
    expect(cache.evaluate('metric', [1], () => result), same(result));
    expect(
        cache.evaluate<Metric<double>>(
            'metric', [1], () => throw StateError('hit')),
        same(result));
    expect(cache.computations, 1);
    expect(cache.hits, 1);
  });
}
