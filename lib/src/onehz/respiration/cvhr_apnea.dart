// RESPIRATION TIER-1 — CVHR / ACAT apnea SCREEN (Hayano 2011).
//
// Cyclic Variation of Heart Rate is the cardiac signature of sleep-disordered
// breathing: each apnea/hypopnea episode produces a bradycardia during the
// event followed by a tachycardia at the arousal/resumption of breathing,
// recurring with a ~20–120 s period. Hayano's Autonomic Cardiac Activity
// (ACAT) / ACT algorithm scores these cycles RR-only (r≈0.84 vs AHI), needs
// zero calibration, and runs all night on our continuous beat-to-beat RR — our
// structural edge.
//
// Method (ACAT-style, deterministic):
//   1. Build a 1 Hz HR-equivalent envelope from cleaned NN (instantaneous HR
//      = 60000/NN), smoothed with a 2nd-order (quadratic) Savitzky-Golay-like
//      local polynomial to suppress beat jitter while preserving cycle shape.
//   2. An adaptive baseline — the sliding MEDIAN over a ~130 s window, which
//      spans ≥2 apnea cycles so it tracks the eupneic level without being
//      pulled into any single event. The bradycardia is an NN MAXIMUM (NN ↑ ⇔
//      HR ↓), so the scored quantity is the POSITIVE excursion above that
//      baseline; negative excursions (the recovery tachycardia) are clipped.
//      A run clears the baseline when it exceeds max(0.5 × the 75th percentile
//      of the positive excursions, 5 ms) — the only percentile in this file.
//   3. Keep a run as a CVHR cycle only if its width is 10–120 s AND its
//      depth-to-width ratio > 0.7 ms/s (the steep bradycardia-then-tachycardia
//      signature, not slow drift).
//   4. CVHR cycles per hour => an apnea SCREEN index (NOT an AHI, NOT a
//      diagnosis). Report night-to-night variability caveat.
//
// HONESTY: this is a SCREEN. We never output an AHI or a clinical category, and
// we flag that single-night CVHR has substantial night-to-night variability.
// The denominator is OBSERVED time: the night is split at recording gaps, each
// contiguous stretch is analysed on its own, and the hole contributes neither
// interpolated beats nor hours. Dividing by the first-to-last span instead let
// a 2 h charging break cut the index from 80.0/h to 53.3/h on identical beats.

import 'dart:math' as math;
import '../types.dart';
import '../util.dart';
import '../../aggregate/json_support.dart';

class CvhrResult {
  final int cycleCount; // detected CVHR cycles
  final double cvhrPerHour; // cycles / hour (the screen index)
  final double analyzedHours; // OBSERVED hours analysed (gaps excluded)

  /// Mean dip depth (ms of NN excursion) — NULL when no cycle was detected.
  /// It used to be 0 in that case, which serialised an absence as a
  /// measurement. `cycleCount == 0` and these being null are the same fact.
  final double? meanDepthMs;

  /// Mean dip width (s) — NULL when no cycle was detected. See [meanDepthMs].
  final double? meanWidthSec;

  /// [p25, p50, p75] of the per-cycle dip depths (ms). NULL when no cycle was
  /// detected. The mean alone hides the shape: a night of a few deep dips and a
  /// night of many shallow ones can share it. These are the raw quartiles of
  /// the same per-cycle list the means come from — no adjective attached, no
  /// threshold, and specifically no category.
  final List<double>? depthQuartilesMs;

  /// [p25, p50, p75] of the per-cycle widths (s) — the cycle LENGTH spread.
  /// See [depthQuartilesMs].
  final List<double>? widthQuartilesSec;
  const CvhrResult({
    required this.cycleCount,
    required this.cvhrPerHour,
    required this.analyzedHours,
    required this.meanDepthMs,
    required this.meanWidthSec,
    this.depthQuartilesMs,
    this.widthQuartilesSec,
  });
  Map<String, dynamic> toJson() => {
        'cycle_count': cycleCount,
        'cvhr_per_hour': round6(cvhrPerHour),
        'analyzed_hours': round6(analyzedHours),
        'mean_depth_ms': meanDepthMs == null ? null : round6(meanDepthMs!),
        'mean_width_sec': meanWidthSec == null ? null : round6(meanWidthSec!),
        'depth_quartiles_ms':
            depthQuartilesMs?.map(round6).toList(growable: false),
        'width_quartiles_sec':
            widthQuartilesSec?.map(round6).toList(growable: false),
      };
}

/// [p25, p50, p75] of [xs], or null when empty. Same linear-interpolated
/// percentile the rest of the package uses.
List<double>? _quartiles(List<double> xs) => xs.isEmpty
    ? null
    : [percentile(xs, 25)!, percentile(xs, 50)!, percentile(xs, 75)!];

