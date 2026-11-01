import 'dart:math' as math;

import '../../aggregate/aggregator.dart';
import '../../aggregate/json_support.dart';
import '../../aggregate/primitives.dart';
import '../types.dart';
import 'load_trimp.dart';

const _trimpInputs = ['hr_per_min', 'resting_hr', 'max_hr'];
const _trimpNote =
    'Banister TRIMP needs finite measured RHR and HRmax (HRmax>RHR)';

// Morton, R. H., Fitz-Clarke, J. R., Banister, E. W. (1990). Modeling human
// performance in running. Journal of Applied Physiology 69(3):1171-1177.
// Supports HR-reserve exponential TRIMP weighting and the impulse-response
// model; the sex-specific coefficients are retained from Banister 1991.
// banisterTrimp() runs this per-minute HR-
// reserve sum in one slice. Merge order changes rounding; checked relative
// tolerance is 1e-12. Retains ESTIMATE tier and confidence 0.6.
/// Builds a mergeable Banister TRIMP summary over per-minute mean HR values.
///
/// The resulting metric has the same missing-input and empty-input behaviour as
/// [banisterTrimp].
Aggregator<dynamic, DoubleColumn, Metric<double>> banisterTrimpAggregator({
  required double? restingHr,
  required double? maxHr,
  required Sex sex,
}) {
  // `maxHr <= restingHr` is FALSE when either is NaN, so the finiteness checks
  // are load-bearing: a NaN anchor otherwise makes a NaN reserve, and every
  // clamp below (`hrr < 0`, `hrr > 1`) is false for NaN too, so the sum comes
  // out NaN inside a PRESENT metric.
  final anchorsValid = restingHr != null &&
      maxHr != null &&
      restingHr.isFinite &&
      maxHr.isFinite &&
      maxHr > restingHr;
  final reserve = anchorsValid ? maxHr - restingHr : 0.0;
  final core = both(
    Count<DoubleColumn>(),
    SumOf<DoubleColumn>((batch) => batch.values, (hr) {
      if (!anchorsValid || !hr.isFinite || hr <= 0) return double.nan;
      // ONE Banister implementation for the whole package: the sex-specific
      // weighting factor y lives in [StrainScorer.banisterY]. 1 minute each.
      var hrr = (hr - restingHr) / reserve;
      if (hrr < 0) hrr = 0.0;
      if (hrr > 1) hrr = 1.0;
      return hrr * StrainScorer.banisterY(hrr, female: sex == Sex.female);
    }),
  );
  return core.map((result) {
    if (!anchorsValid || result.$1 == 0) {
      return const Metric<double>.absent(
        tier: Tier.estimate,
        inputs_used: _trimpInputs,
        note: _trimpNote,
      );
    }
    return Metric<double>(
      value: result.$2,
      confidence: 0.6,
      tier: Tier.estimate,
      inputs_used: _trimpInputs,
      note: 'Banister exponential TRIMP (wrist HR estimate)',
    );
  });
}

// Banister, E. W., Calvert, T. W., Savage, M. V., Bach, T. (1975). A systems
// model of training for athletic performance. Australian Journal of Sports
// Medicine 7:57-61. See also Morton, Fitz-Clarke & Banister 1990 above.
// CTL/ATL are a discrete EWMA fitness/fatigue adaptation, TSB = CTL - ATL;
// 42/7-day defaults and bounded-prefix priming are implementation choices.
// With a=1-lambda, f_y(f_x(c))=a*a*c+a*lambda*x+lambda*y, algebraically
// equal to two EWMA recurrence steps.
// Banister impulse-response model, now also the ctlAtlTsb() one-slice path. The
// identical bounded-prefix prime seeds affine compositions of the same EWMA
// recurrence. Composition is algebraically equal; checked absolute and relative
// tolerances are 1e-9.
/// Builds a mergeable CTL/ATL/TSB summary over a daily-TRIMP column (oldest
/// first), matching [ctlAtlTsb].
///
/// Both accumulators are primed with the mean of the first [primeDays] rows
/// (a bounded prefix), then each later row is one EWMA step, kept as an affine
/// map so chunks merge. With fewer rows than [primeDays] the prime is the row
/// count, as in the reference.
Aggregator<dynamic, DoubleColumn, Metric<LoadState>> ctlAtlTsbAggregator({
  double ctlDays = 42,
  double atlDays = 7,
  int minDays = ctlAtlMinDays,
  int primeDays = 7,
}) {
  const inputs = ['daily_trimp'];
  final lc = 1 - math.exp(-1 / ctlDays);
  final la = 1 - math.exp(-1 / atlDays);
  final core = both(
    const Count<DoubleColumn>(),
    Prefix(
      math.max(primeDays, 1),
      both(
        const Count<DoubleColumn>(),
        Sum<DoubleColumn>((batch) => batch.values),
      ),
      both(
        Ewma<DoubleColumn>((batch) => batch.values, lc),
        Ewma<DoubleColumn>((batch) => batch.values, la),
      ),
      batchFromJson: DoubleColumn.fromJson,
    ),
  );
  final prime = math.max(primeDays, 1);
  return validateCheckpoint(core, (json) {
    final state = decodeList(json);
    if (state.length != 2) throw const FormatException('Expected two states');
    final days = decodeCount(state[0]);
    final rows = field(decodeMap(state[1]), 'rows');
    if (days == 0) {
      if (rows != null) throw const FormatException('Prefix rows without days');
      return;
    }
    if (rows == null || decodeList(rows).length != (days < prime ? days : prime)) {
      throw const FormatException('Prefix rows disagree with days');
    }
  }).map((result) {
    final days = result.$1;
    if (days < minDays) {
      return Metric<LoadState>.absent(
        tier: Tier.estimate,
        inputs_used: inputs,
        note: needBaselineNote(have: days, need: minDays),
      );
    }
    final ((primed, primeSum), (ctlMap, atlMap)) = result.$2;
    final seed = primeSum / primed;
    final ctl = ctlMap.apply(seed);
    final atl = atlMap.apply(seed);
    return Metric<LoadState>(
      value: LoadState(ctl, atl, ctl - atl),
      confidence: (days / 42.0).clamp(0.3, 0.85),
      tier: Tier.estimate,
      inputs_used: inputs,
      note: 'Banister CTL(42d)/ATL(7d)/TSB, primed from the first $primed '
          'observed days; descriptive load, not injury risk',
    );
  });
}
