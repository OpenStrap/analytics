// RED (round 18): exact streaming hrvFreq and RSA respiration.
//
// HrvFreqStream / RsaRespStream must equal the batch hrvFreq / rsaRespRate on
// (folded ++ tail) BIT FOR BIT at every fold: == on doubles, identical
// NaN-ness and sign of zero, same notes, same totalBands. No tolerance.
//
// The batch functions are the reference (they do not change in this round).
import 'dart:convert';
import 'dart:math' as math;

import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

// ───────────────────────── realistic NN night ───────────────────────────────

class Night {
  final List<double> nn = [], times = [];
}

/// A seeded sleep-like night of [hours] with ectopic/missed/extra beats, short
/// garbage runs and one 2-min dropout; cleaned by the production [correctRr]
/// (with timestamps), so the NN carries the same shapes as production input.
/// Breathing at 0.24 Hz, slow HR (~57 bpm), 0.1 Hz and VLF modulation.
Night synthNight(int seed, double hours,
    {double bpmBase = 57, bool dropout = true}) {
  final rnd = math.Random(seed);
  const startMs = 1.7e12;
  final endT = hours * 3600e3;
  final rr = <double>[], ts = <double>[];
  var t = 0.0;
  final phase = rnd.nextDouble() * 6.28;
  final rate = 0.005 + 0.01 * rnd.nextDouble();
  final dropAt = endT * (0.3 + 0.3 * rnd.nextDouble());
  var dropped = !dropout;
  void emit(double v) {
    v = v.roundToDouble();
    t += v;
    rr.add(v);
    ts.add(((startMs + t) / 1000).floorToDouble() * 1000);
  }

  while (t < endT) {
    final s = t / 1000;
    final bpm = bpmBase + 7 * math.sin(s / 5400 + seed);
    final v = 60000 / bpm +
        28 * math.sin(2 * math.pi * 0.24 * s + phase) +
        18 * math.sin(2 * math.pi * 0.1 * s) +
        22 * math.sin(2 * math.pi * 0.01 * s) +
        6 * (rnd.nextDouble() - .5) * 2;
    if (!dropped && t >= dropAt) {
      dropped = true;
      t += 120e3;
      continue;
    }
    if (rnd.nextDouble() < rate) {
      final u = rnd.nextDouble();
      if (u < 0.4) {
        emit(v * (0.55 + 0.15 * rnd.nextDouble()));
        emit(v * (1.3 + 0.2 * rnd.nextDouble()));
      } else if (u < 0.6) {
        emit(v * (1.9 + 0.2 * rnd.nextDouble()));
      } else if (u < 0.85) {
        final f = 0.35 + 0.3 * rnd.nextDouble();
        emit(v * f);
        emit(v * (1 - f));
      } else {
        emit(250 + rnd.nextInt(2100).toDouble());
      }
      continue;
    }
    emit(v);
  }
  final c = correctRr(rr, rrTsMs: ts);
  return Night()
    ..nn.addAll(c.nn)
    ..times.addAll(c.nnTimesMs);
}

// ───────────────────────── bit-for-bit comparison ───────────────────────────

bool sameD(double? a, double? b) {
  if (a == null || b == null) return a == null && b == null;
  if (a.isNaN || b.isNaN) return a.isNaN && b.isNaN;
  return a == b && a.isNegative == b.isNegative;
}

void expectSameD(double? a, double? b, String what) =>
    expect(sameD(a, b), isTrue, reason: '$what: $a vs $b');

void expectSameMetric<T>(Metric<T> a, Metric<T> b, String at) {
  expect(a.value == null, b.value == null, reason: '$at value presence');
  expectSameD(a.confidence, b.confidence, '$at confidence');
  expect(a.tier, b.tier, reason: at);
  expect(a.inputs_used, b.inputs_used, reason: at);
  expect(a.note, b.note, reason: '$at note');
  expect(a.drivers == null, b.drivers == null, reason: at);
}

