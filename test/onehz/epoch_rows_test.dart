// The gap-anchored 30 s epoch grid and its `EpochRows` accumulator (combined
// bump, chunk B1-B3; owner decision 2026-10-22: anchor at the first sample after
// each data gap, replacing the wall-clock grid).
//
//   B1  Epochs are 30,000 ms steps from the FIRST sample of each gap-free run
//       (valid accelerometer coverage, with the stager's usable-run gap: the
//       60 s carry-forward). A run starts at the first sample and again at the
//       first sample after any gap longer than that. The anchor depends on the
//       data only, never on session detection, and is final as soon as the
//       run's first sample arrives. An epoch is clipped only by a data gap: an
//       epoch the data covers is a row (computed on the seconds that exist);
//       an epoch with no data is not a row.
//   B2  `EpochRows` (lookback +-165 s accel / HR, +-150 s RR) emits per-epoch
//       feature rows. Chunk invariance is EXACT (any chunking, with JSON
//       save/restore between chunks); rows ~3 min behind the newest sample are
//       FINAL and never change; the last few are provisional; checkpointable.
//       On an aligned contiguous stream the interior rows are today's
//       `cardioEpochFeatures` rows (LF/HF excepted, see below).
//   B3  Staging from the accumulated rows (`EpochRows.stageWindow`) equals
//       `AdvancedSleepStager.stageWindow` in one batch, exactly, and that
//       hypnogram's boundaries sit on the run's 30 s grid, whatever the session
//       bounds.
//
// LF/HF is compared for presence only against today's rows: the span-dependent
// frequency grid (cardio_stager.dart `remFeaturesFromBeats`) may be fixed in
// the same bump, which moves the value but not whether it exists.
import 'dart:convert';

import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

import '../support/property.dart';
import 'support/causal_night.dart';
import 'support/pre_bump_stager.dart';

const _alignedT0 = 1700000010000; // = kT0Ms, a multiple of 30,000

/// A night as raw input, optionally with holes (both streams lose the same
/// seconds, and the beats in them).
class _Input {
  final int t0Ms, seconds;
  final List<HrSample> hr;
  final List<AccelSample> accel;
  final List<double> rrMs, rrTs;
  _Input(this.t0Ms, this.seconds, this.hr, this.accel, this.rrMs, this.rrTs);

  factory _Input.make(List<(String, int)> segs,
      {int seed = 11, int t0Ms = _alignedT0, List<(int, int)> gaps = const []}) {
    final n = synthNight(segs, seed: seed, t0Ms: t0Ms.toDouble());
    bool inGap(double ts) => gaps.any((g) =>
        ts >= t0Ms + g.$1 * 1000.0 && ts < t0Ms + g.$2 * 1000.0);
    final rr = <double>[], rt = <double>[];
    for (var i = 0; i < n.rrMs.length; i++) {
      if (!inGap(n.rrTsMs[i])) {
        rr.add(n.rrMs[i]);
        rt.add(n.rrTsMs[i]);
      }
    }
    return _Input(t0Ms, n.seconds, [for (final h in n.hr) if (!inGap(h.tsMs)) h],
        [for (final a in n.accel) if (!inGap(a.tsMs)) a], rr, rt);
  }

  /// Samples with `loSec <= second < hiSec` (seconds since t0).
  void foldInto(EpochRows er, int loSec, int hiSec) {
    final lo = t0Ms + loSec * 1000.0, hi = t0Ms + hiSec * 1000.0;
    bool inside(double t) => t >= lo && t < hi;
    final ri = [
      for (var i = 0; i < rrTs.length; i++)
        if (inside(rrTs[i])) i
    ];
    er.fold(
      hr: [for (final h in hr) if (inside(h.tsMs)) h],
      accel: [for (final a in accel) if (inside(a.tsMs)) a],
      rrMs: [for (final i in ri) rrMs[i]],
      rrTsMs: [for (final i in ri) rrTs[i]],
    );
  }

  List<GravTs> get grav => [
        for (final a in accel) GravTs(a.tsMs ~/ 1000, a.x, a.y, a.z)
      ];
  List<HrTs> get hrTs => [for (final h in hr) HrTs(h.tsMs ~/ 1000, h.hr)];
  List<RrTs> get rrTsSec =>
      [for (var i = 0; i < rrMs.length; i++) RrTs(rrTs[i] ~/ 1000, rrMs[i])];
}

