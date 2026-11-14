// Oracle tests: nocturnalRmssd (with/without stage mask), sleepSessionWindowedRmssd
// (raw RR, bounds), irregularBeatScreen (day-long corrected NN).
import 'dart:math' as math;

import 'package:openstrap_analytics/onehz.dart'
    hide RrCorrector, RrSettled, RrSnapshot, IrregularScreenState;
import 'package:test/test.dart';

import '../../tool/incremental/driver.dart';
import '../../tool/incremental/hrv_incr.dart';
import '../../tool/incremental/oracle_util.dart';
import '../../tool/incremental/synth.dart';
import 'support.dart';

void _sameD(Metric<double> a, Metric<double> b, Err e, {String? why}) {
  expect(a.present, b.present, reason: 'present $why');
  expect(a.note, b.note, reason: 'note $why');
  expect(a.tier, b.tier);
  if (b.present) {
    expect(a.value, b.value, reason: 'value $why'); // bit-identical
    e.add(a.confidence, b.confidence);
  }
}

void main() {
  final confErr = Err();

  test('nocturnalRmssd: real night, 15-min folds, with and without a stage mask', () {
    final s = realNightRr()!;
    final spanSec = ((s.ts.last - s.ts.first) / 1000).ceil() + 10;
    // blocky mask: asleep (true) ~70% of the time in 5-40 min blocks
    final r = math.Random(1);
    final mask = List<bool>.filled(spanSec, false);
    for (var i = 0; i < spanSec;) {
      final len = 300 + r.nextInt(2100);
      final v = r.nextDouble() < 0.7;
      for (var k = 0; k < len && i < spanSec; k++, i++) {
        mask[i] = v;
      }
    }
    final st = NocturnalRmssdState();
    final cuts = timeCuts(s.ts, 900);
    final checks = {1, 3, 8, 15, 25, cuts.length - 1};
    driveRr(s, cuts, (f) {
      st.fold(f.settled.nn, f.settled.nnTimes);
      if (!checks.contains(f.fold)) return;
      final o = correctRr(s.rr.sublist(0, f.n), rrTsMs: s.ts.sublist(0, f.n));
      for (final m in [null, mask]) {
        final want = nocturnalRmssd(o.nn, o.nnTimesMs, stageMaskPerSec: m);
        final got = st.evaluate(f.snap.tailNn, f.snap.tailNnTimes, stageMaskPerSec: m);
        _sameD(got, want, confErr, why: 'fold ${f.fold} mask=${m != null}');
      }
    });
  });

  test('nocturnalRmssd: jitter gate (white-noise NN) refuses like the oracle', () {
    final r = math.Random(4);
    final nn = <double>[], t = <double>[];
    var clock = 0.0;
    for (var i = 0; i < 6000; i++) {
      final v = (800 + 300 * (r.nextDouble() - .5)).roundToDouble();
      clock += v;
      nn.add(v);
      t.add(clock);
    }
    final st = NocturnalRmssdState();
    var at = 0;
    for (final cut in randomCuts(math.Random(2), nn.length, sizes: [37, 400, 2000])) {
      st.fold(nn.sublist(at, cut), t.sublist(at, cut));
      at = cut;
      final want = nocturnalRmssd(nn.sublist(0, cut), t.sublist(0, cut));
      final got = st.evaluate(const [], const []);
      _sameD(got, want, confErr, why: 'cut=$cut');
    }
    expect(nocturnalRmssd(nn, t).present, isFalse, reason: 'fixture trips the gate');
  });

  test('sleepSessionWindowedRmssd: raw RR, 15-min folds, session bounds inside the night', () {
    final s = realNightRr()!;
    final start = (s.ts.first / 1000).floor() + 1234;
    final end = (s.ts.last / 1000).floor() - 987;
    final cuts = timeCuts(s.ts, 900);
    final st = SessionRmssdState(start, end);
    var from = 0;
    for (var k = 0; k < cuts.length; k++) {
      st.fold(s.rr.sublist(from, cuts[k]), s.ts.sublist(from, cuts[k]));
      from = cuts[k];
      if (k % 4 == 0 || k == cuts.length - 1) {
        // oracle with the session end clipped to the data seen so far
        final seenEnd = math.min(end, (s.ts[cuts[k] - 1] / 1000).round() + 1);
        final want = sleepSessionWindowedRmssd(
            s.rr.sublist(0, cuts[k]), s.ts.sublist(0, cuts[k]),
            startSec: start, endSec: end);
        final got = st.evaluate();
        _sameD(got, want, confErr, why: 'k=$k seenEnd=$seenEnd');
      }
    }
  });

  test('sleepSessionWindowedRmssd: dirty synthetic night + seams', () {
    final s = synthRr(const SynthConfig(
        seed: 91, hours: 4, ectopicPerMin: 2, noiseRunPerMin: 0.6, gapPerHour: 10));
    final start = (s.ts.first / 1000).floor() + 100;
    final end = (s.ts.last / 1000).floor() - 100;
    final st = SessionRmssdState(start, end);
    var at = 0;
    for (final cut in randomCuts(math.Random(8), s.length, sizes: [3, 200, 1500])) {
      st.fold(s.rr.sublist(at, cut), s.ts.sublist(at, cut));
      at = cut;
      final want = sleepSessionWindowedRmssd(
          s.rr.sublist(0, cut), s.ts.sublist(0, cut),
          startSec: start, endSec: end);
      _sameD(st.evaluate(), want, confErr, why: 'cut=$cut');
    }
  });

  group('irregularBeatScreen', () {
    // AF-like bursts: irregularly irregular RR in 5-30 min blocks.
    ({List<double> nn, List<double> t}) fixture(int seed, double afShare) {
      final r = math.Random(seed);
      final nn = <double>[], t = <double>[];
      var clock = 0.0;
      var af = false;
      var left = 0;
      while (clock < 8 * 3600 * 1000.0) {
        if (--left <= 0) {
          af = r.nextDouble() < afShare;
          left = 300 + r.nextInt(2000);
        }
        final v = af
            ? (420 + r.nextInt(700)).toDouble()
            : (850 + 40 * math.sin(clock / 9000) + 25 * (r.nextDouble() - .5)).roundToDouble();
        clock += v;
        nn.add(v);
        t.add(clock);
      }
      return (nn: nn, t: t);
    }

    for (final share in [0.0, 0.35, 0.75, 1.0]) {
      for (final restart in [false, true]) {
        test('af share=$share restart=$restart', () {
          final x = fixture((share * 100).round() + 3, share);
          var st = IrregularScreenState();
          var at = 0;
          var flags = 0, checks = 0;
          for (final cut in randomCuts(math.Random(5), x.nn.length, sizes: [90, 500, 4000])) {
            st.fold(x.nn.sublist(at, cut), x.t.sublist(at, cut));
            at = cut;
            if (restart) st = IrregularScreenState.fromJson(jsonRoundTrip(st.toJson()));
            for (final af in [0.0, 0.31]) {
              final want = irregularBeatScreen(x.nn.sublist(0, cut),
                  nnTimesMs: x.t.sublist(0, cut), artifactFraction: af);
              final got = st.evaluate(const [], const [], artifactFraction: af);
              expect(got.present, want.present, reason: 'cut=$cut af=$af');
              expect(got.note, want.note);
              if (want.present) {
                expect(got.value!.flag, want.value!.flag, reason: 'flag cut=$cut');
                expect(got.value!.nBeats, want.value!.nBeats);
                expect(got.value!.pnnPct, want.value!.pnnPct);
                expect((got.value!.sd1 - want.value!.sd1).abs(), lessThan(1e-9));
                expect((got.value!.sd2 - want.value!.sd2).abs(), lessThan(1e-9));
                confErr.add(got.confidence, want.confidence);
                if (want.value!.flag) flags++;
                checks++;
              }
            }
          }
          // ignore: avoid_print
          print('irregular share=$share: checks=$checks flagged=$flags');
        });
      }
    }

    test('whole day through RrCorrector -> screen (3 checkpoints)', () {
      final day = realShapedDay();
      final st = IrregularScreenState();
      final cuts = timeCuts(day.ts, 900);
      final checks = {cuts.length ~/ 3, 2 * cuts.length ~/ 3, cuts.length - 1};
      driveRr(day, cuts, (f) {
        st.fold(f.settled.nn, f.settled.nnTimes);
        if (!checks.contains(f.fold)) return;
        final o = correctRr(day.rr.sublist(0, f.n), rrTsMs: day.ts.sublist(0, f.n));
        final af = (1.0 - o.cleanFraction).clamp(0.0, 1.0).toDouble();
        final want = irregularBeatScreen(o.nn,
            nnTimesMs: o.nnTimesMs, artifactFraction: af);
        final got = st.evaluate(f.snap.tailNn, f.snap.tailNnTimes, artifactFraction: af);
        expect(got.present, want.present);
        expect(got.note, want.note);
        if (want.present) {
          expect(got.value!.flag, want.value!.flag);
          expect(got.value!.nBeats, want.value!.nBeats);
          expect(got.value!.pnnPct, want.value!.pnnPct);
          expect((got.value!.sd1 - want.value!.sd1).abs(), lessThan(1e-9));
          expect((got.value!.sd2 - want.value!.sd2).abs(), lessThan(1e-9));
        }
      });
    }, timeout: const Timeout(Duration(minutes: 10)));
  });

  test('confidence error summary', () {
    // ignore: avoid_print
    print('confidence (derived from acf / counts): $confErr');
  });
}
