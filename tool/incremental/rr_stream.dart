// RESEARCH PROTOTYPE — streaming Lipponen-Tarvainen RR correction.
//
// Goal: fold NEW beats onto saved state and get, after every fold, EXACTLY
// what `correctRr` returns over the whole series so far (bit-identical nn,
// nnTimes, classes, counts, cleanFraction), while never re-reading the settled
// prefix.
//
// Why that is possible (derivation, with H = windowBeats ~/ 2 = 45):
//   beat clock   t[i]          prefix recurrence (cur, prevTs, origin)
//   dRR[i]       rr[i]-rr[i-1] local
//   th1[i]       QD of dRR over [i-H, i+H]            -> needs rr up to i+H
//   med[i]       median of rr[i-H..i+H] \ {i}          -> needs rr up to i+H
//   mRR[i]       f(rr[i], med[i])                      -> needs rr up to i+H
//   th2[i]       QD of mRR over [i-H, i+H]             -> needs rr up to i+2H
//   class0[i]    f(rr,dRR,th1,th2,mRR,med)             -> final once n-1 >= i+2H
//   class[i]     left-to-right compensatory-pair pass; reads only final
//                class[i-1], so it folds with one carried class.
//   output       a run of artifacts is dropped, a single one is spline-
//                interpolated from the 2 nearest NORMAL beats each side. The
//                left anchors are carried (last two normals); the right anchors
//                need classes up to the 2nd normal after the artifact. So the
//                settle horizon is 2H beats + (artifact run length) + 2 normals.
// Windows are clipped at n-1, so the last 2H beats are PROVISIONAL: [snapshot]
// re-evaluates just that tail (directly, with the oracle's own clipping) and
// is exactly what correctRr would say at the current n.
import 'dart:math' as math;

import 'package:openstrap_analytics/onehz.dart'
    hide RrCorrector, RrSettled, RrSnapshot, IrregularScreenState;

/// Provisional + counters view after a fold. `settled*` is NOT here: [fold]
/// returns the newly settled output; this is the part that can still change.
class RrSnapshot {
  final int n;
  final List<double> tailNn;
  final List<double> tailNnTimes;
  final int normalCount, droppedCount, correctedCount;
  final int settledBeats, classifiedBeats;
  final List<BeatClass>? tailClasses; // classes of beats [classifiedBeats, n)
  const RrSnapshot({
    required this.n,
    required this.tailNn,
    required this.tailNnTimes,
    required this.normalCount,
    required this.droppedCount,
    required this.correctedCount,
    required this.settledBeats,
    required this.classifiedBeats,
    required this.tailClasses,
  });
  double get cleanFraction => n == 0 ? 0 : normalCount / n;
}

class RrSettled {
  final List<double> nn = [];
  final List<double> nnTimes = [];
}

/// Sorted multiset window with O(log w) search + O(w) memmove, w ~ 91.
class _Sorted {
  final List<double> a = [];
  int _lb(double v) {
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

  void add(double v) => a.insert(_lb(v), v);
  void remove(double v) => a.removeAt(_lb(v));
  void resetFrom(Iterable<double> xs) {
    a
      ..clear()
      ..addAll(xs)
      ..sort();
  }
}

class RrCorrector {
  final double alpha;
  final int windowBeats;
  final double minThresholdMs;
  final double reanchorGapMs;
  final int _h;

  // ---- prefix state (the persisted tuple) ----
  int n = 0; // total beats folded
  bool? _wall; // timestamps supplied for this stream
  double _origin = 0, _cur = 0, _prevTs = 0, _prevRr = 0;
  int _off = 0; // global index of _rr[0]
  final List<double> _rr = [], _t = [], _d = [];
  int _so = 0; // global index of _med[0] (stage arrays)
  final List<double> _med = [], _mrr = [], _th1 = [];
  int _c1 = 0; // beats with med/mRR/th1 final
  int _c2 = 0; // beats with class final
  int _ce = 0; // beats whose OUTPUT is final (emitted)
  final List<int> _fcls = []; // final classes for [_ce, _c2)
  int _lastFinal = 0; // class index of beat _c2-1
  int _normalFinal = 0;
  int _dropped = 0, _corrected = 0;
  final List<double> _lastNormals = []; // <= 2, oldest first

  // ---- derived caches (not persisted) ----
  final _Sorted _wd = _Sorted(), _wr = _Sorted(), _wm = _Sorted();
  int _wPos = -1, _w2Pos = -1;

