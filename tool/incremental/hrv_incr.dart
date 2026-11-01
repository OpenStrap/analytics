// RESEARCH PROTOTYPES — incremental HRV scalars and curves.
//
// Common shape: `fold(settled input)` mutates the carried state; `evaluate`
// / `curve` answers for "settled + provisional tail" WITHOUT mutating it (the
// tail is re-evaluated on a copy). The settled input is what RrCorrector.fold
// returns; the provisional tail is RrSnapshot.tailNn/tailNnTimes.
import 'dart:math' as math;

import 'dart:typed_data';

import 'package:openstrap_analytics/aggregate.dart' show Beats;
import 'package:openstrap_analytics/onehz.dart'
    hide RrCorrector, RrSettled, RrSnapshot, IrregularScreenState;
import 'package:openstrap_analytics/src/onehz/clinical/hrv_jitter_evidence.dart';

// ===========================================================================
// 1. hrvTime scalars: RMSSD, pNN50, SDNN, SDANN, SDNN-index, diffAcf1
// ===========================================================================
//
// RMSSD/pNN50/pairs: sums of d*d, count of |d|>50 taken in beat order are the
// SAME float sequence as the batch loop, so they are BIT-identical.
// SDNN: Welford instead of the batch's two-pass (mean, then sum (x-m)^2) —
//   agrees to ~1e-13 relative, NOT bit-identical (a two-pass over the whole
//   series cannot be folded).
// ACF1: algebraic form from (n, S1, S2, P, E, L); ~1e-14 absolute. The jitter
//   gate (acf1 < -0.35) can only differ when |acf1 + 0.35| < ~1e-12.
// SDANN/SDNN-index: the 5-min segments close for good once a later beat
//   arrives; their (mean, sd) are computed ONCE with the batch's own
//   mean()/stddev() => bit-identical, and the final stddev(means)/mean(sds)
//   run over <= 288 numbers with the batch's own functions.
class HrvTimeAcc {
  int n = 0;
  double prevNn = 0, prevT = 0, t0 = 0;
  double wMean = 0, wM2 = 0;
  int pairs = 0, over50 = 0, lagPairs = 0;
  double ssd = 0, s1 = 0, s2 = 0, prod = 0, endp = 0;
  double? lastDiff;
  int segIdx = 0;
  List<double> cur = [];
  List<double> segMeans = [], segSds = [];
  // Under the ACF floor hrvTime reads the difference runs (noise-share
  // exemption, breathing-line fallback): the library's mergeable evidence for
  // them, fed beat by beat (origin = the first beat).
  JitterState ev = JitterState();
  JitterEvidenceAggregator? _evAgg;

  HrvTimeAcc();

  HrvTimeAcc copy() {
    final c = HrvTimeAcc()
      ..n = n
      ..prevNn = prevNn
      ..prevT = prevT
      ..t0 = t0
      ..wMean = wMean
      ..wM2 = wM2
      ..pairs = pairs
      ..over50 = over50
      ..lagPairs = lagPairs
      ..ssd = ssd
      ..s1 = s1
      ..s2 = s2
      ..prod = prod
      ..endp = endp
      ..lastDiff = lastDiff
      ..segIdx = segIdx
      ..cur = List.of(cur)
      ..segMeans = List.of(segMeans)
      ..segSds = List.of(segSds)
      ..ev = ev.copy()
      .._evAgg = _evAgg;
    return c;
  }

  void add(double v, double t) {
    _evAgg ??= JitterEvidenceAggregator(originMs: t, gapAware: true);
    ev = _evAgg!.addSlice(
        ev, Beats(Float64List.fromList([v]), Float64List.fromList([t])), 0, 1);
    if (n == 0) {
      t0 = t;
    } else if (t - prevT > v + .5) {
      lastDiff = null; // seam: ends a diff run
    } else {
      final d = v - prevNn;
      pairs++;
      ssd += d * d;
      s1 += d;
      s2 += d * d;
      if (d.abs() > 50) over50++;
      if (lastDiff != null) {
        lagPairs++;
        prod += lastDiff! * d;
        endp += lastDiff! + d;
      }
      lastDiff = d;
    }
    n++;
    final dl = v - wMean;
    wMean += dl / n;
    wM2 += dl * (v - wMean);
    final idx = ((t - t0) / 300000.0).floor();
    if (idx != segIdx) {
      if (cur.length >= 2) {
        segMeans.add(mean(cur)!);
        segSds.add(stddev(cur)!);
      }
      cur = <double>[];
      segIdx = idx;
    }
    cur.add(v);
    prevNn = v;
    prevT = t;
  }

  void fold(List<double> nn, List<double> t) {
    for (var i = 0; i < nn.length; i++) {
      add(nn[i], t[i]);
    }
  }

  /// `hrvTime(settled ++ tail, nnTimesMs: ..., artifactFraction)`.
  Metric<HrvTime> evaluate(List<double> tailNn, List<double> tailT,
      {double artifactFraction = 0.0}) {
    final a = copy()..fold(tailNn, tailT);
    return a._finish(artifactFraction);
  }

  Metric<HrvTime> _finish(double artifactFraction) {
    const inputs = ['rr_cleaned'];
    if (n < 2) {
      return const Metric<HrvTime>.absent(
        tier: Tier.high,
        inputs_used: inputs,
        note: 'too few NN intervals',
      );
    }
    double? acf1;
    if (pairs >= 30) {
      final m = s1 / pairs;
      final varSum = s2 - m * s1;
      final cov = prod - m * endp + lagPairs * m * m;
      acf1 = varSum > 0 ? cov / varSum : null;
    }
    final evidence = acf1 != null && acf1 < kNnDiffAcf1Floor
        ? _evAgg!.finish(ev)
        : null;
    final jittery = evidence != null && evidence.refused();
    var rmssd = (pairs > 0 && !jittery) ? math.sqrt(ssd / pairs) : null;
    final pnn50 = (pairs > 0 && !jittery) ? 100.0 * over50 / pairs : null;
    if (jittery) rmssd = evidence.breathingRmssd();
    final byBreathing = jittery && rmssd != null;
    final sdnn = n >= 2 ? math.sqrt(wM2 / (n - 1)) : null;
    double? sdann, sdnnIndex;
    final means = [...segMeans], sds = [...segSds];
    if (cur.length >= 2) {
      means.add(mean(cur)!);
      sds.add(stddev(cur)!);
    }
    if (means.length >= 2) {
      sdann = stddev(means);
      sdnnIndex = sds.isEmpty ? null : mean(sds);
    }
    final q = acf1 == null ? 1.0 : (1 - acf1 / kNnDiffAcf1Floor).clamp(0.0, 1.0);
    final conf = byBreathing
        ? 0.3
        : ((n / 250.0).clamp(0.0, 1.0) * q * (1 - artifactFraction))
            .clamp(0.3, 0.95);
    return Metric<HrvTime>(
      value: HrvTime(
        rmssd: rmssd,
        sdnn: sdnn,
        sdann: sdann,
        sdnnIndex: sdnnIndex,
        pnn50: pnn50,
        nBeats: n,
        diffAcf1: acf1,
      ),
      confidence: conf,
      tier: Tier.high,
      inputs_used: inputs,
      note: jittery
          ? 'rmssd_refused:acf1=${acf1!.toStringAsFixed(3)} — the NN successive '
              'differences are essentially differenced white noise (−0.5 = pure, floor '
              '$kNnDiffAcf1Floor), so RMSSD/pNN50 would measure beat-timing jitter, not '
              'vagal tone. SDNN/SDANN survive it and are the lead here. '
              '${byBreathing ? 'RMSSD only from 5-min windows on a breathing '
                  'line steady in Hz, at floor confidence. ' : ''}PRV not ECG-HRV.'
          : 'PRV not ECG-HRV; RMSSD/pNN50 are quantization-sensitive at 1 Hz '
              '— lead with SDNN/SDANN',
    );
  }

  Map<String, dynamic> toJson() => {
        'n': n,
        'prevNn': prevNn,
        'prevT': prevT,
        't0': t0,
        'wMean': wMean,
        'wM2': wM2,
        'pairs': pairs,
        'over50': over50,
        'lagPairs': lagPairs,
        'ssd': ssd,
        's1': s1,
        's2': s2,
        'prod': prod,
        'endp': endp,
        'lastDiff': lastDiff,
        'segIdx': segIdx,
        'cur': cur,
        'segMeans': segMeans,
        'segSds': segSds,
        'ev': _evAgg == null ? null : _evAgg!.encodeState(ev),
      };

  factory HrvTimeAcc.fromJson(Map<String, dynamic> j) {
    List<double> dl(Object? o) => [for (final x in o as List) (x as num).toDouble()];
    return HrvTimeAcc()
      ..n = j['n'] as int
      ..prevNn = (j['prevNn'] as num).toDouble()
      ..prevT = (j['prevT'] as num).toDouble()
      ..t0 = (j['t0'] as num).toDouble()
      ..wMean = (j['wMean'] as num).toDouble()
      ..wM2 = (j['wM2'] as num).toDouble()
      ..pairs = j['pairs'] as int
      ..over50 = j['over50'] as int
      ..lagPairs = j['lagPairs'] as int
      ..ssd = (j['ssd'] as num).toDouble()
      ..s1 = (j['s1'] as num).toDouble()
      ..s2 = (j['s2'] as num).toDouble()
      ..prod = (j['prod'] as num).toDouble()
      ..endp = (j['endp'] as num).toDouble()
      ..lastDiff = (j['lastDiff'] as num?)?.toDouble()
      ..segIdx = j['segIdx'] as int
      ..cur = dl(j['cur'])
      ..segMeans = dl(j['segMeans'])
      ..segSds = dl(j['segSds'])
      .._restoreEvidence(j['ev']);
  }

  void _restoreEvidence(Object? e) {
    if (e == null || n == 0) return;
    _evAgg = JitterEvidenceAggregator(originMs: t0, gapAware: true);
    ev = _evAgg!.decodeState(e);
  }
}

