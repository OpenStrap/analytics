// Lipponen & Tarvainen 2019 classification with Peltola 2012 correction policy.
// The unpublished artifact-run cap is an internal rule, ESTIMATE with low
// confidence:
// over-cap runs become gaps and each side is re-corrected. Without a cap split
// the result equals uncapped correction. Shared kernel arithmetic and raw seam
// context preserve capped batch NN/classes; settled stream plus provisional tail
// equals capped batch. RrSandwich preserves source-beat absolute timestamps;
// uncapped arbitrarily long artifact runs have no exactness guarantee.
// FOUNDATION — streaming RR artifact correction.
//
// [RrCorrector] is `correctRr` (rr_correction.dart) turned into a fold: feed
// beats in chunks, get back the output that became FINAL with each chunk, and
// ask for the provisional tail on demand. At every prefix of the input,
//
//     (all settled output so far) ++ (snapshot().tail*)  ==  correctRr(prefix)
//
// bit for bit: nn, nnTimesMs, per-beat classes, counts, cleanFraction. Nothing
// is imputed here either: a beat whose neighbours are not there yet is not
// guessed at, it simply is not settled.
//
// Why a beat can be final long before the series ends: its class depends only
// on a centred window of `windowBeats ~/ 2` beats each side (twice that for
// the second threshold), one carried class, and — for the spline — the two
// nearest normal beats either side. Beats closer to the end of the data than
// that are PROVISIONAL, because `correctRr` clips its windows at the end.
//
// Derivation, with H = windowBeats ~/ 2 (45 at the default 91):
//
//   beat clock  t[i]    prefix recurrence (current time, previous timestamp)
//   dRR[i]      rr[i] - rr[i-1]                       local
//   th1, med    QD of dRR / median of rr, over [i-H, i+H]   needs rr up to i+H
//   mRR         from rr[i] and med[i]                       needs rr up to i+H
//   th2         QD of mRR over [i-H, i+H]                   needs rr up to i+2H
//   class       first pass from the above, then the compensatory-pair rule,
//               which reads only the previous FINAL class: one carried class.
//   output      an isolated artifact is spline-corrected from the two nearest
//               normal beats each side (left pair carried, right pair needs
//               classes up to the second normal after it); a run is dropped.
//
// So output settles 2H beats + (artifact run length) + 2 normals behind the
// newest beat. Beats nearer the end than that are provisional because
// `correctRr` clips its windows at the end of the data; [RrCorrector.snapshot]
// re-evaluates just that tail with the same clipping.
//
// With a cap, a future split also changes the windows to its left. The capped
// path keeps 4H + 2K + 4 beats provisional (248 at the defaults), then up to K
// more to avoid committing part of a short artifact run. Uncapped mode retains
// the original stage-by-stage latency described above.
//
// The arithmetic (window, threshold, class, spline) is shared with `correctRr`
// through rr_correction_kernel.dart.

import 'dart:math' as math;

import 'rr_correction.dart';
import 'rr_correction_kernel.dart';

/// What [RrCorrector.fold] hands back: the output that became FINAL with that
/// fold, in order, ready to append to what the caller already holds.
class RrSettled {
  /// Newly final cleaned NN intervals (ms), as `correctRr(...).nn` would hold.
  final List<double> nn;

  /// Beat times (ms) for [nn], as `correctRr(...).nnTimesMs` would hold.
  final List<double> nnTimes;

  /// Classes of the beats whose class became final with this fold, i.e. input
  /// beats `[classifiedBeats before the fold, classifiedBeats after)`. A class
  /// is final earlier than its output: a lone artifact waits for two normal
  /// beats on its right before it can be spline-corrected.
  final List<BeatClass> classes;

  const RrSettled({
    required this.nn,
    required this.nnTimes,
    required this.classes,
  });
}

/// The part of `correctRr(all beats so far)` that can still change, plus the
/// running totals. Recomputed on every [RrCorrector.snapshot]; never stored.
class RrSnapshot {
  /// Beats folded so far.
  final int n;

