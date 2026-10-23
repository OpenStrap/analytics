// Oracle tests for every estimator that consumes the corrected NN series:
//   hrvTime, edge _hrvTimeline, nightHrvShape, rsaRespRate, _respPerWindow
//   (+ breathingRateVariability on top), hrvFreq.
// The incremental states are fed the SETTLED NN from RrCorrector.fold and
// evaluated with the PROVISIONAL tail; the oracle is the batch function on
// correctRr(all beats so far).
import 'dart:convert';
import 'dart:math' as math;

import 'package:openstrap_analytics/onehz.dart'
    hide RrCorrector, RrSettled, RrSnapshot, IrregularScreenState;
import 'package:test/test.dart';

import '../../tool/incremental/driver.dart';
import '../../tool/incremental/edge_oracles.dart';
import '../../tool/incremental/hrv_incr.dart';
import '../../tool/incremental/oracle_util.dart';
import '../../tool/incremental/resp_incr.dart';
import '../../tool/incremental/synth.dart';
import 'support.dart';

RrData _realFirstHours(double hours) {
  final r = realNightRr()!;
  final endMs = r.ts.first + hours * 3.6e6;
  var n = r.ts.indexWhere((t) => t > endMs);
  if (n < 0) n = r.length;
  return RrData(r.rr.sublist(0, n), r.ts.sublist(0, n));
}

/// Equal null-ness and within 1e-9 relative (the aggregator's stated
/// tolerance; hrvTime now runs hrvTimeAggregator).
void _near9(double? got, double? want, String reason) {
  expect(got == null, want == null, reason: reason);
  if (got != null && want != null) {
    expect(got, closeTo(want, 1e-9 * want.abs()), reason: reason);
  }
}

