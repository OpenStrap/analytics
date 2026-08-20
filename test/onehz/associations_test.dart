// MIND-20 — "what actually affects my recovery".
//
// THE LOAD-BEARING TEST IN THIS FILE IS `PURE NOISE PUBLISHES (ALMOST) NOTHING`.
// Everything else here — finding a planted effect, getting its lag right,
// phrasing an effect size — is worth exactly zero if the engine also finds
// things in data that has nothing in it. If that test starts failing, this
// feature does not get retuned, it gets deleted.
//
// The second most important test is `BLOCK PERMUTATION IS WHAT MAKES IT HOLD`,
// which runs the same noise through a day-wise shuffle and shows the false
// positives come flooding back. That is the justification for the block null
// being there at all; without that contrast it is just an unexplained constant.

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

/// An AR(1) walk — the shape real daily health data actually has. Sleep debt,
/// training load and mood all persist, and this is the process that breaks a
/// naive significance test.
List<double?> _ar1(int n, math.Random r,
    {double phi = 0.6, double mean = 50, double sd = 8}) {
  final out = <double?>[];
  var x = 0.0;
  for (var i = 0; i < n; i++) {
    x = phi * x + math.sqrt(1 - phi * phi) * _gauss(r);
    out.add(mean + sd * x);
  }
  return out;
}

List<double?> _iid(int n, math.Random r, {double mean = 50, double sd = 8}) =>
    [for (var i = 0; i < n; i++) mean + sd * _gauss(r)];

DailyVariable _v(String key, List<double?> values) {
  final v = standardVariable(key, values);
  expect(v, isNotNull, reason: '$key must be in the catalog');
  return v!;
}

