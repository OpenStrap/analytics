// RESPIRATION TIER-1 — 24/7 respiratory rate from the 1 Hz substrate.
//
// Two independent estimators + an honest fusion gate:
//   * RSA respiratory rate (PRIMARY) — Lomb-Scargle HF-peak on cleaned NN beat
//     times. Respiratory sinus arrhythmia modulates RR at the breathing
//     frequency; the HF (0.15–0.40 Hz) spectral peak => breaths/min.
//     Welch 1967 segmentation: the peak is estimated on ~5-minute sub-windows
//     and the night's rate is the MEDIAN across them; the robustness check is
//     agreement of those sub-windows with each other. See [rsaRespRate] for why
//     the whole-window periodogram it replaced could not work.
//   * RIIV respiratory rate — band-pass 0.1–0.5 Hz on the 1 Hz green PPG ADC
//     (respiratory-induced intensity variation), peak frequency => breaths/min.
//   * Karlen 2013 SD-gate fusion — discard a window when the two estimates
//     disagree by more than a threshold (Smart Fusion), else inverse-variance
//     fuse them into a single honest rate.
//
// HONESTY CEILINGS:
//   * RIIV rides the 1 Hz green ADC, whose Nyquist caps any rate at 0.5 Hz =
//     30 br/min. We refuse to report a peak at/above that ceiling (aliasing).
//   * RSA rides the TACHOGRAM, which is sampled once per BEAT, not once per
//     second — so its ceiling is the beat-rate Nyquist (0.5/NN), ~37 br/min
//     at HR 75 but only ~25 br/min at HR 50. [rsaRespRate] computes that
//     ceiling from the MEDIAN beat interval (whole input and per sub-window —
//     never from a time span, which a sensor gap stretches), caps it at
//     [respHiHz], and withholds the whole window when that ceiling falls below
//     the classic HF band (the alias would be
//     indistinguishable from a genuine slower rate). A rate the window cannot
//     resolve is ABSENT, never a spurious in-band peak dressed up as a normal
//     number.
//   * Neither estimator can see a TRUE rate above [respHiHz] (30 br/min). Such
//     a window yields a low peak near the ceiling, not an absence — sustained
//     adult tachypnea is outside what this module claims to measure.
//   * RSA is HIGH tier (continuous 24/7, the structural edge); RIIV is MED
//     (1 Hz green is a coarse intensity proxy, not the 419 Hz waveform).
//   * Absent / insufficient input => null + confidence 0, never a guess.

import 'dart:math' as math;
import '../types.dart';
import '../util.dart';
import '../foundations/fusion.dart';
import '../../aggregate/json_support.dart';

/// Hard physiological + Nyquist band for adult respiration on a 1 Hz signal.
/// Lower 0.1 Hz = 6 br/min; upper 0.5 Hz = 30 br/min (the 1 Hz Nyquist limit).
const double respLoHz = 0.1;
const double respHiHz = 0.5;

/// RSA uses the classic HRV HF band (0.15–0.40 Hz = 9–24 br/min) where the
/// respiratory peak lives in the RR spectrum.
///
/// [rsaHiHz] is the top of the *classic HF band*, NOT the search ceiling.
/// Searching only to 0.40 Hz was a silent 24 br/min cap: a real 26–29 br/min
/// breather has no peak inside the band, so the search returned the largest
/// spurious in-band structure instead — measured 26.4 → 22.3 and 28.8 → 17.4,
/// both published at confidence 0.90. [rsaRespRate] therefore searches up to
/// the window's own resolvable ceiling (see [rsaCeilingHz]) and withholds a
/// peak that lands there.
const double rsaLoHz = 0.15;
const double rsaHiHz = 0.40;

/// The highest respiratory frequency an RSA window can actually resolve (Hz).
///
/// The tachogram is sampled once per BEAT, so its Nyquist is `0.5 / NN`, not
/// 0.5 Hz (DeBoer, Karemaker & Strackee 1984). At HR 75 (NN 800 ms) that is
/// 0.625 Hz; at HR 50 it is 0.417 Hz. [respHiHz] caps it because nothing
/// downstream of a 1 Hz record should claim more than 30 br/min.
///
/// [beatIntervalSec] is the BEAT INTERVAL — the median of the NN values, each one a
/// real interval between adjacent beats. Not span/(n−1): missing beats do not
/// lower the Nyquist, they only stretch the span.
double rsaCeilingHz(double beatIntervalSec) {
  if (!beatIntervalSec.isFinite || beatIntervalSec <= 0) return respHiHz;
  final nyq = 0.5 / beatIntervalSec;
  return nyq < respHiHz ? nyq : respHiHz;
}

/// One respiratory-rate estimate (breaths/min) plus its provenance.
class RespEstimate {
  final double? brpm; // breaths per minute
  final double? peakHz; // the spectral peak (Hz)
  final double? power; // peak power (normalized)
  final String source; // 'rsa' | 'riiv'

  /// RSA only: the sub-windows the rate rests on, out of all it tried — how
  /// much of the input was actually usable.
  final int? usableSubwindows;
  final int? subwindows;
  const RespEstimate(this.brpm, this.peakHz, this.power, this.source,
      {this.usableSubwindows, this.subwindows});
  Map<String, dynamic> toJson() => {
        'brpm': brpm == null ? null : round6(brpm!),
        if (peakHz != null) 'peak_hz': round6(peakHz!),
        if (power != null) 'power': round6(power!),
        'source': source,
        if (usableSubwindows != null) 'usable_subwindows': usableSubwindows,
        if (subwindows != null) 'subwindows': subwindows,
      };
}

