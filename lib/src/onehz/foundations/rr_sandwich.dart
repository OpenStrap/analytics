// Lipponen & Tarvainen 2019 classification with Peltola 2012 correction policy.
// The unpublished artifact-run cap is an internal ESTIMATE with low confidence:
// over-cap runs become gaps and each side is re-corrected. Without a cap split
// the result equals uncapped correction. Shared kernel arithmetic and raw seam
// context preserve capped batch NN/classes; settled stream plus provisional tail
// equals capped batch. RrSandwich preserves source-beat absolute timestamps;
// uncapped arbitrarily long artifact runs have no exactness guarantee.
// FOUNDATION — the RR "sandwich": a mergeable summary over RAW RR that feeds
// capped, corrected NN into a downstream aggregator (docs/AGGREGATOR_DESIGN.md,
// "Proposed next step").
//
// Contract (test/aggregate/rr_sandwich_test.dart pins it):
//   * any chunking of a beat series (empty chunks and one-beat chunks
//     included), combined left to right or right to left, finishes to what one
//     pass gives, and that is `correctRr(all beats, maxArtifactRun: K)`: the
//     inner aggregator sees exactly the capped NN, each with the ABSOLUTE raw
//     timestamp of the input beat it came from (`nnSourceIndex`), never
//     correctRr's first-beat-relative clock;
//   * state is bounded (raw head, settled middle folded into `inner`, raw
//     tail), never the series;
//   * persistable when `inner` is.

import 'dart:typed_data';

import '../../aggregate/aggregator.dart';
import '../../aggregate/json_support.dart';
import '../clinical/hrv_time_aggregator.dart' show Beats;
import 'rr_correction.dart';

/// Raw RR beats: interval (ms) and the beat's timestamp (epoch ms), the pair
/// `correctRr(rrMs, rrTsMs: tsMs)` takes. Timestamps non-decreasing.
class RawRr extends Batch<RawRr> {
  RawRr(this.rrMs, this.tsMs) : assert(rrMs.length == tsMs.length);

  factory RawRr.of(List<double> rrMs, List<double> tsMs) =>
      RawRr(Float64List.fromList(rrMs), Float64List.fromList(tsMs));

  factory RawRr.fromJson(Object? json) {
    final map = decodeMap(json);
    final rr = decodeDoubles(field(map, 'rrMs'));
    final ts = decodeDoubles(field(map, 'tsMs'));
    if (rr.length != ts.length) {
      throw const FormatException('RawRr columns differ in length');
    }
    return RawRr(rr, ts);
  }

  final Float64List rrMs;
  final Float64List tsMs;

  @override
  int get length => rrMs.length;

  @override
  RawRr copyRange(int start, int end) => RawRr(
      Float64List(end - start)..setRange(0, end - start, rrMs, start),
      Float64List(end - start)..setRange(0, end - start, tsMs, start));

  @override
  RawRr join(RawRr other) => RawRr(
      Float64List(length + other.length)
        ..setRange(0, length, rrMs)
        ..setRange(length, length + other.length, other.rrMs),
      Float64List(length + other.length)
        ..setRange(0, length, tsMs)
        ..setRange(length, length + other.length, other.tsMs));

  @override
  Object? toJson() =>
      {'rrMs': encodeDoubles(rrMs), 'tsMs': encodeDoubles(tsMs)};
}

/// Opaque [RrSandwich] state: the raw head (first `min(m, W)` beats), the
/// raw tail (last `W` beats, only once `m > W`), and the inner aggregator's
/// state over the NN of the settled middle. `m` is the number of beats seen.
class RrSandwichState<S> {
  RrSandwichState(this.m, this.head, this.tail, this.mid);
  int m;
  RawRr head, tail;
  S mid;
}