EpochRows _oneFold(_Input s) {
  final er = EpochRows();
  s.foldInto(er, 0, s.seconds);
  return er;
}

/// Folds [s] in chunks cut at [cuts] (seconds, ascending; empty chunks allowed),
/// saving to JSON TEXT and restoring between chunks when [restart].
EpochRows _chunked(_Input s, List<int> cuts, {bool restart = false}) {
  var er = EpochRows();
  var at = 0;
  for (final c in [...cuts, s.seconds]) {
    s.foldInto(er, at, c);
    at = c;
    if (restart) {
      er = EpochRows.fromJson(jsonDecode(jsonEncode(er.toJson())) as Map<String, dynamic>);
    }
  }
  return er;
}

List<int> _cuts(Rng r, int seconds) {
  const sizes = [1, 2, 7, 30, 31, 59, 100, 171, 500];
  final out = <int>[];
  var at = 0;
  while (true) {
    at += r.nextBool(.15) ? 0 : 1 + r.nextInt(sizes[r.nextInt(sizes.length)]);
    if (at >= seconds) return out;
    out.add(at);
  }
}

bool _sameRow(EpochFeatureRow a, EpochFeatureRow b) =>
    a.startMs == b.startMs &&
    [
      [a.motion, b.motion], [a.hr, b.hr], [a.hrSd, b.hrSd],
      [a.rmssd, b.rmssd], [a.lfhf, b.lfhf], [a.rk, b.rk], [a.sdnn, b.sdnn],
    ].every((p) => p[0].compareTo(p[1]) == 0);

void _expectSameRows(List<EpochFeatureRow> got, List<EpochFeatureRow> want, String why) {
  expect(got.length, want.length, reason: '$why: row count');
  for (var i = 0; i < got.length; i++) {
    if (!_sameRow(got[i], want[i])) {
      fail('$why: row $i (start ${want[i].startMs}) differs: '
          'got ${_show(got[i])} want ${_show(want[i])}');
    }
  }
}

String _show(EpochFeatureRow r) =>
    '[${r.startMs} motion ${r.motion} hr ${r.hr} hrSd ${r.hrSd} rmssd ${r.rmssd} '
    'lfhf ${r.lfhf} rk ${r.rk} sdnn ${r.sdnn}]';

List<(String, int)> _night() => [
      ('nrem', 900), ('rem', 600), ('nrem', 900), ('wake', 300), ('nrem', 300),
    ];