/// Longest span (seconds) a single RSA periodogram may cover.
///
/// The Lomb-Scargle periodogram is an INCONSISTENT estimator: its variance does
/// not fall as the record lengthens — a longer record buys more independent
/// frequency bins (spacing 1/T), each still ~exponentially distributed around
/// the true PSD. Over an 8-hour night 1/T is 3.5e-5 Hz, so the 0.15–0.5 Hz band
/// holds ~10⁴ independent bins and (measured on 14 real nights) ~2600 local
/// maxima; its global maximum is a noise spike, not the respiratory rate.
/// Breathing is also non-stationary across a night — measured, this person's
/// rate falls ~19 → 16 br/min from the first quarter to the last — so one
/// spectrum over the whole night smears a drifting peak anyway.
///
/// 300 s is the classic compromise: long enough that 1/T = 0.0033 Hz (0.2
/// br/min) resolves the HF band, short enough that breathing is stationary
/// inside it.
const double rsaSegmentSec = 300;

/// Usable sub-windows at which [rsaRespRate]'s confidence stops being
/// discounted for thin evidence: ≈ 1 h of beats, since the 300 s sub-windows
/// step by 150 s — (3600 − 300) / 150 + 1 = 23. Counting them as 5-min bins
/// (12) would call ~33 minutes an hour.
const double _rsaFullWeightSubwindows = 23;

/// RSA respiratory rate from cleaned NN beat times (PRIMARY 24/7 source).
///
/// [nnMs] cleaned NN intervals (ms), [nnTimesMs] their cumulative beat times
/// (ms). [artifactFraction] from RR-correction drives the confidence gate.
///
/// METHOD (Welch 1967 segmentation + a data-perturbation robustness check).
/// The input is cut into ~[rsaSegmentSec] sub-windows overlapping 50%, each gets
/// its own Lomb-Scargle HF peak, and the reported rate is the MEDIAN of those
/// peaks. The robustness test is whether the sub-windows AGREE: at least
/// [minConsensus] of them must land within [tolBrpm] br/min of that median,
/// otherwise the rate is withheld. That perturbs the DATA (different minutes of
/// the same night), which is the actual question — is there a stable
/// respiratory signal here?
///
/// WHAT THIS REPLACED, AND WHY. The previous check took ONE periodogram over
/// the whole input and re-sampled it on 300/450/700-point grids, calling that
/// "a deterministic analogue" of Pimentel 2017's AR-model-order surrogate. It
/// is not one. Refining a grid re-reads the SAME spectrum, and over a night
/// that spectrum's bins are spaced ~30× finer than the grid step, so the three
/// grids were drawing three near-independent noise samples: measured on 14 real
/// nights the three peaks scattered by up to 8 br/min, the gate withheld 17 of
/// 30 nights, and on nights it did publish the number was often not even the
/// band's true maximum (one night published 10.66 br/min where the same night's
/// sub-windows agree on 16.96, and the fine-grid maximum was 18.55). Same night
/// replayed twice with a 24-minute-longer sleep window: withheld once, 17.56
/// the other time. The citation went with it — this is Welch segmentation, not
/// Pimentel's surrogate.
///
/// [tolBrpm] 2.0 and [minConsensus] 0.5 are calibrated against a SURROGATE null
/// (the same nights with their NN values shuffled, which destroys RSA and keeps
/// the sampling geometry): surrogate consensus measured 15–28% across 14 real
/// nights, real consensus 52–85%. Uniform peaks over the ~21 br/min searchable
/// band would put ±2 br/min agreement at 19% by chance, which is what the
/// surrogates show. 50% is ~2.5× chance and sits in the measured gap.
///
/// GAPS. Both Nyquist ceilings (whole input and per sub-window) come from the
/// MEDIAN NN, the beat interval itself. Gaps belong to the completeness test:
/// a sub-window is used only when its kept beats COVER ≥ 80 % of it (Σ NN, not
/// first-to-last span). Lomb–Scargle handles the uneven sampling a dropout
/// leaves (Press & Rybicki 1989); the coverage test discards the stretches too
/// empty to spectrum. Confidence scales with how many sub-windows the rate
/// rests on, reaching full weight at [_rsaFullWeightSubwindows] (≈ 1 h), so a
/// rate read from a few minutes is not "confident".
Metric<RespEstimate> rsaRespRate(
  List<double> nnMs,
  List<double> nnTimesMs, {
  required double artifactFraction,
  double tolBrpm = 2.0,
  double minConsensus = 0.5,
  double maxArtifact = 0.30,
}) {
  const inputs = ['rr_cleaned', 'beat_times'];
  if (nnMs.length < 20 || nnTimesMs.length != nnMs.length) {
    return const Metric<RespEstimate>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'too few beats for an RSA spectral estimate (need ≥20)',
    );
  }
  if (artifactFraction > maxArtifact) {
    return Metric<RespEstimate>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'artifact fraction ${round6(artifactFraction)} > gate '
          '— RSA peak unreliable',
    );
  }
  final tSec = [for (final t in nnTimesMs) t / 1000.0];
  // A non-finite beat time has no place on the clock, and an infinite last
  // time made the sub-window walk below endless (it never reaches infinity).
  if (tSec.any((t) => !t.isFinite)) {
    return const Metric<RespEstimate>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'non-finite beat time',
    );
  }
  final spanSec = tSec.last - tSec.first;
  if (spanSec <= 0) {
    return const Metric<RespEstimate>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'degenerate beat times',
    );
  }

  // SEARCH CEILING. The window's own beat-rate Nyquist, capped at [respHiHz].
  // The search used to stop at [rsaHiHz] while the guard below tested against
  // [respHiHz], so the guard was unreachable and the 24 br/min cap was silent.
  //
  // THE BEAT INTERVAL IS A PROPERTY OF THE BEATS, NOT OF THE CLOCK BETWEEN THE
  // FIRST AND THE LAST ONE. `nnTimesMs` (correctRr) is re-anchored to the wall
  // clock across sensor dropouts and advances across every rejected beat, so
  // span/(n−1) is the beat interval DIVIDED BY COVERAGE: a 60 bpm night missing
  // 25 % of its beats read as 45 bpm and the whole night was withheld as an
  // alias. Each NN value is one real interval between adjacent beats; their
  // median is the beat interval, gap-free by construction, and it is what the
  // tachogram's Nyquist (0.5/NN; DeBoer et al. 1984) depends on.
  final beatSec = median(nnMs)! / 1000.0;
  final hiHz = rsaCeilingHz(beatSec);
  // The ceiling must at least cover the classic HF band. Below that, a rate
  // inside the band the literature defines would fold back down into the band
  // as an alias and be indistinguishable from a genuine slower one — measured:
  // 26 br/min at NN 1400 ms folds to 16.9 br/min with a full-height peak. No
  // spectral test can separate the two, so the honest answer is nothing at all.
  if (hiHz < rsaHiHz) {
    return Metric<RespEstimate>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'sleeping heart rate ${round6(60 / beatSec)} bpm (median beat '
          'interval ${round6(beatSec)} s) can resolve breathing from beat '
          'timing only up to ${round6(hiHz * 60)} br/min, below the top of the '
          'normal 9–24 br/min band, so any peak could be an alias; rate '
          'withheld',
    );
  }

  // WELCH SEGMENTATION. Sub-windows of [rsaSegmentSec] (or half the input when
  // it is shorter than two of them), overlapping 50%. Each gets its own
  // periodogram on a grid oversampled 4× ITS OWN resolution (1/span) — a grid
  // finer than that only re-reads the same bins, which is the trap the old
  // 300/450/700 surrogate fell into.
  var segSec = rsaSegmentSec;
  if (spanSec < 2 * segSec) segSec = spanSec / 2;
  if (segSec < 60) {
    return Metric<RespEstimate>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'window spans ${round6(spanSec)} s — needs ≥120 s to test the '
          'respiratory peak against itself over time',
    );
  }
  final segments = <_RsaSegmentResult>[];
  for (var i = 0;; i++) {
    final s = tSec.first + i * (segSec / 2);
    if (s + segSec > tSec.last + 1e-9) break;
    segments.add(_rsaSegment(tSec, nnMs, s, segSec));
  }
  return _rsaMetricFromSegments(segments,
      artifactFraction: artifactFraction,
      tolBrpm: tolBrpm,
      minConsensus: minConsensus,
      segSec: segSec,
      hiHz: hiHz);
}

