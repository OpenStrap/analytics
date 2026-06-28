import 'dart:math' as math;

import '../types.dart';

/// One display heart-rate zone defined by a bpm interval.
class HeartRateZone {
  final int number; // 1..5
  final double lower; // inclusive bpm
  final double upper; // exclusive except zone 5
  final double lowerPct; // fraction of HRmax
  final double upperPct; // fraction of HRmax

  const HeartRateZone({
    required this.number,
    required this.lower,
    required this.upper,
    required this.lowerPct,
    required this.upperPct,
  });
}

/// The five display heart-rate zones built from a max HR.
class HeartRateZoneSet {
  final List<HeartRateZone> zones;
  final double maxHr;
  final String source; // "tanaka" or "manual"

  const HeartRateZoneSet({
    required this.zones,
    required this.maxHr,
    required this.source,
  }) : assert(zones.length == 5);

  /// Return the zone number (1..5), or 0 when below zone 1.
  int zoneNumber(double bpm) {
    for (final zone in zones) {
      if (zone.number == 5) {
        if (bpm >= zone.lower) return 5;
      } else if (bpm >= zone.lower && bpm < zone.upper) {
        return zone.number;
      }
    }
    return 0;
  }
}

/// Time spent in each display heart-rate zone.
class TimeInHeartRateZone {
  final List<double> seconds; // z1..z5
  final double belowZone1;

  const TimeInHeartRateZone({
    required this.seconds,
    required this.belowZone1,
  }) : assert(seconds.length == 5);

  double get total => seconds.fold<double>(belowZone1, (sum, v) => sum + v);

  double secondsInZone(int zone) =>
      zone >= 1 && zone <= 5 ? seconds[zone - 1] : 0;

  /// Rounded whole minutes per zone, suitable for the app's existing payload.
  Map<String, int> toRoundedMinuteMap() => {
        'z1': (seconds[0] / 60.0).round(),
        'z2': (seconds[1] / 60.0).round(),
        'z3': (seconds[2] / 60.0).round(),
        'z4': (seconds[3] / 60.0).round(),
        'z5': (seconds[4] / 60.0).round(),
      };
}

/// Canonical display HR zones: %HRmax bands with duration-aware accumulation.
class HeartRateZones {
  /// Zone edges for z1..z5: 50/60/70/80/90/100% HRmax.
  static const List<double> zoneEdges = [0.50, 0.60, 0.70, 0.80, 0.90, 1.00];

  /// Tanaka (2001) age-predicted max HR.
  static double tanakaMaxHr(double age) => 208.0 - 0.7 * age;

  /// Build zones from age or a manual max-HR override.
  static HeartRateZoneSet zones({
    required double age,
    double? maxHrOverride,
  }) {
    if (maxHrOverride != null) {
      return zonesFromMaxHr(maxHrOverride, source: 'manual');
    }
    return zonesFromMaxHr(tanakaMaxHr(age), source: 'tanaka');
  }

  /// Build zones directly from a known max HR.
  static HeartRateZoneSet zonesFromMaxHr(double maxHr, {String source = 'manual'}) {
    final built = <HeartRateZone>[];
    for (var i = 0; i < 5; i++) {
      final loPct = zoneEdges[i];
      final hiPct = zoneEdges[i + 1];
      built.add(HeartRateZone(
        number: i + 1,
        lower: loPct * maxHr,
        upper: hiPct * maxHr,
        lowerPct: loPct,
        upperPct: hiPct,
      ));
    }
    return HeartRateZoneSet(zones: built, maxHr: maxHr, source: source);
  }

  /// Time-in-zone from a time-ordered HR stream.
  ///
  /// Each sample is credited with the duration until the next sample. The tail
  /// sample gets the median plausible interval so a regular stream is fully
  /// accounted for without letting one pathological gap dominate a zone.
  static TimeInHeartRateZone timeInZone(
    List<HrSample> hr,
    HeartRateZoneSet zoneSet,
  ) {
    final sorted = [...hr]..sort((a, b) => a.tsMs.compareTo(b.tsMs));
    final zoneSeconds = List<double>.filled(5, 0);
    var below = 0.0;
    if (sorted.isEmpty) {
      return TimeInHeartRateZone(seconds: zoneSeconds, belowZone1: 0);
    }

    final tailSeconds = _medianIntervalSeconds(sorted);
    for (var i = 0; i < sorted.length; i++) {
      final sample = sorted[i];
      if (!sample.valid) continue;
      final durSeconds = i < sorted.length - 1
          ? _boundedGapSeconds(sorted[i + 1].tsMs - sample.tsMs, tailSeconds)
          : tailSeconds;
      final zone = zoneSet.zoneNumber(sample.hr);
      if (zone >= 1) {
        zoneSeconds[zone - 1] += durSeconds;
      } else {
        below += durSeconds;
      }
    }
    return TimeInHeartRateZone(seconds: zoneSeconds, belowZone1: below);
  }

  static double _boundedGapSeconds(double gapMs, double fallbackSeconds) {
    final gapSeconds = gapMs / 1000.0;
    return gapSeconds > 0 ? math.min(gapSeconds, fallbackSeconds) : fallbackSeconds;
  }

  static double _medianIntervalSeconds(List<HrSample> sorted) {
    if (sorted.length < 2) return 1.0;
    final gaps = <double>[];
    for (var i = 1; i < sorted.length; i++) {
      final gapSeconds = (sorted[i].tsMs - sorted[i - 1].tsMs) / 1000.0;
      if (gapSeconds > 0 && gapSeconds <= 300) gaps.add(gapSeconds);
    }
    if (gaps.isEmpty) return 1.0;
    gaps.sort();
    return math.max(gaps[gaps.length ~/ 2], 1.0);
  }
}
