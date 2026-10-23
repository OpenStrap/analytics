// REGRESSION — the causal stager on the REAL WHOOP-4 overnight capture.
//
// Same fixture as real_night_cardio_stager_test.dart (8 h 54 min, anonymised,
// 1 Hz HR + accel + RR). There are no epoch labels for it — only the Apple
// Watch's whole-night minutes — so what is pinned here is AGREEMENT WITH THE
// RETROSPECTIVE STAGER, not accuracy: the online rules must keep tracking the
// offline ones, abstain only when they should, and keep the REM trigger from
// firing away from REM. `tool/causal_stager_validate.dart` prints the full
// report these bands were set from (kappa 0.369, agreement 70.3 %, causal wake
// 62.5 min vs offline 26.0, REM 78 vs 150 min). Bands are wide on purpose.

import 'dart:io';

import 'package:test/test.dart';
import 'package:openstrap_analytics/onehz.dart';

const double _t0Ms = 1700000010000; // 30 s-aligned

class _Night {
  final List<double> hr = [];
  final List<AccelSample> accel = [];
  final List<double> rr = [], rrTs = [];
}

_Night? _load() {
  final a = File('test/onehz/fixtures/real_night_2026_07_onehz.csv');
  final b = File('test/onehz/fixtures/real_night_2026_07_rr.csv');
  if (!a.existsSync() || !b.existsSync()) return null;
  final n = _Night();
  final l1 = a.readAsLinesSync();
  for (var i = 1; i < l1.length; i++) {
    if (l1[i].trim().isEmpty) continue;
    final p = l1[i].split(',');
    n.hr.add(double.parse(p[1]));
    n.accel.add(AccelSample(double.parse(p[0]) * 1000.0, double.parse(p[2]),
        double.parse(p[3]), double.parse(p[4])));
  }
  final l2 = b.readAsLinesSync();
  for (var i = 1; i < l2.length; i++) {
    if (l2[i].trim().isEmpty) continue;
    final p = l2[i].split(',');
    n.rrTs.add(double.parse(p[0]));
    n.rr.add(double.parse(p[1]));
  }
  return n;
}

List<CausalStageObservation> _replay(_Night n, int toSec,
    {double Function(int sec, double bpm)? hrOf}) {
  final out = <CausalStageObservation>[];
  CausalStagerState? st;
  var rrI = 0;
  for (var t = 30; t <= toSec; t += 30) {
    final lo = t - 30;
    final ts = <double>[], v = <double>[];
    while (rrI < n.rrTs.length && n.rrTs[rrI] < t * 1000.0) {
      ts.add(_t0Ms + n.rrTs[rrI]);
      v.add(n.rr[rrI]);
      rrI++;
    }
    final o = CausalStager.observe(
        CausalSampleWindow(
          nowMs: _t0Ms + t * 1000.0,
          hr: [
            for (var i = lo; i < t; i++)
              HrSample(_t0Ms + i * 1000.0, hrOf?.call(i, n.hr[i]) ?? n.hr[i])
          ],
          accel: [
            for (var i = lo; i < t; i++)
              AccelSample(_t0Ms + i * 1000.0, n.accel[i].x, n.accel[i].y,
                  n.accel[i].z)
          ],
          rr: RrSeries(ts, v),
        ),
        st);
    out.add(o);
    st = o.nextState;
  }
  return out;
}

double _kappa(List<int> a, List<int> b) {
  final n = a.length;
  final m = List.generate(3, (_) => List<int>.filled(3, 0));
  for (var i = 0; i < n; i++) {
    m[a[i]][b[i]]++;
  }
  var po = 0.0, pe = 0.0;
  for (var i = 0; i < 3; i++) {
    po += m[i][i];
    var c = 0;
    for (var j = 0; j < 3; j++) {
      c += m[j][i];
    }
    pe += m[i].reduce((x, y) => x + y) * c / n;
  }
  return (po / n - pe / n) / (1 - pe / n);
}