// ===========================================================================
// 2. edge `_hrvTimeline`: trailing 5-min RMSSD of the corrected NN, >60 s apart
// ===========================================================================
// Right-context 0 over the NN list, so a point is final the moment its NN beat
// is settled. State = ring of the last 5 min of NN, first time, last emitted t.
class HrvTimelineState {
  final double originMs;
  List<double> _nn = [], _t = [];
  int _head = 0;
  double? _t0;
  int? _lastT;
  final List<Map<String, num>> out = [];

  HrvTimelineState(this.originMs);

  static double _round(double v, int dp) {
    final p = math.pow(10, dp);
    return (v * p).round() / p;
  }

  void _step(double v, double tm, List<Map<String, num>> sink) {
    _t0 ??= tm;
    _nn.add(v);
    _t.add(tm);
    while (tm - _t[_head] > 300000.0) {
      _head++;
    }
    if (tm - _t0! < 300000.0) return;
    final cnt = _nn.length - 1 - _head;
    if (cnt >= 10) {
      var ssd = 0.0;
      for (var k = _head + 1; k < _nn.length; k++) {
        final diff = _nn[k] - _nn[k - 1];
        ssd += diff * diff;
      }
      final rmssd = math.sqrt(ssd / cnt);
      final tSec = ((originMs + tm) / 1000).round();
      if (_lastT == null || tSec - _lastT! > 60) {
        sink.add({'t': tSec, 'v': _round(rmssd, 1)});
        _lastT = tSec;
      }
    }
  }

  void _trim() {
    if (_head > 512) {
      _nn = _nn.sublist(_head);
      _t = _t.sublist(_head);
      _head = 0;
    }
  }

  void fold(List<double> nn, List<double> t) {
    for (var i = 0; i < nn.length; i++) {
      _step(nn[i], t[i], out);
    }
    _trim();
  }

  /// settled points ++ provisional points from [tailNn].
  List<Map<String, num>> curve(List<double> tailNn, List<double> tailT) {
    final c = HrvTimelineState(originMs)
      .._nn = List.of(_nn)
      .._t = List.of(_t)
      .._head = _head
      .._t0 = _t0
      .._lastT = _lastT;
    final extra = <Map<String, num>>[];
    for (var i = 0; i < tailNn.length; i++) {
      c._step(tailNn[i], tailT[i], extra);
    }
    return [...out, ...extra];
  }
}

// ===========================================================================
// 3. nightHrvShape: per-30-min-bin RMSSD (+ band) over the night
// ===========================================================================
class NightShapeState {
  final double binMin;
  final int minBeatsPerBin;
  double? _t0;
  int _bin = 0;
  List<double> _nn = [], _t = [];
  int _count = 0;
  double _firstT = 0, _lastT = 0;
  // closed bins by index (holes included): [n, rmssd?, lo?, hi?]
  final List<List<num?>> closed = [];

  NightShapeState({this.binMin = 30, this.minBeatsPerBin = kMinBeatsPerHrvBin});

  double get _binMs => binMin * 60000.0;
  double _hi(int b) => _t0! + (b + 1) * _binMs;

  static List<num?> _binValue(
      List<double> nn, List<double> t, int minBeats) {
    final n = nn.length;
    if (n < minBeats) return [n, null, null, null];
    final m = hrvTime(nn, nnTimesMs: t);
    final rmssd = m.value?.rmssd;
    final se = rmssd == null ? null : rmssd / math.sqrt(2 * n);
    return [
      n,
      rmssd,
      se == null ? null : math.max(0.0, rmssd! - 1.96 * se),
      se == null ? null : rmssd! + 1.96 * se,
    ];
  }

  void _step(double v, double tm, List<List<num?>> sink) {
    if (_t0 == null) {
      _t0 = tm;
      _firstT = tm;
    }
    _lastT = tm;
    _count++;
    while (tm >= _hi(_bin)) {
      sink.add(_binValue(_nn, _t, minBeatsPerBin));
      _nn = [];
      _t = [];
      _bin++;
    }
    _nn.add(v);
    _t.add(tm);
  }

  void fold(List<double> nn, List<double> t) {
    for (var i = 0; i < nn.length; i++) {
      _step(nn[i], t[i], closed);
    }
  }

  Metric<NightHrvShape> evaluate(List<double> tailNn, List<double> tailT) {
    const inputs = ['rr_cleaned', 'beat_times'];
    final c = NightShapeState(binMin: binMin, minBeatsPerBin: minBeatsPerBin)
      .._t0 = _t0
      .._bin = _bin
      .._nn = List.of(_nn)
      .._t = List.of(_t)
      .._count = _count
      .._firstT = _firstT
      .._lastT = _lastT
      ..closed.addAll(closed);
    for (var i = 0; i < tailNn.length; i++) {
      c._step(tailNn[i], tailT[i], c.closed);
    }
    final total = c._count;
    if (total < minBeatsPerBin) {
      return Metric<NightHrvShape>.absent(
        tier: Tier.high,
        inputs_used: inputs,
        note: 'too few beats for a nightly shape '
            '($total, need ≥$minBeatsPerBin)',
      );
    }
    final binMs = _binMs;
    final span = c._lastT - c._firstT;
    final nBins = math.max(1, (span / binMs).ceil());
    if (nBins < 3) {
      return Metric<NightHrvShape>.absent(
        tier: Tier.high,
        inputs_used: inputs,
        note:
            'night spans ${(span / 3600000).toStringAsFixed(1)} h — under three '
            '${binMin.round()}-min bins there is no shape to describe',
      );
    }
    final bins = <NightHrvBin>[];
    for (var b = 0; b < nBins; b++) {
      final List<num?> v = b < c.closed.length
          ? c.closed[b]
          : (b == c._bin
              ? _binValue(c._nn, c._t, minBeatsPerBin)
              : [0, null, null, null]);
      bins.add(NightHrvBin(
        startSec: (b * binMs / 1000).round(),
        nBeats: v[0]!.toInt(),
        rmssdMs: v[1]?.toDouble(),
        loMs: v[2]?.toDouble(),
        hiMs: v[3]?.toDouble(),
      ));
    }
    final third = bins.length ~/ 3;
    double? meanOf(Iterable<NightHrvBin> xs) {
      final v = [
        for (final b in xs)
          if (b.present) b.rmssdMs!
      ];
      return v.length < 2 ? null : mean(v);
    }

    final first = meanOf(bins.take(third));
    final last = meanOf(bins.skip(bins.length - third));
    final ratio =
        (first == null || last == null || first == 0) ? null : last / first;
    return Metric<NightHrvShape>(
      value: NightHrvShape(
        bins: bins,
        firstThirdMs: first,
        lastThirdMs: last,
        lastOverFirst: ratio,
      ),
      confidence: (0.8 * bins.where((b) => b.present).length / bins.length)
          .clamp(0.0, 0.8),
      tier: Tier.high,
      inputs_used: inputs,
      note: 'per-bin RMSSD (${binMin.round()}-min bins, PRV not ECG-HRV) — a '
          'DESCRIPTION of the night, never a cause. A low first third is equally '
          'consistent with alcohol, a late meal, late training, a warm room, '
          'illness onset, or nothing. Render each bin as a band, not a point.',
    );
  }
}

