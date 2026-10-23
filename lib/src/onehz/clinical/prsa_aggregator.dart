import 'dart:typed_data';

import '../../aggregate/aggregator.dart';
import '../../aggregate/json_support.dart';
import '../../aggregate/primitives.dart';
import '../types.dart';
import 'prsa.dart';

// Bauer et al. 2006 PRSA, as in decelerationCapacity()/accelerationCapacity().
// Lookback(2*l+1) reproduces the same anchor bounds and [i-l,i+l) profile.
// Merged profile sums and anchor counts give the same mathematical result.
// Checked capacity/profile absolute and relative tolerances are 1e-9; confidence
// absolute tolerance is 1e-12.
/// Running PRSA sums: the per-offset profile total and the anchor count.
class _PrsaState {
  _PrsaState(int l)
      : profile = Float64List(2 * l),
        anchors = 0;
  _PrsaState._(this.profile, this.anchors);
  final Float64List profile;
  int anchors;
}

/// Folds every window of `2l + 1` rows. The window starting at `s` belongs to
/// the anchor candidate `i = s + l`; it tests (x[i-1], x[i]) and adds rows
/// `s .. s + 2l - 1` (the reference's `[i - l, i + l)`). The extra last row
/// keeps the reference's `i < n - l` bound. Run under `Lookback(2l + 1)`.
class _PrsaWindows extends Aggregator<_PrsaState, DoubleColumn, _PrsaState> {
  const _PrsaWindows(this.l, this.deceleration, this.cap);
  final int l;
  final bool deceleration;
  final double cap;

  @override
  _PrsaState empty() => _PrsaState(l);
  @override
  _PrsaState addSlice(_PrsaState state, DoubleColumn batch, int start, int end) {
    final x = batch.values;
    for (var s = start; s + 2 * l + 1 <= end; s++) {
      final prev = x[s + l - 1];
      if (prev <= 0) continue;
      final cur = x[s + l];
      if ((cur - prev > 0) != deceleration) continue;
      if ((cur / prev - 1).abs() > cap) continue;
      state.anchors++;
      for (var k = 0; k < 2 * l; k++) {
        state.profile[k] += x[s + k];
      }
    }
    return state;
  }

  @override
  _PrsaState combine(_PrsaState left, _PrsaState right) {
    for (var k = 0; k < 2 * l; k++) {
      left.profile[k] += right.profile[k];
    }
    left.anchors += right.anchors;
    return left;
  }

  @override
  _PrsaState finish(_PrsaState state) => state;
  @override
  bool get persistable => true;
  @override
  Object? encodeState(_PrsaState state) =>
      {'profile': encodeDoubles(state.profile), 'anchors': state.anchors};
  @override
  _PrsaState decodeState(Object? json) {
    final map = decodeMap(json);
    final profile = decodeDoubles(field(map, 'profile'));
    final anchors = decodeCount(field(map, 'anchors'));
    if (profile.length != 2 * l) {
      throw FormatException('PRSA profile needs $l * 2 entries');
    }
    if (anchors < 0) throw const FormatException('Negative PRSA anchors');
    return _PrsaState._(profile, anchors);
  }
}

/// Mergeable PRSA deceleration or acceleration capacity, matching
/// [decelerationCapacity] and [accelerationCapacity].
Aggregator<dynamic, DoubleColumn, Metric<PrsaResult>> prsaAggregator({
  required bool deceleration,
  int l = 2,
  double anchorRatioCap = 0.05,
}) {
  final kind = deceleration ? 'DC' : 'AC';
  const inputs = ['rr_cleaned'];
  if (l < 2) {
    // Same absent Metric as the reference; Lookback needs a valid window.
    final absent = Metric<PrsaResult>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'PRSA ($kind) needs l≥2 for the s=2 Haar contrast',
    );
    return Count<DoubleColumn>().map((_) => absent);
  }
  final core = both(
    Count<DoubleColumn>(),
    Lookback<DoubleColumn, _PrsaState, _PrsaState>(
      2 * l + 1,
      _PrsaWindows(l, deceleration, anchorRatioCap),
      batchFromJson: DoubleColumn.fromJson,
    ),
  );
  return validateCheckpoint(core, (json) {
    final state = decodeList(json);
    if (state.length != 2) throw const FormatException('Expected two states');
    final count = decodeCount(state[0]);
    final lookback = decodeMap(state[1]);
    if (decodeCount(field(lookback, 'length')) != count) {
      throw const FormatException('Lookback length disagrees with beat count');
    }
    final anchors = decodeCount(field(decodeMap(field(lookback, 'inner')), 'anchors'));
    final windows = count > 2 * l ? count - 2 * l : 0;
    if (anchors > windows) {
      throw const FormatException('PRSA anchors exceed windows');
    }
  }).map((result) {
    final (n, sums) = result;
    if (n < 2 * l + 4) {
      return Metric<PrsaResult>.absent(
        tier: Tier.high,
        inputs_used: inputs,
        note: 'too few beats for PRSA ($kind)',
      );
    }
    final anchors = sums.anchors;
    if (anchors == 0) {
      return Metric<PrsaResult>.absent(
        tier: Tier.high,
        inputs_used: inputs,
        note: 'no valid PRSA anchors ($kind)',
      );
    }
    final profile = [for (final v in sums.profile) v / anchors];
    final capacity =
        (profile[l] + profile[l + 1] - profile[l - 1] - profile[l - 2]) / 4;
    return Metric<PrsaResult>(
      value: PrsaResult(
        capacity: capacity,
        profile: profile,
        anchors: anchors,
        kind: kind,
      ),
      confidence: (anchors / 1000.0).clamp(0.3, 0.95),
      tier: Tier.high,
      inputs_used: inputs,
      note: 'Bauer 2006 PRSA $kind; needs a long overnight RR record for '
          'mortality-grade stability',
    );
  });
}
