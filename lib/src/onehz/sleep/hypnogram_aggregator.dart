import 'dart:math' as math;

import '../../aggregate/aggregator.dart';
import '../../aggregate/json_support.dart';
import 'hypnogram.dart';

// Definition basis: Berry, R. B., et al. The AASM Manual for the Scoring of
// Sleep and Associated Events: Rules, Terminology and Technical Specifications.
// American Academy of Sleep Medicine. TST sums light/deep/REM durations; SOL
// runs from session start to first sleep; efficiency is TST / session duration.
// Application conventions: session bounds stand in for lights-off/on, stages
// are inferred rather than PSG-scored, and WASO counts explicit wake only
// between first sleep and the end of final sleep, excluding terminal wake.
// Gaps are not counted as wake. Sleep segments are summed without clipping
// to session bounds; efficiency is capped at 1. No sleep gives null SOL.
// Reformulation of AdvancedSleepStager.hypnogramMetrics(): sums integer stage
// durations and retains onset, final wake, first REM and wake-transition
// boundaries, reproducing its existing hypnogram accounting.
/// Mergeable AASM-style hypnogram metrics over start-sorted segments.
class HypnogramAggregator
    extends Aggregator<_HypnogramState, ListBatch<StageSegment>, HypnogramMetrics> {
  HypnogramAggregator(this.sessionStart, this.sessionEnd);

  final int sessionStart;
  final int sessionEnd;

  @override
  _HypnogramState empty() => _HypnogramState();

  @override
  _HypnogramState addSlice(
      _HypnogramState state, ListBatch<StageSegment> batch, int start, int end) {
    for (var i = start; i < end; i++) {
      final segment = batch.rows[i];
      switch (segment.stage) {
        case 'light':
        case 'deep':
        case 'rem':
          final duration = segment.end - segment.start;
          state.tst += duration;
          if (segment.stage == 'light') state.light += duration;
          if (segment.stage == 'deep') state.deep += duration;
          if (segment.stage == 'rem') {
            state.rem += duration;
            if (!state.hasRem) {
              state
                ..hasRem = true
                ..firstRemStart = segment.start;
            }
          }
          if (!state.hasSleep) {
            state
              ..hasSleep = true
              ..onset = segment.start;
          }
          state.sptEnd = segment.end;
        case 'wake':
          state.wakes.add((segment.start, segment.end));
      }
    }
    return state;
  }

  @override
  _HypnogramState combine(_HypnogramState left, _HypnogramState right) {
    left
      ..tst += right.tst
      ..deep += right.deep
      ..rem += right.rem
      ..light += right.light
      ..wakes.addAll(right.wakes);
    if (!left.hasSleep && right.hasSleep) {
      left
        ..hasSleep = true
        ..onset = right.onset;
    }
    if (right.hasSleep) left.sptEnd = right.sptEnd;
    if (!left.hasRem && right.hasRem) {
      left
        ..hasRem = true
        ..firstRemStart = right.firstRemStart;
    }
    return left;
  }

  @override
  bool get persistable => true;

  @override
  Object? encodeState(_HypnogramState state) => {
        'tst': state.tst,
        'deep': state.deep,
        'rem': state.rem,
        'light': state.light,
        'hasSleep': state.hasSleep,
        'onset': state.onset,
        'sptEnd': state.sptEnd,
        'hasRem': state.hasRem,
        'firstRemStart': state.firstRemStart,
        'wakes': [
          for (final wake in state.wakes) [wake.$1, wake.$2]
        ],
      };

  @override
  _HypnogramState decodeState(Object? json) {
    final map = decodeMap(json);
    final state = _HypnogramState()
      ..tst = _int(field(map, 'tst'))
      ..deep = _int(field(map, 'deep'))
      ..rem = _int(field(map, 'rem'))
      ..light = _int(field(map, 'light'))
      ..hasSleep = _bool(field(map, 'hasSleep'))
      ..onset = _int(field(map, 'onset'))
      ..sptEnd = _int(field(map, 'sptEnd'))
      ..hasRem = _bool(field(map, 'hasRem'))
      ..firstRemStart = _int(field(map, 'firstRemStart'));
    for (final item in decodeList(field(map, 'wakes'))) {
      final pair = decodeList(item);
      if (pair.length != 2) throw const FormatException('Expected a wake pair');
      state.wakes.add((_int(pair[0]), _int(pair[1])));
    }
    if (state.deep + state.rem + state.light != state.tst) {
      throw const FormatException('Stage totals disagree with tst');
    }
    if (state.hasRem && !state.hasSleep) {
      throw const FormatException('REM without sleep');
    }
    return state;
  }

  @override
  HypnogramMetrics finish(_HypnogramState state) {
    final tib = math.max(0, sessionEnd - sessionStart);
    final onset = state.hasSleep ? state.onset : sessionEnd;
    final sptEnd = state.hasSleep ? state.sptEnd : sessionEnd;
    var waso = 0;
    var disturbances = 0;
    for (final wake in state.wakes) {
      final w0 = math.max(wake.$1, onset);
      final w1 = math.min(wake.$2, sptEnd);
      if (w1 > w0) {
        waso += w1 - w0;
        disturbances++;
      }
    }
    final efficiency = tib > 0 ? state.tst / tib : 0.0;
    double pct(int value) => state.tst > 0 ? value / state.tst * 100 : 0;
    return HypnogramMetrics(
      tibS: tib,
      tstS: state.tst,
      sptS: math.max(0, sptEnd - onset),
      solS: state.hasSleep ? math.max(0, onset - sessionStart) : null,
      remLatencyS:
          state.hasRem ? (state.firstRemStart - onset).toDouble() : double.nan,
      wasoS: waso,
      efficiency: math.min(1.0, efficiency),
      disturbances: disturbances,
      deepMin: state.deep / 60,
      remMin: state.rem / 60,
      lightMin: state.light / 60,
      deepPct: pct(state.deep),
      remPct: pct(state.rem),
      lightPct: pct(state.light),
    );
  }
}

class _HypnogramState {
  var tst = 0;
  var deep = 0;
  var rem = 0;
  var light = 0;
  var hasSleep = false;
  var onset = 0;
  var sptEnd = 0;
  var hasRem = false;
  var firstRemStart = 0;
  final wakes = <(int, int)>[];
}

int _int(Object? value) {
  if (value is! int) throw const FormatException('Expected an int');
  return value;
}

bool _bool(Object? value) {
  if (value is! bool) throw const FormatException('Expected a bool');
  return value;
}