  RrCorrector({
    this.alpha = 5.2,
    this.windowBeats = 91,
    this.minThresholdMs = 100,
    this.reanchorGapMs = 1000,
  }) : _h = windowBeats ~/ 2 {
    if (windowBeats < 3) throw ArgumentError('windowBeats >= 3');
  }

  /// Test hook: called once per beat when its class becomes final.
  void Function(int g, int cls)? debugClassSink;

  int get settledBeats => _ce;
  int get classifiedBeats => _c2;
  int get bufferedBeats => n - _off;

  // ------------------------------------------------------------------ fold
  /// Append beats. Returns the output that became FINAL with this fold.
  RrSettled fold(List<double> rrMs, {List<double>? tsMs}) {
    final out = RrSettled();
    if (rrMs.isEmpty) return out;
    final wall = tsMs != null && tsMs.length == rrMs.length;
    _wall ??= wall;
    if (_wall != wall) {
      throw StateError('timestamps must be supplied for every fold or none');
    }
    for (var k = 0; k < rrMs.length; k++) {
      final r = rrMs[k];
      if (!r.isFinite) throw ArgumentError('non-finite rr at $k');
      final i = n;
      double cur;
      final ts = wall ? tsMs[k] : 0.0;
      if (i == 0) {
        _origin = wall ? ts - r : 0.0;
        _cur = 0.0;
      }
      final dropout = wall && i > 0 && (ts - _prevTs) - r > reanchorGapMs;
      final anchored = wall ? ts - _origin : 0.0;
      cur = (dropout && anchored > _cur) ? anchored : _cur + r;
      _cur = cur;
      if (wall) _prevTs = ts;
      _rr.add(r);
      _t.add(cur);
      _d.add(i == 0 ? 0.0 : r - _prevRr);
      _prevRr = r;
      n++;
    }
    _advance(out);
    _compact();
    return out;
  }

  double _rrAt(int g) => _rr[g - _off];
  double _dAt(int g) => _d[g - _off];
  double _tAt(int g) => _t[g - _off];

  void _advance(RrSettled out) {
    if (n < 3) return;
    final h = _h;
    while (_c1 + h <= n - 1) {
      _stage1(_c1);
      _c1++;
    }
    while (_c2 + 2 * h <= n - 1) {
      _stage2(_c2);
      _c2++;
    }
    _emitCommitted(out);
  }

  // th1/med/mRR for beat g; windows [max(0,g-h), g+h] fully inside the data.
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
    final th1 = _thOf(_wd.a);
    final m = _medExcl(_wr.a, _rrAt(g)) ?? _rrAt(g);
    final d = _rrAt(g) - m;
    _med.add(m);
    _mrr.add(d < 0 ? d * 2 : d);
    _th1.add(th1);
  }

  void _stage2(int g) {
    final h = _h;
    if (_w2Pos == g - 1 && _w2Pos >= 0) {
      _wm.add(_mrr[g + h - _so]);
      if (g - 1 - h >= 0) _wm.remove(_mrr[g - 1 - h - _so]);
    } else {
      final lo = math.max(0, g - h);
      _wm.resetFrom([for (var k = lo; k <= g + h; k++) _mrr[k - _so]]);
    }
    _w2Pos = g;
    final th2 = _thOf(_wm.a);
    var cls = _class0(_rrAt(g), _dAt(g), _th1[g - _so], _med[g - _so],
        _mrr[g - _so], th2);
    cls = _reconcile(g, cls, _lastFinal, _rrAt(g), _dAt(g),
        g > 0 ? _dAt(g - 1) : 0, _med[g - _so]);
    _fcls.add(cls.index);
    debugClassSink?.call(g, cls.index);
    _lastFinal = cls.index;
    if (cls == BeatClass.normal) _normalFinal++;
  }

  double _thOf(List<double> sorted) {
    final q1 = percentileSorted(sorted, 25) ?? 0;
    final q3 = percentileSorted(sorted, 75) ?? 0;
    final qd = (q3 - q1) / 2;
    return math.max(alpha * qd, minThresholdMs);
  }