/// CVHR / ACAT apnea screen on a cleaned NN series.
///
/// [nnMs] cleaned NN intervals (ms), [nnTimesMs] their cumulative beat times
/// (ms). [artifactFraction] from RR-correction. Tunables follow Hayano:
/// dip width 10–120 s, depth/width ratio > 0.7 ms/s, ~130 s baseline window.
///
/// Callers pass one unsegmented block (the whole sleep window), so a charging
/// or off-wrist stretch arrives here inline. Beats more than [maxGapSec] apart
/// start a NEW segment: each is resampled and scored on its own, and only the
/// segments' own spans enter [CvhrResult.analyzedHours]. The gap is not
/// interpolated across and is not charged to the denominator.
Metric<CvhrResult> cvhrApneaScreen(
  List<double> nnMs,
  List<double> nnTimesMs, {
  required double artifactFraction,
  double minWidthSec = 10,
  double maxWidthSec = 120,
  double depthWidthRatioMin = 0.7, // ms per second
  double envWindowSec = 130,
  double maxArtifact = 0.30,
  double maxGapSec = 30,
}) {
  const inputs = ['rr_cleaned', 'beat_times'];
  if (nnMs.length < 60 || nnTimesMs.length != nnMs.length) {
    return const Metric<CvhrResult>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'too few beats for a CVHR screen (need ≥60)',
    );
  }
  if (artifactFraction > maxArtifact) {
    return Metric<CvhrResult>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'artifact fraction ${round6(artifactFraction)} > gate '
          '— CVHR dip detection unreliable',
    );
  }

  final tSec = [for (final t in nnTimesMs) t / 1000.0];
  // A non-finite beat time has no place on the 1 Hz grid: NaN slipped past
  // every gap test and then failed the resample, and an infinite one would be
  // a stretch of its own. Same answer as rsaRespRate / hrvFreq.
  if (tSec.any((t) => !t.isFinite)) {
    return const Metric<CvhrResult>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'non-finite beat time',
    );
  }
  if (tSec.last - tSec.first <= 0) {
    return const Metric<CvhrResult>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'degenerate beat times',
    );
  }

  return _cvhrMetric(_segmentContributions(tSec, nnMs,
      minWidthSec: minWidthSec,
      maxWidthSec: maxWidthSec,
      depthWidthRatioMin: depthWidthRatioMin,
      envWindowSec: envWindowSec,
      maxGapSec: maxGapSec), artifactFraction);
}

class _CvhrContribution {
  final double hours;
  final List<double> depths, widths;
  const _CvhrContribution(this.hours, this.depths, this.widths);

  Map<String, dynamic> toJson() => {
        'hours': encodeDouble(hours),
        'depths': [for (final x in depths) encodeDouble(x)],
        'widths': [for (final x in widths) encodeDouble(x)],
      };
}

List<_CvhrContribution> _segmentContributions(List<double> t, List<double> nn,
    {required double minWidthSec,
    required double maxWidthSec,
    required double depthWidthRatioMin,
    required double envWindowSec,
    required double maxGapSec}) {
  final out = <_CvhrContribution>[];
  var lo = 0;
  for (var hi = 1; hi <= t.length; hi++) {
    if (hi != t.length && t[hi] - t[hi - 1] <= maxGapSec) continue;
    final segT = t.sublist(lo, hi);
    final spanSec = segT.last - segT.first;
    if (segT.length >= 60 && spanSec >= 60) {
      final depths = <double>[];
      final widths = <double>[];
      _scoreSegment(segT, nn.sublist(lo, hi),
          minWidthSec: minWidthSec,
          maxWidthSec: maxWidthSec,
          depthWidthRatioMin: depthWidthRatioMin,
          envWindowSec: envWindowSec,
          onCycle: (depth, width) {
        depths.add(depth);
        widths.add(width);
      });
      out.add(_CvhrContribution(spanSec / 3600.0, depths, widths));
    }
    lo = hi;
  }
  return out;
}

Metric<CvhrResult> _cvhrMetric(
    List<_CvhrContribution> contributions, double artifactFraction) {
  const inputs = ['rr_cleaned', 'beat_times'];
  var analyzedHours = 0.0;
  final depths = <double>[];
  final widths = <double>[];
  for (final c in contributions) {
    analyzedHours += c.hours;
    depths.addAll(c.depths);
    widths.addAll(c.widths);
  }
  if (analyzedHours <= 0) {
    return const Metric<CvhrResult>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'no gap-free stretch long enough for a CVHR screen (<60 s)',
    );
  }
  final cycleCount = depths.length;
  final perHour = cycleCount / analyzedHours;
  final conf = ((1 - artifactFraction) * 0.85).clamp(0.2, 0.85);
  return Metric<CvhrResult>(
    value: CvhrResult(
      cycleCount: cycleCount,
      cvhrPerHour: perHour,
      analyzedHours: analyzedHours,
      meanDepthMs: depths.isEmpty ? null : mean(depths),
      meanWidthSec: widths.isEmpty ? null : mean(widths),
      depthQuartilesMs: _quartiles(depths),
      widthQuartilesSec: _quartiles(widths),
    ),
    confidence: conf,
    tier: Tier.high,
    inputs_used: inputs,
    note: 'CVHR/ACAT (Hayano) apnea SCREEN — NOT a diagnosis, NOT an AHI; '
        'single-night CVHR has substantial night-to-night variability, '
        'interpret as a trend over multiple nights',
  );
}

