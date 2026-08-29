// WELLNESS — multivariate anomaly detector (Mahalanobis complement).
//
// Catalog illness signature: {RHR↑, HRV↓, temp↑, resp↑}. The PRIMARY illness
// detector is the per-signal CUSUM in clinical/illness_cusum.dart (low false
// alarm by design). This module is the MULTIVARIATE COMPLEMENT: a robust
// Mahalanobis distance of each night's feature vector to the personal baseline
// cloud, gated to require ≥[persistDays] consecutive flagged nights before it
// surfaces — so a single noisy night never cries wolf.
//
// Robustness: covariance is estimated from a trailing window via median/MAD
// (diagonal robust scale) + a Pearson correlation off-diagonal taken on the
// already-robustly-standardized columns (NOT a rank correlation — one outlier
// night in the window still moves it), then
// regularized (ridge) so a near-singular small-sample covariance can't blow up
// the distance. Features are sign-ORIENTED so "bad" is always positive
// (HRV is negated: a DROP in HRV is the illness direction).
//
// HONESTY: this is a complement, not a diagnosis. Missing features reduce the
// vector dimension (we never impute), and so does a feature whose baseline has
// no dispersion at all (MAD = 0 AND SD = 0) — there is no scale to standardize
// against, so it is DROPPED rather than floored to an epsilon. Persistence + a
// conservative chi-square
// gate keep the false-positive rate honest, and we report the per-feature
// contributions so a flag is explainable.

import 'dart:math' as math;
import '../types.dart';
import '../util.dart';

/// One night's standardized feature vector (sign-oriented: higher = "worse").
class AnomalyFeatures {
  final double? rhr; // RHR  (↑ worse)
  final double? hrv; // lnRMSSD or RMSSD (↓ worse -> we negate internally)
  /// RAW nightly-mean skin-temp in the device's own unit (`nightlySkinTemp`),
  /// ↑ worse. NOT a z — this detector standardises every column itself against
  /// the trailing window below, so a pre-standardised series is standardised
  /// twice and `minBaseline`/the χ² gate stop meaning what they say.
  final double? temp;
  final double? resp; // respiration rate (↑ worse)
  const AnomalyFeatures({this.rhr, this.hrv, this.temp, this.resp});
}

/// Required minimum valid baseline nights (per feature) before a distance is
/// computed for the multivariate anomaly detector.
const int multivariateAnomalyMinBaseline = 10;

class AnomalyDay {
  final String date;
  final double? mahalanobis; // robust Mahalanobis distance (null if no baseline)
  final bool flagged; // distance crossed gate AND persistence satisfied
  final bool candidate; // distance crossed gate THIS night (pre-persistence)
  final List<Driver> drivers; // per-feature signed contribution

  /// Machine-readable note set on nights that could not be evaluated:
  ///   * "need_baseline:have=H,need=N" — insufficient baseline coverage (H =
  ///     best per-feature baseline count available, N = required minimum).
  ///   * "degenerate_baseline:no_dispersion" — the surviving baseline columns
  ///     are exactly constant (MAD = 0 AND SD = 0), so there is no scale to
  ///     standardize against and we abstain rather than invent one.
  /// Null when the night WAS evaluated.
  final String? need;
  const AnomalyDay(this.date, this.mahalanobis, this.flagged, this.candidate,
      this.drivers, {this.need});
  Map<String, dynamic> toJson() => {
        'date': date,
        if (mahalanobis != null) 'mahalanobis': round6(mahalanobis!),
        'flagged': flagged,
        'candidate': candidate,
        'drivers': drivers.map((d) => d.toJson()).toList(),
        if (need != null) 'note': need,
      };
}

/// Feature labels in canonical order.
const _featLabels = ['RHR', 'HRV(↓)', 'temp', 'resp'];

