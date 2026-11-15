part of 'incremental.dart';

class _MotionBin {
  final List<double> mags = [];
  double magSum = 0, enmoSum = 0, dynSum = 0;
  MotionMinute? row;
  void render(int key) {
    final mean = magSum / mags.length;
    var deviation = 0.0;
    for (final mag in mags) {
      deviation += (mag - mean).abs();
    }
    row = MotionMinute(key * 60000.0, mags.length, enmoSum / mags.length,
        deviation / mags.length, mean, dynSum / mags.length);
  }
}

/// Explicit-reference motion updates retain the causal trailing axis queue.
/// Automatic calibration is retrospective and uses the complete batch path.
// van Hees 2013 ENMO and Vähä-Ypyä 2015 MAD, as in enmoSeries(); dynAmp remains
// the internal vector high-pass adaptation. Explicit gravity reference uses the
// same trailing queue; automatic calibration recomputes batch. Checked numeric
// field tolerance is max(1e-9 absolute, 1e-8 relative); sample counts and minute
// timestamps match exactly.
class IncrementalEnmoSeries {
  List<AccelSample> _valid = [];
  final Map<int, _MotionBin> _bins = {};
  double? _gRef;
  double _windowS = defaultGravityWindowS;
  double _sx = 0, _sy = 0, _sz = 0;
  int _lo = 0, _processedPoints = 0;
  IncrementalEnmoSeries();

