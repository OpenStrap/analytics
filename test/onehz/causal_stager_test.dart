// CAUSAL (online) sleep stager — contract tests.
//
// What is pinned here, in the order the tests appear:
//   1. causality       — nothing after `nowMs` can influence an output
//   2. determinism     — same inputs, same bytes; survives JSON + an isolate hop
//   3. replacement     — re-sent / overlapping / corrected windows converge on
//                        the state a clean feed would have produced
//   4. abstention      — every reason fires, carries its reason, and never
//                        leaves a stage, a confidence or a run behind
//   5. warm-up         — exact have/need accounting, then it stages
//   6. behaviour       — on separable synthetic regimes it stages what is there
//   7. state           — plain data, bounded, rejects garbage
//
// The synthetic night is in support/causal_night.dart.

import 'dart:convert';
import 'dart:isolate';

import 'package:test/test.dart';
import 'package:openstrap_analytics/onehz.dart';

import 'support/causal_night.dart';

/// Everything an observation decides, excluding bookkeeping counters in the
/// trace (e.g. how many future samples were ignored) — those legitimately
/// differ when a caller sends more than it should.
String core(CausalStageObservation o) => jsonEncode([
      o.stage.name,
      o.confidence,
      o.evidenceAgeMs,
      o.abstentionReason?.name,
      o.runSec,
      o.epochStartMs,
      o.note,
      o.nextState.toJson(),
    ]);

/// Full signature, trace included.
String full(CausalStageObservation o) =>
    jsonEncode([o.toJson(), o.nextState.toJson()]);

/// Stream a night in `stepSec` increments from `fromSec` to `toSec`, optionally
/// re-sending `overlapSec` of history in every window. Returns every
/// observation.
List<CausalStageObservation> stream(
  SynthNight n,
  int toSec, {
  int fromSec = 0,
  int stepSec = 30,
  int overlapSec = 0,
  CausalStagerState? start,
}) {
  final out = <CausalStageObservation>[];
  var state = start;
  for (var t = fromSec + stepSec; t <= toSec; t += stepSec) {
    final o = CausalStager.observe(
        windowOf(n, t - stepSec - overlapSec, t), state);
    out.add(o);
    state = o.nextState;
  }
  return out;
}

void expectAbsent(CausalStageObservation o, CausalAbstention why) {
  expect(o.stage, CausalStage.absent);
  expect(o.abstentionReason, why);
  expect(o.confidence, 0, reason: 'absent ⇒ confidence 0');
  expect(o.runSec, 0);
}

