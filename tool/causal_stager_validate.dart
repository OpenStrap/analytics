// VALIDATION HARNESS — replay a recorded night through the CAUSAL stager and
// score it against the retrospective one.
//
// WHAT THIS CAN AND CANNOT SAY. The only recorded night in the repo
// (test/onehz/fixtures/real_night_2026_07_*.csv) has no epoch labels at all —
// just the Apple Watch's whole-night stage minutes, quoted in
// test/onehz/real_night_cardio_stager_test.dart. There is no PSG-labelled set
// in-tree (the DREAMT corpus behind `tool/stager_harness.dart` lives outside
// the repo). So everything below is AGREEMENT WITH THE OFFLINE STAGER, which
// is itself a kappa-0.13 wrist estimate against PSG. It measures how closely
// the online rules track the retrospective ones and how the "REM, wake now"
// trigger behaves against that reference — NOT stage accuracy. One night, one
// subject: read the numbers as a smoke test with a ruler, not as a result.
//
// Usage:
//   dart run tool/causal_stager_validate.dart [onehz.csv rr.csv] [--step S]
//       [--warmup N]
//   defaults: the in-tree real night, 30 s steps, the shipped warm-up.
//
// Fixture columns: onehz.csv `rel_sec,hr,ax,ay,az`; rr.csv `rel_ms,rr_ms`.

import 'dart:convert';
import 'dart:io';

import 'package:openstrap_analytics/onehz.dart';

const _fixtures = 'test/onehz/fixtures/';

/// Shift the fixture's 0-based clock to a realistic, 30 s-aligned absolute one.
const double _t0Ms = 1700000010000;