/// Exact, append-only state for [cvhrApneaScreen]. Closed gap-free stretches
/// are reduced to their scored contributions; only the current stretch's beats
/// are retained for the provisional end-window calculation.
// Hayano 2011 CVHR screening, as in cvhrApneaScreen(). Closed gap-free stretches
// retain scored contributions; the current stretch is rescored provisionally
// with shared batch stages.
class CvhrStream {
  final double minWidthSec, maxWidthSec, depthWidthRatioMin, envWindowSec,
      maxGapSec;
  final List<_CvhrContribution> _closed = [];
  final List<double> _rawNn = [], _rawTimes = [];
  final List<double> _grid = [], _smooth = [], _base = [], _exc = [];
  int _n = 0;
  int _openCount = 0;
  double? _first, _last, _openStart;

  CvhrStream({
    this.minWidthSec = 10,
    this.maxWidthSec = 120,
    this.depthWidthRatioMin = 0.7,
    this.envWindowSec = 130,
    this.maxGapSec = 30,
  });

  factory CvhrStream.fromJson(Map<String, dynamic> json) {
    try {
      final j = decodeMap(json);
      if (field(j, 'type') != 'CvhrStream') {
        throw const FormatException('not a CvhrStream checkpoint');
      }
      if (field(j, 'version') != 1) {
        throw const FormatException('unsupported CvhrStream version');
      }
      final minWidthSec = decodeDouble(field(j, 'minWidthSec'));
      final maxWidthSec = decodeDouble(field(j, 'maxWidthSec'));
      final depthWidthRatioMin = decodeDouble(field(j, 'depthWidthRatioMin'));
      final envWindowSec = decodeDouble(field(j, 'envWindowSec'));
      final maxGapSec = decodeDouble(field(j, 'maxGapSec'));
      final n = decodeCount(field(j, 'n'));
      final first = decodeDoubleOrNull(field(j, 'first'));
      final last = decodeDoubleOrNull(field(j, 'last'));
      final openStart = decodeDoubleOrNull(field(j, 'openStart'));
      final openCount = decodeCount(field(j, 'openCount'));
      final rawNn = decodeDoubles(field(j, 'rawNn'));
      final rawTimes = decodeDoubles(field(j, 'rawTimes'));
      final grid = decodeDoubles(field(j, 'grid'));
      final smooth = decodeDoubles(field(j, 'smooth'));
      final base = decodeDoubles(field(j, 'base'));
      final exc = decodeDoubles(field(j, 'exc'));
      final encodedClosed = decodeList(field(j, 'closed'));
      if (!minWidthSec.isFinite || !maxWidthSec.isFinite ||
          !depthWidthRatioMin.isFinite || !envWindowSec.isFinite ||
          !maxGapSec.isFinite || rawNn.length != rawTimes.length ||
          smooth.length > grid.length || base.length > smooth.length ||
          exc.length != base.length || n < openCount ||
          (n == 0 && (first != null || last != null || openStart != null ||
              openCount != 0 || rawNn.isNotEmpty || grid.isNotEmpty)) ||
          (n > 0 && (first == null || last == null || openStart == null ||
              openCount == 0 || rawNn.isEmpty))) {
        throw const FormatException('inconsistent CvhrStream checkpoint');
      }
      final s = CvhrStream(
        minWidthSec: minWidthSec,
        maxWidthSec: maxWidthSec,
        depthWidthRatioMin: depthWidthRatioMin,
        envWindowSec: envWindowSec,
        maxGapSec: maxGapSec,
      )
        .._n = n
        .._first = first
        .._last = last
        .._openStart = openStart
        .._openCount = openCount
        .._rawNn.addAll(rawNn)
        .._rawTimes.addAll(rawTimes)
        .._grid.addAll(grid)
        .._smooth.addAll(smooth)
        .._base.addAll(base)
        .._exc.addAll(exc);
      if (n > 0 &&
          (s._rawTimes.isEmpty || !_cvhrNondecreasing(s._rawTimes))) {
        throw const FormatException('decreasing checkpoint times');
      }
      for (final value in encodedClosed) {
        final c = decodeMap(value);
        final hours = decodeDouble(field(c, 'hours'));
        final depths = decodeDoubles(field(c, 'depths'));
        final widths = decodeDoubles(field(c, 'widths'));
        if (!hours.isFinite || hours < 0 || depths.length != widths.length) {
          throw const FormatException('invalid CVHR segment');
        }
        s._closed.add(_CvhrContribution(hours, depths.toList(), widths.toList()));
      }
      return s;
    } on FormatException {
      rethrow;
    } catch (e) {
      throw FormatException('malformed CvhrStream checkpoint: $e');
    }
  }

