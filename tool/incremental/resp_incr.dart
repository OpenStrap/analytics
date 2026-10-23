// RESEARCH PROTOTYPES — incremental breathing-rate and spectral estimators.
//
// All three Welch-style estimators (rsaRespRate, hrvFreq, and the per-30-min
// bins behind BRV) have the same structure: the answer is an aggregate over
// SUB-WINDOWS that are each a pure function of the beats inside them. A
// sub-window is final as soon as a beat past its end is settled, so the state
// is "list of finished sub-window results + the beats since the next
// unfinished sub-window". Aggregates (median, consensus, sum/k) are re-run on
// that list with the batch's own arithmetic => bit-identical.
import 'dart:math' as math;

import 'package:openstrap_analytics/onehz.dart'
    hide RrCorrector, RrSettled, RrSnapshot, IrregularScreenState;

int _lowerBound(List<double> a, double v) {
  var lo = 0, hi = a.length;
  while (lo < hi) {
    final m = (lo + hi) >> 1;
    if (a[m] < v) {
      lo = m + 1;
    } else {
      hi = m;
    }
  }
  return lo;
}

double _powerAt(LombScargle ls, double fHz) {
  double best = 0;
  double bestDist = double.infinity;
  for (final pt in ls.spectrum) {
    final d = (pt.freqHz - fHz).abs();
    if (d < bestDist) {
      bestDist = d;
      best = pt.psd;
    }
  }
  return best;
}

// ===========================================================================
// rsaRespRate
// ===========================================================================
class _SegCounts {
  final List<double> peaks = [], peakHz = [], peakPwr = [];
  int atCeiling = 0, belowBand = 0, thin = 0, gappy = 0;
  // The at-ceiling sub-windows' own ceilings, br/min (min and max).
  double ceilingLo = double.infinity, ceilingHi = 0.0;
  _SegCounts copy() {
    final c = _SegCounts();
    c.peaks.addAll(peaks);
    c.peakHz.addAll(peakHz);
    c.peakPwr.addAll(peakPwr);
    c.atCeiling = atCeiling;
    c.belowBand = belowBand;
    c.thin = thin;
    c.gappy = gappy;
    c.ceilingLo = ceilingLo;
    c.ceilingHi = ceilingHi;
    return c;
  }
}

/// [a] and [b] sorted by [double.compareTo] (as `median` sorts), merged.
List<double> _mergeSorted(List<double> a, List<double> b) {
  if (b.isEmpty) return a;
  if (a.isEmpty) return b;
  final out = List<double>.filled(a.length + b.length, 0);
  var i = 0, j = 0, k = 0;
  while (i < a.length && j < b.length) {
    out[k++] = a[i].compareTo(b[j]) <= 0 ? a[i++] : b[j++];
  }
  while (i < a.length) {
    out[k++] = a[i++];
  }
  while (j < b.length) {
    out[k++] = b[j++];
  }
  return out;
}

/// Usable sub-windows at which the batch's confidence reaches full weight
/// (resp_rate.dart `_rsaFullWeightSubwindows`).
const double _rsaFullWeightSubwindows = 23;

class RsaWelchState {
  static const double segSec = rsaSegmentSec; // 300
  // buffer of settled beats (ms and s), from the next unfinished sub-window
  List<double> _tMs = [], _ts = [], _nn = [];
  // Every NN folded, sorted: the whole-input ceiling is the MEDIAN beat
  // interval, which needs all of them (upstream's gap-free ceiling).
  List<double> _sorted = [];
  // A non-finite beat time was folded: the batch abstains on it.
  bool _nonFinite = false;
  double? _first;
  int _count = 0;
  double _lastT = 0;
  bool _folding = false;
  double _next = 0;
  _SegCounts _sc = _SegCounts();

  RsaWelchState();

  int get bufferedBeats => _nn.length;
  int get foldedSegments =>
      _sc.peaks.length + _sc.atCeiling + _sc.belowBand + _sc.thin + _sc.gappy;

