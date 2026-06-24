// §9 Training load (calcLoad) + fitness trend (calcFitnessTrend).
import 'dart:math' as math;
import 'types.dart';
import 'util.dart';

class LoadResult {
  final double? acwr;
  final double acute;
  final double chronic;
  final String band;
  final double confidence;
  final String tier;
  final List<String> inputs_used;
  const LoadResult({
    required this.acwr,
    required this.acute,
    required this.chronic,
    required this.band,
    required this.confidence,
    required this.tier,
    required this.inputs_used,
  });
  Map<String, dynamic> toJson() => {
        'acwr': acwr,
        'acute': acute,
        'chronic': chronic,
        'band': band,
        'confidence': confidence,
        'tier': tier,
        'inputs_used': inputs_used,
      };
}

LoadResult calcLoad(List<DailyStrain> dailyStrain) {
  final sorted = [...dailyStrain]..sort((a, b) => a.ts.compareTo(b.ts));
  final days = sorted.length;

  if (days < 7) {
    return LoadResult(
      acwr: null,
      acute: 0,
      chronic: 0,
      band: 'unknown',
      confidence: round(math.min(1.0, days / 28), 4),
      tier: 'HIGH',
      inputs_used: const ['daily_strain'],
    );
  }

  const lambdaAcute = 2 / (7 + 1);
  const lambdaChronic = 2 / (28 + 1);
  double acute = sorted[0].strain;
  double chronic = sorted[0].strain;
  for (var i = 1; i < sorted.length; i++) {
    acute = sorted[i].strain * lambdaAcute + acute * (1 - lambdaAcute);
    chronic = sorted[i].strain * lambdaChronic + chronic * (1 - lambdaChronic);
  }
  final double? acwr = chronic > 0 ? acute / chronic : null;

  String band = 'unknown';
  if (acwr != null) {
    if (acwr < 0.8) {
      band = 'detraining';
    } else if (acwr <= 1.3) {
      band = 'optimal';
    } else if (acwr <= 1.5) {
      band = 'caution';
    } else {
      band = 'high-risk';
    }
  }

  return LoadResult(
    acwr: acwr == null ? null : round(acwr, 3),
    acute: round(acute, 3),
    chronic: round(chronic, 3),
    band: band,
    confidence: round(math.min(1.0, days / 28), 4),
    tier: 'HIGH',
    inputs_used: const ['daily_strain'],
  );
}

class FitnessTrendResult {
  final String direction;
  final double rhr_slope;
  final double hrr_slope;
  final int days_used;
  final double confidence;
  final String tier;
  final List<String> inputs_used;
  const FitnessTrendResult({
    required this.direction,
    required this.rhr_slope,
    required this.hrr_slope,
    required this.days_used,
    required this.confidence,
    required this.tier,
    required this.inputs_used,
  });
  Map<String, dynamic> toJson() => {
        'direction': direction,
        'rhr_slope': rhr_slope,
        'hrr_slope': hrr_slope,
        'days_used': days_used,
        'confidence': confidence,
        'tier': tier,
        'inputs_used': inputs_used,
      };
}

FitnessTrendResult calcFitnessTrend(List<DayHistory> daily) {
  final rhrSeries = <double>[];
  final hrrSeries = <double>[];
  for (final d in daily) {
    if (d.resting_hr != null) rhrSeries.add(d.resting_hr!);
    if (d.hrr60 != null) hrrSeries.add(d.hrr60!);
  }

  final days = daily.length;
  if (days < 7 || rhrSeries.length < 3) {
    return FitnessTrendResult(
      direction: 'unknown',
      rhr_slope: 0,
      hrr_slope: 0,
      days_used: days,
      confidence: round(math.min(0.8, (days / 21) * 0.8), 4),
      tier: 'ESTIMATE',
      inputs_used: const ['resting_hr', 'hrr60'],
    );
  }

  final rhrRoll = _rollingMean(rhrSeries, 7);
  final hrrRoll = hrrSeries.length >= 3 ? _rollingMean(hrrSeries, 7) : <double>[];

  final rhrSlope = linregSlope(rhrRoll);
  final hrrSlope = hrrRoll.length >= 2 ? linregSlope(hrrRoll) : 0.0;

  String direction;
  if (rhrSlope < 0 && hrrSlope > 0) {
    direction = 'improving';
  } else if (rhrSlope > 0 && (hrrSlope < 0 || hrrRoll.length < 2)) {
    direction = 'declining';
  } else {
    direction = 'flat';
  }

  final confidence = math.min(0.8, (days / 21) * 0.8);

  return FitnessTrendResult(
    direction: direction,
    rhr_slope: round(rhrSlope, 5),
    hrr_slope: round(hrrSlope, 5),
    days_used: days,
    confidence: round(confidence, 4),
    tier: 'ESTIMATE',
    inputs_used: const ['resting_hr', 'hrr60'],
  );
}

List<double> _rollingMean(List<double> values, int w) {
  final out = <double>[];
  for (var i = 0; i < values.length; i++) {
    final start = math.max(0, i - w + 1);
    out.add(mean(values.sublist(start, i + 1)));
  }
  return out;
}
