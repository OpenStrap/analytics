import 'dart:convert';
import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

void main() {
  test('default capped stream retains explicit gaps across chunk and restart', () {
    final rr = [...List<double>.filled(100, 900),
      ...List<double>.filled(33, 100), ...List<double>.filled(100, 900)];
    var stream = RrCorrector();
    final classes = <BeatClass>[];
    final nn = <double>[];
    for (var i = 0; i < rr.length; i++) {
      final settled = stream.fold([rr[i]]);
      classes.addAll(settled.classes);
      nn.addAll(settled.nn);
      if ([99, 119, 132].contains(i)) {
        stream = RrCorrector.fromJson(
            jsonDecode(jsonEncode(stream.toJson())) as Map<String, dynamic>);
      }
      final snap = stream.snapshot();
      final batch = correctRr(rr.sublist(0, i + 1));
      expect([...classes, ...snap.tailClasses], batch.classes,
          reason: 'prefix ${i + 1}');
      expect([...nn, ...snap.tailNn], batch.nn, reason: 'prefix ${i + 1}');
    }
    expect([...classes, ...stream.snapshot().tailClasses].sublist(100, 133),
        everyElement(BeatClass.gap));
    expect(stream.snapshot().droppedCount, 33);
  });

  test('uncapped checkpoint rejects cap-only gap class', () {
    final stream = RrCorrector(maxArtifactRun: null)..fold(
        List<double>.filled(300, 900));
    final state = jsonDecode(jsonEncode(stream.toJson())) as Map<String, dynamic>;
    state['lastFinal'] = BeatClass.gap.index;
    expect(() => RrCorrector.fromJson(state), throwsFormatException);
  });
}