/// Raw RR -> capped, corrected NN -> [inner]. Parameters are `correctRr`'s.
///
/// Each NN reaches [inner] with the ABSOLUTE timestamp (`rrTsMs`) of the input
/// beat it came from (`RrCorrectionResult.nnSourceIndex`), so a seam needs no
/// clock translation: there is no per-chunk clock at all.
///
/// Locality. The class and the value of a beat depend only on the raw beats at
/// most [reach] either side of it: two centred threshold windows (4H, H =
/// windowBeats ~/ 2), a cap decision whose run is at most K long (the streaming
/// corrector's settle delay is 4H + 2K + 4; one more K covers a run that
/// straddles the edge), and the spline anchors. So a chunk of `m` beats has a
/// settled region `[reach, m - reach)` that is final whatever precedes or
/// follows it, and everything else is kept raw: W = 2 * reach beats at each
/// end. `combine` re-corrects only `left.tail ++ right.head` and settles the
/// beats between the two settled regions. State is bounded: head, tail, and
/// whatever [inner] keeps for the settled NN.
///
/// With `maxArtifactRun: null` (uncapped) the reach is sized as for the
/// default cap; an artifact run longer than that is not bounded-state
/// exact, since the uncapped corrector lets one run reach arbitrarily far.
class RrSandwich<S, R> extends Aggregator<RrSandwichState<S>, RawRr, R> {
  const RrSandwich(
    this.inner, {
    this.maxArtifactRun = kMaxArtifactRun,
    this.alpha = 5.2,
    this.windowBeats = 91,
    this.minThresholdMs = 100,
    this.reanchorGapMs = 1000,
  });

  /// Receives the settled NN (`nnMs`) with the absolute timestamp of each
  /// one's source beat (`timeMs`).
  final Aggregator<S, Beats, R> inner;
  final int? maxArtifactRun;
  final double alpha;
  final int windowBeats;
  final double minThresholdMs;
  final double reanchorGapMs;

  /// Beats of context either side that can change a beat's output.
  int get reach => 4 * (windowBeats ~/ 2) + 3 * (maxArtifactRun ?? kMaxArtifactRun) + 4;
  int get _w => 2 * reach;

  static final _none = RawRr(Float64List(0), Float64List(0));

  /// NN of `correctRr(seg)` whose source beat lies in `[lo, hi)`, as a
  /// [Beats] carrying each source beat's absolute timestamp.
  Beats _nn(RawRr seg, int lo, int hi) {
    final c = correctRr(seg.rrMs,
        alpha: alpha,
        windowBeats: windowBeats,
        minThresholdMs: minThresholdMs,
        reanchorGapMs: reanchorGapMs,
        maxArtifactRun: maxArtifactRun);
    final nn = <double>[], t = <double>[];
    for (var k = 0; k < c.nn.length; k++) {
      final i = c.nnSourceIndex[k];
      if (i >= lo && i < hi) {
        nn.add(c.nn[k]);
        t.add(seg.tsMs[i]);
      }
    }
    return Beats(Float64List.fromList(nn), Float64List.fromList(t));
  }

  S _state(Beats b) => inner.addSlice(inner.empty(), b, 0, b.length);

  @override
  RrSandwichState<S> empty() =>
      RrSandwichState<S>(0, _none, _none, inner.empty());

  @override
  RrSandwichState<S> addSlice(
      RrSandwichState<S> state, RawRr batch, int start, int end) {
    if (end <= start) return state;
    return combine(state, _chunk(batch.copyRange(start, end)));
  }

  RrSandwichState<S> _chunk(RawRr raw) {
    final m = raw.length, w = _w, r = reach;
    if (m <= w) return RrSandwichState<S>(m, raw, _none, inner.empty());
    return RrSandwichState<S>(m, raw.copyRange(0, w), raw.copyRange(m - w, m),
        _state(_nn(raw, r, m - r)));
  }

  /// Beats `[lo, hi)` of the series [s] and [t] hold, joined; [t] follows [s].
  RawRr _range(RrSandwichState<S> l, RrSandwichState<S> r, int lo, int hi) {
    final w = _w, ml = l.m;
    RawRr part(RrSandwichState<S> s, int a, int b) {
      if (b <= a) return _none;
      if (s.m <= w) return s.head.copyRange(a, b);
      final base = s.m - w; // tail[0] is beat `base`
      assert(a >= base, 'range reaches before the tail');
      return s.tail.copyRange(a - base, b - base);
    }

    final left = part(l, lo, hi < ml ? hi : ml);
    final a = lo > ml ? lo - ml : 0, b = hi - ml;
    if (b <= a) return left;
    assert(b <= r.head.length, 'range reaches past the head');
    final right = r.head.copyRange(a, b);
    return left.length == 0 ? right : left.join(right);
  }

