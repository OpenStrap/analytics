part of 'incremental.dart';

/// Appends NN moments, gap-aware differences and mutable five-minute bins.
// Task Force 1996 hrvTime() statistics with retained moments and gap-aware
// differences. Applicable jitter exemptions/fallbacks invoke batch hrvTime();
// otherwise numerical accumulation differs. The jitter policy is an internal
// rule, ESTIMATE with low confidence. Welch 1967 and Hirsch & Bishop 1981
// support spectral/respiratory components only; see rmssd_gate.dart. Checked numeric field tolerance is max(1e-9
// absolute, 1e-8 relative); presence, tier, note, inputs and beat counts match
// exactly.
class IncrementalHrvTime {
  List<double> _nn = [];
  List<double>? _times;
  RunningMoments _levels = RunningMoments();
  final List<RunningMoments> _bins = [];
  RunningMoments _binMeans = RunningMoments();
  double _binSdSum = 0;
  int _binIdx = 0;
  int _pairs = 0, _over50 = 0, _lagPairs = 0, _processedPoints = 0;
  double _diffSum = 0, _diffSquares = 0, _products = 0, _endpoints = 0;
  double? _lastDiff;
  bool _finite = true;
  // Evidence for the jitter gate below the ACF floor, derived from the series
  // (not checkpointed; rebuilt from `nn` / `times` on restore): the Welch
  // segments `nnDiffNoiseShare` would see (64 points, stride 32, per
  // contiguous run). See [sync] for why under 20 the batch can only refuse.
  int _closedSegments = 0, _runDiffs = 0;

  IncrementalHrvTime();
  factory IncrementalHrvTime.fromJson(Map<String, dynamic> json) {
    _version(json, 'IncrementalHrvTime');
    final state = IncrementalHrvTime();
    state._nn = _numbers(json['nn']);
    state._times = json['times'] == null ? null : _numbers(json['times']);
    state._processedPoints = _count(json['processedPoints']);
    if (json['finite'] is! bool)
      throw const FormatException('Invalid HRV mode');
    state._finite = json['finite'] as bool;
    state._levels = RunningMoments.fromJson(_map(json['levels']));
    state._pairs = _count(json['pairs']);
    state._over50 = _count(json['over50']);
    state._lagPairs = _count(json['lagPairs']);
    state._diffSum = _number(json['diffSum'], finite: true);
    state._diffSquares = _number(json['diffSquares'], finite: true);
    state._products = _number(json['products'], finite: true);
    state._endpoints = _number(json['endpoints'], finite: true);
    state._lastDiff = json['lastDiff'] == null
        ? null
        : _number(json['lastDiff'], finite: true);
    if (json['binIdx'] is! int || json['bins'] is! List)
      throw const FormatException('Invalid HRV bins');
    state._binIdx = json['binIdx'] as int;
    for (final bin in json['bins'] as List) {
      final moments = RunningMoments.fromJson(_map(bin));
      if (moments.count == 0) throw const FormatException('Empty HRV bin');
      state._bins.add(moments);
      if (moments.count >= 2) {
        state._binMeans.add(moments.mean!);
        state._binSdSum += moments.sampleSd!;
      }
    }
    final timed =
        state._times != null && state._times!.length == state._nn.length;
    if (state._processedPoints < state._nn.length ||
        state._over50 > state._pairs ||
        state._lagPairs > state._pairs ||
        state._pairs > math.max(0, state._nn.length - 1) ||
        state._diffSquares < 0 ||
        (state._finite &&
            (state._levels.count != state._nn.length ||
                state._nn.any((v) => !v.isFinite) ||
                (timed && state._times!.any((v) => !v.isFinite)))) ||
        (!state._finite && state._levels.count != 0) ||
        (state._finite &&
            timed &&
            state._bins.fold<int>(0, (n, b) => n + b.count) !=
                state._nn.length) ||
        ((!timed || !state._finite) && state._bins.isNotEmpty)) {
      throw const FormatException('Inconsistent HRV checkpoint');
    }
    if (state._finite) {
      for (var i = 0; i < state._nn.length; i++) {
        state._evidence(i, state._nn, timed ? state._times : null);
      }
    }
    return state;
  }