  /// Provisional NN / times that follow everything [RrCorrector.fold] has
  /// settled so far.
  final List<double> tailNn;
  final List<double> tailNnTimes;

  /// Provisional classes of the beats `[classifiedBeats, n)`.
  final List<BeatClass> tailClasses;

  /// Totals as `correctRr(all beats so far)` reports them.
  final int normalCount, droppedCount, correctedCount;

  /// Beats whose output is final / whose class is final.
  final int settledBeats, classifiedBeats;

  const RrSnapshot({
    required this.n,
    required this.tailNn,
    required this.tailNnTimes,
    required this.tailClasses,
    required this.normalCount,
    required this.droppedCount,
    required this.correctedCount,
    required this.settledBeats,
    required this.classifiedBeats,
  });

  /// `correctRr`'s `cleanFraction`: 0 on an empty series, never NaN.
  double get cleanFraction => n == 0 ? 0 : normalCount / n;
}

/// Streaming Lipponen–Tarvainen correction. Same parameters as [correctRr].
///
/// Append-only: it cannot take beats back. Anything that changes data behind
/// the settled edge means starting a new corrector.
class RrCorrector {
  final double alpha;
  final int windowBeats;
  final double minThresholdMs;
  final double reanchorGapMs;

  /// Longest artifact run carried; a longer one is a gap. null = uncapped.
  /// Same meaning as [correctRr]'s `maxArtifactRun`.
  final int? maxArtifactRun;
  final int _h;
  final _CappedState? _capState;

  // ---- persisted state ----
  int _n = 0; // beats folded
  bool? _wall; // timestamps given for this stream (null until the first beat)
  double _origin = 0, _cur = 0, _prevTs = 0, _prevRr = 0;
  int _off = 0; // global index of _rr[0]
  final List<double> _rr = [], _t = [], _d = [];
  int _c1 = 0; // beats whose med / mRR / th1 are final
  int _c2 = 0; // beats whose class is final
  int _ce = 0; // beats whose output is final (handed out)
  final List<int> _fcls = []; // final classes for [_ce, _c2)
  int _lastFinal = 0; // class index of beat _c2 - 1
  int _normalFinal = 0;
  int _dropped = 0, _corrected = 0;
  final List<double> _lastNormals = []; // <= 2, oldest first

  // ---- derived, rebuilt on restore ----
  int _so = 0; // global index of _med[0]
  final List<double> _med = [], _mrr = [], _th1 = [];
  final _wd = SortedMultiset(), _wr = SortedMultiset(), _wm = SortedMultiset();
  int _wPos = -1, _w2Pos = -1;

  RrCorrector({
    this.alpha = 5.2,
    this.windowBeats = 91,
    this.minThresholdMs = 100,
    this.reanchorGapMs = 1000,
    this.maxArtifactRun = kMaxArtifactRun,
  }) : _h = windowBeats ~/ 2,
       _capState = maxArtifactRun == null ? null : _CappedState() {
    if (windowBeats < 1) throw ArgumentError.value(windowBeats, 'windowBeats');
    if (maxArtifactRun != null && maxArtifactRun! < 1) {
      throw ArgumentError.value(maxArtifactRun, 'maxArtifactRun');
    }
  }

  /// Restores a corrector from [toJson]. Throws [FormatException] on a
  /// checkpoint of another type or version, or one that is malformed.
  factory RrCorrector.fromJson(Map<String, dynamic> json) {
    try {
      return _restore(json);
    } on FormatException {
      rethrow;
    } catch (e) {
      throw FormatException('malformed RrCorrector checkpoint: $e');
    }
  }