  Map<String, dynamic> toJson() => {
        'type': 'CvhrStream',
        'version': 1,
        'minWidthSec': encodeDouble(minWidthSec),
        'maxWidthSec': encodeDouble(maxWidthSec),
        'depthWidthRatioMin': encodeDouble(depthWidthRatioMin),
        'envWindowSec': encodeDouble(envWindowSec),
        'maxGapSec': encodeDouble(maxGapSec),
        'n': _n,
        'first': _first == null ? null : encodeDouble(_first!),
        'last': _last == null ? null : encodeDouble(_last!),
        'openStart': _openStart == null ? null : encodeDouble(_openStart!),
        'openCount': _openCount,
        'rawNn': [for (final x in _rawNn) encodeDouble(x)],
        'rawTimes': [for (final x in _rawTimes) encodeDouble(x)],
        'grid': [for (final x in _grid) encodeDouble(x)],
        'smooth': [for (final x in _smooth) encodeDouble(x)],
        'base': [for (final x in _base) encodeDouble(x)],
        'exc': [for (final x in _exc) encodeDouble(x)],
        'closed': [for (final x in _closed) x.toJson()],
      };

  void fold(List<double> nnMs, List<double> nnTimesMs) {
    if (nnMs.length != nnTimesMs.length) {
      throw ArgumentError('nnMs and nnTimesMs must have the same length');
    }
    if (nnMs.isEmpty) return;
    final times = [for (final t in nnTimesMs) t / 1000.0];
    // Checked before any state changes (a fold cannot be undone): the batch
    // abstains on such a time, so no snapshot after it could be the batch's.
    if (times.any((t) => !t.isFinite)) {
      throw ArgumentError('beat times must be finite');
    }
    if (!_cvhrNondecreasing(times) ||
        (_last != null && times.first < _last!)) {
      throw StateError('beat times must be non-decreasing');
    }
    _first ??= times.first;
    for (var i = 0; i < times.length; i++) {
      if (_openCount > 0 && times[i] - _last! > maxGapSec) {
        _closeOpen();
      }
      _openStart ??= times[i];
      _openCount++;
      _rawNn.add(nnMs[i]);
      _rawTimes.add(times[i]);
      _last = times[i];
      _settleOpen();
    }
    _n += nnMs.length;
  }

  Metric<CvhrResult> snapshot({
    List<double> tailNnMs = const [],
    List<double> tailNnTimesMs = const [],
    required double artifactFraction,
    double maxArtifact = 0.30,
  }) {
    if (tailNnMs.length != tailNnTimesMs.length) {
      throw ArgumentError('tailNnMs and tailNnTimesMs must have the same length');
    }
    final tailTimes = [for (final t in tailNnTimesMs) t / 1000.0];
    if (!_cvhrNondecreasing(tailTimes) ||
        (tailTimes.isNotEmpty && _last != null && tailTimes.first < _last!)) {
      throw StateError('beat times must be non-decreasing');
    }
    const inputs = ['rr_cleaned', 'beat_times'];
    final n = _n + tailNnMs.length;
    if (n < 60) {
      return const Metric<CvhrResult>.absent(
        tier: Tier.high,
        inputs_used: inputs,
        note: 'too few beats for a CVHR screen (need ≥60)',
      );
    }
    if (artifactFraction > maxArtifact) {
      return Metric<CvhrResult>.absent(
        tier: Tier.high,
        inputs_used: inputs,
        note: 'artifact fraction ${round6(artifactFraction)} > gate '
            '— CVHR dip detection unreliable',
      );
    }
    // The folded times are finite (fold refuses others); a non-finite tail
    // time gets the batch's answer.
    if (tailTimes.any((t) => !t.isFinite)) {
      return const Metric<CvhrResult>.absent(
        tier: Tier.high,
        inputs_used: inputs,
        note: 'non-finite beat time',
      );
    }
    // Nothing folded yet: the tail's first beat is the origin, as in the batch.
    final first = _first ?? (tailTimes.isEmpty ? null : tailTimes.first);
    final last = tailTimes.isEmpty ? _last : tailTimes.last;
    if (first == null || last == null || last - first <= 0) {
      return const Metric<CvhrResult>.absent(
        tier: Tier.high,
        inputs_used: inputs,
        note: 'degenerate beat times',
      );
    }
    return _cvhrMetric(_snapshotContributions(tailNnMs, tailTimes),
        artifactFraction);
  }

  void _closeOpen() {
    final c = _openContribution();
    if (c != null) _closed.add(c);
    _rawNn.clear();
    _rawTimes.clear();
    _grid.clear();
    _smooth.clear();
    _base.clear();
    _exc.clear();
    _openCount = 0;
    _openStart = null;
  }

  void _settleOpen() {
    final start = _openStart!;
    while (start + _grid.length < _rawTimes.last) {
      final g = start + _grid.length;
      _grid.add(_resampleLinear(_rawTimes, _rawNn, [g])[0]);
    }
    while (_smooth.length + 7 < _grid.length) {
      _smooth.add(_savgolAt(_grid, _smooth.length, 7));
    }
    final half = (envWindowSec / 2).round();
    while (_base.length + half < _smooth.length) {
      final i = _base.length;
      final b = _medianAt(_smooth, i, half);
      _base.add(b);
      _exc.add(math.max(0.0, _smooth[i] - b));
    }
    var keep = 0;
    final lastGrid = start + _grid.length - 1;
    while (keep + 1 < _rawTimes.length && _rawTimes[keep + 1] <= lastGrid) {
      keep++;
    }
    if (keep > 0) {
      _rawTimes.removeRange(0, keep);
      _rawNn.removeRange(0, keep);
    }
  }

