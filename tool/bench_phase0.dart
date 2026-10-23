// Round 15, phase 0 benchmark. The frozen before implementations live in the
// parity characterization test and are deliberately imported rather than
// copied again: that file is the versioned source of truth for this comparison.

import 'package:openstrap_analytics/onehz.dart';
import '../test/onehz/phase0_parity_test.dart' as frozen;

int _medianUs(void Function() f, {int runs = 3}) {
  if (runs == 1) {
    final sw = Stopwatch()..start();
    f();
    sw.stop();
    return sw.elapsedMicroseconds;
  }
  final samples = <int>[];
  f(); // warm up JIT and lazy static initialization.
  for (var i = 0; i < runs; i++) {
    final sw = Stopwatch()..start();
    f();
    sw.stop();
    samples.add(sw.elapsedMicroseconds);
  }
  samples.sort();
  return samples[samples.length ~/ 2];
}

int _medianPreparedUs(void Function() prepare, void Function() f,
    {int runs = 3}) {
  if (runs == 1) {
    prepare();
    final sw = Stopwatch()..start();
    f();
    sw.stop();
    return sw.elapsedMicroseconds;
  }
  prepare();
  f(); // JIT warmup; each measured pass gets the same prepared cache state.
  final samples = <int>[];
  for (var i = 0; i < runs; i++) {
    prepare();
    final sw = Stopwatch()..start();
    f();
    sw.stop();
    samples.add(sw.elapsedMicroseconds);
  }
  samples.sort();
  return samples[samples.length ~/ 2];
}

bool _same(double? a, double? b) =>
    a == null || b == null ? a == b : (a.isNaN && b.isNaN) || a == b;

bool _sameList(List<double>? a, List<double>? b) {
  if (a == null || b == null) return a == null && b == null;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (!_same(a[i], b[i])) return false;
  }
  return true;
}

bool _sameCvhr(Metric<CvhrResult> a, Metric<CvhrResult> b) {
  final x = a.value, y = b.value;
  return _same(a.confidence, b.confidence) &&
      ((x == null || y == null)
          ? x == null && y == null
          : x.cycleCount == y.cycleCount &&
              _same(x.cvhrPerHour, y.cvhrPerHour) &&
              _same(x.analyzedHours, y.analyzedHours) &&
              _same(x.meanDepthMs, y.meanDepthMs) &&
              _same(x.meanWidthSec, y.meanWidthSec) &&
              _sameList(x.depthQuartilesMs, y.depthQuartilesMs) &&
              _sameList(x.widthQuartilesSec, y.widthQuartilesSec));
}

void _cvhrStreamBench() {
  // 32 × 15 min, about eight hours at 56 bpm. Each pass makes the newly
  // settled prefix permanent and compares its snapshot with the batch scorer.
  final night = frozen.genBeats(9019, 33000, period: 55, amp: 60);
  final stream = CvhrStream();
  var from = 0, streamTotal = 0, batchTotal = 0;
  var parity = true;
  final start = night.tMs.first;
  print('CVHR stream: pass  stream us  batch us  parity');
  for (var pass = 1; pass <= 32; pass++) {
    final until = start + pass * 15 * 60 * 1000.0;
    var end = from;
    while (end < night.nn.length && night.tMs[end] <= until) {
      end++;
    }
    if (end == from) continue;
    stream.fold(night.nn.sublist(from, end), night.tMs.sublist(from, end));
    from = end;
    final streamWatch = Stopwatch()..start();
    final streamed = stream.snapshot(artifactFraction: 0.02);
    streamWatch.stop();
    final batchWatch = Stopwatch()..start();
    final batch = cvhrApneaScreen(night.nn.sublist(0, end),
        night.tMs.sublist(0, end), artifactFraction: 0.02);
    batchWatch.stop();
    final streamUs = streamWatch.elapsedMicroseconds;
    final batchUs = batchWatch.elapsedMicroseconds;
    streamTotal += streamUs;
    batchTotal += batchUs;
    final same = _sameCvhr(streamed, batch);
    parity = parity && same;
    print('cvhr pass ${pass.toString().padLeft(2)} '
        '${streamUs.toString().padLeft(9)} ${batchUs.toString().padLeft(9)} '
        'parity=$same');
  }
  print('cvhr total    ${streamTotal.toString().padLeft(9)} '
      '${batchTotal.toString().padLeft(9)}');
  print('cvhr stream parity: $parity');
  if (!parity) throw StateError('CVHR stream parity failed');
}