  static RrCorrector _restore(Map<String, dynamic> j) {
    if (j['type'] != 'RrCorrector') {
      throw FormatException('not an RrCorrector checkpoint: ${j['type']}');
    }
    if (j['version'] != 2) {
      throw FormatException('unsupported RrCorrector version ${j['version']}');
    }
    List<double> doubles(String k) =>
        [for (final x in j[k] as List) (x as num).toDouble()];
    final c = RrCorrector(
      maxArtifactRun: j['maxArtifactRun'] as int?,
      alpha: (j['alpha'] as num).toDouble(),
      windowBeats: j['windowBeats'] as int,
      minThresholdMs: (j['minThresholdMs'] as num).toDouble(),
      reanchorGapMs: (j['reanchorGapMs'] as num).toDouble(),
    );
    if (!j.containsKey('maxArtifactRun')) {
      throw const FormatException('missing artifact cap');
    }
    if (c._capState != null) {
      c._capState.restore(j['capped'] as Map<String, dynamic>, c._h);
      return c;
    }
    c._n = j['n'] as int;
    c._wall = j['wall'] as bool?;
    c._origin = (j['origin'] as num).toDouble();
    c._cur = (j['cur'] as num).toDouble();
    c._prevTs = (j['prevTs'] as num).toDouble();
    c._prevRr = (j['prevRr'] as num).toDouble();
    c._off = j['off'] as int;
    c._rr.addAll(doubles('rr'));
    c._t.addAll(doubles('t'));
    c._d.addAll(doubles('d'));
    c._c1 = j['c1'] as int;
    c._c2 = j['c2'] as int;
    c._ce = j['ce'] as int;
    c._fcls.addAll((j['fcls'] as List).cast<int>());
    c._lastFinal = j['lastFinal'] as int;
    c._normalFinal = j['normalFinal'] as int;
    c._dropped = j['dropped'] as int;
    c._corrected = j['corrected'] as int;
    c._lastNormals.addAll(doubles('lastNormals'));
    if (c._n > 0 && c._wall == null) {
      throw const FormatException('invalid wall');
    }
    if (c._dropped < 0 || c._dropped > c._ce) {
      throw const FormatException('invalid dropped');
    }
    if (c._corrected < 0 || c._corrected > c._ce - c._dropped) {
      throw const FormatException('invalid corrected');
    }
    if (c._normalFinal < 0 || c._normalFinal > c._c2) {
      throw const FormatException('invalid normalFinal');
    }
    final buffered = c._n - c._off;
    final ok = c._off >= 0 &&
        buffered >= 0 &&
        c._rr.length == buffered &&
        c._t.length == buffered &&
        c._d.length == buffered &&
        c._ce >= c._off &&
        c._ce <= c._c2 &&
        c._c2 <= c._c1 &&
        c._c1 <= c._n &&
        c._fcls.length == c._c2 - c._ce &&
        c._fcls.every((k) => k >= 0 && k < BeatClass.values.length) &&
        c._lastFinal >= 0 &&
        c._lastFinal < BeatClass.values.length &&
        c._lastNormals.length <= 2 &&
        c._off <= math.max(0, c._c2 - 2 * c._h - 1);
    if (!ok) throw const FormatException('inconsistent RrCorrector checkpoint');
    c._rebuildStageArrays();
    return c;
  }

  /// Checkpoint: `{'version': 2, 'type': 'RrCorrector', ...}`, plain JSON
  /// (survives `jsonEncode`/`jsonDecode` bit-exactly), and bounded — it holds
  /// the unsettled window, not the series.
  Map<String, dynamic> toJson() {
    if (_capState != null) {
      return {
        'version': 2, 'type': 'RrCorrector',
        'maxArtifactRun': maxArtifactRun, 'alpha': alpha,
        'windowBeats': windowBeats, 'minThresholdMs': minThresholdMs,
        'reanchorGapMs': reanchorGapMs, 'capped': _capState.toJson(),
      };
    }
    return {
        'version': 2,
        'maxArtifactRun': maxArtifactRun,
        'type': 'RrCorrector',
        'alpha': alpha,
        'windowBeats': windowBeats,
        'minThresholdMs': minThresholdMs,
        'reanchorGapMs': reanchorGapMs,
        'n': _n,
        'wall': _wall,
        'origin': _origin,
        'cur': _cur,
        'prevTs': _prevTs,
        'prevRr': _prevRr,
        'off': _off,
        'rr': _rr,
        't': _t,
        'd': _d,
        'c1': _c1,
        'c2': _c2,
        'ce': _ce,
        'fcls': _fcls,
        'lastFinal': _lastFinal,
        'normalFinal': _normalFinal,
        'dropped': _dropped,
        'corrected': _corrected,
        'lastNormals': _lastNormals,
      };
  }