/// Run the robust multivariate anomaly detector over a nightly feature series.
///
/// [dates] labels; [feats] per-night features (same length). [baselineDays]
/// trailing window for the covariance cloud; [minBaseline] min valid nights
/// before any distance is computed; [chiSqGate] threshold on Mahalanobis²
/// (see below — no fixed default); [persistDays] consecutive candidate nights
/// required to flag; [ridge] covariance regularizer fraction.
///
/// [chiSqGate] OPTIONAL fixed Mahalanobis² threshold. When null (default) the
/// gate is DIMENSION- AND SAMPLE-AWARE: χ²_{0.999, dof} for the number of
/// features present that night, widened by [_madInflation] for how few nights
/// the MAD scale was estimated from. The bare χ² quantile assumes a KNOWN
/// covariance; ours is a MAD over as few as [minBaseline] nights, and against
/// the bare gate the measured false-candidate rate is 0.197/night at n = 10 and
/// dof = 4 — 196× nominal. See [_madInflationTable].
List<AnomalyDay> multivariateAnomaly(
  List<String> dates,
  List<AnomalyFeatures> feats, {
  int baselineDays = 28,
  int minBaseline = multivariateAnomalyMinBaseline,
  double? chiSqGate,
  int persistDays = 2,
  double ridge = 0.1,
}) {
  final n = feats.length;
  final out = <AnomalyDay>[];
  // CALENDAR days, not rows — see [calendarDays].
  final day = calendarDays(dates);
  var run = 0;
  var lastScoredDay = -1 << 20;
  for (var i = 0; i < n; i++) {
    // Orient: HRV negated so a drop is positive ("worse" direction).
    final cur = _orient(feats[i]);
    // Build per-feature baseline columns (valid only) from the trailing window.
    final cols = List.generate(4, (_) => <double>[]);
    // Aligned rows (all 4 features present) for covariance off-diagonals.
    final rows = <List<double>>[];
    for (var j = i - 1; j >= 0; j--) {
      if (day[i] - day[j] > baselineDays) break;
      final o = _orient(feats[j]);
      for (var f = 0; f < 4; f++) {
        if (o[f] != null) cols[f].add(o[f]!);
      }
      if (o.every((v) => v != null)) {
        rows.add([for (final v in o) v!]);
      }
    }
    // Which features are available BOTH tonight and with enough baseline?
    final idx = <int>[];
    for (var f = 0; f < 4; f++) {
      if (cur[f] != null && cols[f].length >= minBaseline) idx.add(f);
    }
    if (idx.length < 2) {
      // Not enough baseline coverage to compute a distance. If tonight HAS
      // features, attach a machine-readable need_baseline note (have = the best
      // per-feature baseline count among tonight's present features).
      String? need;
      var bestHave = -1;
      for (var f = 0; f < 4; f++) {
        if (cur[f] != null && cols[f].length > bestHave) bestHave = cols[f].length;
      }
      if (bestHave >= 0) {
        need = needBaselineNote(have: bestHave, need: minBaseline);
      }
      out.add(AnomalyDay(dates[i], null, false, false, const [], need: need));
      run = 0;
      continue;
    }
    // Robust center (median) + scale (MAD, ordinary SD as the coarser fallback)
    // per available feature.
    //
    // ABSTAIN, NEVER FLOOR: a feature whose trailing baseline has NO dispersion
    // at all (MAD == 0 AND SD == 0 — an exactly-constant, fully-quantized column
    // such as a skin-temp z that reads 0.0 every night) has no scale to
    // standardize against. Clamping the scale to an epsilon (the old `.clamp(
    // 1e-6, 1e9)`) turned any deviation into a ~1e6 z, so d² blew past the χ²
    // gate unconditionally and a 0.4-unit change surfaced as an illness anomaly.
    // The sibling modules already refuse this case — readiness_composite's
    // `robustZ(v, base) ?? z(v, base)` yields null when SD is also 0, and
    // changepoint guards zero variance — so we match them: DROP the degenerate
    // feature from the vector, and if fewer than 2 features survive, abstain.
    final keep = <int>[];
    final center = <double>[];
    final scale = <double>[];
    for (final f in idx) {
      final m = mad(cols[f]) ?? 0;
      final sc = m > 0 ? m : (stddev(cols[f]) ?? 0);
      if (!sc.isFinite || sc <= 0) continue; // no dispersion → not standardizable
      keep.add(f);
      center.add(median(cols[f])!);
      scale.add(sc);
    }
    if (keep.length < 2) {
      out.add(AnomalyDay(dates[i], null, false, false, const [],
          need: 'degenerate_baseline:no_dispersion'));
      run = 0;
      continue;
    }
    // Standardized current vector.
    final zc = [for (var a = 0; a < keep.length; a++) (cur[keep[a]]! - center[a]) / scale[a]];

    // Robust correlation matrix from aligned rows (standardized), regularized.
    final cov = _robustCorr(rows, keep, center, scale, ridge);
    final inv = _invert(cov);
    double d2;
    if (inv == null) {
      // Fall back to identity (uncorrelated) — sum of squared z.
      d2 = zc.fold(0.0, (s, v) => s + v * v);
    } else {
      d2 = 0.0;
      for (var a = 0; a < zc.length; a++) {
        for (var b = 0; b < zc.length; b++) {
          d2 += zc[a] * inv[a][b] * zc[b];
        }
      }
    }
    if (d2 < 0) d2 = 0; // numerical guard
    final dist = math.sqrt(d2);

    // Per-feature contribution to d² (diagonal share), for the "why".
    final drivers = <Driver>[];
    for (var a = 0; a < keep.length; a++) {
      drivers.add(Driver(_featLabels[keep[a]], roundTo(zc[a], 6),
          detail: 'standardized deviation'));
    }
    drivers.sort((x, y) => y.contribution.abs().compareTo(x.contribution.abs()));

    // "N nights running" means CONSECUTIVE NIGHTS, not consecutive rows.
    if (day[i] - lastScoredDay > 1) run = 0;
    lastScoredDay = day[i];

    // Smallest surviving per-feature baseline drives the gate: the noisiest
    // scale estimate in the vector is the one inflating d².
    var baseN = 1 << 30;
    for (final f in keep) {
      if (cols[f].length < baseN) baseN = cols[f].length;
    }
    final gate = chiSqGate ?? _chiSq999(keep.length) * _madInflation(baseN);
    final candidate = d2 > gate;
    if (candidate) {
      run++;
    } else {
      run = 0;
    }
    final flagged = candidate && run >= persistDays;
    out.add(AnomalyDay(dates[i], dist, flagged, candidate, drivers));
  }
  return out;
}

