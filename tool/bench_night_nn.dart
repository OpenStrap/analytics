// Measurement tool: three ways to get the night's NN on every overnight derive
// pass. Not a test; no lib/ changes. AOT-friendly, seeded, no I/O except print.
//
//   today : correctRr(sleep-window prefix) every pass          (O(n) per pass)
//   (a)   : per-night RrCorrector, fold only the new beats, snapshot each pass
//           (claimed exact: settled ++ snapshot().tail == correctRr(prefix))
//   (b)   : correct the WHOLE day once, slice the result to the sleep window
//           (differs near the window edges: correctRr clips windows at slice ends)
//
// Day layout: 8 h wake, 8 h sleep, 8 h wake (both window edges are interior to
// the day). 32 passes, one per 15 min of the night; the prefix grows each pass.
//
//   dart compile exe tool/bench_night_nn.dart -o /tmp/bench_night_nn
//   /tmp/bench_night_nn [seed ...]        (default seeds 1 2 3)
import 'dart:math' as math;

import 'package:openstrap_analytics/onehz.dart';

const _startMs = 1.7e12;
const _hMs = 3600e3;
const _sleepStartMs = _startMs + 8 * _hMs;
const _sleepEndMs = _startMs + 16 * _hMs;
const _passMs = 15 * 60e3;
const _passes = 32;

class Day {
  final List<double> rr = [], ts = [];
}

Day synth(int seed) {
  final rnd = math.Random(seed);
  final d = Day();
  final wakeRate = 0.02 + 0.01 * rnd.nextDouble(); // 2..3 % of beats
  final sleepRate = 0.005 + 0.01 * rnd.nextDouble(); // 0.5..1.5 %
  var t = 0.0; // ms since start
  final phase = rnd.nextDouble() * 6.28;
  void emit(double v) {
    v = v.roundToDouble();
    t += v;
    d.rr.add(v);
    d.ts.add(((_startMs + t) / 1000).floorToDouble() * 1000);
  }

  // Multi-beat garbage runs (4..8 beats) and one 2-min dropout inside the sleep.
  final runAt = [
    for (var i = 0; i < 3; i++) 8 * 3600e3 + (1 + 6 * rnd.nextDouble()) * _hMs
  ]..sort();
  final dropAt = 8 * 3600e3 + (2 + 4 * rnd.nextDouble()) * _hMs;
  var runIdx = 0;
  var dropped = false;
  const endT = 24 * 3600e3;
  while (t < endT) {
    final sleep = t >= 8 * 3600e3 && t < 16 * 3600e3;
    final s = t / 1000;
    final bpm = sleep
        ? 57 + 7 * math.sin(s / 5400 + seed)
        : 85 + 13 * math.sin(s / 1900 + seed);
    final base = 60000 / bpm;
    final v = base +
        (sleep ? 28 : 14) * math.sin(2 * math.pi * (sleep ? .24 : .27) * s + phase) +
        18 * math.sin(2 * math.pi * 0.1 * s) +
        (sleep ? 6 : 8) * (rnd.nextDouble() - .5) * 2;
    if (sleep && !dropped && t >= dropAt) {
      dropped = true;
      t += 120e3;
      continue;
    }
    if (sleep && runIdx < runAt.length && t >= runAt[runIdx]) {
      runIdx++;
      final len = 4 + rnd.nextInt(5);
      for (var k = 0; k < len; k++) {
        emit(250 + rnd.nextInt(2100).toDouble());
      }
      continue;
    }
    if (rnd.nextDouble() < (sleep ? sleepRate : wakeRate)) {
      final u = rnd.nextDouble();
      if (u < 0.4) {
        emit(v * (0.55 + 0.15 * rnd.nextDouble())); // ectopic + pause
        emit(v * (1.3 + 0.2 * rnd.nextDouble()));
      } else if (u < 0.6) {
        emit(v * (1.9 + 0.2 * rnd.nextDouble())); // missed beat
      } else if (u < 0.85) {
        final f = 0.35 + 0.3 * rnd.nextDouble(); // extra beat
        emit(v * f);
        emit(v * (1 - f));
      } else {
        emit(250 + rnd.nextInt(2100).toDouble()); // lone garbage beat
      }
      continue;
    }
    emit(v);
  }
  return d;
}