  static int _segmentsOf(int diffs) => diffs + 1 < 64 ? 0 : (diffs + 1 - 64) ~/ 32 + 1;

  /// Updates the jitter-gate evidence for point [i] of [nn] ([times] when the
  /// series is timed), splitting runs exactly as `hrvTime` does.
  void _evidence(int i, List<double> nn, List<double>? times) {
    if (i == 0) return;
    if (times != null && times[i] - times[i - 1] > nn[i] + .5) {
      _closedSegments += _segmentsOf(_runDiffs);
      _runDiffs = 0;
    } else {
      _runDiffs++;
    }
  }
  int get processedPoints => _processedPoints;
  Metric<HrvTime> sync(List<double> nnMs,
      {List<double>? nnTimesMs,
      double artifactFraction = 0,
      bool force = false}) {
    final timed = nnTimesMs != null && nnTimesMs.length == nnMs.length;
    final oldTimed = _times != null && _times!.length == _nn.length;
    final finite = nnMs.every((v) => v.isFinite) &&
        (!timed || nnTimesMs.every((v) => v.isFinite));
    if (!finite) {
      final result = hrvTime(nnMs,
          nnTimesMs: nnTimesMs, artifactFraction: artifactFraction);
      _reset();
      _finite = false;
      _nn = List.of(nnMs);
      _times = nnTimesMs == null ? null : List.of(nnTimesMs);
      _processedPoints += nnMs.length;
      return result;
    }
    final append = !force &&
        _finite &&
        timed == oldTimed &&
        _prefix(_nn, nnMs) &&
        (!timed || _prefix(_times!, nnTimesMs));
    if (!append) _reset();
    for (var i = _nn.length; i < nnMs.length; i++) {
      final value = nnMs[i];
      _evidence(i, nnMs, timed ? nnTimesMs : null);
      _levels.add(value);
      if (i > 0) {
        if (timed && nnTimesMs[i] - nnTimesMs[i - 1] > value + .5) {
          _lastDiff = null;
        } else {
          final d = value - nnMs[i - 1];
          _pairs++;
          _diffSum += d;
          _diffSquares += d * d;
          if (d.abs() > 50) _over50++;
          if (_lastDiff != null) {
            _lagPairs++;
            _products += _lastDiff! * d;
            _endpoints += _lastDiff! + d;
          }
          _lastDiff = d;
        }
      }
      if (timed) {
        final idx = ((nnTimesMs[i] - nnTimesMs.first) / 300000).floor();
        if (_bins.isEmpty || idx != _binIdx) {
          _bins.add(RunningMoments());
          _binIdx = idx;
        }
        final bin = _bins.last;
        if (bin.count >= 2) {
          _binMeans.remove(bin.mean!);
          _binSdSum -= bin.sampleSd!;
        }
        bin.add(value);
        if (bin.count >= 2) {
          _binMeans.add(bin.mean!);
          _binSdSum += bin.sampleSd!;
        }
      }
      _processedPoints++;
    }
    _nn = List.of(nnMs);
    _times = nnTimesMs == null ? null : List.of(nnTimesMs);
    if (nnMs.length < 2)
      return hrvTime(nnMs,
          nnTimesMs: nnTimesMs, artifactFraction: artifactFraction);
    double? acf;
    if (_pairs >= 30) {
      final m = _diffSum / _pairs;
      final variance = _diffSquares - _diffSum * m;
      if (variance > 0)
        acf = (_products - m * _endpoints + _lagPairs * m * m) / variance;
      // Reevaluate ill-conditioned sums and decisions at the refusal boundary
      // using the batch function's direct centered differences.
      if ((_diffSquares > 0 && variance.abs() < 1e-12 * _diffSquares) ||
          (acf != null && (acf - kNnDiffAcf1Floor).abs() < 1e-10)) {
        _processedPoints += nnMs.length;
        return hrvTime(nnMs,
            nnTimesMs: nnTimesMs, artifactFraction: artifactFraction);
      }
    }
    final jittery = acf != null && acf < kNnDiffAcf1Floor;
    // Under the floor the batch refuses only when the spectrum shows no
    // respiratory line on a low floor, and a refused timed night may still
    // publish from windows on a breathing line steady in Hz (hrv_time.dart
    // `_jitterRefused`, `_breathingRmssd`). Both read the difference runs, so
    // when either could apply the batch decides, on the series handed in.
    // With fewer than 20 segments neither can: the noise share is null (the
    // night is refused), and the breathing test needs 12 windows each holding
    // a contiguous run of 127 differences, which alone makes at least 3
    // segments per window (36). So a short or fragmented refused night stays
    // on the sums.
    if (jittery && _closedSegments + _segmentsOf(_runDiffs) >= 20) {
      _processedPoints += nnMs.length;
      return hrvTime(nnMs,
          nnTimesMs: nnTimesMs, artifactFraction: artifactFraction);
    }
    final quality =
        acf == null ? 1.0 : (1 - acf / kNnDiffAcf1Floor).clamp(0.0, 1.0);
    return Metric<HrvTime>(
        value: HrvTime(
            nBeats: nnMs.length,
            sdnn: _levels.sampleSd,
            rmssd: _pairs > 0 && !jittery
                ? math.sqrt(_diffSquares / _pairs)
                : null,
            pnn50: _pairs > 0 && !jittery ? 100.0 * _over50 / _pairs : null,
            sdann: _binMeans.count >= 2 ? _binMeans.sampleSd : null,
            sdnnIndex:
                _binMeans.count >= 2 ? _binSdSum / _binMeans.count : null,
            diffAcf1: acf),
        confidence: ((nnMs.length / 250.0).clamp(0.0, 1.0) *
                quality *
                (1 - artifactFraction))
            .clamp(.3, .95),
        tier: Tier.high,
        inputs_used: const ['rr_cleaned'],
        note: jittery
            ? 'rmssd_refused:acf1=${acf.toStringAsFixed(3)} — the NN successive '
                'differences are essentially differenced white noise (−0.5 = pure, floor '
                '$kNnDiffAcf1Floor), so RMSSD/pNN50 would measure beat-timing jitter, not '
                'vagal tone. SDNN/SDANN survive it and are the lead here. PRV not ECG-HRV.'
            : 'PRV not ECG-HRV; RMSSD/pNN50 are quantization-sensitive at 1 Hz '
                '— lead with SDNN/SDANN');
  }

  void _reset() {
    _nn = [];
    _times = null;
    _levels = RunningMoments();
    _bins.clear();
    _binMeans = RunningMoments();
    _binSdSum = 0;
    _binIdx = 0;
    _pairs = _over50 = _lagPairs = 0;
    _diffSum = _diffSquares = _products = _endpoints = 0;
    _lastDiff = null;
    _finite = true;
    _closedSegments = _runDiffs = 0;
  }

  Map<String, dynamic> toJson() => {
        'version': 1,
        'type': 'IncrementalHrvTime',
        'nn': _nn.map(_encode).toList(),
        'times': _times?.map(_encode).toList(),
        'processedPoints': _processedPoints,
        'finite': _finite,
        'levels': _levels.toJson(),
        'bins': [for (final b in _bins) b.toJson()],
        'binIdx': _binIdx,
        'pairs': _pairs,
        'over50': _over50,
        'lagPairs': _lagPairs,
        'diffSum': _diffSum,
        'diffSquares': _diffSquares,
        'products': _products,
        'endpoints': _endpoints,
        'lastDiff': _lastDiff,
      };
}
