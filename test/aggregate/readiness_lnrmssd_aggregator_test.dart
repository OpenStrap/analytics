// readinessLnRmssdAggregator (Count + LastRows(windowDays + 1)) must reproduce
// the reference EXACTLY (every field, bit for bit), and the public
// readinessLnRmssd, which delegates to it, must too. `_reference` is a frozen
// copy of upstream main 9db83ce, including small-window band calibration.
//
// windowDays <= 0 decision. The reference with windowDays 0 keeps an empty
// prior window, so it returns the absent metric (need minNights + 1) and
// LastRows(1) can express that: windowDays 0 is checked on the aggregator
// like any other. With windowDays -1 the reference computes start = n, then
// sublist(n, n - 1) throws RangeError (once n >= minNights; shorter
// histories are absent first). LastRows(0) cannot be built, so the aggregator
// is NOT required to exist for windowDays < 0: the public function keeps the
// reference path there and must behave identically, throw included.


import 'dart:math' as math;

import 'package:openstrap_analytics/aggregate.dart';
import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

import '../support/aggregator_laws.dart';
import '../support/checkpoint_support.dart';
import '../support/property.dart' show Rng;

Metric<ReadinessLnRmssd> _reference(
  List<double> historyLnRmssd, {
  List<String>? dates,
  double? meanNnTodayMs,
  int windowDays = 7,
  int minNights = readinessLnRmssdMinNights,
}) {
  const inputs = ['ln_rmssd_history'];
  if (historyLnRmssd.length < minNights) {
    return Metric<ReadinessLnRmssd>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: needBaselineNote(have: historyLnRmssd.length, need: minNights),
    );
  }
  final today = historyLnRmssd.last;
  final n = historyLnRmssd.length;
  final start = n - 1 - windowDays < 0 ? 0 : n - 1 - windowDays;
  // this used to be historyLnRmssd.sublist(start), which runs to the END of
  // the list - including tonight's own value in its own baseline. that
  // pulls the mean/sd toward tonight, understating how far off a genuinely
  // suppressed/elevated night actually is, worst right when the window is
  // smallest (minNights). the baseline has to be strictly prior nights.
  final List<double> priorWindow;
  // all-or-nothing: calendarDays falls back to the row index for a label it
  // can't parse, and an index compared against epoch days is meaningless.
  if (dates != null &&
      dates.length == n &&
      dates.every((d) => DateTime.tryParse(d) != null)) {
    final day = calendarDays(dates);
    priorWindow = [
      for (var i = 0; i < n - 1; i++)
        if (day[i] < day[n - 1] && day[n - 1] - day[i] <= windowDays)
          historyLnRmssd[i]
    ];
  } else {
    priorWindow = historyLnRmssd.sublist(start, n - 1);
  }
  if (priorWindow.isEmpty || priorWindow.length < minNights - 1) {
    // empty only if minNights got set to 1 somewhere; short when a wear gap
    // left too few nights inside the calendar window. either way there's no
    // baseline yet, same as not enough history.
    return Metric<ReadinessLnRmssd>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: needBaselineNote(
          have: priorWindow.length + 1, need: minNights < 2 ? 2 : minNights),
    );
  }
  final m = mean(priorWindow)!;
  final sd = stddev(priorWindow);
  if (sd == null || m == 0) {
    // The published outputs of this stack (CV, SWC, band) are all defined
    // RELATIVE to the baseline's dispersion. With a single prior night the SD
    // is UNDEFINED — and the metric used to fill in cvPct 0.0 and band
    // 'normal', asserting "tonight is typical" on the strength of nothing at
    // all. Abstain instead (a zero-but-DEFINED SD is a different case: CV is
    // genuinely 0 and SWC is genuinely 0, so that still computes below).
    return Metric<ReadinessLnRmssd>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'lnRMSSD baseline dispersion undefined (needs ≥2 prior nights) — '
          'CV/z/SWC/band are undefined',
    );
  }
  final cv = (sd / m).abs() * 100;
  // ROBUST CENTRE AND SPREAD for the decision band. One illness night in a
  // seven-night window both drags the mean down and inflates the SD, so a
  // genuinely low night reads "normal": on a real window holding a 35.5 ms
  // night, mean 4.465 / SD 0.405 put a 4.478 night (88 ms) inside the band,
  // while the other six nights sat at 4.40–4.79. Median + MAD (×1.4826) are
  // what the window looks like without that one night. MAD collapses only when
  // more than half the window is identical; the SD stands in then. The CV
  // above stays the classic SD/mean (Plews' published CV).
  final centre = median(priorWindow)!;
  final robustSd = mad(priorWindow)!;
  final spread = robustSd > 0 ? robustSd : sd;
  final z = spread > 0 ? (today - centre) / spread : null;
  // Plews SWC ≈ 0.5 × within-window SD (a small worthwhile change in lnRMSSD).
  final swc = 0.5 * spread;

  // The band is a SINGLE-NIGHT decision, so its threshold has to be a
  // single-night one: tonight outside centre ± 1 × spread, Kiviniemi 2007's
  // daily reference value (baseline mean ± SD). The SWC above (0.5 × spread)
  // is Plews' threshold for a 7-day ROLLING mean, where averaging has already
  // cut night-to-night noise by ~1/sqrt(7); applied to one night it sits inside
  // ordinary noise and a user whose HRV never changed read 'suppressed' or
  // 'elevated' on ~70% of nights. Comparing a rolling mean instead does not
  // work against this baseline: the week being tested is six-sevenths the same
  // nights the centre comes from, so a real multi-night drop drags the centre
  // with it and goes unflagged, and one old bad night keeps an ordinary
  // tonight 'suppressed' for the rest of the week. At zero spread any
  // departure from the centre is outside the band.
  //
  // "± 1 SD" only means a ~32% flag rate when the centre and spread are known.
  // Here they come from 3-7 prior nights: the median misses the true level and
  // the MAD of so few points is biased low and noisy, so a user whose HRV
  // never changed still read 'suppressed'/'elevated' on 62% of nights with 3
  // prior nights and 45% with 7. [_lnRmssdBandWidening] restores the intended
  // single-night rate for the window size actually used.
  final halfWidth = spread * _lnRmssdBandWidening(priorWindow.length);
  final String band;
  if (today < centre - halfWidth) {
    band = 'suppressed';
  } else if (today > centre + halfWidth) {
    band = 'elevated';
  } else {
    band = 'normal';
  }

  // LnRMSSD:RR saturation guard: when mean NN is long (low HR, high vagal tone)
  // and lnRMSSD is at the top of the personal range, the metric saturates.
  final saturation =
      meanNnTodayMs != null && meanNnTodayMs > 1100 && z != null && z > 1.0;

  final conf = (priorWindow.length / windowDays.toDouble()).clamp(0.3, 0.9);
  return Metric<ReadinessLnRmssd>(
    value: ReadinessLnRmssd(
      lnRmssdToday: today,
      rolling7Mean: m,
      rolling7Median: centre,
      cvPct: cv,
      z: z,
      swc: swc,
      band: band,
      saturationFlag: saturation,
    ),
    confidence: conf,
    tier: Tier.high,
    inputs_used: inputs,
    note: saturation
        ? 'lnRMSSD:RR saturation — high-HRV interpretation caution'
        : 'Plews/Kiviniemi whole-night lnRMSSD readiness; PRV',
  );
}

