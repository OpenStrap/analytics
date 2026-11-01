// GUARD: the gap-anchored grid against today's labels on the checked-in real
// night (combined bump, chunk B3 + B4; owner decision 2026-10-22).
//
//   * `fixtures/real_night_2026_07_hypnogram_v1.csv` is today's hypnogram for
//     that night (AdvancedSleepStager.stageWindow at analytics 83fc308, the
//     run-start-anchored grid), computed for a window starting at the
//     UNALIGNED second 1700000013, which is also the night's first sample. It is
//     frozen: regenerate it only as a deliberate decision.
//   * AGREEMENT GUARD (B4): per 30 s epoch of that grid (steps of 30 s from the
//     first sample), the new label equals the frozen one at least
//     [kMinAgreement] = 0.97 of the time (both staged; the epoch's midpoint
//     second is looked up). Anchoring at the first sample of each gap-free run
//     is the old grid for a window that starts at the data, so this is a near
//     identity; the wall-clock grid it replaced scored 0.905 here.
//   * The harness (tool/stager_harness.dart) cannot stand in for this: it
//     scores the decision layer on an external PSG corpus (DREAMT feature
//     export) that is not in the repo, and it has no grid-comparison mode. The
//     skipped test at the end says what that needs.
import 'dart:convert';
import 'dart:io';

import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

import 'support/pre_bump_stager.dart';

const kMinAgreement = 0.97;
const _base = 1700000013; // unaligned: 1700000013 % 30 == 3

class _Night {
  final List<HrSample> hr = [];
  final List<AccelSample> accel = [];
  final List<double> rrMs = [], rrTs = [];
  int seconds = 0;
  List<GravTs> get grav =>
      [for (final a in accel) GravTs(a.tsMs ~/ 1000, a.x, a.y, a.z)];
  List<HrTs> get hrTs => [for (final h in hr) HrTs(h.tsMs ~/ 1000, h.hr)];
  List<RrTs> get rrSec =>
      [for (var i = 0; i < rrMs.length; i++) RrTs(rrTs[i] ~/ 1000, rrMs[i])];
}

_Night? _load() {
  final a = File('test/onehz/fixtures/real_night_2026_07_onehz.csv');
  final b = File('test/onehz/fixtures/real_night_2026_07_rr.csv');
  if (!a.existsSync() || !b.existsSync()) return null;
  final n = _Night();
  for (final l in a.readAsLinesSync().skip(1)) {
    if (l.trim().isEmpty) continue;
    final p = l.split(',');
    final s = int.parse(p[0]);
    final ts = (_base + s) * 1000.0;
    n.seconds = s + 1;
    n.hr.add(HrSample(ts, double.parse(p[1])));
    n.accel.add(AccelSample(
        ts, double.parse(p[2]), double.parse(p[3]), double.parse(p[4])));
  }
  for (final l in b.readAsLinesSync().skip(1)) {
    if (l.trim().isEmpty) continue;
    final p = l.split(',');
    n.rrTs.add(_base * 1000.0 + double.parse(p[0]));
    n.rrMs.add(double.parse(p[1]));
  }
  return n;
}

List<(int, int, String)> _golden() => [
      for (final l in File('test/onehz/fixtures/real_night_2026_07_hypnogram_v1.csv')
          .readAsLinesSync()
          .skip(1))
        if (l.trim().isNotEmpty)
          (
            int.parse(l.split(',')[0]),
            int.parse(l.split(',')[1]),
            l.split(',')[2]
          )
    ];

String? _at(List<(int, int, String)> segs, int rel) {
  for (final s in segs) {
    if (rel >= s.$1 && rel < s.$2) return s.$3;
  }
  return null;
}