void main() {
  group('scanAssociations — the noise floor', () {
    test('PURE NOISE publishes (almost) nothing across a whole grid', () {
      // Six independent AR(1) series, no relationship of any kind between any
      // pair of them. That is 30 simultaneous tests. A naive engine at p < 0.05
      // publishes ~1.5 findings here EVERY TIME, for EVERY user — a confident
      // screen assembled entirely out of nothing.
      //
      // At an FDR of 0.10 and a completely null family, the false discovery
      // rate degenerates to the family-wise error rate, so the quantity being
      // asserted is: how often does this engine publish ANY finding at all when
      // there is nothing to find. It must be about 10% or less.
      const trials = 25;
      const days = 120;
      final dates = _dates(days);
      var trialsWithAFinding = 0;
      var totalFindings = 0;
      var totalTests = 0;

      for (var t = 0; t < trials; t++) {
        final r = math.Random(9000 + t);
        final m = scanAssociations(
          dates: dates,
          variables: [
            _v('rmssd', _ar1(days, r, mean: 55, sd: 12)),
            _v('tst_min', _ar1(days, r, mean: 420, sd: 45)),
            _v('rhr', _ar1(days, r, mean: 52, sd: 4)),
            _v('strain', _ar1(days, r, mean: 10, sd: 3)),
            _v('steps', _ar1(days, r, mean: 8000, sd: 2500)),
            _v('stress', _ar1(days, r, mean: 40, sd: 12)),
          ],
          seed: 4000 + t,
        );
        expect(m.present, isTrue, reason: '120 days clears the data gate');
        totalTests += m.value!.testsRun;
        totalFindings += m.value!.findings.length;
        if (m.value!.findings.isNotEmpty) trialsWithAFinding++;
      }

      // Sanity: the family really was big. A noise test over 3 tests proves
      // nothing about multiplicity control.
      expect(totalTests / trials, greaterThanOrEqualTo(20),
          reason: 'the grid must be big enough for this test to mean anything');

      final rate = trialsWithAFinding / trials;
      expect(
        rate,
        lessThanOrEqualTo(0.20),
        reason: 'published a finding out of pure noise in '
            '$trialsWithAFinding/$trials histories '
            '($totalFindings findings over $totalTests tests) — the FDR '
            'control is not holding and this feature is a noise generator',
      );
    });

    test('BLOCK PERMUTATION is what makes it hold — day-wise shuffling fails',
        () {
      // Same autocorrelated noise, only difference is blockLen: 1 day (an
      // ordinary shuffle, which is what every naive implementation does)
      // versus the 14-day default. The day-wise null destroys the persistence
      // that produced the spurious correlation, so it has none of it and calls
      // the correlation significant. Measured over 200 histories at phi = 0.6,
      // the day-wise version published a false finding in 69% of them against
      // 11% for the block null — at phi = 0.8 it was 98% against 12%. This test
      // exists so the block length is a measured decision rather than a number
      // somebody liked.
      const trials = 25;
      const days = 120;
      final dates = _dates(days);

      int findingsAt(int blockLen) {
        var found = 0;
        for (var t = 0; t < trials; t++) {
          final r = math.Random(9000 + t); // SAME data as the block run
          final m = scanAssociations(
            dates: dates,
            variables: [
              _v('rmssd', _ar1(days, r, mean: 55, sd: 12)),
              _v('tst_min', _ar1(days, r, mean: 420, sd: 45)),
              _v('rhr', _ar1(days, r, mean: 52, sd: 4)),
              _v('strain', _ar1(days, r, mean: 10, sd: 3)),
              _v('steps', _ar1(days, r, mean: 8000, sd: 2500)),
              _v('stress', _ar1(days, r, mean: 40, sd: 12)),
            ],
            blockLen: blockLen,
            seed: 4000 + t,
          );
          found += m.value!.findings.length;
        }
        return found;
      }

      final naive = findingsAt(1);
      final blocked = findingsAt(14);
      expect(
        blocked,
        lessThan(naive),
        reason: 'day-wise shuffling produced $naive false findings and the '
            '14-day block null produced $blocked — if these are equal the '
            'block permutation is not doing anything and the autocorrelation '
            'claim in the header is false',
      );
    });
  });

  group('scanAssociations — known answers', () {
    // Today's strain against TONIGHT's HRV. In the day-label grid tonight's HRV
    // is labelled TOMORROW (a night is labelled by the morning it ends on), so
    // the correct alignment is lag +1 and the engine has to derive that itself.
    // Planted effect: -1.5 ms of RMSSD per unit of strain.
    ({List<double?> strain, List<double?> rmssd}) _planted(int days, int seed) {
      final r = math.Random(seed);
      final strain = [for (var i = 0; i < days; i++) 10.0 + 3 * _gauss(r)];
      final rmssd = <double?>[];
      for (var i = 0; i < days; i++) {
        final driver = i == 0 ? 0.0 : (strain[i - 1] - 10.0);
        rmssd.add(55.0 - 1.5 * driver + 5.0 * _gauss(r));
      }
      return (strain: [for (final s in strain) s as double?], rmssd: rmssd);
    }

    test('finds a planted effect, at the right lag, with the right sign', () {
      const days = 120;
      final dates = _dates(days);
      final p = _planted(days, 31);
      final r = math.Random(77);

      final m = scanAssociations(
        dates: dates,
        variables: [
          _v('strain', p.strain),
          _v('rmssd', p.rmssd),
          // Decoys, so the planted effect has to survive a real multiplicity
          // correction rather than being the only test in the family.
          _v('steps', _iid(days, r, mean: 8000, sd: 2500)),
          _v('rhr', _iid(days, r, mean: 52, sd: 4)),
          _v('tst_min', _iid(days, r, mean: 420, sd: 45)),
          _v('stress', _iid(days, r, mean: 40, sd: 12)),
        ],
        seed: 12345,
      );

      expect(m.present, isTrue);
      final scan = m.value!;
      expect(scan.testsRun, greaterThanOrEqualTo(20),
          reason: 'the decoys must actually be in the family');

      final hit = scan.findings.where(
          (f) => f.inputKey == 'strain' && f.outcomeKey == 'rmssd');
      expect(hit, hasLength(1), reason: 'the planted effect must be found');
      final f = hit.first;

      expect(f.lagDays, 1,
          reason: "today's strain lands on the night labelled tomorrow");
      expect(f.rho, lessThan(0), reason: 'more strain, less HRV');
      expect(f.q, lessThanOrEqualTo(0.10));
      expect(f.meaningful, isTrue);

      // THE FEELABLE NUMBER. Top-vs-bottom tertile of strain is a gap of about
      // 2 x 0.97 x 3 = 5.8 units, so at -1.5 ms per unit the contrast should
      // land near -8.7 ms. Assert the magnitude, not just the sign — an engine
      // that gets the direction right and the size wrong is still lying.
      expect(f.contrast, lessThan(-4.0));
      expect(f.contrast, greaterThan(-16.0));
      expect(f.highCut, greaterThan(f.lowCut));
      expect(f.nLow, greaterThanOrEqualTo(5));
      expect(f.nHigh, greaterThanOrEqualTo(5));
      expect(f.n, greaterThanOrEqualTo(100));
      expect(f.outcomeMedian, closeTo(55, 4));
      expect(f.split, ContrastSplit.tertile);
    });

    test('does NOT run the same association backwards in time', () {
      // The requirement is STRUCTURAL, so it is asserted structurally: the
      // reverse pair is aligned at lag 0 (last night's HRV against today's
      // strain), never at lag -1, and the planted direction is much the
      // stronger of the two.
      //
      // Deliberately NOT asserted: that the reverse pair fails to publish on
      // this seed. Over 120 days a null pair draws |rho| = 0.24 about one time
      // in a hundred, and with only two variables in the family the
      // multiplicity correction has almost nothing to correct — this seed is
      // one of those draws. Asserting a probabilistic non-event on one seed
      // would just mean picking the seed that made it true, which is the exact
      // habit this whole file exists to prevent. The real version of that claim
      // is the 25-history noise test above.
      const days = 120;
      final p = _planted(days, 31);
      final m = scanAssociations(
        dates: _dates(days),
        variables: [_v('strain', p.strain), _v('rmssd', p.rmssd)],
        seed: 12345,
      );
      for (final f in m.value!.tested) {
        expect(f.lagDays, greaterThanOrEqualTo(0),
            reason: 'no lag may ever run backwards');
      }
      final forward = m.value!.tested
          .firstWhere((f) => f.inputKey == 'strain' && f.outcomeKey == 'rmssd');
      final reverse = m.value!.tested
          .firstWhere((f) => f.inputKey == 'rmssd' && f.outcomeKey == 'strain');
      expect(forward.lagDays, 1);
      expect(reverse.lagDays, 0,
          reason: 'the reverse question is same-day, not yesterday');
      expect(forward.rho.abs(), greaterThan(2 * reverse.rho.abs()),
          reason: 'the planted direction must dominate its own mirror');
    });

    test('a tick-box input gets a group contrast, not fake tertiles', () {
      // Alcohol logged as 0 or 1 has no tertiles — forcing them on produces two
      // cut points that are the same number. It routes to the two groups it
      // actually has, and says so, so the copy can name the right days.
      const days = 140;
      final r = math.Random(19);
      final drank = [for (var i = 0; i < days; i++) (i % 7 == 4 || i % 11 == 0)];
      final rmssd = <double?>[
        for (var i = 0; i < days; i++)
          55.0 - (i > 0 && drank[i - 1] ? 8.0 : 0.0) + 4.0 * _gauss(r)
      ];
      final m = scanAssociations(
        dates: _dates(days),
        variables: [
          _v('alcohol_units', [for (final d in drank) d ? 1.0 : 0.0]),
          _v('rmssd', rmssd),
        ],
        selfReported: associationSelfReportedKeys,
        seed: 44,
      );

      final f = m.value!.findings.singleWhere(
          (f) => f.inputKey == 'alcohol_units' && f.outcomeKey == 'rmssd');
      expect(f.split, ContrastSplit.binary);
      expect(f.caveats, contains('binary_contrast'));
      expect(f.lagDays, 1, reason: 'tonight, not last night');
      expect(f.lowCut, 0.0);
      expect(f.highCut, 1.0, reason: 'the boundary, not the floor repeated');
      expect(f.contrast, lessThan(-3.0));
      expect(f.nLow, greaterThan(f.nHigh));
    });

    test('a weekday-driven association is not published as physiology', () {
      // The classic fake insight: nothing connects these two series except that
      // both are different at the weekend. An engine that correlates raw
      // columns publishes "your screen time wrecks your sleep"; the honest
      // answer is "that is Saturday".
      const days = 140;
      final dates = _dates(days);
      final r = math.Random(4);
      final screens = <double?>[];
      final tst = <double?>[];
      for (var i = 0; i < days; i++) {
        final wd = DateTime.parse(dates[i]).weekday; // Mon=1 … Sun=7
        // Late screens happen on Friday and Saturday EVENINGS...
        screens.add((wd == 5 || wd == 6 ? 240.0 : 90.0) + 15 * _gauss(r));
        // ...and those are the nights labelled Saturday and Sunday, because a
        // night is labelled by the morning it ends on. Lining the fake up with
        // the engine's own derived lag is the point: a confound that the lag
        // accidentally breaks would prove nothing.
        tst.add((wd == 6 || wd == 7 ? 500.0 : 400.0) + 20 * _gauss(r));
      }
      final m = scanAssociations(
        dates: dates,
        variables: [_v('screens_min', screens), _v('tst_min', tst)],
        selfReported: associationSelfReportedKeys,
        seed: 99,
      );

      final row = m.value!.tested
          .where((f) => f.inputKey == 'screens_min' && f.outcomeKey == 'tst_min')
          .toList();
      expect(row, hasLength(1));
      // The raw correlation is enormous and entirely fake.
      expect(row.first.rhoRaw.abs(), greaterThan(0.6));
      // The weekday-adjusted one, which is the one that is tested, is not.
      expect(row.first.rho.abs(), lessThan(0.3));
      expect(row.first.meaningful, isFalse,
          reason: 'this is a weekend, not a finding');
      expect(row.first.caveats, contains('weekday_confounded'));
      expect(row.first.caveats, contains('self_reported_input'));
    });
  });

  group('scanAssociations — the refusals', () {
    test('never reports readiness against its own ingredients', () {
      // Readiness IS a weighted composite of HRV, RHR, respiratory rate and
      // skin temperature. These correlations are guaranteed, enormous, and
      // completely meaningless — we would be reporting our own arithmetic back
      // to the user as a discovery.
      const days = 120;
      final r = math.Random(5);
      final rmssd = _ar1(days, r, mean: 55, sd: 12);
      final rhr = _ar1(days, r, mean: 52, sd: 4);
      final readiness = <double?>[
        for (var i = 0; i < days; i++)
          50 + 0.5 * (rmssd[i]! - 55) - 2.0 * (rhr[i]! - 52)
      ];
      final m = scanAssociations(
        dates: _dates(days),
        variables: [
          _v('rmssd', rmssd),
          _v('rhr', rhr),
          _v('readiness', readiness),
        ],
        seed: 3,
      );

      for (final f in m.value!.tested) {
        final pair = {f.inputKey, f.outcomeKey};
        expect(pair.contains('readiness') && pair.contains('rmssd'), isFalse);
        expect(pair.contains('readiness') && pair.contains('rhr'), isFalse);
      }
      final reasons = {
        for (final r in m.value!.refusals)
          if (r.subject.contains('readiness')) r.reason
      };
      expect(reasons, contains('tautology'));
    });

    test('collapses three ways of measuring the same night into one finding',
        () {
      // Sleep duration, longest unbroken sleep and efficiency are one thing
      // measured three ways here. All three will "predict" the outcome. Showing
      // all three is one insight repeated until it looks like a body of
      // evidence.
      const days = 140;
      final r = math.Random(11);
      final latent = [for (var i = 0; i < days; i++) _gauss(r)];
      final m = scanAssociations(
        dates: _dates(days),
        variables: [
          _v('tst_min', [for (final l in latent) 420 + 45 * l]),
          _v('longest_sleep_min', [
            for (final l in latent) 400 + 42 * l + 4 * _gauss(r)
          ]),
          _v('efficiency', [for (final l in latent) 88 + 5 * l + 0.6 * _gauss(r)]),
          _v('strain', [
            for (var i = 0; i < days; i++) 10 + 2.5 * latent[i] + 1.2 * _gauss(r)
          ]),
        ],
        seed: 21,
      );

      final onStrain =
          m.value!.findings.where((f) => f.outcomeKey == 'strain').toList();
      expect(onStrain, hasLength(1),
          reason: 'three restatements of one night must collapse to one, got '
              '${onStrain.map((f) => f.inputKey).toList()}');

      final suppressed = m.value!.tested.where((f) =>
          f.outcomeKey == 'strain' && f.redundantWith != null);
      expect(suppressed, isNotEmpty,
          reason: 'the collapsed ones stay auditable with a pointer');
      expect(suppressed.first.redundantWith, onStrain.first.inputKey);

      // AND IN THE JSON, which is the shape a UI actually reads — the field
      // being right on the object is worth nothing if it never serialises.
      // `redundant_with` is conditional, so it is exactly the key that can go
      // missing without a single object-level assertion noticing.
      expect(suppressed.first.toJson()['redundant_with'],
          onStrain.first.inputKey);
      expect(onStrain.first.toJson().containsKey('redundant_with'), isFalse,
          reason: 'a finding that stands alone must not carry the key at all');

      final json = m.value!.toJson();
      final testedJson = (json['tested'] as List).cast<Map<String, dynamic>>();
      expect(
        testedJson.where((t) => t['redundant_with'] != null).map(
            (t) => '${t['input']}->${t['outcome']}=${t['redundant_with']}'),
        isNotEmpty,
        reason: 'the pointer has to survive the whole-scan serialisation too',
      );
      for (final t in testedJson) {
        if (t['redundant_with'] != null) {
          expect(t['meaningful'], isFalse,
              reason: 'a suppressed restatement is never also published');
        }
      }
    });

    test('too little history is an absent metric that says how much it needs',
        () {
      const days = 20;
      final r = math.Random(2);
      final m = scanAssociations(
        dates: _dates(days),
        variables: [
          _v('rmssd', _ar1(days, r)),
          _v('strain', _ar1(days, r, mean: 10, sd: 3)),
        ],
        seed: 1,
      );
      expect(m.present, isFalse);
      expect(m.confidence, 0);
      expect(m.note, contains('need_baseline:have=20,need=84'));
    });

    test('a barely-populated field is dropped with a reason, never imputed',
        () {
      const days = 120;
      final r = math.Random(6);
      final sparse = <double?>[
        for (var i = 0; i < days; i++) (i % 12 == 0) ? 2.0 + _gauss(r) : null
      ];
      final m = scanAssociations(
        dates: _dates(days),
        variables: [
          _v('rmssd', _ar1(days, r, mean: 55, sd: 12)),
          _v('strain', _ar1(days, r, mean: 10, sd: 3)),
          _v('alcohol_units', sparse),
        ],
        seed: 8,
      );
      expect(m.present, isTrue);
      for (final f in m.value!.tested) {
        expect(f.inputKey, isNot('alcohol_units'));
      }
      final why = m.value!.refusals
          .firstWhere((r) => r.subject == 'alcohol_units')
          .reason;
      // SPARSE, not need_pairs. Both are true of this column — 10 entries is
      // under the count floor AND under the rate floor — and the two sentences
      // send the user somewhere different. "You need 74 more nights" tells them
      // to wait, and waiting fixes nothing for a field logged one day in
      // twelve. The rate gate is asked first so the copy is the actionable one.
      expect(why, startsWith('sparse:'),
          reason: 'a rarely-logged field is sparse, not merely young');
      expect(why, contains('need=0.5'));
    });

    test('a column with one value in it is refused, not correlated', () {
      // Water logged as the same number every day has no variance to explain
      // anything with. Ranking it invents an ordering nobody reported, and the
      // rank correlation against it is 0/0.
      const days = 120;
      final r = math.Random(41);
      final m = scanAssociations(
        dates: _dates(days),
        variables: [
          _v('rmssd', _ar1(days, r, mean: 55, sd: 12)),
          _v('strain', _ar1(days, r, mean: 10, sd: 3)),
          _v('water_ml', [for (var i = 0; i < days; i++) 2000.0]),
        ],
        seed: 12,
      );
      expect(m.present, isTrue);
      // It passed BOTH data gates — full coverage, 120 days — so `constant` is
      // the only thing that can have caught it.
      expect(
          m.value!.refusals
              .firstWhere((x) => x.subject == 'water_ml')
              .reason,
          'constant');
      for (final t in m.value!.tested) {
        expect(t.inputKey, isNot('water_ml'));
        expect(t.outcomeKey, isNot('water_ml'));
      }
    });

    test('an effect with nobody on one side of it is refused, not described',
        () {
      // Alcohol logged on exactly 2 of 120 days. There is plenty of DATA here —
      // it clears coverage, the count floor and the rank correlation — but the
      // feelable number would be "the median of two nights", and a contrast
      // stated from two days reads exactly like one stated from sixty.
      const days = 120;
      final r = math.Random(23);
      final m = scanAssociations(
        dates: _dates(days),
        variables: [
          _v('rmssd', _ar1(days, r, mean: 55, sd: 12)),
          _v('strain', _ar1(days, r, mean: 10, sd: 3)),
          _v('alcohol_units',
              [for (var i = 0; i < days; i++) (i == 40 || i == 90) ? 1.0 : 0.0]),
        ],
        seed: 14,
      );
      expect(m.present, isTrue, reason: 'the other pairs still ran');
      final why = m.value!.refusals
          .where((x) => x.subject.startsWith('alcohol_units->'))
          .toList();
      expect(why, isNotEmpty);
      for (final x in why) {
        expect(x.reason, 'no_contrast');
      }
      for (final t in m.value!.tested) {
        expect(t.inputKey, isNot('alcohol_units'),
            reason: 'refused pairs must not enter the family the FDR '
                'correction is computed over');
      }
    });

    test('imported days are erased, not blended', () {
      const days = 120;
      final p = math.Random(31);
      final m = scanAssociations(
        dates: _dates(days),
        variables: [
          _v('rmssd', _ar1(days, p, mean: 55, sd: 12)),
          _v('strain', _ar1(days, p, mean: 10, sd: 3)),
        ],
        // Only the last 30 days came off the band.
        measured: [for (var i = 0; i < days; i++) i >= 90],
        seed: 8,
      );
      expect(m.present, isFalse,
          reason: '30 band days is below the gate once imports are removed');
      expect(m.note, contains('have=30'));
      expect(m.note, contains('imported'));
    });

    test('says when the scan was too wide to have answered anything', () {
      // "We found nothing" and "you asked more questions than this much
      // history can answer" are different sentences. The permutation p cannot
      // go below 1/(B+1), so past a certain family size the best possible test
      // still cannot clear its own Benjamini-Hochberg threshold — and an engine
      // that quietly returns an empty list there is lying by omission.
      const days = 120;
      final r = math.Random(3);
      final keys = [
        'rmssd', 'tst_min', 'rhr', 'strain', 'steps', 'stress', 'efficiency',
        'resp_rate', 'deep_min', 'active_min', 'sdnn', 'nap_min',
      ];
      final m = scanAssociations(
        dates: _dates(days),
        variables: [for (final k in keys) _v(k, _ar1(days, r))],
        permutations: 199, // a deliberately coarse null, to force the case
        seed: 2,
      );
      expect(m.present, isTrue);
      expect(m.value!.findings, isEmpty);
      final scanRefusal =
          m.value!.refusals.where((x) => x.subject == 'scan').toList();
      expect(scanRefusal, hasLength(1));
      expect(scanRefusal.first.reason, startsWith('unreachable:'));
      expect(m.note, contains('could have reached significance'));
    });

    test('an unknown key is refused by the catalog, not guessed at', () {
      expect(standardVariable('spo2', const [1.0]), isNull);
      expect(standardVariable('worn_min', const [1.0]), isNull);
      expect(standardVariable('irregular_rhythm_flag', const [1.0]), isNull);
      expect(standardVariable('tst_min', const [1.0]), isNotNull);
    });
  });

  group('scanAssociations — contract', () {
    test('is deterministic', () {
      const days = 120;
      final dates = _dates(days);
      List<DailyVariable> vars() {
        final r = math.Random(15);
        return [
          _v('rmssd', _ar1(days, r, mean: 55, sd: 12)),
          _v('strain', _ar1(days, r, mean: 10, sd: 3)),
          _v('tst_min', _ar1(days, r, mean: 420, sd: 45)),
        ];
      }

      final a = scanAssociations(dates: dates, variables: vars(), seed: 5);
      final b = scanAssociations(dates: dates, variables: vars(), seed: 5);
      expect(a.value!.toJson().toString(), b.value!.toJson().toString());
    });

    test('a misaligned series abstains instead of crashing', () {
      final m = scanAssociations(
        dates: _dates(60),
        variables: [
          _v('rmssd', List<double?>.filled(59, 50)),
        ],
      );
      expect(m.present, isFalse);
      expect(m.note, contains('misaligned_series'));
    });

    test('a repeated key or date abstains instead of overwriting', () {
      // Both index into the grid, so a repeat does not throw — it silently
      // wins, and the survivor gets published under the loser's label and unit.
      // "Your sleep duration moves your recovery" printed off the steps series
      // is the worst thing this file can emit and there is nothing to see.
      const days = 120;
      final r = math.Random(1);
      final dup = scanAssociations(
        dates: _dates(days),
        variables: [
          _v('rmssd', _ar1(days, r, mean: 55, sd: 12)),
          // Same key, a completely different series behind it.
          _v('rmssd', _ar1(days, r, mean: 8000, sd: 2500)),
        ],
      );
      expect(dup.present, isFalse);
      expect(dup.note, contains('duplicate_key:rmssd'));

      final dates = _dates(days);
      final sameDay = [...dates]..[7] = dates[6];
      final dupDate = scanAssociations(
        dates: sameDay,
        variables: [
          _v('rmssd', _ar1(days, r, mean: 55, sd: 12)),
          _v('strain', _ar1(days, r, mean: 10, sd: 3)),
        ],
      );
      expect(dupDate.present, isFalse);
      expect(dupDate.note, contains('duplicate_date:${dates[6]}'));
    });

    test('lags are derived from timing and never negative', () {
      expect(associationLag(VarTiming.night, VarTiming.day), 0);
      expect(associationLag(VarTiming.day, VarTiming.night), 1);
      expect(associationLag(VarTiming.night, VarTiming.night), 1);
      expect(associationLag(VarTiming.day, VarTiming.day), 1);
    });
  });
}