/// Half-width of the single-night band in units of the baseline's robust SD
/// (MAD × 1.4826), by number of prior nights. Each entry is the empirical
/// 68.27th percentile of |tonight − median| / (MAD × 1.4826) when tonight and
/// the prior nights are drawn from one fixed normal distribution (400k trials
/// per n), so a stable user lands outside the band on ~31.7% of nights,
/// Kiviniemi's mean ± SD rate with known parameters. It folds in both the
/// prediction-interval term for a new observation (√(1 + 1/n)) and the small-n
/// bias and noise of the MAD; 3 is above 2 because the MAD of three points is
/// 1.4826 × the smaller non-median deviation and runs especially small.
/// Interpolated log-linearly in n; past the last anchor it decays toward 1 as
/// 1/n, since the MAD then converges to σ.
const List<(int, double)> _lnRmssdBandWideningTable = [
  (2, 2.144),
  (3, 2.851),
  (4, 1.884),
  (5, 1.687),
  (6, 1.487),
  (7, 1.418),
  (8, 1.334),
  (10, 1.257),
  (14, 1.172),
  (20, 1.119),
  (28, 1.085),
  (45, 1.051),
  (90, 1.025),
];

double _lnRmssdBandWidening(int n) {
  final first = _lnRmssdBandWideningTable.first;
  final last = _lnRmssdBandWideningTable.last;
  if (n <= first.$1) return first.$2;
  if (n >= last.$1) return 1 + (last.$2 - 1) * last.$1 / n;
  for (var i = 1; i < _lnRmssdBandWideningTable.length; i++) {
    final (n1, f1) = _lnRmssdBandWideningTable[i];
    if (n > n1) continue;
    final (n0, f0) = _lnRmssdBandWideningTable[i - 1];
    final t = (math.log(n) - math.log(n0)) / (math.log(n1) - math.log(n0));
    return math.exp(math.log(f0) + t * (math.log(f1) - math.log(f0)));
  }
  return 1.0;
}

