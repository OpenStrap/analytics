// RED (round 22): exact streaming CVHR.
//
// CvhrStream.snapshot(...) must equal cvhrApneaScreen(folded ++ tail, ...) BIT
// FOR BIT at every fold: == on doubles, same NaN-ness and sign of zero, same
// note, confidence, quartiles. No tolerance. The batch function is the
// reference and does not change in this round.
//
// Locality facts the tests lean on (checked against cvhr_apnea.dart):
//  * 1 Hz resample at grid g needs the beat bracketing g. A beat AT g that is
//    the last beat clamps to y.last, but once a later beat exists the same
//    point is y[j] + (y[j+1]-y[j]) * 1.0, which can differ in the last bit,
//    so the on-the-grid tests below feed beats exactly on whole seconds.
//  * Savitzky-Golay reads +-7 grid points, the median +-65 s (clipped at the
//    segment ends); P75, prominence and run detection read the whole segment.
import 'dart:convert';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

// ───────────────────────── synthetic nights ─────────────────────────────────

class Night {
  final List<double> nn = [], times = [];
}

/// A seeded night of [hours]: ~1000 ms NN with breathing and noise. With
/// [apnea], 30-60 s cyclic bradycardia (+80 ms half-sine bumps, 20 s wide,
/// every 45 s; the period wobbles per stretch) over alternating stretches of
/// the night. [jumps] are (atSec, lengthSec) holes in the recording clock.
/// [fast] = (fromSec, toSec) runs 500 ms NN there (>= 60 beats in < 60 s).
Night synth(int seed, double hours,
    {bool apnea = true,
    List<(double, double)> jumps = const [],
    (double, double)? fast}) {
  final rnd = math.Random(seed);
  final n = Night();
  final endS = hours * 3600;
  var s = 0.0; // recording clock, seconds
  var t = 1.7e12; // beat clock, ms
  final phase = rnd.nextDouble() * 6.28;
  final jl = [...jumps]..sort((a, b) => a.$1.compareTo(b.$1));
  var ji = 0;
  while (s < endS) {
    while (ji < jl.length && s >= jl[ji].$1) {
      t += jl[ji].$2 * 1000;
      s += jl[ji].$2;
      ji++;
    }
    var v = 1000.0 +
        25 * math.sin(2 * math.pi * 0.24 * s + phase) +
        30 * math.sin(s / 900 + seed) +
        6 * (rnd.nextDouble() - .5) * 2;
    if (apnea) {
      // Stretches of 12 min with events, 8 min without.
      final stretch = (s % 1200);
      if (stretch < 720) {
        final period = 45.0 + 5 * (s ~/ 1200 % 3);
        final u = s % period;
        if (u < 20) v += 80 * math.sin(math.pi * u / 20);
      }
    }
    if (fast != null && s >= fast.$1 && s < fast.$2) v = 500;
    v = v.roundToDouble();
    t += v;
    s += v / 1000;
    n.nn.add(v);
    n.times.add(t);
  }
  return n;
}

// ───────────────────────── bit-for-bit comparison ───────────────────────────

bool sameD(double? a, double? b) {
  if (a == null || b == null) return a == null && b == null;
  if (a.isNaN || b.isNaN) return a.isNaN && b.isNaN;
  return a == b && a.isNegative == b.isNegative;
}

/// Empty string when equal, else the first difference. (A String so it can
/// cross an isolate boundary.)
String diffD(double? a, double? b, String what) =>
    sameD(a, b) ? '' : '$what: $a vs $b; ';

String diffList(List<double>? a, List<double>? b, String what) {
  if (a == null || b == null) return a == null && b == null ? '' : '$what null; ';
  if (a.length != b.length) return '$what length; ';
  final sb = StringBuffer();
  for (var i = 0; i < a.length; i++) {
    sb.write(diffD(a[i], b[i], '$what[$i]'));
  }
  return sb.toString();
}