void expectSameHrv(Metric<HrvFreq> a, Metric<HrvFreq> b, String at) {
  expectSameMetric(a, b, at);
  final x = a.value, y = b.value;
  if (x == null || y == null) return;
  expectSameD(x.ulf, y.ulf, '$at ulf');
  expectSameD(x.vlf, y.vlf, '$at vlf');
  expectSameD(x.lf, y.lf, '$at lf');
  expectSameD(x.hf, y.hf, '$at hf');
  expectSameD(x.total, y.total, '$at total');
  expect(x.totalBands, y.totalBands, reason: '$at totalBands');
  expectSameD(x.lfhf, y.lfhf, '$at lfhf');
  expectSameD(x.nuLf, y.nuLf, '$at nuLf');
  expectSameD(x.nuHf, y.nuHf, '$at nuHf');
  expect(x.hfGated, y.hfGated, reason: at);
}

void expectSameResp(
    Metric<RespEstimate> a, Metric<RespEstimate> b, String at) {
  expectSameMetric(a, b, at);
  final x = a.value, y = b.value;
  if (x == null || y == null) return;
  expectSameD(x.brpm, y.brpm, '$at brpm');
  expectSameD(x.peakHz, y.peakHz, '$at peakHz');
  expectSameD(x.power, y.power, '$at power');
  expect(x.source, y.source, reason: at);
}

// ───────────────────────── drivers ──────────────────────────────────────────

/// Chunk boundaries (beat counts) with random sizes in [lo, hi], starting small
/// so the first folds sit below every minimum-beats / minimum-span gate.
List<int> chunkEnds(int n, math.Random rnd, int lo, int hi, {int first = 8}) {
  final ends = <int>[];
  var at = first;
  while (at < n) {
    ends.add(at);
    at += lo + rnd.nextInt(hi - lo + 1);
  }
  ends.add(n);
  return ends;
}

Metric<HrvFreq> batchHrv(Night n, int end, double af,
        {double gate = 0.15, double os = 4.0}) =>
    hrvFreq(n.nn.sublist(0, end), n.times.sublist(0, end),
        artifactFraction: af, hfArtifactGate: gate, oversample: os);

Metric<RespEstimate> batchRsa(Night n, int end, double af,
        {double tol = 2.0, double cons = 0.5, double maxA = 0.30}) =>
    rsaRespRate(n.nn.sublist(0, end), n.times.sublist(0, end),
        artifactFraction: af,
        tolBrpm: tol,
        minConsensus: cons,
        maxArtifact: maxA);

void hrvParity(Night n, List<int> ends, double af, {int tailBeats = 100}) {
  final s = HrvFreqStream();
  var from = 0;
  for (final end in ends) {
    s.fold(n.nn.sublist(from, end), n.times.sublist(from, end));
    from = end;
    expectSameHrv(s.snapshot(artifactFraction: af), batchHrv(n, end, af),
        'hrv prefix $end');
    final tEnd = math.min(n.nn.length, end + tailBeats);
    expectSameHrv(
        s.snapshot(
            tailNnMs: n.nn.sublist(end, tEnd),
            tailNnTimesMs: n.times.sublist(end, tEnd),
            artifactFraction: af),
        batchHrv(n, tEnd, af),
        'hrv prefix $end + tail ${tEnd - end}');
  }
}

void rsaParity(Night n, List<int> ends, double af, {int tailBeats = 100}) {
  final s = RsaRespStream();
  var from = 0;
  for (final end in ends) {
    s.fold(n.nn.sublist(from, end), n.times.sublist(from, end));
    from = end;
    expectSameResp(s.snapshot(artifactFraction: af), batchRsa(n, end, af),
        'rsa prefix $end');
    final tEnd = math.min(n.nn.length, end + tailBeats);
    expectSameResp(
        s.snapshot(
            tailNnMs: n.nn.sublist(end, tEnd),
            tailNnTimesMs: n.times.sublist(end, tEnd),
            artifactFraction: af),
        batchRsa(n, tEnd, af),
        'rsa prefix $end + tail ${tEnd - end}');
  }
}