  /// Beats whose output is final.
  int get settledBeats => _capState?.edge ?? _ce;

  /// Appends beats. [tsMs] (same length as [rrMs]) is either given on EVERY
  /// fold or on none; mixing throws [StateError]. A non-finite RR throws
  /// [ArgumentError] and leaves the corrector unchanged. An empty chunk is a
  /// no-op.
  RrSettled fold(List<double> rrMs, {List<double>? tsMs}) {
    if (_capState != null) return _capState.fold(this, rrMs, tsMs);
    if (rrMs.isEmpty) {
      return const RrSettled(nn: [], nnTimes: [], classes: []);
    }
    // Everything that can throw happens before the first mutation.
    final wall = tsMs != null;
    if (wall && tsMs.length != rrMs.length) {
      throw ArgumentError('tsMs has ${tsMs.length} entries for '
          '${rrMs.length} beats');
    }
    if (_wall != null && _wall != wall) {
      throw StateError('timestamps must be given on every fold or on none');
    }
    for (var k = 0; k < rrMs.length; k++) {
      if (!rrMs[k].isFinite) throw ArgumentError('non-finite RR at index $k');
      if (wall && !tsMs[k].isFinite) {
        throw ArgumentError('non-finite timestamp at index $k');
      }
    }
    _wall = wall;
    for (var k = 0; k < rrMs.length; k++) {
      final r = rrMs[k];
      final ts = wall ? tsMs[k] : 0.0;
      if (_n == 0) {
        _origin = wall ? ts - r : 0.0;
        _cur = 0.0;
      }
      // Same clock as `correctRr`'s beat times: cumsum inside a contiguous run,
      // re-anchored to the real timestamp at a dropout, never backwards.
      final dropout = wall && _n > 0 && (ts - _prevTs) - r > reanchorGapMs;
      final anchored = wall ? ts - _origin : 0.0;
      _cur = (dropout && anchored > _cur) ? anchored : _cur + r;
      if (wall) _prevTs = ts;
      _rr.add(r);
      _t.add(_cur);
      _d.add(_n == 0 ? 0.0 : r - _prevRr);
      _prevRr = r;
      _n++;
    }
    final nn = <double>[], times = <double>[];
    final classes = <BeatClass>[];
    _advance(classes);
    _emitCommitted(nn, times);
    _compact();
    return RrSettled(nn: nn, nnTimes: times, classes: classes);
  }

  double _rrAt(int g) => _rr[g - _off];
  double _dAt(int g) => _d[g - _off];
  double _tAt(int g) => _t[g - _off];

  void _advance(List<BeatClass> classes) {
    // Under 3 beats `correctRr` takes its short branch; nothing settles yet.
    if (_n < 3) return;
    while (_c1 + _h <= _n - 1) {
      _stage1(_c1);
      _c1++;
    }
    while (_c2 + 2 * _h <= _n - 1) {
      classes.add(_stage2(_c2));
      _c2++;
    }
  }

  // th1 / med / mRR for beat g, whose window [max(0, g-h), g+h] is fully inside
  // the data.
  void _stage1(int g) {
    final h = _h;
    if (_wPos == g - 1 && _wPos >= 0) {
      _wd.add(_dAt(g + h));
      _wr.add(_rrAt(g + h));
      if (g - 1 - h >= 0) {
        _wd.remove(_dAt(g - 1 - h));
        _wr.remove(_rrAt(g - 1 - h));
      }
    } else {
      final lo = math.max(0, g - h);
      _wd.resetFrom([for (var k = lo; k <= g + h; k++) _dAt(k)]);
      _wr.resetFrom([for (var k = lo; k <= g + h; k++) _rrAt(k)]);
    }
    _wPos = g;
    final m = medianExcluding(_wr.a, _rrAt(g)) ?? _rrAt(g);
    _th1.add(thresholdOfSorted(_wd.a, alpha, minThresholdMs));
    _med.add(m);
    _mrr.add(medianDeviation(_rrAt(g), m));
  }

