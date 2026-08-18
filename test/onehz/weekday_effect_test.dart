// MIND-12 — which day of the week costs you.
//
// The load-bearing test in this file is the FALSE-POSITIVE RATE one. Everything
// downstream of this function — a card, a copy line, a row on the circadian
// screen — is worth exactly nothing if a two-stage gate at alpha 0.05 publishes
// a "worst weekday" out of pure noise more often than about 5% of the time. If
// that test starts failing, the feature does not get retuned, it gets deleted.

import 'dart:math' as math;

import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

/// [n] consecutive real calendar dates from a Monday.
List<String> _dates(int n) {
  final start = DateTime(2026, 1, 5); // a Monday
  return [
    for (var i = 0; i < n; i++)
      () {
        final d = start.add(Duration(days: i));
        return '${d.year}-${d.month.toString().padLeft(2, '0')}'
            '-${d.day.toString().padLeft(2, '0')}';
      }(),
  ];
}

/// Box-Muller, so the noise is actually normal rather than uniform-shaped.
double _gauss(math.Random r) =>
    math.sqrt(-2 * math.log(1 - r.nextDouble())) *
    math.cos(2 * math.pi * r.nextDouble());

void main() {
  group('weekdayEffect', () {
    test('PURE NOISE clears at roughly the nominal rate', () {
      // 150 independent 12-week histories with no weekday structure at all.
      // One of the seven weekdays is always the worst — that is arithmetic, not
      // physiology — so a naive "show the worst day" publishes 150 findings
      // here. The two-stage gate has to publish about 7.
      const trials = 150;
      const days = 84; // 12 weeks
      final dates = _dates(days);
      var published = 0;
      var computed = 0;
      for (var t = 0; t < trials; t++) {
        final rng = math.Random(1000 + t);
        final m = weekdayEffect(
          dates,
          [for (var i = 0; i < days; i++) 50.0 + 8 * _gauss(rng)],
          permutations: 199,
          seed: 7 + t,
        );
        expect(m.present, isTrue, reason: '12 weeks clears the history floor');
        computed++;
        if (m.value!.meaningful) published++;
      }
      expect(computed, trials);
      final rate = published / trials;
      expect(
        rate,
        lessThanOrEqualTo(0.10),
        reason: 'a two-stage gate at alpha 0.05 publishing $published/$trials '
            'noise findings means nothing downstream is worth building',
      );
    });

    test('a real weekday shift IS detected', () {
      // Every Sunday runs 12 units low against a spread of 4 — a difference a
      // person would actually notice, over the same 12 weeks.
      const days = 84;
      final dates = _dates(days);
      final rng = math.Random(3);
      final vals = <double>[
        for (var i = 0; i < days; i++)
          50.0 +
              4 * _gauss(rng) +
              (DateTime.parse(_dates(days)[i]).weekday == DateTime.sunday
                  ? -12.0
                  : 0.0),
      ];
      final m = weekdayEffect(dates, vals, permutations: 199);
      expect(m.present, isTrue);
      final v = m.value!;
      expect(v.meaningful, isTrue);
      expect(v.peakWeekday, DateTime.sunday);
      expect(v.peakDelta, lessThan(0), reason: 'Sunday is LOW, and says so');
      expect(v.omnibusP, lessThanOrEqualTo(0.05));
      expect(v.peakP, lessThanOrEqualTo(0.05));
      expect(v.nByWeekday[DateTime.sunday], 12);
    });

    test('under eight weeks it is absent, not weak', () {
      final dates = _dates(35); // 5 weeks
      final m = weekdayEffect(
        dates,
        [for (var i = 0; i < 35; i++) 50.0 + i % 7],
      );
      expect(m.present, isFalse);
      expect(m.note, startsWith('need_history:'));
    });

    test('a weekday with too few days blocks the whole test', () {
      // 12 weeks of history, but Sundays are almost all missing. A verdict
      // about the worst weekday cannot come out of a group of two.
      const days = 84;
      final dates = _dates(days);
      final vals = <double?>[
        for (var i = 0; i < days; i++)
          (DateTime.parse(dates[i]).weekday == DateTime.sunday && i > 20)
              ? null
              : 50.0 + (i % 5),
      ];
      final m = weekdayEffect(dates, vals);
      expect(m.present, isFalse);
      expect(m.note, contains('min_per_weekday'));
    });

    test('a misaligned series is refused, not truncated', () {
      expect(
        weekdayEffect(_dates(84), const [1.0, 2.0]).present,
        isFalse,
      );
    });

    test('the same history always gives the same answer', () {
      const days = 84;
      final dates = _dates(days);
      final vals = [for (var i = 0; i < days; i++) 50.0 + (i % 11) * 0.7];
      final a = weekdayEffect(dates, vals, permutations: 199);
      final b = weekdayEffect(dates, vals, permutations: 199);
      expect(a.value!.omnibusP, b.value!.omnibusP);
      expect(a.value!.peakP, b.value!.peakP);
    });
  });
}
