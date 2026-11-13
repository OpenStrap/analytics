// JSON helpers shared by the aggregate persistence codecs. Not exported.
//
// Non-finite doubles are written as the strings 'NaN', 'Infinity' and
// '-Infinity' (the same strings incremental_core.dart reads). Every reader
// throws FormatException, never TypeError or RangeError.

import 'dart:typed_data';

/// A double as a JSON value: finite stays a number, the rest become strings.
Object encodeDouble(double value) {
  if (value.isFinite) return value;
  if (value.isNaN) return 'NaN';
  return value > 0 ? 'Infinity' : '-Infinity';
}

/// Inverse of [encodeDouble]; an int is accepted for a double.
double decodeDouble(Object? value) {
  if (value is num) return value.toDouble();
  if (value == 'NaN') return double.nan;
  if (value == 'Infinity') return double.infinity;
  if (value == '-Infinity') return double.negativeInfinity;
  throw const FormatException('Invalid number');
}

double? decodeDoubleOrNull(Object? value) =>
    value == null ? null : decodeDouble(value);

/// A non-negative int.
int decodeCount(Object? value) {
  if (value is! int || value < 0) throw const FormatException('Invalid count');
  return value;
}

List<Object?> decodeList(Object? value) {
  if (value is! List) throw const FormatException('Expected a list');
  return value;
}

/// A JSON object with string keys.
Map<String, Object?> decodeMap(Object? value) {
  if (value is! Map) throw const FormatException('Expected an object');
  for (final key in value.keys) {
    if (key is! String) throw const FormatException('Expected string keys');
  }
  return value.cast<String, Object?>();
}

/// The value at [key]; the key must be present (null is a value).
Object? field(Map<String, Object?> map, String key) {
  if (!map.containsKey(key)) throw FormatException('Missing field $key');
  return map[key];
}

List<Object> encodeDoubles(Float64List values) =>
    [for (final value in values) encodeDouble(value)];

Float64List decodeDoubles(Object? value) {
  final list = decodeList(value);
  final result = Float64List(list.length);
  for (var i = 0; i < list.length; i++) {
    result[i] = decodeDouble(list[i]);
  }
  return result;
}