  BeatClass _stage2(int g) {
    final h = _h;
    if (_w2Pos == g - 1 && _w2Pos >= 0) {
      _wm.add(_mrr[g + h - _so]);
      if (g - 1 - h >= 0) _wm.remove(_mrr[g - 1 - h - _so]);
    } else {
      final lo = math.max(0, g - h);
      _wm.resetFrom([for (var k = lo; k <= g + h; k++) _mrr[k - _so]]);
    }
    _w2Pos = g;
    final th2 = thresholdOfSorted(_wm.a, alpha, minThresholdMs);
    final cls = _finalClass(g, _th1[g - _so], _med[g - _so], _mrr[g - _so],
        th2, _lastFinal);
    _fcls.add(cls.index);
    _lastFinal = cls.index;
    if (cls == BeatClass.normal) _normalFinal++;
    return cls;
  }

  /// Class of beat g given the class of g-1: first pass, then the
  /// compensatory-pair rule.
  BeatClass _finalClass(int g, double th1, double med, double mrr, double th2,
      int prevClass) {
    final rr = _rrAt(g), d = _dAt(g);
    final cls = classifyBeat(rr, d, th1, med, mrr, th2);
    if (g < 1 || cls != BeatClass.ectopic) return cls;
    return isRecoveryBeat(
            prevIsArtifact: prevClass != BeatClass.normal.index,
            rr: rr,
            dRR: d,
            dRRPrev: _dAt(g - 1),
            med: med)
        ? BeatClass.normal
        : cls;
  }

  // Output over classes [ce, limit). Shared by the committed pass (limit = c2,
  // isEnd false: an artifact whose fate is not decidable yet waits) and the
  // provisional pass (limit = n, isEnd true: the end of the data resolves it
  // exactly the way `correctRr` does). Returns the new ce.
  int _emit({
    required int ce,
    required int limit,
    required bool isEnd,
    required int Function(int g) clsAt,
    required List<double> lastNormals,
    required void Function(double nn, double t) put,
    required void Function(int runLen) drop,
    required void Function() corrected,
  }) {
    const normal = 0;
    while (ce < limit) {
      if (clsAt(ce) == normal) {
        put(_rrAt(ce), _tAt(ce));
        lastNormals.add(_rrAt(ce));
        if (lastNormals.length > 2) lastNormals.removeAt(0);
        ce++;
        continue;
      }
      var j = ce;
      while (j < limit && clsAt(j) != normal) {
        j++;
      }
      if (j == limit && !isEnd) break;
      final runLen = j - ce;
      if (runLen == 1) {
        final right = <double>[];
        var k = j;
        while (k < limit && right.length < 2) {
          if (clsAt(k) == normal) right.add(_rrAt(k));
          k++;
        }
        if (right.length < 2 && k == limit && !isEnd) break;
        final corr = splineMid(lastNormals, right);
        if (corr != null) {
          put(corr, _tAt(ce));
          corrected();
        } else {
          drop(1); // no anchors: an honest drop; the clock already elapsed
        }
      } else {
        drop(runLen);
      }
      ce = j;
    }
    return ce;
  }

  void _emitCommitted(List<double> nn, List<double> times) {
    final fo = _ce;
    _ce = _emit(
      ce: _ce,
      limit: _c2,
      isEnd: false,
      clsAt: (g) => _fcls[g - fo],
      lastNormals: _lastNormals,
      put: (v, t) {
        nn.add(v);
        times.add(t);
      },
      drop: (r) => _dropped += r,
      corrected: () => _corrected++,
    );
    final used = _ce - fo;
    if (used > 0) _fcls.removeRange(0, used);
  }