// ===========================================================================
// 4. edge `dayHrvCurve`: trailing 5-min RMSSD on gated RR, emitted every 60 s
// ===========================================================================
// Right-context 0. Exact append-only. State: ring of gated beats of the last
// 5 min, lastEmit, emitted list. (Works on raw substrate RR, not on NN.)
class DayHrvCurveState {
  List<double> _ts = [], _rr = [];
  int _head = 0;
  double _lastEmit = -1e18;
  final List<Map<String, num>> out = [];

  DayHrvCurveState();

  void fold(List<double> rrMs, List<double> rrTsMs) {
    for (var q = 0; q < rrMs.length; q++) {
      final v = rrMs[q];
      if (!(v >= 300 && v <= 2000)) continue;
      _ts.add(rrTsMs[q]);
      _rr.add(v);
      final i = _ts.length - 1;
      while (_ts[i] - _ts[_head] > 300000.0) {
        _head++;
      }
      if (i - _head >= 10 && _ts[i] - _lastEmit > 60000) {
        double? value;
        var ssd = 0.0;
        var nd = 0;
        for (var k = _head + 1; k <= i; k++) {
          final d = _rr[k] - _rr[k - 1];
          if (d.abs() > 0.20 * _rr[k - 1] || d.abs() > 200) continue;
          ssd += d * d;
          nd++;
        }
        if (nd >= 8) {
          final rmssd = math.sqrt(ssd / nd);
          value = rmssd <= 220 ? double.parse(rmssd.toStringAsFixed(1)) : null;
        }
        _lastEmit = _ts[i];
        if (value != null) out.add({'t': (_ts[i] / 1000).round(), 'v': value});
      }
    }
    if (_head > 512) {
      _ts = _ts.sublist(_head);
      _rr = _rr.sublist(_head);
      _head = 0;
    }
  }

  int get ringSize => _ts.length - _head;

  Map<String, dynamic> toJson() => {
        'ts': _ts.sublist(_head),
        'rr': _rr.sublist(_head),
        'lastEmit': _lastEmit,
        'out': out,
      };

  factory DayHrvCurveState.fromJson(Map<String, dynamic> j) {
    final s = DayHrvCurveState();
    s._ts = [for (final x in j['ts'] as List) (x as num).toDouble()];
    s._rr = [for (final x in j['rr'] as List) (x as num).toDouble()];
    s._lastEmit = (j['lastEmit'] as num).toDouble();
    for (final m in j['out'] as List) {
      final mm = m as Map;
      s.out.add({'t': mm['t'] as num, 'v': mm['v'] as num});
    }
    return s;
  }
}

// ===========================================================================
// 5. edge `_daytimeHrv`: 5-min bins of squared successive differences over
//    quiet seconds, outside the (known) sleep window
// ===========================================================================
// Each pair (prev, v) lands in bin tSec~/300 and only needs (a) whether the
// second of each beat is quiet and (b) the previous beat in the quiet chain.
// State: per-bin (sum of d^2, count) in beat order, the chain's `prev`, quiet
// seconds near the head, pending beats whose second the accelerometer has not
// reported yet (watermark). Sleep window fixed at construction; a changed
// window means refold (only bins straddling onset/offset differ — see report).
class DaytimeHrvState {
  final int onsetSec, offsetSec;
  final double cut;
  final Map<int, double> _sum = {};
  final Map<int, int> _cnt = {};
  double? _prev;
  final Set<int> _quiet = {};
  final List<double> _pendRr = [], _pendTs = [];
  int _maxBeatSec = 0;

  DaytimeHrvState(this.onsetSec, this.offsetSec, {this.cut = 0.02});

  static bool _isQuiet(double ax, double ay, double az, double cut) {
    final magSq = ax * ax + ay * ay + az * az;
    if (!(magSq > 0 && magSq <= 16.0)) return false;
    final mag = math.sqrt(ax * ax + ay * ay + az * az);
    return (mag - 1.0).abs() <= cut;
  }

  /// [watermarkSec]: every accel row with tsSec < watermarkSec has been given.
  void fold(List<double> rrMs, List<double> rrTsMs, List<int> accTs,
      List<double> ax, List<double> ay, List<double> az, int watermarkSec) {
    for (var i = 0; i < accTs.length; i++) {
      if (_isQuiet(ax[i], ay[i], az[i], cut)) _quiet.add(accTs[i]);
    }
    _pendRr.addAll(rrMs);
    _pendTs.addAll(rrTsMs);
    var used = 0;
    for (; used < _pendRr.length; used++) {
      final tSec = _pendTs[used] ~/ 1000;
      if (tSec >= watermarkSec) break; // second not fully known yet
      _beat(_pendRr[used], tSec);
    }
    _pendRr.removeRange(0, used);
    _pendTs.removeRange(0, used);
    // forget quiet seconds far behind the head (RR is time-ordered)
    if (_quiet.length > 4000) {
      final keep = _maxBeatSec - 120;
      _quiet.removeWhere((s) => s < keep);
    }
  }

  void _beat(double v, int tSec) {
    if (tSec > _maxBeatSec) _maxBeatSec = tSec;
    if (offsetSec > onsetSec && tSec >= onsetSec && tSec < offsetSec) {
      _prev = null;
      return;
    }
    if (!_quiet.contains(tSec)) {
      _prev = null;
      return;
    }
    if (v < 300 || v > 2000) {
      _prev = null;
      return;
    }
    if (_prev != null) {
      final d = v - _prev!;
      if (d.abs() <= 200) {
        final b = tSec ~/ 300;
        _sum[b] = (_sum[b] ?? 0.0) + d * d;
        _cnt[b] = (_cnt[b] ?? 0) + 1;
      }
    }
    _prev = v;
  }

  Map<String, dynamic> result() {
    final timeline = <Map<String, dynamic>>[];
    final means = <double>[];
    final keys = _sum.keys.toList()..sort();
    for (final b in keys) {
      final n = _cnt[b]!;
      if (n < 5) continue;
      final rmssd = math.sqrt(_sum[b]! / n);
      timeline.add({'t': b * 300, 'rmssd': (rmssd * 10).round() / 10.0, 'n': n});
      means.add(rmssd);
    }
    final mean = means.isEmpty ? null : means.reduce((a, c) => a + c) / means.length;
    return {
      'timeline': timeline,
      'mean_rmssd': mean == null ? null : (mean * 10).round() / 10.0,
      'n_buckets': timeline.length,
    };
  }

  int get pending => _pendRr.length;