  void fold(List<double> nn, List<double> tMs) {
    _sorted = _mergeSorted(_sorted, [...nn]..sort());
    for (final t in tMs) {
      if (!(t / 1000.0).isFinite) _nonFinite = true;
    }
    if (_nonFinite) {
      // Nothing settles after a non-finite time (the walk below would never
      // end); the batch abstains, and so does [evaluate].
      _nn.addAll(nn);
      _tMs.addAll(tMs);
      _ts.addAll([for (final t in tMs) t / 1000.0]);
      _count += nn.length;
      return;
    }
    for (var i = 0; i < nn.length; i++) {
      _nn.add(nn[i]);
      _tMs.add(tMs[i]);
      final s = tMs[i] / 1000.0;
      _ts.add(s);
      _first ??= s;
      _lastT = s;
      _count++;
    }
    if (!_folding && _count > 0 && _lastT - _first! >= 2 * segSec) {
      _folding = true;
      _next = _first!;
    }
    if (_folding) {
      while (_next + segSec <= _lastT) {
        _evalSeg(_next, _ts, _nn, _sc);
        _next += segSec / 2;
      }
      final cut = _lowerBound(_ts, _next);
      if (cut > 0) {
        _tMs = _tMs.sublist(cut);
        _ts = _ts.sublist(cut);
        _nn = _nn.sublist(cut);
      }
    }
  }

  static void _evalSeg(
      double s, List<double> tSec, List<double> nnMs, _SegCounts c) {
    final lo = _lowerBound(tSec, s);
    final hi = _lowerBound(tSec, s + segSec);
    final k = hi - lo;
    final segT = tSec.sublist(lo, hi);
    final segNn = nnMs.sublist(lo, hi);
    // Time-complete = the kept beats COVER >= 80 % of the sub-window (sum of
    // NN, not first-to-last span), judged before the beat count.
    final coveredSec = segNn.fold<double>(0, (a, b) => a + b) / 1000.0;
    if (coveredSec < segSec * 0.8) {
      c.gappy++;
      return;
    }
    if (k < 30) {
      c.thin++;
      return;
    }
    final segSpan = segT.last - segT.first;
    // The sub-window's ceiling from its median beat interval, gap-free.
    final segHi = rsaCeilingHz(median(segNn)! / 1000.0);
    if (segHi < rsaHiHz) {
      c.belowBand++;
      return;
    }
    final grid = math.max(64, ((segHi - rsaLoHz) * 4 * segSpan).ceil());
    final ls = lombScargle(segT, segNn, freqGrid(rsaLoHz, segHi, grid));
    if (ls == null) {
      c.thin++;
      return;
    }
    final pk = ls.peakFreq(rsaLoHz, segHi);
    if (pk == null) {
      c.thin++;
      return;
    }
    if (pk >= segHi - (segHi - rsaLoHz) / (grid - 1)) {
      c.atCeiling++;
      c.ceilingLo = math.min(c.ceilingLo, segHi * 60);
      c.ceilingHi = math.max(c.ceilingHi, segHi * 60);
      return;
    }
    c.peaks.add(pk * 60.0);
    c.peakHz.add(pk);
    c.peakPwr.add(_powerAt(ls, pk));
  }