void main(List<String> args) {
  final pos = [for (final a in args) if (!a.startsWith('--')) a];
  int intArg(String n, int d) {
    final i = args.indexOf(n);
    return (i >= 0 && i + 1 < args.length) ? int.parse(args[i + 1]) : d;
  }

  final stepSec = intArg('--step', 30);
  final warm = intArg('--warmup', CausalStagerConfig.defaults.warmupEpochs);
  final onehz = pos.isNotEmpty ? pos[0] : '${_fixtures}real_night_2026_07_onehz.csv';
  final rrPath = pos.length > 1 ? pos[1] : '${_fixtures}real_night_2026_07_rr.csv';
  if (!File(onehz).existsSync() || !File(rrPath).existsSync()) {
    stderr.writeln('fixture not found: $onehz / $rrPath');
    exitCode = 66;
    return;
  }
  final night = _load(onehz, rrPath);
  stdout.writeln('night: ${night.hr.length} s '
      '(${(night.hr.length / 3600).toStringAsFixed(2)} h), '
      '${night.rrTs.length} RR beats');

  // ── offline reference ──────────────────────────────────────────────────────
  final off = cardioStager(night.hr, night.accel,
      rrMs: night.rr, rrTsMs: night.rrTs);
  final offStages = off.base.stages;
  final nEp = offStages.length;
  stdout.writeln('offline epochs: $nEp   confidence ${off.confidence}');
  _minutes('offline cardioStager', offStages.map(_name).toList());
  stdout.writeln('Apple Watch reference (summary only): wake 3  REM 162  '
      'light 330  deep 38 min');
  stdout.writeln('');

  // ── causal replay ──────────────────────────────────────────────────────────
  final cfg = CausalStagerConfig(warmupEpochs: warm);
  final run = _replay(night, stepSec, cfg);
  final again = _replay(night, stepSec, cfg);
  final deterministic = _digest(run) == _digest(again);
  stdout.writeln('causal replay: step ${stepSec}s, warm-up $warm epochs '
      '(${warm * 30 / 60} min), deterministic on replay: $deterministic');

  // Latest observation per epoch (a finer step can describe an epoch twice).
  final perEpoch = <int, CausalStageObservation>{};
  for (final o in run) {
    if (o.stage != CausalStage.absent) {
      perEpoch[(o.epochStartMs! / 30000).round()] = o;
    }
  }
  final reasons = <String, int>{};
  for (final o in run) {
    if (o.stage == CausalStage.absent) {
      reasons[o.abstentionReason!.name] =
          (reasons[o.abstentionReason!.name] ?? 0) + 1;
    }
  }
  final base = (_t0Ms / 30000).round();
  stdout.writeln('observations ${run.length}: staged ${run.length - reasons.values.fold(0, (a, b) => a + b)}, '
      'abstained $reasons');
  final causal = List<String?>.filled(nEp, null);
  for (final e in perEpoch.entries) {
    final i = e.key - base;
    if (i >= 0 && i < nEp) causal[i] = e.value.stage.name;
  }
  _minutes('causal (staged epochs only)',
      [for (final c in causal) if (c != null) c]);
  stdout.writeln('');

  // ── agreement, by lag ──────────────────────────────────────────────────────
  // causal(k) is built from TRAILING windows, so it describes the physiology a
  // couple of minutes earlier. Compare causal(k) with offline(k - d).
  stdout.writeln('AGREEMENT with offline cardioStager (staged epochs only)');
  stdout.writeln('  lag d: causal(k) vs offline(k-d)   n      agree   kappa');
  var bestD = 0;
  var bestK = -2.0;
  for (final d in [0, 1, 2, 3, 4, 6, 8]) {
    final a = <int>[], b = <int>[];
    for (var k = d; k < nEp; k++) {
      final c = causal[k];
      if (c == null) continue;
      a.add(_idx(c));
      b.add(_idx(_name(offStages[k - d])));
    }
    final kap = _kappa(a, b);
    if (kap > bestK) {
      bestK = kap;
      bestD = d;
    }
    stdout.writeln('  d=$d (${d * 30}s)${' ' * (21 - '$d (${d * 30}s)'.length)}'
        '${a.length.toString().padLeft(6)}  ${_pct(_agree(a, b))}  ${_f(kap)}');
  }
  stdout.writeln('  best lag: d=$bestD');
  {
    final a = <int>[], b = <int>[];
    for (var k = 0; k < nEp; k++) {
      final c = causal[k];
      if (c == null) continue;
      a.add(_idx(c));
      b.add(_idx(_name(offStages[k])));
    }
    stdout.writeln('');
    stdout.writeln('CONFUSION at d=0 (rows = offline, cols = causal)');
    _confusion(b, a);
  }

  // ── the REM "wake now" use case ────────────────────────────────────────────
  _remTrigger(perEpoch, base, offStages, nEp, causal);

  // ── warm-up sensitivity ────────────────────────────────────────────────────
  stdout.writeln('');
  stdout.writeln('WARM-UP sensitivity (d=0)   warm-up   staged%   agree   kappa');
  for (final w in [20, 40, 60, 120]) {
    final r = _replay(night, 30, CausalStagerConfig(warmupEpochs: w));
    final a = <int>[], b = <int>[];
    var staged = 0;
    for (final o in r) {
      if (o.stage == CausalStage.absent) continue;
      staged++;
      final i = (o.epochStartMs! / 30000).round() - base;
      if (i < 0 || i >= nEp) continue;
      a.add(_idx(o.stage.name));
      b.add(_idx(_name(offStages[i])));
    }
    stdout.writeln('                            ${(w * 0.5).toStringAsFixed(0).padLeft(4)} min '
        '${_pct(staged / nEp)}  ${_pct(_agree(a, b))}  ${_f(_kappa(a, b))}');
  }
}

// ── REM trigger analysis ───────────────────────────────────────────────────────