  Map<String, dynamic> toJson() => {
        'sum': {for (final e in _sum.entries) '${e.key}': e.value},
        'cnt': {for (final e in _cnt.entries) '${e.key}': e.value},
        'prev': _prev,
        'quiet': _quiet.toList(),
        'pendRr': _pendRr,
        'pendTs': _pendTs,
        'maxBeatSec': _maxBeatSec,
      };

  factory DaytimeHrvState.fromJson(
      Map<String, dynamic> j, int onsetSec, int offsetSec,
      {double cut = 0.02}) {
    final s = DaytimeHrvState(onsetSec, offsetSec, cut: cut);
    (j['sum'] as Map).forEach((k, v) => s._sum[int.parse(k as String)] = (v as num).toDouble());
    (j['cnt'] as Map).forEach((k, v) => s._cnt[int.parse(k as String)] = v as int);
    s._prev = (j['prev'] as num?)?.toDouble();
    s._quiet.addAll((j['quiet'] as List).cast<int>());
    s._pendRr.addAll([for (final x in j['pendRr'] as List) (x as num).toDouble()]);
    s._pendTs.addAll([for (final x in j['pendTs'] as List) (x as num).toDouble()]);
    s._maxBeatSec = j['maxBeatSec'] as int;
    return s;
  }
}

// ===========================================================================
// 6. nocturnalRmssd (median of 5-min window RMSSDs) and
//    sleepSessionWindowedRmssd (mean of cleaned 5-min window RMSSDs)
// ===========================================================================
// Both are "closed windows" estimators: a window's RMSSD is a pure function of
// the beats inside it, and the headline is an order-statistic / mean over the
// <= ~100 window values. State = per-window record. The stage mask (nocturnal)
// and the session bounds (session) are applied at READ time over those records,
// so a re-staged night does not invalidate them.
//
// Upstream's jitter gate is no longer a pooled ACF1 alone: a night below the
// ACF1 floor can still pass on a respiratory line in the pooled spectrum (then
// every window must clear the gate itself), or, as a last resort, on the
// windows whose breathing line holds still in Hz. Those need each window's
// difference RUNS, not additive sums, so a record keeps its runs (a window
// holds a few hundred differences) and the gate is the batch's own code over
// them, bit-identical.

/// One closed window. [kind]: 0 usable, 1 over-counted (more beat-time than
/// the window has), 2 thin (fewer differences than the floor). Only a usable
/// window carries [rmssd], [runs] and [meanRr].
class _WinRec {
  final int idx;
  final int kind;
  final double rmssd;
  final List<List<double>> runs;
  final double meanRr;
  _WinRec(this.idx, this.kind, this.rmssd, this.runs, this.meanRr);
  _WinRec.dropped(this.idx, this.kind)
      : rmssd = double.nan,
        runs = const [],
        meanRr = double.nan;
  Object toJson() => [idx, kind, rmssd.isFinite ? rmssd : null, runs,
        meanRr.isFinite ? meanRr : null];
}

/// Σd² and the count of [runs], summed in the batch's order.
(double, int) _ssdOf(List<List<double>> runs) {
  var ssd = 0.0;
  var nd = 0;
  for (final r in runs) {
    for (final d in r) {
      ssd += d * d;
      nd++;
    }
  }
  return (ssd, nd);
}

class NocturnalRmssdState {
  final double windowMs;
  final int minBeatsPerWindow;
  double? _t0;
  int _idx = 0;
  List<double> _nn = [], _t = [];
  final List<_WinRec> recs = [];

  NocturnalRmssdState({this.windowMs = 300000.0, this.minBeatsPerWindow = 5});

  _WinRec? _close(int idx, List<double> nn, List<double> t) {
    if (nn.length < minBeatsPerWindow + 1) return null;
    final winRuns = <List<double>>[];
    var run = <double>[];
    for (var k = 1; k < nn.length; k++) {
      if (t[k] - t[k - 1] > nn[k] + 0.5) {
        if (run.isNotEmpty) {
          winRuns.add(run);
          run = <double>[];
        }
        continue;
      }
      run.add(nn[k] - nn[k - 1]);
    }
    if (run.isNotEmpty) winRuns.add(run);
    final (ssd, nd) = _ssdOf(winRuns);
    if (nd < minBeatsPerWindow) return null;
    return _WinRec(idx, 0, math.sqrt(ssd / nd), winRuns, mean(nn)!);
  }

  void _step(double v, double tm, List<_WinRec> sink) {
    _t0 ??= tm;
    final idx = ((tm - _t0!) / windowMs).floor();
    if (idx != _idx && _nn.isNotEmpty) {
      final r = _close(_idx, _nn, _t);
      if (r != null) sink.add(r);
      _nn = [];
      _t = [];
    }
    _idx = idx;
    _nn.add(v);
    _t.add(tm);
  }

  int _count = 0;
  void fold(List<double> nn, List<double> t) {
    for (var i = 0; i < nn.length; i++) {
      _step(nn[i], t[i], recs);
    }
    _count += nn.length;
  }

  Metric<double> evaluate(List<double> tailNn, List<double> tailT,
      {List<bool>? stageMaskPerSec, RrCoverage? coverage}) {
    const inputs = ['rr_cleaned', 'beat_times'];
    if (coverage != null && coverage.overCounted) {
      return Metric<double>.absent(
        tier: Tier.high,
        inputs_used: inputs,
        note: rrOvercountNote(coverage),
      );
    }
    final c = NocturnalRmssdState(
        windowMs: windowMs, minBeatsPerWindow: minBeatsPerWindow)
      .._t0 = _t0
      .._idx = _idx
      .._nn = List.of(_nn)
      .._t = List.of(_t)
      ..recs.addAll(recs);
    for (var i = 0; i < tailNn.length; i++) {
      c._step(tailNn[i], tailT[i], c.recs);
    }
    final total = _count + tailNn.length;
    if (total < minBeatsPerWindow + 1) {
      return const Metric<double>.absent(
        tier: Tier.high,
        inputs_used: inputs,
        note: 'too few NN intervals for windowed nocturnal RMSSD',
      );
    }
    final all = [...c.recs];
    final open = c._close(c._idx, c._nn, c._t);
    if (open != null) all.add(open);
    final rmssds = <double>[];
    final runs = <List<double>>[];
    final perWindow = <List<List<double>>>[];
    final meanRr = <double>[];
    for (final r in all) {
      if (stageMaskPerSec != null) {
        final midSec = ((r.idx + 0.5) * windowMs / 1000.0).floor();
        final keep = midSec >= 0 &&
            midSec < stageMaskPerSec.length &&
            stageMaskPerSec[midSec];
        if (!keep) continue;
      }
      rmssds.add(r.rmssd);
      runs.addAll(r.runs);
      perWindow.add(r.runs);
      meanRr.add(r.meanRr);
    }
    final acf1 = nnDiffAcf1(runs);
    final refused = _jitterRefused(acf1, runs);
    if (rmssds.isEmpty && !refused) {
      return const Metric<double>.absent(
        tier: Tier.high,
        inputs_used: inputs,
        note: 'no usable 5-min windows for nocturnal RMSSD',
      );
    }
    final kept = _keptWindows(acf1, refused, rmssds, perWindow, meanRr);
    if (kept == null) {
      return Metric<double>.absent(
        tier: Tier.high,
        inputs_used: inputs,
        note: refused
            ? _jitterNote(acf1!)
            : '${_jitterNote(acf1!)}; no 5-min window clears it on its own',
      );
    }
    final robust = median(kept.rmssds)!;
    final conf = kept.byBreathing
        ? 0.3
        : ((kept.rmssds.length / 12.0).clamp(0.0, 1.0) * _acf1Quality(acf1))
            .clamp(0.3, 0.95);
    return Metric<double>(
      value: robust,
      confidence: conf,
      tier: Tier.high,
      inputs_used: inputs,
      note: 'robust nocturnal RMSSD = MEDIAN of ${kept.rmssds.length} consecutive '
          '5-min-window RMSSDs (REM/arousal-robust). PRV not ECG-HRV; '
          'RMSSD is quantization-sensitive at 1 Hz.${kept.note}',
    );
  }
}

