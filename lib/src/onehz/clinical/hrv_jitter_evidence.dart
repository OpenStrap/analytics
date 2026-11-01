// Rejection and breathing-line exemption thresholds are an internal rule.
// Welch 1967 spectral estimation; Hirsch & Bishop 1981 provides the
// breathing/RSA basis. This is hrvTime()'s existing internal jitter policy,
// ESTIMATE with low confidence, not a published classifier. Shared formulas
// preserve the calculation; reordered sums can change decisions within rounding
// of a threshold.
// CLINICAL — mergeable evidence for the RMSSD jitter gate, for
// `hrvTimeAggregator`.
//
// Under [kNnDiffAcf1Floor] `hrvTime` decides on the difference RUNS themselves
// (rmssd_gate.dart): the white-noise share of the pooled Welch spectrum
// (64-beat segments every 32 beats from each run's start) and, for a refused
// timed night, the breathing-line test over the 5-min windows (128-beat
// segments every 64 beats from each in-window run's start). This aggregator
// keeps what those tests read as sums, so a night is never kept beat by beat:
//
//  * NOISE SHARE. A run that starts and ends inside a state is reduced to its
//    segment sums on the spot (as the batch does). A run cut by a chunk edge
//    is a PIECE: its first and last 63 differences raw (the only ones whose
//    coverage weight or segment depends on what lies past the edge), the
//    segment sums of every segment fully inside it, and the squared
//    differences of the rest by position mod 32 (their Hann coverage weight
//    depends on nothing else). A piece cut on its left does not know where in
//    its run it starts, so it keeps the segment sums for all 32 alignments;
//    the join that tells it (or the series start, at finish) picks one. A
//    piece is at most ~1.2k numbers, whatever its length.
//  * BREATHING. An in-window run lies inside one 5-min window, so it is short;
//    one cut by a chunk edge stays raw. Each finished run is reduced to its
//    128-beat segments' autocorrelation at lags 0..127, from which the
//    window's spectrum at ANY frequency follows (the test reads it at
//    frequencies that depend on the whole night's median beat): one record of
//    ~130 numbers per window, O(windows).
//  * The coarse-lattice test needs every distinct |difference| (it asks
//    whether all are multiples of the smallest): kept as a sorted set. Its
//    size is the number of distinct difference magnitudes, not of beats (on a
//    1 ms or 0.5 ms grid at most a few thousand).
//
// Sums are formed in another order than the batch's (and a cut piece's levels
// are integrated from its own start), so numbers agree to float rounding, not
// bit for bit; a verdict can differ only within rounding of a threshold.
//
// Not exported.

import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';

import '../../aggregate/aggregator.dart';
import '../../aggregate/json_support.dart';
import 'hrv_time.dart';
import 'hrv_time_aggregator.dart' show Beats;
import 'rmssd_gate.dart';

const int _edge = 63; // raw differences kept at each end of a piece
const int _bins = kNoiseHiBin - kNoiseLoBin + 1;
const int _lags = 128;
const double _windowMs = 300000.0;

double _t(double v) => v.isNaN ? 0.0 : v;

/// Hann coverage of a point at offset a (mod 32) from the segment grid, when
/// two segments cover it.
final List<double> _cw = [
  for (var a = 0; a < 32; a++)
    noiseHann[a] * noiseHann[a] + noiseHann[a + 32] * noiseHann[a + 32]
];

class _Phase {
  final Float64List psd = Float64List(kNoiseHiBin + 1);
  double p = 0, p2 = 0;
  int segs = 0;

  void addAll(_Phase o) {
    for (var k = kNoiseLoBin; k <= kNoiseHiBin; k++) {
      psd[k] += o.psd[k];
    }
    p += o.p;
    p2 += o.p2;
    segs += o.segs;
  }

  _Phase copy() => _Phase()..addAll(this);

