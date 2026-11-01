// Timing: whole-series oracle vs incremental (fold + evaluate) per 15-min pass.
// dart run tool/incremental/bench_all.dart
import 'dart:convert';
import 'package:openstrap_analytics/onehz.dart'
    hide RrCorrector, RrSettled, RrSnapshot, IrregularScreenState;
import 'driver.dart';
import 'edge_oracles.dart';
import 'hrv_incr.dart';
import 'oracle_util.dart';
import 'resp_incr.dart';
import 'synth.dart';

double ms(Stopwatch s) => s.elapsedMicroseconds / 1000.0;
double sum(List<double> x) => x.fold(0.0, (a, b) => a + b);
double mean(List<double> x) => x.isEmpty ? 0 : sum(x) / x.length;
double mx(List<double> x) => x.fold(0.0, (a, b) => a > b ? a : b);

class Row {
  final String name;
  final double oracleFullMs;
  final List<double> passMs; // fold+evaluate per pass
  final int stateBytes;
  Row(this.name, this.oracleFullMs, this.passMs, this.stateBytes);
  String line() =>
      '| $name | ${oracleFullMs.toStringAsFixed(0)} | ${mean(passMs).toStringAsFixed(1)} | ${mx(passMs).toStringAsFixed(1)} | ${sum(passMs).toStringAsFixed(0)} | $stateBytes |';
}

T timed<T>(Stopwatch sw, T Function() f, List<double> sink) {
  sw..reset()..start();
  final r = f();
  sink.add(ms(sw));
  return r;
}