// ---- verbatim copies of hrv_time.dart's private RMSSD gate (private there) --
/// True when every successive difference is a whole multiple of one step q and
/// the mean squared difference is under 2q². Beat times rounded to a grid q
/// make RR a two-level sequence on a near-constant heart: its differences are
/// 0 or ±q, a deterministic sawtooth at frac(RR/q) cycles/beat, so it reads as
/// one clean line and the white-floor test cannot see it. Rounding alone puts
/// mean(d²) at 2·min(f, 1−f)·q² ≤ q², so under 2q² the grid, not the heart,
/// sets RMSSD.
// ponytail: exact lattice only; a grid re-rounded to whole ms (7.8 ms → 7/8)
// breaks the common step and is not caught.
bool _onCoarseLattice(List<List<double>> diffRuns, double msd) {
  var q = double.infinity;
  for (final r in diffRuns) {
    for (final d in r) {
      if (d.abs() > 1e-6 && d.abs() < q) q = d.abs();
    }
  }
  if (q.isInfinite || msd >= 2 * q * q) return false;
  for (final r in diffRuns) {
    for (final d in r) {
      final k = d.abs() / q;
      if ((k - k.roundToDouble()).abs() > 1e-3) return false;
    }
  }
  return true;
}

/// The one RMSSD jitter verdict every path shares: ACF1 below the floor AND
/// the spectrum does not show a respiratory line on a low white floor.
bool _jitterRefused(double? acf1, List<List<double>> runs,
    {int minSegments = 20}) {
  if (acf1 == null || acf1 >= kNnDiffAcf1Floor) return false;
  final share = nnDiffNoiseShare(runs, minSegments: minSegments);
  return share == null || share >= kNnDiffNoiseShareCeiling;
}

/// One 5-min window judged on its own: a measured ACF1 at or above the floor,
/// or its own spectral line (4 segments is what a window at HR ~40 holds).
bool _windowClears(List<List<double>> runs) {
  final a = nnDiffAcf1(runs);
  return a != null && !_jitterRefused(a, runs, minSegments: 4);
}

/// The window RMSSDs a headline may use. A night that cleared the floor
/// outright keeps them all. One that only passed through the spectral
/// exemption proved a line somewhere in the pooled power, not in every window:
/// quiet jitter-only windows can win the median or dilute the mean while a few
/// loud breathing windows carry the pooled share. There every window has to
/// clear the gate itself.
List<double> _clearedWindows(double? nightAcf1, List<double> rmssds,
    List<List<List<double>>> winRuns) {
  if (nightAcf1 == null || nightAcf1 >= kNnDiffAcf1Floor) return rmssds;
  return [
    for (var i = 0; i < rmssds.length; i++)
      if (_windowClears(winRuns[i])) rmssds[i]
  ];
}

final _hann128 = [
  for (var i = 0; i < 128; i++) 0.5 - 0.5 * math.cos(2 * math.pi * i / 127)
];
final _hann128Sq = _hann128.fold(0.0, (a, w) => a + w * w);

/// Welch power (128-beat Hann, 50 % overlap, averaged over segments) of one
/// window's RR, rebuilt from its difference runs, at cycles-per-beat
/// frequencies [f]. Null when no run holds a full segment.
List<double>? _windowPsd(List<List<double>> diffRuns, List<double> f) {
  const n = 128;
  final p = List<double>.filled(f.length, 0.0);
  var segs = 0;
  for (final r in diffRuns) {
    final x = List<double>.filled(r.length + 1, 0.0);
    for (var i = 0; i < r.length; i++) {
      x[i + 1] = x[i] + r[i];
    }
    for (var s = 0; s + n <= x.length; s += n ~/ 2) {
      var m = 0.0;
      for (var i = 0; i < n; i++) {
        m += x[s + i];
      }
      m /= n;
      for (var j = 0; j < f.length; j++) {
        final c = math.cos(2 * math.pi * f[j]), sn = math.sin(2 * math.pi * f[j]);
        var cr = 1.0, ci = 0.0, re = 0.0, im = 0.0;
        for (var i = 0; i < n; i++) {
          final v = (x[s + i] - m) * _hann128[i];
          re += v * cr;
          im += v * ci;
          final t = cr * c - ci * sn;
          ci = cr * sn + ci * c;
          cr = t;
        }
        p[j] += re * re + im * im;
      }
      segs++;
    }
  }
  return segs == 0 ? null : [for (final v in p) v / segs];
}

/// Last resort for a night the jitter gate refused: the windows whose
/// breathing line holds still in Hz while the heart rate moves.
///
/// RSA follows breathing (Hirsch & Bishop 1981), a rate in breaths per
/// minute, so its line sits at a fixed frequency in Hz; a heart rate that
/// drifts across the night slides it in cycles per beat. Beat-timing jitter,
/// alternation and grid artifacts are tied to the beat, not the clock. So each
/// 5-min window's spectrum is pooled twice, once on a cycles-per-beat axis and
/// once rescaled by its own mean RR onto a Hz axis, and the night passes only
/// when the Hz pooling shows a line in 8–30 br/min that is sharper than the
/// beat pooling. If the heart rate barely moves the two poolings coincide and
/// the night stays refused: stability in Hz says nothing there.
///
/// Ceiling: needs >= 12 windows and a heart rate that wanders; breathing at
/// half the heart rate is still an alternation and still refused.
/// Returns the indices of the windows whose own peak sits on the line.
List<int>? _steadyBreathingWindows(
    List<List<List<double>>> winRuns, List<double> meanRrMs) {
  var ssd = 0.0, nd = 0;
  final all = [for (final w in winRuns) ...w];
  for (final r in all) {
    for (final d in r) {
      ssd += d * d;
      nd++;
    }
  }
  if (nd == 0 || _onCoarseLattice(all, ssd / nd)) return null;
  final ref = median([for (final m in meanRrMs) if (m > 0) m]);
  if (ref == null) return null;
  // 0.15–0.5 cycles/beat at the night's median beat.
  final fc = [for (var j = 38; j <= 128; j++) j / 256];
  final byBeat = List<double>.filled(fc.length, 0.0);
  final byHz = List<double>.filled(fc.length, 0.0);
  final cover = List<int>.filled(fc.length, 0);
  final peakHz = <int, double>{}; // window -> its own peak, cycles per ms
  final psd = <int, List<double>>{}; // window -> its cycles-per-beat PSD
  for (var w = 0; w < winRuns.length; w++) {
    if (meanRrMs[w] <= 0) continue;
    final pb = _windowPsd(winRuns[w], fc);
    if (pb == null) continue;
    final norm = median(pb)!;
    if (norm <= 0) continue;
    final k = meanRrMs[w] / ref;
    final fh = [for (final f in fc) f * k];
    final ph = _windowPsd(winRuns[w], fh)!;
    var best = -1;
    for (var j = 0; j < fc.length; j++) {
      byBeat[j] += pb[j] / norm;
      if (fh[j] > 0.5) continue;
      byHz[j] += ph[j] / norm;
      cover[j]++;
      if (best < 0 || ph[j] > ph[best]) best = j;
    }
    if (best >= 0) peakHz[w] = fc[best] / ref;
    psd[w] = pb;
  }
  final nw = peakHz.length;
  if (nw < 12) return null;
  final bins = [for (var j = 0; j < fc.length; j++) if (cover[j] == nw) j];
  if (bins.length < 20) return null;
  final hz = [for (final j in bins) byHz[j]];
  final bt = [for (final j in bins) byBeat[j]];
  var pk = 0;
  for (var i = 1; i < hz.length; i++) {
    if (hz[i] > hz[pk]) pk = i;
  }
  if (pk == 0 || pk == hz.length - 1) return null;
  final f0 = fc[bins[pk]] / ref;
  final brpm = f0 * 60000;
  if (brpm < 8 || brpm > 30) return null;
  // Same bins, same normalisation: the line must stand taller aligned in Hz
  // than the beat pooling stands anywhere within ±12 bins of it.
  var near = 0.0;
  for (var i = math.max(0, pk - 12); i <= math.min(bt.length - 1, pk + 12); i++) {
    near = math.max(near, bt[i]);
  }
  // The pooled noise ripple shrinks as 1/√windows, so the bar does too.
  final promHz = hz[pk] / median(hz)!;
  if (promHz < math.max(2.5, 1.5 + 7 / math.sqrt(nw))) return null;
  if (promHz < 1.1 * near / median(bt)!) return null;
  // Alternation lives at Nyquist on the beat axis, outside these bins.
  if (byBeat.last / median(bt)! >= 0.5 * promHz) return null;
  final keep = [
    for (final e in peakHz.entries)
      if (math.log(e.value / f0).abs() <= 0.15) e.key
  ];
  if (keep.length < 6) return null;
  // The line proves breathing is there, not that it carries RMSSD: beat-time
  // jitter loud enough to fail the gate would still be most of the number.
  // Same ceiling as [nnDiffNoiseShare], over the kept windows. Jitter σ² has
  // an RR spectrum σ²·(2 − 2cos ω), flat once divided by that shape, and its
  // differences carry 6σ²; physiology only adds power on top. Breathing
  // wanders across the night and its line spreads with it, so each window
  // drops the bins of every rate the kept windows peaked at (plus a Hann
  // main lobe), mapped onto its own beats. σ² is the floor of what is left,
  // pooled over windows and smoothed over four resolution cells.
  var lo = double.infinity, hi = 0.0;
  for (final w in keep) {
    lo = math.min(lo, peakHz[w]!);
    hi = math.max(hi, peakHz[w]!);
  }
  var sq = 0.0, nAll = 0;
  final acc = List<double>.filled(fc.length, 0.0);
  final wt = List<double>.filled(fc.length, 0.0);
  for (final w in keep) {
    var n = 0;
    for (final r in winRuns[w]) {
      for (final d in r) {
        sq += d * d;
        n++;
      }
    }
    nAll += n;
    final a = lo * meanRrMs[w] - 3 / 128, b = hi * meanRrMs[w] + 3 / 128;
    for (var j = 0; j < fc.length; j++) {
      if (fc[j] > a && fc[j] < b) continue;
      acc[j] += n * psd[w]![j] / (2 - 2 * math.cos(2 * math.pi * fc[j]));
      wt[j] += n;
    }
  }
  var floor = double.infinity;
  for (var j = 8; j < fc.length - 8; j++) {
    var s = 0.0, m = 0;
    for (var i = j - 8; i <= j + 8; i++) {
      if (wt[i] < nAll / 2) break;
      s += acc[i] / wt[i];
      m++;
    }
    if (m == 17) floor = math.min(floor, s / 17);
  }
  if (floor == double.infinity) return null;
  // The lowest stretch of a noisy curve reads below its mean; 1.1 puts the
  // floor back at these pooled sizes, so jitter alone is not undercounted.
  final noise = 1.1 * 6 * floor / _hann128Sq * nAll;
  return noise < kNnDiffNoiseShareCeiling * sq ? keep : null;
}

