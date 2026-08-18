import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

void main() {
  group('device family dispatch seam', () {
    test('known ids parse, everything else is unknown', () {
      expect(deviceFamilyOf('gen4'), DeviceFamily.gen4);
      expect(deviceFamilyOf('gen5'), DeviceFamily.gen5);
      for (final id in [null, '', 'GEN4', 'gen6', 'whoop4', 'imported']) {
        expect(deviceFamilyOf(id), isNull, reason: 'id=$id must be unknown');
      }
    });

    test('id round-trips', () {
      for (final f in DeviceFamily.values) {
        expect(deviceFamilyOf(deviceFamilyId(f)), f);
      }
    });

    test('unknown family gets NO constants — never gen4 as a fallback', () {
      const k = {DeviceFamily.gen4: 230, DeviceFamily.gen5: 210};
      expect(calibrationFor(k, 'gen4'), 230);
      expect(calibrationFor(k, 'gen5'), 210);
      expect(calibrationFor(k, null), isNull);
      expect(calibrationFor(k, 'gen6'), isNull);
      // a family the metric itself has not calibrated is also a refusal
      expect(calibrationFor(const {DeviceFamily.gen5: 1}, 'gen4'), isNull);
    });

    test('refusal note is machine-readable', () {
      expect(unknownFamilyNote(null), 'unknown_device_family:id=none');
      expect(unknownFamilyNote(''), 'unknown_device_family:id=none');
      expect(unknownFamilyNote('gen6'), 'unknown_device_family:id=gen6');
    });
  });
}
