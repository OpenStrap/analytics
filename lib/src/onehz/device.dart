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
//   const _ceiling = {'gen4': 230, 'gen5': 210};
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

/// This metric's own constants for [family], or null when it must REFUSE —
/// either the family is unstamped or this metric has nothing calibrated for it.
/// Both are refusals: never substitute another family's constants.
///
/// THE SET OF FAMILIES IS OPEN, and it is each map's own business who is in it.
/// There used to be a closed `DeviceFamily` enum here, which made "a strap this
/// build has never heard of" and "a strap this METRIC has no numbers for" the
/// same answer arrived at in two places — and meant a new band could not be
/// calibrated for one metric at a time. A key is in a map or it is not.
///
/// Null and empty are not keys: both mean NO STAMP, which no map may answer
/// for. (An id is never trimmed or case-folded on the way in — the stamp is
/// written by ingest, and quietly matching a near-miss is how one family's
/// constants get applied to another's counts.)
T? calibrationFor<T>(Map<String, T> byFamily, String? family) =>
    (family == null || family.isEmpty) ? null : byFamily[family];

/// MACHINE-READABLE refusal note, same convention as `need_baseline:`.
///
///     unknown_device_family:id=<id|none>
String unknownFamilyNote(String? id) =>
    'unknown_device_family:id=${(id == null || id.isEmpty) ? 'none' : id}';
