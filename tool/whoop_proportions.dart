// Calibrate the stage-score CUTOFFS on our own device's feature distribution.
//
// The axis weights come from DREAMT (PSG ground truth, 99 wrist nights) and are
// what that corpus is good for: which features carry stage information and in
// which direction. The CUTOFFS are a different question — they sit on a
// robust-z score whose spread depends on how OUR feature extraction behaves,
// and the DREAMT-derived values demonstrably under-call REM on a real WHOOP
// night (62 min against a ~162 min reference). So sweep them here, on real
// device captures, and pick for NORMATIVE STAGE PROPORTIONS:
//
//   REM  20-25% of TST   Deep 13-23% of TST     (Mitterling 2015 percentile
//   curves; Boulos 2019 meta-regression, N=5,273, AASM scoring)
//
// There is no ground truth in these files — that is the point. This calibrates
// distributional plausibility only, and it is the honest limit of what we can
// do on our own device until we have concurrent PSG.
//
// Usage: dart run tool/whoop_proportions.dart <dir-of-night-json>
// Night JSON: {"day","start","end","onehz":[[ts,hr,ax,ay,az],..],"rr":[[tsMs,rr],..]}

import 'dart:convert';
import 'dart:io';

import 'package:openstrap_analytics/onehz.dart';

void main(List<String> args) {
  final dir = Directory(args.isEmpty ? '/tmp/sleepdbg' : args.first);
  final files = dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.contains('2026-') && f.path.endsWith('.json'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  final nights = <(String, List<double>, List<AccelSample>, List<double>,
      List<double>)>[];
  for (final f in files) {
    final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    final oh = j['onehz'] as List;
    if (oh.length < 3600) continue;
    final start = j['start'] as int, end = j['end'] as int;
    final span = end - start;
    final accel =
        List<AccelSample>.filled(span, AccelSample(start * 1000.0, 0, 0, 1));
    final hr = List<double>.filled(span, 0);
    var last = -1;
    final byTs = <int, List<double>>{};
    for (final r in oh) {
      byTs[r[0] as int] = [
        (r[1] as num).toDouble(),
        (r[2] as num).toDouble(),
        (r[3] as num).toDouble(),
        (r[4] as num).toDouble(),
      ];
    }
    for (var i = 0; i < span; i++) {
      final ts = start + i;
      final g = byTs[ts];
      if (g != null) {
        accel[i] = AccelSample(ts * 1000.0, g[1], g[2], g[3]);
        hr[i] = g[0];
        last = i;
      } else if (last >= 0 && i - last <= 120) {
        final p = accel[i - 1];
        accel[i] = AccelSample(ts * 1000.0, p.x, p.y, p.z);
      }
    }
    final rrMs = <double>[], rrTs = <double>[];
    for (final r in (j['rr'] as List)) {
      rrTs.add((r[0] as num).toDouble());
      rrMs.add((r[1] as num).toDouble());
    }
    nights.add((j['day'] as String, hr, accel, rrMs, rrTs));
  }

  stdout.writeln('${nights.length} real device nights');
  stdout.writeln('target: REM 20-25% of TST, Deep 13-23% of TST');
  stdout.writeln('');
  stdout.writeln('remCut deepCut |  median %REM of TST   median %Deep of TST '
      '  median TST(h)');
  for (final rc in [0.0, 0.2, 0.3, 0.4, 0.5, 0.6, 0.8]) {
    for (final dc in [0.0, 0.2, 0.3, 0.4]) {
      final rems = <double>[], deeps = <double>[], tsts = <double>[];
      for (final (_, hr, accel, rrMs, rrTs) in nights) {
        final r = cardioStager(hr, accel,
            rrMs: rrMs,
            rrTsMs: rrTs,
            remScoreCut: rc,
            deepScoreCut: dc);
        var rem = 0, nrem = 0, deep = 0;
        for (var e = 0; e < r.base.stages.length; e++) {
          switch (r.base.stages[e]) {
            case SleepStage.rem:
              rem++;
            case SleepStage.nrem:
              nrem++;
              if (e < r.deepFlag.length && r.deepFlag[e]) deep++;
            case SleepStage.wake:
              break;
          }
        }
        final tst = rem + nrem;
        if (tst == 0) continue;
        rems.add(100 * rem / tst);
        deeps.add(100 * deep / tst);
        tsts.add(tst * 30 / 3600);
      }
      if (rems.isEmpty) continue;
      final flagR = (median(rems)! >= 20 && median(rems)! <= 25) ? ' REM✓' : '';
      final flagD = (median(deeps)! >= 13 && median(deeps)! <= 23) ? ' Deep✓' : '';
      stdout.writeln('  ${rc.toStringAsFixed(1)}    ${dc.toStringAsFixed(1)}  '
          '|      ${median(rems)!.toStringAsFixed(1).padLeft(5)}%'
          '              ${median(deeps)!.toStringAsFixed(1).padLeft(5)}%'
          '            ${median(tsts)!.toStringAsFixed(1)}$flagR$flagD');
    }
  }
}

double? median(List<double> v) {
  if (v.isEmpty) return null;
  final s = [...v]..sort();
  final n = s.length;
  return n.isOdd ? s[n ~/ 2] : (s[n ~/ 2 - 1] + s[n ~/ 2]) / 2;
}

