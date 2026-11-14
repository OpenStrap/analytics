import 'dart:convert';
import 'dart:typed_data';

import 'package:openstrap_analytics/aggregate.dart';
import 'package:test/test.dart';

Beats beats(List<double> nn, List<double> ts) =>
    Beats(Float64List.fromList(nn), Float64List.fromList(ts));

class ConsumingInner extends Aggregator<List<double>, Beats, List<double>> {
  @override
  List<double> empty() => [];
  @override
  List<double> addSlice(List<double> s, Beats b, int a, int z) =>
      s..addAll(b.nnMs.sublist(a, z));
  @override
  List<double> combine(List<double> a, List<double> b) => b..insertAll(0, a);
  @override
  List<double> finish(List<double> s) => List.of(s);
}

void main() {
  // why: every child must see the same finite intervals, and failed folds are atomic.
  // # catches: Moments skips NaN after differences/evidence have already counted it.
  for (final gap in [false, true]) {
    for (final bad in [double.nan, double.infinity, double.negativeInfinity]) {
      test('HRV refuses non-finite NN before mutation ($gap, $bad)', () {
        final a = hrvTimeAggregator(originMs: 0, gapAware: gap);
        final s = a.fold(beats([800, 810], [800, 1610]));
        final before = jsonEncode(a.encodeState(s));
        expect(
            () =>
                a.addSlice(s, beats([820, bad, 830], [2430, 3250, 4080]), 0, 3),
            throwsArgumentError);
        expect(jsonEncode(a.encodeState(s)), before);
      });
    }
  }
  // why: a backward clock cannot justify successive differences, including seams.
  // # catches: a negative delta is mistaken for a small contiguous delta.
  for (final mode in ['slice', 'append', 'combine']) {
    test('HRV refuses a regressing clock ($mode)', () {
      final a = hrvTimeAggregator(originMs: 1000);
      final b = beats([800, 900, 870], [1000, 1900, 1800]);
      if (mode == 'slice') {
        expect(() => a.fold(b), throwsStateError);
      } else {
        final s = a.fold(b, 0, 2);
        final before = jsonEncode(a.encodeState(s));
        expect(
            () => mode == 'append'
                ? a.addSlice(s, b, 2, 3)
                : a.combine(s, a.fold(b, 2, 3)),
            throwsStateError);
        expect(jsonEncode(a.encodeState(s)), before);
      }
    });
  }
  // why: a deferred checkpoint cannot borrow the live piece's histogram counts.
  // # catches: _Piece.toJson returns cnt directly.
  test('HRV jitter evidence checkpoint owns count bins', () {
    final a = hrvTimeAggregator(gapAware: false);
    final b = beats(List.generate(300, (i) => 800 + (i % 7).toDouble()),
        List.filled(300, double.nan));
    final s = a.fold(b, 0, 150);
    final saved = a.encodeState(s);
    final before = jsonEncode(saved);
    a.addSlice(s, b, 150, 300);
    expect(jsonEncode(saved), before);
    expect(a.finish(a.decodeState(saved)).nBeats, 150);
  });
  // why: a PRSA profile cannot mix anchors selected by different policies.
  // # catches: restore validates profile size but ignores mode and ratio cap.
  for (final (label, other) in [
    ('mode', prsaAggregator(deceleration: false)),
    ('cap', prsaAggregator(deceleration: true, anchorRatioCap: .10)),
  ]) {
    test('PRSA refuses mismatched policy $label', () {
      final a = prsaAggregator(deceleration: true);
      final b = DoubleColumn(
          Float64List.fromList(List.generate(30, (i) => 800 + i.toDouble())));
      expect(() => other.decodeState(a.encodeState(a.fold(b))),
          throwsFormatException);
    });
  }
  // why: a one-beat window can carry alternating recovery phase indefinitely.
  // # catches: restart a 401-beat 800/950 tail at odd index 201 and emit 950 NN.
  test('sandwich refuses context-free threshold windows', () {
    final a = RrSandwich<int, int>(const Count<Beats>(), windowBeats: 1);
    final rr = List.generate(401, (i) => i.isEven ? 800.0 : 950.0);
    final raw = RawRr.of(rr, List.generate(401, (i) => i * 1000.0));
    expect(() => a.run(raw), throwsArgumentError);
  });
  // why: finish needs an owned middle even when combine consumes its right input.
  // # catches: finish passes state.mid directly to a consuming non-persistable child.
  test('sandwich refuses an inner without a state-copy codec', () {
    final a = RrSandwich<List<double>, List<double>>(ConsumingInner());
    expect(
        () => a.fold(RawRr.of(
            List.filled(1300, 800.0), List.generate(1300, (i) => i * 800.0))),
        throwsUnsupportedError);
  });
}