/// "Wake now" = REM that has persisted for X seconds (`runSec >= X`), the rule
/// a caller would build from the observation. 300 s is [remEpisodeMinMin], the
/// retrospective stager's shortest credible REM bout; the table below shows
/// what shorter thresholds trade.
void _remTrigger(Map<int, CausalStageObservation> perEpoch, int base,
    List<SleepStage> offStages, int nEp, List<String?> causal) {
  bool offRem(int k) => k >= 0 && k < nEp && offStages[k] == SleepStage.rem;
  // Offline REM within +-5 min (10 epochs): trailing windows keep the edges of a
  // bout in view for a few minutes, so "near" is the fair no-false-trigger test.
  bool nearRem(int k) {
    for (var d = -10; d <= 10; d++) {
      if (offRem(k + d)) return true;
    }
    return false;
  }

  bool trigAt(int k, int x) {
    final o = perEpoch[k + base];
    return o != null && o.stage == CausalStage.rem && o.runSec >= x;
  }

  final bouts = <(int, int)>[];
  for (var i = 0; i < nEp;) {
    if (!offRem(i)) {
      i++;
      continue;
    }
    var j = i;
    while (j < nEp && offRem(j)) {
      j++;
    }
    bouts.add((i, j));
    i = j;
  }

  var nStaged = 0, nOffRem = 0, nNear = 0;
  for (var k = 0; k < nEp; k++) {
    if (causal[k] == null) continue;
    nStaged++;
    if (offRem(k)) nOffRem++;
    if (nearRem(k)) nNear++;
  }
  stdout.writeln('');
  stdout.writeln('REM "WAKE NOW" TRIGGER   reference = ${bouts.length} offline REM '
      'bouts as the retrospective stager emits them (several are under 5 min)');
  stdout.writeln('  chance level for a trigger landing on offline REM: '
      '${_pct(nOffRem / nStaged)}; within +-5 min of it: ${_pct(nNear / nStaged)}'
      '  <- the "no false trigger" test is only as strict as this');
  stdout.writeln('  rule: causal stage = rem AND run >= X s');
  stdout.writeln('     X s  trigger epochs  @offlineREM  @+-5min  falseEpochs  '
      'bouts caught (of ${bouts.length})  lateness min (median)  '
      'late-tail epochs');
  for (final x in [60, 120, 180, 300, 420]) {
    final eps = [for (var k = 0; k < nEp; k++) if (trigAt(k, x)) k];
    final onRem = eps.where(offRem).length;
    final near = eps.where(nearRem).length;
    var caught = 0;
    final late = <double>[];
    for (final (s, e) in bouts) {
      for (var k = s; k < e; k++) {
        if (trigAt(k, x)) {
          caught++;
          late.add((k - s) * 0.5);
          break;
        }
      }
    }
    // Trigger epochs that are not REM but follow a bout within 5 min: the
    // late tail, i.e. "woke you just after REM ended".
    final tail = eps.where((k) {
      if (offRem(k)) return false;
      for (var d = 1; d <= 10; d++) {
        if (offRem(k - d)) return true;
      }
      return false;
    }).length;
    String p(int v) => eps.isEmpty ? '  n/a' : _pct(v / eps.length);
    stdout.writeln('  ${x.toString().padLeft(5)}  ${eps.length.toString().padLeft(13)}'
        '  ${p(onRem)}  ${p(near)}  ${(eps.length - near).toString().padLeft(11)}'
        '  ${caught.toString().padLeft(16)}'
        '  ${late.isEmpty ? "n/a".padLeft(20) : _median(late).toStringAsFixed(1).padLeft(20)}'
        '  ${tail.toString().padLeft(16)}');
  }

  stdout.writeln('');
  stdout.writeln('  per offline bout at X=300 / X=120 (first trigger INSIDE the bout):');
  for (final (s, e) in bouts) {
    String f(int x) {
      for (var k = s; k < e; k++) {
        if (trigAt(k, x)) return '+${((k - s) * 0.5).toStringAsFixed(1)} min';
      }
      return 'none';
    }

    stdout.writeln('    ${_hm(s)}-${_hm(e)} (${((e - s) * 0.5).toStringAsFixed(1).padLeft(4)} min)'
        '   X=300: ${f(300).padRight(9)} X=120: ${f(120)}');
  }

  // Natural-Wake-shaped windows: every must-be-up time T on the 30 s grid whose
  // whole window [T-N, T) was observable; fire once, at the first trigger epoch.
  for (final x in [120, 300]) {
    stdout.writeln('');
    stdout.writeln('WINDOW SIMULATION, X=$x s  (fire once at the first trigger '
        'epoch in [T-N, T))');
    stdout.writeln('   N min  windows   fired  @offlineREM  @+-5min  '
        'fired w/o REM near  missed(REM in window)  quiet(no REM)');
    for (final nMin in [15, 30, 60, 120]) {
      final nW = nMin * 2;
      var windows = 0, fired = 0, onRem = 0, near = 0, falseFire = 0;
      var missed = 0, quiet = 0;
      for (var t = nW; t <= nEp; t++) {
        var ok = true;
        for (var k = t - nW; k < t; k++) {
          if (causal[k] == null) {
            ok = false;
            break;
          }
        }
        if (!ok) continue;
        windows++;
        int? f;
        var remInWin = false;
        for (var k = t - nW; k < t; k++) {
          if (f == null && trigAt(k, x)) f = k;
          if (offRem(k)) remInWin = true;
        }
        if (f != null) {
          fired++;
          if (offRem(f)) onRem++;
          if (nearRem(f)) {
            near++;
          } else {
            falseFire++;
          }
        } else if (remInWin) {
          missed++;
        } else {
          quiet++;
        }
      }
      String c(int v, [int w = 9]) => v.toString().padLeft(w);
      stdout.writeln('   ${nMin.toString().padLeft(4)}  ${c(windows)}${c(fired)}'
          '${c(onRem, 13)}${c(near, 9)}${c(falseFire, 19)}${c(missed, 21)}${c(quiet, 15)}');
    }
  }
}