void main() {
  final errSdnn = Err(), errAcf = Err(), errConf = Err();
  var hrvChecks = 0;

  group('hrvTime accumulators', () {
    for (final restart in [false, true]) {
      for (final name in ['real 3h', 'synthetic dirty 2h', 'synthetic clean 1h']) {
        test('$name restart=$restart', () {
          final s = name == 'real 3h'
              ? _realFirstHours(3)
              : name.contains('dirty')
                  ? synthRr(const SynthConfig(
                      seed: 61, hours: 2, ectopicPerMin: 1.5, noiseRunPerMin: 0.3))
                  : synthRr(const SynthConfig(
                      seed: 62,
                      hours: 1,
                      ectopicPerMin: 0,
                      missedPerMin: 0,
                      extraPerMin: 0,
                      noiseRunPerMin: 0,
                      gapPerHour: 0));
          final r = math.Random(restart ? 5 : 6);
          final cuts = randomCuts(r, s.length, sizes: [90, 181, 400, 1200, 3000]);
          var acc = HrvTimeAcc();
          driveRr(s, cuts, (f) {
            acc.fold(f.settled.nn, f.settled.nnTimes);
            if (restart) acc = HrvTimeAcc.fromJson(jsonRoundTrip(acc.toJson()));
            if (f.fold % 3 != 0 && f.fold != cuts.length - 1) return;
            final o = correctRr(s.rr.sublist(0, f.n), rrTsMs: s.ts.sublist(0, f.n));
            final af = (1.0 - o.cleanFraction).clamp(0.0, 1.0).toDouble();
            expect(f.artifactFraction, af);
            final want = hrvTime(o.nn, nnTimesMs: o.nnTimesMs, artifactFraction: af);
            final got = acc.evaluate(f.snap.tailNn, f.snap.tailNnTimes,
                artifactFraction: af);
            hrvChecks++;
            expect(got.present, want.present);
            if (!want.present) return;
            final a = got.value!, b = want.value!;
            expect(a.nBeats, b.nBeats);
            // rmssd / pnn50 bit-identical; sdann / sdnnIndex 1e-9 relative
            // (hrvTime now runs hrvTimeAggregator; was exact).
            expect(a.rmssd, b.rmssd, reason: 'rmssd');
            expect(a.pnn50, b.pnn50, reason: 'pnn50');
            _near9(a.sdann, b.sdann, 'sdann');
            _near9(a.sdnnIndex, b.sdnnIndex, 'sdnnIndex');
            // bounded error
            errSdnn.add(a.sdnn, b.sdnn);
            errAcf.add(a.diffAcf1, b.diffAcf1);
            errConf.add(got.confidence, want.confidence);
            expect(got.note, want.note);
          });
        });
      }
    }
    test('error summary', () {
      // ignore: avoid_print
      print('hrvTime checks=$hrvChecks\n  sdnn: $errSdnn\n  acf1: $errAcf\n  conf: $errConf');
      expect(errSdnn.maxRel, lessThan(1e-11));
      expect(errAcf.maxAbs, lessThan(1e-11));
    });
  });

  group('hrv timeline + night shape', () {
    for (final restart in [false, true]) {
      test('real 8.9 h night, 15-min folds restart=$restart', () {
        final s = realNightRr()!;
        final origin = s.ts.first - s.rr.first;
        var tl = HrvTimelineState(origin);
        var shape = NightShapeState();
        final cuts = timeCuts(s.ts, 900);
        final checks = {5, 20, 35, cuts.length - 1};
        driveRr(s, cuts, (f) {
          tl.fold(f.settled.nn, f.settled.nnTimes);
          shape.fold(f.settled.nn, f.settled.nnTimes);
          if (!checks.contains(f.fold)) return;
          final o = correctRr(s.rr.sublist(0, f.n), rrTsMs: s.ts.sublist(0, f.n));
          // timeline
          expect(
              tl.curve(f.snap.tailNn, f.snap.tailNnTimes)
                  .map((m) => '${m['t']}:${m['v']}')
                  .toList(),
              oracleHrvTimeline(o.nn, o.nnTimesMs, origin)
                  .map((m) => '${m['t']}:${m['v']}')
                  .toList(),
              reason: 'timeline fold ${f.fold}');
          // night shape
          final want = nightHrvShape(o.nn, o.nnTimesMs);
          final got = shape.evaluate(f.snap.tailNn, f.snap.tailNnTimes);
          sameEnvelope(got, want, why: 'shape ${f.fold}');
          if (want.present) {
            expect(got.value!.toJson(), want.value!.toJson());
            final gb = got.value!.bins, wb = want.value!.bins;
            for (var i = 0; i < wb.length; i++) {
              expect(gb[i].rmssdMs, wb[i].rmssdMs);
              expect(gb[i].loMs, wb[i].loMs);
              expect(gb[i].hiMs, wb[i].hiMs);
              expect(gb[i].nBeats, wb[i].nBeats);
            }
            expect(got.value!.lastOverFirst, want.value!.lastOverFirst);
          }
          if (restart) {
            // json round trip of the HRV timeline ring is covered by day curve;
            // here we only re-create from scratch to prove state is the whole story
          }
        }, restart: restart);
      });
    }
  }, timeout: const Timeout(Duration(minutes: 10)));

  group('rsaRespRate / respPerWindow / BRV', () {
    test('real night 15-min folds (state JSON-restarted each fold)', () {
      final s = realNightRr()!;
      var rsa = RsaWelchState();
      var wins = RespWindowsState();
      final cuts = timeCuts(s.ts, 900);
      final checks = {0, 1, 2, 3, 12, 20, 30, 33, cuts.length - 1};
      var maxBuf = 0;
      driveRr(s, cuts, (f) {
        rsa.fold(f.settled.nn, f.settled.nnTimes);
        rsa = RsaWelchState.fromJson(jsonRoundTrip(rsa.toJson()));
        wins.fold(f.settled.nn, f.settled.nnTimes);
        maxBuf = math.max(maxBuf, rsa.bufferedBeats);
        if (!checks.contains(f.fold)) return;
        final o = correctRr(s.rr.sublist(0, f.n), rrTsMs: s.ts.sublist(0, f.n));
        final af = (1.0 - o.cleanFraction).clamp(0.0, 1.0).toDouble();
        final want = rsaRespRate(o.nn, o.nnTimesMs, artifactFraction: af);
        final got = rsa.evaluate(f.snap.tailNn, f.snap.tailNnTimes,
            artifactFraction: af);
        sameEnvelope(got, want, why: 'rsa fold ${f.fold}');
        expect(got.value?.brpm, want.value?.brpm);
        expect(got.value?.peakHz, want.value?.peakHz);
        expect(got.value?.power, want.value?.power);
        // resp windows + BRV
        final wantW = oracleRespPerWindow(o.nn, o.nnTimesMs);
        final gotW = wins.evaluate(f.snap.tailNn, f.snap.tailNnTimes);
        expect(gotW, orderedEquals(wantW), reason: 'windows fold ${f.fold}');
        if (wantW.length >= 3) {
          final a = breathingRateVariability(gotW);
          final b = breathingRateVariability(wantW);
          expect(a.value!.toJson(), b.value!.toJson());
        }
      });
      // ignore: avoid_print
      print('rsa: max buffered settled beats=$maxBuf (state carries '
          '${maxBuf * 2} doubles + per-segment peaks)');
    });

    test('synthetic dirty 2 h, random chunks + restart', () {
      final s = synthRr(const SynthConfig(seed: 71, hours: 2.2, ectopicPerMin: 1));
      final r = math.Random(3);
      final cuts = randomCuts(r, s.length, sizes: [90, 300, 1000, 2500]);
      var rsa = RsaWelchState();
      driveRr(s, cuts, (f) {
        rsa.fold(f.settled.nn, f.settled.nnTimes);
        if (f.fold % 2 == 0) {
          rsa = RsaWelchState.fromJson(jsonRoundTrip(rsa.toJson()));
        }
        final o = correctRr(s.rr.sublist(0, f.n), rrTsMs: s.ts.sublist(0, f.n));
        final af = (1.0 - o.cleanFraction).clamp(0.0, 1.0).toDouble();
        final want = rsaRespRate(o.nn, o.nnTimesMs, artifactFraction: af);
        final got = rsa.evaluate(f.snap.tailNn, f.snap.tailNnTimes,
            artifactFraction: af);
        sameEnvelope(got, want, why: 'rsa fold ${f.fold} n=${f.n}');
        expect(got.value?.brpm, want.value?.brpm);
      });
    });
  }, timeout: const Timeout(Duration(minutes: 15)));

  group('hrvFreq (LF/HF)', () {
    test('real night 15-min folds, state JSON-restarted each fold', () {
      final s = realNightRr()!;
      var hf = HrvFreqState();
      final cuts = timeCuts(s.ts, 900);
      final checks = {2, 10, 24, cuts.length - 1};
      var maxBuf = 0;
      driveRr(s, cuts, (f) {
        hf.fold(f.settled.nn, f.settled.nnTimes);
        hf = HrvFreqState.fromJson(jsonRoundTrip(hf.toJson()));
        maxBuf = math.max(maxBuf, hf.bufferedBeats);
        if (!checks.contains(f.fold)) return;
        final o = correctRr(s.rr.sublist(0, f.n), rrTsMs: s.ts.sublist(0, f.n));
        final af = (1.0 - o.cleanFraction).clamp(0.0, 1.0).toDouble();
        final want = hrvFreq(o.nn, o.nnTimesMs, artifactFraction: af);
        final got = hf.evaluate(f.snap.tailNn, f.snap.tailNnTimes,
            artifactFraction: af);
        sameEnvelope(got, want, why: 'hrvFreq fold ${f.fold}');
        if (want.present) {
          final a = got.value!, b = want.value!;
          expect(a.ulf, b.ulf);
          expect(a.vlf, b.vlf);
          expect(a.lf, b.lf);
          expect(a.hf, b.hf);
          expect(a.total, b.total);
          expect(a.lfhf, b.lfhf);
          expect(a.nuLf, b.nuLf);
          expect(a.totalBands, b.totalBands);
        }
      });
      // ignore: avoid_print
      print('hrvFreq: max buffered beats=$maxBuf (ULF/VLF keep the record)');
    });
    test('includeUlf:false keeps the buffer small and is exact below 33 333 s', () {
      final s = realNightRr()!; // 32 040 s span < ULF segment
      var hf = HrvFreqState(includeUlf: false);
      final cuts = timeCuts(s.ts, 900);
      final checks = {4, 18, cuts.length - 1};
      var maxBuf = 0, maxBytes = 0;
      driveRr(s, cuts, (f) {
        hf.fold(f.settled.nn, f.settled.nnTimes);
        final txt = jsonEncode(hf.toJson());
        maxBytes = math.max(maxBytes, txt.length);
        hf = HrvFreqState.fromJson(jsonDecode(txt) as Map<String, dynamic>,
            includeUlf: false);
        maxBuf = math.max(maxBuf, hf.bufferedBeats);
        if (!checks.contains(f.fold)) return;
        final o = correctRr(s.rr.sublist(0, f.n), rrTsMs: s.ts.sublist(0, f.n));
        final af = (1.0 - o.cleanFraction).clamp(0.0, 1.0).toDouble();
        final want = hrvFreq(o.nn, o.nnTimesMs, artifactFraction: af);
        final got = hf.evaluate(f.snap.tailNn, f.snap.tailNnTimes,
            artifactFraction: af);
        sameEnvelope(got, want, why: 'hrvFreq noULF fold ${f.fold}');
        if (want.present) {
          expect(got.value!.vlf, want.value!.vlf);
          expect(got.value!.lf, want.value!.lf);
          expect(got.value!.hf, want.value!.hf);
          expect(got.value!.ulf, want.value!.ulf);
          expect(got.value!.total, want.value!.total);
        }
      });
      // ignore: avoid_print
      print('hrvFreq(includeUlf:false): max buffered beats=$maxBuf, '
          'max state JSON bytes=$maxBytes');
      expect(maxBuf, lessThan(8000));
    });
  }, timeout: const Timeout(Duration(minutes: 20)));
}
