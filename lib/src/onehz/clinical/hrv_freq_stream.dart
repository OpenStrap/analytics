part of 'hrv_freq.dart';

class _HrvBandState {
  final double loHz, hiHz, segSec;
  double nextStart;
  double sum;
  int count;

  _HrvBandState(this.loHz, this.hiHz, this.nextStart,
      {this.sum = 0.0, this.count = 0})
      : segSec = 10.0 / loHz;

  double? value(List<double> times, List<double> nn, double last,
      double oversample) {
    if (last - times.first < segSec) return null;
    var total = sum;
    var n = count;
    final grid = _welchGrid(loHz, hiHz, segSec, oversample);
    for (var start = nextStart; start + segSec <= last; start += segSec / 2) {
      final p = _welchSegmentPower(times, nn, start, segSec, loHz, hiHz,
          grid: grid, minPointsPerSegment: 16);
      if (p != null && p.isFinite) {
        total += p;
        n++;
      }
    }
    return n == 0 ? null : total / n;
  }

  void settle(List<double> times, List<double> nn, double last,
      double oversample) {
    final grid = _welchGrid(loHz, hiHz, segSec, oversample);
    while (nextStart + segSec <= last) {
      final p = _welchSegmentPower(times, nn, nextStart, segSec, loHz, hiHz,
          grid: grid, minPointsPerSegment: 16);
      if (p != null && p.isFinite) {
        sum += p;
        count++;
      }
      nextStart += segSec / 2;
    }
  }

  Map<String, dynamic> toJson() => {
        'nextStart': encodeDouble(nextStart),
        'sum': encodeDouble(sum),
        'count': count,
      };
}

List<double> _welchGrid(double lo, double hi, double seg, double oversample) {
  final df = 1.0 / seg / oversample;
  return freqGrid(lo, hi, ((hi - lo) / df).ceil() + 1);
}

// Laguna, Moody & Mark 1998 / Bigger 1992 HRV with Welch 1967 segmentation, as
// in hrvFreq(). Closed segments use the exact shared segment function; open data
// is evaluated provisionally with the same origin, grid and segment order.
/// Exact, append-only Welch state for [hrvFreq].
class HrvFreqStream {
  final double oversample;
  final List<double> _nn = [], _times = [];
  late final List<_HrvBandState> _bands;
  int _n = 0;
  double? _first, _last;

  HrvFreqStream({this.oversample = 4.0}) {
    _bands = [
      _HrvBandState(0.0003, 0.003, 0),
      _HrvBandState(0.003, 0.04, 0),
      _HrvBandState(0.04, 0.15, 0),
      _HrvBandState(0.15, 0.40, 0),
    ];
  }

  factory HrvFreqStream.fromJson(Map<String, dynamic> json) {
    try {
      final j = decodeMap(json);
      if (field(j, 'type') != 'HrvFreqStream') {
        throw const FormatException('not an HrvFreqStream checkpoint');
      }
      if (field(j, 'version') != 1) {
        throw const FormatException('unsupported HrvFreqStream version');
      }
      final oversample = decodeDouble(field(j, 'oversample'));
      final n = decodeCount(field(j, 'n'));
      final first = decodeDoubleOrNull(field(j, 'first'));
      final last = decodeDoubleOrNull(field(j, 'last'));
      final nn = decodeDoubles(field(j, 'nn'));
      final times = decodeDoubles(field(j, 'times'));
      final encodedBands = decodeList(field(j, 'bands'));
      if (encodedBands.length != 4 || nn.length != times.length ||
          !oversample.isFinite || oversample <= 0 ||
          (n == 0 && (first != null || last != null)) ||
          (n > 0 && (first == null || last == null))) {
        throw const FormatException('inconsistent HrvFreqStream checkpoint');
      }
      final s = HrvFreqStream(oversample: oversample)
        .._n = n
        .._first = first
        .._last = last
        .._nn.addAll(nn)
        .._times.addAll(times);
      if (!_nondecreasing(s._times)) {
        throw const FormatException('decreasing checkpoint times');
      }
      final configs = const [
        [0.0003, 0.003],
        [0.003, 0.04],
        [0.04, 0.15],
        [0.15, 0.40],
      ];
      s._bands.clear();
      for (var i = 0; i < configs.length; i++) {
        final b = decodeMap(encodedBands[i]);
        final next = decodeDouble(field(b, 'nextStart'));
        final sum = decodeDouble(field(b, 'sum'));
        final count = decodeCount(field(b, 'count'));
        s._bands.add(_HrvBandState(configs[i][0], configs[i][1], next,
            sum: sum, count: count));
      }
      return s;
    } on FormatException {
      rethrow;
    } catch (e) {
      throw FormatException('malformed HrvFreqStream checkpoint: $e');
    }
  }