String diffCvhr(Metric<CvhrResult> a, Metric<CvhrResult> b) {
  final sb = StringBuffer();
  if ((a.value == null) != (b.value == null)) return 'value presence; ';
  sb.write(diffD(a.confidence, b.confidence, 'confidence'));
  if (a.tier != b.tier) sb.write('tier; ');
  if ('${a.inputs_used}' != '${b.inputs_used}') sb.write('inputs; ');
  if (a.note != b.note) sb.write('note "${a.note}" vs "${b.note}"; ');
  if ((a.drivers == null) != (b.drivers == null)) sb.write('drivers; ');
  final x = a.value, y = b.value;
  if (x == null || y == null) return sb.toString();
  if (x.cycleCount != y.cycleCount) {
    sb.write('cycleCount ${x.cycleCount} vs ${y.cycleCount}; ');
  }
  sb.write(diffD(x.cvhrPerHour, y.cvhrPerHour, 'cvhrPerHour'));
  sb.write(diffD(x.analyzedHours, y.analyzedHours, 'analyzedHours'));
  sb.write(diffD(x.meanDepthMs, y.meanDepthMs, 'meanDepthMs'));
  sb.write(diffD(x.meanWidthSec, y.meanWidthSec, 'meanWidthSec'));
  sb.write(diffList(x.depthQuartilesMs, y.depthQuartilesMs, 'depthQ'));
  sb.write(diffList(x.widthQuartilesSec, y.widthQuartilesSec, 'widthQ'));
  return sb.toString();
}

void expectSame(Metric<CvhrResult> a, Metric<CvhrResult> b, String at) =>
    expect(diffCvhr(a, b), '', reason: at);

// ───────────────────────── drivers ──────────────────────────────────────────

/// Chunk boundaries (beat counts) with random sizes in [lo, hi], starting small
/// so the first folds sit below the 60-beat gate.
List<int> chunkEnds(int n, math.Random rnd, int lo, int hi, {int first = 20}) {
  final ends = <int>[];
  var at = first;
  while (at < n) {
    ends.add(at);
    at += lo + rnd.nextInt(hi - lo + 1);
  }
  ends.add(n);
  return ends;
}

Metric<CvhrResult> batch(List<double> nn, List<double> t, int end, double af,
        {double minW = 10,
        double maxW = 120,
        double ratio = 0.7,
        double env = 130,
        double maxA = 0.30,
        double gap = 30}) =>
    cvhrApneaScreen(nn.sublist(0, end), t.sublist(0, end),
        artifactFraction: af,
        minWidthSec: minW,
        maxWidthSec: maxW,
        depthWidthRatioMin: ratio,
        envWindowSec: env,
        maxArtifact: maxA,
        maxGapSec: gap);

/// Fold [nn]/[t] by [ends]; after each fold compare an empty-tail and a
/// [tailBeats]-tail snapshot against the batch. Returns the first mismatch
/// ('' when none) so it can run inside an isolate.
String parity(List<double> nn, List<double> t, List<int> ends, double af,
    {int tailBeats = 100,
    double minW = 10,
    double maxW = 120,
    double ratio = 0.7,
    double env = 130,
    double maxA = 0.30,
    double gap = 30}) {
  final s = CvhrStream(
      minWidthSec: minW,
      maxWidthSec: maxW,
      depthWidthRatioMin: ratio,
      envWindowSec: env,
      maxGapSec: gap);
  var from = 0;
  for (final end in ends) {
    s.fold(nn.sublist(from, end), t.sublist(from, end));
    from = end;
    var d = diffCvhr(
        s.snapshot(artifactFraction: af, maxArtifact: maxA),
        batch(nn, t, end, af,
            minW: minW,
            maxW: maxW,
            ratio: ratio,
            env: env,
            maxA: maxA,
            gap: gap));
    if (d.isNotEmpty) return 'prefix $end: $d';
    final tEnd = math.min(nn.length, end + tailBeats);
    d = diffCvhr(
        s.snapshot(
            tailNnMs: nn.sublist(end, tEnd),
            tailNnTimesMs: t.sublist(end, tEnd),
            artifactFraction: af,
            maxArtifact: maxA),
        batch(nn, t, tEnd, af,
            minW: minW,
            maxW: maxW,
            ratio: ratio,
            env: env,
            maxA: maxA,
            gap: gap));
    if (d.isNotEmpty) return 'prefix $end + tail ${tEnd - end}: $d';
  }
  return '';
}

void expectParity(Night n, List<int> ends, double af,
        {int tailBeats = 100,
        double minW = 10,
        double maxW = 120,
        double ratio = 0.7,
        double env = 130,
        double maxA = 0.30,
        double gap = 30}) =>
    expect(
        parity(n.nn, n.times, ends, af,
            tailBeats: tailBeats,
            minW: minW,
            maxW: maxW,
            ratio: ratio,
            env: env,
            maxA: maxA,
            gap: gap),
        '');

