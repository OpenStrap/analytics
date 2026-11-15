// Oracle tests for the three DAY-side curves that live in edge:
//   dayHrvCurve, dayRespCurve, _daytimeHrv  (verbatim ports in edge_oracles.dart)
// Chunked by wall time like derive passes: RR with ts < T and accel rows with
// tsSec < T arrive together, watermark = T. JSON restart between chunks.
import 'dart:math' as math;

import 'package:test/test.dart';

import '../../tool/incremental/edge_oracles.dart';
import '../../tool/incremental/hrv_incr.dart';
import '../../tool/incremental/oracle_util.dart';
import '../../tool/incremental/resp_incr.dart';
import '../../tool/incremental/synth.dart';

class _Day {
  final RrData rr;
  final AccelSeries acc;
  _Day(this.rr, this.acc);
  DaySub prefix(int rrN, int accN) => DaySub(
      rr.rr.sublist(0, rrN),
      rr.ts.sublist(0, rrN),
      acc.tsSec.sublist(0, accN),
      acc.ax.sublist(0, accN),
      acc.ay.sublist(0, accN),
      acc.az.sublist(0, accN));
}

_Day _makeDay({bool backwards = false}) {
  final rr = backwards
      ? synthRr(const SynthConfig(seed: 81, hours: 6, backwardsPerHour: 10))
      : realShapedDay();
  final from = (rr.ts.first / 1000).floor() - 2;
  final to = (rr.ts.last / 1000).ceil() + 3;
  return _Day(rr, synthAccel(5, from, to));
}

/// wall-clock cut points (seconds) like derive passes: mostly 15 min, some odd.
List<int> _cutSecs(_Day d, math.Random r) {
  final first = (d.rr.ts.first / 1000).floor(), last = (d.rr.ts.last / 1000).ceil() + 3;
  final cuts = <int>[];
  var t = first;
  while (t < last) {
    t += [60, 300, 900, 900, 900, 1800, 3600][r.nextInt(7)] + r.nextInt(7);
    cuts.add(math.min(t, last + 1));
  }
  return cuts;
}