bool _sameHrv(Metric<HrvFreq> a, Metric<HrvFreq> b) {
  final x = a.value, y = b.value;
  return _same(a.confidence, b.confidence) &&
      ((x == null || y == null)
          ? x == null && y == null
          : _same(x.ulf, y.ulf) &&
              _same(x.vlf, y.vlf) &&
              _same(x.lf, y.lf) &&
              _same(x.hf, y.hf) &&
              _same(x.total, y.total) &&
              _same(x.lfhf, y.lfhf) &&
              _same(x.nuLf, y.nuLf) &&
              _same(x.nuHf, y.nuHf) &&
              x.hfGated == y.hfGated &&
              x.totalBands.toString() == y.totalBands.toString());
}

bool _sameStager(CardioStagerResult a, CardioStagerResult b) =>
    a.base.stages.toString() == b.base.stages.toString() &&
    a.base.epochSec == b.base.epochSec &&
    _same(a.base.wakePct, b.base.wakePct) &&
    _same(a.base.nremPct, b.base.nremPct) &&
    _same(a.base.remPct, b.base.remPct) &&
    a.deepFlag.toString() == b.deepFlag.toString() &&
    _same(a.confidence, b.confidence);

bool _sameRsa(Metric<RespEstimate> a, Metric<RespEstimate> b) {
  final x = a.value, y = b.value;
  return _same(a.confidence, b.confidence) &&
      a.tier == b.tier &&
      a.inputs_used.toString() == b.inputs_used.toString() &&
      a.note == b.note &&
      ((x == null || y == null)
          ? x == null && y == null
          : _same(x.brpm, y.brpm) &&
              _same(x.peakHz, y.peakHz) &&
              _same(x.power, y.power) &&
              x.source == y.source);
}

void _welchStreamBench() {
  // 32 × 15 min, about eight hours at 56 bpm. The tail is provisional: it is
  // included in each snapshot and batch call, then folded in a later pass.
  final night = frozen.genBeats(9018, 33000, period: 53, amp: 50);
  final hrv = HrvFreqStream();
  final rsa = RsaRespStream();
  var from = 0;
  var hrvStreamTotal = 0, hrvBatchTotal = 0;
  var rsaStreamTotal = 0, rsaBatchTotal = 0;
  var parity = true;
  final start = night.tMs.first;
  print('Welch streams: pass  stream hrv/rsa us  batch hrv/rsa us  parity');
  for (var pass = 1; pass <= 32; pass++) {
    final until = start + pass * 15 * 60 * 1000.0;
    var end = from;
    while (end < night.nn.length && night.tMs[end] <= until) {
      end++;
    }
    if (end == from) continue;
    hrv.fold(night.nn.sublist(from, end), night.tMs.sublist(from, end));
    rsa.fold(night.nn.sublist(from, end), night.tMs.sublist(from, end));
    from = end;
    final tailEnd = (end + 100).clamp(0, night.nn.length);
    final tailNn = night.nn.sublist(end, tailEnd);
    final tailTimes = night.tMs.sublist(end, tailEnd);
    final hrvStreamWatch = Stopwatch()..start();
    final streamHrv = hrv.snapshot(
        tailNnMs: tailNn, tailNnTimesMs: tailTimes, artifactFraction: 0.02);
    hrvStreamWatch.stop();
    final rsaStreamWatch = Stopwatch()..start();
    final streamRsa = rsa.snapshot(
        tailNnMs: tailNn, tailNnTimesMs: tailTimes, artifactFraction: 0.02);
    rsaStreamWatch.stop();
    final hrvBatchWatch = Stopwatch()..start();
    final batchHrv = hrvFreq(night.nn.sublist(0, tailEnd),
        night.tMs.sublist(0, tailEnd), artifactFraction: 0.02);
    hrvBatchWatch.stop();
    final rsaBatchWatch = Stopwatch()..start();
    final batchRsa = rsaRespRate(night.nn.sublist(0, tailEnd),
        night.tMs.sublist(0, tailEnd), artifactFraction: 0.02);
    rsaBatchWatch.stop();
    final hrvStreamUs = hrvStreamWatch.elapsedMicroseconds;
    final rsaStreamUs = rsaStreamWatch.elapsedMicroseconds;
    final hrvBatchUs = hrvBatchWatch.elapsedMicroseconds;
    final rsaBatchUs = rsaBatchWatch.elapsedMicroseconds;
    hrvStreamTotal += hrvStreamUs;
    rsaStreamTotal += rsaStreamUs;
    hrvBatchTotal += hrvBatchUs;
    rsaBatchTotal += rsaBatchUs;
    final same = _sameHrv(streamHrv, batchHrv) && _sameRsa(streamRsa, batchRsa);
    parity = parity && same;
    print('welch pass ${pass.toString().padLeft(2)} '
        '${hrvStreamUs.toString().padLeft(8)}/${rsaStreamUs.toString().padLeft(8)} '
        '${hrvBatchUs.toString().padLeft(8)}/${rsaBatchUs.toString().padLeft(8)} '
        'parity=$same');
  }
  print('welch total    '
      '${hrvStreamTotal.toString().padLeft(8)}/${rsaStreamTotal.toString().padLeft(8)} '
      '${hrvBatchTotal.toString().padLeft(8)}/${rsaBatchTotal.toString().padLeft(8)}');
  print('welch stream parity: $parity');
  if (!parity) throw StateError('Welch stream parity failed');
}