void main() {
  group('B1: the gap-anchored grid', () {
    test('kEpochMs is 30,000 ms', () => expect(kEpochMs, 30000));

    test('no data: no runs, no epoch', () {
      final er = EpochRows();
      expect(er.runAnchorsMs, isEmpty);
      expect(er.epochStartMsFor(_alignedT0), isNull);
    });

    for (final offsetMs in [0, 13000, 29000, 13250]) {
      test('data starting ${offsetMs} ms past a Unix boundary: epochs are 30 s '
          'steps from the first sample, every covered epoch is a row', () {
        final s = _Input.make([('nrem', 700), ('wake', 140)], t0Ms: _alignedT0 + offsetMs);
        final er = _oneFold(s);
        expect(er.runAnchorsMs, [s.t0Ms]);
        final rows = er.allRows();
        expect(rows, isNotEmpty);
        expect(rows.first.startMs, s.t0Ms, reason: 'the first sample opens the grid');
        for (final r in rows) {
          expect((r.startMs - s.t0Ms) % kEpochMs, 0, reason: 'start ${r.startMs}');
        }
        for (var i = 1; i < rows.length; i++) {
          expect(rows[i].startMs - rows[i - 1].startMs, kEpochMs,
              reason: 'contiguous data: no epoch skipped or repeated');
        }
        final lastEnd = s.t0Ms + s.seconds * 1000;
        expect(rows.last.startMs + kEpochMs,
            inInclusiveRange(lastEnd, lastEnd + kEpochMs),
            reason: 'the epoch holding the last sample is the last row');
        // the per-timestamp lookup agrees with the rows
        for (final r in rows) {
          expect(er.epochStartMsFor(r.startMs), r.startMs);
          expect(er.epochStartMsFor(r.startMs + kEpochMs - 1), r.startMs);
        }
        expect(er.epochStartMsFor(s.t0Ms - 1), isNull, reason: 'before the data');
      });
    }

    test('the anchor is final as soon as the first sample arrives', () {
      final s = _Input.make([('nrem', 900)], t0Ms: _alignedT0 + 13250);
      final er = EpochRows();
      s.foldInto(er, 0, 5);
      expect(er.runAnchorsMs, [s.t0Ms]);
      s.foldInto(er, 5, 400);
      s.foldInto(er, 400, s.seconds);
      expect(er.runAnchorsMs, [s.t0Ms], reason: 'later data never moves it');
      // and it does not depend on a session: nothing has been asked of the rows
      expect(er.allRows().first.startMs, s.t0Ms);
    });

    test('a gap longer than the usable-run gap re-anchors at the first sample '
        'after it; a shorter one does not', () {
      // next valid accel at +61 s after the last: the carry bridges it (one run);
      // at +62 s it does not (second run). Same threshold as the stager's
      // usable-run split.
      for (final (holeSec, runs) in [(60, 1), (61, 2), (100, 2), (600, 2)]) {
        // a hole of `holeSec` missing seconds after +599 (both streams)
        final s = _Input.make([('nrem', 1500)],
            gaps: [(600, 600 + holeSec)], seed: 17, t0Ms: _alignedT0 + 13000);
        final er = _oneFold(s);
        expect(er.runAnchorsMs.length, runs, reason: 'hole $holeSec s');
        if (runs == 2) {
          expect(er.runAnchorsMs.last, s.t0Ms + (600 + holeSec) * 1000);
          // the new grid steps from the new anchor, not the old one
          final starts = er.allRows().map((r) => r.startMs).toSet();
          expect(starts.contains(s.t0Ms + (600 + holeSec) * 1000), isTrue);
          if ((holeSec) % 30 != 0) {
            expect(starts.contains(s.t0Ms + (630 + (holeSec ~/ 30) * 30) * 1000),
                isFalse, reason: 'the old phase is gone after the gap');
          }
        } else {
          for (final r in er.allRows()) {
            expect((r.startMs - s.t0Ms) % kEpochMs, 0);
          }
        }
      }
    });

    test('gap-only clipping: an epoch inside a gap is not a row, an epoch the '
        'gap only nibbles still is (on the seconds that exist)', () {
      // gap A: 117 s (a new run, anchored at +417); gap B: 10 s in the middle
      // of one epoch (bridged). Offsets are seconds since t0.
      final s = _Input.make([('nrem', 1500)],
          gaps: [(300, 417), (810, 820)], seed: 17);
      final er = _oneFold(s);
      expect(er.runAnchorsMs, [s.t0Ms, s.t0Ms + 417000]);
      final byStart = {for (final r in er.allRows()) r.startMs: r};
      // the first run's grid ends with its coverage (last sample + the carry)
      for (var e = 360; e < 417; e += 1) {
        expect(byStart.containsKey(s.t0Ms + e * 1000), isFalse,
            reason: 'second +${e}s lies in the gap, no epoch starts there');
      }
      for (final e in [270, 417, 447, 777, 837]) {
        expect(byStart.containsKey(s.t0Ms + e * 1000), isTrue,
            reason: 'epoch at +${e}s has data');
      }
      final nibbled = byStart[s.t0Ms + 807 * 1000]!; // 417 + 13 * 30 = 807
      final present = [
        for (final h in s.hr)
          if (h.tsMs >= s.t0Ms + 807000 && h.tsMs < s.t0Ms + 837000 && h.valid)
            h.hr
      ];
      expect(present.length, 20);
      expect(nibbled.hr, closeTo(present.reduce((a, b) => a + b) / present.length, 1e-9),
          reason: 'mean HR of the 20 seconds that exist');
    });

    test('nothing is trimmed to a "session": the first and last wake epochs of a '
        'night are rows', () {
      final s = _Input.make([('wake', 300), ('nrem', 600), ('wake', 300)]);
      final rows = _oneFold(s).allRows();
      expect(rows.first.startMs, _alignedT0);
      expect(rows.last.startMs, _alignedT0 + 1200 * 1000 - kEpochMs);
    });

    test('a run that continues data folded earlier (seeded anchor) keeps the '
        'earlier grid', () {
      final s = _Input.make([('nrem', 2400)], t0Ms: _alignedT0 + 13250);
      final full = _oneFold(s);
      // fold only the part from +400 s on, telling the accumulator that the run
      // it joins was anchored at the true first sample
      final part = EpochRows(continuingAnchorMs: s.t0Ms);
      s.foldInto(part, 400, s.seconds);
      expect(part.runAnchorsMs, [s.t0Ms]);
      final starts = part.allRows().map((r) => r.startMs).toList();
      expect(starts, isNotEmpty);
      for (final st in starts) {
        expect((st - s.t0Ms) % kEpochMs, 0);
      }
      // rows well inside the fed part are the full-night rows
      final want = {for (final r in full.allRows()) r.startMs: r};
      var same = 0;
      for (final r in part.allRows()) {
        if (r.startMs < s.t0Ms + 400000 + 200000) continue;
        expect(_sameRow(r, want[r.startMs]!), isTrue, reason: 'row ${r.startMs}');
        same++;
      }
      expect(same, greaterThan(50));
    });
  });

  group('B2: EpochRows', () {
    final night = _Input.make(_night(), t0Ms: _alignedT0 + 13000);
    late final whole = _oneFold(night).allRows();

    test('rows exist and are not all provisional', () {
      expect(whole.length, greaterThanOrEqualTo(100), reason: '3000 s, 30 s epochs');
      final er = _oneFold(night);
      expect(er.finalRows, isNotEmpty);
      expect(er.provisionalRows(), isNotEmpty);
      expect(er.finalRows.length + er.provisionalRows().length, whole.length);
    });

    forAll('chunk invariance: any chunking (empty chunks, JSON restarts) = one fold',
        G.intIn(1, 100000), (seed) {
      final r = Rng(seed);
      final cuts = _cuts(r, night.seconds);
      final got = _chunked(night, cuts, restart: r.nextBool());
      _expectSameRows(got.allRows(), whole, 'cuts $cuts');
    }, cases: 12, budget: const Duration(seconds: 120));

    test('one-second chunks give the same rows', () {
      final s = _Input.make([('nrem', 600), ('wake', 120)], t0Ms: _alignedT0 + 7000);
      final want = _oneFold(s).allRows();
      final er = EpochRows();
      for (var t = 0; t < s.seconds; t++) {
        s.foldInto(er, t, t + 1);
      }
      _expectSameRows(er.allRows(), want, '1 s chunks');
    });

    test('rows ~3 min behind the newest sample are final and never change; the '
        'last few are provisional', () {
      final er = EpochRows();
      var prevFinal = 0;
      var at = 0;
      for (final c in [..._cuts(Rng(5), night.seconds), night.seconds]) {
        night.foldInto(er, at, c);
        at = c;
        final fin = er.finalRows;
        // never retracted, never rewritten: a prefix of the full-night rows
        expect(fin.length, greaterThanOrEqualTo(prevFinal));
        _expectSameRows(fin, whole.sublist(0, fin.length), 'final rows at +${c}s');
        prevFinal = fin.length;
        // liveness: everything 4+ min behind the newest sample is final
        final newest = er.newestMs!;
        final settledBy = whole.where((r) => r.startMs <= newest - 240000).length;
        expect(fin.length, greaterThanOrEqualTo(settledBy),
            reason: 'rows 4 min behind the newest sample must be final (at +${c}s)');
        // the provisional rows continue the final ones, and are few
        final prov = er.provisionalRows();
        expect(prov.length, lessThanOrEqualTo(14));
        if (fin.isNotEmpty && prov.isNotEmpty) {
          expect(prov.first.startMs, fin.last.startMs + kEpochMs);
        }
        expect(er.allRows().length, fin.length + prov.length);
      }
      expect(er.newestMs, night.t0Ms + (night.seconds - 1) * 1000);
    });

    test('provisional rows match a fold of the data so far, clipped at its end', () {
      final cut = 1500;
      final er = EpochRows();
      night.foldInto(er, 0, cut);
      final prefixOnly = _Input.make(_night(), t0Ms: _alignedT0 + 13000);
      final fresh = EpochRows();
      prefixOnly.foldInto(fresh, 0, cut);
      _expectSameRows(er.allRows(), fresh.allRows(), 'same prefix, same rows');
      // asking does not change anything
      final before = jsonEncode(er.toJson());
      er.provisionalRows();
      er.allRows();
      expect(jsonEncode(er.toJson()), before);
    });

    test('checkpoint: toJson -> JSON text -> fromJson is lossless and resumes', () {
      final er = EpochRows();
      night.foldInto(er, 0, 1700);
      final text = jsonEncode(er.toJson());
      final back = EpochRows.fromJson(jsonDecode(text) as Map<String, dynamic>);
      expect(jsonEncode(back.toJson()), text);
      _expectSameRows(back.allRows(), er.allRows(), 'restored');
      night.foldInto(back, 1700, night.seconds);
      _expectSameRows(back.allRows(), whole, 'resumed');
    });

    test('an empty accumulator checkpoints and resumes', () {
      final back = EpochRows.fromJson(
          jsonDecode(jsonEncode(EpochRows().toJson())) as Map<String, dynamic>);
      expect(back.allRows(), isEmpty);
      expect(back.newestMs, isNull);
      night.foldInto(back, 0, night.seconds);
      _expectSameRows(back.allRows(), whole, 'from an empty checkpoint');
    });

    test('a checkpoint of another type, version or shape is refused', () {
      final er = EpochRows();
      night.foldInto(er, 0, 400);
      final good = jsonDecode(jsonEncode(er.toJson())) as Map<String, dynamic>;
      for (final bad in <Map<String, dynamic>>[
        {...good, 'type': 'RrCorrector'},
        {...good, 'version': 999},
        {...good}..remove('type'),
        {'type': good['type'], 'version': good['version']},
        <String, dynamic>{},
      ]) {
        expect(() => EpochRows.fromJson(bad), throwsA(isA<FormatException>()),
            reason: jsonEncode(bad));
      }
    });

    test('checkpoints written before 81b9b4b (versions 1-3) are refused', () {
      final er = EpochRows();
      night.foldInto(er, 0, 1000);
      final good = jsonDecode(jsonEncode(er.toJson())) as Map<String, dynamic>;
      expect(good['version'], 4, reason: 'row semantics changed: new version');
      for (final v in [1, 2, 3]) {
        // Finalized rows carry the old (wrong) values; the shape is otherwise
        // what version 3 wrote.
        final bad = {...good, 'version': v};
        expect(() => EpochRows.fromJson(bad), throwsA(isA<FormatException>()),
            reason: 'version $v');
      }
    });

    test('on an aligned contiguous stream the interior rows are today\'s '
        'cardioEpochFeatures rows', () {
      final s = _Input.make(_night()); // aligned t0
      final rows = {for (final r in _oneFold(s).allRows()) r.startMs: r};
      final f = cardioEpochFeatures(
        [for (final h in s.hr) h.hr],
        s.accel,
        rrMs: s.rrMs,
        rrTsMs: s.rrTs,
      );
      var compared = 0;
      for (var e = 0; e < f.length; e++) {
        final startSec = e * 30;
        if (startSec < 165 || startSec + 30 + 165 > s.seconds) continue;
        final r = rows[_alignedT0 + startSec * 1000];
        expect(r, isNotNull, reason: 'row for epoch $e');
        bool same(double a, double b) => a.compareTo(b) == 0;
        expect(same(r!.motion, f.motion[e]), isTrue, reason: 'motion e=$e ${r.motion} vs ${f.motion[e]}');
        expect(same(r.hr, f.hr[e]), isTrue, reason: 'hr e=$e');
        expect(same(r.hrSd, f.hrSd[e]), isTrue, reason: 'hrSd e=$e');
        expect(same(r.rmssd, f.rmssd[e]), isTrue, reason: 'rmssd e=$e');
        expect(same(r.sdnn, f.sdnn[e]), isTrue, reason: 'sdnn e=$e');
        expect(same(r.rk, f.rk[e]), isTrue, reason: 'rk e=$e');
        expect(r.lfhf.isNaN, f.lfhf[e].isNaN, reason: 'lfhf presence e=$e');
        compared++;
      }
      expect(compared, greaterThan(80));
    });
  });

  group('B3: staging on the gap-anchored grid', () {
    SleepSession batch(_Input s, [int fromSec = 0, int? toSec]) =>
        AdvancedSleepStager.stageWindow(s.t0Ms ~/ 1000 + fromSec,
            s.t0Ms ~/ 1000 + (toSec ?? s.seconds), s.grav, s.hrTs, rr: s.rrTsSec);

    String show(List<StageSegment> l) => jsonEncode([for (final g in l) g.toJson()]);

    for (final (name, offsetMs, gaps) in [
      ('unaligned start, no gaps', 13000, <(int, int)>[]),
      ('aligned start', 0, <(int, int)>[]),
      ('unaligned start, a 100 s hole in accel and HR', 13000, [(1300, 1400)]),
    ]) {
      test('staging from accumulated rows = one batch, exactly ($name)', () {
        final s = _Input.make(_night(), t0Ms: _alignedT0 + offsetMs, gaps: gaps, seed: 29);
        final want = batch(s).stages;
        final r = Rng(offsetMs + gaps.length);
        final er = _chunked(s, _cuts(r, s.seconds), restart: true);
        final got = er.stageWindow(s.t0Ms ~/ 1000, s.t0Ms ~/ 1000 + s.seconds);
        expect(show(got), show(want));
      });
    }

    test('a session that begins inside a gap-free run is staged on ITS OWN '
        'start (grid option 2: phase 0 at the session start, as pre-bump)', () {
      // Replaces the gap-anchored expectation (owner decision 2026-10-23): the
      // run\'s grid no longer decides where a session\'s epochs sit.
      final s = _Input.make(_night(), t0Ms: _alignedT0 + 13000, seed: 37);
      for (final (from, to) in [(1000, 2400), (777, 2111), (1234, 2999)]) {
        final t0 = s.t0Ms ~/ 1000;
        final got = batch(s, from, to).stages;
        var checked = 0;
        for (var i = 1; i < got.length; i++) {
          if (got[i].stage == 'unobserved' || got[i - 1].stage == 'unobserved') {
            continue;
          }
          expect((got[i].start - (t0 + from)) % 30, 0,
              reason: 'session +$from..+${to}s: boundary ${got[i].start}');
          checked++;
        }
        // +777..+2111 has two boundaries in the pre-bump labels too.
        expect(checked, greaterThan(1), reason: 'session +$from..+${to}s');
        expect(show(got),
            show(preBumpStageSessionCardio(t0 + from, t0 + to, s.grav, s.hrTs, s.rrTsSec)),
            reason: 'session +$from..+${to}s equals the pre-bump labels');
      }
    });

    test('the hypnogram\'s boundaries sit on the 30 s grid of the first sample', () {
      for (final offsetMs in [13000, 21000]) {
        final s = _Input.make(_night(), t0Ms: _alignedT0 + offsetMs, seed: 31);
        final st = batch(s);
        final stages = st.stages;
        expect(stages.first.start, st.start);
        expect(stages.last.end, st.end);
        for (var i = 1; i < stages.length; i++) {
          expect(stages[i].start, stages[i - 1].end, reason: 'tiles without holes');
        }
        var checked = 0;
        for (var i = 1; i < stages.length; i++) {
          final edge = stages[i].start;
          if (stages[i].stage == 'unobserved' || stages[i - 1].stage == 'unobserved') {
            continue;
          }
          expect((edge - s.t0Ms ~/ 1000) % 30, 0,
              reason: 'boundary at $edge (${stages[i - 1].stage} -> '
                  '${stages[i].stage}), data starts at +${offsetMs ~/ 1000}s');
          checked++;
        }
        expect(checked, greaterThan(2), reason: 'the night must change stage');
      }
    });

    test('a hole shorter than the carry-forward does not move the grid', () {
      final s = _Input.make(_night(),
          t0Ms: _alignedT0 + 13000, gaps: [(1000, 1040)], seed: 33);
      final stages = batch(s).stages;
      for (var i = 1; i < stages.length; i++) {
        if (stages[i].stage == 'unobserved' || stages[i - 1].stage == 'unobserved') {
          continue;
        }
        expect((stages[i].start - s.t0Ms ~/ 1000) % 30, 0,
            reason: 'boundary ${stages[i].start}');
      }
    });

    test('a hole longer than the carry-forward re-anchors the grid after it', () {
      // 1100 % 30 = 20: the second run's grid is 20 s out of phase with the first
      final s = _Input.make(_night(),
          t0Ms: _alignedT0 + 13000, gaps: [(1000, 1100)], seed: 35);
      final t0 = s.t0Ms ~/ 1000;
      final stages = batch(s).stages;
      var before = 0, after = 0;
      for (var i = 1; i < stages.length; i++) {
        if (stages[i].stage == 'unobserved' || stages[i - 1].stage == 'unobserved') {
          continue;
        }
        final edge = stages[i].start - t0;
        if (edge < 1000) {
          expect(edge % 30, 0, reason: 'first run, boundary at +$edge');
          before++;
        } else {
          expect((edge - 1100) % 30, 0, reason: 'second run, boundary at +$edge');
          after++;
        }
      }
      expect(before, greaterThan(0));
      expect(after, greaterThan(0));
    });
  });
}