void main() {
  final night = realNightRr()!;
  final cuts = timeCuts(night.ts, 900);
  final steps = <FoldStep>[];
  driveRr(night, cuts, steps.add);
  final o = correctRr(night.rr, rrTsMs: night.ts);
  final af = (1.0 - o.cleanFraction).clamp(0.0, 1.0).toDouble();
  print('night: ${night.length} beats, ${steps.length} folds, '
      'NN=${o.nn.length}, artifactFraction=${af.toStringAsFixed(4)}');
  final sw = Stopwatch();
  final rows = <Row>[];

  Row bench(String name, double Function() oracle, void Function(FoldStep, List<double>) pass, int Function() bytes) {
    oracle(); // warm
    sw..reset()..start();
    oracle();
    final fullMs = ms(sw);
    final ps = <double>[];
    for (final f in steps) {
      pass(f, ps);
    }
    final r = Row(name, fullMs, ps, bytes());
    rows.add(r);
    return r;
  }

  // hrvTime
  {
    var acc = HrvTimeAcc();
    bench('hrvTime scalars (night)', () {
      sw..reset()..start();
      hrvTime(o.nn, nnTimesMs: o.nnTimesMs, artifactFraction: af);
      return ms(sw);
    }, (f, ps) {
      timed(sw, () {
        acc.fold(f.settled.nn, f.settled.nnTimes);
        acc.evaluate(f.snap.tailNn, f.snap.tailNnTimes, artifactFraction: f.artifactFraction);
      }, ps);
    }, () => jsonEncode(acc.toJson()).length);
  }
  // nocturnal rmssd
  {
    final st = NocturnalRmssdState();
    bench('nocturnalRmssd', () {
      sw..reset()..start();
      nocturnalRmssd(o.nn, o.nnTimesMs);
      return ms(sw);
    }, (f, ps) {
      timed(sw, () {
        st.fold(f.settled.nn, f.settled.nnTimes);
        st.evaluate(f.snap.tailNn, f.snap.tailNnTimes);
      }, ps);
    }, () => st.recs.length * 60);
  }
  // session rmssd (raw)
  {
    final start = (night.ts.first / 1000).floor() + 1234;
    final end = (night.ts.last / 1000).floor() - 987;
    final st = SessionRmssdState(start, end);
    var from = 0;
    var k = 0;
    bench('sleepSessionWindowedRmssd (raw RR)', () {
      sw..reset()..start();
      sleepSessionWindowedRmssd(night.rr, night.ts, startSec: start, endSec: end);
      return ms(sw);
    }, (f, ps) {
      timed(sw, () {
        st.fold(night.rr.sublist(from, cuts[k]), night.ts.sublist(from, cuts[k]));
        from = cuts[k];
        k++;
        st.evaluate();
      }, ps);
    }, () => st.recs.length * 60);
  }
  // night shape
  {
    final st = NightShapeState();
    bench('nightHrvShape', () {
      sw..reset()..start();
      nightHrvShape(o.nn, o.nnTimesMs);
      return ms(sw);
    }, (f, ps) {
      timed(sw, () {
        st.fold(f.settled.nn, f.settled.nnTimes);
        st.evaluate(f.snap.tailNn, f.snap.tailNnTimes);
      }, ps);
    }, () => st.closed.length * 40);
  }
  // hrv timeline
  {
    final origin = night.ts.first - night.rr.first;
    final st = HrvTimelineState(origin);
    bench('_hrvTimeline (night)', () {
      sw..reset()..start();
      oracleHrvTimeline(o.nn, o.nnTimesMs, origin);
      return ms(sw);
    }, (f, ps) {
      timed(sw, () {
        st.fold(f.settled.nn, f.settled.nnTimes);
        st.curve(f.snap.tailNn, f.snap.tailNnTimes);
      }, ps);
    }, () => st.out.length * 20 + 900 * 16);
  }
  // rsa
  {
    var st = RsaWelchState();
    bench('rsaRespRate (night)', () {
      sw..reset()..start();
      rsaRespRate(o.nn, o.nnTimesMs, artifactFraction: af);
      return ms(sw);
    }, (f, ps) {
      timed(sw, () {
        st.fold(f.settled.nn, f.settled.nnTimes);
        st.evaluate(f.snap.tailNn, f.snap.tailNnTimes, artifactFraction: f.artifactFraction);
      }, ps);
    }, () => jsonEncode(st.toJson()).length);
  }
  // resp windows
  {
    final st = RespWindowsState();
    bench('_respPerWindow (30-min bins)', () {
      sw..reset()..start();
      oracleRespPerWindow(o.nn, o.nnTimesMs);
      return ms(sw);
    }, (f, ps) {
      timed(sw, () {
        st.fold(f.settled.nn, f.settled.nnTimes);
        st.evaluate(f.snap.tailNn, f.snap.tailNnTimes);
      }, ps);
    }, () => st.closed.length * 8 + 12000);
  }
  // hrvFreq
  {
    var st = HrvFreqState();
    bench('hrvFreq LF/HF (night)', () {
      sw..reset()..start();
      hrvFreq(o.nn, o.nnTimesMs, artifactFraction: af);
      return ms(sw);
    }, (f, ps) {
      timed(sw, () {
        st.fold(f.settled.nn, f.settled.nnTimes);
        st.evaluate(f.snap.tailNn, f.snap.tailNnTimes, artifactFraction: f.artifactFraction);
      }, ps);
    }, () => jsonEncode(st.toJson()).length);
  }
  print('\nNIGHT estimators (8.9 h, 32k beats, 15-min passes)');
  print('| estimator | oracle whole-night ms | incr mean ms/pass | max | sum over passes | state bytes (json) |');
  print('|---|---|---|---|---|---|');
  rows.forEach((r) => print(r.line()));

  // ---------------- day-long ----------------
  final day = realShapedDay();
  final dcuts = timeCuts(day.ts, 900);
  final dsteps = <FoldStep>[];
  driveRr(day, dcuts, dsteps.add);
  final from = (day.ts.first / 1000).floor() - 2, to = (day.ts.last / 1000).ceil() + 3;
  final acc = synthAccel(5, from, to);
  final dsub = DaySub(day.rr, day.ts, acc.tsSec, acc.ax, acc.ay, acc.az);
  final drows = <Row>[];
  print('\nday: ${day.length} beats, ${dsteps.length} folds');
  // irregular
  {
    final o2 = correctRr(day.rr, rrTsMs: day.ts);
    final af2 = (1.0 - o2.cleanFraction).clamp(0.0, 1.0).toDouble();
    irregularBeatScreen(o2.nn, nnTimesMs: o2.nnTimesMs, artifactFraction: af2);
    sw..reset()..start();
    irregularBeatScreen(o2.nn, nnTimesMs: o2.nnTimesMs, artifactFraction: af2);
    final full = ms(sw);
    var st = IrregularScreenState();
    final ps = <double>[];
    for (final f in dsteps) {
      timed(sw, () {
        st.fold(f.settled.nn, f.settled.nnTimes);
        st.evaluate(f.snap.tailNn, f.snap.tailNnTimes, artifactFraction: f.artifactFraction);
      }, ps);
    }
    drows.add(Row('irregularBeatScreen (day NN, excl. correctRr)', full, ps, jsonEncode(st.toJson()).length));
  }
  // day hrv curve
  {
    oracleDayHrvCurve(dsub);
    sw..reset()..start();
    oracleDayHrvCurve(dsub);
    final full = ms(sw);
    final st = DayHrvCurveState();
    final ps = <double>[];
    var a = 0;
    for (final cut in dcuts) {
      timed(sw, () {
        st.fold(day.rr.sublist(a, cut), day.ts.sublist(a, cut));
      }, ps);
      a = cut;
    }
    drows.add(Row('dayHrvCurve', full, ps, jsonEncode(st.toJson()).length));
  }
  // daytime hrv
  {
    oracleDaytimeHrv(dsub, 1700000000, 1700032040);
    sw..reset()..start();
    oracleDaytimeHrv(dsub, 1700000000, 1700032040);
    final full = ms(sw);
    final st = DaytimeHrvState(1700000000, 1700032040);
    final ps = <double>[];
    var ra = 0, aa = 0;
    for (final cut in dcuts) {
      final T = (day.ts[cut - 1] / 1000).floor() + 1;
      var at = aa;
      while (at < acc.length && acc.tsSec[at] < T) {
        at++;
      }
      timed(sw, () {
        st.fold(day.rr.sublist(ra, cut), day.ts.sublist(ra, cut), acc.tsSec.sublist(aa, at),
            acc.ax.sublist(aa, at), acc.ay.sublist(aa, at), acc.az.sublist(aa, at), T);
        st.result();
      }, ps);
      ra = cut;
      aa = at;
    }
    drows.add(Row('_daytimeHrv', full, ps, jsonEncode(st.toJson()).length));
  }
  // day resp curve
  {
    oracleDayRespCurve(dsub);
    sw..reset()..start();
    oracleDayRespCurve(dsub);
    final full = ms(sw);
    final st = DayRespCurveState();
    final ps = <double>[];
    var ra = 0, aa = 0;
    for (final cut in dcuts) {
      final T = (day.ts[cut - 1] / 1000).floor() + 1;
      var at = aa;
      while (at < acc.length && acc.tsSec[at] < T) {
        at++;
      }
      timed(sw, () {
        st.fold(day.rr.sublist(ra, cut), day.ts.sublist(ra, cut), acc.tsSec.sublist(aa, at),
            acc.ax.sublist(aa, at), acc.ay.sublist(aa, at), acc.az.sublist(aa, at), T);
      }, ps);
      ra = cut;
      aa = at;
    }
    drows.add(Row('dayRespCurve', full, ps, jsonEncode(st.toJson()).length));
  }
  print('\nDAY estimators (23 h, 97k beats, 15-min passes)');
  print('| estimator | oracle whole-day ms | incr mean ms/pass | max | sum over passes | state bytes (json) |');
  print('|---|---|---|---|---|---|');
  drows.forEach((r) => print(r.line()));
}