class _RsaSegmentResult {
  // 0 = usable peak, 1 = ceiling, 2 = below HF band, 3 = thin, 4 = gappy
  // (kept beats cover < 80 % of the sub-window).
  final int kind;
  final double? brpm, peakHz, power;
  // kind 1 only: the sub-window's own ceiling, br/min.
  final double? ceilingBrpm;
  const _RsaSegmentResult(this.kind,
      [this.brpm, this.peakHz, this.power, this.ceilingBrpm]);

  Map<String, dynamic> toJson() => {
        'kind': kind,
        'brpm': brpm == null ? null : encodeDouble(brpm!),
        'peakHz': peakHz == null ? null : encodeDouble(peakHz!),
        'power': power == null ? null : encodeDouble(power!),
        'ceiling': ceilingBrpm == null ? null : encodeDouble(ceilingBrpm!),
      };
}

_RsaSegmentResult _rsaSegment(
    List<double> tSec, List<double> nnMs, double start, double segSec) {
  final lo = _lowerBound(tSec, start);
  final hi = _lowerBound(tSec, start + segSec);
  final k = hi - lo;
  // A sub-window has to be BOTH time-complete and beat-dense: a dropout in
  // the middle leaves few beats spanning the full 5 minutes, and its
  // periodogram is a window function, not a spectrum.
  final segT = tSec.sublist(lo, hi);
  final segNn = nnMs.sublist(lo, hi);
  // TIME-COMPLETE = the kept beats COVER ≥ 80 % of the sub-window. Σ NN, not
  // first-to-last span: two beats near the edges with a 3-minute hole between
  // them passed the span test and handed Lomb–Scargle a window function.
  // Judged first, so a sub-window a sensor gap emptied is named a gap.
  final coveredSec = segNn.fold<double>(0, (a, b) => a + b) / 1000.0;
  if (coveredSec < segSec * 0.8) return const _RsaSegmentResult(4);
  if (k < 30) return const _RsaSegmentResult(3);
  final segSpan = segT.last - segT.first; // still sets the grid resolution
  // Per sub-window Nyquist from its median beat interval, gap-free, like the
  // whole-input check.
  final segHi = rsaCeilingHz(median(segNn)! / 1000.0);
  if (segHi < rsaHiHz) return const _RsaSegmentResult(2);
  final grid = math.max(64, ((segHi - rsaLoHz) * 4 * segSpan).ceil());
  final ls = lombScargle(segT, segNn, freqGrid(rsaLoHz, segHi, grid));
  if (ls == null) return const _RsaSegmentResult(3);
  final pk = ls.peakFreq(rsaLoHz, segHi);
  if (pk == null) return const _RsaSegmentResult(3);
  if (pk >= segHi - (segHi - rsaLoHz) / (grid - 1)) {
    return _RsaSegmentResult(1, null, null, null, segHi * 60);
  }
  return _RsaSegmentResult(0, pk * 60.0, pk, _powerAt(ls, pk));
}