  /// `rsaRespRate(settled ++ tail, artifactFraction: ...)`.
  Metric<RespEstimate> evaluate(List<double> tailNn, List<double> tailTMs,
      {required double artifactFraction,
      double tolBrpm = 2.0,
      double minConsensus = 0.5,
      double maxArtifact = 0.30}) {
    const inputs = ['rr_cleaned', 'beat_times'];
    final n = _count + tailNn.length;
    if (n < 20) {
      return const Metric<RespEstimate>.absent(
        tier: Tier.high,
        inputs_used: inputs,
        note: 'too few beats for an RSA spectral estimate (need ≥20)',
      );
    }
    final allNn = [..._nn, ...tailNn];
    final allTMs = [..._tMs, ...tailTMs];
    final allTs = [..._ts, for (final t in tailTMs) t / 1000.0];
    final first = _first ?? allTs.first;
    final last = allTs.last;
    final spanSec = last - first;
    if (!_folding) {
      // short record (< 2 sub-windows): the oracle's segSec = span/2 rule
      // makes every window length depend on the total. Buffer holds all
      // beats here (no folding yet, and a non-finite time never starts it),
      // so just call the oracle.
      return rsaRespRate(allNn, allTMs, artifactFraction: artifactFraction);
    }
    if (artifactFraction > maxArtifact) {
      return Metric<RespEstimate>.absent(
        tier: Tier.high,
        inputs_used: inputs,
        note: 'artifact fraction ${round6(artifactFraction)} > gate '
            '— RSA peak unreliable',
      );
    }
    if (_nonFinite || allTs.any((t) => !t.isFinite)) {
      return const Metric<RespEstimate>.absent(
        tier: Tier.high,
        inputs_used: inputs,
        note: 'non-finite beat time',
      );
    }
    if (spanSec <= 0) {
      return const Metric<RespEstimate>.absent(
        tier: Tier.high,
        inputs_used: inputs,
        note: 'degenerate beat times',
      );
    }
    // The beat interval is the median NN over settled ++ tail (gap-free).
    final beatSec =
        percentile(_mergeSorted(_sorted, [...tailNn]..sort()), 50)! / 1000.0;
    final hiHz = rsaCeilingHz(beatSec);
    if (hiHz < rsaHiHz) {
      return Metric<RespEstimate>.absent(
        tier: Tier.high,
        inputs_used: inputs,
        note: 'sleeping heart rate ${round6(60 / beatSec)} bpm (median beat '
            'interval ${round6(beatSec)} s) can resolve breathing from beat '
            'timing only up to ${round6(hiHz * 60)} br/min, below the top of the '
            'normal 9–24 br/min band, so any peak could be an alias; rate '
            'withheld',
      );
    }
    // provisional sub-windows on a copy: those that end after the settled edge
    final sc = _sc.copy();
    var s = _next;
    while (s + segSec <= last + 1e-9) {
      _evalSeg(s, allTs, allNn, sc);
      s += segSec / 2;
    }
    return _finish(sc, segSec, hiHz, artifactFraction, tolBrpm, minConsensus);
  }

  static Metric<RespEstimate> _finish(_SegCounts c, double segSec, double hiHz,
      double artifactFraction, double tolBrpm, double minConsensus) {
    const inputs = ['rr_cleaned', 'beat_times'];
    final peaks = c.peaks, peakHz = c.peakHz, peakPwr = c.peakPwr;
    final dropped = c.atCeiling + c.belowBand + c.thin + c.gappy;
    final total = peaks.length + dropped;
    if (peaks.length < 3) {
      // The largest counter is the reason; ties go to the earlier entry.
      final reasons = <(int, String)>[
        (
          c.belowBand,
          '${c.belowBand} of $total sub-windows had a beat rate too low to '
              'cover the HF band (any peak could be an alias)'
        ),
        (
          c.atCeiling,
          c.atCeiling == 0
              ? ''
              : '${c.atCeiling} of $total sub-windows peaked at/above their '
                  'resolvable ceiling (${round6(c.ceilingLo)}'
                  '${c.ceilingHi > c.ceilingLo ? '–${round6(c.ceilingHi)}' : ''} '
                  'br/min)'
        ),
        (
          c.gappy,
          '${c.gappy} of $total ${round6(segSec)}s sub-windows had less than '
              '80 % of their time covered by clean beats (sensor gaps or '
              'rejected beats)'
        ),
        (
          c.thin,
          '${c.thin} of $total sub-windows had fewer than 30 beats or no '
              'spectral peak'
        ),
      ];
      var top = reasons.first;
      for (final r in reasons.skip(1)) {
        if (r.$1 > top.$1) top = r;
      }
      final why =
          dropped == 0 ? 'only ${peaks.length} usable sub-windows' : top.$2;
      return Metric<RespEstimate>.absent(
        tier: Tier.high,
        inputs_used: inputs,
        note: 'no stable HF respiratory peak resolved — $why',
      );
    }
    final medBrpm0 = median(peaks)!;
    var within = 0;
    for (final p in peaks) {
      if ((p - medBrpm0).abs() <= tolBrpm) within++;
    }
    final consensus = within / peaks.length;
    if (consensus < minConsensus) {
      return Metric<RespEstimate>.absent(
        tier: Tier.high,
        inputs_used: inputs,
        note: 'HF peak unstable across the window\'s own sub-windows — only '
            '$within of ${peaks.length} ${round6(segSec)}s sub-windows fall '
            'within ${round6(tolBrpm)} br/min of the median; withheld',
      );
    }
    var best = 0;
    for (var i = 1; i < peaks.length; i++) {
      if ((peaks[i] - medBrpm0).abs() < (peaks[best] - medBrpm0).abs()) best = i;
    }
    final brpm = peaks[best];
    final conf = ((1 - artifactFraction) *
            consensus *
            (peaks.length / _rsaFullWeightSubwindows).clamp(0.0, 1.0))
        .clamp(0.2, 0.9);
    return Metric<RespEstimate>(
      value: RespEstimate(brpm, peakHz[best], peakPwr[best], 'rsa',
          usableSubwindows: peaks.length, subwindows: total),
      confidence: conf,
      tier: Tier.high,
      inputs_used: inputs,
      note: 'RSA HF-peak respiratory rate (Lomb-Scargle on native beat times, '
          'median of ${peaks.length} ${round6(segSec)}s sub-windows, $within of '
          'them within ${round6(tolBrpm)} br/min of it — brpm, peak_hz and power '
          'all come from the medoid sub-window); PRV-derived; this window could '
          'resolve up to ${round6(hiHz * 60)} br/min',
    );
  }

