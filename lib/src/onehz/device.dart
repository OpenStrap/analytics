// device.dart — the per-device dispatch seam.
//
// A "device family" is the sensor package a row was MEASURED BY, stamped at
// ingest from the link that produced it (edge: `decoded_onehz.device_family`).
// It is not a model name and it is never inferred from the data afterwards.
//
// Why it exists: the same column means different things on different straps —
// gen4 reports skin temperature as a raw ADC count, gen5 as centi-°C; the HR
// ceiling, the accel scale and the staging inputs all differ too. A universal
// constant across families is a fabricated number for whichever family it was
// not calibrated on.
//
// THE CONTRACT: unknown family ⇒ REFUSE. Every historical row predates this
// column and carries NULL, and a strap we have not calibrated for is not gen4
// with a different badge. A metric that cannot name its own constants for the
// family in front of it returns an ABSENT Metric with [unknownFamilyNote] —
// never gen4's numbers as a fallback.
//
// HOW A METRIC USES IT — the whole mechanism, no framework:
//
//   const _ceiling = {DeviceFamily.gen4: 230, DeviceFamily.gen5: 210};
//
//   Metric<double> foo(..., {String? deviceFamily}) {
//     final hi = calibrationFor(_ceiling, deviceFamily);
//     if (hi == null) {
//       return Metric.absent(
//         tier: Tier.high,
//         inputs_used: const ['hr'],
//         note: unknownFamilyNote(deviceFamily),
//       );
//     }
//     ...
//   }
//
// The constants live NEXT TO the metric that uses them. There is deliberately
// no registry, no plugin table and no central constants file: a shared table
// is how one family's number quietly becomes another's.

/// The sensor packages we have calibrated algorithms for.
///
/// `gen5` covers the whole fd4b family (WHOOP 5, MG) — they share one sensor
/// package. Add a value here only alongside the calibration work; an enum entry
/// with no constants behind it just moves the refusal one step later.
enum DeviceFamily { gen4, gen5 }

/// Parse the ingest-stamped family id (`decoded_onehz.device_family`).
///
/// Returns null for NULL, for empty, and for any id this build does not know —
/// all three mean "unknown provenance", which is its own case, not gen4.
DeviceFamily? deviceFamilyOf(String? id) => switch (id) {
      'gen4' => DeviceFamily.gen4,
      'gen5' => DeviceFamily.gen5,
      _ => null,
    };

/// The id a [DeviceFamily] is stamped as. Inverse of [deviceFamilyOf].
String deviceFamilyId(DeviceFamily f) => f.name;

/// This metric's own constants for [family], or null when it must REFUSE —
/// either the family is unknown or this metric has nothing calibrated for it.
/// Both are refusals: never substitute another family's constants.
T? calibrationFor<T>(Map<DeviceFamily, T> byFamily, String? family) {
  final f = deviceFamilyOf(family);
  return f == null ? null : byFamily[f];
}

/// MACHINE-READABLE refusal note, same convention as `need_baseline:`.
///
///     unknown_device_family:id=<id|none>
String unknownFamilyNote(String? id) =>
    'unknown_device_family:id=${(id == null || id.isEmpty) ? 'none' : id}';
