import 'dart:convert';

import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

Map<String, dynamic> _wire(Map<String, dynamic> json) =>
    jsonDecode(jsonEncode(json)) as Map<String, dynamic>;

void main() {
  // why: a saved map must remain restorable while its source keeps folding,
  // and edits to that map must not change the source (CLAIM(screen-checkpoint)).
  test('open-window checkpoint owns its beat list in both directions', () {
    final state = IrregularScreenState()..fold([800, 900], [800, 1700]);
    final saved = state.toJson();
    state.fold([850], [2550]);
    final restored = IrregularScreenState.fromJson(_wire(saved));
    expect(restored.toJson()['bk'], [800.0, 900.0]);
    expect(restored.evaluateDetailed([], []).diagnostics.nnIn, 2);
    (saved['bk'] as List).clear();
    expect(state.toJson()['bk'], [800.0, 900.0, 850.0]);
    expect(state.evaluateDetailed([], []).diagnostics.windows!.openBeats, 3);
  });

  final nonFinite = <String, double>{
    'NaN': double.nan,
    'Infinity': double.infinity,
    '-Infinity': double.negativeInfinity,
  };
  for (final entry in nonFinite.entries) {
    for (final window in [true, false]) {
      // why: failing closed is a supported config path; its evidence and
      // checkpoint must persist (CLAIM(screen-json-nonfinite)).
      test(
          '${entry.key} ${window ? 'window' : 'fraction'} persists fail-closed',
          () {
        final rr = [for (var i = 0; i < 600; i++) 800.0 + i % 20];
        var clock = 0.0;
        final times = [for (final v in rr) clock += v];
        final state = IrregularScreenState(
          windowMinutes: window ? entry.value : 5,
          sustainedFraction: window ? 0.5 : entry.value,
        )..fold(rr, times);
        final batch = irregularBeatScreenDetailed(
          rr,
          nnTimesMs: times,
          windowMinutes: window ? entry.value : 5,
          sustainedFraction: window ? 0.5 : entry.value,
        );
        final stateJson = _wire(state.toJson());
        expect(stateJson[window ? 'windowMinutes' : 'sustainedFraction'],
            entry.key);
        final restored = IrregularScreenState.fromJson(stateJson);
        expect(_wire(restored.toJson()), stateJson);
        for (final result in [batch, restored.evaluateDetailed([], [])]) {
          expect(result.metric.present, isTrue);
          expect(result.metric.value!.flag, isFalse);
          expect(result.diagnostics.windows, isNull);
          final envelope = _wire(result.toJson());
          final diag = envelope['diagnostics'] as Map<String, dynamic>;
          expect(
              (diag['thresholds']
                  as Map)[window ? 'window_minutes' : 'sustained_fraction'],
              entry.key);
          expect(_wire(IrregularDiagnostics.fromJson(diag).toJson()), diag);
        }
      });
    }

    // why: an unknown timestamp must not poison every later window or make
    // checkpoint JSON fail (CLAIM(screen-finite-window-time)).
    test(
        '${entry.key} beat times are excluded from windows and break adjacency',
        () {
      final rr = List<double>.filled(8, 800);
      final times = [
        entry.value,
        0.0,
        800.0,
        300000.0,
        entry.value,
        300800.0,
        600000.0,
        entry.value
      ];
      var state = IrregularScreenState(minWindowBeats: 2);
      for (var i = 0; i < rr.length; i++) {
        state.fold([rr[i]], [times[i]]);
        state = IrregularScreenState.fromJson(_wire(state.toJson()));
      }
      final batch = irregularBeatScreenDetailed(rr,
          nnTimesMs: times, minWindowBeats: 2, minBeats: 3);
      final stream = state.evaluateDetailed([], [], minBeats: 3);
      for (final result in [batch, stream]) {
        final d = result.diagnostics;
        // Five finite times make three buckets: [0,800], [300000,300800],
        // [600000]. The unknown time splits adjacency in the middle bucket.
        expect(d.nnKept, 8);
        expect(d.abstain, IrregularAbstain.tooFewBeats);
        expect(d.windows!.total, 3);
        expect(d.windows!.valid, 1);
        expect(d.windows!.flagged, 0);
        expect(d.windows!.openBeats, 1);
        expect(d.windows!.open, IrregularOpenWindow.thin);
      }
      expect(_wire(stream.toJson()), _wire(batch.toJson()));
      expect((state.toJson()['bk'] as List).length, 1);
    });
  }

  // why: a malformed in-memory checkpoint must not reintroduce an immortal
  // window even when JSON text would reject it (CLAIM(screen-finite-window-time)).
  test('restoring a non-finite window start is refused', () {
    final state = IrregularScreenState()..fold([800], [800]);
    for (final bad in nonFinite.values) {
      expect(
          () => IrregularScreenState.fromJson(
              {...state.toJson(), 'winStart': bad}),
          throwsFormatException);
    }
  });
}
