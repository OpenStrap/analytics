import 'dart:io';
import 'dart:convert';
import 'package:openstrap_analytics/onehz.dart';

void main(List<String> args) {
  const base = 1700000013;
  final accel = <AccelSample>[], hr = <HrSample>[];
  final rr = <double>[], ts = <double>[];
  for (final l in File('test/onehz/fixtures/real_night_2026_07_onehz.csv')
      .readAsLinesSync()
      .skip(1)) {
    final p = l.split(',');
    if (p.length < 5) continue;
    final t = (base + int.parse(p[0])) * 1000.0;
    hr.add(HrSample(t, double.parse(p[1])));
    accel.add(AccelSample(
        t, double.parse(p[2]), double.parse(p[3]), double.parse(p[4])));
  }
  for (final l in File('test/onehz/fixtures/real_night_2026_07_rr.csv')
      .readAsLinesSync()
      .skip(1)) {
    final p = l.split(',');
    if (p.length < 2) continue;
    rr.add(double.parse(p[1]));
    ts.add(base * 1000.0 + double.parse(p[0]));
  }
  if (args.contains('rr-bench')) {
    for (var i = 0; i < 8; i++) {
      correctRr(rr, rrTsMs: ts);
      correctRr(rr, rrTsMs: ts, maxArtifactRun: null);
    }
    print('correctRr capped: ${medianUs(() => correctRr(rr, rrTsMs: ts))} us');
    print(
        'correctRr uncapped: ${medianUs(() => correctRr(rr, rrTsMs: ts, maxArtifactRun: null))} us');
    return;
  }
  if (args.contains('bench')) {
    benchmark(hr, accel, rr, ts);
    return;
  }
  final old = <(int, int, String)>[];
  for (final l
      in File('test/onehz/fixtures/real_night_2026_07_hypnogram_v1.csv')
          .readAsLinesSync()
          .skip(1)) {
    final p = l.split(',');
    if (p.length < 3) continue;
    old.add((base + int.parse(p[0]), base + int.parse(p[1]), p[2]));
  }
  void compare(String name, List<StageSegment> segments) {
    var same = 0, count = 0;
    final confusion = <String, int>{};
    for (var t = (base + 29) ~/ 30 * 30 + 15;
        t + 15 <= base + hr.length;
        t += 30) {
      final a = old.where((s) => t >= s.$1 && t < s.$2).first.$3;
      final b = segments.where((s) => t >= s.start && t < s.end).first.stage;
      if (a == 'unobserved' || b == 'unobserved') continue;
      count++;
      if (a == b) same++;
      if (a != b) confusion.update('$a->$b', (v) => v + 1, ifAbsent: () => 1);
    }
    print('$name agreement=$same/$count=${same / count} $confusion');
  }

  final er = EpochRows();
  final sw = Stopwatch()..start();
  er.fold(hr: hr, accel: accel, rrMs: rr, rrTsMs: ts);
  final rows = er.allRows();
  sw.stop();
  print('EpochRows full ${sw.elapsedMicroseconds} us, ${rows.length} rows');
  compare('EpochRows', er.stageWindow(base, base + hr.length));
  for (final lowHz in [1 / 180, 0.04]) {
    final lfhf = <double>[];
    for (final row in rows) {
      final b = cleanRrBeatsBetween(
          rr, ts, row.startMs - 75000.0, row.startMs + 105000.0);
      final ls = b.beats.length < 16
          ? null
          : lombScargle(b.tsSec, b.beats, freqGrid(lowHz, 0.4, 240));
      final hf = ls?.bandPower(0.15, 0.4) ?? 0;
      lfhf.add(hf > 0 ? ls!.bandPower(0.04, 0.15) / hf : double.nan);
    }
    final result = classifyCardioEpochs(CardioEpochFeatures(
        motion: [for (final r in rows) r.motion],
        hr: [for (final r in rows) r.hr],
        hrSd: [for (final r in rows) r.hrSd],
        rmssd: [for (final r in rows) r.rmssd],
        lfhf: lfhf,
        rk: [for (final r in rows) r.rk],
        sdnn: [for (final r in rows) r.sdnn]));
    compare('fixed grid $lowHz', [
      for (var i = 0; i < result.base.stages.length; i++)
        StageSegment(
            i == 0 ? base : rows[i].startMs ~/ 1000,
            i == result.base.stages.length - 1
                ? base + hr.length
                : rows[i + 1].startMs ~/ 1000,
            result.base.stages[i] == SleepStage.wake
                ? 'wake'
                : result.base.stages[i] == SleepStage.rem
                    ? 'rem'
                    : result.deepFlag[i]
                        ? 'deep'
                        : 'light')
    ]);
  }
  for (final skip in [0, 27]) {
    final s = Stopwatch()..start();
    final result = cardioStager(
        [for (final h in hr.skip(skip)) h.hr], accel.sublist(skip),
        rrMs: rr, rrTsMs: ts);
    s.stop();
    print('cardioStager skip=$skip ${s.elapsedMicroseconds} us');
    compare('direct skip=$skip', [
      for (var i = 0; i < result.base.stages.length; i++)
        StageSegment(
            base + skip + i * 30,
            i == result.base.stages.length - 1
                ? base + hr.length
                : base + skip + (i + 1) * 30,
            result.base.stages[i] == SleepStage.wake
                ? 'wake'
                : result.base.stages[i] == SleepStage.rem
                    ? 'rem'
                    : result.deepFlag[i]
                        ? 'deep'
                        : 'light')
    ]);
  }
}

