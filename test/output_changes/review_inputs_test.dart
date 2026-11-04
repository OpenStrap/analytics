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
  test('a capped reset keeps source time but invalidates regressing HRV time', () {
    // The RR clock exceeds elapsed sensor time before the cap. Re-anchoring
    // the next independent segment must retain its actual sensor timestamp.
    final rr = [...List<double>.filled(100, 1500),
      ...List<double>.filled(33, 3000), ...List<double>.filled(100, 1500)];
    final ts = [for (var i = 0; i < rr.length; i++) 1.7e12 + i * 1000];
    final result = correctRr(rr, rrTsMs: ts);
    expect(result.nnTimesMs[99], 150000);
    expect(result.nnTimesMs[100], 134500);
    for (final metric in [
      hrvTime(result.nn, nnTimesMs: result.nnTimesMs),
      nocturnalRmssd(result.nn, result.nnTimesMs),
      sleepSessionRmssdDetail(result.nn, result.nnTimesMs,
          startSec: 1, endSec: 400),
      sleepSessionRmssdDetail(result.nn, result.nnTimesMs,
          startSec: 1, endSec: 100),
    ]) {
      expect(metric.present, isFalse);
      expect(metric.note, 'regressing beat time');
    }
  });

  for (final entry in <String, Metric<dynamic> Function(List<double>, List<double>)>{
    'frequency HRV': (nn, ts) => hrvFreq(nn, ts, artifactFraction: 0),
    'RSA': (nn, ts) => rsaRespRate(nn, ts, artifactFraction: 0),
    'CVHR': (nn, ts) => cvhrApneaScreen(nn, ts, artifactFraction: 0),
  }.entries) {
    test('${entry.key} refuses a regressing spectral clock', () {
      final nn = List<double>.filled(1500, 900);
      final ts = [for (var i = 0; i < nn.length; i++) i * 900.0];
      ts[700] = ts[699] - 500;
      final metric = entry.value(nn, ts);
      expect(metric.present, isFalse);
      expect(metric.note, 'regressing beat time');
    });
  }

  for (final times in <List<double>>[[], [800], [800, 1700, 2500]]) {
    test('time HRV refuses a supplied ${times.length}-beat clock for two NN', () {
      final metric = hrvTime([800, 900], nnTimesMs: times);
      expect(metric.present, isFalse);
      expect(metric.note, 'beat time length mismatch');
      // NN-only remains supported, as does a matching two-beat clock.
      // One 100 ms difference has RMSSD exactly 100 ms.
      expect(hrvTime([800, 900]).value!.rmssd, 100);
      expect(hrvTime([800, 900], nnTimesMs: [800, 1700]).value!.rmssd, 100);
    });
  }

  test('cosinor refuses overflow from a subnormal positive period', () {
    final metric = cosinor(
      List<double>.generate(48, (i) => i.toDouble()),
      List<double>.generate(48, (i) => 60.0 + i % 3),
      periodHours: 1e-320,
    );
    expect(metric.present, isFalse);
    expect(metric.note, 'non-finite cosinor design');
  });
  for (final bad in [double.nan, double.infinity, double.negativeInfinity]) {
    for (final axis in ['time', 'response']) {
      test('cosinor refuses non-finite $axis moment $bad', () {
        final ts = List<double>.generate(48, (i) => i.toDouble());
        final values = List<double>.generate(48, (i) => 60.0 + i % 3);
        (axis == 'time' ? ts : values)[12] = bad;
        final metric = cosinor(ts, values);
        expect(metric.present, isFalse);
        expect(metric.note, 'non-finite cosinor design');
      });
    }
  }
  test('cosinor refuses non-finite moments from finite overflow', () {
    final metric = cosinor(
      List<double>.generate(48, (i) => i.toDouble()),
      List<double>.generate(48, (i) => i.isEven ? 1e308 : -1e308),
    );
    expect(metric.present, isFalse);
    expect(metric.note, 'non-finite cosinor design');
  });

  test('an entirely unknown load history abstains', () {
    expect(ctlAtlTsb(List<double>.filled(42, double.nan)).present, isFalse);
  });

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