Metric<RespEstimate> _rsaMetricFromSegments(
  List<_RsaSegmentResult> segments, {
  required double artifactFraction,
  required double tolBrpm,
  required double minConsensus,
  required double segSec,
  required double hiHz,
}) {
  const inputs = ['rr_cleaned', 'beat_times'];
  final peaks = <double>[];
  final peakHz = <double>[];
  final peakPwr = <double>[];
  var atCeiling = 0, belowBand = 0, thin = 0, gappy = 0;
  // The ceilings those sub-windows peaked at, br/min — their own, which
  // move with heart rate; not the whole input's.
  var ceilingLo = double.infinity, ceilingHi = 0.0;
  for (final segment in segments) {
    if (segment.kind == 0) {
      peaks.add(segment.brpm!);
      peakHz.add(segment.peakHz!);
      peakPwr.add(segment.power!);
    } else if (segment.kind == 1) {
      atCeiling++;
      ceilingLo = math.min(ceilingLo, segment.ceilingBrpm!);
      ceilingHi = math.max(ceilingHi, segment.ceilingBrpm!);
    } else if (segment.kind == 2) {
      belowBand++;
    } else if (segment.kind == 4) {
      gappy++;
    } else {
      thin++;
    }
  }
  final dropped = atCeiling + belowBand + thin + gappy;
  final total = peaks.length + dropped;
  if (peaks.length < 3) {
    // The largest counter is the reason; ties go to the earlier entry.
    final reasons = <(int, String)>[
      (
        belowBand,
        '$belowBand of $total sub-windows had a beat rate too low to cover '
            'the HF band (any peak could be an alias)'
      ),
      (
        atCeiling,
        atCeiling == 0
            ? ''
            : '$atCeiling of $total sub-windows peaked at/above their '
                'resolvable ceiling (${round6(ceilingLo)}'
                '${ceilingHi > ceilingLo ? '–${round6(ceilingHi)}' : ''} '
                'br/min)'
      ),
      (
        gappy,
        '$gappy of $total ${round6(segSec)}s sub-windows had less than 80 % '
            'of their time covered by clean beats (sensor gaps or rejected '
            'beats)'
      ),
      (
        thin,
        '$thin of $total sub-windows had fewer than 30 beats or no spectral '
            'peak'
      ),
    ];
    var top = reasons.first;
    for (final r in reasons.skip(1)) {
      if (r.$1 > top.$1) top = r;
    }
    final why =
        dropped == 0 ? 'only ${peaks.length} usable sub-windows' : top.$2;
    return Metric<RespEstimate>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'no stable HF respiratory peak resolved — $why',
    );
  }
  // AGREEMENT GATE — over TIME, not over grid resolution. How much of the night
  // agrees with the night's own median?
  final medBrpm0 = median(peaks)!;
  var within = 0;
  for (final p in peaks) {
    if ((p - medBrpm0).abs() <= tolBrpm) within++;
  }
  final consensus = within / peaks.length;
  if (consensus < minConsensus) {
    return Metric<RespEstimate>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'HF peak unstable across the window\'s own sub-windows — only '
          '$within of ${peaks.length} ${round6(segSec)}s sub-windows fall '
          'within ${round6(tolBrpm)} br/min of the median; withheld',
    );
  }
  // ONE SOURCE for the reported triple. `brpm` used to be median(peaks) while
  // `peakHz`/`power` came from the highest-POWER estimate, so `peak_hz * 60`
  // and `brpm` could disagree inside a single RespEstimate. We pick the MEDOID
  // sub-window — the one whose peak is closest to the median across
  // sub-windows — and report its rate, frequency and power together, so
  // `brpm == peakHz * 60` holds exactly and `power` is the power measured AT
  // the reported frequency.
  var best = 0;
  for (var i = 1; i < peaks.length; i++) {
    if ((peaks[i] - medBrpm0).abs() < (peaks[best] - medBrpm0).abs()) best = i;
  }
  final brpm = peaks[best];
  final bestPeakHz = peakHz[best];
  final bestPower = peakPwr[best];
  // Confidence: how much of the window agrees with itself, discounted by
  // artifacts and by how few sub-windows it rests on. Cap below 1 (PRV
  // ceiling).
  final conf = ((1 - artifactFraction) *
          consensus *
          (peaks.length / _rsaFullWeightSubwindows).clamp(0.0, 1.0))
      .clamp(0.2, 0.9);
  return Metric<RespEstimate>(
    value: RespEstimate(brpm, bestPeakHz, bestPower, 'rsa',
        usableSubwindows: peaks.length,
        subwindows: total),
    confidence: conf,
    tier: Tier.high,
    inputs_used: inputs,
    note: 'RSA HF-peak respiratory rate (Lomb-Scargle on native beat times, '
        'median of ${peaks.length} ${round6(segSec)}s sub-windows, $within of '
        'them within ${round6(tolBrpm)} br/min of it — brpm, peak_hz and power '
        'all come from the medoid sub-window); PRV-derived; this window could '
        'resolve up to ${round6(hiHz * 60)} br/min',
  );
}

