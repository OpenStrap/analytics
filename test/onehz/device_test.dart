import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

void main() {
  group('device family dispatch seam', () {
    test('unknown family gets NO constants — never gen4 as a fallback', () {
      const k = {'gen4': 230, 'gen5': 210};
      expect(calibrationFor(k, 'gen4'), 230);
      expect(calibrationFor(k, 'gen5'), 210);
      expect(calibrationFor(k, null), isNull);
      expect(calibrationFor(k, ''), isNull);
      expect(calibrationFor(k, 'gen6'), isNull);
      // No trimming, no case folding: a near-miss stamp is a refusal, not a
      // hint. Matching one would apply gen4's counts to another band's.
      expect(calibrationFor(k, 'GEN4'), isNull);
      expect(calibrationFor(k, ' gen4'), isNull);
      // a family the metric itself has not calibrated is also a refusal
      expect(calibrationFor(const {'gen5': 1}, 'gen4'), isNull);
    });

    test('the set of families is open — a new id needs no enum entry', () {
      // The whole point of deleting `DeviceFamily`: one metric can be
      // calibrated for a band before any other is.
      expect(calibrationFor(const {'gen6': 42}, 'gen6'), 42);
      expect(calibrationFor(const {'gen6': 42}, 'gen4'), isNull);
    });

    test('refusal note is machine-readable', () {
      expect(unknownFamilyNote(null), 'unknown_device_family:id=none');
      expect(unknownFamilyNote(''), 'unknown_device_family:id=none');
      expect(unknownFamilyNote('gen6'), 'unknown_device_family:id=gen6');
    });
  });
}