/// Isolate entry: msg = [SendPort, nn, t, ends, af]. A hang cannot be
/// interrupted by the test timeout, so the run is killed after 20 s.
void _entry(List<Object> msg) {
  final port = msg[0] as SendPort;
  final nn = (msg[1] as List).cast<double>();
  final t = (msg[2] as List).cast<double>();
  final ends = (msg[3] as List).cast<int>();
  port.send(parity(nn, t, ends, msg[4] as double, tailBeats: 60));
}

Future<String> parityIsolated(
    List<double> nn, List<double> t, List<int> ends, double af) async {
  final rp = ReceivePort();
  final iso =
      await Isolate.spawn(_entry, <Object>[rp.sendPort, nn, t, ends, af]);
  try {
    return await rp.first.timeout(const Duration(seconds: 20)) as String;
  } finally {
    iso.kill(priority: Isolate.immediate);
    rp.close();
  }
}

Object? wire(Map<String, dynamic> j) => jsonDecode(jsonEncode(j));

void expectMalformedRejected(
    Map<String, dynamic> good, Object? Function(Map<String, dynamic>) revive) {
  for (final k in good.keys) {
    final missing = Map<String, dynamic>.from(good)..remove(k);
    expect(() => revive(missing), throwsFormatException, reason: 'missing $k');
    final wrong = Map<String, dynamic>.from(good)..[k] = {'bogus': true};
    expect(() => revive(wrong), throwsFormatException, reason: 'wrong $k');
  }
  expect(() => revive(<String, dynamic>{}), throwsFormatException);
  expect(() => revive({...good, 'type': 'NotAStream'}), throwsFormatException);
  expect(() => revive({...good, 'version': 9999}), throwsFormatException);
  expect(() => revive({...good, 'version': 'one'}), throwsFormatException);
}

// Holes: two > 30 s gaps, a 45 s island (< 60 beats), a 40 s island of 500 ms
// beats (>= 60 beats, span < 60 s), then a long tail segment.
const _gappy = <(double, double)>[
  (2400, 90),
  (3000, 60),
  (3045, 60),
  (5000, 45),
  (5040, 70),
  (7000, 31),
];