// ── replay + metrics ──────────────────────────────────────────────────────────

List<CausalStageObservation> _replay(
    _Night n, int stepSec, CausalStagerConfig cfg) {
  final out = <CausalStageObservation>[];
  CausalStagerState? st = CausalStagerState.initial(cfg);
  final secs = n.hr.length;
  var rrI = 0;
  for (var t = stepSec; t <= secs; t += stepSec) {
    final lo = t - stepSec;
    final loMs = _t0Ms + lo * 1000.0, hiMs = _t0Ms + t * 1000.0;
    final rrTs = <double>[], rrV = <double>[];
    while (rrI < n.rrTs.length && _t0Ms + n.rrTs[rrI] < hiMs) {
      if (_t0Ms + n.rrTs[rrI] >= loMs) {
        rrTs.add(_t0Ms + n.rrTs[rrI]);
        rrV.add(n.rr[rrI]);
      }
      rrI++;
    }
    final o = CausalStager.observe(
        CausalSampleWindow(
          nowMs: hiMs,
          hr: [
            for (var i = lo; i < t; i++) HrSample(_t0Ms + i * 1000.0, n.hr[i])
          ],
          accel: [
            for (var i = lo; i < t; i++)
              AccelSample(_t0Ms + i * 1000.0, n.accel[i].x, n.accel[i].y,
                  n.accel[i].z)
          ],
          rr: RrSeries(rrTs, rrV),
        ),
        st);
    out.add(o);
    st = o.nextState;
  }
  return out;
}