  Map<String, dynamic> toJson() => {
        'tMs': _tMs,
        'nn': _nn,
        'sorted': _sorted,
        'nonFinite': _nonFinite,
        'first': _first,
        'count': _count,
        'lastT': _lastT,
        'folding': _folding,
        'next': _next,
        'peaks': _sc.peaks,
        'peakHz': _sc.peakHz,
        'peakPwr': _sc.peakPwr,
        'atCeiling': _sc.atCeiling,
        'belowBand': _sc.belowBand,
        'thin': _sc.thin,
        'gappy': _sc.gappy,
        'ceilingLo': _sc.ceilingLo.isFinite ? _sc.ceilingLo : null,
        'ceilingHi': _sc.ceilingHi,
      };

  factory RsaWelchState.fromJson(Map<String, dynamic> j) {
    List<double> dl(Object? o) => [for (final x in o as List) (x as num).toDouble()];
    final s = RsaWelchState();
    s._tMs = dl(j['tMs']);
    s._ts = [for (final t in s._tMs) t / 1000.0];
    s._nn = dl(j['nn']);
    s._sorted = dl(j['sorted']);
    s._nonFinite = j['nonFinite'] as bool;
    s._first = (j['first'] as num?)?.toDouble();
    s._count = j['count'] as int;
    s._lastT = (j['lastT'] as num).toDouble();
    s._folding = j['folding'] as bool;
    s._next = (j['next'] as num).toDouble();
    s._sc.peaks.addAll(dl(j['peaks']));
    s._sc.peakHz.addAll(dl(j['peakHz']));
    s._sc.peakPwr.addAll(dl(j['peakPwr']));
    s._sc.atCeiling = j['atCeiling'] as int;
    s._sc.belowBand = j['belowBand'] as int;
    s._sc.thin = j['thin'] as int;
    s._sc.gappy = j['gappy'] as int;
    s._sc.ceilingLo = (j['ceilingLo'] as num?)?.toDouble() ?? double.infinity;
    s._sc.ceilingHi = (j['ceilingHi'] as num).toDouble();
    return s;
  }
}

// ===========================================================================
// _respPerWindow (feeds BRV): 30-min bins of NN from the first NN beat
// ===========================================================================
class RespWindowsState {
  final double windowMs;
  final int minBeats;
  double? _t0;
  int _bin = 0;
  RsaWelchState _open = RsaWelchState();
  int _openCount = 0;
  final List<double> closed = [];

  RespWindowsState({this.windowMs = 1800000.0, this.minBeats = 60});

  void _closeOpen(List<double> sink, RsaWelchState st, int count) {
    if (count < minBeats) return;
    final r = st.evaluate(const [], const [], artifactFraction: 0.0);
    final b = r.present ? r.value!.brpm : null;
    if (b != null) sink.add(b);
  }