  Object toJson() => [
        for (var k = kNoiseLoBin; k <= kNoiseHiBin; k++) encodeDouble(psd[k]),
        encodeDouble(p),
        encodeDouble(p2),
        segs,
      ];

  static _Phase fromJson(Object? j) {
    final l = decodeList(j);
    if (l.length != _bins + 3) throw const FormatException('invalid phase');
    final ph = _Phase();
    for (var k = 0; k < _bins; k++) {
      ph.psd[k + kNoiseLoBin] = decodeDouble(l[k]);
    }
    ph.p = decodeDouble(l[_bins]);
    ph.p2 = decodeDouble(l[_bins + 1]);
    ph.segs = decodeCount(l[_bins + 2]);
    return ph;
  }
}

/// A contiguous run of differences cut by a chunk edge (see the header).
class _Piece {
  _Piece(this.anchored)
      : phases = [for (var i = 0; i < (anchored ? 1 : 32); i++) _Phase()];

  /// Starts at its run's start (else its alignment in the run is unknown).
  bool anchored;

  /// Ends at its run's end.
  bool rightClosed = false;
  int len = 0; // differences
  final List<double> front = [];
  ListQueue<double> back = ListQueue();
  final Float64List s2 = Float64List(32);
  final List<int> cnt = List<int>.filled(32, 0);

  /// Levels of the last <= 64 points (integrated from the piece's start, or
  /// from wherever a join left them; only differences within a segment
  /// matter).
  ListQueue<double> xs = ListQueue()..add(0.0);
  double x = 0.0;
  List<_Phase> phases;

  /// Segments starting at or after this point are not formed (a join's
  /// replay: they belong to the right piece's sums).
  int stop = 1 << 62;

  final Float64List _seg = Float64List(kNoiseSegment);

  void append(double d) {
    len++;
    x += d;
    xs.add(x);
    if (xs.length > kNoiseSegment) xs.removeFirst();
    if (front.length < _edge) front.add(d);
    back.add(d);
    if (back.length > _edge) {
      final popped = back.removeFirst();
      final idx = len - _edge - 1;
      if (idx >= _edge) {
        s2[idx % 32] += popped * popped;
        cnt[idx % 32]++;
      }
    }
    final start = len - (kNoiseSegment - 1);
    if (start < 0 || start >= stop) return;
    final phase = start % 32;
    if (anchored && phase != 0) return;
    var i = 0;
    for (final v in xs) {
      _seg[i++] = v;
    }
    final ph = phases[anchored ? 0 : phase];
    final p = addNoiseSegment(_seg, 0, ph.psd);
    ph.p += p;
    ph.p2 += p * p;
    ph.segs++;
  }

  /// Every difference, for a piece of at most 2 * 63 (front and back cover it).
  List<double> allDiffs() {
    assert(len <= 2 * _edge);
    final overlap = front.length - (len - back.length);
    return [...front, ...back.skip(math.max(0, overlap))];
  }

  void anchor() {
    if (anchored) return;
    anchored = true;
    phases = [phases[0]];
  }

  /// This piece, then [d], then [right] (open on its left, never anchored).
  void join(double d, _Piece right) {
    append(d);
    if (right.len <= 2 * _edge) {
      for (final v in right.allDiffs()) {
        append(v);
      }
      rightClosed = right.rightClosed;
      return;
    }
    final boundary = len; // right's point 0
    stop = boundary;
    for (final v in right.front) {
      append(v);
    }
    stop = 1 << 62;
    // The replayed front sits in the interior of the joined piece.
    var k = 0;
    for (final v in back) {
      final idx = boundary + k++;
      if (idx >= _edge) {
        s2[idx % 32] += v * v;
        cnt[idx % 32]++;
      }
    }
    back = ListQueue.of(right.back);
    for (var r = 0; r < 32; r++) {
      s2[(r + boundary) % 32] += right.s2[r];
      cnt[(r + boundary) % 32] += right.cnt[r];
    }
    if (anchored) {
      phases[0].addAll(right.phases[(32 - boundary % 32) % 32]);
    } else {
      for (var f = 0; f < 32; f++) {
        phases[f].addAll(right.phases[((f - boundary) % 32 + 32) % 32]);
      }
    }
    len = boundary + right.len;
    xs = ListQueue.of(right.xs);
    x = right.x;
    rightClosed = right.rightClosed;
  }

