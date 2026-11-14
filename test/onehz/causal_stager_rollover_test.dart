// CAUSAL stager: label persistence across history rollover, the recent-coverage
// gate on stored labels, and persisted-row invariants.
import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

import 'support/causal_night.dart' show kT0Ms;

/// Constant HR (60) and accel (0, 0, 1) for seconds [lo, hi); decision time at
/// the end of the window.
CausalSampleWindow constWindow(int lo, int hi) => CausalSampleWindow(
      nowMs: kT0Ms + hi * 1000.0,
      hr: [for (var s = lo; s < hi; s++) HrSample(kT0Ms + s * 1000.0, 60)],
      accel: [
        for (var s = lo; s < hi; s++)
          AccelSample(kT0Ms + s * 1000.0, 0, 0, 1)
      ],
    );

List<String?> labels(CausalStageObservation o) =>
    [for (final r in o.nextState.rows) r.label?.name];

void main() {
  // why: once history rolls over, the rows an earlier epoch's baseline used are
  // gone. Re-deciding that epoch on the shorter baseline cleared its label, so a
  // window that merely re-sent 120 s of identical history changed the run and
  // the state.
  // # catches: warmup == history == 40, 40 epochs, then epoch 41 with and
  // without a 120 s overlap: runSec 60 vs 30 and different labels.
  test('re-sent identical history does not change labels after rollover', () {
    const cfg = CausalStagerConfig(warmupEpochs: 40, historyEpochs: 40);
    CausalStagerState? s;
    for (var e = 0; e < 40; e++) {
      s = CausalStager.observe(constWindow(e * 30, e * 30 + 30), s ?? CausalStagerState.initial(cfg)).nextState;
    }
    final plain = CausalStager.observe(constWindow(1200, 1230), s);
    final overlap = CausalStager.observe(constWindow(1200 - 120, 1230), s);
    expect(plain.stage, isNot(CausalStage.absent), reason: 'the setup stages');
    expect(overlap.stage, plain.stage);
    expect(overlap.runSec, plain.runSec);
    expect(labels(overlap), labels(plain));
    expect(overlap.nextState.toJson(), plain.nextState.toJson());
  });

  // why: an epoch the observer abstains on for coverage must not keep a label
  // that a later run can count.
  // # catches: 40 usable epochs, 22 missing, 20 usable: the abstained epochs
  // carry labels and the first covered observation reports a run that counts
  // them (300 s here instead of 30 s).
  test('an epoch that fails recent coverage gets no label to extend a run', () {
    const cfg = CausalStagerConfig(warmupEpochs: 20, historyEpochs: 360);
    CausalStagerState? s;
    for (var e = 0; e < 40; e++) {
      s = CausalStager.observe(constWindow(e * 30, e * 30 + 30),
              s ?? CausalStagerState.initial(cfg))
          .nextState;
    }
    final byEpoch = <int, CausalStageObservation>{};
    for (var e = 62; e < 82; e++) {
      final o = CausalStager.observe(constWindow(e * 30, e * 30 + 30), s);
      s = o.nextState;
      byEpoch[e] = o;
    }
    final firstCovered = byEpoch.entries
        .firstWhere((e) => e.value.stage != CausalStage.absent)
        .key;
    expect(firstCovered, greaterThan(62), reason: 'the gap really abstains');
    for (var e = 62; e < firstCovered; e++) {
      expect(byEpoch[e]!.abstentionReason, CausalAbstention.lowCoverage,
          reason: 'epoch $e');
    }
    // The run starts at the first covered epoch: abstained ones break it.
    expect(byEpoch[firstCovered]!.runSec, 30);
    expect(byEpoch[firstCovered + 1]!.runSec, 60);
    for (final r in s!.rows.where((r) => r.epoch >= 62 && r.epoch < firstCovered)) {
      expect(r.label, isNull, reason: 'epoch ${r.epoch}');
    }
  });

  // why: a usable row is read for its motion in every decision.
  // # catches: a persisted row with motion == null passes `usable` and throws
  // at r.motion! on the next decision.
  group('persisted rows', () {
    List<Object?> row({Object? motion = 0.01, Object? hr = 60.0, Object? label}) =>
        [5, 30, 0, 30, motion, hr, 1.0, null, null, null, label];

    test('a usable row without motion is refused', () {
      expect(CausalEpochRow.fromJson(row()), isNotNull);
      expect(CausalEpochRow.fromJson(row(motion: null)), isNull);
    });
    test('counts and labels must be consistent', () {
      expect(CausalEpochRow.fromJson([5, -1, 0, 30, 0.01, 60.0, 1.0, null, null, null, null]), isNull);
      expect(CausalEpochRow.fromJson([5, 31, 0, 30, 0.01, 60.0, 1.0, null, null, null, null]), isNull);
      // A label on a row that is not usable (no HR value).
      expect(CausalEpochRow.fromJson(row(hr: null, label: 1)), isNull);
      expect(CausalEpochRow.fromJson(row(label: 1)), isNotNull);
    });
    test('a state holding such a row restarts instead of crashing', () {
      final s = CausalStager.observe(constWindow(0, 30), null).nextState;
      final json = s.toJson();
      final bad = Map<String, dynamic>.of(json);
      bad['rows'] = [row(motion: null)];
      expect(CausalStagerState.fromJson(bad), isNull);
    });
  });
}