/// The window RMSSDs a windowed headline publishes, or null for none: the
/// usual gate first, and only when it leaves nothing, the windows on a
/// breathing line that holds still in Hz ([_steadyBreathingWindows]), which
/// publish at the confidence floor.
({List<double> rmssds, bool byBreathing, String note})? _keptWindows(
    double? acf1,
    bool refused,
    List<double> rmssds,
    List<List<List<double>>> winRuns,
    List<double> meanRrMs) {
  final kept = refused ? const <double>[] : _clearedWindows(acf1, rmssds, winRuns);
  if (kept.isNotEmpty) return (rmssds: kept, byBreathing: false, note: '');
  if (acf1 == null || acf1 >= kNnDiffAcf1Floor) return null;
  final idx = _steadyBreathingWindows(winRuns, meanRrMs);
  if (idx == null) return null;
  return (
    rmssds: [for (final i in idx) rmssds[i]],
    byBreathing: true,
    note: ' Jitter gate failed; kept the ${idx.length} windows on a breathing '
        'line steady in Hz while heart rate drifted, at floor confidence.',
  );
}

/// Confidence multiplier for a measured [acf1]: 1.0 on a smooth tachogram,
/// falling linearly to 0 at [kNnDiffAcf1Floor] so confidence bottoms out
/// exactly where RMSSD is refused. 1.0 when ACF1 could not be measured.
double _acf1Quality(double? acf1) =>
    acf1 == null ? 1.0 : (1 - acf1 / kNnDiffAcf1Floor).clamp(0.0, 1.0);

String _jitterNote(double acf1) =>
    'rmssd_refused:acf1=${acf1.toStringAsFixed(3)} — the NN successive '
    'differences are essentially differenced white noise (−0.5 = pure, floor '
    '$kNnDiffAcf1Floor), so RMSSD/pNN50 would measure beat-timing jitter, not '
    'vagal tone';

/// Intervals [rrCoverage] counts as beat-time, ms. Wider than the cleaners'
/// 2000 ms on purpose: a 2000–2400 ms beat is a slow heart (25–30 bpm), still
/// real elapsed time; only a glitch (e.g. a 65 535 ms sentinel) must not be
/// summed, or it would fake an over-count on a short span.
const double _rrCoverageMinMs = 300;
const double _rrCoverageMaxMs = 2400;

bool _rrCoverageCounts(double rrMs) =>
    rrMs >= _rrCoverageMinMs && rrMs <= _rrCoverageMaxMs;

// ---- verbatim copy of hrv_time.dart `_cleanWindowRuns` (private there) ----
List<List<double>> _cleanWindowRuns(List<double> rr, List<double> ts) {
  const radius = 2;
  const threshold = 0.20;
  // Range filter first, keeping each survivor's position in [rr] — BOTH filters
  // break a run, so neither one's compaction can manufacture a difference.
  final nn = <double>[];
  final at = <int>[];
  final nnTs = <double>[];
  for (var i = 0; i < rr.length; i++) {
    if (rr[i] >= 300 && rr[i] <= 2000) {
      nn.add(rr[i]);
      at.add(i);
      nnTs.add(ts[i]);
    }
  }
  final runs = <List<double>>[];
  var run = <double>[];
  var lastKept = -2;
  var lastTs = 0.0;
  for (var i = 0; i < nn.length; i++) {
    var keep = true;
    if (nn.length > radius) {
      final lo = math.max(0, i - radius);
      final hi = math.min(nn.length - 1, i + radius);
      final neighbors = <double>[];
      for (var j = lo; j <= hi; j++) {
        if (j != i) neighbors.add(nn[j]);
      }
      final med = neighbors.length < 2 ? null : median(neighbors);
      if (med != null && med > 0) keep = (nn[i] - med).abs() / med <= threshold;
    }
    if (!keep) {
      if (run.isNotEmpty) {
        runs.add(run);
        run = <double>[];
      }
      continue;
    }
    if (run.isNotEmpty &&
        (at[i] != lastKept + 1 || nnTs[i] - lastTs > nn[i] + 1000.0)) {
      runs.add(run);
      run = <double>[];
    }
    run.add(nn[i]);
    lastKept = at[i];
    lastTs = nnTs[i];
  }
  if (run.isNotEmpty) runs.add(run);
  return runs;
}

/// Raw-RR stream (NOT the corrected NN): a bucket is final the moment a beat of
/// a later bucket arrives. Session bounds fixed at construction.
class SessionRmssdState {
  final int startSec, endSec, windowSec, minDiffsPerWindow;
  int _idx = -1;
  List<double> _rr = [], _ts = [];
  final List<_WinRec> recs = [];
  int _seen = 0; // beats folded, in the session or not
  // Session-wide coverage (rrCoverage over the in-session beats), from
  // running figures: the earliest beat (first of equals) and its interval,
  // the latest beat time, and the plausible RR summed in input order.
  int _inN = 0;
  double _loTs = 0, _loRr = 0, _hiTs = 0, _sumRr = 0;
  int _implausible = 0;

