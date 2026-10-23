// Shared fixtures for the option-2 (onset-anchored, phase-keyed) EpochRows
// tests: a synthetic night as raw samples, optionally with holes.
import 'dart:convert';

import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

import '../../support/property.dart';
import 'causal_night.dart';

const int kAlignedT0Ms = 1700000010000; // a multiple of 30,000

class EpochInput {
  final int t0Ms, seconds;
  final List<HrSample> hr;
  final List<AccelSample> accel;
  final List<double> rrMs, rrTs;
  EpochInput(this.t0Ms, this.seconds, this.hr, this.accel, this.rrMs, this.rrTs);

  /// Both streams lose the same seconds [gaps] (seconds since t0), and the
  /// beats in them.
  factory EpochInput.make(List<(String, int)> segs,
      {int seed = 11, int t0Ms = kAlignedT0Ms, List<(int, int)> gaps = const []}) {
    final n = synthNight(segs, seed: seed, t0Ms: t0Ms.toDouble());
    bool inGap(double ts) => gaps
        .any((g) => ts >= t0Ms + g.$1 * 1000.0 && ts < t0Ms + g.$2 * 1000.0);
    final rr = <double>[], rt = <double>[];
    for (var i = 0; i < n.rrMs.length; i++) {
      if (!inGap(n.rrTsMs[i])) {
        rr.add(n.rrMs[i]);
        rt.add(n.rrTsMs[i]);
      }
    }
    return EpochInput(t0Ms, n.seconds, [for (final h in n.hr) if (!inGap(h.tsMs)) h],
        [for (final a in n.accel) if (!inGap(a.tsMs)) a], rr, rt);
  }

  /// Samples with `loSec <= second < hiSec` (seconds since t0), as a new input
  /// (same t0; `seconds` becomes hiSec - loSec only for bookkeeping).
  EpochInput between(int loSec, int hiSec) {
    final lo = t0Ms + loSec * 1000.0, hi = t0Ms + hiSec * 1000.0;
    bool inside(double t) => t >= lo && t < hi;
    final ri = [
      for (var i = 0; i < rrTs.length; i++)
        if (inside(rrTs[i])) i
    ];
    return EpochInput(
        t0Ms,
        seconds,
        [for (final h in hr) if (inside(h.tsMs)) h],
        [for (final a in accel) if (inside(a.tsMs)) a],
        [for (final i in ri) rrMs[i]],
        [for (final i in ri) rrTs[i]]);
  }

  void foldInto(EpochRows er, int loSec, int hiSec) {
    final p = between(loSec, hiSec);
    er.fold(hr: p.hr, accel: p.accel, rrMs: p.rrMs, rrTsMs: p.rrTs);
  }

  int get sampleCount => hr.length + accel.length + rrMs.length;

  List<GravTs> get grav =>
      [for (final a in accel) GravTs(a.tsMs ~/ 1000, a.x, a.y, a.z)];
  List<HrTs> get hrTs => [for (final h in hr) HrTs(h.tsMs ~/ 1000, h.hr)];
  List<RrTs> get rrTsSec =>
      [for (var i = 0; i < rrMs.length; i++) RrTs(rrTs[i] ~/ 1000, rrMs[i])];
}

List<(String, int)> nightSegs() => [
      ('nrem', 900), ('rem', 600), ('nrem', 900), ('wake', 300), ('nrem', 300),
    ];

List<int> randomCuts(Rng r, int seconds) {
  const sizes = [1, 2, 7, 30, 31, 59, 100, 171, 500];
  final out = <int>[];
  var at = 0;
  while (true) {
    at += r.nextBool(.15) ? 0 : 1 + r.nextInt(sizes[r.nextInt(sizes.length)]);
    if (at >= seconds) return out;
    out.add(at);
  }
}

bool sameRow(EpochFeatureRow a, EpochFeatureRow b) =>
    a.startMs == b.startMs &&
    [
      [a.motion, b.motion], [a.hr, b.hr], [a.hrSd, b.hrSd],
      [a.rmssd, b.rmssd], [a.lfhf, b.lfhf], [a.rk, b.rk], [a.sdnn, b.sdnn],
    ].every((p) => p[0].compareTo(p[1]) == 0);

void expectSameRows(
    List<EpochFeatureRow> got, List<EpochFeatureRow> want, String why) {
  expect(got.length, want.length, reason: '$why: row count');
  for (var i = 0; i < got.length; i++) {
    if (!sameRow(got[i], want[i])) {
      fail('$why: row $i differs: got start ${got[i].startMs} hr ${got[i].hr} '
          'motion ${got[i].motion}; want start ${want[i].startMs} '
          'hr ${want[i].hr} motion ${want[i].motion}');
    }
  }
}

String showStages(List<StageSegment> l) =>
    jsonEncode([for (final g in l) g.toJson()]);