void main() {
  final night = _load();

  test('fixtures are present', () {
    expect(night, isNotNull);
    expect(night!.seconds, greaterThan(32000));
    expect(_golden().length, greaterThan(10));
    expect(_base % 30, isNot(0));
  });

  final nightOrNull = night;
  if (nightOrNull == null) return;

  SleepSession stageBatch() => AdvancedSleepStager.stageWindow(
      _base, _base + nightOrNull.seconds, nightOrNull.grav, nightOrNull.hrTs,
      rr: nightOrNull.rrSec);

  late final SleepSession now = stageBatch();

  test('per-epoch agreement with today\'s labels is at least $kMinAgreement', () {
    final old = _golden();
    final stages = [
      for (final g in now.stages) (g.start - _base, g.end - _base, g.stage)
    ];
    var epochs = 0, compared = 0, agree = 0;
    for (var start = _base; start + 30 <= _base + nightOrNull.seconds; start += 30) {
      epochs++;
      final mid = start + 15 - _base;
      final a = _at(old, mid), b = _at(stages, mid);
      if (a == null || b == null || a == 'unobserved' || b == 'unobserved') continue;
      compared++;
      if (a == b) agree++;
    }
    expect(compared, greaterThan(epochs * 0.9),
        reason: 'most of the night must be staged under both grids');
    final agreement = agree / compared;
    expect(agreement, greaterThanOrEqualTo(kMinAgreement),
        reason: 'agreement $agree/$compared = ${agreement.toStringAsFixed(4)}');
  });

  // Grid option 2 (owner decision 2026-10-23): the window start is phase 0 of
  // the epoch grid, as before the bump. On this night the start is the first
  // sample, so agreement with the frozen hypnogram is exactly 1.0 (it is 1.0
  // under the gap-anchored grid too; this keeps it there).
  test('onset grid: agreement with the frozen hypnogram is exactly 1.0', () {
    final old = _golden();
    final stages = [
      for (final g in now.stages) (g.start - _base, g.end - _base, g.stage)
    ];
    var compared = 0, agree = 0;
    for (var start = _base; start + 30 <= _base + nightOrNull.seconds; start += 30) {
      final mid = start + 15 - _base;
      final a = _at(old, mid), b = _at(stages, mid);
      // Complete label equality: 'unobserved' (and missing) epochs count too.
      compared++;
      if (a == b) agree++;
    }
    expect(compared, greaterThan(1000));
    expect(agree, compared, reason: 'agreement $agree/$compared');
  });

  test('a window that starts mid-night (unaligned to the first sample) is '
      'staged on the onset grid: labels equal the pre-bump stager', () {
    // 5 h in, 17 s off the 30 s steps of the first sample, 3 h long.
    final start = _base + 18000 + 17, end = start + 3 * 3600;
    final got = AdvancedSleepStager.stageWindow(
            start, end, nightOrNull.grav, nightOrNull.hrTs, rr: nightOrNull.rrSec)
        .stages;
    final want = preBumpStageSessionCardio(
        start, end, nightOrNull.grav, nightOrNull.hrTs, nightOrNull.rrSec);
    expect(showSegments(got), showSegments(want));
  });

  test('the real night\'s hypnogram boundaries sit on the grid of their '
      'gap-free run (30 s steps from the run\'s first sample)', () {
    // The run anchors, found independently of the code under test: a new run
    // starts at the first valid sample more than 61 s after the previous one
    // (the stager's 60 s carry-forward bridges anything shorter).
    final anchors = <int>[];
    int? prev;
    for (final g in nightOrNull.grav) {
      if (prev == null || g.ts > prev + 61) anchors.add(g.ts);
      prev = g.ts;
    }
    expect(anchors.first, _base);
    final stages = now.stages;
    var checked = 0;
    for (var i = 1; i < stages.length; i++) {
      if (stages[i].stage == 'unobserved' || stages[i - 1].stage == 'unobserved') {
        continue;
      }
      final edge = stages[i].start;
      final anchor = anchors.lastWhere((a) => a <= edge);
      expect((edge - anchor) % 30, 0,
          reason: 'boundary at $edge (${stages[i - 1].stage} -> '
              '${stages[i].stage}), run anchored at $anchor');
      checked++;
    }
    expect(checked, greaterThan(20));
  });

  test('EpochRows over the whole night in 15-minute chunks with checkpoints '
      'stages exactly like one batch, and its checkpoint stays small', () {
    var er = EpochRows();
    var worst = 0;
    for (var lo = 0; lo < nightOrNull.seconds; lo += 900) {
      final hi = lo + 900 < nightOrNull.seconds ? lo + 900 : nightOrNull.seconds;
      final t0 = (_base + lo) * 1000.0, t1 = (_base + hi) * 1000.0;
      bool inside(double t) => t >= t0 && t < t1;
      final ri = [
        for (var i = 0; i < nightOrNull.rrTs.length; i++)
          if (inside(nightOrNull.rrTs[i])) i
      ];
      er.fold(
        hr: nightOrNull.hr.sublist(lo, hi),
        accel: nightOrNull.accel.sublist(lo, hi),
        rrMs: [for (final i in ri) nightOrNull.rrMs[i]],
        rrTsMs: [for (final i in ri) nightOrNull.rrTs[i]],
      );
      final text = jsonEncode(er.toJson());
      if (text.length > worst) worst = text.length;
      er = EpochRows.fromJson(jsonDecode(text) as Map<String, dynamic>);
    }
    // ~1,070 rows of 8 numbers plus an unsettled tail of a few minutes of
    // samples; the raw night (32,000 s x 5 channels) would be several times this.
    expect(worst, lessThan(800000), reason: 'checkpoint chars');
    final got = er.stageWindow(_base, _base + nightOrNull.seconds);
    expect(jsonEncode([for (final g in got) g.toJson()]),
        jsonEncode([for (final g in now.stages) g.toJson()]));
  });

  test('DREAMT harness: per-epoch agreement of the gap-anchored grid with the '
      'run-start grid on the PSG corpus', () {
    // Needs (1) the DREAMT feature export (stager_harness.dart's fixture JSON),
    // which is not in this repo, and (2) a grid-comparison mode in
    // tool/stager_harness.dart: classify the same subject once on epochs cut at
    // the subject's start and once on epochs cut 0..29 s later, report per-epoch
    // agreement and kappa for both against the PSG labels. Threshold: 0.97.
    fail('unreachable: skipped until the corpus and the harness mode exist');
  }, skip: 'DREAMT fixture is not in the repo and tool/stager_harness.dart has no '
      'grid-comparison mode; run it on the machine that holds the corpus '
      '(B4 of combined-bump/brief.md).');
}