  void fold(List<double> nn, List<double> tMs) {
    var from = 0;
    for (var i = 0; i < nn.length; i++) {
      _t0 ??= tMs[i];
      final idx = ((tMs[i] - _t0!) / windowMs).floor();
      if (idx != _bin) {
        _open.fold(nn.sublist(from, i), tMs.sublist(from, i));
        _openCount += i - from;
        from = i;
        _closeOpen(closed, _open, _openCount);
        _open = RsaWelchState();
        _openCount = 0;
        _bin = idx;
      }
    }
    _open.fold(nn.sublist(from), tMs.sublist(from));
    _openCount += nn.length - from;
  }

  /// `_respPerWindow(settled ++ tail)`.
  List<double> evaluate(List<double> tailNn, List<double> tailTMs) {
    final out = [...closed];
    if (tailNn.isEmpty) {
      _closeOpen(out, _open, _openCount);
      return out;
    }
    // tail beats may open new bins: split by bin index
    var curIdx = _bin;
    var curSettledOpen = _open;
    var curCount = _openCount;
    var from = 0;
    var useCopy = true; // the first bin continues the settled open bin
    for (var i = 0; i < tailNn.length; i++) {
      final idx = ((tailTMs[i] - (_t0 ?? tailTMs[0])) / windowMs).floor();
      if (idx != curIdx) {
        _flushTail(out, curSettledOpen, curCount, useCopy, tailNn.sublist(from, i),
            tailTMs.sublist(from, i));
        useCopy = false;
        curSettledOpen = RsaWelchState();
        curCount = 0;
        curIdx = idx;
        from = i;
      }
    }
    _flushTail(out, curSettledOpen, curCount, useCopy, tailNn.sublist(from),
        tailTMs.sublist(from));
    return out;
  }

  void _flushTail(List<double> out, RsaWelchState st, int count, bool settled,
      List<double> nn, List<double> t) {
    final total = count + nn.length;
    if (total < minBeats) return;
    final r = st.evaluate(nn, t, artifactFraction: 0.0);
    final b = r.present ? r.value!.brpm : null;
    if (b != null) out.add(b);
  }
}

// ===========================================================================
// hrvFreq (LF/HF): Welch-averaged Lomb-Scargle band powers, 4 bands
// ===========================================================================
class _Band {
  final double lo, hi, segSec, step;
  final List<double> grid;
  double sum = 0;
  int k = 0;
  double next = 0;
  bool started = false;
  _Band(this.lo, this.hi, double oversample)
      : segSec = 10.0 / lo,
        step = (10.0 / lo) / 2,
        grid = _gridFor(lo, hi, 10.0 / lo, oversample);
  static List<double> _gridFor(double lo, double hi, double seg, double os) {
    final df = 1.0 / seg / os;
    final nGrid = ((hi - lo) / df).ceil() + 1;
    return freqGrid(lo, hi, nGrid);
  }
}

class HrvFreqState {
  final double oversample;

  /// ULF needs a 33 333 s segment: it can only ever resolve on a record longer
  /// than 9.26 h, and while unresolved it forces the WHOLE record to be kept.
  /// With [includeUlf] false the state stays small (VLF buffer ~1.5 segments
  /// = 83 min) but is only valid while the record spans < 33 333 s; beyond
  /// that [evaluate] throws and the caller must use the batch function.
  final bool includeUlf;
  final List<_Band> _bands;
  List<double> _ts = [], _y = [];
  double? _first;
  int _count = 0;
  double _lastT = 0;

  HrvFreqState({this.oversample = 4.0, this.includeUlf = true})
      : _bands = [
          _Band(0.0003, 0.003, oversample),
          _Band(0.003, 0.04, oversample),
          _Band(0.04, 0.15, oversample),
          _Band(0.15, 0.40, oversample),
        ];

  int get bufferedBeats => _ts.length;