  Map<String, dynamic> toJson() => {
        'type': 'HrvFreqStream',
        'version': 1,
        'oversample': encodeDouble(oversample),
        'n': _n,
        'first': _first == null ? null : encodeDouble(_first!),
        'last': _last == null ? null : encodeDouble(_last!),
        'nn': [for (final x in _nn) encodeDouble(x)],
        'times': [for (final x in _times) encodeDouble(x)],
        'bands': [for (final b in _bands) b.toJson()],
      };

  void fold(List<double> nnMs, List<double> nnTimesMs) {
    if (nnMs.length != nnTimesMs.length) {
      throw ArgumentError('nnMs and nnTimesMs must have the same length');
    }
    if (nnMs.isEmpty) return;
    final incoming = [for (final t in nnTimesMs) t / 1000.0];
    // Checked before any state changes: an infinite time would make the band
    // settle endless, and a fold cannot be undone.
    if (incoming.any((t) => !t.isFinite)) {
      throw ArgumentError('beat times must be finite');
    }
    if (!_nondecreasing(incoming) ||
        (_last != null && incoming.first < _last!)) {
      throw StateError('beat times must be non-decreasing');
    }
    if (_first == null) {
      _first = incoming.first;
      for (final b in _bands) {
        b.nextStart = _first!;
      }
    }
    _nn.addAll(nnMs);
    _times.addAll(incoming);
    _n += nnMs.length;
    _last = incoming.last;
    for (final b in _bands) {
      b.settle(_times, _nn, _last!, oversample);
    }
    _compact();
  }

  Metric<HrvFreq> snapshot({
    List<double> tailNnMs = const [],
    List<double> tailNnTimesMs = const [],
    required double artifactFraction,
    double hfArtifactGate = 0.15,
  }) {
    if (tailNnMs.length != tailNnTimesMs.length) {
      throw ArgumentError('tailNnMs and tailNnTimesMs must have the same length');
    }
    // A non-finite tail time: the batch's own answer (it abstains).
    if (_n + tailNnMs.length < 16 ||
        _first == null ||
        tailNnTimesMs.any((t) => !(t / 1000.0).isFinite)) {
      return hrvFreq([..._nn, ...tailNnMs],
          [..._times.map((x) => x * 1000.0), ...tailNnTimesMs],
          artifactFraction: artifactFraction,
          hfArtifactGate: hfArtifactGate,
          oversample: oversample);
    }
    final tail = [for (final t in tailNnTimesMs) t / 1000.0];
    if (!_nondecreasing(tail) || (tail.isNotEmpty && tail.first < _last!)) {
      throw StateError('beat times must be non-decreasing');
    }
    final times = [..._times, ...tail];
    final nn = [..._nn, ...tailNnMs];
    final last = times.last;
    if (last - _first! <= 0) {
      return hrvFreq(nn, [for (final t in times) t * 1000.0],
          artifactFraction: artifactFraction,
          hfArtifactGate: hfArtifactGate,
          oversample: oversample);
    }
    final powers = [
      for (final b in _bands) b.value(times, nn, last, oversample),
    ];
    return _hrvFreqMetric(powers[0], powers[1], powers[2], powers[3],
        artifactFraction: artifactFraction, hfArtifactGate: hfArtifactGate);
  }

  void _compact() {
    if (_times.isEmpty) return;
    var keepFrom = _bands.map((b) => b.nextStart).reduce((a, b) => a < b ? a : b);
    var cut = 0;
    while (cut < _times.length && _times[cut] < keepFrom) {
      cut++;
    }
    if (cut > 0) {
      _times.removeRange(0, cut);
      _nn.removeRange(0, cut);
    }
  }
}

bool _nondecreasing(List<double> values) {
  for (var i = 1; i < values.length; i++) {
    if (values[i] < values[i - 1]) return false;
  }
  return true;
}