List<Object?> _fields(Metric<ReadinessLnRmssd> m) {
  final v = m.value;
  return [
        m.present, m.confidence, m.tier, m.inputs_used.join(','), m.note,
        m.drivers, v?.lnRmssdToday, v?.rolling7Mean, v?.rolling7Median, v?.cvPct, v?.z, v?.swc,
        v?.band, v?.saturationFlag,
      ];
}

final _same = fieldsEqual<Metric<ReadinessLnRmssd>>(_fields);

DoubleColumn _hist(Rng r, int n, int style) => col([
      for (var i = 0; i < n; i++)
        switch (style) {
          0 => 3.0 + r.nextDouble() * 2.0,
          1 => 4.2, // constant: sd == 0
          2 => 0.0, // zeros: m == 0
          _ => r.nextBool(.3) ? 0.0 : 3.0 + r.nextDouble() * 2.0,
        }
    ]);

List<DoubleColumn> _cases(int seed) {
  final r = Rng(seed);
  return [
    for (var n = 0; n <= 40; n++) _hist(r, n, n % 4),
    for (var n = 1; n <= 12; n++) _hist(r, n, 0),
    for (var n = 3; n <= 20; n += 4) _hist(r, n, 1),
    for (var n = 3; n <= 20; n += 4) _hist(r, n, 2),
  ];
}

