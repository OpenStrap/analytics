// Combined bump, grid option 2 (owner decision 2026-10-23): onset-anchored
// staging plus a phase-keyed epoch-row memo. RED until the implementation lands.
// Contract: edge.research/combined-bump/option2-brief.md.
//
// New API under test (everything else already exists):
//
//   EpochRows({CardioRowCache? rowCache, int? continuingAnchorMs,
//              int? anchorMs})
//     anchorMs: the first run's grid passes through this absolute time, rows are
//     anchorMs + k * kEpochMs. No row starts before anchorMs when it lies after
//     the first sample (earlier samples only serve as feature context); when it
//     lies before the first sample the first row is the epoch holding it. A run
//     that follows a data gap longer than the usable-run gap still re-anchors at
//     its first sample (this is what the pre-bump stager did; see
//     test/onehz/support/pre_bump_stager.dart).
//   int? EpochRows.phaseMs        anchor mod kEpochMs of the first run's grid
//                                 (null while no anchor/sample is known).
//   toJson()['phase']             the same value, carried in the checkpoint;
//                                 fromJson refuses a phase its rows contradict.
//
//   EpochRowsMemo({int maxPhases = 2, CardioRowCache? rowCache})
//     EpochRows rowsFor(int anchorMs, {hr, accel, rrMs, rrTsMs})
//         Rows for the phase anchorMs % kEpochMs. The lists are the CUMULATIVE
//         input from the start of the data (append-only between calls). A held
//         phase folds only the samples it has not consumed; an unheld phase is
//         built from scratch from the lists (exact recompute) and the least
//         recently used phase beyond maxPhases is dropped.
//     List<int> phases      held phases, least recently used first
//     int phaseBuilds       phases built from scratch (incl. rebuilds)
//     int samplesFolded     samples handed to EpochRows.fold, hr + accel + rr
//     toJson() / EpochRowsMemo.fromJson(map)   checkpoint; carries each held
//         phase's rows and how many cumulative samples it consumed. A restored
//         memo reuses a phase only when it is asked for the same phase.
import 'dart:convert';

import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

import '../support/property.dart';
import 'support/epoch_input.dart';

EpochRows _batch(EpochInput s, int anchorMs) {
  final er = EpochRows(anchorMs: anchorMs);
  s.foldInto(er, 0, s.seconds);
  return er;
}

EpochRows _chunked(EpochInput s, int anchorMs, List<int> cuts,
    {bool restart = false}) {
  var er = EpochRows(anchorMs: anchorMs);
  var at = 0;
  for (final c in [...cuts, s.seconds]) {
    s.foldInto(er, at, c);
    at = c;
    if (restart) {
      er = EpochRows.fromJson(
          jsonDecode(jsonEncode(er.toJson())) as Map<String, dynamic>);
    }
  }
  return er;
}

EpochRows _ask(EpochRowsMemo m, int anchorMs, EpochInput upTo) =>
    m.rowsFor(anchorMs,
        hr: upTo.hr, accel: upTo.accel, rrMs: upTo.rrMs, rrTsMs: upTo.rrTs);