Object? wire(Map<String, dynamic> j) => jsonDecode(jsonEncode(j));

/// Every top-level key removed, and every top-level value swapped for a wrong
/// type, must be a FormatException (never a TypeError / RangeError / success).
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

void main() {
  group('fresh and short-prefix streams equal the batch on the tail', () {
    final ks = [1, 2, 8, 15, 16, 17, 19, 20, 21, 29, 30, 31, 60, 200, 1000];

    void check(Night n, List<int> tails, {int folded = 0}) {
      for (final k in tails) {
        final end = math.min(folded + k, n.nn.length);
        if (end <= folded) continue;
        final h = HrvFreqStream();
        final r = RsaRespStream();
        if (folded > 0) {
          h.fold(n.nn.sublist(0, folded), n.times.sublist(0, folded));
          r.fold(n.nn.sublist(0, folded), n.times.sublist(0, folded));
        }
        final tn = n.nn.sublist(folded, end), tt = n.times.sublist(folded, end);
        expectSameHrv(
            h.snapshot(tailNnMs: tn, tailNnTimesMs: tt, artifactFraction: 0.02),
            batchHrv(n, end, 0.02),
            'hrv folded $folded tail $k');
        expectSameResp(
            r.snapshot(tailNnMs: tn, tailNnTimesMs: tt, artifactFraction: 0.02),
            batchRsa(n, end, 0.02),
            'rsa folded $folded tail $k');
      }
    }

    test('fresh stream, tails across the 16/20/30 gates', () {
      check(synthNight(91, 1), ks);
    });

    test('fresh stream, tail is a full 2 h night (with a dropout)', () {
      final n = synthNight(92, 2);
      check(n, [n.nn.length]);
    });

    test('a few folded beats plus a long tail', () {
      final n = synthNight(93, 2);
      for (final f in [1, 5, 8, 15, 16, 19, 20]) {
        check(n, [1, 5, 30, 200, n.nn.length], folded: f);
      }
    });
  });

  group('HrvFreqStream', () {
    test('prefix parity at every fold, empty and non-empty tail (2 h night)',
        () {
      final n = synthNight(1, 2);
      final ends = chunkEnds(n.nn.length, math.Random(11), 700, 1500);
      hrvParity(n, ends, 0.02);
    });

    test('HF gate path and non-default gate / oversample are bit-identical',
        () {
      final n = synthNight(2, 1.0);
      final s = HrvFreqStream(oversample: 2.0);
      final ends = chunkEnds(n.nn.length, math.Random(5), 700, 1300);
      var from = 0;
      for (final end in ends) {
        s.fold(n.nn.sublist(from, end), n.times.sublist(from, end));
        from = end;
        for (final af in [0.02, 0.2]) {
          expectSameHrv(s.snapshot(artifactFraction: af),
              batchHrv(n, end, af, os: 2.0), 'af $af prefix $end');
        }
        expectSameHrv(
            s.snapshot(artifactFraction: 0.1, hfArtifactGate: 0.05),
            batchHrv(n, end, 0.1, gate: 0.05, os: 2.0),
            'gate 0.05 prefix $end');
      }
    });

    test('absent paths: <16 beats, degenerate times, fresh stream', () {
      final fresh = HrvFreqStream();
      expectSameHrv(
          fresh.snapshot(artifactFraction: 0),
          hrvFreq(const [], const [], artifactFraction: 0),
          'fresh stream, no beats');
      // 15 beats: below the 16-beat floor.
      final s = HrvFreqStream();
      final nn = List<double>.generate(15, (i) => 800.0 + i);
      final ts = List<double>.generate(15, (i) => 1000.0 * i);
      s.fold(nn, ts);
      expectSameHrv(s.snapshot(artifactFraction: 0),
          hrvFreq(nn, ts, artifactFraction: 0), '15 beats');
      // The 16th arrives as a tail only.
      expectSameHrv(
          s.snapshot(
              tailNnMs: [900],
              tailNnTimesMs: [15000],
              artifactFraction: 0),
          hrvFreq([...nn, 900], [...ts, 15000], artifactFraction: 0),
          '15 + tail 1');
      // 20 beats at one instant: span 0 -> 'degenerate beat times'.
      final d = HrvFreqStream();
      final dn = List<double>.filled(20, 800);
      final dt = List<double>.filled(20, 5000);
      d.fold(dn, dt);
      expectSameHrv(d.snapshot(artifactFraction: 0),
          hrvFreq(dn, dt, artifactFraction: 0), 'degenerate');
      // A short record: 20 min, no band but HF/LF resolvable? whatever the
      // batch says (including 'record too short to resolve any HRV band').
      final short = synthNight(3, 0.05);
      final sh = HrvFreqStream()..fold(short.nn, short.times);
      expectSameHrv(sh.snapshot(artifactFraction: 0.01),
          hrvFreq(short.nn, short.times, artifactFraction: 0.01), 'short');
    });

    test('segments close exactly at start+seg: beat on / just before the edge',
        () {
      // 1 s beats: HF segment is 66.67 s, 50 % overlap. Probe every prefix
      // length around several segment ends with single-beat folds.
      final nn = List<double>.filled(400, 1000);
      final ts = List<double>.generate(400, (i) => 1000.0 * i);
      final n = Night()
        ..nn.addAll(nn)
        ..times.addAll(ts);
      final s = HrvFreqStream();
      for (var i = 0; i < n.nn.length; i++) {
        s.fold([n.nn[i]], [n.times[i]]);
        if (i >= 60 && i <= 140 || i >= 190 && i <= 210) {
          expectSameHrv(s.snapshot(artifactFraction: 0.01),
              batchHrv(n, i + 1, 0.01), 'single-beat fold $i');
        }
      }
    });

    test('8 h night: VLF segments close and stay exact', () {
      final n = synthNight(4, 8);
      final len = n.nn.length;
      final ends = [len ~/ 3, (len * 2) ~/ 3, len];
      final s = HrvFreqStream();
      var from = 0;
      for (final end in ends) {
        s.fold(n.nn.sublist(from, end), n.times.sublist(from, end));
        from = end;
        final got = s.snapshot(artifactFraction: 0.02);
        expectSameHrv(got, batchHrv(n, end, 0.02), '8h prefix $end');
        if (end == len) {
          expect(got.value?.vlf, isNotNull, reason: 'VLF resolved at 8 h');
        }
      }
    });

    test('snapshot never mutates: different tails, then folding, still exact',
        () {
      final n = synthNight(5, 1.5);
      final len = n.nn.length;
      final mid = len ~/ 2;
      final s = HrvFreqStream()..fold(n.nn.sublist(0, mid), n.times.sublist(0, mid));
      final before = s.snapshot(artifactFraction: 0.03);
      // A long tail that would close many segments, then a different short one.
      s.snapshot(
          tailNnMs: n.nn.sublist(mid, len),
          tailNnTimesMs: n.times.sublist(mid, len),
          artifactFraction: 0.03);
      s.snapshot(
          tailNnMs: [700, 710, 720],
          tailNnTimesMs: [
            n.times[mid - 1] + 700,
            n.times[mid - 1] + 1410,
            n.times[mid - 1] + 2130
          ],
          artifactFraction: 0.5);
      expectSameHrv(s.snapshot(artifactFraction: 0.03), before, 'repeat');
      expectSameHrv(before, batchHrv(n, mid, 0.03), 'before');
      // The real continuation overlaps what the tails pretended.
      s.fold(n.nn.sublist(mid, len), n.times.sublist(mid, len));
      expectSameHrv(s.snapshot(artifactFraction: 0.03), batchHrv(n, len, 0.03),
          'after folding');
      // A tail may also be folded afterwards with the very same beats.
      final json1 = jsonEncode(s.toJson());
      s.snapshot(
          tailNnMs: [800], tailNnTimesMs: [n.times.last + 800], artifactFraction: 0);
      expect(jsonEncode(s.toJson()), json1, reason: 'toJson unchanged');
    });

    test('JSON round trip mid-night resumes bit-identically', () {
      final n = synthNight(6, 1.5);
      final len = n.nn.length;
      final cuts = [len ~/ 5, (len * 2) ~/ 5, (len * 3) ~/ 5, len];
      var s = HrvFreqStream();
      var from = 0;
      for (final end in cuts) {
        s.fold(n.nn.sublist(from, end), n.times.sublist(from, end));
        from = end;
        if (end != len) {
          final text = jsonEncode(s.toJson());
          s = HrvFreqStream.fromJson(
              jsonDecode(text) as Map<String, dynamic>);
          // lossless: re-serializing the revived stream is byte-identical.
          expect(jsonEncode(s.toJson()), text);
        }
        expectSameHrv(s.snapshot(artifactFraction: 0.02),
            batchHrv(n, end, 0.02), 'resumed prefix $end');
      }
      // A fresh stream also round-trips and keeps the oversample setting.
      final f = HrvFreqStream(oversample: 3.0);
      final f2 = HrvFreqStream.fromJson(wire(f.toJson()) as Map<String, dynamic>);
      f2.fold(n.nn.sublist(0, 800), n.times.sublist(0, 800));
      expectSameHrv(
          f2.snapshot(artifactFraction: 0.02),
          batchHrv(n, 800, 0.02, os: 3.0),
          'oversample survives round trip');
    });

    test('malformed JSON is a FormatException', () {
      final n = synthNight(7, 1.2);
      final s = HrvFreqStream()..fold(n.nn, n.times);
      final good = wire(s.toJson()) as Map<String, dynamic>;
      expectMalformedRejected(good,
          (j) => HrvFreqStream.fromJson(j));
    });

    test('non-monotone fold is a StateError', () {
      final s = HrvFreqStream()
        ..fold([800, 810, 820], [1000, 1810, 2630]);
      // Earlier than the previous fold's last beat.
      expect(() => s.fold([800], [2000]), throwsStateError);
      // Decreasing inside one call.
      expect(() => HrvFreqStream().fold([800, 800], [5000, 4000]),
          throwsStateError);
      // Equal times are allowed (non-decreasing) and do not throw.
      final eq = HrvFreqStream()..fold([800], [1000]);
      expect(() => eq.fold([800], [1000]), returnsNormally);
    });
  });

  group('RsaRespStream', () {
    test('prefix parity at every fold, empty and non-empty tail (2 h night)',
        () {
      final n = synthNight(11, 2);
      // First folds are tiny: < 20 beats, then span < 600 s where the batch
      // shortens its segment to span/2.
      final ends = chunkEnds(n.nn.length, math.Random(21), 400, 1300, first: 12);
      rsaParity(n, ends, 0.02);
    });

    test('short-span prefixes (segment = span/2 regime) fold beat by beat',
        () {
      final n = synthNight(12, 0.4);
      final s = RsaRespStream();
      for (var i = 0; i < n.nn.length && i < 900; i++) {
        s.fold([n.nn[i]], [n.times[i]]);
        if (i > 15 && i % 7 == 0) {
          expectSameResp(s.snapshot(artifactFraction: 0.02),
              batchRsa(n, i + 1, 0.02), 'single-beat fold $i');
        }
      }
    });

    test('gates and options: artifact gate, tolerance, consensus', () {
      final n = synthNight(13, 0.8);
      final s = RsaRespStream();
      final ends = chunkEnds(n.nn.length, math.Random(2), 500, 900);
      var from = 0;
      for (final end in ends) {
        s.fold(n.nn.sublist(from, end), n.times.sublist(from, end));
        from = end;
        expectSameResp(s.snapshot(artifactFraction: 0.4),
            batchRsa(n, end, 0.4), 'artifact 0.4 prefix $end');
        expectSameResp(
            s.snapshot(artifactFraction: 0.4, maxArtifact: 0.5),
            batchRsa(n, end, 0.4, maxA: 0.5),
            'maxArtifact 0.5 prefix $end');
        expectSameResp(
            s.snapshot(artifactFraction: 0.05, tolBrpm: 0.1, minConsensus: 0.9),
            batchRsa(n, end, 0.05, tol: 0.1, cons: 0.9),
            'strict consensus prefix $end');
      }
    });

    test('slow heart (NN 1400 ms): window ceiling below HF band -> withheld',
        () {
      final nn = List<double>.generate(500, (i) => 1400.0 + 20 * math.sin(i / 3));
      final ts = <double>[];
      var t = 0.0;
      for (final v in nn) {
        t += v;
        ts.add(t);
      }
      final n = Night()
        ..nn.addAll(nn)
        ..times.addAll(ts);
      final s = RsaRespStream();
      for (var from = 0; from < 500; from += 100) {
        s.fold(nn.sublist(from, from + 100), ts.sublist(from, from + 100));
        expectSameResp(s.snapshot(artifactFraction: 0.01),
            batchRsa(n, from + 100, 0.01), 'slow HR prefix ${from + 100}');
      }
    });

    test('absent paths: fresh stream, <20 beats, degenerate times', () {
      expectSameResp(
          RsaRespStream().snapshot(artifactFraction: 0),
          rsaRespRate(const [], const [], artifactFraction: 0),
          'fresh');
      final nn = List<double>.generate(19, (i) => 800.0 + i);
      final ts = List<double>.generate(19, (i) => 1000.0 * i);
      final s = RsaRespStream()..fold(nn, ts);
      expectSameResp(s.snapshot(artifactFraction: 0),
          rsaRespRate(nn, ts, artifactFraction: 0), '19 beats');
      expectSameResp(
          s.snapshot(
              tailNnMs: [900], tailNnTimesMs: [19000], artifactFraction: 0),
          rsaRespRate([...nn, 900], [...ts, 19000], artifactFraction: 0),
          '19 + tail 1');
      final dn = List<double>.filled(25, 800);
      final dt = List<double>.filled(25, 5000);
      final d = RsaRespStream()..fold(dn, dt);
      expectSameResp(d.snapshot(artifactFraction: 0),
          rsaRespRate(dn, dt, artifactFraction: 0), 'degenerate');
    });

    test('segments close exactly at start+300 s: single-beat folds at the edge',
        () {
      // 1 s beats, 300 s segments, 150 s step: probe prefixes around ends.
      final nn = List<double>.filled(1000, 1000);
      for (var i = 0; i < nn.length; i++) {
        nn[i] += 40 * math.sin(2 * math.pi * 0.24 * i);
      }
      final ts = <double>[];
      for (var i = 0; i < nn.length; i++) {
        ts.add(1000.0 * i);
      }
      final n = Night()
        ..nn.addAll(nn)
        ..times.addAll(ts);
      final s = RsaRespStream();
      for (var i = 0; i < n.nn.length; i++) {
        s.fold([n.nn[i]], [n.times[i]]);
        final near = [299, 449, 599, 749, 899]
            .any((e) => i >= e - 3 && i <= e + 3);
        if (near || i == 119 || i == 120 || i == 121) {
          expectSameResp(s.snapshot(artifactFraction: 0.01),
              batchRsa(n, i + 1, 0.01), 'single-beat fold $i');
        }
      }
    });

    test('night with a dropout: thin segments counted the same', () {
      final n = synthNight(14, 1.5, dropout: true);
      rsaParity(n, chunkEnds(n.nn.length, math.Random(3), 500, 1200), 0.01);
    });

    test('8 h night: parity at checkpoints', () {
      final n = synthNight(15, 8);
      final len = n.nn.length;
      final s = RsaRespStream();
      var from = 0;
      for (final end in [len ~/ 3, (len * 2) ~/ 3, len]) {
        s.fold(n.nn.sublist(from, end), n.times.sublist(from, end));
        from = end;
        expectSameResp(s.snapshot(artifactFraction: 0.02),
            batchRsa(n, end, 0.02), '8h prefix $end');
      }
    });

    test('snapshot never mutates: different tails, then folding, still exact',
        () {
      final n = synthNight(16, 1.5);
      final len = n.nn.length;
      final mid = len ~/ 2;
      final s = RsaRespStream()..fold(n.nn.sublist(0, mid), n.times.sublist(0, mid));
      final before = s.snapshot(artifactFraction: 0.03);
      s.snapshot(
          tailNnMs: n.nn.sublist(mid, len),
          tailNnTimesMs: n.times.sublist(mid, len),
          artifactFraction: 0.03);
      s.snapshot(
          tailNnMs: [700, 710, 720],
          tailNnTimesMs: [
            n.times[mid - 1] + 700,
            n.times[mid - 1] + 1410,
            n.times[mid - 1] + 2130
          ],
          artifactFraction: 0.5);
      expectSameResp(s.snapshot(artifactFraction: 0.03), before, 'repeat');
      expectSameResp(before, batchRsa(n, mid, 0.03), 'before');
      s.fold(n.nn.sublist(mid, len), n.times.sublist(mid, len));
      expectSameResp(s.snapshot(artifactFraction: 0.03),
          batchRsa(n, len, 0.03), 'after folding');
      final json1 = jsonEncode(s.toJson());
      s.snapshot(
          tailNnMs: [800], tailNnTimesMs: [n.times.last + 800], artifactFraction: 0);
      expect(jsonEncode(s.toJson()), json1, reason: 'toJson unchanged');
    });

    test('JSON round trip mid-night resumes bit-identically', () {
      final n = synthNight(17, 1.5);
      final len = n.nn.length;
      // Cuts include one inside the span<600 s regime.
      final cuts = [60, len ~/ 5, (len * 2) ~/ 5, (len * 3) ~/ 5, len];
      var s = RsaRespStream();
      var from = 0;
      for (final end in cuts) {
        s.fold(n.nn.sublist(from, end), n.times.sublist(from, end));
        from = end;
        if (end != len) {
          final text = jsonEncode(s.toJson());
          s = RsaRespStream.fromJson(jsonDecode(text) as Map<String, dynamic>);
          expect(jsonEncode(s.toJson()), text);
        }
        expectSameResp(s.snapshot(artifactFraction: 0.02),
            batchRsa(n, end, 0.02), 'resumed prefix $end');
      }
    });

    test('malformed JSON is a FormatException', () {
      final n = synthNight(18, 1.2);
      final s = RsaRespStream()..fold(n.nn, n.times);
      final good = wire(s.toJson()) as Map<String, dynamic>;
      expectMalformedRejected(good, (j) => RsaRespStream.fromJson(j));
    });

    test('non-monotone fold is a StateError', () {
      final s = RsaRespStream()..fold([800, 810, 820], [1000, 1810, 2630]);
      expect(() => s.fold([800], [2000]), throwsStateError);
      expect(() => RsaRespStream().fold([800, 800], [5000, 4000]),
          throwsStateError);
      final eq = RsaRespStream()..fold([800], [1000]);
      expect(() => eq.fold([800], [1000]), returnsNormally);
    });
  });
}