  /// One sub-window of one band; returns the band power or null (skipped).
  static double? _seg(_Band b, double start, List<double> tSec, List<double> y) {
    final end = start + b.segSec;
    final lo = _lowerBound(tSec, start);
    final hi = _lowerBound(tSec, end);
    final ts = tSec.sublist(lo, hi);
    final ys = y.sublist(lo, hi);
    if (ts.length < 16 || ts.last - ts.first < b.segSec * 0.8) return null;
    var maxGap = 0.0;
    for (var i = 1; i < ts.length; i++) {
      final g = ts[i] - ts[i - 1];
      if (g > maxGap) maxGap = g;
    }
    if (maxGap > b.segSec * 0.2) return null;
    final ls = lombScargle(ts, ys, b.grid);
    if (ls == null) return null;
    final p = ls.bandPower(b.lo, b.hi);
    if (!p.isFinite) return null;
    return p;
  }

  void fold(List<double> nn, List<double> tMs) {
    for (var i = 0; i < nn.length; i++) {
      _y.add(nn[i]);
      final s = tMs[i] / 1000.0;
      _ts.add(s);
      _first ??= s;
      _lastT = s;
      _count++;
    }
    if (_count == 0) return;
    for (final b in _bands) {
      if (!includeUlf && identical(b, _bands[0])) continue;
      if (!b.started) {
        b.started = true;
        b.next = _first!;
      }
      while (b.next + b.segSec <= _lastT) {
        final p = _seg(b, b.next, _ts, _y);
        if (p != null) {
          b.sum += p;
          b.k++;
        }
        b.next += b.step;
      }
    }
    var minNext = double.infinity;
    for (final b in _bands) {
      if (!includeUlf && identical(b, _bands[0])) continue;
      if (b.next < minNext) minNext = b.next;
    }
    final cut = _lowerBound(_ts, minNext);
    if (cut > 0) {
      _ts = _ts.sublist(cut);
      _y = _y.sublist(cut);
    }
  }

  double? _band(_Band b, List<double> tSec, List<double> y, int count,
      double first, double last) {
    if (count < 16) return null;
    final span = last - first;
    if (span < b.segSec) return null;
    var sum = b.sum;
    var k = b.k;
    var start = b.started ? b.next : first;
    while (start + b.segSec <= last) {
      final p = _seg(b, start, tSec, y);
      if (p != null) {
        sum += p;
        k++;
      }
      start += b.step;
    }
    return k == 0 ? null : sum / k;
  }

  Metric<HrvFreq> evaluate(List<double> tailNn, List<double> tailTMs,
      {required double artifactFraction, double hfArtifactGate = 0.15}) {
    const inputs = ['rr_cleaned', 'beat_times'];
    final n = _count + tailNn.length;
    if (n < 16) {
      return const Metric<HrvFreq>.absent(
        tier: Tier.high,
        inputs_used: inputs,
        note: 'too few beats for a spectral estimate',
      );
    }
    final ts = [..._ts, for (final t in tailTMs) t / 1000.0];
    final y = [..._y, ...tailNn];
    final first = _first ?? ts.first;
    final last = ts.last;
    final spanSec = last - first;
    if (spanSec <= 0) {
      return const Metric<HrvFreq>.absent(
        tier: Tier.high,
        inputs_used: inputs,
        note: 'degenerate beat times',
      );
    }
    if (!includeUlf && spanSec >= _bands[0].segSec) {
      throw StateError('ULF is resolvable (span >= ${_bands[0].segSec} s): '
          'this state excludes it; use hrvFreq() or includeUlf: true');
    }
    final ulf = includeUlf ? _band(_bands[0], ts, y, n, first, last) : null;
    final vlf = _band(_bands[1], ts, y, n, first, last);
    final lf = _band(_bands[2], ts, y, n, first, last);
    final hfRaw = _band(_bands[3], ts, y, n, first, last);
    if (lf == null && hfRaw == null) {
      return const Metric<HrvFreq>.absent(
        tier: Tier.high,
        inputs_used: inputs,
        note: 'record too short to resolve any HRV band',
      );
    }
    final hfGated = artifactFraction > hfArtifactGate;
    final hf = hfGated ? null : hfRaw;
    double? lfhf, nuLf, nuHf;
    if (lf != null && hf != null && (lf + hf) > 0) {
      lfhf = hf == 0 ? null : lf / hf;
      nuLf = 100.0 * lf / (lf + hf);
      nuHf = 100.0 * hf / (lf + hf);
    }
    final bands = <String, double?>{'ulf': ulf, 'vlf': vlf, 'lf': lf, 'hf': hfRaw};
    final resolved = [
      for (final e in bands.entries)
        if (e.value != null) e.key
    ];
    final total = (hfGated || lf == null || hfRaw == null)
        ? null
        : [for (final b in resolved) bands[b]!].reduce((a, b) => a + b);
    final conf = ((1 - artifactFraction) * (hfGated ? 0.6 : 0.9)).clamp(0.2, 0.9);
    return Metric<HrvFreq>(
      value: HrvFreq(
        ulf: ulf,
        vlf: vlf,
        lf: lf,
        hf: hf,
        total: total,
        totalBands: total == null ? null : resolved,
        lfhf: lfhf,
        nuLf: nuLf,
        nuHf: nuHf,
        hfGated: hfGated,
      ),
      confidence: conf,
      tier: Tier.high,
      inputs_used: inputs,
      note: hfGated
          ? 'HF suppressed: artifact fraction ${round6(artifactFraction)} '
              '> gate — LF/VLF reported, HF/LF-HF/nu/total withheld'
          : 'PRV spectrum; HF band quantization-limited at 1 Hz',
    );
  }