  List<_CvhrContribution> _snapshotContributions(
      List<double> tailNn, List<double> tailTimes) {
    final out = <_CvhrContribution>[..._closed];
    if (_openCount == 0) {
      if (tailTimes.isNotEmpty) {
        out.addAll(_segmentContributions(tailTimes, tailNn,
            minWidthSec: minWidthSec,
            maxWidthSec: maxWidthSec,
            depthWidthRatioMin: depthWidthRatioMin,
            envWindowSec: envWindowSec,
            maxGapSec: maxGapSec));
      }
      return out;
    }
    var split = 0;
    var previous = _last!;
    while (split < tailTimes.length && tailTimes[split] - previous <= maxGapSec) {
      previous = tailTimes[split++];
    }
    final open = _openContribution(tailNn.sublist(0, split),
        tailTimes.sublist(0, split));
    if (open != null) out.add(open);
    if (split < tailTimes.length) {
      out.addAll(_segmentContributions(tailTimes.sublist(split), tailNn.sublist(split),
          minWidthSec: minWidthSec,
          maxWidthSec: maxWidthSec,
          depthWidthRatioMin: depthWidthRatioMin,
          envWindowSec: envWindowSec,
          maxGapSec: maxGapSec));
    }
    return out;
  }

  _CvhrContribution? _openContribution(
      [List<double> tailNn = const [], List<double> tailTimes = const []]) {
    final start = _openStart!;
    final count = _openCount + tailNn.length;
    final last = tailTimes.isEmpty ? _last! : tailTimes.last;
    if (count < 60 || last - start < 60) return null;
    final exc = _openExcursion(tailNn, tailTimes);
    final depths = <double>[];
    final widths = <double>[];
    _cvhrCycles(exc,
        minWidthSec: minWidthSec,
        maxWidthSec: maxWidthSec,
        depthWidthRatioMin: depthWidthRatioMin,
        onCycle: (depth, width) {
      depths.add(depth);
      widths.add(width);
    });
    return _CvhrContribution((last - start) / 3600.0, depths, widths);
  }

  List<double> _openExcursion(List<double> tailNn, List<double> tailTimes) {
    final rawNn = [..._rawNn, ...tailNn];
    final rawTimes = [..._rawTimes, ...tailTimes];
    final grid = <double>[..._grid];
    final start = _openStart!;
    final last = rawTimes.last;
    while (start + grid.length < last) {
      grid.add(_resampleLinear(rawTimes, rawNn, [start + grid.length])[0]);
    }
    final nGrid = (last - start).floor() + 1;
    while (grid.length < nGrid) {
      grid.add(_resampleLinear(rawTimes, rawNn, [start + grid.length])[0]);
    }
    final smooth = <double>[..._smooth];
    while (smooth.length < grid.length) {
      smooth.add(_savgolAt(grid, smooth.length, 7));
    }
    final half = (envWindowSec / 2).round();
    final base = <double>[..._base];
    while (base.length < smooth.length) {
      base.add(_medianAt(smooth, base.length, half));
    }
    return [
      ..._exc,
      for (var i = _exc.length; i < smooth.length; i++)
        math.max(0.0, smooth[i] - base[i]),
    ];
  }
}

bool _cvhrNondecreasing(List<double> values) {
  for (var i = 1; i < values.length; i++) {
    if (values[i] < values[i - 1]) return false;
  }
  return true;
}

// ─────────────────────────────────────────────────────────────────────────────
// RESP-01 — the 30-night PERSONAL DISTRIBUTION.
//
// The per-night index above is not shippable on its own: single-night CVHR has
// substantial night-to-night variability, it fires on AF, on periodic breathing
// at altitude and on any arousal-rich fragmented night, and it is BLUNTED by
// beta-blockers, autonomic neuropathy and diabetes — so it misses real apnea
// too. Both directions are harm. What survives that is one statement about a
// user's OWN recent nights against their OWN earlier ones.
//
// WHAT THIS MAY NEVER BECOME: an AHI, a severity band, a per-night value on a
// screen, a finding about the user, or a notification. A quiet screen means
// NOTHING — that line is permanent copy, not a tooltip.
//
// RESP-02 (gate half) — nights where `irregular_rhythm_flag` fired are EXCLUDED
// here, not down-weighted. AF produces the same cyclic RR pattern this screen
// scores, so an AF night's index is not a weak apnea signal, it is a different
// signal wearing the same shape. The corroboration half of RESP-02 (10-second
// ENMO) is deliberately not built: it is new accel work, and its absence costs
// this aggregate nothing.

