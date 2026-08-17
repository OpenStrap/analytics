// TS-11 / TS-12 / MIND-11 / WH-08 — the refusals, mostly. Each of these
// features is one sentence of output wrapped in the conditions under which it
// must say nothing, and the abstention is the part that gets quietly deleted
// later, so it is the part that is pinned here.

import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

List<String> _dates(int n) {
  final start = DateTime.utc(2026, 1, 1);
  return [
    for (var i = 0; i < n; i++)
      () {
        final d = start.add(Duration(days: i));
        return '${d.year}-${d.month.toString().padLeft(2, '0')}'
            '-${d.day.toString().padLeft(2, '0')}';
      }(),
  ];
}

void main() {
  // -------------------------------------------------------------------------
  group('MIND-11 alertness forecast', () {
    test('ABSTAINS on a missing night — it never assumes eight hours', () {
      for (final m in [
        alertnessForecast(wakeLocalHour: 7, sleepDurationHours: null),
        alertnessForecast(wakeLocalHour: null, sleepDurationHours: 7.5),
        alertnessForecast(wakeLocalHour: 7, sleepDurationHours: 0),
      ]) {
        expect(m.present, isFalse);
        expect(m.confidence, 0);
        expect(m.note, contains('no_judged_night'));
      }
    });

    test('the safety refusal is on every output, present or absent', () {
      final present =
          alertnessForecast(wakeLocalHour: 7, sleepDurationHours: 7.5);
      final absent =
          alertnessForecast(wakeLocalHour: 7, sleepDurationHours: null);
      for (final m in [present, absent]) {
        expect(m.note, contains('fitness-to-drive'));
        expect(m.note, contains('impaired'));
      }
    });

    test('emits a shape and a named window, and NO score', () {
      final m = alertnessForecast(
        wakeLocalHour: 7,
        sleepDurationHours: 7.5,
        circadianAcrophaseHours: 16,
      );
      expect(m.present, isTrue);
      final j = m.value!.toJson();
      // Whatever else changes, there must never be a scalar alertness value.
      for (final k in ['score', 'alertness', 'kss', 'value', 'level']) {
        expect(j.containsKey(k), isFalse, reason: k);
      }
      expect(j['shape'], isA<List<dynamic>>());
      expect(m.value!.troughLabel, isNotEmpty);
      expect(m.value!.shape.every((v) => v >= 0 && v <= 1), isTrue);
    });

    test('the trough is not just sleep inertia, and a nap moves the shape', () {
      final m = alertnessForecast(wakeLocalHour: 7, sleepDurationHours: 7.5);
      // The first hour after waking is the lowest raw point in the model. If
      // the trough window reported that, the "forecast" would be the past.
      expect(m.value!.troughStartHour, greaterThan(8.0));

      final napped = alertnessForecast(
        wakeLocalHour: 7,
        sleepDurationHours: 7.5,
        naps: const [DaytimeSleepWindow(13, 13.5)],
      );
      expect(napped.value!.shape, isNot(equals(m.value!.shape)));
    });

    test('an assumed circadian phase is disclosed as assumed', () {
      expect(alertnessForecast(wakeLocalHour: 7, sleepDurationHours: 7.5).note,
          contains('ASSUMED'));
      expect(
          alertnessForecast(
                  wakeLocalHour: 7,
                  sleepDurationHours: 7.5,
                  circadianAcrophaseHours: 15.2)
              .note,
          isNot(contains('ASSUMED')));
    });
  });

  // -------------------------------------------------------------------------
  group('TS-11 next-morning cost by session type', () {
    // 60 days of a 50 bpm resting HR with real dispersion, and a football
    // session every 4th day whose next morning runs +10 bpm.
    List<double?> series({required bool withEffect}) {
      const noise = [0.0, 1, -1, 2, -2, 1, -1, 0, 2, -2];
      final v = <double?>[for (var i = 0; i < 60; i++) 50.0 + noise[i % 10]];
      if (withEffect) {
        for (var i = 4; i < 60; i += 4) {
          v[i] = v[i]! + 10;
        }
      }
      return v;
    }

    Map<String, List<String>> football(List<String> dates, {int every = 4}) => {
          for (var i = 3; i < dates.length; i += every) dates[i]: ['football'],
        };

    test('reports the median move and the n it rests on', () {
      final dates = _dates(60);
      final m = sessionMorningEffects(
        dates: dates,
        values: series(withEffect: true),
        metric: 'rhr',
        sessionTypesByDate: football(dates),
      );
      expect(m.present, isTrue);
      final e = m.value!.single;
      expect(e.sessionType, 'football');
      // Smaller than the injected 10: the trailing baseline is his USUAL, and
      // his usual already contains a football morning every fourth day, which
      // pulls the baseline up. The card says "above your baseline", and this
      // is that baseline.
      expect(e.medianDelta, greaterThan(6.0));
      expect(e.medianDelta, lessThan(10.0));
      expect(e.n, greaterThanOrEqualTo(10));
      expect(e.exceedsMdc, isTrue);
      expect(m.note, contains('ASSOCIATION ONLY'));
    });

    test('a move inside the MDC is not reported as a finding', () {
      final dates = _dates(60);
      final v = <double?>[
        for (var i = 0; i < 60; i++)
          50.0 + [0.0, 1, -1, 2, -2, 1, -1, 0, 2, -2][i % 10]
      ];
      for (var i = 4; i < 60; i += 4) {
        v[i] = v[i]! + 0.5; // real, tiny, unresolvable
      }
      final e = sessionMorningEffects(
        dates: dates,
        values: v,
        metric: 'rhr',
        sessionTypesByDate: football(dates),
      ).value!.single;
      expect(e.exceedsMdc, isFalse);
    });

    test('a day with two sessions belongs to neither type', () {
      final dates = _dates(60);
      final both = {
        for (var i = 3; i < 60; i += 4) dates[i]: ['football', 'run'],
      };
      final m = sessionMorningEffects(
        dates: dates,
        values: series(withEffect: true),
        metric: 'rhr',
        sessionTypesByDate: both,
      );
      expect(m.present, isFalse, reason: 'ambiguous days are dropped entirely');
    });

    test('a low-coverage night is not a morning', () {
      final dates = _dates(60);
      final m = sessionMorningEffects(
        dates: dates,
        values: series(withEffect: true),
        metric: 'rhr',
        sessionTypesByDate: football(dates),
        coverage: [for (var i = 0; i < 60; i++) 0.1],
      );
      expect(m.present, isFalse);
    });

    test('refuses under the minimum n rather than showing a small one', () {
      final dates = _dates(60);
      final m = sessionMorningEffects(
        dates: dates,
        values: series(withEffect: true),
        metric: 'rhr',
        sessionTypesByDate: football(dates, every: 20),
      );
      expect(m.present, isFalse);
      expect(m.note, contains('need_sessions'));
    });
  });

  // -------------------------------------------------------------------------
  group('TS-12 overreaching conjunction', () {
    final quiet = [for (var i = 0; i < 28; i++) 50.0 + (i.isEven ? 1 : -1)];

    Metric<LoadState> loadWithRamp() => ctlAtlTsb([
          for (var i = 0; i < 35; i++) 40.0,
          for (var i = 0; i < 7; i++) 200.0,
        ]);

    test('fires only when BOTH facts hold', () {
      final m = overreachingConjunction(
        load: loadWithRamp(),
        rhrRecent: const [58.0, 59, 57, 58, 50],
        rhrBaselineWindow: quiet,
      );
      expect(m.present, isTrue);
      expect(m.value!.loadRatio, greaterThan(1.5));
      expect(m.value!.nightsElevated, 4);
      expect(m.value!.bothPointSameWay, isTrue);

      // Same nights, no load ramp.
      final flat = overreachingConjunction(
        load: ctlAtlTsb([for (var i = 0; i < 42; i++) 40.0]),
        rhrRecent: const [58.0, 59, 57, 58, 50],
        rhrBaselineWindow: quiet,
      );
      expect(flat.value!.bothPointSameWay, isFalse);
    });

    test('a rise inside the MDC does not count as an elevated night', () {
      final m = overreachingConjunction(
        load: loadWithRamp(),
        rhrRecent: const [50.5, 50.6, 50.4, 50.5, 50.5],
        rhrBaselineWindow: quiet,
      );
      expect(m.value!.nightsElevated, 0);
      expect(m.value!.bothPointSameWay, isFalse);
    });

    test('abstains without load history or a usable baseline', () {
      expect(
          overreachingConjunction(
            load: null,
            rhrRecent: const [58.0, 59, 57, 58, 50],
            rhrBaselineWindow: quiet,
          ).present,
          isFalse);
      expect(
          overreachingConjunction(
            load: loadWithRamp(),
            rhrRecent: const [58.0, 59, 57, 58, 50],
            rhrBaselineWindow: List<double>.filled(28, 50), // no dispersion
          ).present,
          isFalse);
    });

    test('the copy names the confounds and refuses the push channel', () {
      final m = overreachingConjunction(
        load: loadWithRamp(),
        rhrRecent: const [58.0, 59, 57, 58, 50],
        rhrBaselineWindow: quiet,
      );
      for (final w in ['Illness', 'travel', 'altitude', 'no notification']) {
        expect(m.note, contains(w));
      }
    });
  });

  // -------------------------------------------------------------------------
  group('WH-08 logged cycle lengths', () {
    List<String> onsets(List<int> lengths) {
      var d = DateTime.utc(2025, 1, 1);
      final out = <String>[_fmt(d)];
      for (final l in lengths) {
        d = d.add(Duration(days: l));
        out.add(_fmt(d));
      }
      return out;
    }

    test('differences consecutive onsets and carries the criterion numbers',
        () {
      final m = cycleLengthSeries(onsets(List<int>.filled(13, 28)));
      expect(m.present, isTrue);
      expect(m.value!.lengthsDays, everyElement(28));
      expect(m.value!.maxConsecutiveDifferenceDays, 0);
      final j = m.value!.toJson();
      expect(j['difference_criterion_days'], 7);
      expect(j['long_interval_criterion_days'], 60);
    });

    test('emits NO verdict text and no stage vocabulary', () {
      final m = cycleLengthSeries(
          onsets([28, 35, 26, 41, 27, 30, 45, 25, 33, 29, 38, 26, 31]));
      final blob = '${m.note} ${m.value!.toJson()}'.toLowerCase();
      for (final word in [
        'menopause',
        'perimenopause',
        'transition',
        'stage',
        'early',
        'late',
        'premature',
      ]) {
        expect(blob.contains(word), isFalse, reason: word);
      }
      expect(m.note, contains('clinician'));
    });

    test('REFUSES on a hole — a missed log and a long interval are identical',
        () {
      final m = cycleLengthSeries(
          onsets([28, 28, 28, 120, 28, 28, 28, 28, 28, 28, 28, 28, 28]));
      expect(m.present, isFalse);
      expect(m.note, contains('log_has_holes'));
    });

    test('refuses under a long history', () {
      final m = cycleLengthSeries(onsets(List<int>.filled(4, 28)));
      expect(m.present, isFalse);
      expect(m.note, contains('need_baseline'));
    });

    test('a 60-day interval is charted, not judged', () {
      final m = cycleLengthSeries(
          onsets([28, 28, 60, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28]));
      expect(m.present, isTrue);
      expect(m.value!.longestIntervalDays, 60);
      expect(m.value!.maxConsecutiveDifferenceDays, 32);
    });
  });
}

String _fmt(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}'
    '-${d.day.toString().padLeft(2, '0')}';
