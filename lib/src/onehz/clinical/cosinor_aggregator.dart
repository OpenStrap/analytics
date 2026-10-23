import 'dart:math' as math;
import 'dart:typed_data';

import '../../aggregate/aggregator.dart';
import '../../aggregate/json_support.dart';
import '../types.dart';
import 'cosinor.dart';

/// Sample times and values for a cosinor fit.
class TimedValues extends Batch<TimedValues> {
  TimedValues(this.tHours, this.y) : assert(tHours.length == y.length);

  factory TimedValues.fromJson(Object? json) {
    final map = decodeMap(json);
    final times = decodeDoubles(field(map, 'tHours'));
    final values = decodeDoubles(field(map, 'y'));
    if (times.length != values.length) {
      throw const FormatException('TimedValues columns differ in length');
    }
    return TimedValues(times, values);
  }

  final Float64List tHours;
  final Float64List y;

  @override
  Object? toJson() =>
      {'tHours': encodeDoubles(tHours), 'y': encodeDoubles(y)};

  @override
  int get length => y.length;

  @override
  TimedValues copyRange(int start, int end) => TimedValues(
        Float64List(end - start)..setRange(0, end - start, tHours, start),
        Float64List(end - start)..setRange(0, end - start, y, start),
      );

  @override
  TimedValues join(TimedValues other) {
    final times = Float64List(length + other.length);
    final values = Float64List(length + other.length);
    times
      ..setRange(0, length, tHours)
      ..setRange(length, times.length, other.tHours);
    values
      ..setRange(0, length, y)
      ..setRange(length, values.length, other.y);
    return TimedValues(times, values);
  }
}

class _CosinorState {
  var n = 0;
  var meanC = 0.0;
  var meanS = 0.0;
  var meanY = 0.0;
  var mCC = 0.0;
  var mSS = 0.0;
  var mYY = 0.0;
  var mCS = 0.0;
  var mCY = 0.0;
  var mSY = 0.0;

  void addCentered(double c, double s, double y) {
    final nextN = n + 1;
    final dc = c - meanC;
    final ds = s - meanS;
    final dy = y - meanY;
    final nextMeanC = meanC + dc / nextN;
    final nextMeanS = meanS + ds / nextN;
    final nextMeanY = meanY + dy / nextN;
    mCC += dc * (c - nextMeanC);
    mSS += ds * (s - nextMeanS);
    mYY += dy * (y - nextMeanY);
    mCS += dc * (s - nextMeanS);
    mCY += dc * (y - nextMeanY);
    mSY += ds * (y - nextMeanY);
    meanC = nextMeanC;
    meanS = nextMeanS;
    meanY = nextMeanY;
    n = nextN;
  }

  void mergeCentered(_CosinorState other) {
    if (other.n == 0) return;
    if (n == 0) {
      meanC = other.meanC;
      meanS = other.meanS;
      meanY = other.meanY;
      mCC = other.mCC;
      mSS = other.mSS;
      mYY = other.mYY;
      mCS = other.mCS;
      mCY = other.mCY;
      mSY = other.mSY;
      n = other.n;
      return;
    }
    final total = n + other.n;
    final factor = n * other.n / total;
    final dc = other.meanC - meanC;
    final ds = other.meanS - meanS;
    final dy = other.meanY - meanY;
    mCC += other.mCC + dc * dc * factor;
    mSS += other.mSS + ds * ds * factor;
    mYY += other.mYY + dy * dy * factor;
    mCS += other.mCS + dc * ds * factor;
    mCY += other.mCY + dc * dy * factor;
    mSY += other.mSY + ds * dy * factor;
    meanC += dc * other.n / total;
    meanS += ds * other.n / total;
    meanY += dy * other.n / total;
    n = total;
  }
}