  /// median of [sorted] with ONE occurrence of [v] removed — what
  /// `_slidingMedian` computes (it skips k == i), without re-sorting.
  static double? _medExcl(List<double> sorted, double v) {
    final len = sorted.length - 1;
    if (len <= 0) return null;
    var lo = 0, hi = sorted.length;
    while (lo < hi) {
      final m = (lo + hi) >> 1;
      if (sorted[m] < v) {
        lo = m + 1;
      } else {
        hi = m;
      }
    }
    final p = lo;
    double at(int j) => j < p ? sorted[j] : sorted[j + 1];
    if (len == 1) return at(0);
    final rank = (50.0 / 100) * (len - 1);
    final l = rank.floor(), u = rank.ceil();
    if (l == u) return at(l);
    final frac = rank - l;
    return at(l) + (at(u) - at(l)) * frac;
  }

  BeatClass _class0(
      double rr, double d, double th1, double med, double mrr, double th2) {
    final hardLong = rr > 2000;
    final hardShort = rr < 300;
    final bigJump = d.abs() > th1;
    final bigDev = mrr.abs() > th2;
    if (hardLong || (bigDev && mrr > 0)) {
      return (med > 0 && rr > 1.5 * med) ? BeatClass.missed : BeatClass.longShort;
    } else if (hardShort || (bigDev && mrr < 0)) {
      return (med > 0 && rr < 0.6 * med) ? BeatClass.extra : BeatClass.longShort;
    } else if (bigJump) {
      return BeatClass.ectopic;
    }
    return BeatClass.normal;
  }

  BeatClass _reconcile(int g, BeatClass cls, int prevCls, double rr, double d,
      double dPrev, double med) {
    if (g < 1 || cls != BeatClass.ectopic) return cls;
    final prevBad = prevCls != BeatClass.normal.index;
    if (!prevBad) return cls;
    final opposite = d * dPrev < 0;
    final valueNormal =
        med > 0 && rr >= 300 && rr <= 2000 && (rr - med).abs() <= 0.2 * med;
    return (opposite && valueNormal) ? BeatClass.normal : cls;
  }

