// Persistent, exact feature rows for the cardio sleep stager.

import '../../aggregate/json_support.dart';

// Reformulates cardioStager() feature extraction and classification: van Hees
// 2013 motion and Long 2016 / Fonseca 2015/2018 cardiorespiratory staging.
// Internal fitted weights and rules remain ESTIMATE with low confidence.
// Session-onset anchoring and post-gap re-anchoring preserve the pre-bump grid;
// shared arithmetic preserves labels except for separately documented
// RR/spectral changes. Cached rows require matching dependencies; missing phases
// are recomputed.
/// A cache identity for one cardio feature epoch.
///
/// [fingerprint] is an unsigned 64-bit FNV-1a digest assembled by the stager
/// from every input that can affect the row. It deliberately is not a Dart
/// [Object.hashCode]: cache files have to work across processes and releases.
class CardioRowKey {
  final int startSec;
  final int epochSec;
  final int fingerprint;

  const CardioRowKey(this.startSec, this.epochSec, this.fingerprint);

  @override
  bool operator ==(Object other) =>
      other is CardioRowKey &&
      startSec == other.startSec &&
      epochSec == other.epochSec &&
      fingerprint == other.fingerprint;

  @override
  int get hashCode => Object.hash(startSec, epochSec, fingerprint);
}

/// The seven raw feature values consumed by one cardio epoch classifier row.
class CardioEpochRow {
  final double motion;
  final double hr;
  final double hrSd;
  final double rmssd;
  final double lfhf;
  final double rk;
  final double sdnn;

  const CardioEpochRow(
      this.motion, this.hr, this.hrSd, this.rmssd, this.lfhf, this.rk, this.sdnn);
}

/// Reusable, mergeable cache of exact cardio feature rows.
class CardioRowCache {
  // 2: window RMSSD and R(k) skip seam pairs (upstream merge); older rows
  // hold values computed across seams.
  static const int _version = 2;
  final Map<CardioRowKey, CardioEpochRow> _rows = {};

  CardioRowCache();

  /// Number of successful lookups since this cache was created or decoded.
  int hits = 0;

  /// Number of unsuccessful lookups since this cache was created or decoded.
  int misses = 0;

  int get length => _rows.length;

  CardioEpochRow? lookup(CardioRowKey key) {
    final row = _rows[key];
    if (row == null) {
      misses++;
    } else {
      hits++;
    }
    return row;
  }

  void insert(CardioRowKey key, CardioEpochRow row) {
    _rows[key] = row;
  }

  void retainWhere(bool Function(CardioRowKey key) keep) {
    _rows.removeWhere((key, _) => !keep(key));
  }

  /// Union [other] into this cache. Rows already held here win identically-keyed
  /// ties; an identical key can only describe an identical input row.
  void merge(CardioRowCache other) {
    for (final entry in other._rows.entries) {
      _rows.putIfAbsent(entry.key, () => entry.value);
    }
  }

  Map<String, dynamic> toJson() {
    final entries = _rows.entries.toList()
      ..sort((a, b) {
        final k = a.key, q = b.key;
        var c = k.startSec.compareTo(q.startSec);
        if (c != 0) return c;
        c = k.epochSec.compareTo(q.epochSec);
        if (c != 0) return c;
        return k.fingerprint.compareTo(q.fingerprint);
      });
    return {
      'version': _version,
      'rows': [
        for (final entry in entries)
          {
            'startSec': entry.key.startSec,
            'epochSec': entry.key.epochSec,
            // Decimal strings keep a 64-bit word lossless in JSON
            // implementations whose numeric type is IEEE-754.
            'fingerprint': entry.key.fingerprint.toSigned(64).toString(),
            'motion': encodeDouble(entry.value.motion),
            'hr': encodeDouble(entry.value.hr),
            'hrSd': encodeDouble(entry.value.hrSd),
            'rmssd': encodeDouble(entry.value.rmssd),
            'lfhf': encodeDouble(entry.value.lfhf),
            'rk': encodeDouble(entry.value.rk),
            'sdnn': encodeDouble(entry.value.sdnn),
          }
      ],
    };
  }

  factory CardioRowCache.fromJson(Map<String, dynamic> json) {
    try {
      if (json['version'] != _version) {
        throw const FormatException('Unsupported CardioRowCache version');
      }
      final raw = json['rows'];
      if (raw is! List) throw const FormatException('Invalid CardioRowCache rows');
      final cache = CardioRowCache();
      for (final item in raw) {
        if (item is! Map) throw const FormatException('Invalid CardioRowCache row');
        final row = item.cast<Object?, Object?>();
        int readInt(String name) {
          final value = row[name];
          if (value is! int) throw FormatException('Invalid $name');
          return value;
        }
        final fingerprint = row['fingerprint'];
        if (fingerprint is! String) {
          throw const FormatException('Invalid fingerprint');
        }
        final fp = int.tryParse(fingerprint);
        if (fp == null) {
          throw const FormatException('Invalid fingerprint');
        }
        final key = CardioRowKey(readInt('startSec'), readInt('epochSec'), fp);
        if (key.epochSec <= 0) throw const FormatException('Invalid epochSec');
        if (cache._rows.containsKey(key)) {
          throw const FormatException('Duplicate CardioRowCache row');
        }
        cache._rows[key] = CardioEpochRow(
          decodeDouble(row['motion']),
          decodeDouble(row['hr']),
          decodeDouble(row['hrSd']),
          decodeDouble(row['rmssd']),
          decodeDouble(row['lfhf']),
          decodeDouble(row['rk']),
          decodeDouble(row['sdnn']),
        );
      }
      return cache;
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('Invalid CardioRowCache');
    }
  }
}