/// Exact, append-only Welch state for [rsaRespRate].
///
/// The whole-input ceiling comes from the MEDIAN beat interval, so every folded
/// NN is kept once more in [_sorted] ([double.compareTo] order, as `median`
/// sorts); a snapshot merges the tail in. Checkpoint version 2 carries it; a
/// version 1 checkpoint (span-based ceiling, no gappy sub-windows) is refused.
// Welch 1967; Lomb 1976; Scargle 1982; Press & Rybicki 1989; DeBoer, Karemaker &
// Strackee 1984, as in rsaRespRate(). Shared segment scoring, retained exact NN
// median and provisional windows reproduce batch.
class RsaRespStream {
  final List<double> _nn = [], _times = [];
  List<double> _sorted = [];
  final List<_RsaSegmentResult> _closed = [];
  int _n = 0;
  double? _first, _last, _nextStart;

  RsaRespStream();

  factory RsaRespStream.fromJson(Map<String, dynamic> json) {
    try {
      final j = decodeMap(json);
      if (field(j, 'type') != 'RsaRespStream') {
        throw const FormatException('not an RsaRespStream checkpoint');
      }
      if (field(j, 'version') != 2) {
        throw const FormatException('unsupported RsaRespStream version');
      }
      final n = decodeCount(field(j, 'n'));
      final first = decodeDoubleOrNull(field(j, 'first'));
      final last = decodeDoubleOrNull(field(j, 'last'));
      final next = decodeDoubleOrNull(field(j, 'nextStart'));
      final nn = decodeDoubles(field(j, 'nn'));
      final times = decodeDoubles(field(j, 'times'));
      final encoded = decodeList(field(j, 'closed'));
      final sorted = decodeDoubles(field(j, 'sorted'));
      if (nn.length != times.length ||
          sorted.length != n ||
          !_nondecreasingBy(sorted) ||
          (n == 0 && (first != null || last != null || next != null)) ||
          (n > 0 && (first == null || last == null || next == null))) {
        throw const FormatException('inconsistent RsaRespStream checkpoint');
      }
      final s = RsaRespStream()
        .._n = n
        .._first = first
        .._last = last
        .._nextStart = next
        .._nn.addAll(nn)
        .._times.addAll(times)
        .._sorted = sorted;
      if (!_nondecreasing(s._times)) {
        throw const FormatException('decreasing checkpoint times');
      }
      for (final value in encoded) {
        final r = decodeMap(value);
        final kind = field(r, 'kind');
        if (kind is! int || kind < 0 || kind > 4) {
          throw const FormatException('invalid RSA segment');
        }
        final brpm = decodeDoubleOrNull(field(r, 'brpm'));
        final peakHz = decodeDoubleOrNull(field(r, 'peakHz'));
        final power = decodeDoubleOrNull(field(r, 'power'));
        final ceiling = decodeDoubleOrNull(field(r, 'ceiling'));
        if ((kind == 0) != (brpm != null && peakHz != null && power != null) ||
            (kind == 1) != (ceiling != null)) {
          throw const FormatException('invalid RSA segment');
        }
        s._closed.add(_RsaSegmentResult(kind, brpm, peakHz, power, ceiling));
      }
      return s;
    } on FormatException {
      rethrow;
    } catch (e) {
      throw FormatException('malformed RsaRespStream checkpoint: $e');
    }
  }

  Map<String, dynamic> toJson() => {
        'type': 'RsaRespStream',
        'version': 2,
        'n': _n,
        'first': _first == null ? null : encodeDouble(_first!),
        'last': _last == null ? null : encodeDouble(_last!),
        'nextStart': _nextStart == null ? null : encodeDouble(_nextStart!),
        'nn': [for (final x in _nn) encodeDouble(x)],
        'times': [for (final x in _times) encodeDouble(x)],
        'closed': [for (final x in _closed) x.toJson()],
        'sorted': [for (final x in _sorted) encodeDouble(x)],
      };

  void fold(List<double> nnMs, List<double> nnTimesMs) {
    if (nnMs.length != nnTimesMs.length) {
      throw ArgumentError('nnMs and nnTimesMs must have the same length');
    }
    if (nnMs.isEmpty) return;
    final times = [for (final t in nnTimesMs) t / 1000.0];
    // Checked before any state changes: an infinite time would make [_settle]
    // endless, and a fold cannot be undone.
    if (times.any((t) => !t.isFinite)) {
      throw ArgumentError('beat times must be finite');
    }
    if (!_nondecreasing(times) ||
        (_last != null && times.first < _last!)) {
      throw StateError('beat times must be non-decreasing');
    }
    _first ??= times.first;
    _nextStart ??= _first;
    _nn.addAll(nnMs);
    _times.addAll(times);
    _sorted = _mergeSorted(_sorted, [...nnMs]..sort());
    _n += nnMs.length;
    _last = times.last;
    final span = _last! - _first!;
    if (span >= 2 * rsaSegmentSec) {
      _settle();
      _compact();
    }
  }