class _CosinorStats
    extends Aggregator<_CosinorState, TimedValues, _CosinorState> {
  const _CosinorStats(this.periodHours);

  final double periodHours;

  @override
  _CosinorState empty() => _CosinorState();

  @override
  _CosinorState addSlice(
      _CosinorState state, TimedValues batch, int start, int end) {
    final w = 2 * math.pi / periodHours;
    for (var i = start; i < end; i++) {
      final c = math.cos(w * batch.tHours[i]);
      final s = math.sin(w * batch.tHours[i]);
      final y = batch.y[i];
      state.addCentered(c, s, y);
    }
    return state;
  }

  @override
  _CosinorState combine(_CosinorState left, _CosinorState right) {
    left.mergeCentered(right);
    return left;
  }

  @override
  _CosinorState finish(_CosinorState state) => state;

  @override
  bool get persistable => true;

  @override
  Object? encodeState(_CosinorState state) => {
        'n': state.n,
        'meanC': encodeDouble(state.meanC),
        'meanS': encodeDouble(state.meanS),
        'meanY': encodeDouble(state.meanY),
        'mCC': encodeDouble(state.mCC),
        'mSS': encodeDouble(state.mSS),
        'mYY': encodeDouble(state.mYY),
        'mCS': encodeDouble(state.mCS),
        'mCY': encodeDouble(state.mCY),
        'mSY': encodeDouble(state.mSY),
      };

  @override
  _CosinorState decodeState(Object? json) {
    final map = decodeMap(json);
    return _CosinorState()
      ..n = decodeCount(field(map, 'n'))
      ..meanC = decodeDouble(field(map, 'meanC'))
      ..meanS = decodeDouble(field(map, 'meanS'))
      ..meanY = decodeDouble(field(map, 'meanY'))
      ..mCC = decodeDouble(field(map, 'mCC'))
      ..mSS = decodeDouble(field(map, 'mSS'))
      ..mYY = decodeDouble(field(map, 'mYY'))
      ..mCS = decodeDouble(field(map, 'mCS'))
      ..mCY = decodeDouble(field(map, 'mCY'))
      ..mSY = decodeDouble(field(map, 'mSY'));
  }
}

// Halberg & Nelson 1979 single-component cosinor. Centered co-moments solve the
// same least-squares model. cosinor() now runs this aggregator in one slice.
// Floating-point order differs from the former batch solver; the relative
// determinant gate replaces its absolute 1e-12 pivot gate. See
// test/aggregate/cosinor_aggregator_test.dart for numerical tolerances and phase
// degeneracies.
/// Builds a mergeable single-component cosinor fit over [TimedValues].
Aggregator<_CosinorState, TimedValues, Metric<CosinorFit>> cosinorAggregator({
  double periodHours = 24,
  int minPoints = cosinorMinPoints,
}) =>
    _CosinorStats(periodHours).map((state) =>
        _finishCosinor(state, periodHours: periodHours, minPoints: minPoints));

Metric<CosinorFit> _finishCosinor(
  _CosinorState state, {
  required double periodHours,
  required int minPoints,
}) {
  const inputs = ['signal_timeseries'];
  final n = state.n;
  if (n < math.max(4, minPoints) || periodHours <= 0) {
    return const Metric<CosinorFit>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'too few points for cosinor',
    );
  }
  final determinant = state.mCC * state.mSS - state.mCS * state.mCS;
  // The determinant is relative to the diagonal co-moments.  A design needs
  // at least 1e-12 of that scale after removing its means to identify both
  // cosine coefficients; below that, numerical noise decides the fit.
  if (determinant <= 1e-12 * state.mCC * state.mSS) {
    return const Metric<CosinorFit>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'singular cosinor design (insufficient phase coverage)',
    );
  }
  final beta =
      (state.mCY * state.mSS - state.mSY * state.mCS) / determinant;
  final gamma =
      (state.mSY * state.mCC - state.mCY * state.mCS) / determinant;
  final mesor = state.meanY - beta * state.meanC - gamma * state.meanS;
  final amplitude = math.sqrt(beta * beta + gamma * gamma);
  final acro = math.atan2(-gamma, beta);
  final w = 2 * math.pi / periodHours;
  var phaseHours = -acro / w;
  phaseHours = phaseHours % periodHours;
  if (phaseHours < 0) phaseHours += periodHours;

  final ssTot = state.mYY;
  final ssRes = state.mYY -
      2 * beta * state.mCY -
      2 * gamma * state.mSY +
      beta * beta * state.mCC +
      gamma * gamma * state.mSS +
      2 * beta * gamma * state.mCS;
  final double r2 = ssTot == 0 ? 0.0 : (1 - ssRes / ssTot).clamp(0, 1);
  final double r2Adj = (1 - (1 - r2) * (n - 1) / (n - 3)).clamp(0, 1);
  return Metric<CosinorFit>(
    value: CosinorFit(
      mesor: mesor,
      amplitude: amplitude,
      acrophaseRad: acro,
      acrophaseHours: phaseHours,
      periodHours: periodHours,
      r2: r2,
      r2Adj: r2Adj,
    ),
    confidence: r2Adj.clamp(0.1, 0.95),
    tier: Tier.high,
    inputs_used: inputs,
    note: 'single-component cosinor; anchor circadian phase on the nocturnal '
        'trough, not the daytime peak',
  );
}
