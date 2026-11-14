// Before/after for two night metrics edge re-runs on every pass: the 30-min
// RSA bins behind breathing-rate variability (edge `_respPerWindow`, copied
// here) and PRSA deceleration/acceleration capacity. 32 passes of 15 min; each
// pass folds the newly settled beats and asks with a ~100-beat provisional
// tail. "After" keeps closed bins' rates and folds PRSA with prsaAggregator.

import 'dart:typed_data';

import 'package:openstrap_analytics/aggregate.dart';
import 'package:openstrap_analytics/onehz.dart';
import '../test/onehz/phase0_parity_test.dart' as frozen;

const _windowMs = 1800000.0;

/// Edge's `_respPerWindow`, verbatim apart from the name.
List<double> batchBins(List<double> nn, List<double> nnTimes) {
  if (nn.isEmpty || nn.length != nnTimes.length) return const [];
  final t0 = nnTimes.first;
  final binsNn = <int, List<double>>{};
  final binsTs = <int, List<double>>{};
  for (var i = 0; i < nn.length; i++) {
    final idx = ((nnTimes[i] - t0) / _windowMs).floor();
    (binsNn[idx] ??= <double>[]).add(nn[i]);
    (binsTs[idx] ??= <double>[]).add(nnTimes[i]);
  }
  final out = <double>[];
  final idxs = binsNn.keys.toList()..sort();
  for (final idx in idxs) {
    final segNn = binsNn[idx]!;
    if (segNn.length < 60) continue;
    final r = rsaRespRate(segNn, binsTs[idx]!, artifactFraction: 0.0);
    final b = r.present ? r.value!.brpm : null;
    if (b != null) out.add(b);
  }
  return out;
}

/// Closed bins (a settled beat exists in a later bin) are scored once.
class BinStream {
  final closed = <double>[];
  final _openNn = <double>[], _openTs = <double>[];
  double? _t0;
  int _openIdx = 0;

  int _idx(double t) => ((t - _t0!) / _windowMs).floor();

  void _close() {
    if (_openNn.isNotEmpty) closed.addAll(batchBinsFrom(_openNn, _openTs));
    _openNn.clear();
    _openTs.clear();
  }

  // One bin's rate, through the batch on that bin alone.
  List<double> batchBinsFrom(List<double> nn, List<double> ts) {
    if (nn.length < 60) return const [];
    final r = rsaRespRate(nn, ts, artifactFraction: 0.0);
    return r.present && r.value!.brpm != null ? [r.value!.brpm!] : const [];
  }

  void fold(List<double> nn, List<double> ts) {
    for (var i = 0; i < nn.length; i++) {
      _t0 ??= ts[i];
      final k = _idx(ts[i]);
      if (k != _openIdx) {
        _close();
        _openIdx = k;
      }
      _openNn.add(nn[i]);
      _openTs.add(ts[i]);
    }
  }

  List<double> snapshot(List<double> tailNn, List<double> tailTs) {
    if (_t0 == null) return batchBins(tailNn, tailTs);
    final out = [...closed];
    var nn = [..._openNn], ts = [..._openTs];
    var k = _openIdx;
    for (var i = 0; i < tailNn.length; i++) {
      final j = _idx(tailTs[i]);
      if (j != k) {
        out.addAll(batchBinsFrom(nn, ts));
        nn = [];
        ts = [];
        k = j;
      }
      nn.add(tailNn[i]);
      ts.add(tailTs[i]);
    }
    out.addAll(batchBinsFrom(nn, ts));
    return out;
  }
}

bool _sameList(List<double> a, List<double> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _samePrsa(Metric<PrsaResult> a, Metric<PrsaResult> b) {
  if (a.present != b.present || a.note != b.note) return false;
  if (!a.present) return true;
  final x = a.value!, y = b.value!;
  return x.capacity == y.capacity &&
      x.anchors == y.anchors &&
      _sameList(x.profile, y.profile) &&
      a.confidence == b.confidence;
}

void main() {
  final night = frozen.genBeats(9031, 33000, period: 55, amp: 60);
  final bins = BinStream();
  final dcAgg = prsaAggregator(deceleration: true);
  final acAgg = prsaAggregator(deceleration: false);
  Object? dc = dcAgg.empty(), ac = acAgg.empty();
  var from = 0, parity = true;
  var binsAfter = 0, binsBefore = 0, prsaAfter = 0, prsaBefore = 0;
  final start = night.tMs.first;
  print('pass  bins after/before us  prsa after/before us  parity');
  for (var pass = 1; pass <= 32; pass++) {
    final until = start + pass * 15 * 60 * 1000.0;
    var end = from;
    while (end < night.nn.length && night.tMs[end] <= until) {
      end++;
    }
    if (end == from) continue;
    final tailEnd = (end + 100).clamp(0, night.nn.length);
    final tailNn = night.nn.sublist(end, tailEnd);
    final tailTs = night.tMs.sublist(end, tailEnd);
    final allNn = night.nn.sublist(0, tailEnd);
    final allTs = night.tMs.sublist(0, tailEnd);

    var w = Stopwatch()..start();
    bins.fold(night.nn.sublist(from, end), night.tMs.sublist(from, end));
    final b1 = bins.snapshot(tailNn, tailTs);
    final bA = w.elapsedMicroseconds;
    w = Stopwatch()..start();
    final b0 = batchBins(allNn, allTs);
    final bB = w.elapsedMicroseconds;

    w = Stopwatch()..start();
    final settled = DoubleColumn(Float64List.fromList(night.nn.sublist(from, end)));
    dc = dcAgg.addSlice(dc, settled, 0, settled.length);
    ac = acAgg.addSlice(ac, settled, 0, settled.length);
    final tail = DoubleColumn(Float64List.fromList(tailNn));
    Metric<PrsaResult> snap(
        Aggregator<dynamic, DoubleColumn, Metric<PrsaResult>> agg, Object? s) {
      final copy = agg.decodeState(agg.encodeState(s));
      return agg.finish(agg.addSlice(copy, tail, 0, tail.length));
    }

    final dc1 = snap(dcAgg, dc), ac1 = snap(acAgg, ac);
    final pA = w.elapsedMicroseconds;
    w = Stopwatch()..start();
    final dc0 = decelerationCapacity(allNn), ac0 = accelerationCapacity(allNn);
    final pB = w.elapsedMicroseconds;
    from = end;

    final same = _sameList(b1, b0) && _samePrsa(dc1, dc0) && _samePrsa(ac1, ac0);
    parity = parity && same;
    binsAfter += bA;
    binsBefore += bB;
    prsaAfter += pA;
    prsaBefore += pB;
    print('${pass.toString().padLeft(4)}  ${'$bA/$bB'.padLeft(18)}  '
        '${'$pA/$pB'.padLeft(18)}  $same');
  }
  print('total bins after $binsAfter us, before $binsBefore us; '
      'prsa after $prsaAfter us, before $prsaBefore us; parity $parity');
  if (!parity) throw StateError('parity failed');
}
