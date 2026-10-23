import 'aggregator.dart';

/// Wraps the JSON form of [state] in a versioned envelope:
/// {'kind', 'version', 'state'}. Throws [UnsupportedError] if [agg] is not
/// persistable.
Map<String, Object?> encodeCheckpoint<S>(
  Aggregator<S, dynamic, dynamic> agg,
  S state, {
  required String kind,
  required int version,
}) {
  if (!agg.persistable) {
    throw UnsupportedError('${agg.runtimeType} is not persistable');
  }
  return {'kind': kind, 'version': version, 'state': agg.encodeState(state)};
}

/// Restores a state written by [encodeCheckpoint]. Returns null, never a
/// guess, when the kind or version differ or the envelope or state is
/// malformed; the caller then recomputes from raw data.
S? decodeCheckpoint<S>(
  Aggregator<S, dynamic, dynamic> agg,
  Object? json, {
  required String kind,
  required int version,
}) {
  if (json is! Map ||
      json['kind'] != kind ||
      json['version'] is! int ||
      json['version'] != version ||
      !json.containsKey('state')) {
    return null;
  }
  try {
    return agg.decodeState(json['state']);
  } on FormatException {
    return null;
  }
}
