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
// (diagonal robust scale) + Spearman-style rank correlation off-diagonal, then
// regularized (ridge) so a near-singular small-sample covariance can't blow up
// the distance. Features are sign-ORIENTED so "bad" is always positive
// (HRV is negated: a DROP in HRV is the illness direction).
//
// HONESTY: this is a complement, not a diagnosis. Missing features reduce the
// vector dimension (we never impute). Persistence + a conservative chi-square
// gate keep the false-positive rate honest, and we report the per-feature
// contributions so a flag is explainable.

import 'dart:math' as math;
import '../types.dart';
import '../util.dart';

/// One night's standardized feature vector (sign-oriented: higher = "worse").
class AnomalyFeatures {
  final double? rhr; // RHR  (↑ worse)
  final double? hrv; // lnRMSSD or RMSSD (↓ worse -> we negate internally)
  final double? temp; // relative skin-temp (↑ worse)
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

  /// Machine-readable "need_baseline:have=H,need=N" note set on nights that
  /// could not be evaluated for lack of baseline coverage (H = best per-feature
  /// baseline count available, N = required minimum). Null when evaluated.
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
/// (default 9.21 ≈ χ²_{0.99,2}, conservative); [persistDays] consecutive
/// candidate nights required to flag; [ridge] covariance regularizer fraction.
///
/// [chiSqGate] OPTIONAL fixed Mahalanobis² threshold. When null (default) the
/// gate is DIMENSION-AWARE: a conservative χ²_{0.999, dof} upper quantile keyed
/// by the number of features actually present that night — so the false-alarm
/// rate stays honest as the vector dimension changes. (Robust MAD modestly
/// under-estimates SD on small samples, which inflates z; the conservative
/// 0.999 level absorbs that so normal nights don't trip the alarm.)
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
  var run = 0;
  for (var i = 0; i < n; i++) {
    // Orient: HRV negated so a drop is positive ("worse" direction).
    final cur = _orient(feats[i]);
    final lo = i - baselineDays < 0 ? 0 : i - baselineDays;
    // Build per-feature baseline columns (valid only) from the trailing window.
    final cols = List.generate(4, (_) => <double>[]);
    // Aligned rows (all 4 features present) for covariance off-diagonals.
    final rows = <List<double>>[];
    for (var j = lo; j < i; j++) {
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
    // Robust center (median) + scale (MAD) per available feature.
    final center = [for (final f in idx) median(cols[f])!];
    final scale = [
      for (final f in idx)
        () {
          final s = mad(cols[f]) ?? 0;
          return s <= 0 ? (stddev(cols[f]) ?? 1.0).clamp(1e-6, 1e9) : s;
        }()
    ];
    // Standardized current vector.
    final zc = [for (var a = 0; a < idx.length; a++) (cur[idx[a]]! - center[a]) / scale[a]];

    // Robust correlation matrix from aligned rows (standardized), regularized.
    final cov = _robustCorr(rows, idx, center, scale, ridge);
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
    for (var a = 0; a < idx.length; a++) {
      drivers.add(Driver(_featLabels[idx[a]], round6(zc[a]),
          detail: 'standardized deviation'));
    }
    drivers.sort((x, y) => y.contribution.abs().compareTo(x.contribution.abs()));

    final gate = chiSqGate ?? _chiSq999(idx.length);
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

/// Conservative χ² 0.999 upper-quantile by degrees of freedom (1..4 — the four
/// illness features). A single noisy night must clear this to even become a
/// candidate, so the persistence gate then needs TWO such nights to flag.
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
        final rc = clamp(r ?? 0.0, -0.95, 0.95);
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