  Metric<RespEstimate> snapshot({
    List<double> tailNnMs = const [],
    List<double> tailNnTimesMs = const [],
    required double artifactFraction,
    double tolBrpm = 2.0,
    double minConsensus = 0.5,
    double maxArtifact = 0.30,
  }) {
    if (tailNnMs.length != tailNnTimesMs.length) {
      throw ArgumentError('tailNnMs and tailNnTimesMs must have the same length');
    }
    final tail = [for (final t in tailNnTimesMs) t / 1000.0];
    if (!_nondecreasing(tail) ||
        (tail.isNotEmpty && _last != null && tail.first < _last!)) {
      throw StateError('beat times must be non-decreasing');
    }
    final n = _n + tailNnMs.length;
    // A non-finite tail time: the batch's own answer (it abstains).
    if (n < 20 || _first == null || tail.any((t) => !t.isFinite)) {
      return rsaRespRate([..._nn, ...tailNnMs],
          [..._times.map((x) => x * 1000.0), ...tailNnTimesMs],
          artifactFraction: artifactFraction,
          tolBrpm: tolBrpm,
          minConsensus: minConsensus,
          maxArtifact: maxArtifact);
    }
    if (artifactFraction > maxArtifact) {
      return Metric<RespEstimate>.absent(
          tier: Tier.high,
          inputs_used: const ['rr_cleaned', 'beat_times'],
          note: 'artifact fraction ${round6(artifactFraction)} > gate '
              '— RSA peak unreliable');
    }
    final times = [..._times, ...tail];
    final nn = [..._nn, ...tailNnMs];
    final last = times.last;
    final span = last - _first!;
    if (span <= 0) {
      return rsaRespRate(nn, [for (final t in times) t * 1000.0],
          artifactFraction: artifactFraction,
          tolBrpm: tolBrpm,
          minConsensus: minConsensus,
          maxArtifact: maxArtifact);
    }
    // Same median the batch takes over settled ++ tail.
    final beatSec =
        percentileSorted(_mergeSorted(_sorted, [...tailNnMs]..sort()), 50)! /
            1000.0;
    final hiHz = rsaCeilingHz(beatSec);
    if (hiHz < rsaHiHz) {
      return Metric<RespEstimate>.absent(
          tier: Tier.high,
          inputs_used: const ['rr_cleaned', 'beat_times'],
          note: 'sleeping heart rate ${round6(60 / beatSec)} bpm (median beat '
              'interval ${round6(beatSec)} s) can resolve breathing from beat '
              'timing only up to ${round6(hiHz * 60)} br/min, below the top of '
              'the normal 9–24 br/min band, so any peak could be an alias; rate '
              'withheld');
    }
    var segSec = rsaSegmentSec;
    if (span < 2 * segSec) segSec = span / 2;
    if (segSec < 60) {
      return rsaRespRate(nn, [for (final t in times) t * 1000.0],
          artifactFraction: artifactFraction,
          tolBrpm: tolBrpm,
          minConsensus: minConsensus,
          maxArtifact: maxArtifact);
    }
    if (span < 2 * rsaSegmentSec) {
      return rsaRespRate(nn, [for (final t in times) t * 1000.0],
          artifactFraction: artifactFraction,
          tolBrpm: tolBrpm,
          minConsensus: minConsensus,
          maxArtifact: maxArtifact);
    }
    final segments = <_RsaSegmentResult>[..._closed];
    for (var i = _closed.length;; i++) {
      final start = _first! + i * (rsaSegmentSec / 2);
      if (start + rsaSegmentSec > last + 1e-9) break;
      segments.add(_rsaSegment(times, nn, start, rsaSegmentSec));
    }
    return _rsaMetricFromSegments(segments,
        artifactFraction: artifactFraction,
        tolBrpm: tolBrpm,
        minConsensus: minConsensus,
        segSec: rsaSegmentSec,
        hiHz: hiHz);
  }

  void _settle() {
    while (_nextStart! + rsaSegmentSec < _last! - 1e-9) {
      _closed.add(_rsaSegment(_times, _nn, _nextStart!, rsaSegmentSec));
      _nextStart = _first! + _closed.length * (rsaSegmentSec / 2);
    }
  }

  void _compact() {
    var cut = 0;
    while (cut < _times.length && _times[cut] < _nextStart!) {
      cut++;
    }
    if (cut > 0) {
      _times.removeRange(0, cut);
      _nn.removeRange(0, cut);
    }
  }
}

/// [a] and [b] sorted by [double.compareTo]; the merge is sorted the same way.
List<double> _mergeSorted(List<double> a, List<double> b) {
  if (b.isEmpty) return a;
  if (a.isEmpty) return b;
  final out = List<double>.filled(a.length + b.length, 0);
  var i = 0, j = 0, k = 0;
  while (i < a.length && j < b.length) {
    out[k++] = a[i].compareTo(b[j]) <= 0 ? a[i++] : b[j++];
  }
  while (i < a.length) {
    out[k++] = a[i++];
  }
  while (j < b.length) {
    out[k++] = b[j++];
  }
  return out;
}

