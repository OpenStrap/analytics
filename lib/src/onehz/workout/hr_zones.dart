import 'dart:math' as math;

import '../types.dart';
import '../util.dart';

/// One display heart-rate zone defined by a bpm interval.
class HeartRateZone {
  final int number; // 1..5
  final double lower; // inclusive bpm
  final double upper; // exclusive except zone 5
  // Fraction of the anchor this zone set was built on: of HRmax for the
  // %HRmax sets, of HEART-RATE RESERVE for a Karvonen set (`source` says which).
  final double lowerPct;
  final double upperPct;

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
  static HeartRateZoneSet zonesFromMaxHr(double maxHr,
      {String source = 'manual'}) {
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

  /// Minimum trailing daily resting-HR values [reserveZones] will accept.
  ///
  /// The anchor is the 28-day MEDIAN resting HR. One night is a measurement of
  /// that night — a poor night moves every zone boundary in the app, and the
  /// user has no way to see why. Half the window is the floor.
  static const int reserveMinDays = 14;

  /// Karvonen %HRR zones: the same 50/60/70/80/90 convention, in RESERVE units.
  ///
  /// `lower = rhr + pct · (maxHr − rhr)`, so a zone is a band between two heart
  /// rates the band actually measured instead of one guessed one — and Banister
  /// TRIMP already works in reserve units, so strain and zones finally agree.
  ///
  /// STILL A MODEL. %HRR bands are a convention, not a measurement of your
  /// thresholds: never "your aerobic threshold", never "fat burning zone". What
  /// changes is that the app can name the two numbers it anchored on.
  ///
  /// [restingHrHistory] is the trailing daily resting HR (up to 28 days, any
  /// order); the median of the valid values is the anchor. It is taken as a
  /// series rather than a scalar on purpose: a call site that has only tonight
  /// cannot pass tonight and have it read as the baseline.
  ///
  /// Returns null when there is not enough history, or when [maxHr] is not
  /// above the anchor — an inverted reserve is not a zone set, and there is no
  /// substitute number to fall back to.
  static HeartRateZoneSet? reserveZones({
    required List<double> restingHrHistory,
    required double maxHr,
    int minDays = reserveMinDays,
    String source = 'karvonen',
  }) {
    final valid = [
      for (final v in restingHrHistory)
        if (v.isFinite && v > 0) v
    ];
    if (valid.length < minDays) return null;
    valid.sort();
    final rhr = valid.length.isOdd
        ? valid[valid.length ~/ 2]
        : (valid[valid.length ~/ 2 - 1] + valid[valid.length ~/ 2]) / 2.0;
    if (!(maxHr > rhr)) return null;
    final reserve = maxHr - rhr;
    final built = <HeartRateZone>[];
    for (var i = 0; i < 5; i++) {
      final loPct = zoneEdges[i];
      final hiPct = zoneEdges[i + 1];
      built.add(HeartRateZone(
        number: i + 1,
        lower: rhr + loPct * reserve,
        upper: rhr + hiPct * reserve,
        lowerPct: loPct,
        upperPct: hiPct,
      ));
    }
    // A very low resting HR widens zone 1 a long way. That is the arithmetic
    // working, not a bug, and it will be reported as one.
    return HeartRateZoneSet(zones: built, maxHr: maxHr, source: source);
  }

  /// Time-in-zone from a time-ordered HR stream.
  ///
  /// Each sample is credited with the duration until the next sample. The tail
  /// sample gets the median plausible interval so a regular stream is fully
  /// accounted for without letting one pathological gap dominate a zone.
  ///
  /// NULL when [sampleCadenceSeconds] cannot vouch for the stream's cadence —
  /// see it for the rule. Every duration in here is a multiple of that cadence,
  /// so without it there is no time-in-zone, only a number shaped like one: a
  /// 301 s stream used to credit each reading with a single second and publish
  /// a ~300× undercount as minutes.
  static TimeInHeartRateZone? timeInZone(
    List<HrSample> hr,
    HeartRateZoneSet zoneSet,
  ) {
    final sorted = [...hr]..sort((a, b) => a.tsMs.compareTo(b.tsMs));
    final zoneSeconds = List<double>.filled(5, 0);
    var below = 0.0;

    final tailSeconds =
        sampleCadenceSeconds([for (final s in sorted) s.tsMs / 1000.0]);
    if (tailSeconds == null) return null;
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
    return gapSeconds > 0
        ? math.min(gapSeconds, fallbackSeconds)
        : fallbackSeconds;
  }

}
