// HUMAN — what each session type actually cost you the next morning (TS-11).
//
// "On the 14 mornings after a football session, your resting heart rate was a
// median 5 bpm above your baseline." A description of your own history, with
// its sample size printed next to it — never "football is costing you
// recovery", never a recommendation to skip anything.
//
// CONFOUNDING IS TOTAL AND THAT IS WHY THE REFUSALS EXIST. Hard sessions
// cluster with late nights, with alcohol, with stress, with travel. Nothing
// here can separate the session from the evening around it. So:
//   * a day with MORE THAN ONE session is dropped entirely — it belongs to no
//     single type and averaging it into both is how a gentle type inherits a
//     brutal one's mornings;
//   * a morning whose night had poor wear coverage is dropped — a resting HR
//     from two hours of contact is not a morning;
//   * a type under [minSessions] mornings is REFUSED, not shown with a small n;
//   * a median move smaller than the metric's MDC is reported as
//     indistinguishable from noise rather than as a finding.
//
// Nothing new is measured here. This reuses the daily series and the existing
// robust baseline; it is deliberately NOT built on journalNumericCorrelations,
// which is journal-field-shaped and does not group by session type.

import '../foundations/baseline.dart';
import '../types.dart';
import '../util.dart';

/// One session type's typical next-morning move on one metric.
class SessionMorningEffect {
  final String sessionType;

  /// Which daily metric moved — 'rhr', 'rmssd', whatever the caller passed.
  final String metric;

  /// Mornings that survived every refusal. Print it next to the claim.
  final int n;

  /// Median of (that morning's value − that morning's own baseline centre),
  /// in the metric's own units and SIGNED.
  final double medianDelta;

  /// The metric's minimal detectable change over the same baselines. A
  /// [medianDelta] inside this is not a finding.
  final double? mdc;

  bool get exceedsMdc => mdc != null && medianDelta.abs() >= mdc!;

  const SessionMorningEffect({
    required this.sessionType,
    required this.metric,
    required this.n,
    required this.medianDelta,
    required this.mdc,
  });

  Map<String, dynamic> toJson() => {
        'session_type': sessionType,
        'metric': metric,
        'n': n,
        'median_delta': round6(medianDelta),
        if (mdc != null) 'mdc': round6(mdc!),
        'exceeds_mdc': exceedsMdc,
      };
}

/// Minimum mornings after a session type before anything is said about it.
///
/// Ten is not a statistical guarantee, it is a floor under the most obvious
/// nonsense: a "median" over three mornings is one morning with two opinions.
const int sessionCostMinSessions = 10;

/// Next-morning effect of each session type, one row per type.
///
/// POSITIONAL ALIGNMENT, contiguous daily series, oldest first: [dates],
/// [values] and [coverage] are index-aligned, and index i+1 is the morning
/// AFTER index i. The caller passes the day series it already has; nothing here
/// parses a date, so a local day label never has to survive a timezone.
///
/// [sessionTypesByDate] maps a day label to every session that started that
/// day. A day with more than one entry is dropped, not split.
///
/// Returns ABSENT when no type clears the floor — that is the normal state for
/// months, and it is the honest one.
Metric<List<SessionMorningEffect>> sessionMorningEffects({
  required List<String> dates,
  required List<double?> values,
  required String metric,
  required Map<String, List<String>> sessionTypesByDate,
  List<double?>? coverage,
  int minSessions = sessionCostMinSessions,
  int baselineDays = 28,
  int minBaseline = 14,
  double minCoverage = 0.5,
}) {
  final inputs = [metric, 'sessions', if (coverage != null) 'coverage'];
  if (values.length != dates.length ||
      (coverage != null && coverage.length != dates.length)) {
    return Metric<List<SessionMorningEffect>>.absent(
      tier: Tier.estimate,
      inputs_used: inputs,
      note: 'dates/values/coverage must be index-aligned daily series',
    );
  }

  final deltasByType = <String, List<double>>{};
  final mdcsByType = <String, List<double>>{};

  for (var i = 0; i + 1 < dates.length; i++) {
    final types = sessionTypesByDate[dates[i]];
    if (types == null || types.length != 1) continue; // none, or ambiguous
    final morning = i + 1;
    final v = values[morning];
    if (v == null) continue;
    if (coverage != null) {
      final c = coverage[morning];
      if (c == null || c < minCoverage) continue;
    }
    // Baseline from the days BEFORE the morning, excluding the morning itself.
    // Including it would drag the baseline toward the very value under test.
    final from = morning - baselineDays < 0 ? 0 : morning - baselineDays;
    final window = [
      for (var k = from; k < morning; k++)
        if (values[k] != null) values[k]!
    ];
    if (window.length < minBaseline) continue;
    final base = robustBaseline(window, minValid: minBaseline);
    final centre = base.center;
    if (centre == null) continue;
    final m = mdc(base);
    deltasByType.putIfAbsent(types.single, () => []).add(v - centre);
    if (m != null) mdcsByType.putIfAbsent(types.single, () => []).add(m);
  }

  final out = <SessionMorningEffect>[];
  for (final e in deltasByType.entries) {
    if (e.value.length < minSessions) continue; // refuse, don't show a small n
    out.add(SessionMorningEffect(
      sessionType: e.key,
      metric: metric,
      n: e.value.length,
      medianDelta: median(e.value)!,
      mdc: median(mdcsByType[e.key] ?? const []),
    ));
  }
  out.sort((a, b) => a.sessionType.compareTo(b.sessionType));

  const note = 'Your own history, per session type, n printed with every row. '
      'ASSOCIATION ONLY — hard sessions cluster with late nights, alcohol, '
      'stress and travel, and none of that is separable here. Never a claim '
      'that a session type is costing you recovery, never a suggestion to '
      'skip one. Multi-session days and low-coverage nights are excluded.';

  if (out.isEmpty) {
    return Metric<List<SessionMorningEffect>>.absent(
      tier: Tier.estimate,
      inputs_used: inputs,
      note: 'need_sessions:need=$minSessions per type. $note',
    );
  }
  return Metric<List<SessionMorningEffect>>(
    value: out,
    confidence: 0.4,
    tier: Tier.estimate,
    inputs_used: inputs,
    note: note,
  );
}