void main() {
  group('guards: the generator really produces CVHR cycles', () {
    test('batch finds cycles on the apnea night and few on the plain one', () {
      final a = synth(1, 3);
      final r = batch(a.nn, a.times, a.nn.length, 0.02).value!;
      expect(r.cycleCount, greaterThan(20));
      expect(r.depthQuartilesMs, isNotNull);
      final p = synth(1, 3, apnea: false);
      final q = batch(p.nn, p.times, p.nn.length, 0.02).value!;
      expect(q.cycleCount, lessThan(r.cycleCount ~/ 4));
    });

    test('gappy night: several segments, cycles found, short islands skipped',
        () {
      final g = synth(2, 3, jumps: _gappy, fast: (5000, 5040));
      final r = batch(g.nn, g.times, g.nn.length, 0.02).value!;
      expect(r.cycleCount, greaterThan(10));
      final whole = synth(2, 3, fast: (5000, 5040));
      expect(r.analyzedHours,
          lessThan(batch(whole.nn, whole.times, whole.nn.length, 0.02)
              .value!
              .analyzedHours));
    });
  });

  group('CvhrStream with nothing (or almost nothing) folded', () {
    Metric<CvhrResult> viaTail(List<double> nn, List<double> t, int folded,
        int end, double af) {
      final s = CvhrStream();
      if (folded > 0) s.fold(nn.sublist(0, folded), t.sublist(0, folded));
      return s.snapshot(
          tailNnMs: nn.sublist(folded, end),
          tailNnTimesMs: t.sublist(folded, end),
          artifactFraction: af);
    }

    void expectEmptyPrefix(Night n, List<int> ks, {int folded = 0}) {
      for (final k in ks) {
        final end = math.min(k, n.nn.length);
        if (end <= folded) continue;
        expectSame(viaTail(n.nn, n.times, folded, end, 0.02),
            batch(n.nn, n.times, end, 0.02), 'folded $folded tail ${end - folded}');
      }
    }

    test('fresh stream, tail across the 60-beat gate', () {
      final n = synth(81, 1);
      expectEmptyPrefix(n, [1, 2, 3, 30, 58, 59, 60, 61, 62, 100, 400]);
    });

    test('fresh stream, tail is a full 2 h night', () {
      final n = synth(82, 2);
      expectEmptyPrefix(n, [n.nn.length]);
    });

    test('fresh stream, tail with gaps > maxGapSec and short islands', () {
      final n = synth(83, 3, jumps: _gappy, fast: (5000, 5040));
      expectEmptyPrefix(n, [200, 1500, 3000, 6000, n.nn.length]);
      // gaps right at the tail edge
      final cuts = <int>[];
      for (var i = 1; i < n.times.length; i++) {
        if (n.times[i] - n.times[i - 1] > 30000) cuts.addAll([i - 1, i, i + 1]);
      }
      expectEmptyPrefix(n, cuts.where((c) => c > 0).toList());
    });

    test('a few folded beats (below any segment) plus a long tail', () {
      final n = synth(84, 2, jumps: const [(2400, 90)]);
      for (final f in [1, 5, 30, 59, 60]) {
        expectEmptyPrefix(n, [f + 1, f + 30, f + 61, n.nn.length], folded: f);
      }
    });
  });

  group('CvhrStream parity', () {
    test('no gaps, apnea cycles present (3 h), random chunks', () {
      final n = synth(3, 3);
      expectParity(n, chunkEnds(n.nn.length, math.Random(31), 300, 1400), 0.02);
    });

    test('no gaps, cycles absent (2 h)', () {
      final n = synth(4, 2, apnea: false);
      expectParity(n, chunkEnds(n.nn.length, math.Random(41), 300, 1400), 0.02);
    });

    test('several >30 s gaps and short islands (3 h)', () {
      final n = synth(5, 3, jumps: _gappy, fast: (5000, 5040));
      final ends = chunkEnds(n.nn.length, math.Random(51), 150, 900);
      expectParity(n, ends, 0.02);
    });

    test('folds that end exactly at, just before and just after each gap', () {
      final n = synth(6, 1.5, jumps: const [(1500, 40), (3000, 35)]);
      final ends = <int>{n.nn.length};
      for (var i = 1; i < n.times.length; i++) {
        if (n.times[i] - n.times[i - 1] > 30000) {
          for (final d in [-2, -1, 0, 1, 2]) {
            ends.add(i + d);
          }
        }
      }
      final sorted = ends.where((e) => e > 20).toList()..sort();
      expect(sorted.length, greaterThan(6));
      expectParity(n, sorted, 0.02, tailBeats: 30);
    });

    test('gap of exactly maxGapSec stays one segment, +1 ms splits it', () {
      for (final extra in [0.0, 1.0]) {
        final nn = <double>[], t = <double>[];
        var clock = 0.0;
        final rnd = math.Random(61);
        for (var i = 0; i < 500; i++) {
          nn.add(1000 + 40 * math.sin(i / 7) + 10 * rnd.nextDouble());
          clock += 1000;
          if (i == 250) clock += 29000 + extra; // 30 000 (+1) ms between beats
          t.add(clock);
        }
        final ends = [30, 200, 250, 251, 252, 400, 500];
        expect(parity(nn, t, ends, 0.02), '', reason: 'extra=$extra');
        expect(parity(nn, t, ends, 0.02, gap: 10), '', reason: 'gap 10');
      }
    });

    test('beats exactly on whole seconds, beat by beat (resample edge)', () {
      // nn is independent of the times, so every grid point lands exactly on a
      // beat; duplicate times (non-decreasing) are mixed in.
      final rnd = math.Random(71);
      final nn = <double>[], t = <double>[];
      var clock = 5000.0;
      for (var i = 0; i < 420; i++) {
        nn.add(700 + 300 * rnd.nextDouble() + 90 * math.sin(i / 9));
        if (i % 37 != 36) clock += 1000;
        t.add(clock);
      }
      expect(parity(nn, t, [for (var e = 61; e <= 420; e++) e], 0.02,
              tailBeats: 3),
          '');
    });

    test('single-beat folds across 70 min of a segment (median window edges)',
        () {
      final n = synth(8, 1.2);
      final ends = [for (var e = 40; e <= 400; e += 1) e] +
          [for (var e = 400; e <= n.nn.length; e += 97) e];
      expectParity(n, ends, 0.02, tailBeats: 0);
    });

    test('artifact gate on / off and near the threshold', () {
      final n = synth(9, 1.5);
      final ends = chunkEnds(n.nn.length, math.Random(91), 400, 1200);
      for (final af in [0.0, 0.1, 0.30, 0.3000001, 0.5]) {
        expectParity(n, ends, af);
      }
      expectParity(n, ends, 0.2, maxA: 0.1);
      expectParity(n, ends, 0.2, maxA: 0.25);
    });

    test('non-default options', () {
      final n = synth(10, 1.5);
      final ends = chunkEnds(n.nn.length, math.Random(101), 300, 1000);
      expectParity(n, ends, 0.02, minW: 15, maxW: 90);
      expectParity(n, ends, 0.02, ratio: 0.4);
      expectParity(n, ends, 0.02, env: 90); // half = 45
      expectParity(n, ends, 0.02, env: 131); // half = round(65.5) = 66
      expectParity(n, ends, 0.02, gap: 5);
    });

    test('absent paths: fresh stream, <60 beats, degenerate times', () {
      final s = CvhrStream();
      expectSame(s.snapshot(artifactFraction: 0),
          cvhrApneaScreen(const [], const [], artifactFraction: 0), 'fresh');
      final n = synth(11, 0.3);
      s.fold(n.nn.sublist(0, 40), n.times.sublist(0, 40));
      expectSame(s.snapshot(artifactFraction: 0),
          batch(n.nn, n.times, 40, 0), '40 beats');
      expectSame(
          s.snapshot(
              tailNnMs: n.nn.sublist(40, 59),
              tailNnTimesMs: n.times.sublist(40, 59),
              artifactFraction: 0),
          batch(n.nn, n.times, 59, 0),
          '59 beats');
      final flat = CvhrStream()
        ..fold(List.filled(80, 800.0), List.filled(80, 5000.0));
      expectSame(
          flat.snapshot(artifactFraction: 0),
          cvhrApneaScreen(List.filled(80, 800.0), List.filled(80, 5000.0),
              artifactFraction: 0),
          'degenerate times');
      // 60 beats but a 59 s span, then 60 beats over 80 s.
      for (final step in [1000.0, 1300.0]) {
        final nn = List.filled(60, 900.0);
        final t = [for (var i = 0; i < 60; i++) 1000 + i * step];
        final f = CvhrStream()..fold(nn, t);
        expectSame(f.snapshot(artifactFraction: 0),
            cvhrApneaScreen(nn, t, artifactFraction: 0), 'span step $step');
      }
    });

    test('tail that starts a new segment, or only extends the open one', () {
      final n = synth(12, 1, jumps: const [(1800, 60)]);
      var cut = 0;
      for (var i = 1; i < n.times.length; i++) {
        if (n.times[i] - n.times[i - 1] > 30000) cut = i;
      }
      final s = CvhrStream()..fold(n.nn.sublist(0, cut), n.times.sublist(0, cut));
      for (final k in [0, 1, 5, 59, 60, 61, 300]) {
        final e = math.min(n.nn.length, cut + k);
        expectSame(
            s.snapshot(
                tailNnMs: n.nn.sublist(cut, e),
                tailNnTimesMs: n.times.sublist(cut, e),
                artifactFraction: 0.02),
            batch(n.nn, n.times, e, 0.02),
            'tail $k after the gap');
      }
    });

    test('NaN / +-inf NN: no hang, matches batch (with cycles in the night)',
        () async {
      final n = synth(13, 1.5);
      final nn = [...n.nn];
      nn[300] = double.nan;
      for (var i = 900; i < 940; i++) {
        nn[i] = double.nan;
      }
      nn[1500] = double.infinity;
      nn[2000] = double.negativeInfinity;
      nn[0] = double.nan;
      nn[nn.length - 1] = double.nan;
      final ends = chunkEnds(nn.length, math.Random(131), 150, 700);
      expect(await parityIsolated(nn, n.times, ends, 0.02), '');
      final all = List<double>.filled(500, double.nan);
      final t = [for (var i = 0; i < 500; i++) i * 800.0];
      expect(
          await parityIsolated(all, t, [100, 300, 500], 0.0), '');
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('8 h night with gaps: parity at checkpoints', () {
      final n = synth(14, 8, jumps: _gappy + const [(15000, 45), (22000, 100)],
          fast: (5000, 5040));
      expect(n.nn.length, greaterThan(25000));
      final ends = chunkEnds(n.nn.length, math.Random(141), 2500, 4000);
      expectParity(n, ends, 0.02);
    }, timeout: const Timeout(Duration(seconds: 60)));
  });

  group('CvhrStream state', () {
    test('snapshot never mutates: different tails, then folding, still exact',
        () {
      final n = synth(15, 1.5, jumps: const [(2000, 50)]);
      final len = n.nn.length;
      final s = CvhrStream()..fold(n.nn.sublist(0, 2000), n.times.sublist(0, 2000));
      final json1 = jsonEncode(s.toJson());
      final base = s.snapshot(artifactFraction: 0.02);
      s.snapshot(
          tailNnMs: n.nn.sublist(2000, 2400),
          tailNnTimesMs: n.times.sublist(2000, 2400),
          artifactFraction: 0.02);
      s.snapshot(
          tailNnMs: [800, 800],
          tailNnTimesMs: [n.times[1999] + 90000, n.times[1999] + 90800],
          artifactFraction: 0.5);
      expect(jsonEncode(s.toJson()), json1, reason: 'toJson unchanged');
      expectSame(s.snapshot(artifactFraction: 0.02), base, 'repeat snapshot');
      expectSame(base, batch(n.nn, n.times, 2000, 0.02), 'base');
      s.fold(n.nn.sublist(2000, len), n.times.sublist(2000, len));
      expectSame(s.snapshot(artifactFraction: 0.02),
          batch(n.nn, n.times, len, 0.02), 'after tail snapshots');
    });

    test('JSON round trip mid-night resumes bit-identically', () {
      final n = synth(16, 2, jumps: _gappy, fast: (5000, 5040));
      final len = n.nn.length;
      // cut inside the open segment, right at a gap, and in a closed island.
      var gapAt = 0;
      for (var i = 1; i < n.times.length; i++) {
        if (n.times[i] - n.times[i - 1] > 30000) {
          gapAt = i;
          break;
        }
      }
      final cuts = ({30, gapAt, gapAt + 1, len ~/ 3, (len * 2) ~/ 3, len}.toList()
        ..sort());
      var s = CvhrStream();
      var from = 0;
      for (final end in cuts) {
        s.fold(n.nn.sublist(from, end), n.times.sublist(from, end));
        from = end;
        if (end != len) {
          final text = jsonEncode(s.toJson());
          s = CvhrStream.fromJson(jsonDecode(text) as Map<String, dynamic>);
          expect(jsonEncode(s.toJson()), text, reason: 'lossless at $end');
        }
        expectSame(s.snapshot(artifactFraction: 0.02),
            batch(n.nn, n.times, end, 0.02), 'resumed prefix $end');
      }
      // Options survive a round trip.
      final f = CvhrStream(envWindowSec: 90, maxGapSec: 12, minWidthSec: 14);
      final f2 = CvhrStream.fromJson(wire(f.toJson()) as Map<String, dynamic>);
      f2.fold(n.nn.sublist(0, 1500), n.times.sublist(0, 1500));
      expectSame(
          f2.snapshot(artifactFraction: 0.02),
          batch(n.nn, n.times, 1500, 0.02, env: 90, gap: 12, minW: 14),
          'options survive round trip');
    });

    test('malformed JSON is a FormatException', () {
      final n = synth(17, 1, jumps: const [(1200, 40)]);
      final s = CvhrStream()..fold(n.nn, n.times);
      final good = wire(s.toJson()) as Map<String, dynamic>;
      expect(good['type'], 'CvhrStream');
      expect(good['version'], 1);
      expectMalformedRejected(good, (j) => CvhrStream.fromJson(j));
      // A fresh stream's checkpoint is rejected the same way.
      final fresh = wire(CvhrStream().toJson()) as Map<String, dynamic>;
      expectMalformedRejected(fresh, (j) => CvhrStream.fromJson(j));
    });

    test('non-monotone fold is a StateError', () {
      final s = CvhrStream()..fold([800, 810, 820], [1000, 1810, 2630]);
      expect(() => s.fold([800], [2000]), throwsStateError);
      expect(() => CvhrStream().fold([800, 800], [5000, 4000]), throwsStateError);
      final eq = CvhrStream()..fold([800], [1000]);
      expect(() => eq.fold([800], [1000]), returnsNormally);
    });
  });
}