/// Replica of correctRr's private clock, so whole-day output can be mapped back
/// to input beat indices (the kept beats' times are tAll[i] bit for bit).
List<double> beatTimes(List<double> rr, List<double> ts) {
  final t = List<double>.filled(rr.length, 0);
  final origin = ts[0] - rr[0];
  var cur = 0.0;
  for (var i = 0; i < rr.length; i++) {
    final dropout = i > 0 && (ts[i] - ts[i - 1]) - rr[i] > 1000;
    final anchored = ts[i] - origin;
    cur = (dropout && anchored > cur) ? anchored : cur + rr[i];
    t[i] = cur;
  }
  return t;
}

int lowerBound(List<double> a, double x, [int lo = 0]) {
  var hi = a.length;
  while (lo < hi) {
    final m = (lo + hi) >> 1;
    if (a[m] < x) {
      lo = m + 1;
    } else {
      hi = m;
    }
  }
  return lo;
}

/// beat index -> NN value for one correctRr result (kept beats only).
Map<int, double> byBeat(RrCorrectionResult r, List<double> tAll, int offset) {
  final m = <int, double>{};
  var j = 0;
  for (var k = 0; k < r.nn.length; k++) {
    j = lowerBound(tAll, r.nnTimesMs[k], j);
    if (tAll[j] != r.nnTimesMs[k]) throw StateError('beat map broke');
    m[j + offset] = r.nn[k];
  }
  return m;
}

class Down {
  final double? rmssd, sdnn, pnn50, dc, ac, lf, hf, total;
  Down(this.rmssd, this.sdnn, this.pnn50, this.dc, this.ac, this.lf, this.hf,
      this.total);
  List<double?> get all => [rmssd, sdnn, pnn50, dc, ac, lf, hf, total];
  static const names = ['RMSSD', 'SDNN', 'pNN50', 'DC', 'AC', 'LF', 'HF', 'TotP'];
}

Down downstream(List<double> nn, List<double> times, double clean) {
  final art = 1 - clean;
  final h = hrvTime(nn, nnTimesMs: times, artifactFraction: art).value;
  final dc = decelerationCapacity(nn).value;
  final ac = accelerationCapacity(nn).value;
  final f = hrvFreq(nn, times, artifactFraction: art).value;
  return Down(h?.rmssd, h?.sdnn, h?.pnn50, dc?.capacity, ac?.capacity, f?.lf,
      f?.hf, f?.total);
}

String ms(int us) => (us / 1000).toStringAsFixed(2);
String f(double? x, [int p = 3]) => x == null ? 'null' : x.toStringAsFixed(p);

