// "Never fabricate": at EVERY short prefix (1-beat folds, n = 0..~700) every
// incremental estimator is absent exactly where its oracle is absent, present
// exactly where it is present, with the same note.
import 'package:openstrap_analytics/onehz.dart'
    hide RrCorrector, RrSettled, RrSnapshot, IrregularScreenState;
import 'package:test/test.dart';

import '../../tool/incremental/driver.dart';
import '../../tool/incremental/edge_oracles.dart';
import '../../tool/incremental/hrv_incr.dart';
import '../../tool/incremental/resp_incr.dart';
import '../../tool/incremental/synth.dart';
import 'support.dart';

void main() {
  for (final name in ['clean', 'dirty']) {
    test('thin-input sweep, 1-beat folds ($name)', () {
      final s = name == 'clean'
          ? synthRr(const SynthConfig(
              seed: 101,
              hours: 0.4,
              ectopicPerMin: 0,
              missedPerMin: 0,
              extraPerMin: 0,
              noiseRunPerMin: 0,
              gapPerHour: 0))
          : synthRr(const SynthConfig(
              seed: 102, hours: 0.4, ectopicPerMin: 3, noiseRunPerMin: 1, gapPerHour: 20));
      final n = s.length < 760 ? s.length : 760;
      final sub = RrData(s.rr.sublist(0, n), s.ts.sublist(0, n));
      final cuts = [for (var i = 1; i <= n; i++) i];
      final acc = HrvTimeAcc();
      final noc = NocturnalRmssdState();
      final shape = NightShapeState(binMin: 2, minBeatsPerBin: 20);
      final rsa = RsaWelchState();
      final hf = HrvFreqState();
      final irr = IrregularScreenState();
      final origin = sub.ts.first - sub.rr.first;
      final tl = HrvTimelineState(origin);
      final wins = RespWindowsState(windowMs: 120000, minBeats: 20);
      var presentCount = <String, int>{};
      void tally(String k, bool p) => presentCount[k] = (presentCount[k] ?? 0) + (p ? 1 : 0);
      driveRr(sub, cuts, (f) {
        acc.fold(f.settled.nn, f.settled.nnTimes);
        noc.fold(f.settled.nn, f.settled.nnTimes);
        shape.fold(f.settled.nn, f.settled.nnTimes);
        rsa.fold(f.settled.nn, f.settled.nnTimes);
        hf.fold(f.settled.nn, f.settled.nnTimes);
        irr.fold(f.settled.nn, f.settled.nnTimes);
        tl.fold(f.settled.nn, f.settled.nnTimes);
        wins.fold(f.settled.nn, f.settled.nnTimes);
        if (!(f.n <= 130 || f.n % 9 == 0)) return;
        final o = correctRr(sub.rr.sublist(0, f.n), rrTsMs: sub.ts.sublist(0, f.n));
        final af = (1.0 - o.cleanFraction).clamp(0.0, 1.0).toDouble();
        final why = '$name n=${f.n}';
        // hrvTime
        var w = hrvTime(o.nn, nnTimesMs: o.nnTimesMs, artifactFraction: af);
        var g = acc.evaluate(f.snap.tailNn, f.snap.tailNnTimes, artifactFraction: af);
        expect(g.present, w.present, reason: 'hrvTime $why');
        expect(g.note, w.note);
        tally('hrvTime', w.present);
        if (w.present) {
          expect(g.value!.rmssd == null, w.value!.rmssd == null, reason: why);
          expect(g.value!.sdann == null, w.value!.sdann == null, reason: why);
          expect(g.value!.sdnnIndex == null, w.value!.sdnnIndex == null, reason: why);
          expect(g.value!.diffAcf1 == null, w.value!.diffAcf1 == null, reason: why);
        }
        // nocturnal
        final wn = nocturnalRmssd(o.nn, o.nnTimesMs);
        final gn = noc.evaluate(f.snap.tailNn, f.snap.tailNnTimes);
        expect(gn.present, wn.present, reason: 'nocturnal $why');
        expect(gn.note, wn.note);
        tally('nocturnalRmssd', wn.present);
        // shape (2-min bins so the 3-bin gate is reachable at this size)
        final ws = nightHrvShape(o.nn, o.nnTimesMs, minBeatsPerBin: 20, binMin: 2);
        final gs = shape.evaluate(f.snap.tailNn, f.snap.tailNnTimes);
        sameEnvelope(gs, ws, why: 'shape $why');
        if (ws.present) expect(gs.value!.toJson(), ws.value!.toJson(), reason: why);
        tally('nightShape', ws.present);
        // rsa
        final wr = rsaRespRate(o.nn, o.nnTimesMs, artifactFraction: af);
        final gr = rsa.evaluate(f.snap.tailNn, f.snap.tailNnTimes, artifactFraction: af);
        expect(gr.present, wr.present, reason: 'rsa $why');
        expect(gr.note, wr.note);
        expect(gr.value?.brpm, wr.value?.brpm);
        tally('rsa', wr.present);
        // hrvFreq
        final wf = hrvFreq(o.nn, o.nnTimesMs, artifactFraction: af);
        final gf = hf.evaluate(f.snap.tailNn, f.snap.tailNnTimes, artifactFraction: af);
        expect(gf.present, wf.present, reason: 'hrvFreq $why');
        expect(gf.note, wf.note);
        tally('hrvFreq', wf.present);
        if (wf.present) {
          expect(gf.value!.lf, wf.value!.lf, reason: why);
          expect(gf.value!.hf, wf.value!.hf, reason: why);
          expect(gf.value!.vlf, wf.value!.vlf, reason: why);
        }
        // irregular (500-beat floor: absent until then, exactly)
        final wi = irregularBeatScreen(o.nn, nnTimesMs: o.nnTimesMs, artifactFraction: af);
        final gi = irr.evaluate(f.snap.tailNn, f.snap.tailNnTimes, artifactFraction: af);
        expect(gi.present, wi.present, reason: 'irregular $why');
        expect(gi.note, wi.note);
        tally('irregular', wi.present);
        // timeline
        final wt = oracleHrvTimeline(o.nn, o.nnTimesMs, origin);
        expect(tl.curve(f.snap.tailNn, f.snap.tailNnTimes).length, wt.length,
            reason: 'timeline $why');
        // resp windows
        final ww = oracleRespPerWindow(o.nn, o.nnTimesMs, windowMs: 120000, minBeats: 20);
        expect(wins.evaluate(f.snap.tailNn, f.snap.tailNnTimes), orderedEquals(ww),
            reason: 'respWindows $why');
      });
      // ignore: avoid_print
      print('$name: present-at-checked-prefix counts $presentCount');
    });
  }
}
