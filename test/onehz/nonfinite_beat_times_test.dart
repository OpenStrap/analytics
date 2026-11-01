// A non-finite beat time used to make rsaRespRate and hrvFreq walk their
// sub-windows forever (an infinite last time is never reached), which ran a
// test isolate out of memory on the dev box. They abstain now, and the
// streams refuse such a fold and answer a snapshot with the batch.
// cvhrApneaScreen / CvhrStream follow the same rule: CvhrStream took a NaN
// time and its snapshot then threw where the batch answered.
// hrvTime (and nocturnalRmssd, sleepSessionRmssdDetail, hrvTimeAggregator,
// IncrementalHrvTime) threw on one: "Infinity or NaN toInt".
import 'dart:typed_data';

import 'package:openstrap_analytics/aggregate.dart';
import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

void main() {
  final nn = [for (var i = 0; i < 1500; i++) 900.0 + 40 * (i % 7)];
  final ts = <double>[];
  var t = 0.0;
  for (final v in nn) {
    t += v;
    ts.add(t);
  }
  List<double> withLast(double bad) => [...ts]..[ts.length - 1] = bad;

  for (final bad in [double.infinity, double.nan, double.negativeInfinity]) {
    test('batch abstains on a last beat time of $bad', () {
      final r = rsaRespRate(nn, withLast(bad), artifactFraction: 0);
      expect(r.present, isFalse);
      expect(r.note, 'non-finite beat time');
      final h = hrvFreq(nn, withLast(bad), artifactFraction: 0);
      expect(h.present, isFalse);
      expect(h.note, 'non-finite beat time');
      final c = cvhrApneaScreen(nn, withLast(bad), artifactFraction: 0);
      expect(c.present, isFalse);
      expect(c.note, 'non-finite beat time');
    });

    test('streams refuse the fold, unchanged, on $bad', () {
      final r = RsaRespStream()..fold(nn.sublist(0, 700), ts.sublist(0, 700));
      final h = HrvFreqStream()..fold(nn.sublist(0, 700), ts.sublist(0, 700));
      final c = CvhrStream()..fold(nn.sublist(0, 700), ts.sublist(0, 700));
      final rBefore = r.toJson(), hBefore = h.toJson(), cBefore = c.toJson();
      final badTs = [...ts.sublist(700, 800)]..[50] = bad;
      expect(() => r.fold(nn.sublist(700, 800), badTs), throwsArgumentError);
      expect(() => h.fold(nn.sublist(700, 800), badTs), throwsArgumentError);
      expect(() => c.fold(nn.sublist(700, 800), badTs), throwsArgumentError);
      expect(r.toJson(), rBefore);
      expect(h.toJson(), hBefore);
      expect(c.toJson(), cBefore);
    });
  }

  test('a snapshot with an infinite tail time is the batch answer', () {
    final r = RsaRespStream()..fold(nn.sublist(0, 1400), ts.sublist(0, 1400));
    final h = HrvFreqStream()..fold(nn.sublist(0, 1400), ts.sublist(0, 1400));
    final tailTs = withLast(double.infinity).sublist(1400);
    final tailNn = nn.sublist(1400);
    expect(
        r.snapshot(tailNnMs: tailNn, tailNnTimesMs: tailTs, artifactFraction: 0)
            .note,
        'non-finite beat time');
    expect(
        h.snapshot(tailNnMs: tailNn, tailNnTimesMs: tailTs, artifactFraction: 0)
            .note,
        'non-finite beat time');
    final c = CvhrStream()..fold(nn.sublist(0, 1400), ts.sublist(0, 1400));
    for (final bad in [double.infinity, double.nan]) {
      final tail = withLast(bad).sublist(1400);
      final got =
          c.snapshot(tailNnMs: tailNn, tailNnTimesMs: tail, artifactFraction: 0);
      expect(got.note, 'non-finite beat time');
      expect(got.note,
          cvhrApneaScreen(nn, withLast(bad), artifactFraction: 0).note);
    }
  });

  group('hrvTime family', () {
    for (final bad in [double.infinity, double.nan, double.negativeInfinity]) {
      test('hrvTime abstains on a beat time of $bad', () {
        for (final at in [ts.length - 1, 0, 700]) {
          final t = [...ts]..[at] = bad;
          final m = hrvTime(nn, nnTimesMs: t);
          expect(m.present, isFalse);
          expect(m.note, 'non-finite beat time');
        }
        // Without times nothing about them is read.
        expect(hrvTime(nn).present, isTrue);
      });

      test('nocturnalRmssd abstains on a beat time of $bad', () {
        final m = nocturnalRmssd(nn, withLast(bad));
        expect(m.present, isFalse);
        expect(m.note, 'non-finite beat time');
      });

      test('sleepSessionRmssdDetail abstains on a beat time of $bad', () {
        final start = 1700000000;
        final abs = [for (final x in ts) start * 1000.0 + x];
        abs[abs.length - 1] = bad;
        final m = sleepSessionRmssdDetail(nn, abs,
            startSec: start, endSec: start + 3 * 3600);
        expect(m.present, isFalse);
        expect(m.note, 'non-finite beat time');
      });

      test('hrvTimeAggregator refuses the slice, state unchanged, on $bad',
          () {
        final agg = hrvTimeAggregator(originMs: ts.first);
        Beats beats(List<double> t) => Beats(
            Float64List.fromList(nn.sublist(0, t.length)),
            Float64List.fromList(t));
        final state = agg.fold(beats(ts.sublist(0, 700)));
        final before = agg.encodeState(state);
        final badTs = [...ts.sublist(0, 100)]..[50] = bad;
        expect(() => agg.addSlice(state, beats(badTs), 0, badTs.length),
            throwsArgumentError);
        expect(agg.encodeState(state), before);
        expect(() => agg.fold(beats(badTs)), throwsArgumentError);
        // Times are ignored when not gap-aware, so NaN stays fine there.
        final plain = hrvTimeAggregator(gapAware: false);
        expect(() => plain.fold(beats(badTs)), returnsNormally);
      });

      test('IncrementalHrvTime snapshot with a tail time of $bad is the batch',
          () {
        final inc = IncrementalHrvTime();
        inc.sync(nn.sublist(0, 1400), nnTimesMs: ts.sublist(0, 1400));
        final got = inc.sync(nn, nnTimesMs: withLast(bad));
        expect(got.present, isFalse);
        expect(got.note, 'non-finite beat time');
        expect(got.note, hrvTime(nn, nnTimesMs: withLast(bad)).note);
      });
    }
  });
}
