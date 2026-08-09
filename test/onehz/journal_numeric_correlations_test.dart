// Numeric journal fields — Spearman rank correlation against outcome series.
//
// The tag path can only ask "were the tagged days different?". A field that
// carries a dose (three coffees, 700 ml, mood 4/5) needs a statistic that can
// tell one coffee from five, and it has to refuse to answer far more often
// than a difference-of-means does: a correlation over a handful of days is
// close to meaningless, and that is exactly when it looks most convincing.

import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

List<String> _dates(int n) => [
  for (var i = 1; i <= n; i++) '2026-01-${i.toString().padLeft(2, '0')}',
];

/// One field over [values], aligned to `_dates(values.length)`.
List<JournalNumericDay> _days(String field, List<double?> values) => [
  for (var i = 0; i < values.length; i++)
    JournalNumericDay(
      _dates(values.length)[i],
      values[i] == null ? const {} : {field: values[i]!},
    ),
];

JournalNumericEffect _effect(
  List<JournalNumericCorrelation> out,
  String field,
  String outcome,
) => out.firstWhere((e) => e.field == field).effects.firstWhere(
  (e) => e.outcome == outcome,
);

void main() {
  group('spearmanRho', () {
    test('is 1 for any increasing relationship, however curved', () {
      // The point of ranks: this is not linear, and Pearson would not say 1.
      expect(
        spearmanRho([1, 2, 3, 4, 5], [1, 4, 9, 16, 25]),
        closeTo(1.0, 1e-12),
      );
    });

    test('is -1 for a decreasing relationship', () {
      expect(spearmanRho([1, 2, 3, 4], [9, 7, 5, 1]), closeTo(-1.0, 1e-12));
    });

    test('handles ties by sharing the mean rank', () {
      // Journal fields are full of ties — mood is 1..5 and most days carry the
      // same 2 coffees. Ranking ties arbitrarily would invent an order the
      // user never reported.
      expect(spearmanRho([1, 2, 2, 3], [1, 2, 2, 3]), closeTo(1.0, 1e-12));
      expect(spearmanRho([1, 2, 2, 3], [3, 2, 2, 1]), closeTo(-1.0, 1e-12));
    });

    test('is null when either side never varies', () {
      expect(spearmanRho([2, 2, 2, 2], [1, 2, 3, 4]), isNull);
      expect(spearmanRho([1, 2, 3, 4], [5, 5, 5, 5]), isNull);
    });

    test('is null below two points', () {
      expect(spearmanRho([1], [2]), isNull);
      expect(spearmanRho(const [], const []), isNull);
    });
  });

  group('journalNumericCorrelations', () {
    test('finds a strong monotone relationship and signs it correctly', () {
      final dates = _dates(12);
      final caffeine = <double>[1, 2, 3, 4, 5, 6, 1, 2, 3, 4, 5, 6];
      final rmssd = [for (final c in caffeine) 80.0 - 6 * c];
      final out = journalNumericCorrelations(
        journal: [
          for (var i = 0; i < dates.length; i++)
            JournalNumericDay(dates[i], {'caffeine': caffeine[i]}),
        ],
        dates: dates,
        outcomes: {'rmssd': rmssd},
      );

      final e = _effect(out, 'caffeine', 'rmssd');
      expect(e.insufficient, isFalse);
      expect(e.meaningful, isTrue);
      expect(e.rho, closeTo(-1.0, 1e-9));
      expect(e.n, 12);
      // The interpretable half: ms of RMSSD per extra coffee, in the outcome's
      // own units rather than standardized.
      expect(e.slopePerUnit, closeTo(-6.0, 1e-9));
      expect(e.rhoHigh, isNotNull);
      expect(e.rhoHigh!, lessThan(0), reason: 'the CI must exclude zero');
    });

    test('refuses to answer below the paired-day floor', () {
      // A perfect correlation over 5 days is a small-sample artefact. It must
      // not surface as a finding just because rho happens to be 1.
      final dates = _dates(5);
      final out = journalNumericCorrelations(
        journal: [
          for (var i = 0; i < 5; i++)
            JournalNumericDay(dates[i], {'water': (i + 1).toDouble()}),
        ],
        dates: dates,
        outcomes: {'readiness': [for (var i = 0; i < 5; i++) 50.0 + i]},
      );
      final e = _effect(out, 'water', 'readiness');
      expect(e.insufficient, isTrue);
      expect(e.meaningful, isFalse);
      expect(e.rho, isNull);
      expect(e.n, 5);
    });

    test('a missing field is excluded pairwise, never read as zero', () {
      // "I did not fill in the caffeine field" is not "I had no caffeine".
      // Reading the second for the first invents a point at the bottom of the
      // dose range, which is where a correlation is most sensitive.
      final dates = _dates(10);
      final logged = <double?>[3, null, 3, null, 3, null, 3, null, 3, null];
      final out = journalNumericCorrelations(
        journal: [
          for (var i = 0; i < dates.length; i++)
            JournalNumericDay(
              dates[i],
              logged[i] == null ? const {} : {'caffeine': logged[i]!},
            ),
        ],
        dates: dates,
        outcomes: {'rmssd': [for (var i = 0; i < 10; i++) 60.0 + i]},
      );
      final e = _effect(out, 'caffeine', 'rmssd');
      expect(e.n, 5, reason: 'only the days the field was actually recorded');
      expect(
        e.insufficient,
        isTrue,
        reason: 'five paired days is below the floor, and a constant field '
            'has no spread to correlate anyway',
      );
    });

    test('a missing outcome day is excluded pairwise too', () {
      final dates = _dates(12);
      final out = journalNumericCorrelations(
        journal: _days('mood', [
          for (var i = 0; i < 12; i++) (i % 5 + 1).toDouble(),
        ]),
        dates: dates,
        outcomes: {
          'readiness': [
            for (var i = 0; i < 12; i++) i.isEven ? null : 50.0 + i,
          ],
        },
      );
      expect(_effect(out, 'mood', 'readiness').n, 6);
    });

    test('noise does not become a finding', () {
      // A field that wanders independently of the outcome must come back not
      // meaningful — the confidence interval straddles zero.
      final dates = _dates(20);
      const field = <double>[4, 1, 3, 2, 5, 3, 1, 4, 2, 5,
                             3, 2, 4, 1, 5, 2, 3, 4, 1, 5];
      // The same twenty outcome values, permuted to a rank correlation of
      // exactly 0 against the field above — so this test fails if the gate
      // ever starts calling an unrelated field a finding.
      const outcome = <double?>[53, 47, 50, 49, 49, 51, 49, 48, 51, 50,
                                52, 52, 48, 52, 47, 53, 51, 50, 48, 53];
      final out = journalNumericCorrelations(
        journal: [
          for (var i = 0; i < dates.length; i++)
            JournalNumericDay(dates[i], {'screens': field[i]}),
        ],
        dates: dates,
        outcomes: {'readiness': outcome},
      );
      final e = _effect(out, 'screens', 'readiness');
      expect(e.insufficient, isFalse);
      expect(e.meaningful, isFalse);
      expect(e.rho!.abs(), lessThan(0.2));
      expect(
        e.rhoLow!,
        lessThan(0),
        reason: 'the interval must straddle zero, which is what makes it '
            'not a finding',
      );
      expect(e.rhoHigh!, greaterThan(0));
    });

    test('a misaligned outcome series is reported, not truncated or thrown', () {
      final dates = _dates(10);
      final out = journalNumericCorrelations(
        journal: _days('water', [for (var i = 0; i < 10; i++) i.toDouble()]),
        dates: dates,
        outcomes: {'rhr': const [50.0, 51.0]},
      );
      final e = _effect(out, 'water', 'rhr');
      expect(e.insufficient, isTrue);
      expect(e.n, 0);
    });

    test('a field that never varies yields no verdict', () {
      final dates = _dates(14);
      final out = journalNumericCorrelations(
        journal: _days('water', [for (var i = 0; i < 14; i++) 2.0]),
        dates: dates,
        outcomes: {'readiness': [for (var i = 0; i < 14; i++) 50.0 + i]},
      );
      final e = _effect(out, 'water', 'readiness');
      expect(e.insufficient, isTrue);
      expect(e.rho, isNull);
    });

    test('fields come back sorted, and every field sees every outcome', () {
      final dates = _dates(10);
      final out = journalNumericCorrelations(
        journal: [
          for (var i = 0; i < dates.length; i++)
            JournalNumericDay(dates[i], {
              'water': i.toDouble(),
              'caffeine': (10 - i).toDouble(),
            }),
        ],
        dates: dates,
        outcomes: {
          'rmssd': [for (var i = 0; i < 10; i++) 60.0 + i],
          'rhr': [for (var i = 0; i < 10; i++) 50.0 - i],
        },
      );
      expect(out.map((e) => e.field), ['caffeine', 'water']);
      for (final f in out) {
        expect(f.effects.map((e) => e.outcome).toSet(), {'rmssd', 'rhr'});
      }
    });

    test('a perfect correlation still widens its interval on few days', () {
      // rho saturates at exactly -1 the moment a field moves monotonically
      // with an outcome, which happens easily. Abstaining there would discard
      // the strongest evidence there is; claiming near-certainty from eight
      // days would be the opposite mistake. The interval excludes zero either
      // way, but it must be visibly wider on the smaller sample.
      List<JournalNumericEffect> run(int n) {
        final dates = _dates(n);
        return journalNumericCorrelations(
          journal: [
            for (var i = 0; i < n; i++)
              JournalNumericDay(dates[i], {'caffeine': i.toDouble()}),
          ],
          dates: dates,
          outcomes: {'rmssd': [for (var i = 0; i < n; i++) 90.0 - 5 * i]},
        ).single.effects;
      }

      final small = run(8).single;
      final large = run(40).single;
      expect(small.rho, closeTo(-1.0, 1e-9));
      expect(large.rho, closeTo(-1.0, 1e-9));
      expect(small.meaningful, isTrue);
      expect(large.meaningful, isTrue);
      expect(
        small.rhoHigh!,
        greaterThan(large.rhoHigh!),
        reason: 'eight days must not claim the confidence of forty',
      );
      expect(small.rhoHigh!, lessThan(0), reason: 'still excludes zero');
    });

    test('empty input is empty output, not a crash', () {
      expect(
        journalNumericCorrelations(
          journal: const [],
          dates: const [],
          outcomes: const {},
        ),
        isEmpty,
      );
    });
  });
}
