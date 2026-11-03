import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

void main() {
  for (final bad in [double.nan, double.infinity, double.negativeInfinity]) {
    test('HRV entry points abstain on non-finite NN interval $bad', () {
      final nn = List<double>.filled(1200, 900);
      final ts = [for (var i = 0; i < nn.length; i++) 2000.0 + i * 900];
      nn[400] = bad;
      for (final metric in [
        hrvTime(nn, nnTimesMs: ts),
        nocturnalRmssd(nn, ts),
        sleepSessionRmssdDetail(nn, ts, startSec: 1, endSec: 1200),
        sleepSessionWindowedRmssd(nn, ts, startSec: 1, endSec: 1200),
      ]) {
        expect(metric.present, isFalse);
        expect(metric.note, 'non-finite NN interval');
      }
      expect(hrvTime(nn).present, isFalse);
    });
    test('unknown training load $bad abstains in prime and later history', () {
      for (final index in [0, 6, 7, 13]) {
        final loads = List<double>.filled(14, 50)..[index] = bad;
        final metric = ctlAtlTsb(loads);
        expect(metric.present, isFalse, reason: 'day $index');
        expect(metric.note, 'non-finite daily TRIMP');
      }
    });
  }
  test('a five-minute segment containing only NaNs abstains without throwing', () {
    final nn = List<double>.filled(1200, 900);
    for (var i = 0; i < 334; i++) { nn[i] = double.nan; }
    final ts = [for (var i = 0; i < nn.length; i++) i * 900.0];
    expect(hrvTime(nn, nnTimesMs: ts).present, isFalse);
  });
  for (final period in [0.0, -24.0, double.nan, double.infinity,
    double.negativeInfinity]) {
    test('cosinor refuses invalid period $period', () {
      final metric = cosinor(
        [for (var i = 0; i < 48; i++) i.toDouble()],
        [for (var i = 0; i < 48; i++) 60.0 + i % 3],
        periodHours: period,
      );
      expect(metric.present, isFalse);
      expect(metric.note, 'invalid cosinor period');
    });
  }
  test('over-cap artifacts have an explicit gap label', () {
    final rr = [
      ...List<double>.filled(100, 900),
      ...List<double>.filled(33, 100),
      ...List<double>.filled(100, 900),
    ];
    final result = correctRr(rr);
    expect(result.classes.sublist(100, 133).map((c) => c.name),
        everyElement('gap'));
    expect(result.droppedCount, 33);
    expect(result.nn, List<double>.filled(200, 900));
    expect(result.nnSourceIndex,
        [...List<int>.generate(100, (i) => i),
         ...List<int>.generate(100, (i) => i + 133)]);
  });

  test('observed rest days still decay load', () {
    // Seven 50-load days prime at 50. Seven observed rest days then apply
    // exp(-1/tau) seven times, giving 50*exp(-7/42) and 50*exp(-7/7).
    final metric = ctlAtlTsb([
      ...List<double>.filled(7, 50), ...List<double>.filled(7, 0),
    ]);
    expect(metric.value!.ctl, closeTo(42.3240862445307, 1e-12));
    expect(metric.value!.atl, closeTo(18.3939720585721, 1e-12));
    expect(ctlAtlTsb(List<double>.filled(14, 50)).value!.ctl,
        closeTo(50, 1e-12));
  });
}