  Map<String, dynamic> toJson() => {
        'ts': _ts,
        'y': _y,
        'first': _first,
        'count': _count,
        'lastT': _lastT,
        'bands': [
          for (final b in _bands)
            {'sum': b.sum, 'k': b.k, 'next': b.next, 'started': b.started}
        ],
      };

  factory HrvFreqState.fromJson(Map<String, dynamic> j,
      {double oversample = 4.0, bool includeUlf = true}) {
    final s = HrvFreqState(oversample: oversample, includeUlf: includeUlf);
    s._ts = [for (final x in j['ts'] as List) (x as num).toDouble()];
    s._y = [for (final x in j['y'] as List) (x as num).toDouble()];
    s._first = (j['first'] as num?)?.toDouble();
    s._count = j['count'] as int;
    s._lastT = (j['lastT'] as num).toDouble();
    final bs = j['bands'] as List;
    for (var i = 0; i < s._bands.length; i++) {
      final m = bs[i] as Map;
      s._bands[i]
        ..sum = (m['sum'] as num).toDouble()
        ..k = m['k'] as int
        ..next = (m['next'] as num).toDouble()
        ..started = m['started'] as bool;
    }
    return s;
  }
}

// ===========================================================================
// edge `dayRespCurve`: 3-min RSA windows every 5 min, stillness-gated
// ===========================================================================
// Right-context 0 in RR, but the stillness gate reads accelerometer seconds up
// to ceil(ts[i]/1000), so an attempt WAITS for the accel watermark. Exact and
// append-only once an attempt has run.
class DayRespCurveState {
  final double cut;
  List<double> _ts = [], _rr = [];
  int _head = 0;
  int _gated = 0;
  double _lastEmit = -1e18;
  final List<Map<String, num>> _out = [];
  final List<int> _rowSec = [];
  final List<bool> _rowQuiet = [];
  final List<double> _pendRr = [], _pendTs = [];
  int attempts = 0;

  DayRespCurveState({this.cut = 0.02});

  List<Map<String, num>> get curve => _gated < 60 ? const [] : _out;

  static bool _present(double ax, double ay, double az) {
    final magSq = ax * ax + ay * ay + az * az;
    return magSq > 0 && magSq <= 16.0;
  }