void main() {
  final night = _load();
  if (night == null) {
    test('real night fixtures not found', () {
      markTestSkipped('real night fixtures not found');
    });
    return;
  }
  final cfg = CausalStagerConfig.defaults;
  final off = cardioStager(night.hr, night.accel,
          rrMs: night.rr, rrTsMs: night.rrTs)
      .base
      .stages;
  const idx = {CausalStage.wake: 0, CausalStage.nrem: 1, CausalStage.rem: 2};
  const base = 1700000010000 ~/ 30000;
  late List<CausalStageObservation> obs;
  setUpAll(() => obs = _replay(night, night.hr.length));

  int offK(CausalStageObservation o) =>
      (o.epochStartMs! / 30000).round() - base;

  test('abstains only while warming up, then stages every epoch', () {
    final absent = obs.where((o) => o.stage == CausalStage.absent).toList();
    expect(absent.length, cfg.warmupEpochs - 1);
    expect(absent.every((o) => o.abstentionReason == CausalAbstention.warmup),
        isTrue);
    expect(obs.last.stage, isNot(CausalStage.absent));
  });

  test('tracks the retrospective stager (kappa and agreement bands)', () {
    final a = <int>[], b = <int>[];
    for (final o in obs.where((o) => o.stage != CausalStage.absent)) {
      final k = offK(o);
      if (k < 0 || k >= off.length) continue;
      a.add(idx[o.stage]!);
      b.add(off[k].index);
    }
    var agree = 0;
    for (var i = 0; i < a.length; i++) {
      if (a[i] == b[i]) agree++;
    }
    expect(agree / a.length, greaterThan(0.62)); // measured 0.703
    expect(_kappa(a, b), greaterThan(0.28)); // measured 0.369
  });

  test('stage minutes stay sane: no wake blow-up, REM not collapsed', () {
    var wake = 0, rem = 0, nrem = 0;
    for (final o in obs.where((o) => o.stage != CausalStage.absent)) {
      switch (o.stage) {
        case CausalStage.wake:
          wake++;
        case CausalStage.rem:
          rem++;
        case CausalStage.nrem:
          nrem++;
        case CausalStage.absent:
          break;
      }
    }
    // Causal wake is NOT Webster-bridged, so it runs above the offline 26 min
    // (measured 62.5). The guard is against the posture-artifact blow-up the
    // 1 g reference window exists to prevent (a 300 s reference gave 104 min).
    expect(wake * 0.5, lessThan(90));
    expect(rem * 0.5, greaterThan(40)); // measured 78
    expect(nrem * 0.5, greaterThan(250)); // measured 374
  });

  test('REM trigger: stable REM lands near offline REM, never far from it',
      () {
    bool offRem(int k) => k >= 0 && k < off.length && off[k] == SleepStage.rem;
    bool near(int k) {
      for (var d = -10; d <= 10; d++) {
        if (offRem(k + d)) return true;
      }
      return false;
    }

    for (final x in [120, 300]) {
      final trig = obs
          .where((o) =>
              o.stage == CausalStage.rem && o.runSec >= x)
          .map(offK)
          .toList();
      expect(trig, isNotEmpty, reason: 'X=$x never fired');
      final far = trig.where((k) => !near(k)).length;
      // measured 0 at X=120 and 300
      expect(far / trig.length, lessThan(0.05), reason: 'X=$x false triggers');
    }
    // X=120 s catches most offline REM bouts inside the bout (measured 11/16).
    final bouts = <(int, int)>[];
    for (var i = 0; i < off.length;) {
      if (!offRem(i)) {
        i++;
        continue;
      }
      var j = i;
      while (j < off.length && offRem(j)) {
        j++;
      }
      bouts.add((i, j));
      i = j;
    }
    final trig = {
      for (final o in obs)
        if (o.stage == CausalStage.rem && o.runSec >= 120) offK(o)
    };
    var caught = 0;
    for (final (s, e) in bouts) {
      if (List.generate(e - s, (i) => s + i).any(trig.contains)) caught++;
    }
    expect(caught / bouts.length, greaterThan(0.5));
  });

  test('the whole replay is deterministic (first 3 h, twice)', () {
    final a = _replay(night, 3 * 3600);
    final b = _replay(night, 3 * 3600);
    for (var i = 0; i < a.length; i++) {
      expect(b[i].toJson().toString(), a[i].toJson().toString());
    }
    // ...and equal to the corresponding prefix of the full replay (causality).
    for (var i = 0; i < a.length; i++) {
      expect(obs[i].toJson().toString(), a[i].toJson().toString());
    }
  });

  test('a strap-off gap mid-night abstains with offWrist, then recovers', () {
    // 4h00-4h10 off-skin (hr 0), everything else untouched.
    const lo = 4 * 3600, hi = 4 * 3600 + 600;
    final r = _replay(night, 5 * 3600,
        hrOf: (s, bpm) => (s >= lo && s < hi) ? 0.0 : bpm);
    var inside = 0;
    for (final o in r) {
      if (o.epochStartMs == null) continue;
      final t = (o.epochStartMs! - _t0Ms) / 1000 + 30; // epoch end, s
      if (t >= lo + 30 && t <= hi) {
        inside++;
        expect(o.stage, CausalStage.absent, reason: 'at ${t}s');
        expect(o.abstentionReason, CausalAbstention.offWrist);
      }
    }
    expect(inside, 20, reason: '10 min = 20 epochs checked');
    final after = r.where((o) =>
        o.epochStartMs != null && (o.epochStartMs! - _t0Ms) / 1000 > hi + 600);
    expect(after.every((o) => o.stage != CausalStage.absent), isTrue);
  });
}