void main() {
  final t0 = kAlignedT0Ms + 13000; // phase 13000
  final night = EpochInput.make(nightSegs(), t0Ms: t0, seed: 41);

  group('EpochRows(anchorMs:) puts rows on anchorMs + k * 30 s', () {
    for (final (name, a) in [
      ('before the first sample', t0 - 40000),
      ('at the first sample', t0),
      ('a few seconds in', t0 + 7000),
      ('777 s in (a detected onset)', t0 + 777000),
    ]) {
      test('anchor $name', () {
        final er = _batch(night, a);
        final rows = er.allRows();
        expect(rows, isNotEmpty);
        expect(er.phaseMs, a % kEpochMs);
        for (final r in rows) {
          expect((r.startMs - a) % kEpochMs, 0, reason: 'start ${r.startMs}');
        }
        for (var i = 1; i < rows.length; i++) {
          expect(rows[i].startMs - rows[i - 1].startMs, kEpochMs);
        }
        if (a >= t0) {
          expect(rows.first.startMs, a, reason: 'no row before the anchor');
        } else {
          expect(rows.first.startMs, lessThanOrEqualTo(t0));
          expect(rows.first.startMs + kEpochMs, greaterThan(t0),
              reason: 'the epoch holding the first sample opens the grid');
        }
        final lastEnd = t0 + night.seconds * 1000;
        expect(rows.last.startMs + kEpochMs,
            inInclusiveRange(lastEnd, lastEnd + kEpochMs));
      });
    }

    test('a different phase gives different row starts over the same samples',
        () {
      final a = _batch(night, t0 + 7000).allRows();
      final b = _batch(night, t0 + 19000).allRows();
      expect((a[3].startMs - b[3].startMs) % kEpochMs, isNot(0));
    });

    forAll('any chunking, with JSON restarts (even before the first sample), '
        'equals one fold on the same anchor', G.intIn(1, 100000), (seed) {
      final r = Rng(seed);
      final a = t0 + [0, 7000, 19000, 777000, -40000][r.nextInt(5)];
      final want = _batch(night, a).allRows();
      final cuts = randomCuts(r, night.seconds);
      final got = _chunked(night, a, cuts, restart: r.nextBool());
      expectSameRows(got.allRows(), want, 'anchor $a cuts $cuts');
    }, cases: 10, budget: const Duration(seconds: 120));

    test('an anchored checkpoint taken before any sample keeps the anchor', () {
      final a = t0 + 777000;
      final empty = EpochRows(anchorMs: a);
      final back = EpochRows.fromJson(
          jsonDecode(jsonEncode(empty.toJson())) as Map<String, dynamic>);
      night.foldInto(back, 0, night.seconds);
      expectSameRows(back.allRows(), _batch(night, a).allRows(),
          'resumed from an empty anchored checkpoint');
    });

    test('resumed mid-night from a checkpoint = batch on that anchor', () {
      final a = t0 + 7000;
      final er = EpochRows(anchorMs: a);
      night.foldInto(er, 0, 1700);
      final back = EpochRows.fromJson(
          jsonDecode(jsonEncode(er.toJson())) as Map<String, dynamic>);
      night.foldInto(back, 1700, night.seconds);
      expectSameRows(back.allRows(), _batch(night, a).allRows(), 'resumed');
    });

    test('after a gap longer than the usable-run gap the next sample re-anchors '
        '(pre-bump behaviour): the onset grid is NOT kept across the gap', () {
      // 100 s hole at +1300..+1400 s. Anchor +7 s; the second run starts at
      // +1400 s, 1393 s = 13 s (mod 30) past the onset grid.
      final s = EpochInput.make(nightSegs(),
          t0Ms: t0, gaps: [(1300, 1400)], seed: 43);
      final a = t0 + 7000;
      final er = _batch(s, a);
      final starts = er.allRows().map((r) => r.startMs).toList();
      for (final st in starts) {
        final rel = st - (t0 + 1400000);
        if (st < t0 + 1300000) {
          expect((st - a) % kEpochMs, 0, reason: 'first run on the onset grid');
        } else {
          expect(rel % kEpochMs, 0, reason: 'second run on its own grid: $st');
        }
      }
      expect(starts.contains(t0 + 1400000), isTrue);
      expect(starts.contains(a + 1400000 ~/ 30000 * 30000 + 30000), isFalse,
          reason: 'the old phase is gone after the gap');
    });

    test('a hole the carry bridges keeps the onset grid', () {
      final s = EpochInput.make(nightSegs(),
          t0Ms: t0, gaps: [(1000, 1040)], seed: 45);
      final a = t0 + 7000;
      for (final r in _batch(s, a).allRows()) {
        expect((r.startMs - a) % kEpochMs, 0, reason: 'start ${r.startMs}');
      }
    });

    test('the checkpoint carries the phase, and refuses one its rows contradict',
        () {
      final a = t0 + 7000;
      final er = EpochRows(anchorMs: a);
      night.foldInto(er, 0, 1200);
      expect(er.phaseMs, a % kEpochMs);
      final good = jsonDecode(jsonEncode(er.toJson())) as Map<String, dynamic>;
      expect(good['phase'], a % kEpochMs);
      expect(EpochRows.fromJson(good).phaseMs, a % kEpochMs);
      final bad = {...good, 'phase': (a % kEpochMs + 1000) % kEpochMs};
      expect(() => EpochRows.fromJson(bad), throwsA(isA<FormatException>()));
    });
  });

  group('EpochRowsMemo: rows keyed by phase', () {
    final a1 = t0 + 7000; // phase 20000
    final a2 = t0 + 19000; // phase 2000 (32000 mod 30000)
    final a3 = t0 + 23000; // phase 6000

    test('same phase: rows are reused and extended, never recomputed', () {
      final m = EpochRowsMemo();
      final early = night.between(0, 1000);
      final late = night.between(0, 1500);
      final r1 = _ask(m, a1, early);
      expect(m.phaseBuilds, 1);
      expect(m.samplesFolded, early.sampleCount);
      expectSameRows(r1.allRows(), _batch(early, a1).allRows(), 'first ask');
      final r2 = _ask(m, a1, late);
      expect(m.phaseBuilds, 1, reason: 'same phase: no rebuild');
      expect(m.samplesFolded, late.sampleCount,
          reason: 'every sample folded exactly once');
      expectSameRows(r2.allRows(), _batch(late, a1).allRows(), 'extended');
      // nothing new: nothing folded
      _ask(m, a1, late);
      expect(m.samplesFolded, late.sampleCount);
      expect(m.phaseBuilds, 1);
      expect(m.phases, [a1 % kEpochMs]);
    });

    test('an onset that moves by whole epochs keeps the phase and the rows', () {
      final m = EpochRowsMemo();
      final all = night.between(0, 2000);
      _ask(m, a1, all);
      final moved = a1 + 20 * kEpochMs;
      final r = _ask(m, moved, all);
      expect(m.phaseBuilds, 1);
      expect(m.samplesFolded, all.sampleCount);
      final want = _batch(all, moved).allRows();
      expectSameRows(
          [for (final x in r.allRows()) if (x.startMs >= moved) x], want,
          'rows from the new onset on');
    });

    test('a different phase yields rows exactly equal to a fresh batch on that '
        'phase, and the memo keeps the new phase', () {
      final m = EpochRowsMemo();
      final all = night.between(0, 2400);
      _ask(m, a1, all);
      final r = _ask(m, a2, all);
      expect(m.phaseBuilds, 2);
      expect(m.phases.last, a2 % kEpochMs);
      expectSameRows(r.allRows(), _batch(all, a2).allRows(), 'phase changed');
      for (final x in r.allRows()) {
        expect((x.startMs - a2) % kEpochMs, 0);
      }
      // and the old phase is still exact when asked again with more data
      final more = night.between(0, night.seconds);
      final back = _ask(m, a1, more);
      expectSameRows(back.allRows(), _batch(more, a1).allRows(), 'back to a1');
    });

    test('the memo is bounded: at most 2 phases are kept, always exact', () {
      final m = EpochRowsMemo();
      final all = night.between(0, 1800);
      for (final a in [a1, a2, a3, a1, a3, a2]) {
        final r = _ask(m, a, all);
        expect(m.phases.length, lessThanOrEqualTo(2), reason: 'after $a');
        expect(m.phases.last, a % kEpochMs, reason: 'most recent is held');
        expectSameRows(r.allRows(), _batch(all, a).allRows(), 'anchor $a');
      }
      expect(m.phaseBuilds, greaterThanOrEqualTo(4),
          reason: 'a third phase evicts one; asking for it again rebuilds');
    });

    test('checkpoint: same phase resumes without a rebuild', () {
      final m = EpochRowsMemo();
      _ask(m, a1, night.between(0, 1000));
      final back = EpochRowsMemo.fromJson(
          jsonDecode(jsonEncode(m.toJson())) as Map<String, dynamic>);
      expect(back.phases, [a1 % kEpochMs]);
      final more = night.between(0, 2200);
      final r = _ask(back, a1, more);
      expect(back.phaseBuilds, 0, reason: 'nothing rebuilt after the restore');
      expect(back.samplesFolded, more.sampleCount - night.between(0, 1000).sampleCount,
          reason: 'only the samples the checkpoint had not consumed');
      expectSameRows(r.allRows(), _batch(more, a1).allRows(), 'resumed');
    });

    test('checkpoint: a different phase rebuilds, never reusing the other '
        'phase\'s rows, and still equals batch', () {
      final m = EpochRowsMemo();
      _ask(m, a1, night.between(0, 1000));
      final back = EpochRowsMemo.fromJson(
          jsonDecode(jsonEncode(m.toJson())) as Map<String, dynamic>);
      final more = night.between(0, 2200);
      final r = _ask(back, a2, more);
      expect(back.phaseBuilds, 1);
      expect(back.samplesFolded, more.sampleCount,
          reason: 'built from all the samples');
      for (final x in r.allRows()) {
        expect((x.startMs - a2) % kEpochMs, 0, reason: 'start ${x.startMs}');
      }
      expectSameRows(r.allRows(), _batch(more, a2).allRows(), 'other phase');
    });

    test('a memo embedding a version-3 row checkpoint is refused', () {
      final m = EpochRowsMemo();
      _ask(m, a1, night.between(0, 1000));
      final good = jsonDecode(jsonEncode(m.toJson())) as Map<String, dynamic>;
      for (final v in [1, 2, 3]) {
        final bad = jsonDecode(jsonEncode(good)) as Map<String, dynamic>;
        for (final p in bad['phases'] as List) {
          (p['rows'] as Map<String, dynamic>)['version'] = v;
        }
        expect(() => EpochRowsMemo.fromJson(bad),
            throwsA(isA<FormatException>()), reason: 'rows version $v');
      }
    });

    test('a checkpoint is refused when it is of another type or shape', () {
      final m = EpochRowsMemo();
      _ask(m, a1, night.between(0, 600));
      final good = jsonDecode(jsonEncode(m.toJson())) as Map<String, dynamic>;
      for (final bad in <Map<String, dynamic>>[
        {...good, 'type': 'EpochRows'},
        {...good}..remove('type'),
        <String, dynamic>{},
      ]) {
        expect(() => EpochRowsMemo.fromJson(bad),
            throwsA(isA<FormatException>()), reason: jsonEncode(bad));
      }
    });
  });

  group('staging from memo rows = batch staging from the onset', () {
    for (final (name, onsetSec, endSec, firstAsk) in [
      ('onset 777 s in, fresh memo', 777, 2400, null),
      ('onset 1234 s in, memo first asked on another phase', 1234, 2900, 3),
      ('onset on a 30 s multiple of the data start', 600, 2100, null),
    ]) {
      test(name, () {
        final base = t0 ~/ 1000;
        final onset = base + onsetSec, end = base + endSec;
        final want = AdvancedSleepStager.stageWindow(
                onset, end, night.grav, night.hrTs, rr: night.rrTsSec)
            .stages;
        final m = EpochRowsMemo();
        final window = night.between(onsetSec, endSec);
        if (firstAsk != null) {
          _ask(m, t0 + 5000 + firstAsk * 1000, night.between(onsetSec, onsetSec + 900));
        }
        final rows = _ask(m, onset * 1000, window);
        expect(showStages(rows.stageWindow(onset, end)), showStages(want));
      });
    }

    test('staged in growing prefixes through one memo = batch at the end', () {
      final base = t0 ~/ 1000;
      final onset = base + 777, end = base + 2400;
      final m = EpochRowsMemo();
      EpochRows? rows;
      for (var hi = 1000; hi <= 2400; hi += 350) {
        rows = _ask(m, onset * 1000, night.between(777, hi < 2400 ? hi : 2400));
      }
      rows = _ask(m, onset * 1000, night.between(777, 2400));
      expect(m.phaseBuilds, 1);
      final want = AdvancedSleepStager.stageWindow(
              onset, end, night.grav, night.hrTs, rr: night.rrTsSec)
          .stages;
      expect(showStages(rows.stageWindow(onset, end)), showStages(want));
    });
  });
}
