// Numeric journal fields — Spearman rank correlation against outcome series.
//
// The tag path can only ask "were the tagged days different?". A field that
// carries a dose (three coffees, 700 ml, mood 4/5) needs a statistic that can
// tell one coffee from five, and it has to refuse to answer far more often
// than a difference-of-means does: a correlation over a handful of days is
// close to meaningless, and that is exactly when it looks most convincing.

import 'dart:math' as math;

import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

/// [n] consecutive real calendar dates from 2026-01-01. Real ones, because a
/// naive day counter runs past 2026-01-31 and starts emitting dates that do
/// not exist — harmless while the code treats a date as an opaque key, and a
/// baffling failure the day it stops.
List<String> _dates(int n) {
  final start = DateTime(2026, 1, 1);
  return [
    for (var i = 0; i < n; i++)
      () {
        final d = start.add(Duration(days: i));
        return '${d.year}-${d.month.toString().padLeft(2, '0')}'
            '-${d.day.toString().padLeft(2, '0')}';
      }(),
  ];
}

/// One field over [values], aligned to `_dates(values.length)`.
List<JournalNumericDay> _days(String field, List<double?> values) {
  final dates = _dates(values.length);
  return [
    for (var i = 0; i < values.length; i++)
      JournalNumericDay(
        dates[i],
        values[i] == null ? const {} : {field: values[i]!},
      ),
  ];
}