/// How much the χ² gate must be widened because the scale is ESTIMATED, not
/// known.
///
/// χ²(0.999) is the quantile of a Mahalanobis distance taken against a KNOWN
/// covariance. Ours is a median + MAD over `minBaseline` nights, and a MAD on
/// ten values is so noisy that d² lives in a far heavier-tailed distribution
/// than χ². Measured (200 k trials/cell, iid N(0,1) features, replicating this
/// function exactly — `_robustCorr`'s Pearson-on-standardised-columns, the 0.1
/// ridge, the stddev fallback), the false-candidate rate against the bare χ²
/// gate was:
///
///   baseline n | dof 2  | dof 3  | dof 4
///   -----------|--------|--------|-------
///           10 | 0.0796 | 0.1298 | 0.1973   ← 196× nominal at dof 4
///           14 | 0.0451 | 0.0709 | 0.1048
///           20 | 0.0244 | 0.0376 | 0.0532
///           28 | 0.0144 | 0.0202 | 0.0272
///           60 | 0.0050 | 0.0059 | 0.0075
///
/// That is user-facing: a flagged night drives a quiet-hours-overriding
/// "Unusual overnight physiology" notification, and the exposure is concentrated
/// in a new user's first month while the per-feature baseline grows from 10 to
/// `baselineDays`.
///
/// The factor below is the empirical 99.9 %ile of d² divided by χ²(0.999) at
/// that dof, taken as the MAX over dof 2..4 at each n (conservative by
/// construction — a shared curve must not under-widen the widest case).
/// Interpolated log-linearly in n; below the first anchor it holds, above the
/// last it decays to 1.0 as MAD → σ. `test/onehz/wellness_test.dart` pins the
/// anchors.
const List<(int, double)> _madInflationTable = [
  (10, 13.23),
  (14, 5.65),
  (20, 3.17),
  (28, 2.24),
  (45, 1.65),
  (90, 1.25),
  (200, 1.0),
];

double _madInflation(int n) {
  if (n <= _madInflationTable.first.$1) return _madInflationTable.first.$2;
  if (n >= _madInflationTable.last.$1) return 1.0;
  for (var i = 1; i < _madInflationTable.length; i++) {
    final (n1, f1) = _madInflationTable[i];
    if (n > n1) continue;
    final (n0, f0) = _madInflationTable[i - 1];
    final t = (math.log(n) - math.log(n0)) / (math.log(n1) - math.log(n0));
    return math.exp(math.log(f0) + t * (math.log(f1) - math.log(f0)));
  }
  return 1.0;
}