void main(List<String> args) {
  // 8 h / 30k beats / one 8 h night, respectively. Fixed seeds make both the
  // timings and the parity gate reproducible.
  final cvhr = frozen.genBeats(9001, 32000, period: 55, amp: 60);
  final hrv = frozen.genBeats(9002, 30000, period: 53, amp: 50);
  final night = frozen.genNight(9003, 8 * 60 * 60, rrOutliers: true);

  final cvhrBefore = () => frozen.refCvhrApneaScreen(cvhr.nn, cvhr.tMs,
      artifactFraction: 0.02);
  final cvhrAfter = () =>
      cvhrApneaScreen(cvhr.nn, cvhr.tMs, artifactFraction: 0.02);
  final hrvBefore = () =>
      frozen.refHrvFreq(hrv.nn, hrv.tMs, artifactFraction: 0.02);
  final hrvAfter = () => hrvFreq(hrv.nn, hrv.tMs, artifactFraction: 0.02);
  final stagerBefore = () => frozen.refCardioStager(night.hr, night.accel,
      rrMs: night.rr, rrTsMs: night.rrTs);
  final stagerAfter = () => cardioStager(night.hr, night.accel,
      rrMs: night.rr, rrTsMs: night.rrTs);

  final selected = args.isEmpty ? {'cvhr', 'hrv', 'cardio'} : args.toSet();
  print('case                         before us  after us');
  var parity = true;
  void row(String key, String name, void Function() before, void Function() after,
      bool same) {
    if (!selected.contains(key)) return;
    parity = parity && same;
    final beforeUs = _medianUs(before);
    final afterUs = _medianUs(after);
    print('${name.padRight(28)} ${beforeUs.toString().padLeft(9)} '
        '${afterUs.toString().padLeft(9)} parity=$same');
  }
  row('cvhr', 'cvhrApneaScreen (8 h)', cvhrBefore, cvhrAfter,
      _sameCvhr(cvhrBefore(), cvhrAfter()));
  row('hrv', 'hrvFreq (30k beats)', hrvBefore, hrvAfter,
      _sameHrv(hrvBefore(), hrvAfter()));
  row('cardio', 'cardioStager (one night)', stagerBefore, stagerAfter,
      _sameStager(stagerBefore(), stagerAfter()));
  if (args.isEmpty || selected.contains('cvhr-stream')) _cvhrStreamBench();
  if (selected.contains('cardio') || selected.contains('cache')) {
    final extra = frozen.genNight(9004, 15 * 60, rrOutliers: true);
    const nightMs = 8 * 60 * 60 * 1000.0;
    final appendedAccel = [
      ...night.accel,
      for (final a in extra.accel)
        AccelSample(a.tsMs + nightMs, a.x, a.y, a.z, valid: a.valid),
    ];
    final appendedHr = [...night.hr, ...extra.hr];
    final appendedRr = [...night.rr, ...extra.rr];
    final appendedRrTs = [
      ...night.rrTs,
      for (final ts in extra.rrTs) ts + nightMs,
    ];
    CardioRowCache? cache;
    void warmNight() {
      cache = CardioRowCache();
      cardioStager(night.hr, night.accel,
          rrMs: night.rr, rrTsMs: night.rrTs, rowCache: cache);
    }
    final coldUs = _medianUs(() => cardioStager(night.hr, night.accel,
        rrMs: night.rr, rrTsMs: night.rrTs, rowCache: CardioRowCache()),
        runs: 1);
    final warmUs = _medianPreparedUs(warmNight, () => cardioStager(
        night.hr, night.accel,
        rrMs: night.rr, rrTsMs: night.rrTs, rowCache: cache), runs: 1);
    final appendedUs = _medianPreparedUs(warmNight, () => cardioStager(
        appendedHr, appendedAccel,
        rrMs: appendedRr, rrTsMs: appendedRrTs, rowCache: cache), runs: 1);
    print('cardio cache (8 h) cold us       $coldUs');
    print('cardio cache (8 h) warm us       $warmUs');
    print('cardio cache warm +15 min us     $appendedUs');
  }
  if (args.isEmpty || selected.contains('welch')) _welchStreamBench();
  print('parity: frozen references == production: $parity');
  if (!parity) {
    throw StateError('frozen-reference parity failed');
  }
}