  /// Adds this piece, anchored and closed (a whole run), to [sums]' spectral
  /// and coverage terms (not its squared-difference count: the state keeps
  /// that).
  void finalizeInto(NoiseShareSums sums) {
    assert(anchored);
    if (len <= 2 * _edge) {
      final scratch = NoiseShareSums()..addRun(allDiffs());
      for (var k = kNoiseLoBin; k <= kNoiseHiBin; k++) {
        sums.psd[k] += scratch.psd[k];
      }
      sums.pSum += scratch.pSum;
      sums.p2Sum += scratch.p2Sum;
      sums.segs += scratch.segs;
      sums.wsd += scratch.wsd;
      sums.wsum += scratch.wsum;
      return;
    }
    final ph = phases[0];
    for (var k = kNoiseLoBin; k <= kNoiseHiBin; k++) {
      sums.psd[k] += ph.psd[k];
    }
    sums.pSum += ph.p;
    sums.p2Sum += ph.p2;
    sums.segs += ph.segs;
    for (var r = 0; r < 32; r++) {
      final c = (_cw[r] + _cw[(r + 1) % 32]) / 2;
      sums.wsd += c * s2[r];
      sums.wsum += c * cnt[r];
    }
    // The edges: coverage from the segments at 0, 32, ... that fit the run.
    final last =
        len + 1 >= kNoiseSegment ? ((len + 1 - kNoiseSegment) ~/ 32) * 32 : -1;
    double cov(int j) {
      var c = 0.0;
      for (var s = (j - kNoiseSegment + 1).clamp(0, 1 << 62);
          s <= j && s <= last;
          s++) {
        if (s % 32 == 0) c += noiseHann[j - s] * noiseHann[j - s];
      }
      return c;
    }

    void edge(int i, double d) {
      final c = (cov(i) + cov(i + 1)) / 2;
      sums.wsd += c * d * d;
      sums.wsum += c;
    }

    for (var i = 0; i < front.length; i++) {
      edge(i, front[i]);
    }
    var i = len - back.length;
    for (final d in back) {
      edge(i++, d);
    }
  }

  _Piece copy() {
    final c = _Piece(anchored)
      ..rightClosed = rightClosed
      ..len = len
      ..back = ListQueue.of(back)
      ..xs = ListQueue.of(xs)
      ..x = x
      ..stop = stop
      ..phases = [for (final p in phases) p.copy()];
    c.front.addAll(front);
    c.s2.setAll(0, s2);
    c.cnt.setAll(0, cnt);
    return c;
  }

  Object toJson() => {
        'anchored': anchored,
        'rightClosed': rightClosed,
        'len': len,
        'front': [for (final v in front) encodeDouble(v)],
        'back': [for (final v in back) encodeDouble(v)],
        's2': encodeDoubles(s2),
        'cnt': cnt,
        'xs': [for (final v in xs) encodeDouble(v)],
        'x': encodeDouble(x),
        'phases': [for (final p in phases) p.toJson()],
      };