void main() {
  group('parity with the reference', () {
    for (final w in [0, 1, 3, 7, 14]) {
      for (final nn in [null, 900.0, 1200.0]) {
        test('windowDays=$w meanNn=$nn, minNights 1/2/4/6', () {
          for (final mn in [1, 2, 4, 6]) {
            expectConversion<dynamic, DoubleColumn, Metric<ReadinessLnRmssd>>(
              (_) => readinessLnRmssdAggregator(
                  meanNnTodayMs: nn, windowDays: w, minNights: mn),
              _cases(w * 31 + mn),
              (b) => _reference(b.values.toList(),
                  meanNnTodayMs: nn, windowDays: w, minNights: mn),
              equals: _same,
              chunkings: 3,
              seed: w + mn,
            );
          }
        });
      }
    }
  });

  group('public readinessLnRmssd equals the reference', () {
    for (final w in [0, 1, 3, 7, 14]) {
      test('windowDays=$w', () {
        for (final nn in [null, 900.0, 1200.0]) {
          for (final mn in [1, 2, 4, 6]) {
            for (final b in _cases(w + 500)) {
              final h = b.values.toList();
              final got = readinessLnRmssd(h,
                  meanNnTodayMs: nn, windowDays: w, minNights: mn);
              final want = _reference(h,
                  meanNnTodayMs: nn, windowDays: w, minNights: mn);
              expect(_same(got, want), isTrue,
                  reason: 'n=${h.length} mn=$mn: $got vs $want');
            }
          }
        }
      });
    }
    test('default arguments', () {
      for (final b in _cases(9)) {
        final h = b.values.toList();
        expect(_same(readinessLnRmssd(h), _reference(h)), isTrue);
      }
    });
    test('windowDays=-1: absent when short, RangeError otherwise, as before',
        () {
      for (final b in _cases(3)) {
        final h = b.values.toList();
        Object? run(Metric<ReadinessLnRmssd> Function() f) {
          try {
            return f();
          } on RangeError {
            return 'RangeError';
          }
        }

        final got = run(() => readinessLnRmssd(h, windowDays: -1));
        final want = run(() => _reference(h, windowDays: -1));
        if (want is String) {
          expect(got, want, reason: 'n=${h.length}');
          expect(h.length >= readinessLnRmssdMinNights, isTrue);
        } else {
          expect(got, isA<Metric<ReadinessLnRmssd>>());
          expect(
              _same(got as Metric<ReadinessLnRmssd>,
                  want as Metric<ReadinessLnRmssd>),
              isTrue);
        }
      }
    });
  });

  test('persistable: a mid-stream checkpoint resumes to the one-pass result',
      () {
    final agg = readinessLnRmssdAggregator(meanNnTodayMs: 1200);
    expect(agg.persistable, isTrue);
    expectCheckpointResumes(agg, _hist(Rng(0x12), 30, 0), equals: _same);
  });

  group('checkpoint relationships (count against the kept rows)', () {
    final agg = readinessLnRmssdAggregator(windowDays: 7); // keeps 8 rows
    Metric<ReadinessLnRmssd>? restore(Object? state) {
      final got = decodeCheckpoint<dynamic>(
          agg, {'kind': 'k', 'version': 1, 'state': state},
          kind: 'k', version: 1);
      return got == null ? null : agg.finish(got);
    }

    test('review case: count 4 with no rows is refused', () {
      // Used to decode, then finish threw on the missing rows.
      expect(
          decodeCheckpoint<dynamic>(
              agg,
              {
                'kind': 'k',
                'version': 1,
                'state': [4, {'rows': null}]
              },
              kind: 'k',
              version: 1),
          isNull);
    });
    test('count 0 with rows present is refused', () {
      final rows = ((checkpointOf(agg, _hist(Rng(1), 3, 0))['state'] as List)[1]
          as Map)['rows'];
      expect(restore([0, {'rows': rows}]), isNull);
    });
    test('count that disagrees with the number of kept rows is refused', () {
      final long = _hist(Rng(2), 30, 0);
      // 30 nights keep 8 rows; claiming 5 (or 3 nights holding 8) is damage.
      expectDamagedCheckpointRefused(agg, long, (s) {
        (s as List)[0] = 5;
        return s;
      });
      expectDamagedCheckpointRefused(agg, long, (s) {
        (s as List)[0] = 0;
        return s;
      });
      final short = _hist(Rng(3), 5, 0); // keeps all 5
      expectDamagedCheckpointRefused(agg, short, (s) {
        (s as List)[0] = 9;
        return s;
      });
      expectDamagedCheckpointRefused(agg, short, (s) {
        (s as List)[0] = 4;
        return s;
      });
    });
    test('a consistent checkpoint still restores', () {
      for (final n in [0, 1, 5, 8, 9, 30]) {
        final b = _hist(Rng(n), n, 0);
        final got = decodeCheckpoint<dynamic>(agg, checkpointOf(agg, b),
            kind: 'test', version: 1);
        expect(got, isNotNull, reason: 'n=$n');
        expect(_same(agg.finish(got), agg.run(b)), isTrue);
      }
    });
  });

  group('reads only the suffix of the history', () {
    test('an unused prefix element is never read', () {
      // Element 0 is not a double; only the last windowDays + 1 are read.
      final h = <dynamic>['unused', 3.0, 4.0, 5.0, 6.0].cast<double>();
      final got = readinessLnRmssd(h, windowDays: 3);
      final want = _reference(h, windowDays: 3);
      expect(want.present, isTrue);
      expect(_same(got, want), isTrue, reason: '$got vs $want');
    });
    test('a too-short history is refused without reading any element', () {
      final h = <dynamic>['a', 'b'].cast<double>();
      final got = readinessLnRmssd(h);
      expect(got.present, isFalse);
      expect(got.note, needBaselineNote(have: 2, need: readinessLnRmssdMinNights));
    });
  });

  group('windowDays at the int limit', () {
    const huge = 0x7fffffffffffffff;
    final h = [3.0, 4.0, 5.0, 6.0];
    test('the public function matches the reference', () {
      final got = readinessLnRmssd(h, windowDays: huge);
      expect(_same(got, _reference(h, windowDays: huge)), isTrue);
      expect(got.present, isTrue);
    });
    test('the aggregator matches the reference and resumes', () {
      final agg = readinessLnRmssdAggregator(windowDays: huge);
      expect(_same(agg.run(col(h)), _reference(h, windowDays: huge)), isTrue);
      expectCheckpointResumes(agg, col(h), equals: _same);
    });
  });
}
