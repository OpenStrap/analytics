import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import '../../tool/reproduce_outputs.dart';

void main() {
  test('Compute circadian variance with centered moments: unrounded synthetic batch regression', () {
    // Old/new values were captured independently on 3a7ca34 and f8e7d3c.
    // The fixture gives the input formulas and provenance, never personal data.
    final fixture = jsonDecode(File('test/fixtures/output_changes.json').readAsStringSync()) as Map<String, dynamic>;
    final actual = reproduce(fixture);
    for (final key in ['circadian']) {
      expect(actual[key], fixture['new'][key], reason: key);
    }
  });
}