void main() {
  final day = _makeDay();
  final sleepOnset = 1700000000, sleepOffset = 1700000000 + 32040;

  test('dayHrvCurve: 24 h in random wall-time chunks, restart each chunk', () {
    final r = math.Random(1);
    var st = DayHrvCurveState();
    var rrAt = 0;
    var maxRing = 0;
    final cuts = _cutSecs(day, r);
    for (var k = 0; k < cuts.length; k++) {
      final T = cuts[k];
      var rrTo = rrAt;
      while (rrTo < day.rr.length && day.rr.ts[rrTo] < T * 1000.0) {
        rrTo++;
      }
      st.fold(day.rr.rr.sublist(rrAt, rrTo), day.rr.ts.sublist(rrAt, rrTo));
      rrAt = rrTo;
      st = DayHrvCurveState.fromJson(jsonRoundTrip(st.toJson()));
      maxRing = math.max(maxRing, st.ringSize);
      if (k % 7 == 0 || k == cuts.length - 1) {
        final want = oracleDayHrvCurve(day.prefix(rrTo, 0));
        expect(st.out.map((m) => '${m['t']}:${m['v']}').toList(),
            want.map((m) => '${m['t']}:${m['v']}').toList(),
            reason: 'chunk $k');
      }
    }
    // ignore: avoid_print
    print('dayHrvCurve: points=${st.out.length}, max ring beats=$maxRing');
  });

  test('dayHrvCurve with backwards timestamps', () {
    final d = _makeDay(backwards: true);
    final st = DayHrvCurveState();
    final r = math.Random(2);
    var at = 0;
    for (final cut in randomCuts(r, d.rr.length, sizes: [1, 10, 500, 3000])) {
      st.fold(d.rr.rr.sublist(at, cut), d.rr.ts.sublist(at, cut));
      at = cut;
    }
    final want = oracleDayHrvCurve(d.prefix(d.rr.length, 0));
    expect(st.out.map((m) => '${m['t']}:${m['v']}').toList(),
        want.map((m) => '${m['t']}:${m['v']}').toList());
  });

  for (final lag in [0, 400]) {
  test('_daytimeHrv: 24 h, night masked, accel lag=${lag}s behind RR, restart', () {
    final r = math.Random(3);
    var st = DaytimeHrvState(sleepOnset, sleepOffset);
    var rrAt = 0, accAt = 0;
    final cuts = _cutSecs(day, r);
    var maxPending = 0;
    for (var k = 0; k < cuts.length; k++) {
      final T = cuts[k];
      var rrTo = rrAt, accTo = accAt;
      while (rrTo < day.rr.length && day.rr.ts[rrTo] < T * 1000.0) {
        rrTo++;
      }
      while (accTo < day.acc.length && day.acc.tsSec[accTo] < T - lag) {
        accTo++;
      }
      st.fold(
          day.rr.rr.sublist(rrAt, rrTo),
          day.rr.ts.sublist(rrAt, rrTo),
          day.acc.tsSec.sublist(accAt, accTo),
          day.acc.ax.sublist(accAt, accTo),
          day.acc.ay.sublist(accAt, accTo),
          day.acc.az.sublist(accAt, accTo),
          T - lag);
      rrAt = rrTo;
      accAt = accTo;
      st = DaytimeHrvState.fromJson(jsonRoundTrip(st.toJson()), sleepOnset, sleepOffset);
      maxPending = math.max(maxPending, st.pending);
      if (k % 5 == 0 || k == cuts.length - 1) {
        // the oracle only sees what has been delivered AND processed: beats
        // pending (second not yet reported) are excluded from the prefix.
        final processedRr = rrTo - st.pending;
        final want = oracleDaytimeHrv(day.prefix(processedRr, accTo), sleepOnset, sleepOffset);
        final got = st.result();
        expect(got['timeline'].toString(), want['timeline'].toString(), reason: 'chunk $k');
        expect(got['mean_rmssd'], want['mean_rmssd']);
        expect(got['n_buckets'], want['n_buckets']);
      }
    }
    // ignore: avoid_print
    print('daytimeHrv: max pending beats at a chunk edge=$maxPending '
        'buckets=${st.result()['n_buckets']}');
    if (lag > 0) expect(maxPending, greaterThan(0));
  });
  }

  test('_daytimeHrv with no sleep window (onset=offset=0)', () {
    final st = DaytimeHrvState(0, 0);
    st.fold(day.rr.rr, day.rr.ts, day.acc.tsSec, day.acc.ax, day.acc.ay, day.acc.az,
        (day.rr.ts.last / 1000).ceil() + 10);
    final want = oracleDaytimeHrv(day.prefix(day.rr.length, day.acc.length), 0, 0);
    expect(st.result().toString(), want.toString());
  });

  for (final lag in [0, 400]) {
  test('dayRespCurve: 24 h, accel lag=${lag}s behind RR, restart each chunk', () {
    final r = math.Random(4);
    var st = DayRespCurveState();
    var rrAt = 0, accAt = 0;
    final cuts = _cutSecs(day, r);
    var maxPending = 0, maxRing = 0;
    for (var k = 0; k < cuts.length; k++) {
      final T = cuts[k];
      var rrTo = rrAt, accTo = accAt;
      while (rrTo < day.rr.length && day.rr.ts[rrTo] < T * 1000.0) {
        rrTo++;
      }
      while (accTo < day.acc.length && day.acc.tsSec[accTo] < T - lag) {
        accTo++;
      }
      st.fold(
          day.rr.rr.sublist(rrAt, rrTo),
          day.rr.ts.sublist(rrAt, rrTo),
          day.acc.tsSec.sublist(accAt, accTo),
          day.acc.ax.sublist(accAt, accTo),
          day.acc.ay.sublist(accAt, accTo),
          day.acc.az.sublist(accAt, accTo),
          T - lag);
      rrAt = rrTo;
      accAt = accTo;
      st = DayRespCurveState.fromJson(jsonRoundTrip(st.toJson()));
      maxPending = math.max(maxPending, st.pending);
      maxRing = math.max(maxRing, st.ringBeats);
      if (k % 6 == 0 || k == cuts.length - 1) {
        final processedRr = rrTo - st.pending;
        final want = oracleDayRespCurve(day.prefix(processedRr, accTo));
        expect(st.curve.map((m) => '${m['t']}:${m['v']}').toList(),
            want.map((m) => '${m['t']}:${m['v']}').toList(),
            reason: 'chunk $k');
      }
    }
    // ignore: avoid_print
    print('dayRespCurve lag=$lag: points=${st.curve.length} '
        'max pending=$maxPending max ring beats=$maxRing');
    expect(st.curve, isNotEmpty);
    if (lag > 0) expect(maxPending, greaterThan(0));
  });
  }
}