  static _Piece fromJson(Object? j) {
    final m = decodeMap(j);
    final anchored = field(m, 'anchored');
    final rightClosed = field(m, 'rightClosed');
    if (anchored is! bool || rightClosed is! bool) {
      throw const FormatException('invalid piece flags');
    }
    final p = _Piece(anchored)
      ..rightClosed = rightClosed
      ..len = decodeCount(field(m, 'len'))
      ..x = decodeDouble(field(m, 'x'));
    p.front.addAll(decodeDoubles(field(m, 'front')));
    p.back = ListQueue.of(decodeDoubles(field(m, 'back')));
    p.xs = ListQueue.of(decodeDoubles(field(m, 'xs')));
    final s2 = decodeDoubles(field(m, 's2'));
    final cnt = decodeList(field(m, 'cnt'));
    final phases = decodeList(field(m, 'phases'));
    final edge = math.min(p.len, _edge);
    if (p.front.length != edge ||
        p.back.length != edge ||
        p.xs.length != math.min(p.len + 1, kNoiseSegment) ||
        s2.length != 32 ||
        cnt.length != 32 ||
        phases.length != (anchored ? 1 : 32)) {
      throw const FormatException('inconsistent piece');
    }
    p.s2.setAll(0, s2);
    var interior = 0;
    for (var r = 0; r < 32; r++) {
      p.cnt[r] = decodeCount(cnt[r]);
      interior += p.cnt[r];
    }
    if (interior != math.max(0, p.len - 2 * _edge)) {
      throw const FormatException('piece interior count');
    }
    p.phases = [for (final ph in phases) _Phase.fromJson(ph)];
    return p;
  }
}

/// One 5-min window's breathing-test record: its beats' RR, its in-window
/// differences, and its 128-beat segments' lag sums.
class _Win {
  double rrSum = 0;
  int rrN = 0;
  double sq = 0;
  int n = 0;
  int segs = 0;
  final Float64List r = Float64List(_lags);

  void addAll(_Win o) {
    rrSum += o.rrSum;
    rrN += o.rrN;
    sq += o.sq;
    n += o.n;
    segs += o.segs;
    for (var m = 0; m < _lags; m++) {
      r[m] += o.r[m];
    }
  }

  /// The segments of one finished in-window run (from its start, as the
  /// batch walks them).
  void addRun(List<double> diffs) {
    const n = 128;
    final x = List<double>.filled(diffs.length + 1, 0.0);
    for (var i = 0; i < diffs.length; i++) {
      x[i + 1] = x[i] + diffs[i];
    }
    final v = Float64List(n);
    for (var s = 0; s + n <= x.length; s += n ~/ 2) {
      var mean = 0.0;
      for (var i = 0; i < n; i++) {
        mean += x[s + i];
      }
      mean /= n;
      for (var i = 0; i < n; i++) {
        v[i] = (x[s + i] - mean) * hann128[i];
      }
      for (var m = 0; m < n; m++) {
        var acc = 0.0;
        for (var i = 0; i + m < n; i++) {
          acc += v[i] * v[i + m];
        }
        r[m] += acc;
      }
      segs++;
    }
  }

  /// [windowPsd] of this window at cycles-per-beat frequencies [f]:
  /// Σ_segments |Σ v e^{iθk}|² = R0 + 2 Σ_m R_m cos(mθ), over the segments.
  List<double>? psd(List<double> f) {
    if (segs == 0) return null;
    return [
      for (final fr in f) _cosSeries(2 * math.pi * fr) / segs,
    ];
  }

  double _cosSeries(double theta) {
    final c1 = math.cos(theta);
    var prev = 1.0, cur = c1; // cos(0), cos(θ)
    var sum = r[0];
    for (var m = 1; m < _lags; m++) {
      sum += 2 * r[m] * cur;
      final next = 2 * c1 * cur - prev;
      prev = cur;
      cur = next;
    }
    return sum;
  }

  _Win copy() => _Win()..addAll(this);

  Object toJson() => [
        encodeDouble(rrSum),
        rrN,
        encodeDouble(sq),
        n,
        segs,
        encodeDoubles(r),
      ];

  static _Win fromJson(Object? j) {
    final l = decodeList(j);
    if (l.length != 6) throw const FormatException('invalid window');
    final w = _Win()
      ..rrSum = decodeDouble(l[0])
      ..rrN = decodeCount(l[1])
      ..sq = decodeDouble(l[2])
      ..n = decodeCount(l[3])
      ..segs = decodeCount(l[4]);
    final r = decodeDoubles(l[5]);
    if (r.length != _lags) throw const FormatException('invalid window lags');
    w.r.setAll(0, r);
    return w;
  }
}

