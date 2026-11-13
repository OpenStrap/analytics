import 'dart:convert';

import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

import '../../../tool/incremental/rr_stream.dart' as prototype;

void main() {
  // why: a retained checkpoint must describe its creation prefix after more folds.
  // # catches: toJson exposes the live RR, time, class, or anchor lists.
  for (final cap in [null, kMaxArtifactRun]) {
    test('RR checkpoint owns lists (cap=$cap)', () {
      final c = RrCorrector(maxArtifactRun: cap);
      c.fold(List.filled(500, 800.0));
      final saved = c.toJson();
      final text = jsonEncode(saved);
      c.fold([810, 820]);
      expect(jsonEncode(saved), text);
      expect(jsonEncode(RrCorrector.fromJson(saved).toJson()), text);
      final edited = saved[cap == null ? 'rr' : 'capped'];
      if (cap == null) {
        (edited as List)[0] = 123.0;
      } else {
        ((edited as Map)['rr'] as List)[0] = 123.0;
      }
      expect(jsonEncode(c.toJson()), isNot(contains('123.0')));
    });
  }
  test('prototype RR checkpoint owns lists', () {
    final c = prototype.RrCorrector()..fold(List.filled(500, 800.0));
    final saved = c.toJson();
    final text = jsonEncode(saved);
    c.fold([810, 820]);
    expect(jsonEncode(saved), text);
    expect(jsonEncode(prototype.RrCorrector.fromJson(saved).toJson()), text);
  });
}