String _digest(List<CausalStageObservation> r) {
  var h = 0;
  for (final o in r) {
    for (final c in jsonEncode(o.toJson()).codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
  }
  return '$h';
}

class _Night {
  final List<double> hr;
  final List<AccelSample> accel;
  final List<double> rr, rrTs;
  _Night(this.hr, this.accel, this.rr, this.rrTs);
}

_Night _load(String onehz, String rrPath) {
  final hr = <double>[];
  final accel = <AccelSample>[];
  final l1 = File(onehz).readAsLinesSync();
  for (var i = 1; i < l1.length; i++) {
    if (l1[i].trim().isEmpty) continue;
    final p = l1[i].split(',');
    hr.add(double.parse(p[1]));
    accel.add(AccelSample(double.parse(p[0]) * 1000.0, double.parse(p[2]),
        double.parse(p[3]), double.parse(p[4])));
  }
  final rr = <double>[], rrTs = <double>[];
  final l2 = File(rrPath).readAsLinesSync();
  for (var i = 1; i < l2.length; i++) {
    if (l2[i].trim().isEmpty) continue;
    final p = l2[i].split(',');
    rrTs.add(double.parse(p[0]));
    rr.add(double.parse(p[1]));
  }
  return _Night(hr, accel, rr, rrTs);
}

String _name(SleepStage s) => s.name;
int _idx(String s) => const {'wake': 0, 'nrem': 1, 'rem': 2}[s]!;
String _pct(double v) => '${(100 * v).toStringAsFixed(1).padLeft(5)}%';
String _f(double v) => v.isNaN ? '  n/a' : v.toStringAsFixed(3).padLeft(6);
String _hm(int epoch) {
  final m = epoch ~/ 2;
  return '${m ~/ 60}h${(m % 60).toString().padLeft(2, '0')}';
}

double _median(List<double> v) {
  final s = [...v]..sort();
  return s[s.length ~/ 2];
}

void _minutes(String label, List<String> stages) {
  final c = <String, int>{'wake': 0, 'nrem': 0, 'rem': 0};
  for (final s in stages) {
    c[s] = c[s]! + 1;
  }
  stdout.writeln('$label: wake ${c['wake']! / 2} min  nrem ${c['nrem']! / 2} min  '
      'rem ${c['rem']! / 2} min  (${stages.length / 2} min)');
}

double _agree(List<int> a, List<int> b) {
  if (a.isEmpty) return double.nan;
  var m = 0;
  for (var i = 0; i < a.length; i++) {
    if (a[i] == b[i]) m++;
  }
  return m / a.length;
}

double _kappa(List<int> a, List<int> b) {
  final n = a.length;
  if (n == 0) return double.nan;
  final m = List.generate(3, (_) => List<int>.filled(3, 0));
  for (var i = 0; i < n; i++) {
    m[a[i]][b[i]]++;
  }
  var po = 0.0, pe = 0.0;
  for (var i = 0; i < 3; i++) {
    po += m[i][i];
    final r = m[i].reduce((x, y) => x + y);
    var c = 0;
    for (var j = 0; j < 3; j++) {
      c += m[j][i];
    }
    pe += r * c / n;
  }
  po /= n;
  pe /= n;
  return pe >= 1 ? double.nan : (po - pe) / (1 - pe);
}

/// rows = `ref`, cols = `got`.
void _confusion(List<int> ref, List<int> got) {
  const names = ['wake', 'nrem', 'rem'];
  final m = List.generate(3, (_) => List<int>.filled(3, 0));
  for (var i = 0; i < ref.length; i++) {
    m[ref[i]][got[i]]++;
  }
  stdout.writeln('             ${names.map((s) => s.padLeft(7)).join()}   recall');
  for (var i = 0; i < 3; i++) {
    final tot = m[i].reduce((a, b) => a + b);
    stdout.writeln('  ${names[i].padRight(9)}  ${m[i].map((v) => v.toString().padLeft(7)).join()}'
        '  ${tot == 0 ? "   n/a" : _pct(m[i][i] / tot)}');
  }
  final prec = <String>[];
  for (var j = 0; j < 3; j++) {
    var col = 0;
    for (var i = 0; i < 3; i++) {
      col += m[i][j];
    }
    prec.add(col == 0 ? '    n/a' : _pct(m[j][j] / col).padLeft(7));
  }
  stdout.writeln('  precision  ${prec.join()}');
}