int medianUs(void Function() run) {
  run();
  final samples = <int>[];
  for (var i = 0; i < 3; i++) {
    final sw = Stopwatch()..start();
    run();
    samples.add(sw.elapsedMicroseconds);
  }
  samples.sort();
  return samples[1];
}

void benchmark(List<HrSample> hr, List<AccelSample> accel, List<double> rr,
    List<double> ts) {
  final values = [for (final h in hr) h.hr];
  print('Real night: ${hr.length} seconds, ${rr.length} beats');
  print('EpochRows fold + allRows: ${medianUs(() {
    final er = EpochRows();
    er.fold(hr: hr, accel: accel, rrMs: rr, rrTsMs: ts);
    er.allRows();
  })} us');
  print(
      'cardioEpochFeatures: ${medianUs(() => cardioEpochFeatures(values, accel, rrMs: rr, rrTsMs: ts))} us');
  print('correctRr capped: ${medianUs(() => correctRr(rr, rrTsMs: ts))} us');
  print(
      'correctRr uncapped: ${medianUs(() => correctRr(rr, rrTsMs: ts, maxArtifactRun: null))} us');
  final er = EpochRows();
  var rb = 0, streamed = 0, batch = 0, checkpointChars = 0;
  final t0 = hr.first.tsMs;
  for (var begin = 0; begin < hr.length; begin += 900) {
    final end = (begin + 900).clamp(0, hr.length);
    final rt = t0 + end * 1000;
    var re = rb;
    while (re < ts.length && ts[re] < rt) {
      re++;
    }
    final watch = Stopwatch()..start();
    er.fold(
        hr: hr.sublist(begin, end),
        accel: accel.sublist(begin, end),
        rrMs: rr.sublist(rb, re),
        rrTsMs: ts.sublist(rb, re));
    er.allRows();
    streamed += watch.elapsedMicroseconds;
    checkpointChars = jsonEncode(er.toJson()).length;
    watch.reset();
    cardioEpochFeatures(values.sublist(0, end), accel.sublist(0, end),
        rrMs: rr.sublist(0, re), rrTsMs: ts.sublist(0, re));
    batch += watch.elapsedMicroseconds;
    rb = re;
  }
  print(
      '15-minute passes total: EpochRows $streamed us, batch features $batch us');
  print('EpochRows final checkpoint: $checkpointChars chars');
  print(
      'RrSandwich benchmark unavailable: generic clock translation is unresolved');
}
