// The screen's artifact fraction is a share of the beats the corrector saw. When
// it saw none there is no denominator: the diagnostics carry null (absent), never
// the 1.0 a caller computes from `1 - cleanFraction` of an empty series, which
// would read as "100% of beats are artifacts" beside zero beats. Verdicts are
// unchanged: the fraction handed in still drives the artifact gate.
import 'dart:convert';

import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

const _none = RrCleaningCounts(raw: 0, corrected: 0, dropped: 0);

void main() {
  test('batch: zero beats in -> no artifact fraction, same absent verdict', () {
    final r = irregularBeatScreenDetailed(const [],
        artifactFraction: 1.0, cleaning: _none);
    expect(r.diagnostics.artifactFraction, isNull);
    expect((r.diagnostics.toJson()['beats'] as Map)['artifact_fraction'], isNull);
    expect(r.diagnostics.rrRaw, 0, reason: 'the raw count stays a real zero');
    expect(r.metric.present, isFalse);
    expect(jsonEncode(r.metric.toJson((v) => v.toJson())),
        jsonEncode(irregularBeatScreen(const [], artifactFraction: 1.0)
            .toJson((v) => v.toJson())));
  });

  test('batch: the fraction is kept whenever the corrector saw beats, or the '
      'caller gave no counts (unchanged)', () {
    const seen = RrCleaningCounts(raw: 100, corrected: 5, dropped: 2);
    expect(
        irregularBeatScreenDetailed(const [], artifactFraction: 0.07, cleaning: seen)
            .diagnostics
            .artifactFraction,
        0.07);
    expect(irregularBeatScreenDetailed(const []).diagnostics.artifactFraction, 0.0);
  });

  test('streaming: zero beats in -> no artifact fraction', () {
    final r = IrregularScreenState().evaluateDetailed(const [], const [],
        artifactFraction: 1.0, cleaning: _none);
    expect(r.diagnostics.artifactFraction, isNull);
    expect(r.metric.present, isFalse);
  });

  test('the wire round-trips an absent fraction', () {
    final d = irregularBeatScreenDetailed(const [],
            artifactFraction: 1.0, cleaning: _none)
        .diagnostics;
    final text = jsonEncode(d.toJson());
    final back = IrregularDiagnostics.fromJson(
        (jsonDecode(text) as Map).cast<String, dynamic>());
    expect(back.artifactFraction, isNull);
    expect(jsonEncode(back.toJson()), text);
  });
}