  /// Provisional tail and totals; does not change the corrector.
  RrSnapshot snapshot() {
    if (_capState != null) return _capState.snapshot(this);
    final n = _n;
    if (n == 0) {
      return const RrSnapshot(
          n: 0,
          tailNn: [],
          tailNnTimes: [],
          tailClasses: [],
          normalCount: 0,
          droppedCount: 0,
          correctedCount: 0,
          settledBeats: 0,
          classifiedBeats: 0);
    }
    if (n < 3) {
      // `correctRr`'s short branch: plausible beats pass, the rest are
      // long/short. Nothing is settled below 3 beats.
      final nn = <double>[], times = <double>[];
      final cl = <BeatClass>[];
      for (var g = 0; g < n; g++) {
        final ok = _rrAt(g) >= 300 && _rrAt(g) <= 2000;
        cl.add(ok ? BeatClass.normal : BeatClass.longShort);
        if (ok) {
          nn.add(_rrAt(g));
          times.add(_tAt(g));
        }
      }
      return RrSnapshot(
          n: n,
          tailNn: nn,
          tailNnTimes: times,
          tailClasses: cl,
          normalCount: nn.length,
          droppedCount: n - nn.length,
          correctedCount: 0,
          settledBeats: 0,
          classifiedBeats: 0);
    }
    final h = _h;
    final end = n - 1;
    // Provisional stage 1 for beats [c1, n): windows clipped at the end.
    final tMed = <double>[], tMrr = <double>[], tTh1 = <double>[];
    double mrrAt(int k) => k < _c1 ? _mrr[k - _so] : tMrr[k - _c1];
    for (var k = _c1; k < n; k++) {
      final lo = math.max(0, k - h), hi = math.min(end, k + h);
      final dd = <double>[for (var q = lo; q <= hi; q++) _dAt(q)]..sort();
      final rs = <double>[for (var q = lo; q <= hi; q++) _rrAt(q)]..sort();
      tTh1.add(thresholdOfSorted(dd, alpha, minThresholdMs));
      final m = medianExcluding(rs, _rrAt(k)) ?? _rrAt(k);
      tMed.add(m);
      tMrr.add(medianDeviation(_rrAt(k), m));
    }
    // Provisional classes for [c2, n).
    final tc = <int>[];
    var prev = _lastFinal;
    var normalTent = 0;
    for (var g = _c2; g < n; g++) {
      final lo = math.max(0, g - h), hi = math.min(end, g + h);
      final ms = <double>[for (var q = lo; q <= hi; q++) mrrAt(q)]..sort();
      final th2 = thresholdOfSorted(ms, alpha, minThresholdMs);
      final th1 = g < _c1 ? _th1[g - _so] : tTh1[g - _c1];
      final med = g < _c1 ? _med[g - _so] : tMed[g - _c1];
      final cls = _finalClass(g, th1, med, mrrAt(g), th2, prev);
      tc.add(cls.index);
      prev = cls.index;
      if (cls == BeatClass.normal) normalTent++;
    }
    // Provisional output over [ce, n).
    final fo = _ce;
    final ln = List<double>.of(_lastNormals);
    final nn = <double>[], times = <double>[];
    var dropped = _dropped, corrected = _corrected;
    _emit(
      ce: _ce,
      limit: n,
      isEnd: true,
      clsAt: (g) => g < _c2 ? _fcls[g - fo] : tc[g - _c2],
      lastNormals: ln,
      put: (v, t) {
        nn.add(v);
        times.add(t);
      },
      drop: (r) => dropped += r,
      corrected: () => corrected++,
    );
    return RrSnapshot(
      n: n,
      tailNn: nn,
      tailNnTimes: times,
      tailClasses: [for (final c in tc) BeatClass.values[c]],
      normalCount: _normalFinal + normalTent,
      droppedCount: dropped,
      correctedCount: corrected,
      settledBeats: _ce,
      classifiedBeats: _c2,
    );
  }