bool sameList(List<double> a, List<double> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

void run(int seed) {
  final day = synth(seed);
  final n = day.rr.length;
  final i0 = lowerBound(day.ts, _sleepStartMs);
  final i1All = lowerBound(day.ts, _sleepEndMs);
  print('\n==== seed $seed: day $n beats, sleep window beats [$i0,$i1All) '
      '= ${i1All - i0} ====');

  // Whole day, as edge already does: fold (timed) then derive the day result.
  final swW = Stopwatch()..start();
  final dayCorr = RrCorrector();
  dayCorr.fold(day.rr, tsMs: day.ts);
  dayCorr.snapshot();
  swW.stop();
  final swWd = Stopwatch()..start();
  final whole = correctRr(day.rr, rrTsMs: day.ts);
  swWd.stop();
  final tWhole = beatTimes(day.rr, day.ts);
  final wholeMap = byBeat(whole, tWhole, 0);
  // normal-beat prefix sums for (b)'s cleanFraction
  final normPre = List<int>.filled(n + 1, 0);
  for (var i = 0; i < n; i++) {
    normPre[i + 1] = normPre[i] + (whole.classes[i] == BeatClass.normal ? 1 : 0);
  }

  // (a) state
  final corr = RrCorrector();
  final aNn = <double>[], aT = <double>[];
  var folded = i0;

  final tToday = <int>[], tA = <int>[], tB = <int>[];
  final exact = <bool>[];
  final diffCnt = <int>[], diffMaxMs = <double>[], dClean = <double>[];
  final nearStart = <int>[], nearEnd = <int>[]; // diffs within 60 s of an edge
  final farDiff = <int>[]; // diffs > 300 s from both edges
  final worstEdgeS = <double>[]; // max over diffs of min(dist start, dist end)
  final rel = List.generate(8, (_) => <double>[]);
  final abs = List.generate(8, (_) => <double>[]);
  Down? finalToday, finalB;
  var finalLine = '';

  for (var p = 1; p <= _passes; p++) {
    final cut = _sleepStartMs + p * _passMs;
    final i1 = lowerBound(day.ts, cut);
    final rr = day.rr.sublist(i0, i1), ts = day.ts.sublist(i0, i1);

    final sw = Stopwatch()..start();
    final today = correctRr(rr, rrTsMs: ts);
    sw.stop();
    tToday.add(sw.elapsedMicroseconds);

    sw
      ..reset()
      ..start();
    final settled = corr.fold(day.rr.sublist(folded, i1),
        tsMs: day.ts.sublist(folded, i1));
    folded = i1;
    aNn.addAll(settled.nn);
    aT.addAll(settled.nnTimes);
    final snap = corr.snapshot();
    final aOutNn = [...aNn, ...snap.tailNn];
    final aOutT = [...aT, ...snap.tailNnTimes];
    final aClean = snap.cleanFraction;
    sw.stop();
    tA.add(sw.elapsedMicroseconds);
    exact.add(sameList(aOutNn, today.nn) &&
        sameList(aOutT, today.nnTimesMs) &&
        aClean == today.cleanFraction);

    sw
      ..reset()
      ..start();
    final bNn = <double>[], bT = <double>[];
    final base = tWhole[i0];
    final lo = lowerBound(whole.nnTimesMs, tWhole[i0]);
    final hi = lowerBound(whole.nnTimesMs, tWhole[i1 - 1], lo);
    final hiIncl = (hi < whole.nn.length && whole.nnTimesMs[hi] == tWhole[i1 - 1])
        ? hi + 1
        : hi;
    for (var k = lo; k < hiIncl; k++) {
      bNn.add(whole.nn[k]);
      bT.add(whole.nnTimesMs[k] - base + rr[0]); // rebase to the slice's frame
    }
    final bClean = (normPre[i1] - normPre[i0]) / (i1 - i0);
    sw.stop();
    tB.add(sw.elapsedMicroseconds);

    // Diff by input beat index.
    final tAllToday = beatTimes(rr, ts);
    final tm = byBeat(today, tAllToday, i0);
    var cnt = 0, near0 = 0, near1 = 0, far = 0;
    var mx = 0.0, worst = 0.0;
    final keys = {...tm.keys, ...wholeMap.keys.where((k) => k >= i0 && k < i1)};
    for (final k in keys) {
      final x = tm[k], y = wholeMap[k];
      if (x != null && y != null && x == y) continue;
      cnt++;
      if (x != null && y != null) mx = math.max(mx, (x - y).abs());
      final ds = (day.ts[k] - _sleepStartMs) / 1000;
      final de = (cut - day.ts[k]) / 1000;
      final dm = math.min(ds, de);
      if (ds <= 60) near0++;
      if (de <= 60) near1++;
      if (dm > 300) far++;
      worst = math.max(worst, dm);
    }
    diffCnt.add(cnt);
    diffMaxMs.add(mx);
    dClean.add(bClean - today.cleanFraction);
    nearStart.add(near0);
    nearEnd.add(near1);
    farDiff.add(far);
    worstEdgeS.add(worst);

    final dt = downstream(today.nn, today.nnTimesMs, today.cleanFraction);
    final db = downstream(bNn, bT, bClean);
    for (var m = 0; m < 8; m++) {
      final x = dt.all[m], y = db.all[m];
      if (x == null || y == null) continue;
      abs[m].add((y - x).abs());
      rel[m].add(x == 0 ? 0 : (y - x).abs() / x.abs() * 100);
    }
    if (p == _passes) {
      finalToday = dt;
      finalB = db;
      finalLine = 'final pass: today nn=${today.nn.length} clean='
          '${today.cleanFraction.toStringAsFixed(5)} | (b) nn=${bNn.length} '
          'clean=${bClean.toStringAsFixed(5)}';
    }
  }

  double sum(Iterable<num> x) => x.fold(0.0, (a, b) => a + b);
  double mean(List<num> x) => x.isEmpty ? 0 : sum(x) / x.length;
  double lastHalf(List<int> x) => mean(x.sublist(x.length ~/ 2));

  print('-- 1. time (ms), AOT, single run per pass --');
  print('pass:   ${[1, 8, 16, 24, 32].map((p) => 'p$p').join('      ')}');
  String row(String name, List<int> t) =>
      '${name.padRight(8)}${[1, 8, 16, 24, 32].map((p) => ms(t[p - 1]).padLeft(8)).join()}'
      '   total ${ms(t.fold(0, (a, b) => a + b)).padLeft(9)}'
      '   mean/pass ${ms((sum(t) / t.length).round())}'
      '   mean last16 ${(lastHalf(t) / 1000).toStringAsFixed(2)}';
  print(row('today', tToday));
  print(row('(a)', tA));
  print(row('(b)', tB));
  print('whole-day RrCorrector fold+snapshot (paid by edge): ${ms(swW.elapsedMicroseconds)} ms;'
      ' whole-day correctRr: ${ms(swWd.elapsedMicroseconds)} ms');

  print('-- 2. exactness of (a) vs today: all $_passes passes bit-identical = '
      '${exact.every((e) => e)}  (${exact.where((e) => e).length}/$_passes) --');

  print('-- 3. (b) vs today --');
  print(finalLine);
  print('differing NN beats (changed value or kept in one only):');
  print('  final pass : ${diffCnt.last} of '
      '${i1All - i0} beats; within 60 s of window start ${nearStart.last}, '
      'of window end ${nearEnd.last}, >300 s from both ${farDiff.last}; '
      'farthest from an edge ${worstEdgeS.last.toStringAsFixed(1)} s; '
      'max |dNN| ${diffMaxMs.last.toStringAsFixed(1)} ms; '
      'dClean ${dClean.last.toStringAsExponential(2)}');
  print('  mean/pass  : ${mean(diffCnt).toStringAsFixed(1)} beats; '
      'within 60 s of start ${mean(nearStart).toStringAsFixed(1)}, of end '
      '${mean(nearEnd).toStringAsFixed(1)}, >300 s from both '
      '${mean(farDiff).toStringAsFixed(1)}; farthest max over passes '
      '${worstEdgeS.reduce(math.max).toStringAsFixed(1)} s; '
      'max |dNN| over passes ${diffMaxMs.reduce(math.max).toStringAsFixed(1)} ms; '
      'mean |dClean| ${mean([for (final x in dClean) x.abs()]).toStringAsExponential(2)}');
  print('downstream: metric | today(final) | (b)(final) | abs d final | rel% final'
      ' | mean abs d | mean rel%');
  for (var m = 0; m < 8; m++) {
    final x = finalToday!.all[m], y = finalB!.all[m];
    final ad = (x == null || y == null) ? null : (y - x).abs();
    final rd = (ad == null || x == 0) ? null : ad / x!.abs() * 100;
    print('  ${Down.names[m].padRight(6)}| ${f(x).padLeft(11)} | ${f(y).padLeft(11)}'
        ' | ${f(ad, 4).padLeft(9)} | ${f(rd, 3).padLeft(8)} | '
        '${f(mean(abs[m]), 4).padLeft(9)} | ${f(mean(rel[m]), 3).padLeft(8)}');
  }
}

void main(List<String> args) {
  final seeds = args.isEmpty ? [1, 2, 3] : args.map(int.parse).toList();
  for (final s in seeds) {
    run(s);
  }
}