  SessionRmssdState(this.startSec, this.endSec,
      {this.windowSec = 300, this.minDiffsPerWindow = kMinDiffsPerRmssdWindow});

  _WinRec _close(int idx, List<double> winRr, List<double> winTs) {
    // Per-window over-count, as the batch judges it.
    final winStart = startSec + idx * windowSec;
    final winSec = math.min(winStart + windowSec, endSec) - winStart;
    var bankedMs = 0.0;
    var lo = 0;
    for (var i = 0; i < winRr.length; i++) {
      if (winTs[i] < winTs[lo]) lo = i;
      if (_rrCoverageCounts(winRr[i])) bankedMs += winRr[i];
    }
    final overhangMs = _rrCoverageCounts(winRr[lo]) ? winRr[lo] : 0.0;
    if (bankedMs > kRrCoverageCeiling * (winSec * 1000 + overhangMs)) {
      return _WinRec.dropped(idx, 1);
    }
    final rrRuns = [
      for (final r in _cleanWindowRuns(winRr, winTs))
        if (r.length >= 2) r
    ];
    final diffRuns = [
      for (final r in rrRuns) [for (var i = 1; i < r.length; i++) r[i] - r[i - 1]]
    ];
    final (ssd, nd) = _ssdOf(diffRuns);
    if (nd < minDiffsPerWindow) return _WinRec.dropped(idx, 2);
    return _WinRec(idx, 0, math.sqrt(ssd / nd), diffRuns,
        mean([for (final r in rrRuns) ...r])!);
  }

  void _step(double rr, double ts, List<_WinRec> sink) {
    _seen++;
    final tsSec = (ts / 1000.0).round();
    if (tsSec < startSec || tsSec >= endSec) return;
    if (_inN == 0 || ts < _loTs) {
      _loTs = ts;
      _loRr = rr;
    }
    if (_inN == 0 || ts > _hiTs) _hiTs = ts;
    if (_rrCoverageCounts(rr)) {
      _sumRr += rr;
    } else {
      _implausible++;
    }
    _inN++;
    final idx = (tsSec - startSec) ~/ windowSec;
    if (idx != _idx && _rr.isNotEmpty) {
      sink.add(_close(_idx, _rr, _ts));
      _rr = [];
      _ts = [];
    }
    _idx = idx;
    _rr.add(rr);
    _ts.add(ts);
  }

  void fold(List<double> rr, List<double> ts) {
    for (var i = 0; i < rr.length; i++) {
      _step(rr[i], ts[i], recs);
    }
  }

  /// `rrCoverage` of the in-session beats, or null where the batch has none.
  /// The duplicate count is not kept (it needs every beat); the refusal reads
  /// only the coverage.
  RrCoverage? _coverage() {
    if (_inN < 2) return null;
    final spanSec =
        (_hiTs - _loTs + (_rrCoverageCounts(_loRr) ? _loRr : 0)) / 1000.0;
    if (!spanSec.isFinite || spanSec < kRrCoverageMinSpanSec) return null;
    final sumSec = _sumRr / 1000.0;
    return RrCoverage(
      coverage: sumSec / spanSec,
      sumRrSec: sumSec,
      spanSec: spanSec,
      beats: _inN,
      implausibleBeats: _implausible,
      duplicateBeats: 0,
    );
  }

  /// The open bucket is closed on a copy; the state is not changed.
  Metric<double> evaluate() {
    const inputs = ['rr_sleep_window'];
    if (startSec <= 0 || endSec <= startSec || _seen == 0) {
      return const Metric<double>.absent(
        tier: Tier.high,
        inputs_used: inputs,
        note: 'invalid or empty RR session window',
      );
    }
    if (_inN == 0) {
      return const Metric<double>.absent(
        tier: Tier.high,
        inputs_used: inputs,
        note: 'no RR beats inside the session window',
      );
    }
    final cov = _coverage();
    if (cov != null && cov.overCounted) {
      return Metric<double>.absent(
        tier: Tier.high,
        inputs_used: inputs,
        note: rrOvercountNote(cov),
      );
    }
    final all = [...recs];
    if (_rr.isNotEmpty) all.add(_close(_idx, _rr, _ts));
    final rmssds = <double>[];
    final runs = <List<double>>[];
    final perWindow = <List<List<double>>>[];
    final meanRr = <double>[];
    var overCountedWindows = 0, thinWindows = 0;
    for (final r in all) {
      if (r.kind == 1) {
        overCountedWindows++;
        continue;
      }
      if (r.kind == 2) {
        thinWindows++;
        continue;
      }
      rmssds.add(r.rmssd);
      runs.addAll(r.runs);
      perWindow.add(r.runs);
      meanRr.add(r.meanRr);
    }
    final droppedWhy = [
      if (thinWindows > 0)
        '$thinWindows window(s) had fewer than $minDiffsPerWindow clean '
            'successive differences',
      if (overCountedWindows > 0)
        '$overCountedWindows window(s) held more beat-time than elapsed time',
    ];
    final dropped = droppedWhy.isEmpty ? '' : ' (${droppedWhy.join('; ')})';
    final acf1 = nnDiffAcf1(runs);
    final refused = _jitterRefused(acf1, runs);
    if (rmssds.isEmpty && !refused) {
      return Metric<double>.absent(
        tier: Tier.high,
        inputs_used: inputs,
        note: 'no valid 5-min windows for sleep-session RMSSD$dropped',
      );
    }
    final kept = _keptWindows(acf1, refused, rmssds, perWindow, meanRr);
    if (kept == null) {
      return Metric<double>.absent(
        tier: Tier.high,
        inputs_used: inputs,
        note: refused
            ? '${_jitterNote(acf1!)}$dropped'
            : '${_jitterNote(acf1!)}; no 5-min window clears it on its own'
                '$dropped',
      );
    }
    final conf = kept.byBreathing
        ? 0.3
        : ((kept.rmssds.length / 12.0).clamp(0.0, 1.0) * _acf1Quality(acf1))
            .clamp(0.3, 0.95);
    return Metric<double>(
      value: mean(kept.rmssds)!,
      confidence: conf,
      tier: Tier.high,
      inputs_used: inputs,
      note: 'sleep-session HRV: mean RMSSD over cleaned 5-min windows'
          '$dropped.${kept.note}',
    );
  }
}

// ===========================================================================
// 7. irregularBeatScreen over the (day-long) corrected NN
// ===========================================================================
// Aggregates (SD1/SD2 from stddev of diffs and of levels, pNN70) are sums =>
// Welford, ~1e-13. The "sustained across 5-min windows" test is a COUNT of
// flagged/valid closed windows plus one open window evaluated on a copy => exact.
class IrregularScreenState {
  // elementwise stream state over the corrected NN list
  bool _prevKept = false;
  double _prevV = 0;
  // Time of the previous kept beat: a pair across a time hole is not
  // successive (the batch's seam test). NaN = unknown, never within a seam.
  double _prevT = double.nan;
  int _nKept = 0;
  // diff stats (adjacent kept pairs)
  int _dN = 0;
  double _dMean = 0, _dM2 = 0;
  int _over = 0;
  // level stats (kept beats)
  int _lN = 0;
  double _lMean = 0, _lM2 = 0;
  // windows
  double? _winStart;
  List<double> _bk = [];
  List<bool> _bkAdj = [];
  int _valid = 0, _flagged = 0;

  final double sd1sd2Flag, pnnThresholdMs, pnnFlagPct, windowMs, sustainedFraction;
  final int minWindowBeats;