  @override
  RrSandwichState<S> combine(RrSandwichState<S> left, RrSandwichState<S> right) {
    if (left.m == 0) return right;
    if (right.m == 0) return left;
    final w = _w, rc = reach, ml = left.m, mr = right.m, m = ml + mr;
    // Settled regions: left [rc, ml - rc), right (merged coordinates)
    // [ml + rc, m - rc). The beats between them are settled here, from the
    // raw windows around the seam.
    final aEnd = ml > w ? ml - rc : rc;
    final cStart = mr > w ? ml + rc : m - rc;
    var mid = left.mid;
    if (cStart > aEnd) {
      final lo = aEnd - rc, hi = cStart + rc;
      final seg = _range(left, right, lo, hi);
      mid = inner.combine(mid, _state(_nn(seg, aEnd - lo, cStart - lo)));
    }
    if (mr > w) mid = inner.combine(mid, right.mid);
    final head = ml >= w
        ? left.head
        : left.head.join(right.head.copyRange(0, (m < w ? m : w) - ml));
    var tail = _none;
    if (m > w) {
      tail = mr >= w
          ? (mr == w ? right.head : right.tail)
          : _range(left, right, m - w, ml).join(right.head);
    }
    return RrSandwichState<S>(m, head, tail, mid);
  }

  @override
  R finish(RrSandwichState<S> state) {
    final m = state.m, w = _w, rc = reach;
    if (m <= w) return inner.finish(_state(_nn(state.head, 0, m)));
    // The settled middle is combined into fresh states; combine may consume
    // its inputs, so work on a copy of the stored one.
    final mid = inner.persistable
        ? inner.decodeState(inner.encodeState(state.mid))
        : state.mid;
    var out = _state(_nn(state.head, 0, rc));
    out = inner.combine(out, mid);
    out = inner.combine(out, _state(_nn(state.tail, rc, w)));
    return inner.finish(out);
  }

  @override
  bool get persistable => inner.persistable;

  @override
  Object? encodeState(RrSandwichState<S> state) => {
        'm': state.m,
        'head': state.head.toJson(),
        'tail': state.tail.toJson(),
        'mid': inner.encodeState(state.mid),
      };

  @override
  RrSandwichState<S> decodeState(Object? json) {
    final map = decodeMap(json);
    final m = field(map, 'm');
    if (m is! int || m < 0) throw const FormatException('bad RrSandwich m');
    final head = RawRr.fromJson(field(map, 'head'));
    final tail = RawRr.fromJson(field(map, 'tail'));
    final w = _w;
    if (head.length != (m < w ? m : w) || tail.length != (m > w ? w : 0)) {
      throw const FormatException('RrSandwich window lengths disagree with m');
    }
    return RrSandwichState<S>(m, head, tail, inner.decodeState(field(map, 'mid')));
  }
}

/// Adapts a column aggregator over NN (e.g. `prsaAggregator`) to the [Beats]
/// batch [RrSandwich] feeds: it sees `Beats.nnMs` as a [DoubleColumn].
class NnColumn<S, R> extends Aggregator<S, Beats, R> {
  const NnColumn(this.inner);
  final Aggregator<S, DoubleColumn, R> inner;

  @override
  S empty() => inner.empty();

  @override
  S addSlice(S state, Beats batch, int start, int end) =>
      inner.addSlice(state, DoubleColumn(batch.nnMs), start, end);

  @override
  S combine(S left, S right) => inner.combine(left, right);

  @override
  R finish(S state) => inner.finish(state);

  @override
  bool get persistable => inner.persistable;

  @override
  Object? encodeState(S state) => inner.encodeState(state);

  @override
  S decodeState(Object? json) => inner.decodeState(json);
}