/// One stored night, as the aggregate needs it. Straight off `day_result`.
class CvhrNight {
  /// Local day label the night is filed under (used only for ordering/dedupe).
  final String dayKey;

  /// `respiration.cvhr_apnea.cvhr_per_hour` for that night.
  final double cvhrPerHour;

  /// `respiration.cvhr_apnea.analyzed_hours` — the OBSERVED, gap-excluded hours
  /// behind [cvhrPerHour], and this night's weight.
  final double analyzedHours;

  /// Whether `irregular_rhythm_flag` fired on that day. Null counts as NOT
  /// fired: the flag predates nothing here, but a night we cannot ask about is
  /// not a night we may silently drop from the denominator.
  final bool irregularRhythm;

  const CvhrNight({
    required this.dayKey,
    required this.cvhrPerHour,
    required this.analyzedHours,
    this.irregularRhythm = false,
  });
}

/// The result of the 30-night screen. Deliberately holds NO per-night value.
class CvhrDistribution {
  /// Nights that passed every gate and are behind [recentWeightedMean].
  final int nightsUsed;

  /// Nights dropped because `irregular_rhythm_flag` fired (RESP-02 cross-gate).
  final int nightsExcludedIrregular;

  /// Nights dropped for having under [minAnalyzedHoursPerNight] observed hours.
  final int nightsExcludedThin;

  /// Analyzed-hours-weighted mean cvhr/h over the whole retained window. This
  /// is the user's OWN usual level — it is not a threshold and has no published
  /// normal range.
  final double weightedMean;

  /// The same weighted mean over the most recent third of the retained nights.
  final double recentWeightedMean;

  /// [p25, p50, p75] of the retained nights' indices — the spread the recent
  /// mean is being read against.
  final List<double> quartiles;

  /// True when the recent nights sit above the retained distribution's own p75.
  /// This is the ONLY comparative statement the screen makes, and it is a
  /// statement about this user's own history, not about apnea.
  final bool aboveOwnUsual;

  const CvhrDistribution({
    required this.nightsUsed,
    required this.nightsExcludedIrregular,
    required this.nightsExcludedThin,
    required this.weightedMean,
    required this.recentWeightedMean,
    required this.quartiles,
    required this.aboveOwnUsual,
  });

  Map<String, dynamic> toJson() => {
        'nights_used': nightsUsed,
        'nights_excluded_irregular': nightsExcludedIrregular,
        'nights_excluded_thin': nightsExcludedThin,
        'weighted_mean': round6(weightedMean),
        'recent_weighted_mean': round6(recentWeightedMean),
        'quartiles': quartiles.map(round6).toList(growable: false),
        'above_own_usual': aboveOwnUsual,
      };
}

/// A night needs this many OBSERVED hours before it may weigh on the screen.
const double minAnalyzedHoursPerNight = 4.0;

/// And this many such nights must exist before the screen says anything.
const int minNightsForCvhrDistribution = 5;

/// Nights considered, newest-first, once the gates have run.
const int cvhrDistributionWindowNights = 30;

/// RESP-01 — the 30-night personal CVHR distribution.
///
/// [nights] in any order; the newest [cvhrDistributionWindowNights] retained
/// nights are used. Returns ABSENT — never a partial number — until at least
/// [minNightsForCvhrDistribution] nights clear both gates.
Metric<CvhrDistribution> cvhrPersonalDistribution(List<CvhrNight> nights) {
  const inputs = ['cvhr_apnea', 'irregular_rhythm_flag'];
  // Newest first, one row per day (a re-derive can leave two).
  final byDay = <String, CvhrNight>{};
  for (final n in nights) {
    byDay[n.dayKey] = n;
  }
  final sorted = byDay.values.toList()
    ..sort((a, b) => b.dayKey.compareTo(a.dayKey));

  var excludedIrregular = 0;
  var excludedThin = 0;
  final kept = <CvhrNight>[];
  for (final n in sorted) {
    if (kept.length >= cvhrDistributionWindowNights) break;
    if (!n.cvhrPerHour.isFinite || !n.analyzedHours.isFinite) continue;
    // RESP-02 cross-gate FIRST: an AF night is not a thin night, and counting
    // it as one would misreport why the screen is quiet.
    if (n.irregularRhythm) {
      excludedIrregular++;
      continue;
    }
    if (n.analyzedHours < minAnalyzedHoursPerNight) {
      excludedThin++;
      continue;
    }
    kept.add(n);
  }

  if (kept.length < minNightsForCvhrDistribution) {
    return Metric<CvhrDistribution>.absent(
      tier: Tier.relative,
      inputs_used: inputs,
      note: 'need_baseline:nights=${kept.length}/'
          '$minNightsForCvhrDistribution with ≥'
          '${minAnalyzedHoursPerNight.round()} analyzed hours '
          '(excluded ${excludedIrregular} for irregular rhythm, '
          '${excludedThin} too thinly observed)',
    );
  }

  double weighted(List<CvhrNight> xs) {
    var num = 0.0, den = 0.0;
    for (final n in xs) {
      num += n.cvhrPerHour * n.analyzedHours;
      den += n.analyzedHours;
    }
    return den > 0 ? num / den : 0.0;
  }

  final indices = [for (final n in kept) n.cvhrPerHour];
  // "Recent" is the newest third of the retained nights (≥2 by construction:
  // 5 nights ⇒ 2). One night is not a comparison.
  final recentCount = math.max(2, (kept.length / 3).round());
  final recent = kept.take(recentCount).toList();
  final all = weighted(kept);
  final rec = weighted(recent);
  final q = [
    percentile(indices, 25)!,
    percentile(indices, 50)!,
    percentile(indices, 75)!,
  ];

  return Metric<CvhrDistribution>(
    value: CvhrDistribution(
      nightsUsed: kept.length,
      nightsExcludedIrregular: excludedIrregular,
      nightsExcludedThin: excludedThin,
      weightedMean: all,
      recentWeightedMean: rec,
      quartiles: q,
      aboveOwnUsual: rec > q[2],
    ),
    // Relative tier on purpose: this compares the user only with themselves.
    tier: Tier.relative,
    // The floor is 5 nights, so a 5-night answer must not read like a 30-night
    // one. Confidence rises with the nights actually behind it.
    confidence: (0.3 + 0.4 * (kept.length / cvhrDistributionWindowNights))
        .clamp(0.3, 0.7),
    inputs_used: inputs,
    note: 'CVHR is a CARDIAC SURROGATE, not a breathing measurement: this is '
        'how often the pattern showed up across ${kept.length} of your own '
        'nights, never an AHI, never a severity, never a per-night value. '
        'It also fires on atrial fibrillation (those nights are excluded), on '
        'periodic breathing at altitude and on any fragmented night, and it is '
        'blunted by beta-blockers, autonomic neuropathy and diabetes — so a '
        'quiet screen means nothing.',
  );
}