  /// Drops what no later beat can read: raw beats behind both the settled edge
  /// and the oldest window a pending stage-2 beat still needs, and stage
  /// arrays behind the oldest stage-2 window.
  void _compact() {
    final h = _h;
    final newOff = math.max(0, math.min(_ce, _c2 - 2 * h - 1));
    if (newOff > _off) {
      final drop = newOff - _off;
      _rr.removeRange(0, drop);
      _t.removeRange(0, drop);
      _d.removeRange(0, drop);
      _off = newOff;
    }
    final newSo = math.max(0, _c2 - h - 1);
    if (newSo > _so && _med.isNotEmpty) {
      final drop = math.min(newSo - _so, _med.length);
      _med.removeRange(0, drop);
      _mrr.removeRange(0, drop);
      _th1.removeRange(0, drop);
      _so += drop;
    }
  }

  /// The stage arrays are pure functions of the buffered raw beats; rebuild
  /// them rather than persist them.
  void _rebuildStageArrays() {
    final h = _h;
    _so = math.max(0, _c2 - h - 1);
    _med.clear();
    _mrr.clear();
    _th1.clear();
    for (var g = _so; g < _c1; g++) {
      final lo = math.max(0, g - h), hi = g + h;
      final dd = <double>[for (var q = lo; q <= hi; q++) _dAt(q)]..sort();
      final rs = <double>[for (var q = lo; q <= hi; q++) _rrAt(q)]..sort();
      _th1.add(thresholdOfSorted(dd, alpha, minThresholdMs));
      final m = medianExcluding(rs, _rrAt(g)) ?? _rrAt(g);
      _med.add(m);
      _mrr.add(medianDeviation(_rrAt(g), m));
    }
    _wPos = -1;
    _w2Pos = -1;
  }
}

// The cap can cut a window that an uncapped detector has already read. Keep
// that decision provisional until both the run and its left influence have
// settled. No stage-1/2 arrays from across a cut are ever reused.
class _CappedState {
  int n = 0, off = 0, edge = 0, segmentStart = 0;
  int normal = 0, dropped = 0, corrected = 0;
  bool? wall;
  bool gap = false, hardGap = false;
  double origin = 0, clock = 0;
  BeatClass previous = BeatClass.normal;
  final rr = <double>[], ts = <double>[], normals = <double>[];

  RrCapWindow evaluate(RrCorrector c) => RrCapWindow.evaluate(rr,
      ts: wall == true ? ts : null,
      cap: c.maxArtifactRun!,
      alpha: c.alpha,
      windowBeats: c.windowBeats,
      minThresholdMs: c.minThresholdMs,
      reanchorGapMs: c.reanchorGapMs,
      from: edge - off,
      previous: previous,
      leftNormals: normals,
      leadingGap: gap,
      leadingHardGap: hardGap,
      segmentStart: math.max(0, segmentStart - off),
      clock: clock,
      origin: origin);

  RrSettled fold(RrCorrector c, List<double> values, List<double>? times) {
    if (values.isEmpty)
      return const RrSettled(nn: [], nnTimes: [], classes: []);
    if (times != null && times.length != values.length) {
      throw ArgumentError('RR and timestamp lengths differ');
    }
    if (wall != null && wall != (times != null)) {
      throw StateError('timestamps must be given on every fold or on none');
    }
    for (var i = 0; i < values.length; i++) {
      if (!values[i].isFinite || (times != null && !times[i].isFinite)) {
        throw ArgumentError('non-finite beat at index $i');
      }
    }
    wall = times != null;
    if (n == 0) origin = times == null ? 0 : times.first - values.first;
    rr.addAll(values);
    if (times != null) ts.addAll(times);
    n += values.length;
    final w = evaluate(c);
    final nn = <double>[], nt = <double>[], classes = <BeatClass>[];
    // Two centred threshold windows, the cap decision and its backwards
    // influence. Extra normal anchors settle isolated spline corrections.
    var limit = math.max(edge, n - (4 * c._h + 2 * c.maxArtifactRun! + 4));
    // Do not split a short artifact run between folds: its final beat must
    // never be mistaken for an isolated artifact at the next pending edge.
    while (limit > edge &&
        w.classes[limit - off - 1] != BeatClass.normal &&
        !w.gaps[limit - off - 1]) {
      limit--;
    }
    for (var i = edge - off; i < limit - off; i++) {
      final cl = w.classes[i];
      classes.add(cl);
      previous = cl;
      if (cl == BeatClass.normal) {
        normal++;
        normals.add(rr[i]);
        if (normals.length > 2) normals.removeAt(0);
      }
      if (w.gaps[i]) normals.clear();
      final v = w.values[i];
      if (v == null) {
        dropped++;
      } else {
        nn.add(v);
        nt.add(w.times[i]);
        if (cl != BeatClass.normal) corrected++;
      }
      clock = w.times[i];
      if (gap && !w.gaps[i]) segmentStart = off + i;
      gap = w.gaps[i];
      hardGap = w.hardGaps[i];
    }
    edge = limit;
    final nextOff = math.max(0, edge - 2 * c._h - 2);
    final trim = nextOff - off;
    if (trim > 0) {
      rr.removeRange(0, trim);
      if (wall == true) ts.removeRange(0, trim);
      off = nextOff;
    }
    return RrSettled(nn: nn, nnTimes: nt, classes: classes);
  }