bool _nondecreasingBy(List<double> values) {
  for (var i = 1; i < values.length; i++) {
    if (values[i].compareTo(values[i - 1]) < 0) return false;
  }
  return true;
}

bool _nondecreasing(List<double> values) {
  for (var i = 1; i < values.length; i++) {
    if (values[i] < values[i - 1]) return false;
  }
  return true;
}

/// RIIV respiratory rate from the 1 Hz green PPG ADC.
///
/// Respiratory-Induced Intensity Variation: a 0.1–0.5 Hz band-pass on the green
/// ADC, then the dominant spectral peak in the respiratory band => breaths/min.
/// [adc] the green ADC samples, [tsSec] their times (seconds). Uneven times are
/// fine — we use Lomb-Scargle, no resampling — but the stream must sample at
/// 1 Hz OR FASTER, because the band is fixed and anything slower aliases into
/// it (see the Nyquist gate below). [validFraction] of the window that passed
/// the contact/SQI gate drives confidence.
Metric<RespEstimate> riivRespRate(
  List<double> adc,
  List<double> tsSec, {
  double validFraction = 1.0,
}) {
  const inputs = ['ppg_green', 'ts'];
  final n = adc.length;
  if (n < 30 || tsSec.length != n) {
    return const Metric<RespEstimate>.absent(
      tier: Tier.relative,
      inputs_used: inputs,
      note: 'too few green-ADC samples for RIIV (need ≥30 s)',
    );
  }
  final spanSec = tsSec.last - tsSec.first;
  if (spanSec <= 0) {
    return const Metric<RespEstimate>.absent(
      tier: Tier.relative,
      inputs_used: inputs,
      note: 'degenerate timestamps',
    );
  }
  // NYQUIST. Unlike RSA (which derives its ceiling per window, `_beatNyquist`),
  // this band was FIXED at 0.1–0.5 Hz with no reference to the sampling rate at
  // all. A stream slower than 1 Hz cannot represent it: at 5 s sampling every
  // real breath sits above Nyquist and folds back INSIDE the band as an alias,
  // so the peak is real, in range, and about a rate nobody is breathing —
  // measured on a real night, 21.2 br/min was published as 10.8. Narrowing the
  // search grid is no defence, because an alias is in-band by construction.
  // The only honest output is absence.
  final cadenceSec = sampleCadenceSeconds(tsSec);
  if (cadenceSec == null || 1.0 / (2 * cadenceSec) < respHiHz) {
    return Metric<RespEstimate>.absent(
      tier: Tier.relative,
      inputs_used: inputs,
      note: cadenceSec == null
          ? 'no measurable sampling cadence — cannot rule out a respiratory '
              'alias, so RIIV is withheld'
          : 'sampling at ${round6(cadenceSec)}s (Nyquist '
              '${round6(1.0 / (2 * cadenceSec))} Hz) cannot represent the '
              '${respLoHz}–${respHiHz} Hz respiratory band — every rate in it '
              'would alias into the band; withheld',
    );
  }
  // Detrend (remove DC/slow baseline wander) via a robust-ish linear fit; the
  // band-pass character comes from restricting the Lomb-Scargle grid to the
  // respiratory band, which rejects both DC (<0.1 Hz) and HR/cardiac (>0.5 Hz).
  final fit = olsFit(adc, tsSec);
  final detr = <double>[];
  for (var i = 0; i < n; i++) {
    final base = fit == null ? 0.0 : (fit.slope * tsSec[i] + fit.intercept);
    detr.add(adc[i] - base);
  }
  final ls = lombScargle(tsSec, detr, freqGrid(respLoHz, respHiHz, 500));
  if (ls == null) {
    return const Metric<RespEstimate>.absent(
      tier: Tier.relative,
      inputs_used: inputs,
      note: 'RIIV spectrum undefined',
    );
  }
  final pk = ls.peakFreq(respLoHz, respHiHz);
  if (pk == null || pk >= respHiHz) {
    return const Metric<RespEstimate>.absent(
      tier: Tier.relative,
      inputs_used: inputs,
      note: 'no respiratory-band peak (or aliased at Nyquist)',
    );
  }
  final brpm = pk * 60.0;
  final pwr = _powerAt(ls, pk);
  // RIIV from 1 Hz green is MED/relative at best — never high confidence.
  final conf = (0.6 * validFraction).clamp(0.15, 0.6);
  return Metric<RespEstimate>(
    value: RespEstimate(brpm, pk, pwr, 'riiv'),
    confidence: conf,
    tier: Tier.relative,
    inputs_used: inputs,
    note: 'RIIV band-pass (0.1–0.5 Hz) on 1 Hz green ADC; coarse intensity '
        'proxy (not 419 Hz waveform); 1 Hz Nyquist caps rate at 30 br/min',
  );
}

