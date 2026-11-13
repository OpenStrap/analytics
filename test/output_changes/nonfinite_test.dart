import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:openstrap_analytics/onehz.dart';
import '../../tool/reproduce_outputs.dart';

void main() {
  for (final bad in [double.nan, double.infinity, double.negativeInfinity]) {
    test('all batch timestamp guards abstain on $bad', () {
      final nn = [for (var i = 0; i < 1500; i++) 900.0 + 40 * (i % 7)];
      final ts = [for (var i = 0; i < nn.length; i++) i * 1100.0];
      ts[700] = bad;
      for (final metric in [hrvTime(nn, nnTimesMs: ts), hrvFreq(nn, ts, artifactFraction: 0),
        rsaRespRate(nn, ts, artifactFraction: 0), cvhrApneaScreen(nn, ts, artifactFraction: 0), nocturnalRmssd(nn, ts),
        sleepSessionRmssdDetail(nn, ts, startSec: 1, endSec: 7200)]) {
        expect(metric.present, isFalse);
        expect(metric.note, 'non-finite beat time');
      }
    });
  }

  test('Abstain when a beat has no finite time: unrounded synthetic batch regression', () {
    // Old/new values were captured independently on 3a7ca34 and f8e7d3c.
    // The fixture gives the input formulas and provenance, never personal data.
    final fixture = jsonDecode(File('test/fixtures/output_changes.json').readAsStringSync()) as Map<String, dynamic>;
    final actual = reproduce(fixture);
    for (final key in ['nonfinite']) {
      expect(actual[key], fixture['new'][key], reason: key);
    }
  });
}