  RrSnapshot snapshot(RrCorrector c) {
    final w = evaluate(c);
    final nn = <double>[], nt = <double>[], classes = <BeatClass>[];
    var nc = normal, dc = dropped, cc = corrected;
    for (var i = edge - off; i < rr.length; i++) {
      final cl = w.classes[i];
      classes.add(cl);
      if (cl == BeatClass.normal) nc++;
      final v = w.values[i];
      if (v == null) {
        dc++;
      } else {
        nn.add(v);
        nt.add(w.times[i]);
        if (cl != BeatClass.normal) cc++;
      }
    }
    return RrSnapshot(
        n: n,
        tailNn: nn,
        tailNnTimes: nt,
        tailClasses: classes,
        normalCount: nc,
        droppedCount: dc,
        correctedCount: cc,
        settledBeats: edge,
        classifiedBeats: edge);
  }

  Map<String, dynamic> toJson() => {
        'n': n,
        'off': off,
        'edge': edge,
        'segmentStart': segmentStart,
        'hardGap': hardGap,
        'normal': normal,
        'dropped': dropped,
        'corrected': corrected,
        'wall': wall,
        'gap': gap,
        'origin': origin,
        'clock': clock,
        'previous': previous.index,
        'rr': rr,
        'ts': ts,
        'normals': normals,
      };

  void restore(Map<String, dynamic> j, int half) {
    n = j['n'] as int;
    off = j['off'] as int;
    edge = j['edge'] as int;
    segmentStart = j['segmentStart'] as int;
    hardGap = j['hardGap'] as bool;
    normal = j['normal'] as int;
    dropped = j['dropped'] as int;
    corrected = j['corrected'] as int;
    wall = j['wall'] as bool?;
    gap = j['gap'] as bool;
    origin = (j['origin'] as num).toDouble();
    clock = (j['clock'] as num).toDouble();
    previous = BeatClass.values[j['previous'] as int];
    List<double> read(String key) =>
        [for (final v in j[key] as List) (v as num).toDouble()];
    rr.addAll(read('rr'));
    ts.addAll(read('ts'));
    normals.addAll(read('normals'));
    if (segmentStart < 0 ||
        segmentStart > edge ||
        (hardGap && !gap) ||
        off != math.max(0, edge - 2 * half - 2) ||
        edge < off ||
        n < edge ||
        rr.length != n - off ||
        (gap && (previous == BeatClass.normal || normals.isNotEmpty)) ||
        (wall == true ? ts.length != rr.length : ts.isNotEmpty) ||
        (n > 0 && wall == null) ||
        normals.length > 2 ||
        normal < 0 ||
        dropped < 0 ||
        corrected < 0 ||
        normal + dropped + corrected != edge ||
        ![...rr, ...ts, ...normals, origin, clock].every((v) => v.isFinite)) {
      throw const FormatException('inconsistent capped RR checkpoint');
    }
  }
}