JournalNumericEffect _effect(
  List<JournalNumericCorrelation> out,
  String field,
  String outcome,
) =>
    out.firstWhere((e) => e.field == field).effects.firstWhere(
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
        // MIND-02: this test is about the statistic, not the alignment.
        fieldLagDays: const {},
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
        // MIND-02: this test is about the statistic, not the alignment.
        fieldLagDays: const {},
        journal: [
          for (var i = 0; i < 5; i++)
            JournalNumericDay(dates[i], {'water': (i + 1).toDouble()}),
        ],
        dates: dates,
        outcomes: {
          'readiness': [for (var i = 0; i < 5; i++) 50.0 + i]
        },
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
        outcomes: {
          'rmssd': [for (var i = 0; i < 10; i++) 60.0 + i]
        },
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
      const field = <double>[
        4,
        1,
        3,
        2,
        5,
        3,
        1,
        4,
        2,
        5,
        3,
        2,
        4,
        1,
        5,
        2,
        3,
        4,
        1,
        5
      ];
      // The same twenty outcome values, permuted to a rank correlation of
      // exactly 0 against the field above — so this test fails if the gate
      // ever starts calling an unrelated field a finding.
      const outcome = <double?>[
        53,
        47,
        50,
        49,
        49,
        51,
        49,
        48,
        51,
        50,
        52,
        52,
        48,
        52,
        47,
        53,
        51,
        50,
        48,
        53
      ];
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

    test('a misaligned outcome series is reported, not truncated or thrown',
        () {
      final dates = _dates(10);
      final out = journalNumericCorrelations(
        journal: _days('water', [for (var i = 0; i < 10; i++) i.toDouble()]),
        dates: dates,
        outcomes: {
          'rhr': const [50.0, 51.0]
        },
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
        outcomes: {
          'readiness': [for (var i = 0; i < 14; i++) 50.0 + i]
        },
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
          // MIND-02: this test is about the statistic, not the alignment.
          fieldLagDays: const {},
          journal: [
            for (var i = 0; i < n; i++)
              JournalNumericDay(dates[i], {'caffeine': i.toDouble()}),
          ],
          dates: dates,
          outcomes: {
            'rmssd': [for (var i = 0; i < n; i++) 90.0 - 5 * i]
          },
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

    test('the strength floor and the interval gate are separate', () {
      // Both have to pass. Raising the floor above a computed rho must turn
      // meaningful off WITHOUT claiming the relationship was uncomputable —
      // "too weak to mention" and "not enough evidence" are different answers
      // and the caller may want to phrase them differently.
      final dates = _dates(30);
      final journal = [
        for (var i = 0; i < 30; i++)
          JournalNumericDay(dates[i], {'water': (i % 7).toDouble()}),
      ];
      final outcomes = {
        'readiness': <double?>[
          for (var i = 0; i < 30; i++) 50.0 + (i % 7) * 1.5 + (i % 3),
        ],
      };

      final permissive = journalNumericCorrelations(
        // MIND-02: this test is about the statistic, not the alignment.
        fieldLagDays: const {},
        journal: journal,
        dates: dates,
        outcomes: outcomes,
      ).single.effects.single;
      expect(permissive.insufficient, isFalse);
      expect(permissive.meaningful, isTrue);

      final strict = journalNumericCorrelations(
        // MIND-02: this test is about the statistic, not the alignment.
        fieldLagDays: const {},
        journal: journal,
        dates: dates,
        outcomes: outcomes,
        minAbsRho: permissive.rho!.abs() + 0.05,
      ).single.effects.single;
      expect(strict.rho, permissive.rho, reason: 'the statistic is unchanged');
      expect(strict.insufficient, isFalse, reason: 'it was computable');
      expect(strict.meaningful, isFalse, reason: 'just below the floor');
    });

    test('minN gates the statistic, the interval keeps its own n > 3 rule', () {
      final dates = _dates(5);
      final journal = [
        for (var i = 0; i < 5; i++)
          JournalNumericDay(dates[i], {'water': i.toDouble()}),
      ];
      final outcomes = {
        'readiness': <double?>[for (var i = 0; i < 5; i++) 50.0 + i],
      };

      // Default floor of 8 refuses five days outright.
      expect(
        journalNumericCorrelations(
          // MIND-02: this test is about the statistic, not the alignment.
          fieldLagDays: const {},
          journal: journal,
          dates: dates,
          outcomes: outcomes,
        ).single.effects.single.rho,
        isNull,
      );

      // Lowered below the pair count, rho is computed and — because 5 > 3 —
      // still carries an interval.
      final e = journalNumericCorrelations(
        // MIND-02: this test is about the statistic, not the alignment.
        fieldLagDays: const {},
        journal: journal,
        dates: dates,
        outcomes: outcomes,
        minN: 5,
      ).single.effects.single;
      expect(e.rho, closeTo(1.0, 1e-9));
      expect(e.n, 5);
      expect(e.rhoLow, isNotNull);
      expect(e.rhoHigh, isNotNull);

      // Four pairs is where the interval gets absurdly wide but still exists
      // — and being unable to exclude zero is exactly the right answer there.
      expect(e.rhoLow!, lessThan(0), reason: 'five days cannot clear zero');
      // STAT-08. The DISPLAY interval (Bonett & Wright) and the GATE
      // (permutation p) are now two different tests, and this is where they
      // part company: five days in perfect rank order has an exact two-sided
      // permutation p of 2/5! = 0.0167, which clears 0.05, while the B-W
      // interval — a continuous-data simulation result applied to ordinal
      // journal fields, evaluated at the observed r — cannot. The exact test is
      // the honest one; `minN` (8 in production, overridden to 5 here) is what
      // keeps five-day findings off the screen, not a conservative SE.
      expect(e.p!, closeTo(2 / 120, 0.01));
      expect(e.meaningful, isTrue);

      // At three the standard error is undefined outright, so there is no
      // interval at all and therefore no verdict.
      final three = _dates(3);
      final e3 = journalNumericCorrelations(
        // MIND-02: this test is about the statistic, not the alignment.
        fieldLagDays: const {},
        journal: [
          for (var i = 0; i < 3; i++)
            JournalNumericDay(three[i], {'water': i.toDouble()}),
        ],
        dates: three,
        outcomes: {
          'readiness': [for (var i = 0; i < 3; i++) 50.0 + i]
        },
        minN: 3,
      ).single.effects.single;
      expect(e3.rho, closeTo(1.0, 1e-9));
      expect(e3.rhoLow, isNull, reason: 'n > 3 is required for the SE');
      expect(
        e3.meaningful,
        isFalse,
        reason: 'no interval means no evidence it clears zero',
      );
    });

    // -----------------------------------------------------------------------
    // MIND-01 — Benjamini-Hochberg over the returned grid.
    // -----------------------------------------------------------------------

    test('a grid of pure noise produces per-test hits and NO findings', () {
      // The whole reason the correction is not optional. Twenty unrelated
      // fields against one outcome, all noise: at a per-test 0.05 gate about
      // one of them is a "finding" every time, for every user, forever. Under
      // BH the same grid publishes nothing.
      const n = 40;
      final dates = _dates(n);
      final rng = math.Random(1);
      final journal = [
        for (var i = 0; i < n; i++)
          JournalNumericDay(dates[i], {
            for (var f = 0; f < 20; f++) 'f$f': rng.nextDouble() * 5,
          }),
      ];
      final out = journalNumericCorrelations(
        journal: journal,
        dates: dates,
        outcomes: {
          'readiness': [
            for (var i = 0; i < n; i++) 50.0 + rng.nextDouble() * 10
          ],
        },
      );
      final effects = [for (final f in out) ...f.effects];
      expect(effects, hasLength(20));
      expect(
        effects.any((e) => e.p != null && e.p! < 0.05),
        isTrue,
        reason: 'if no per-test hit turns up here the test has stopped '
            'exercising the thing it guards',
      );
      expect(
        effects.every((e) => !e.meaningful),
        isTrue,
        reason: 'pure noise must publish nothing',
      );
      for (final e in effects) {
        expect(e.q!, greaterThanOrEqualTo(e.p!), reason: 'q never below p');
      }
    });

    test('a family of one is the identity — q equals p', () {
      final dates = _dates(12);
      final caffeine = <double>[1, 2, 3, 4, 5, 6, 1, 2, 3, 4, 5, 6];
      final out = journalNumericCorrelations(
        // MIND-02: this test is about the statistic, not the alignment.
        fieldLagDays: const {},
        journal: [
          for (var i = 0; i < dates.length; i++)
            JournalNumericDay(dates[i], {'caffeine': caffeine[i]}),
        ],
        dates: dates,
        outcomes: {
          'rmssd': [for (final c in caffeine) 80.0 - 6 * c]
        },
      );
      final e = _effect(out, 'caffeine', 'rmssd');
      expect(e.q, closeTo(e.p!, 1e-12));
      expect(e.meaningful, isTrue, reason: 'a real relationship still lands');
    });

    // -----------------------------------------------------------------------
    // MIND-04 — a 0/1 field is a tick box, not a dose.
    // -----------------------------------------------------------------------

    test('a 0/1 field routes to a difference of means, not to rho', () {
      // Habits are custom journal fields with max == 1, so this is the habit
      // path. "On the 9 days you did this, HRV was 4 ms higher."
      const n = 18;
      final dates = _dates(n);
      final flag = [for (var i = 0; i < n; i++) i.isEven ? 1.0 : 0.0];
      // +4 ms on the days it was ticked, with real within-group spread.
      final hrv = [
        for (var i = 0; i < n; i++) 60.0 + (flag[i] == 1 ? 4.0 : 0.0) + (i % 3),
      ];
      final out = journalNumericCorrelations(
        journal: [
          for (var i = 0; i < n; i++)
            JournalNumericDay(dates[i], {'meditate': flag[i]}),
        ],
        dates: dates,
        outcomes: {'rmssd': hrv},
      );
      final e = _effect(out, 'meditate', 'rmssd');
      expect(e.binary, isTrue);
      expect(e.rho, isNull, reason: 'a two-valued field has no dose to rank');
      expect(e.slopePerUnit, isNull);
      expect(e.rhoLow, isNull);
      expect(e.nWith, 9);
      expect(e.nWithout, 9);
      expect(e.delta!, closeTo(4.0, 1e-9));
      expect(e.cohensD!, greaterThan(0.5));
      expect(e.insufficient, isFalse);
      expect(e.meaningful, isTrue);
    });

    test('a ticked habit with no real difference is shippable as "not yet"',
        () {
      // Not insufficient — we ran the comparison and it came back nothing.
      // "No difference detectable yet" needs that distinction to be printable.
      const n = 20;
      final dates = _dates(n);
      final flag = [for (var i = 0; i < n; i++) i.isEven ? 1.0 : 0.0];
      final rng = math.Random(11);
      final out = journalNumericCorrelations(
        journal: [
          for (var i = 0; i < n; i++)
            JournalNumericDay(dates[i], {'stretch': flag[i]}),
        ],
        dates: dates,
        outcomes: {
          'readiness': [
            for (var i = 0; i < n; i++) 50.0 + rng.nextDouble() * 8
          ],
        },
      );
      final e = _effect(out, 'stretch', 'readiness');
      expect(e.binary, isTrue);
      expect(e.insufficient, isFalse);
      expect(e.meaningful, isFalse);
      expect(e.delta, isNotNull);
    });

    test('a 0/1 field with too few days on one side gives no verdict', () {
      const n = 12;
      final dates = _dates(n);
      final out = journalNumericCorrelations(
        journal: [
          for (var i = 0; i < n; i++)
            JournalNumericDay(dates[i], {'rare': i < 2 ? 1.0 : 0.0}),
        ],
        dates: dates,
        outcomes: {
          'rhr': [for (var i = 0; i < n; i++) 50.0 + i]
        },
      );
      final e = _effect(out, 'rare', 'rhr');
      expect(e.insufficient, isTrue);
      expect(e.meaningful, isFalse);
    });

    // STAT-03. A permutation test's null distribution is DISCRETE. At exactly
    // n = 8 with a 3/5 split the label vector has C(8,3) = 56 assignments, so
    // the smallest two-sided p is 1/56 = 0.0179 — and after the BH correction
    // over a family of 4 that is q = 0.071, above 0.05. The test CANNOT be
    // published however perfect the separation. At n = 9 it can
    // (1/126 × 4 = 0.032). What shipped was silence with no reason attached.
    test('an unreachable test abstains and says how many days it needs', () {
      List<JournalNumericCorrelation> run(int n) {
        final dates = _dates(n);
        // Perfectly separated: every ticked day is 20 ms above every other.
        final flag = [for (var i = 0; i < n; i++) i < 3 ? 1.0 : 0.0];
        return journalNumericCorrelations(
          fieldLagDays: const {},
          journal: [
            for (var i = 0; i < n; i++)
              JournalNumericDay(dates[i], {'sauna': flag[i]}),
          ],
          dates: dates,
          // FOUR outcomes: the family size the only production caller passes.
          outcomes: {
            for (final k in ['rmssd', 'rhr', 'readiness', 'efficiency'])
              k: [
                for (var i = 0; i < n; i++)
                  60.0 + (flag[i] == 1 ? 20.0 : 0.0) + (i % 3)
              ],
          },
        );
      }

      final at8 = _effect(run(8), 'sauna', 'rmssd');
      expect(at8.insufficient, isTrue, reason: '1/C(8,3) x 4 = 0.071 > 0.05');
      expect(at8.meaningful, isFalse);
      expect(at8.note, 'need_history:have=8,need=9');

      final at9 = _effect(run(9), 'sauna', 'rmssd');
      expect(at9.insufficient, isFalse, reason: '1/C(9,3) x 4 = 0.032');
      expect(at9.note, isNull);
      expect(at9.meaningful, isTrue);
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

  // MIND-02 — the journal row for day D describes the DAYTIME of D, but the
  // outcome labelled D comes from the night that ENDED on the morning of D. So
  // a behaviour field has to be matched against D+1, and a retrospective field
  // must NOT be.
  group('MIND-02 per-field lag', () {
    test('a behaviour field is matched against the FOLLOWING night', () {
      final dates = _dates(14);
      // Coffee on day i wrecks the night that follows, i.e. the outcome
      // labelled i+1. Same-day pairing sees a scrambled series and nothing
      // else — that is the bug, reproduced here as the control.
      final caffeine = <double>[1, 2, 3, 4, 5, 6, 1, 2, 3, 4, 5, 6, 1, 2];
      final rmssd = <double?>[
        null, // day 0's outcome belongs to the night before the log starts
        for (var i = 0; i + 1 < caffeine.length; i++) 80.0 - 6 * caffeine[i],
      ];
      final journal = [
        for (var i = 0; i < dates.length; i++)
          JournalNumericDay(dates[i], {'caffeine': caffeine[i]}),
      ];

      final lagged = journalNumericCorrelations(
        journal: journal,
        dates: dates,
        outcomes: {'rmssd': rmssd},
      );
      final e = _effect(lagged, 'caffeine', 'rmssd');
      expect(e.rho, closeTo(-1.0, 1e-9));
      expect(e.meaningful, isTrue);
      expect(lagged.first.lagDays, 1, reason: 'disclosed, not silent');

      // The old alignment cannot see it at all.
      final sameDay = journalNumericCorrelations(
        journal: journal,
        dates: dates,
        outcomes: {'rmssd': rmssd},
        fieldLagDays: const {},
      );
      expect(_effect(sameDay, 'caffeine', 'rmssd').rho!.abs(), lessThan(0.9));
    });

    test('a retrospective field is NOT shifted', () {
      // mood on day D describes the daytime of D, which the night ending that
      // morning produced. A blanket +1 would break the fields that are already
      // right, which is why the constant is per-field.
      expect(journalFieldLagDays['mood'], 0);
      expect(journalFieldLagDays['sleep_quality'], 0);
      expect(journalFieldLagDays['caffeine'], 1);
      expect(journalFieldLagDays['alcohol'], 1);
      // An unlisted (custom) field is not silently re-aligned either.
      expect(journalFieldLagDays['a_field_we_invented'], isNull);
    });

    test('a lagged day with no outcome the next day is DROPPED, not backfilled',
        () {
      final dates = _dates(12);
      final out = <double?>[for (var i = 0; i < 12; i++) 50.0 + i];
      out[6] = null; // the night after day 5 was never judged
      final res = journalNumericCorrelations(
        journal: [
          for (var i = 0; i < dates.length; i++)
            JournalNumericDay(dates[i], {'water': i.toDouble()}),
        ],
        dates: dates,
        outcomes: {'readiness': out},
      );
      // 12 journal days; day 11 has no day-12 outcome in the series, and day 5
      // loses its (null) one. 10 pairs, never 12.
      expect(_effect(res, 'water', 'readiness').n, 10);
    });

    test('shiftDayLabel crosses a month and a DST boundary correctly', () {
      expect(shiftDayLabel('2026-01-31', 1), '2026-02-01');
      expect(shiftDayLabel('2026-03-29', 1), '2026-03-30'); // EU DST Sunday
      expect(shiftDayLabel('2026-12-31', 1), '2027-01-01');
      expect(shiftDayLabel('d0', 1), isNull);
      expect(shiftDayLabel('d0', 0), 'd0');
    });
  });
}