void main() {
  final night = synthNight(standardNight());
  final warmSec = CausalStagerConfig.defaults.warmupEpochs * 30;

  group('exports', () {
    test('the public barrel exposes the whole surface', () {
      // Compiles only if every name is exported from onehz.dart.
      expect(CausalStage.values.map((s) => s.name),
          containsAll(['wake', 'nrem', 'rem', 'absent']));
      expect(CausalAbstention.values, isNotEmpty);
      expect(CausalStagerConfig.defaults.warmupEpochs, greaterThan(0));
    });
  });

  group('causality', () {
    test('samples after nowMs never change any output or state', () {
      CausalStagerState? sPast, sFut;
      var sawIgnored = false;
      for (var t = 30; t <= 100 * 60; t += 30) {
        final past = windowOf(night, t - 30, t);
        // same call, but the window also carries 10 min of FUTURE samples
        final fut = windowOf(night, t - 30, t + 600, nowSec: t);
        final a = CausalStager.observe(past, sPast);
        final b = CausalStager.observe(fut, sFut);
        expect(core(b), core(a), reason: 'diverged at t=${t}s');
        if (((b.trace['ignoredFuture'] as num?) ?? 0) > 0) sawIgnored = true;
        sPast = a.nextState;
        sFut = b.nextState;
      }
      expect(sawIgnored, isTrue,
          reason: 'the guard must actually have been exercised');
    });

    test('rewriting the future cannot move the present', () {
      final base = stream(night, 90 * 60);
      // Same history, then a window whose samples after `now` are garbage.
      final t = 90 * 60;
      final state = base[base.length - 2].nextState;
      final clean = windowOf(night, t - 30, t);
      final dirty = CausalSampleWindow(
        nowMs: clean.nowMs,
        hr: [
          ...clean.hr,
          for (var i = 1; i <= 120; i++)
            HrSample(clean.nowMs + i * 1000.0, 190), // a future "wake"
        ],
        accel: [
          ...clean.accel,
          for (var i = 1; i <= 120; i++)
            AccelSample(clean.nowMs + i * 1000.0, 3, 3, 3),
        ],
        rr: clean.rr,
      );
      expect(core(CausalStager.observe(dirty, state)),
          core(CausalStager.observe(clean, state)));
    });

    test('an output at time t is identical whether or not the stream continues',
        () {
      final short = stream(night, 80 * 60);
      final long = stream(night, 120 * 60);
      for (var i = 0; i < short.length; i++) {
        expect(full(long[i]), full(short[i]));
      }
    });
  });

  group('determinism', () {
    test('the same inputs give byte-identical outputs and state', () {
      final a = stream(night, 70 * 60);
      final b = stream(night, 70 * 60);
      for (var i = 0; i < a.length; i++) {
        expect(full(b[i]), full(a[i]));
      }
    });

    test('state survives JSON (restart / persistence) without changing results',
        () {
      CausalStagerState? plain, viaJson;
      for (var t = 30; t <= 80 * 60; t += 30) {
        final w = windowOf(night, t - 30, t);
        final a = CausalStager.observe(w, plain);
        final b = CausalStager.observe(w, viaJson);
        expect(full(b), full(a), reason: 'diverged at t=${t}s');
        plain = a.nextState;
        final j = jsonDecode(jsonEncode(b.nextState.toJson()));
        viaJson = CausalStagerState.fromJson(j as Map<String, dynamic>);
        expect(viaJson, isNotNull);
      }
    });

    test('the result does not depend on how the stream is chunked', () {
      final fine = stream(night, 3600, stepSec: 30).last;
      final mid = stream(night, 3600, stepSec: 300).last;
      final coarse = stream(night, 3600, stepSec: 3600).last;
      expect(core(mid), core(fine));
      expect(core(coarse), core(fine));
    });

    test('state and window cross an isolate boundary and give the same answer',
        () async {
      final upTo = stream(night, 60 * 60);
      final state = upTo[upTo.length - 2].nextState;
      final w = windowOf(night, 60 * 60 - 30, 60 * 60);
      final local = CausalStager.observe(w, state);
      final remote = await Isolate.run(() => CausalStager.observe(w, state));
      expect(full(remote), full(local));
    });
  });

  group('incremental replacement', () {
    test('re-sending the same window changes nothing', () {
      final upTo = stream(night, 50 * 60);
      final prior = upTo[upTo.length - 2].nextState;
      final w = windowOf(night, 50 * 60 - 30, 50 * 60);
      final first = CausalStager.observe(w, prior);
      final again = CausalStager.observe(w, first.nextState);
      expect(core(again), core(first));
      final thrice = CausalStager.observe(w, again.nextState);
      expect(core(thrice), core(first));
    });

    test('overlapping windows converge on the same state as a clean feed', () {
      final clean = stream(night, 75 * 60);
      final overlap = stream(night, 75 * 60, overlapSec: 120);
      for (var i = 0; i < clean.length; i++) {
        expect(core(overlap[i]), core(clean[i]), reason: 'step $i');
      }
    });

    test('a corrected re-send replaces earlier samples', () {
      final t = 70 * 60;
      final upTo = stream(night, t - 30);
      final prior = upTo.last.nextState;
      // First delivery of the last 3 min is corrupt (HR 40 bpm off-spec)...
      final lo = t - 180;
      final good = windowOf(night, lo, t);
      // ...and every beat doubled, which only a span REPLACEMENT (not a
      // per-key upsert) can undo.
      final bad = CausalSampleWindow(
        nowMs: good.nowMs,
        hr: [for (final h in good.hr) HrSample(h.tsMs, 40)],
        accel: good.accel,
        rr: RrSeries([
          for (var i = 0; i < good.rr.length; i++) ...[
            good.rr.tsMs[i],
            good.rr.tsMs[i]
          ]
        ], [
          for (var i = 0; i < good.rr.length; i++) ...[
            good.rr.rrMs[i],
            good.rr.rrMs[i]
          ]
        ]),
      );
      final afterBad = CausalStager.observe(bad, prior);
      // ...then the producer re-sends the correct window.
      final fixed = CausalStager.observe(good, afterBad.nextState);
      final clean = CausalStager.observe(good, prior);
      expect(core(fixed), core(clean));
      expect(jsonEncode(fixed.nextState.toJson()),
          jsonEncode(clean.nextState.toJson()));
    });

    test('samples older than the replacement horizon are ignored, not applied',
        () {
      final t = 80 * 60;
      final upTo = stream(night, t);
      final state = upTo.last.nextState;
      // Re-send an old minute with different content, with a fresh `now`.
      final old = windowOf(night, 20 * 60, 21 * 60, nowSec: t);
      final poisoned = CausalSampleWindow(
        nowMs: old.nowMs,
        hr: [for (final h in old.hr) HrSample(h.tsMs, 150)],
        accel: old.accel,
        rr: old.rr,
      );
      final o = CausalStager.observe(poisoned, state);
      expect(o.trace['ignoredStale'], greaterThan(0));
      expect(jsonEncode(o.nextState.toJson()),
          jsonEncode(state.toJson()));
    });

    test('duplicate seconds inside one window: the later entry wins', () {
      final t = 50 * 60;
      final prior = stream(night, t - 30).last.nextState;
      final w = windowOf(night, t - 30, t);
      final withDup = CausalSampleWindow(
        nowMs: w.nowMs,
        hr: [for (final h in w.hr) HrSample(h.tsMs, 150), ...w.hr],
        accel: w.accel,
        rr: w.rr,
      );
      expect(core(CausalStager.observe(withDup, prior)),
          core(CausalStager.observe(w, prior)));
    });
  });

  group('abstention', () {
    // Stream clean to `t`, then hand back state + the last observation.
    CausalStagerState warm(int t) => stream(night, t).last.nextState;
    final t = warmSec + 20 * 60;

    test('absent window, no prior: noEvidence, with a usable state', () {
      final o = CausalStager.observe(
          CausalSampleWindow(nowMs: kT0Ms, hr: const [], accel: const []),
          null);
      expectAbsent(o, CausalAbstention.noEvidence);
      expect(o.evidenceAgeMs, isNull);
      expect(o.epochStartMs, isNull);
      expect(jsonEncode(o.nextState.toJson()), isNotEmpty);
    });

    test('data stopped (disconnect): staleEvidence, never a carried stage', () {
      final s = warm(t);
      final ok = CausalStager.observe(windowOf(night, t, t + 30), s);
      expect(ok.stage, isNot(CausalStage.absent), reason: 'precondition');
      final o = CausalStager.observe(
          CausalSampleWindow(
              nowMs: night.t0Ms + (t + 30 + 300) * 1000.0,
              hr: const [],
              accel: const []),
          ok.nextState);
      expectAbsent(o, CausalAbstention.staleEvidence);
      expect(o.evidenceAgeMs, greaterThanOrEqualTo(300 * 1000));
    });

    test('evidence just inside the freshness limit still stages', () {
      final s = warm(t);
      final maxAge = CausalStagerConfig.defaults.maxEvidenceAgeSec;
      final o = CausalStager.observe(
          CausalSampleWindow(
              nowMs: night.t0Ms + (t + maxAge - 5) * 1000.0,
              hr: const [],
              accel: const []),
          s);
      expect(o.stage, isNot(CausalStage.absent));
      expect(o.evidenceAgeMs, lessThanOrEqualTo(maxAge * 1000));
    });

    test('clock going backwards: clockRegressed, state untouched', () {
      final s = warm(t);
      final o = CausalStager.observe(
          windowOf(night, t - 120, t - 60, nowSec: t - 300), s);
      expectAbsent(o, CausalAbstention.clockRegressed);
      expect(jsonEncode(o.nextState.toJson()), jsonEncode(s.toJson()));
    });

    test('hr == 0 (off-skin) for the latest epoch: offWrist', () {
      final s = warm(t);
      final w = windowOf(night, t, t + 60);
      final off = CausalSampleWindow(
        nowMs: w.nowMs,
        hr: [for (final h in w.hr) HrSample(h.tsMs, 0)],
        accel: w.accel,
        rr: w.rr,
      );
      expectAbsent(CausalStager.observe(off, s), CausalAbstention.offWrist);
    });

    test('no HR at all in the latest epoch: missingHr', () {
      final s = warm(t);
      final w = windowOf(night, t, t + 60, hrOn: false);
      expectAbsent(CausalStager.observe(w, s), CausalAbstention.missingHr);
    });

    test('non-finite HR is missing, not a value', () {
      final s = warm(t);
      final w = windowOf(night, t, t + 60);
      final nan = CausalSampleWindow(
        nowMs: w.nowMs,
        hr: [for (final h in w.hr) HrSample(h.tsMs, double.nan)],
        accel: w.accel,
        rr: w.rr,
      );
      expectAbsent(CausalStager.observe(nan, s), CausalAbstention.missingHr);
    });

    test('no accel in the latest epoch: missingAccel', () {
      final s = warm(t);
      final w = windowOf(night, t, t + 60, accelOn: false);
      expectAbsent(CausalStager.observe(w, s), CausalAbstention.missingAccel);
    });

    test('accel flagged invalid: missingAccel', () {
      final s = warm(t);
      final w = windowOf(night, t, t + 60);
      final inv = CausalSampleWindow(
        nowMs: w.nowMs,
        hr: w.hr,
        accel: [
          for (final a in w.accel)
            AccelSample(a.tsMs, a.x, a.y, a.z, valid: false)
        ],
        rr: w.rr,
      );
      expectAbsent(CausalStager.observe(inv, s), CausalAbstention.missingAccel);
    });

    test('too few HR seconds in the epoch: lowCoverage', () {
      final s = warm(t);
      final w = windowOf(night, t, t + 60);
      final sparse = CausalSampleWindow(
        nowMs: w.nowMs,
        hr: [
          for (var i = 0; i < w.hr.length; i++)
            if (i % 30 < 4) w.hr[i] // 4 of every 30 seconds
        ],
        accel: w.accel,
        rr: w.rr,
      );
      expectAbsent(
          CausalStager.observe(sparse, s), CausalAbstention.lowCoverage);
    });

    test('too few accel seconds in the epoch: lowCoverage', () {
      final s = warm(t);
      final w = windowOf(night, t, t + 60);
      final sparse = CausalSampleWindow(
        nowMs: w.nowMs,
        hr: w.hr,
        accel: [
          for (var i = 0; i < w.accel.length; i++)
            if (i % 30 < 4) w.accel[i]
        ],
        rr: w.rr,
      );
      expectAbsent(
          CausalStager.observe(sparse, s), CausalAbstention.lowCoverage);
    });

    test('a staged stream recovers after a gap and does not carry old labels',
        () {
      final s = warm(t);
      // 3 minutes of nothing (strap off the charger, say), then data again
      final gapEnd = t + 180;
      final resumed = CausalStager.observe(
          windowOf(night, gapEnd, gapEnd + 60), s);
      // the first closed epoch after the gap is fine; the point is that during
      // the gap itself the answer was absent
      final during = CausalStager.observe(
          CausalSampleWindow(
              nowMs: night.t0Ms + (t + 150) * 1000.0,
              hr: const [],
              accel: const []),
          s);
      expectAbsent(during, CausalAbstention.staleEvidence);
      expect(resumed.stage, isNot(CausalStage.absent));
    });

    test('a stream with no usable HR never produces a stage', () {
      CausalStagerState? state;
      for (var s = 30; s <= 60 * 60; s += 30) {
        final w = windowOf(night, s - 30, s);
        final blind = CausalSampleWindow(
          nowMs: w.nowMs,
          hr: [for (final h in w.hr) HrSample(h.tsMs, double.nan)],
          accel: w.accel,
          rr: w.rr,
        );
        final o = CausalStager.observe(blind, state);
        expect(o.stage, CausalStage.absent, reason: 'second $s');
        expect(o.abstentionReason, isNotNull);
        state = o.nextState;
      }
    });

    test('invariants: absent <=> reason; present ⇒ confidence in (0, 0.6]', () {
      for (final o in stream(night, 100 * 60)) {
        if (o.stage == CausalStage.absent) {
          expect(o.abstentionReason, isNotNull);
          expect(o.confidence, 0);
          expect(o.runSec, 0);
        } else {
          expect(o.abstentionReason, isNull);
          expect(o.confidence, inExclusiveRange(0, 0.6 + 1e-12));
          expect(o.runSec, greaterThan(0));
          expect(o.epochStartMs, isNotNull);
          expect(o.evidenceAgeMs, isNotNull);
        }
      }
    });
  });

  group('warm-up', () {
    test('abstains with an exact have/need count, then stages', () {
      final need = CausalStagerConfig.defaults.warmupEpochs;
      final obs = stream(night, (need + 6) * 30);
      // After k calls, k epochs are closed (the stream starts epoch-aligned).
      for (var k = 1; k <= need + 6; k++) {
        final o = obs[k - 1];
        if (k < need) {
          expectAbsent(o, CausalAbstention.warmup);
          expect(o.note, 'warmup:have=$k,need=$need');
        } else {
          expect(o.stage, isNot(CausalStage.absent), reason: 'k=$k');
          expect(o.note, isNull);
        }
      }
    });

    test('a thin start does not count epochs that were never usable', () {
      // 10 min of off-skin first: none of it may count toward warm-up.
      final need = CausalStagerConfig.defaults.warmupEpochs;
      CausalStagerState? s;
      for (var t = 30; t <= 600; t += 30) {
        final w = windowOf(night, t - 30, t);
        final off = CausalSampleWindow(
          nowMs: w.nowMs,
          hr: [for (final h in w.hr) HrSample(h.tsMs, 0)],
          accel: w.accel,
          rr: w.rr,
        );
        s = CausalStager.observe(off, s).nextState;
      }
      final o = CausalStager.observe(windowOf(night, 600, 630), s);
      expectAbsent(o, CausalAbstention.warmup);
      expect(o.note, 'warmup:have=1,need=$need');
    });
  });

  group('behaviour on separable regimes', () {
    late List<CausalStageObservation> obs;
    setUpAll(() => obs = stream(night, night.seconds));

    // Ground truth for the epoch an observation describes.
    String truthOf(CausalStageObservation o) {
      final sec = ((o.epochStartMs! - night.t0Ms) / 1000).round();
      // majority regime across the 30 s epoch
      final c = <String, int>{};
      for (var i = sec; i < sec + 30; i++) {
        c[night.truth[i]] = (c[night.truth[i]] ?? 0) + 1;
      }
      return c.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
    }

    test('REM is called inside REM blocks, mostly after the first minutes', () {
      final inRem = obs.where((o) =>
          o.stage != CausalStage.absent && truthOf(o) == 'rem').toList();
      expect(inRem.length, greaterThan(20));
      final hit = inRem.where((o) => o.stage == CausalStage.rem).length;
      expect(hit / inRem.length, greaterThan(0.6));
    });

    test('NREM time is not called wake', () {
      final inN = obs.where((o) =>
          o.stage != CausalStage.absent && truthOf(o) == 'nrem').toList();
      final wake = inN.where((o) => o.stage == CausalStage.wake).length;
      expect(wake / inN.length, lessThan(0.05));
    });

    // The REM "wake now" rule a caller would build: REM that has persisted for
    // at least the shortest credible REM bout (remEpisodeMinMin = 5 min).
    bool stableRem(CausalStageObservation o) =>
        o.stage == CausalStage.rem && o.runSec >= remEpisodeMinMin * 60;

    // [lo, hi) minute spans of the REM blocks in standardNight().
    const remBlocks = [(35, 47), (123, 138)];
    double minOf(CausalStageObservation o) =>
        (o.epochStartMs! - night.t0Ms) / 60000.0;

    test('every REM block raises a stable-REM candidate inside the block, '
        'within 8 min of onset', () {
      for (final (lo, hi) in remBlocks) {
        final first = obs
            .where((o) => stableRem(o) && minOf(o) >= lo && minOf(o) < hi)
            .map(minOf)
            .toList();
        expect(first, isNotEmpty, reason: 'REM block $lo-$hi min missed');
        expect(first.first - lo, lessThanOrEqualTo(8));
      }
    });

    test('stable-REM candidates far from any REM block are rare', () {
      // "far" = more than 6 min after a block ended (trailing windows keep the
      // tail of REM variability in view for a few minutes — the lag the doc
      // states) and not inside one.
      bool far(double m) => remBlocks.every((b) => m < b.$1 || m >= b.$2 + 6);
      final farEpochs = obs
          .where((o) => o.stage != CausalStage.absent && far(minOf(o)))
          .toList();
      final falseTrig = farEpochs.where(stableRem).length;
      expect(falseTrig / farEpochs.length, lessThan(0.06));
    });

    test('a motion/HR wake block is called wake', () {
      final inW = obs.where((o) =>
          o.stage != CausalStage.absent && truthOf(o) == 'wake').toList();
      expect(inW, isNotEmpty);
      final hit = inW.where((o) => o.stage == CausalStage.wake).length;
      expect(hit / inW.length, greaterThan(0.6));
    });

    test('runSec counts how long the stage has persisted, in whole epochs', () {
      var prev = CausalStage.absent;
      var prevRun = 0.0;
      for (final o in obs) {
        if (o.stage == CausalStage.absent) {
          prev = CausalStage.absent;
          prevRun = 0;
          continue;
        }
        expect(o.runSec % 30, 0);
        if (o.stage == prev) {
          expect(o.runSec, prevRun + 30);
        } else {
          expect(o.runSec, 30);
        }
        prev = o.stage;
        prevRun = o.runSec;
      }
    });

    test('evidence age is small for a live feed', () {
      for (final o in obs.where((o) => o.stage != CausalStage.absent)) {
        expect(o.evidenceAgeMs, lessThanOrEqualTo(2000));
      }
    });
  });

  group('shared building blocks (extracted from cardioStager, unchanged)', () {
    test('weightedAxisScore: weighted mean over measurable axes only', () {
      expect(weightedAxisScore([(1.0, 0.5), (null, 0.3), (double.nan, 0.2)]),
          1.0);
      expect(weightedAxisScore([(2.0, 0.5), (-1.0, 0.5)]), 0.5);
      expect(weightedAxisScore([(null, 0.5)]), isNull);
      expect(weightedAxisScore([(1.0, -0.5), (3.0, 0.5)]), 1.0,
          reason: 'a negative weight flips the axis; the denominator is |w|');
    });

    test('cleanRrBeatsBetween is the same gate as the centred-window gather',
        () {
      final accel = <AccelSample>[
        for (var i = 0; i < 30; i++) AccelSample(i * 1000.0, 0, 0, 1)
      ];
      final ts = <double>[9000, 10000, 10000, 15000, 20000, 20000, 21000];
      final rr = <double>[900, 910, 5000, 920, 930, 240, 940]; // 5000/240 gated
      final centred =
          cleanBeatsInWindowForTest(rr, ts, accel, 0, 30, halfWinMs: 5000);
      final direct = cleanRrBeatsBetween(rr, ts, 10000, 20000);
      expect(direct.beats, centred);
      expect(direct.tsSec.first, 0, reason: 'rebased to the window start');
    });

    test('REM weights are the shipped effect sizes', () {
      expect(
          [kRemWeightRk, kRemWeightSdnn, kRemWeightHrSd, kRemWeightLfhf],
          [0.43, 0.32, 0.27, 0.12]);
    });
  });

  group('state', () {
    test('is plain JSON data', () {
      final s = stream(night, 60 * 60).last.nextState;
      final j = s.toJson();
      expect(jsonDecode(jsonEncode(j)), j);
    });

    test('is bounded no matter how long the stream runs', () {
      final long = synthNight([('nrem', 7 * 3600)], seed: 5);
      final s = stream(long, long.seconds, stepSec: 600).last.nextState;
      final j = s.toJson();
      final cfg = CausalStagerConfig.defaults;
      expect((j['rows'] as List).length, lessThanOrEqualTo(cfg.historyEpochs));
      expect((j['hr'] as List).length, lessThanOrEqualTo(1000));
      expect((j['accel'] as List).length, lessThanOrEqualTo(1000));
    });

    test('a round-trip is the identity', () {
      final s = stream(night, 45 * 60).last.nextState;
      final back = CausalStagerState.fromJson(
          jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>);
      expect(jsonEncode(back!.toJson()), jsonEncode(s.toJson()));
    });

    test('garbage and unknown versions are rejected (null), not guessed at', () {
      final j = stream(night, 45 * 60).last.nextState.toJson();
      expect(CausalStagerState.fromJson(<String, dynamic>{}), isNull);
      expect(CausalStagerState.fromJson({...j, 'v': 999}), isNull);
      expect(CausalStagerState.fromJson({...j, 'rows': 'nope'}), isNull);
      expect(CausalStagerState.fromJson({...j, 'hr': [1, 2, 3]}), isNull);
    });

    test('an old state with a different config keeps its own config', () {
      const cfg = CausalStagerConfig(warmupEpochs: 10);
      final s0 = CausalStagerState.initial(cfg);
      final o = CausalStager.observe(windowOf(night, 0, 30), s0);
      expect(o.note, 'warmup:have=1,need=10');
    });
  });
}