/// An in-window run cut by a chunk edge: raw (a window bounds it).
class _WinRun {
  _WinRun(this.w, {required this.anchored});
  final int w;
  bool anchored;
  bool closed = false;
  List<double> diffs = [];

  _WinRun copy() => _WinRun(w, anchored: anchored)
    ..closed = closed
    ..diffs = List.of(diffs);

  Object toJson() => [
        w,
        anchored,
        closed,
        [for (final d in diffs) encodeDouble(d)]
      ];

  static _WinRun? fromJson(Object? j) {
    if (j == null) return null;
    final l = decodeList(j);
    if (l.length != 4 || l[0] is! int || l[1] is! bool || l[2] is! bool) {
      throw const FormatException('invalid window run');
    }
    return _WinRun(l[0] as int, anchored: l[1] as bool)
      ..closed = l[2] as bool
      ..diffs = decodeDoubles(l[3]).toList();
  }
}

class JitterState {
  int n = 0;
  double firstNn = 0, firstT = 0, lastNn = 0, lastT = 0;
  int lastW = 0;

  /// The run cut by the state's left edge (alignment unknown).
  _Piece? head;

  /// The run cut by its right edge, when a seam lies inside the state.
  _Piece? tail;
  NoiseShareSums closed = NoiseShareSums();
  double ssd = 0;
  int nd = 0;
  // Only coarseLattice reads magnitudes numerically; it ignores their order.
  // Checkpoints sort these sets on encode to retain their original ordering.
  Set<double> mags = <double>{};

  final SplayTreeMap<int, _Win> wins = SplayTreeMap<int, _Win>();
  _WinRun? headRun, tailRun;
  double winSsd = 0;
  int winNd = 0;
  Set<double> winMags = <double>{};

  JitterState copy() {
    final c = JitterState()
      ..n = n
      ..firstNn = firstNn
      ..firstT = firstT
      ..lastNn = lastNn
      ..lastT = lastT
      ..lastW = lastW
      ..head = head?.copy()
      ..tail = tail?.copy()
      ..ssd = ssd
      ..nd = nd
      ..mags = Set.of(mags)
      ..headRun = headRun?.copy()
      ..tailRun = tailRun?.copy()
      ..winSsd = winSsd
      ..winNd = winNd
      ..winMags = Set.of(winMags);
    _addSums(c.closed, closed);
    for (final e in wins.entries) {
      c.wins[e.key] = e.value.copy();
    }
    return c;
  }
}

void _addSums(NoiseShareSums into, NoiseShareSums from) {
  for (var k = kNoiseLoBin; k <= kNoiseHiBin; k++) {
    into.psd[k] += from.psd[k];
  }
  into.pSum += from.pSum;
  into.p2Sum += from.p2Sum;
  into.segs += from.segs;
  into.wsd += from.wsd;
  into.wsum += from.wsum;
}

/// What the jitter gate reads, for a finished state.
class JitterEvidence {
  JitterEvidence(this.sums, this.mags, this.windows, this.winSsd, this.winNd,
      this.winMags);
  final NoiseShareSums sums;
  final Iterable<double> mags;
  final List<_Win> windows;
  final double winSsd;
  final int winNd;
  final Iterable<double> winMags;

  /// `_jitterRefused` from these sums.
  bool refused() {
    final share = noiseShareFrom(sums,
        lattice: () => coarseLattice(mags, sums.ssd / sums.nd));
    return share == null || share >= kNnDiffNoiseShareCeiling;
  }