/// Conservative χ² 0.999 upper-quantile by degrees of freedom (1..4 — the four
/// illness features). A single noisy night must clear this to even become a
/// candidate, so the persistence gate then needs TWO such nights to flag.
/// Widened by [_madInflation] for the small-sample scale estimate.
double _chiSq999(int dof) {
  switch (dof) {
    case 1:
      return 10.83;
    case 2:
      return 13.82;
    case 3:
      return 16.27;
    default:
      return 18.47; // dof 4
  }
}

List<double?> _orient(AnomalyFeatures f) => [
      f.rhr,
      f.hrv == null ? null : -f.hrv!, // HRV drop = illness direction
      f.temp,
      f.resp,
    ];

/// Robust correlation matrix over the available feature indices, built from
/// standardized aligned rows, then ridge-regularized toward the identity.
List<List<double>> _robustCorr(
  List<List<double>> rows,
  List<int> idx,
  List<double> center,
  List<double> scale,
  double ridge,
) {
  final k = idx.length;
  // Initialize to identity (correlation of a feature with itself = 1).
  final m = List.generate(k, (i) => List<double>.filled(k, 0.0));
  for (var i = 0; i < k; i++) {
    m[i][i] = 1.0;
  }
  if (rows.length >= 4) {
    // Standardize each aligned row's available features (using same center/scale).
    final std = <List<double>>[];
    for (final r in rows) {
      std.add([for (var a = 0; a < k; a++) (r[idx[a]] - center[a]) / scale[a]]);
    }
    for (var a = 0; a < k; a++) {
      for (var b = a + 1; b < k; b++) {
        // Pearson on the (already-robustly-standardized) columns; clamp.
        final xa = [for (final s in std) s[a]];
        final xb = [for (final s in std) s[b]];
        final r = _corr(xa, xb);
        final rc = (r ?? 0.0).clamp(-0.95, 0.95);
        m[a][b] = rc;
        m[b][a] = rc;
      }
    }
  }
  // Ridge toward identity: (1-ridge)·R + ridge·I keeps it invertible.
  for (var a = 0; a < k; a++) {
    for (var b = 0; b < k; b++) {
      m[a][b] = (1 - ridge) * m[a][b] + (a == b ? ridge : 0.0);
    }
  }
  return m;
}

double? _corr(List<double> a, List<double> b) {
  final n = a.length;
  if (n < 2) return null;
  final ma = mean(a)!, mb = mean(b)!;
  var sab = 0.0, saa = 0.0, sbb = 0.0;
  for (var i = 0; i < n; i++) {
    final da = a[i] - ma, db = b[i] - mb;
    sab += da * db;
    saa += da * da;
    sbb += db * db;
  }
  if (saa <= 0 || sbb <= 0) return null;
  return sab / math.sqrt(saa * sbb);
}

/// Invert a small symmetric matrix via Gauss-Jordan. Null if singular.
List<List<double>>? _invert(List<List<double>> a) {
  final n = a.length;
  final m = List.generate(n, (i) => List<double>.filled(2 * n, 0.0));
  for (var i = 0; i < n; i++) {
    for (var j = 0; j < n; j++) {
      m[i][j] = a[i][j];
    }
    m[i][n + i] = 1.0;
  }
  for (var col = 0; col < n; col++) {
    var piv = col;
    for (var r = col + 1; r < n; r++) {
      if (m[r][col].abs() > m[piv][col].abs()) piv = r;
    }
    if (m[piv][col].abs() < 1e-12) return null;
    final tmp = m[col];
    m[col] = m[piv];
    m[piv] = tmp;
    final d = m[col][col];
    for (var j = 0; j < 2 * n; j++) {
      m[col][j] /= d;
    }
    for (var r = 0; r < n; r++) {
      if (r == col) continue;
      final f = m[r][col];
      for (var j = 0; j < 2 * n; j++) {
        m[r][j] -= f * m[col][j];
      }
    }
  }
  return [for (var i = 0; i < n; i++) m[i].sublist(n)];
}
