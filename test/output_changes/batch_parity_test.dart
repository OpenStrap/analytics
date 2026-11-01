import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import '../../tool/reproduce_outputs.dart';

void main() {
  final config = jsonDecode(File('test/fixtures/output_changes.json').readAsStringSync()) as Map<String, dynamic>;
  final golden = jsonDecode(File('test/fixtures/output_batch_parity.json').readAsStringSync()) as Map<String, dynamic>;
  final cases = reproductionCases(config);
  test('the full synthetic corpus is available', () {
    expect(cases.length, 12);
    expect(golden['cases'], hasLength(12));
  });
  for (var i = 0; i < 12; i++) {
    test('split-2 public batch arithmetic survives refactoring, case $i', () {
      // Frozen before aggregator adoption, not computed by the current path.
      // Covers high-frequency jitter, time holes, cap boundaries and epochs.
      expect(reproduce(cases[i]), golden['cases'][i], reason: 'case $i');
    });
  }
}
