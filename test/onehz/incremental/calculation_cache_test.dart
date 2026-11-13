import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

void main() {
  group('CalculationCache dependencies', () {
    test('an unchanged list is a hit, a changed one recalculates', () {
      final cache = CalculationCache();
      final deps = [1, 2, 3];
      expect(cache.evaluate<int>('k', deps, () => 6), 6);
      expect(cache.evaluate<int>('k', deps, () => 99), 6);
      expect(cache.hits, 1);
      deps.add(4);
      expect(cache.evaluate<int>('k', deps, () => 10), 10);
      expect(cache.computations, 2);
    });

    test('changing a set dependency in place invalidates the entry', () {
      final cache = CalculationCache();
      final deps = <int>{1, 2};
      expect(cache.evaluate<int>('k', deps, () => 1), 1);
      deps.add(3);
      expect(cache.evaluate<int>('k', deps, () => 2), 2);
      expect(cache.computations, 2);
      // The same contents in another set instance is still a hit.
      expect(cache.evaluate<int>('k', <int>{3, 2, 1}, () => 3), 2);
      expect(cache.hits, 1);
    });

    test('a set nested in a map is snapshotted too', () {
      final cache = CalculationCache();
      final inner = <String>{'a'};
      final deps = {'tags': inner};
      expect(cache.evaluate<int>('k', deps, () => 1), 1);
      inner.add('b');
      expect(cache.evaluate<int>('k', deps, () => 2), 2);
    });

    test('a lazy iterable is refused instead of being stored by reference', () {
      final cache = CalculationCache();
      expect(
        () => cache.evaluate<int>('k', [1, 2].map((v) => v), () => 1),
        throwsArgumentError,
      );
    });
  });

  group('CalculationCache results', () {
    test('a map of boolean lists keeps its declared type', () {
      final cache = CalculationCache();
      final first = cache.evaluate<Map<String, List<bool>>>(
          'flags', null, () => {'enabled': [true]});
      expect(first, {'enabled': [true]});
      first['enabled']!.add(false);
      final second = cache.evaluate<Map<String, List<bool>>>(
          'flags', null, () => {'enabled': [false]});
      // A hit, and the caller's edit did not reach the cache.
      expect(second, {'enabled': [true]});
    });

    test('a numeric list map keeps its declared type', () {
      final cache = CalculationCache();
      final value = cache.evaluate<Map<String, List<num>>>(
          'n', null, () => {'x': <num>[1, 2.5]});
      expect(value['x'], [1, 2.5]);
    });

    test('a type the default copier cannot rebuild says so', () {
      final cache = CalculationCache();
      expect(
        () => cache.evaluate<Map<String, Set<int>>>(
            's', null, () => {'a': <int>{1}}),
        throwsA(isA<ArgumentError>()
            .having((e) => e.message, 'message', contains('copy:'))),
      );
      // A failed evaluation leaves nothing cached.
      expect(cache.computations, 0);
    });

    test('a caller supplied copier handles any result type', () {
      final cache = CalculationCache();
      Map<String, Set<int>> copy(Map<String, Set<int>> v) =>
          {for (final e in v.entries) e.key: {...e.value}};
      final first = cache.evaluate<Map<String, Set<int>>>(
          's', null, () => {'a': <int>{1}},
          copy: copy);
      first['a']!.add(2);
      final second = cache.evaluate<Map<String, Set<int>>>(
          's', null, () => {'a': <int>{9}},
          copy: copy);
      expect(second, {'a': <int>{1}});
      expect(cache.hits, 1);
    });
  });
}