/// Score ONE gap-free stretch: resample → smooth → sliding-median baseline →
/// positive-excursion runs → width + steepness gates. Calls [onCycle] with
/// (depthMs, widthSec) per surviving cycle. [t] in seconds, [nn] in ms.
void _scoreSegment(
  List<double> t,
  List<double> nn, {
  required double minWidthSec,
  required double maxWidthSec,
  required double depthWidthRatioMin,
  required double envWindowSec,
  required void Function(double depthMs, double widthSec) onCycle,
}) {
  final exc = _cvhrExcursion(t, nn, envWindowSec);
  _cvhrCycles(exc,
      minWidthSec: minWidthSec,
      maxWidthSec: maxWidthSec,
      depthWidthRatioMin: depthWidthRatioMin,
      onCycle: onCycle);
}

List<double> _cvhrExcursion(
    List<double> t, List<double> nn, double envWindowSec) {
  // Resample NN onto a uniform 1 Hz grid by piecewise-linear interpolation of
  // the tachogram (NN vs beat time). This gives evenly-spaced points for the
  // sliding-window baseline and the polynomial smoother. Only ever called on a
  // stretch with no gap larger than the caller's tolerance, so no interpolation
  // here spans a hole.
  final t0 = t.first;
  final nGrid = (t.last - t0).floor() + 1;
  final grid = List<double>.generate(nGrid, (i) => t0 + i);
  final nnGrid = _resampleLinear(t, nn, grid);

  // 2nd-order local-polynomial smoothing (Savitzky-Golay quadratic, ~7 s half
  // window) to suppress beat jitter while keeping the cyclic shape.
  final smooth = _savgolQuadratic(nnGrid, halfWin: 7);

  // Adaptive baseline over a ~130 s sliding median (spans ≥2 apnea cycles, so
  // it tracks the eupneic level without being pulled into individual dips).
  // The CVHR bradycardia shows up as a local NN MAXIMUM (NN ↑ ⇔ HR ↓) standing
  // proud of this baseline; the following tachycardia is the recovery valley.
  final halfEnv = (envWindowSec / 2).round();
  final base = slidingMedians(smooth, halfEnv);
  // Baseline-subtracted bradycardic excursion (clip negatives — we only score
  // the NN-up bradycardia, not the tachycardia trough).
  final exc = [
    for (var j = 0; j < nGrid; j++) math.max(0.0, smooth[j] - base[j])
  ];

  return exc;
}