  void fold(List<double> rrMs, List<double> rrTsMs, List<int> accTs,
      List<double> ax, List<double> ay, List<double> az, int watermarkSec) {
    for (var i = 0; i < accTs.length; i++) {
      var q = false;
      if (_present(ax[i], ay[i], az[i])) {
        final mag =
            math.sqrt(ax[i] * ax[i] + ay[i] * ay[i] + az[i] * az[i]);
        q = (mag - 1.0).abs() <= cut;
      }
      _rowSec.add(accTs[i]);
      _rowQuiet.add(q);
    }
    _pendRr.addAll(rrMs);
    _pendTs.addAll(rrTsMs);
    var used = 0;
    for (; used < _pendRr.length; used++) {
      final v = _pendRr[used];
      if (!(v >= 300 && v <= 2000)) continue;
      final t = _pendTs[used];
      // would this beat trigger an attempt? decide on the ring + this beat
      final i = _ts.length; // index it will take
      var head = _head;
      // while (ts[i]-ts[lo] > win) lo++ — evaluated with the beat appended
      final tsTmp = t;
      while (head < i && tsTmp - _ts[head] > 180000.0) {
        head++;
      }
      final attempt = (i - head >= 30) && (tsTmp - _lastEmit > 300000);
      if (attempt) {
        final hiSec = (tsTmp / 1000).ceil();
        if (watermarkSec < hiSec) break; // accel for this window not here yet
      }
      _ts.add(t);
      _rr.add(v);
      _gated++;
      _head = head;
      if (attempt) _attempt(i);
    }
    _pendRr.removeRange(0, used);
    _pendTs.removeRange(0, used);
    // trim the rings
    if (_head > 256) {
      _ts = _ts.sublist(_head);
      _rr = _rr.sublist(_head);
      _head = 0;
    }
    if (_ts.isNotEmpty) {
      final keepSec = (_ts[_head] / 1000).floor() - 5;
      var k = 0;
      while (k < _rowSec.length && _rowSec[k] < keepSec) {
        k++;
      }
      if (k > 0) {
        _rowSec.removeRange(0, k);
        _rowQuiet.removeRange(0, k);
      }
    }
  }

  void _attempt(int i) {
    final loSec = (_ts[_head] / 1000).floor();
    final hiSec = (_ts[i] / 1000).ceil();
    var still = 0;
    for (var r = 0; r < _rowSec.length; r++) {
      if (_rowSec[r] >= loSec && _rowSec[r] < hiSec && _rowQuiet[r]) still++;
    }
    final spanSec = hiSec - loSec;
    double? brpm;
    if (!(spanSec <= 0 || still < 0.9 * spanSec)) {
      attempts++;
      final nn = _rr.sublist(_head, i + 1);
      final t0 = _ts[_head];
      final nnt = [for (var k = _head; k <= i; k++) _ts[k] - t0];
      final est = rsaRespRate(nn, nnt, artifactFraction: 0.15);
      brpm = est.present ? est.value!.brpm : null;
    }
    _lastEmit = _ts[i];
    if (brpm != null) {
      _out.add({
        't': (_ts[i] / 1000).round(),
        'v': double.parse(brpm.toStringAsFixed(1)),
      });
    }
  }

  int get pending => _pendRr.length;
  int get ringBeats => _ts.length - _head;

  Map<String, dynamic> toJson() => {
        'ts': _ts.sublist(_head),
        'rr': _rr.sublist(_head),
        'gated': _gated,
        'lastEmit': _lastEmit,
        'out': _out,
        'rowSec': _rowSec,
        'rowQuiet': [for (final q in _rowQuiet) q ? 1 : 0],
        'pendRr': _pendRr,
        'pendTs': _pendTs,
      };

  factory DayRespCurveState.fromJson(Map<String, dynamic> j, {double cut = 0.02}) {
    List<double> dl(Object? o) => [for (final x in o as List) (x as num).toDouble()];
    final s = DayRespCurveState(cut: cut);
    s._ts = dl(j['ts']);
    s._rr = dl(j['rr']);
    s._gated = j['gated'] as int;
    s._lastEmit = (j['lastEmit'] as num).toDouble();
    for (final m in j['out'] as List) {
      final mm = m as Map;
      s._out.add({'t': mm['t'] as num, 'v': mm['v'] as num});
    }
    s._rowSec.addAll((j['rowSec'] as List).cast<int>());
    s._rowQuiet.addAll([for (final q in j['rowQuiet'] as List) q == 1]);
    s._pendRr.addAll(dl(j['pendRr']));
    s._pendTs.addAll(dl(j['pendTs']));
    return s;
  }
}