  factory IncrementalEnmoSeries.fromJson(Map<String, dynamic> json) {
    _version(json, 'IncrementalEnmoSeries');
    final state = IncrementalEnmoSeries();
    state._processedPoints = _count(json['processedPoints']);
    state._gRef =
        json['gRef'] == null ? null : _number(json['gRef'], finite: true);
    state._windowS = _number(json['windowS'], finite: true);
    state._sx = _number(json['sx'], finite: true);
    state._sy = _number(json['sy'], finite: true);
    state._sz = _number(json['sz'], finite: true);
    state._lo = _count(json['lo']);
    if (json['valid'] is! List || json['bins'] is! List)
      throw const FormatException('Invalid motion state');
    state._valid = [
      for (final raw in json['valid'] as List)
        (() {
          final row = _numbers(raw, finite: true);
          if (row.length != 4)
            throw const FormatException('Invalid acceleration row');
          return AccelSample(row[0], row[1], row[2], row[3]);
        })()
    ];
    for (final raw in json['bins'] as List) {
      final data = _map(raw);
      if (data['key'] is! int)
        throw const FormatException('Invalid motion minute');
      final key = data['key'] as int;
      if (state._bins.containsKey(key))
        throw const FormatException('Duplicate motion minute');
      final bin = _MotionBin();
      bin.mags.addAll(_numbers(data['mags'], finite: true));
      bin.magSum = _number(data['magSum'], finite: true);
      bin.enmoSum = _number(data['enmoSum'], finite: true);
      bin.dynSum = _number(data['dynSum'], finite: true);
      if (bin.mags.isEmpty || bin.enmoSum < 0 || bin.dynSum < 0)
        throw const FormatException('Invalid motion sums');
      bin.render(key);
      state._bins[key] = bin;
    }
    if (state._processedPoints < state._valid.length ||
        state._lo > math.max(0, state._valid.length - 1) ||
        state._bins.values.fold<int>(0, (n, b) => n + b.mags.length) !=
            state._valid.length ||
        (state._gRef == null && state._valid.isNotEmpty))
      throw const FormatException('Inconsistent motion checkpoint');
    for (var i = 1; i < state._valid.length; i++) {
      if (state._valid[i].tsMs < state._valid[i - 1].tsMs)
        throw const FormatException('Unsorted motion state');
    }
    return state;
  }
  int get processedPoints => _processedPoints;
  EnmoResult sync(List<AccelSample> samples,
      {double? gRef,
      int minSamplesPerMinute = 30,
      double gravityWindowS = defaultGravityWindowS,
      int? expectedMinutes,
      bool force = false}) {
    final valid = samples.where((s) => s.valid).toList()
      ..sort((a, b) => a.tsMs.compareTo(b.tsMs));
    if (gRef == null ||
        !gRef.isFinite ||
        !gravityWindowS.isFinite ||
        valid.any((s) =>
            !s.tsMs.isFinite ||
            !s.x.isFinite ||
            !s.y.isFinite ||
            !s.z.isFinite)) {
      final result = enmoSeries(samples,
          gRef: gRef,
          minSamplesPerMinute: minSamplesPerMinute,
          gravityWindowS: gravityWindowS,
          expectedMinutes: expectedMinutes);
      _reset();
      _processedPoints += valid.length;
      return result;
    }
    var append = !force &&
        gRef == _gRef &&
        gravityWindowS == _windowS &&
        valid.length >= _valid.length;
    if (append) {
      for (var i = 0; i < _valid.length; i++) {
        final a = _valid[i], b = valid[i];
        if (a.tsMs != b.tsMs || a.x != b.x || a.y != b.y || a.z != b.z) {
          append = false;
          break;
        }
      }
    }
    if (!append) _reset();
    _gRef = gRef;
    _windowS = gravityWindowS;
    final changed = <int>{};
    for (var i = _valid.length; i < valid.length; i++) {
      final s = valid[i];
      _sx += s.x;
      _sy += s.y;
      _sz += s.z;
      while (_lo < i && s.tsMs - valid[_lo].tsMs >= gravityWindowS * 1000) {
        _sx -= valid[_lo].x;
        _sy -= valid[_lo].y;
        _sz -= valid[_lo].z;
        _lo++;
      }
      final n = i - _lo + 1;
      final dx = s.x - _sx / n, dy = s.y - _sy / n, dz = s.z - _sz / n;
      final dyn = math.sqrt(dx * dx + dy * dy + dz * dz);
      final mag = math.sqrt(s.x * s.x + s.y * s.y + s.z * s.z);
      final key = (s.tsMs / 60000).floor();
      final bin = _bins[key] ??= _MotionBin();
      bin.mags.add(mag);
      bin.magSum += mag;
      bin.enmoSum += mag > gRef ? mag - gRef : 0;
      bin.dynSum += dyn;
      changed.add(key);
      _processedPoints++;
    }
    _valid = valid;
    for (final key in changed) {
      _bins[key]!.render(key);
    }
    final keys = _bins.keys.toList()..sort();
    final covered =
        _bins.values.where((b) => b.mags.length >= minSamplesPerMinute).length;
    final span = keys.isEmpty ? 0 : keys.last - keys.first + 1;
    final denominator = expectedMinutes ?? span;
    return EnmoResult(gRef, [for (final key in keys) _bins[key]!.row!],
        denominator <= 0 ? 0 : (covered / denominator).clamp(0.0, 1.0));
  }

  void _reset() {
    _valid = [];
    _bins.clear();
    _gRef = null;
    _windowS = defaultGravityWindowS;
    _sx = _sy = _sz = 0;
    _lo = 0;
  }

  Map<String, dynamic> toJson() => {
        'version': 1,
        'type': 'IncrementalEnmoSeries',
        'processedPoints': _processedPoints,
        'gRef': _gRef,
        'windowS': _windowS,
        'sx': _sx,
        'sy': _sy,
        'sz': _sz,
        'lo': _lo,
        'valid': [
          for (final s in _valid) [s.tsMs, s.x, s.y, s.z]
        ],
        'bins': [
          for (final entry in _bins.entries)
            {
              'key': entry.key,
              'mags': List.of(entry.value.mags),
              'magSum': entry.value.magSum,
              'enmoSum': entry.value.enmoSum,
              'dynSum': entry.value.dynSum,
            }
        ],
      };
}