void _cvhrCycles(List<double> exc,
    {required double minWidthSec,
    required double maxWidthSec,
    required double depthWidthRatioMin,
    required void Function(double depthMs, double widthSec) onCycle}) {
  final nGrid = exc.length;
  // Prominence threshold: a dip must clear a robust noise floor AND a fraction
  // of the typical excursion amplitude. We anchor it BELOW the median positive
  // excursion (Hayano's adaptive amplitude criterion is permissive enough to
  // capture the whole bradycardia run, not just its tip) — a threshold at the
  // peak would clip the run width to a few seconds and miss the cycle.
  final posExc = [
    for (final e in exc)
      if (e > 0) e
  ];
  final excP75 = (posExc.isNotEmpty ? percentile(posExc, 75) : null) ?? 0;
  // half of the upper-quartile excursion: well inside each genuine dip's run.
  final prom = math.max(0.5 * excP75, 5.0); // ms

  // Find peaks of `exc`: local maxima exceeding `prom`, each isolated to one
  // contiguous super-threshold run (so one bradycardia = one cycle). Measure
  // the run width and the peak depth; apply the width + depth/width gates.
  var i = 0;
  while (i < nGrid) {
    // `!(x > prom)` rather than `x <= prom`: a NaN excursion is neither, and
    // would stall this loop. A non-finite excursion never starts a dip.
    if (!_above(exc[i], prom)) {
      i++;
      continue;
    }
    final start = i;
    var peakDepth = 0.0;
    while (i < nGrid && _above(exc[i], prom)) {
      if (exc[i] > peakDepth) peakDepth = exc[i];
      i++;
    }
    final widthSec = (i - start).toDouble(); // 1 Hz grid => samples == seconds
    if (widthSec < minWidthSec || widthSec > maxWidthSec) continue;
    // Depth-to-width steepness gate (ms per second): the bradycardia-tachycardia
    // swing is steep; slow baseline drift is shallow per second.
    if (peakDepth / widthSec < depthWidthRatioMin) continue;
    onCycle(peakDepth, widthSec);
  }
}

/// True when [e] is a finite excursion above [prom]. NaN and +-Infinity never
/// are, so they can neither start nor extend a dip.
bool _above(double e, double prom) => e.isFinite && e > prom;

/// Piecewise-linear resample of (t,y) onto a sorted [grid] of times (same unit).
/// Out-of-range grid points clamp to the nearest endpoint value.
List<double> _resampleLinear(
    List<double> t, List<double> y, List<double> grid) {
  final out = List<double>.filled(grid.length, 0);
  var j = 0;
  for (var k = 0; k < grid.length; k++) {
    final g = grid[k];
    if (g <= t.first) {
      out[k] = y.first;
      continue;
    }
    if (g >= t.last) {
      out[k] = y.last;
      continue;
    }
    while (j < t.length - 1 && t[j + 1] < g) {
      j++;
    }
    final t0 = t[j], t1 = t[j + 1];
    final span = t1 - t0;
    final frac = span == 0 ? 0.0 : (g - t0) / span;
    out[k] = y[j] + (y[j + 1] - y[j]) * frac;
  }
  return out;
}

/// 2nd-order Savitzky-Golay smoothing via a local quadratic least-squares fit
/// over a symmetric window of half-width [halfWin]. Evaluated at the centre.
List<double> _savgolQuadratic(List<double> x, {int halfWin = 7}) {
  final n = x.length;
  final out = List<double>.filled(n, 0);
  for (var i = 0; i < n; i++) {
    out[i] = _savgolAt(x, i, halfWin);
  }
  return out;
}

double _savgolAt(List<double> x, int i, int halfWin) {
  final lo = math.max(0, i - halfWin);
  final hi = math.min(x.length - 1, i + halfWin);
  final m = hi - lo + 1;
  if (m < 3) return x[i];
  var s0 = 0.0, s1 = 0.0, s2 = 0.0, s3 = 0.0, s4 = 0.0;
  var sy = 0.0, suy = 0.0, su2y = 0.0;
  for (var k = lo; k <= hi; k++) {
    final u = (k - i).toDouble();
    final u2 = u * u;
    s0 += 1;
    s1 += u;
    s2 += u2;
    s3 += u2 * u;
    s4 += u2 * u2;
    sy += x[k];
    suy += u * x[k];
    su2y += u2 * x[k];
  }
  final a = _solve3(
    [s0, s1, s2, s1, s2, s3, s2, s3, s4],
    [sy, suy, su2y],
  );
  return a == null ? x[i] : a[0];
}

double _medianAt(List<double> x, int i, int halfWin) {
  final lo = math.max(0, i - halfWin);
  final hi = math.min(x.length - 1, i + halfWin);
  return slidingMedians(x.sublist(lo, hi + 1), hi - lo + 1)[0];
}

/// Solve a 3x3 linear system (row-major A, rhs b) via Cramer's rule. Null if
/// singular.
List<double>? _solve3(List<double> a, List<double> b) {
  double det3(double a0, double a1, double a2, double a3, double a4, double a5,
          double a6, double a7, double a8) =>
      a0 * (a4 * a8 - a5 * a7) -
      a1 * (a3 * a8 - a5 * a6) +
      a2 * (a3 * a7 - a4 * a6);
  final d = det3(a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8]);
  if (d == 0) return null;
  final dx = det3(b[0], a[1], a[2], b[1], a[4], a[5], b[2], a[7], a[8]);
  final dy = det3(a[0], b[0], a[2], a[3], b[1], a[5], a[6], b[2], a[8]);
  final dz = det3(a[0], a[1], b[0], a[3], a[4], b[1], a[6], a[7], b[2]);
  return [dx / d, dy / d, dz / d];
}