/// Fused respiratory rate result with the Karlen SD-gate decision.
class FusedResp {
  final double? brpm; // fused breaths/min (null if gated out / nothing)
  final double? rsaBrpm;
  final double? riivBrpm;
  final bool agreed; // passed the Karlen SD-gate
  final String
      decision; // 'fused' | 'rsa_only' | 'riiv_only' | 'disagree' | 'none'
  const FusedResp({
    required this.brpm,
    required this.rsaBrpm,
    required this.riivBrpm,
    required this.agreed,
    required this.decision,
  });
  Map<String, dynamic> toJson() => {
        'brpm': brpm == null ? null : round6(brpm!),
        if (rsaBrpm != null) 'rsa_brpm': round6(rsaBrpm!),
        if (riivBrpm != null) 'riiv_brpm': round6(riivBrpm!),
        'agreed': agreed,
        'decision': decision,
      };
}

/// Karlen 2013 Smart-Fusion SD-gate on RSA + RIIV.
///
/// If both estimates are present, fuse only when they agree within [sdGateBrpm]
/// br/min (Karlen discards the window otherwise — we down-rank to RSA-only since
/// RSA is the validated primary). With only one present, pass it through at its
/// own confidence. Inverse-variance weighting uses each estimate's confidence
/// (higher confidence => lower variance).
Metric<FusedResp> fuseRespRate(
  Metric<RespEstimate> rsa,
  Metric<RespEstimate> riiv, {
  double sdGateBrpm = 5.0,
}) {
  final inputs = <String>[...rsa.inputs_used, ...riiv.inputs_used];
  final rsaV = rsa.value?.brpm;
  final riivV = riiv.value?.brpm;

  if (rsaV == null && riivV == null) {
    return Metric<FusedResp>.absent(
      tier: Tier.high,
      inputs_used: inputs,
      note: 'neither RSA nor RIIV resolved a respiratory rate',
    );
  }
  if (rsaV != null && riivV == null) {
    return Metric<FusedResp>(
      value: FusedResp(
        brpm: rsaV,
        rsaBrpm: rsaV,
        riivBrpm: null,
        agreed: false,
        decision: 'rsa_only',
      ),
      confidence: rsa.confidence,
      tier: Tier.high,
      inputs_used: inputs,
      note: 'RSA-only (RIIV absent)',
    );
  }
  if (rsaV == null && riivV != null) {
    return Metric<FusedResp>(
      value: FusedResp(
        brpm: riivV,
        rsaBrpm: null,
        riivBrpm: riivV,
        agreed: false,
        decision: 'riiv_only',
      ),
      confidence: riiv.confidence,
      tier: Tier.relative,
      inputs_used: inputs,
      note: 'RIIV-only (RSA absent) — relative/MED tier',
    );
  }

  // Both present: Karlen SD-gate.
  final disagree = (rsaV! - riivV!).abs();
  if (disagree > sdGateBrpm) {
    // Karlen discards the window. We keep the validated primary (RSA) but flag
    // the disagreement and lower confidence rather than emit a fused number we
    // don't trust.
    return Metric<FusedResp>(
      value: FusedResp(
        brpm: rsaV,
        rsaBrpm: rsaV,
        riivBrpm: riivV,
        agreed: false,
        decision: 'disagree',
      ),
      confidence: rsa.confidence * 0.6,
      tier: Tier.high,
      inputs_used: inputs,
      note: 'Karlen SD-gate: RSA/RIIV disagree by ${round6(disagree)} br/min '
          '> ${sdGateBrpm}; fell back to RSA, lowered confidence',
    );
  }
  // Agree => inverse-variance fuse (confidence -> variance).
  final fused = inverseVarianceFuse([
    FusionInput(rsaV, _confToVar(rsa.confidence), label: 'rsa'),
    FusionInput(riivV, _confToVar(riiv.confidence), label: 'riiv'),
  ]);
  final brpm = fused.value ?? rsaV;
  // Agreement boosts confidence above either alone (independent corroboration).
  final conf =
      (math.max(rsa.confidence, riiv.confidence) + 0.1).clamp(0.2, 0.95);
  return Metric<FusedResp>(
    value: FusedResp(
      brpm: brpm,
      rsaBrpm: rsaV,
      riivBrpm: riivV,
      agreed: true,
      decision: 'fused',
    ),
    confidence: conf,
    tier: Tier.high,
    inputs_used: inputs,
    note: 'Karlen SD-gate passed (Δ ${round6(disagree)} br/min); '
        'inverse-variance fused RSA+RIIV',
  );
}

/// Map a 0..1 confidence to a positive variance for inverse-variance fusion.
/// Higher confidence => lower variance. Floored so confidence 0 stays finite.
double _confToVar(double conf) {
  final c = conf.clamp(0.05, 1.0);
  return 1.0 / (c * c);
}

/// First index of [a] whose value is >= [v]. [a] must be non-decreasing.
int _lowerBound(List<double> a, double v) {
  var lo = 0, hi = a.length;
  while (lo < hi) {
    final m = (lo + hi) >> 1;
    if (a[m] < v) {
      lo = m + 1;
    } else {
      hi = m;
    }
  }
  return lo;
}

/// Power at (or nearest to) a given frequency in a Lomb-Scargle spectrum.
double _powerAt(LombScargle ls, double fHz) {
  double best = 0;
  double bestDist = double.infinity;
  for (final pt in ls.spectrum) {
    final d = (pt.freqHz - fHz).abs();
    if (d < bestDist) {
      bestDist = d;
      best = pt.psd;
    }
  }
  return best;
}
