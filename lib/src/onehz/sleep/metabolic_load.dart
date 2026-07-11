class MetabolicLoadResult {
  final bool hasLateMealSignature;
  final int lateDropMinute; // Minute into sleep where HR finally drops
  final double elevatedHrAverage;
  final double baselineHr;

  const MetabolicLoadResult({
    required this.hasLateMealSignature,
    required this.lateDropMinute,
    required this.elevatedHrAverage,
    required this.baselineHr,
  });
}

class MetabolicLoadAnalyzer {
  /// Analyzes the first 4 hours of sleep HR to detect a late meal or alcohol signature.
  /// A healthy sleep HR drops into a hammock shape within the first 60-90 minutes.
  /// A metabolic load HR stays flat and elevated, suddenly crashing late in the night.
  static MetabolicLoadResult analyze(List<double> sleepHr, {int sampleRateSec = 60}) {
    final empty = MetabolicLoadResult(
      hasLateMealSignature: false,
      lateDropMinute: 0,
      elevatedHrAverage: 0,
      baselineHr: 0,
    );

    if (sleepHr.isEmpty) return empty;

    // Require an integer number of samples per minute (and avoid divide-by-zero).
    if (sampleRateSec <= 0 || sampleRateSec > 60 || 60 % sampleRateSec != 0) {
      return empty;
    }

    final samplesPerMin = 60 ~/ sampleRateSec;
    if (sleepHr.length < 120 * samplesPerMin) return empty;

    final firstFourHoursSamples = 240 * samplesPerMin;
    final analysisLength =
        sleepHr.length < firstFourHoursSamples ? sleepHr.length : firstFourHoursSamples;

    double minHr = double.infinity;
    double maxHr = 0;
    
    for (int i = 0; i < analysisLength; i++) {
      if (sleepHr[i] <= 0) continue;
      if (sleepHr[i] < minHr) minHr = sleepHr[i];
      if (sleepHr[i] > maxHr) maxHr = sleepHr[i];
    }
    
    if (minHr == double.infinity) {
       return MetabolicLoadResult(
          hasLateMealSignature: false,
          lateDropMinute: 0,
          elevatedHrAverage: 0,
          baselineHr: 0);
    }

    // Find when the HR drops within 20% of the minimum
    final thresholdHr = minHr + ((maxHr - minHr) * 0.2);
    int dropIndex = -1;
    
    for (int i = 0; i < analysisLength; i++) {
      if (sleepHr[i] <= 0) continue;
      if (sleepHr[i] <= thresholdHr) {
        dropIndex = i;
        break;
      }
    }
    
    if (dropIndex == -1) dropIndex = analysisLength - 1;
    final dropMinute = dropIndex ~/ samplesPerMin;
    
    // If it takes more than 120 minutes (2 hours) to reach the baseline hammock,
    // and the delta between elevated and baseline is significant (> 10 bpm),
    // it's a metabolic load signature.
    bool hasSignature = dropMinute > 120 && (maxHr - minHr) > 10;
    
    double elevatedSum = 0;
    int count = 0;
    for (int i = 0; i < dropIndex; i++) {
      if (sleepHr[i] > 0) {
        elevatedSum += sleepHr[i];
        count++;
      }
    }
    double elevatedAvg = count > 0 ? elevatedSum / count : maxHr;

    return MetabolicLoadResult(
      hasLateMealSignature: hasSignature,
      lateDropMinute: dropMinute,
      elevatedHrAverage: elevatedAvg,
      baselineHr: minHr,
    );
  }
}