  static double? _spline(List<double> left, List<double> right) {
    if (left.isEmpty || right.isEmpty) return null;
    final p1 = left.last;
    final p2 = right.first;
    final p0 = left.length >= 2 ? left.first : p1;
    final p3 = right.length >= 2 ? right.last : p2;
    const t = 0.5;
    final t2 = t * t;
    final t3 = t2 * t;
    return 0.5 *
        ((2 * p1) +
            (-p0 + p2) * t +
            (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 +
            (-p0 + 3 * p1 - 3 * p2 + p3) * t3);
  }

  // Emission over classes [ce, limit). Shared by the committed pass (limit =
  // c2, isEnd=false: undecidable artifacts wait) and the provisional pass
  // (limit = n, isEnd=true: end of data resolves them exactly like the batch).
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
        final corr = _spline(lastNormals, right);
        if (corr != null) {
          put(corr, _tAt(ce));
          corrected();
        } else {
          drop(1);
        }
      } else {
        drop(runLen);
      }
      ce = j;
    }
    return ce;
  }

  void _emitCommitted(RrSettled out) {
    final fo = _ce;
    _ce = _emit(
      ce: _ce,
      limit: _c2,
      isEnd: false,
      clsAt: (g) => _fcls[g - fo],
      lastNormals: _lastNormals,
      put: (v, t) {
        out.nn.add(v);
        out.nnTimes.add(t);
      },
      drop: (r) => _dropped += r,
      corrected: () => _corrected++,
    );
    // forget classes that are now emitted
    final used = _ce - fo;
    if (used > 0) _fcls.removeRange(0, used);
  }

  // ------------------------------------------------------------- snapshot
  /// The part of `correctRr(all beats so far)` that is not settled yet, plus
  /// the totals. Settled output (from [fold]) ++ tail == the oracle, exactly.
  RrSnapshot snapshot({bool withClasses = false}) {
    if (n == 0) {
      return const RrSnapshot(
          n: 0,
          tailNn: [],
          tailNnTimes: [],
          normalCount: 0,
          droppedCount: 0,
          correctedCount: 0,
          settledBeats: 0,
          classifiedBeats: 0,
          tailClasses: []);
    }
    if (n < 3) {
      // oracle's n<3 branch (nothing is ever settled below 3 beats)
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
          normalCount: nn.length,
          droppedCount: n - nn.length,
          correctedCount: 0,
          settledBeats: 0,
          classifiedBeats: 0,
          tailClasses: withClasses ? cl : null);
    }
    final h = _h;
    final end = n - 1;
    // ---- provisional stage 1 for beats [c1, n): windows clipped at `end`
    final tMed = <double>[], tMrr = <double>[], tTh1 = <double>[];
    double mrrAt(int k) =>
        k < _c1 ? _mrr[k - _so] : tMrr[k - _c1];
    for (var k = _c1; k < n; k++) {
      final lo = math.max(0, k - h), hi = math.min(end, k + h);
      final dd = <double>[for (var q = lo; q <= hi; q++) _dAt(q)]..sort();
      final rs = <double>[for (var q = lo; q <= hi; q++) _rrAt(q)]..sort();
      tTh1.add(_thOf(dd));
      final m = _medExcl(rs, _rrAt(k)) ?? _rrAt(k);
      final d = _rrAt(k) - m;
      tMed.add(m);
      tMrr.add(d < 0 ? d * 2 : d);
    }
    // ---- provisional classes for [c2, n)
    final tc = <int>[];
    var prev = _lastFinal;
    var normalTent = 0;
    for (var g = _c2; g < n; g++) {
      final lo = math.max(0, g - h), hi = math.min(end, g + h);
      final ms = <double>[for (var q = lo; q <= hi; q++) mrrAt(q)]..sort();
      final th2 = _thOf(ms);
      final th1 = g < _c1 ? _th1[g - _so] : tTh1[g - _c1];
      final med = g < _c1 ? _med[g - _so] : tMed[g - _c1];
      final mrr = mrrAt(g);
      var cls = _class0(_rrAt(g), _dAt(g), th1, med, mrr, th2);
      cls = _reconcile(
          g, cls, prev, _rrAt(g), _dAt(g), g > 0 ? _dAt(g - 1) : 0, med);
      tc.add(cls.index);
      prev = cls.index;
      if (cls == BeatClass.normal) normalTent++;
    }
    // ---- provisional emission over [ce, n)
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
      normalCount: _normalFinal + normalTent,
      droppedCount: dropped,
      correctedCount: corrected,
      settledBeats: _ce,
      classifiedBeats: _c2,
      tailClasses: withClasses
          ? [for (final c in tc) BeatClass.values[c]]
          : null,
    );
  }

  // --------------------------------------------------------------- compact
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

  // ------------------------------------------------------------------ json
  Map<String, dynamic> toJson() => {
        'v': 1,
        'alpha': alpha,
        'win': windowBeats,
        'floor': minThresholdMs,
        'reanchor': reanchorGapMs,
        'n': n,
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

  factory RrCorrector.fromJson(Map<String, dynamic> j) {
    List<double> dl(Object? o) => [for (final x in o as List) (x as num).toDouble()];
    final c = RrCorrector(
      alpha: (j['alpha'] as num).toDouble(),
      windowBeats: j['win'] as int,
      minThresholdMs: (j['floor'] as num).toDouble(),
      reanchorGapMs: (j['reanchor'] as num).toDouble(),
    );
    c.n = j['n'] as int;
    c._wall = j['wall'] as bool?;
    c._origin = (j['origin'] as num).toDouble();
    c._cur = (j['cur'] as num).toDouble();
    c._prevTs = (j['prevTs'] as num).toDouble();
    c._prevRr = (j['prevRr'] as num).toDouble();
    c._off = j['off'] as int;
    c._rr.addAll(dl(j['rr']));
    c._t.addAll(dl(j['t']));
    c._d.addAll(dl(j['d']));
    c._c1 = j['c1'] as int;
    c._c2 = j['c2'] as int;
    c._ce = j['ce'] as int;
    c._fcls.addAll((j['fcls'] as List).cast<int>());
    c._lastFinal = j['lastFinal'] as int;
    c._normalFinal = j['normalFinal'] as int;
    c._dropped = j['dropped'] as int;
    c._corrected = j['corrected'] as int;
    c._lastNormals.addAll(dl(j['lastNormals']));
    c._rebuildStageArrays();
    return c;
  }

  /// Stage arrays are pure functions of the buffered raw beats; recompute.
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
      _th1.add(_thOf(dd));
      final m = _medExcl(rs, _rrAt(g)) ?? _rrAt(g);
      final d = _rrAt(g) - m;
      _med.add(m);
      _mrr.add(d < 0 ? d * 2 : d);
    }
    _wPos = -1;
    _w2Pos = -1;
  }
}