  /// `_breathingRmssd` from the window records.
  double? breathingRmssd() {
    final meanRr = [for (final w in windows) w.rrSum / w.rrN];
    final idx = steadyBreathingFrom(
      windows: windows.length,
      meanRrMs: meanRr,
      psdAt: (w, f) => windows[w].psd(f),
      diffs: (w) => windows[w].n,
      addSquares: (w, acc) => acc + windows[w].sq,
      allSsd: winSsd,
      allNd: winNd,
      lattice: (msd) => coarseLattice(winMags, msd),
    );
    if (idx == null) return null;
    var ss = 0.0, n = 0;
    for (final i in idx) {
      ss += windows[i].sq;
      n += windows[i].n;
    }
    return n == 0 ? null : math.sqrt(ss / n);
  }
}

/// The jitter-gate evidence over a beat batch (see the header).
class JitterEvidenceAggregator
    extends Aggregator<JitterState, Beats, JitterEvidence> {
  const JitterEvidenceAggregator({this.originMs, required this.gapAware});
  final double? originMs;
  final bool gapAware;

  int _window(double t) {
    final origin = originMs;
    if (origin == null) throw StateError('gap-aware HRV needs originMs');
    return ((_t(t) - origin) / _windowMs).floor();
  }

  bool _contiguous(double prevT, double t, double nn) =>
      !gapAware || _t(t) - _t(prevT) <= nn + 0.5;

  @override
  JitterState empty() => JitterState();

  _Win _win(JitterState s, int w) => s.wins.putIfAbsent(w, _Win.new);

  void _inRun(JitterState s, double d) {
    s.ssd += d * d;
    s.nd++;
    s.mags.add(d.abs());
  }

  void _inWindow(JitterState s, int w, double d) {
    final win = _win(s, w);
    win.sq += d * d;
    win.n++;
    s.winSsd += d * d;
    s.winNd++;
    s.winMags.add(d.abs());
  }

  void _closePiece(JitterState s, _Piece p) => p.finalizeInto(s.closed);

  void _closeRun(JitterState s, _WinRun r) => _win(s, r.w).addRun(r.diffs);

  @override
  JitterState addSlice(JitterState s, Beats batch, int start, int end) {
    for (var i = start; i < end; i++) {
      final v = batch.nnMs[i], t = batch.timeMs[i];
      final w = gapAware ? _window(t) : 0;
      if (s.n == 0) {
        s.firstNn = v;
        s.firstT = t;
        s.head = _Piece(false);
        if (gapAware) s.headRun = _WinRun(w, anchored: false);
      } else {
        final contig = _contiguous(s.lastT, t, v);
        final d = v - s.lastNn;
        if (contig) {
          _inRun(s, d);
          (s.tail ?? s.head!).append(d);
        } else if (s.tail == null) {
          s.head!.rightClosed = true;
          s.tail = _Piece(true);
        } else {
          _closePiece(s, s.tail!);
          s.tail = _Piece(true);
        }
        if (gapAware) {
          if (contig && w == s.lastW) {
            _inWindow(s, w, d);
            (s.tailRun ?? s.headRun!).diffs.add(d);
          } else {
            if (s.tailRun == null) {
              s.headRun!.closed = true;
            } else {
              _closeRun(s, s.tailRun!);
            }
            s.tailRun = _WinRun(w, anchored: true);
          }
        }
      }
      if (gapAware) {
        final win = _win(s, w);
        win.rrSum += v;
        win.rrN++;
      }
      s.n++;
      s.lastNn = v;
      s.lastT = t;
      s.lastW = w;
    }
    return s;
  }

  @override
  JitterState combine(JitterState l, JitterState r) {
    if (r.n == 0) return l;
    if (l.n == 0) return r;
    final contig = _contiguous(l.lastT, r.firstT, r.firstNn);
    final d = r.firstNn - l.lastNn;
    // Noise-share pieces.
    final lOpen = l.tail ?? l.head!;
    final rHead = r.head!;
    if (contig) {
      _inRun(l, d);
      lOpen.join(d, rHead);
      if (l.tail == null) {
        l.tail = r.tail; // the joined head is closed iff r had a seam
      } else if (r.tail != null) {
        _closePiece(l, lOpen);
        l.tail = r.tail;
      }
    } else {
      if (l.tail == null) {
        l.head!.rightClosed = true;
      } else {
        _closePiece(l, l.tail!);
      }
      rHead.anchor();
      if (r.tail != null) {
        _closePiece(l, rHead);
        l.tail = r.tail;
      } else {
        l.tail = rHead;
      }
    }
    _addSums(l.closed, r.closed);
    l.ssd += r.ssd;
    l.nd += r.nd;
    l.mags.addAll(r.mags);
    // Breathing windows.
    if (gapAware) {
      for (final e in r.wins.entries) {
        _win(l, e.key).addAll(e.value);
      }
      final lRun = l.tailRun ?? l.headRun!;
      final rRun = r.headRun!;
      if (contig && l.lastW == _window(r.firstT)) {
        _inWindow(l, l.lastW, d);
        lRun.diffs
          ..add(d)
          ..addAll(rRun.diffs);
        if (l.tailRun == null) {
          lRun.closed = rRun.closed;
          l.tailRun = r.tailRun;
        } else if (r.tailRun != null) {
          _closeRun(l, lRun);
          l.tailRun = r.tailRun;
        }
      } else {
        if (l.tailRun == null) {
          l.headRun!.closed = true;
        } else {
          _closeRun(l, l.tailRun!);
        }
        rRun.anchored = true;
        if (r.tailRun != null) {
          _closeRun(l, rRun);
          l.tailRun = r.tailRun;
        } else {
          l.tailRun = rRun;
        }
      }
      l.winSsd += r.winSsd;
      l.winNd += r.winNd;
      l.winMags.addAll(r.winMags);
    }
    l.n += r.n;
    l.lastNn = r.lastNn;
    l.lastT = r.lastT;
    l.lastW = r.lastW;
    return l;
  }

  @override
  JitterEvidence finish(JitterState state) {
    final s = state.copy();
    // The left edge is the series start: a run starts there.
    if (s.head != null) {
      s.head!.anchor();
      _closePiece(s, s.head!);
    }
    if (s.tail != null) _closePiece(s, s.tail!);
    if (s.headRun != null) _closeRun(s, s.headRun!);
    if (s.tailRun != null) _closeRun(s, s.tailRun!);
    s.closed
      ..ssd = s.ssd
      ..nd = s.nd;
    return JitterEvidence(
        s.closed, s.mags, s.wins.values.toList(), s.winSsd, s.winNd, s.winMags);
  }

  @override
  bool get persistable => true;

  @override
  Object? encodeState(JitterState s) => {
        'type': 'HrvJitterEvidence',
        'version': 1,
        'n': s.n,
        'first': [encodeDouble(s.firstNn), encodeDouble(s.firstT)],
        'last': [encodeDouble(s.lastNn), encodeDouble(s.lastT), s.lastW],
        'head': s.head?.toJson(),
        'tail': s.tail?.toJson(),
        'closed': [
          for (var k = kNoiseLoBin; k <= kNoiseHiBin; k++)
            encodeDouble(s.closed.psd[k]),
          encodeDouble(s.closed.pSum),
          encodeDouble(s.closed.p2Sum),
          s.closed.segs,
          encodeDouble(s.closed.wsd),
          encodeDouble(s.closed.wsum),
        ],
        'ssd': encodeDouble(s.ssd),
        'nd': s.nd,
        'mags': [for (final m in (s.mags.toList()..sort())) encodeDouble(m)],
        'wins': [
          for (final e in s.wins.entries) [e.key, e.value.toJson()]
        ],
        'headRun': s.headRun?.toJson(),
        'tailRun': s.tailRun?.toJson(),
        'winSsd': encodeDouble(s.winSsd),
        'winNd': s.winNd,
        'winMags': [for (final m in (s.winMags.toList()..sort())) encodeDouble(m)],
      };

  @override
  JitterState decodeState(Object? json) {
    final m = decodeMap(json);
    if (field(m, 'type') != 'HrvJitterEvidence' || field(m, 'version') != 1) {
      throw const FormatException('unsupported HrvJitterEvidence');
    }
    final s = JitterState()..n = decodeCount(field(m, 'n'));
    final first = decodeList(field(m, 'first'));
    final last = decodeList(field(m, 'last'));
    if (first.length != 2 || last.length != 3 || last[2] is! int) {
      throw const FormatException('invalid edges');
    }
    s
      ..firstNn = decodeDouble(first[0])
      ..firstT = decodeDouble(first[1])
      ..lastNn = decodeDouble(last[0])
      ..lastT = decodeDouble(last[1])
      ..lastW = last[2] as int;
    final head = field(m, 'head'), tail = field(m, 'tail');
    s.head = head == null ? null : _Piece.fromJson(head);
    s.tail = tail == null ? null : _Piece.fromJson(tail);
    final closed = decodeList(field(m, 'closed'));
    if (closed.length != _bins + 5) throw const FormatException('invalid sums');
    for (var k = 0; k < _bins; k++) {
      s.closed.psd[k + kNoiseLoBin] = decodeDouble(closed[k]);
    }
    s.closed
      ..pSum = decodeDouble(closed[_bins])
      ..p2Sum = decodeDouble(closed[_bins + 1])
      ..segs = decodeCount(closed[_bins + 2])
      ..wsd = decodeDouble(closed[_bins + 3])
      ..wsum = decodeDouble(closed[_bins + 4]);
    s
      ..ssd = decodeDouble(field(m, 'ssd'))
      ..nd = decodeCount(field(m, 'nd'))
      ..mags = Set.of(decodeDoubles(field(m, 'mags')))
      ..headRun = _WinRun.fromJson(field(m, 'headRun'))
      ..tailRun = _WinRun.fromJson(field(m, 'tailRun'))
      ..winSsd = decodeDouble(field(m, 'winSsd'))
      ..winNd = decodeCount(field(m, 'winNd'))
      ..winMags = Set.of(decodeDoubles(field(m, 'winMags')));
    for (final e in decodeList(field(m, 'wins'))) {
      final pair = decodeList(e);
      if (pair.length != 2 || pair[0] is! int) {
        throw const FormatException('invalid window entry');
      }
      if (s.wins.containsKey(pair[0])) {
        throw const FormatException('duplicate window');
      }
      s.wins[pair[0] as int] = _Win.fromJson(pair[1]);
    }
    // The parts must describe one state.
    final pieces =
        (s.head == null ? 0 : s.head!.len) + (s.tail == null ? 0 : s.tail!.len);
    final ok = (s.n == 0) == (s.head == null) &&
        (s.tail == null ||
            (s.head != null &&
                s.head!.rightClosed &&
                s.tail!.anchored &&
                !s.tail!.rightClosed)) &&
        (s.head == null || !s.head!.anchored) &&
        (s.tail != null || s.head == null || !s.head!.rightClosed) &&
        s.nd >= pieces &&
        s.nd < math.max(1, s.n) &&
        s.winNd <= s.nd &&
        s.mags.length <= s.nd &&
        s.winMags.length <= s.winNd &&
        (gapAware
            ? ((s.n == 0) == (s.headRun == null) &&
                (s.tailRun == null ||
                    (s.headRun!.closed && s.tailRun!.anchored)) &&
                (s.headRun == null || !s.headRun!.anchored) &&
                s.wins.values.fold<int>(0, (a, w) => a + w.rrN) == s.n &&
                s.wins.values.fold<int>(0, (a, w) => a + w.n) == s.winNd)
            : (s.headRun == null && s.tailRun == null && s.wins.isEmpty));
    if (!ok) throw const FormatException('inconsistent HrvJitterEvidence');
    return s;
  }
}