  IrregularScreenState({
    this.sd1sd2Flag = 0.70,
    this.pnnThresholdMs = 70,
    this.pnnFlagPct = 30,
    double windowMinutes = 5,
    this.minWindowBeats = 40,
    this.sustainedFraction = 0.5,
  }) : windowMs = windowMinutes * 60000;

  IrregularScreenState _copy() {
    final c = IrregularScreenState(
        sd1sd2Flag: sd1sd2Flag,
        pnnThresholdMs: pnnThresholdMs,
        pnnFlagPct: pnnFlagPct,
        windowMinutes: windowMs / 60000,
        minWindowBeats: minWindowBeats,
        sustainedFraction: sustainedFraction)
      .._prevKept = _prevKept
      .._prevV = _prevV
      .._prevT = _prevT
      .._nKept = _nKept
      .._dN = _dN
      .._dMean = _dMean
      .._dM2 = _dM2
      .._over = _over
      .._lN = _lN
      .._lMean = _lMean
      .._lM2 = _lM2
      .._winStart = _winStart
      .._bk = List.of(_bk)
      .._bkAdj = List.of(_bkAdj)
      .._valid = _valid
      .._flagged = _flagged;
    return c;
  }

  void _flush() {
    final diffs = <double>[
      for (var i = 1; i < _bk.length; i++)
        if (_bkAdj[i]) _bk[i] - _bk[i - 1]
    ];
    // Valid on successive pairs, not beats (the batch's window rule).
    if (diffs.length >= minWindowBeats - 1) {
      _valid++;
      final sdsd = stddev(diffs);
      final sdnn = stddev(_bk);
      if (sdsd != null && sdnn != null) {
        final sd1 = sdsd / math.sqrt2;
        final v = 2 * sdnn * sdnn - sd1 * sd1;
        final sd2 = v > 0 ? math.sqrt(v) : 0.0;
        if (sd2 > 0) {
          final ratio = sd1 / sd2;
          final over = diffs.where((d) => d.abs() > pnnThresholdMs).length;
          final pnn = 100.0 * over / diffs.length;
          if (ratio >= sd1sd2Flag && pnn >= pnnFlagPct) _flagged++;
        }
      }
    }
    _bk = [];
    _bkAdj = [];
  }

  void _add(double v, double tm) {
    final kept = v >= 300 && v <= 2000;
    if (kept) {
      // previous INPUT element was kept and no time hole lies between them
      final adjacent = _prevKept && tm - _prevT <= v + 0.5;
      if (adjacent) {
        final d = v - _prevV;
        _dN++;
        final dl = d - _dMean;
        _dMean += dl / _dN;
        _dM2 += dl * (d - _dMean);
        if (d.abs() > pnnThresholdMs) _over++;
      }
      _lN++;
      final dl = v - _lMean;
      _lMean += dl / _lN;
      _lM2 += dl * (v - _lMean);
      _nKept++;
      _winStart ??= tm;
      if (tm - _winStart! >= windowMs) {
        _flush();
        _winStart = tm;
      }
      _bk.add(v);
      _bkAdj.add(adjacent);
    }
    _prevKept = kept;
    if (kept) {
      _prevV = v;
      _prevT = tm;
    }
  }

  void fold(List<double> nn, List<double> t) {
    for (var i = 0; i < nn.length; i++) {
      _add(nn[i], t[i]);
    }
  }

  Metric<IrregularRhythm> evaluate(List<double> tailNn, List<double> tailT,
      {double artifactFraction = 0.0,
      int minBeats = irregularScreenMinBeats,
      double maxArtifact = 0.30}) {
    const inputs = ['rr_cleaned'];
    final c = _copy()..fold(tailNn, tailT);
    // The batch gates on the successive pairs it averages, not on beats.
    if (c._dN < minBeats - 1) {
      return const Metric<IrregularRhythm>.absent(
        tier: Tier.estimate,
        inputs_used: inputs,
        note: 'too few clean beats for an irregular-rhythm screen',
      );
    }
    if (artifactFraction > maxArtifact) {
      return Metric<IrregularRhythm>.absent(
        tier: Tier.estimate,
        inputs_used: inputs,
        note: 'artifact fraction ${(artifactFraction * 100).round()}% > '
            '${(maxArtifact * 100).round()}% — screen suppressed on noisy RR',
      );
    }
    final sdsd = c._dN < 2 ? null : math.sqrt(c._dM2 / (c._dN - 1));
    final sdnn = c._lN < 2 ? null : math.sqrt(c._lM2 / (c._lN - 1));
    if (sdsd == null || sdnn == null) {
      return const Metric<IrregularRhythm>.absent(
        tier: Tier.estimate,
        inputs_used: inputs,
        note: 'no successive clean beats to build a Poincare plot from',
      );
    }
    final sd1 = sdsd / math.sqrt2;
    final v = 2 * sdnn * sdnn - sd1 * sd1;
    final sd2 = v > 0 ? math.sqrt(v) : 0.0;
    if (sd2 <= 0) {
      return const Metric<IrregularRhythm>.absent(
        tier: Tier.estimate,
        inputs_used: inputs,
        note: 'no long-term variability (SD2 = 0) — the SD1/SD2 ratio is '
            'undefined, not "perfectly regular"',
      );
    }
    final ratio = sd1 / sd2;
    final pnnPct = c._dN == 0 ? 0.0 : 100.0 * c._over / c._dN;
    final aggregateHigh = ratio >= sd1sd2Flag && pnnPct >= pnnFlagPct;
    var flag = false;
    if (aggregateHigh) {
      c._flush(); // the open window closes at end of data
      flag = c._valid != 0 && c._flagged / c._valid >= sustainedFraction;
    }
    final conf = (c._nKept / 5000.0 * (1 - artifactFraction)).clamp(0.2, 0.9);
    return Metric<IrregularRhythm>(
      value: IrregularRhythm(
        sd1: sd1,
        sd2: sd2,
        sd1sd2: ratio,
        pnnPct: pnnPct,
        nBeats: c._nKept,
        flag: flag,
      ),
      confidence: conf,
      tier: Tier.estimate,
      inputs_used: inputs,
      note: 'irregular-rhythm SCREEN (not a diagnosis): Poincaré SD1/SD2 + pNN'
          '${pnnThresholdMs.round()}. PRV not ECG — wrist pulse misses P-waves. '
          'Discuss with a clinician only if you have symptoms.',
    );
  }

  Map<String, dynamic> toJson() => {
        'prevKept': _prevKept,
        'prevV': _prevV,
        'prevT': _prevT.isFinite ? _prevT : null,
        'nKept': _nKept,
        'dN': _dN,
        'dMean': _dMean,
        'dM2': _dM2,
        'over': _over,
        'lN': _lN,
        'lMean': _lMean,
        'lM2': _lM2,
        'winStart': _winStart,
        'bk': _bk,
        'bkAdj': [for (final a in _bkAdj) a ? 1 : 0],
        'valid': _valid,
        'flagged': _flagged,
      };

  factory IrregularScreenState.fromJson(Map<String, dynamic> j) {
    final s = IrregularScreenState();
    s._prevKept = j['prevKept'] as bool;
    s._prevV = (j['prevV'] as num).toDouble();
    s._prevT = (j['prevT'] as num?)?.toDouble() ?? double.nan;
    s._nKept = j['nKept'] as int;
    s._dN = j['dN'] as int;
    s._dMean = (j['dMean'] as num).toDouble();
    s._dM2 = (j['dM2'] as num).toDouble();
    s._over = j['over'] as int;
    s._lN = j['lN'] as int;
    s._lMean = (j['lMean'] as num).toDouble();
    s._lM2 = (j['lM2'] as num).toDouble();
    s._winStart = (j['winStart'] as num?)?.toDouble();
    s._bk = [for (final x in j['bk'] as List) (x as num).toDouble()];
    s._bkAdj = [for (final x in j['bkAdj'] as List) x == 1];
    s._valid = j['valid'] as int;
    s._flagged = j['flagged'] as int;
    return s;
  }
}
