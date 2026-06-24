// §HAR — Human Activity Recognition from wrist accelerometer windows (Mannini 2013).
import 'dart:math' as math;
import 'dart:typed_data';
import 'util.dart';

class HarFeatures {
  final double smv_mean;
  final double smv_std;
  final double smv_min;
  final double smv_max;
  final double total_power;
  final double dom1_freq;
  final double dom1_pow;
  final double dom2_freq;
  final double dom2_pow;
  final double cad_freq;
  final double cad_pow;
  final double dom1_ratio;
  final double freq_ratio_prev;
  final double wav_e5;
  final double wav_e6;
  const HarFeatures({
    required this.smv_mean,
    required this.smv_std,
    required this.smv_min,
    required this.smv_max,
    required this.total_power,
    required this.dom1_freq,
    required this.dom1_pow,
    required this.dom2_freq,
    required this.dom2_pow,
    required this.cad_freq,
    required this.cad_pow,
    required this.dom1_ratio,
    required this.freq_ratio_prev,
    required this.wav_e5,
    required this.wav_e6,
  });
}

const List<double> DB10_LO = [
  2.667005790055555358661744877130858277192498290851289932779975e-02,
  1.881768000776914890208929736790939942702546758640393484348595e-01,
  5.272011889317255864817448279595081924981402680840223445318549e-01,
  6.884590394536035657418717825492358539771364042407339537279681e-01,
  2.811723436605774607487269984455892876243888859026150413831543e-01,
  -2.498464243273153794161018979207791000564669737132073715013121e-01,
  -1.959462743773770435042992543190981318766776476382778474396781e-01,
  1.273693403357932600826772332014009770786177480422245995563097e-01,
  9.305736460357235116035228983545273226942917998946925868063974e-02,
  -7.139414716639708714533609307605064767292611983702150917523756e-02,
  -2.945753682187581285828323760141839199388200516064948779769654e-02,
  3.321267405934100173976365318215912897978337413267096043323351e-02,
  3.606553566956169655423291417133403299517350518618994762730612e-03,
  -1.073317548333057504431811410651364448111548781143923213370333e-02,
  1.395351747052901165789318447957707567660542855688552426721117e-03,
  1.992405295185056117158742242640643211762555365514105280067936e-03,
  -6.858566949597116265613709819265714196625043336786920516211903e-04,
  -1.164668551292854509514809710258991891527461854347597362819235e-04,
  9.358867032006959133405013034222854399688456215297276443521873e-05,
  -1.326420289452124481243667531226683305749240960605829756400674e-05,
];

List<double> _db10Hi() {
  final n = DB10_LO.length;
  return List<double>.generate(
      n, (k) => (k % 2 == 0 ? 1 : -1) * DB10_LO[n - 1 - k]);
}

final List<double> DB10_HI = _db10Hi();

class _Dwt {
  final List<double> a;
  final List<double> d;
  _Dwt(this.a, this.d);
}

_Dwt _dwtStep(List<double> sig, List<double> lo, List<double> hi) {
  final n = sig.length, l = lo.length;
  final half = n ~/ 2;
  final a = List<double>.filled(half, 0);
  final d = List<double>.filled(half, 0);
  for (var i = 0; i < half; i++) {
    double sa = 0, sd = 0;
    for (var k = 0; k < l; k++) {
      final idx = (2 * i + k) % n;
      sa += lo[k] * sig[idx];
      sd += hi[k] * sig[idx];
    }
    a[i] = sa;
    d[i] = sd;
  }
  return _Dwt(a, d);
}

List<double> dwtDetailEnergies(List<double> signal, int levels) {
  var a = [...signal];
  final out = <double>[];
  for (var lvl = 1; lvl <= levels; lvl++) {
    if (a.length < 2) {
      out.add(0);
      continue;
    }
    final r = _dwtStep(a, DB10_LO, DB10_HI);
    out.add(r.d.fold<double>(0, (s, v) => s + v * v));
    a = r.a;
  }
  return out;
}

List<double> _biquadLP(List<double> sig, double fs, double fc, double q) {
  final w0 = (2 * math.pi * fc) / fs;
  final cosw = math.cos(w0), sinw = math.sin(w0);
  final alpha = sinw / (2 * q);
  final a0 = 1 + alpha;
  final b0 = ((1 - cosw) / 2) / a0,
      b1 = (1 - cosw) / a0,
      b2 = ((1 - cosw) / 2) / a0;
  final a1 = (-2 * cosw) / a0, a2 = (1 - alpha) / a0;
  final out = List<double>.filled(sig.length, 0);
  final s0 = sig.isNotEmpty ? sig[0] : 0.0;
  double x1 = s0, x2 = s0, y1 = s0, y2 = s0;
  for (var i = 0; i < sig.length; i++) {
    final x0 = sig[i];
    final y0 = b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2;
    x2 = x1;
    x1 = x0;
    y2 = y1;
    y1 = y0;
    out[i] = y0;
  }
  return out;
}

List<double> _butterLP4(List<double> sig, double fs, [double fc = 15]) {
  return _biquadLP(_biquadLP(sig, fs, fc, 0.54119610), fs, fc, 1.30656296);
}

int _nextPow2(int n) {
  var p = 1;
  while (p < n) {
    p <<= 1;
  }
  return p;
}

List<double> _powerSpectrum(List<double> sig) {
  final N = _nextPow2(sig.length);
  final re = Float64List(N), im = Float64List(N);
  for (var i = 0; i < sig.length; i++) {
    re[i] = sig[i];
  }
  for (var i = 1, j = 0; i < N; i++) {
    var bit = N >> 1;
    for (; j & bit != 0; bit >>= 1) {
      j ^= bit;
    }
    j ^= bit;
    if (i < j) {
      final tr = re[i];
      re[i] = re[j];
      re[j] = tr;
      final ti = im[i];
      im[i] = im[j];
      im[j] = ti;
    }
  }
  for (var len = 2; len <= N; len <<= 1) {
    final ang = (-2 * math.pi) / len;
    final wr = math.cos(ang), wi = math.sin(ang);
    for (var i = 0; i < N; i += len) {
      double cr = 1, ci = 0;
      for (var k = 0; k < len ~/ 2; k++) {
        final ur = re[i + k], ui = im[i + k];
        final vr = re[i + k + len ~/ 2] * cr - im[i + k + len ~/ 2] * ci;
        final vi = re[i + k + len ~/ 2] * ci + im[i + k + len ~/ 2] * cr;
        re[i + k] = ur + vr;
        im[i + k] = ui + vi;
        re[i + k + len ~/ 2] = ur - vr;
        im[i + k + len ~/ 2] = ui - vi;
        final ncr = cr * wr - ci * wi;
        ci = cr * wi + ci * wr;
        cr = ncr;
      }
    }
  }
  final half = N ~/ 2;
  final pow = List<double>.filled(half + 1, 0);
  for (var i = 0; i <= half; i++) {
    pow[i] = (re[i] * re[i] + im[i] * im[i]) / N;
  }
  return pow;
}

HarFeatures extractHarFeaturesFromSmv(List<double> smvRaw, double fs,
    [double prevDomFreq = 0]) {
  final smv = _butterLP4(smvRaw, fs);
  final smvMean = mean(smv), smvStd = stddev(smv);
  final smvMin = smv.reduce(math.min), smvMax = smv.reduce(math.max);

  final ac = smv.map((v) => v - smvMean).toList();
  final pow = _powerSpectrum(ac);
  final N = _nextPow2(ac.length);
  final binHz = fs / N;
  int idxOf(double f) => jsRound(f / binHz).toInt();
  final loBin = math.max(1, idxOf(0.3)),
      hiBin = math.min(pow.length - 1, idxOf(15));
  double total = 0;
  for (var i = loBin; i <= hiBin; i++) {
    total += pow[i];
  }

  var d1i = loBin, d2i = loBin;
  for (var i = loBin; i <= hiBin; i++) {
    if (pow[i] > pow[d1i]) d1i = i;
  }
  for (var i = loBin; i <= hiBin; i++) {
    if (i != d1i && pow[i] > pow[d2i]) d2i = i;
  }
  final cLo = math.max(1, idxOf(0.6)),
      cHi = math.min(pow.length - 1, idxOf(2.5));
  var ci = cLo;
  for (var i = cLo; i <= cHi; i++) {
    if (pow[i] > pow[ci]) ci = i;
  }

  final dom1Freq = d1i * binHz, dom1Pow = pow[d1i];
  final wav = dwtDetailEnergies(smv, 6);

  return HarFeatures(
    smv_mean: smvMean,
    smv_std: smvStd,
    smv_min: smvMin,
    smv_max: smvMax,
    total_power: total,
    dom1_freq: dom1Freq,
    dom1_pow: dom1Pow,
    dom2_freq: d2i * binHz,
    dom2_pow: pow[d2i],
    cad_freq: ci * binHz,
    cad_pow: pow[ci],
    dom1_ratio: total > 0 ? dom1Pow / total : 0,
    freq_ratio_prev: prevDomFreq > 0 ? dom1Freq / prevDomFreq : 1,
    wav_e5: wav.length > 4 ? wav[4] : 0,
    wav_e6: wav.length > 5 ? wav[5] : 0,
  );
}

HarFeatures extractHarFeatures(
    List<double> x, List<double> y, List<double> z, double fs,
    [double prevDomFreq = 0]) {
  final n = math.min(x.length, math.min(y.length, z.length));
  final smvRaw = List<double>.filled(n, 0);
  for (var i = 0; i < n; i++) {
    smvRaw[i] = math.sqrt(x[i] * x[i] + y[i] * y[i] + z[i] * z[i]);
  }
  return extractHarFeaturesFromSmv(smvRaw, fs, prevDomFreq);
}

const _sedPower = 0.02;
const _sedStd = 0.04;
const _periodic = 0.25;
const _runHz = 2.4;
const _walkHz = 1.3;
const _cycleHzLo = 0.6;

class ClassifyResult {
  final String cls;
  final double confidence;
  const ClassifyResult(this.cls, this.confidence);
}

ClassifyResult classifyActivityWindow(HarFeatures f) {
  if (f.total_power < _sedPower && f.smv_std < _sedStd) {
    return const ClassifyResult('sedentary', 0.6);
  }
  final periodic = f.dom1_ratio >= _periodic;
  final peakConf = math.min(0.9, 0.4 + f.dom1_ratio);
  final cad = f.dom1_freq;

  if (periodic) {
    if (cad >= _runHz) return ClassifyResult('run', peakConf);
    if (cad >= _walkHz) return ClassifyResult('walk', peakConf);
    if (cad >= _cycleHzLo && f.smv_std < _sedStd * 4) {
      return ClassifyResult('cycle', peakConf * 0.9);
    }
  }
  if (f.smv_std >= _sedStd && !periodic) {
    return const ClassifyResult('lift', 0.45);
  }
  return const ClassifyResult('other', 0.4);
}

class ClassVote {
  final double ts;
  final String cls;
  final double conf;
  const ClassVote(this.ts, this.cls, this.conf);
}

class WorkoutSegment {
  double start_ts;
  double end_ts;
  String type;
  double confidence;
  WorkoutSegment(this.start_ts, this.end_ts, this.type, this.confidence);
  Map<String, dynamic> toJson() => {
        'start_ts': start_ts,
        'end_ts': end_ts,
        'type': type,
        'confidence': confidence,
      };
}

class SegmentResult {
  final String primary;
  final List<WorkoutSegment> segments;
  final double type_confidence;
  const SegmentResult(this.primary, this.segments, this.type_confidence);
}

String _modeClass(List<ClassVote> window) {
  final c = <String, int>{};
  for (final v in window) {
    c[v.cls] = (c[v.cls] ?? 0) + 1;
  }
  String best = window[0].cls;
  int bestN = -1;
  for (final k in c.keys) {
    if (c[k]! > bestN) {
      bestN = c[k]!;
      best = k;
    }
  }
  return best;
}

SegmentResult segmentWorkout(List<ClassVote> votes,
    {int? smoothWin, int? minPhaseSec}) {
  final sw = smoothWin ?? 7;
  final mps = minPhaseSec ?? 180;
  if (votes.isEmpty) return const SegmentResult('other', [], 0);
  final sorted = [...votes]..sort((a, b) => a.ts.compareTo(b.ts));

  final smoothed = <ClassVote>[];
  for (var i = 0; i < sorted.length; i++) {
    final v = sorted[i];
    final half = sw ~/ 2;
    final win = sorted.sublist(
        math.max(0, i - half), math.min(sorted.length, i + half + 1));
    smoothed.add(ClassVote(v.ts, _modeClass(win), v.conf));
  }

  final raw = <WorkoutSegment>[];
  for (final v in smoothed) {
    final last = raw.isNotEmpty ? raw[raw.length - 1] : null;
    if (last != null && last.type == v.cls) {
      last.end_ts = v.ts;
      last.confidence = (last.confidence + v.conf) / 2;
    } else {
      raw.add(WorkoutSegment(v.ts, v.ts, v.cls, v.conf));
    }
  }

  final phases = <WorkoutSegment>[];
  for (final seg in raw) {
    final dur = seg.end_ts - seg.start_ts;
    if (dur < mps && phases.isNotEmpty) {
      phases[phases.length - 1].end_ts = seg.end_ts;
    } else if (dur < mps && phases.isEmpty) {
      phases.add(WorkoutSegment(
          seg.start_ts, seg.end_ts, seg.type, seg.confidence));
    } else {
      if (phases.isNotEmpty && phases[phases.length - 1].type == seg.type) {
        phases[phases.length - 1].end_ts = seg.end_ts;
      } else {
        phases.add(WorkoutSegment(
            seg.start_ts, seg.end_ts, seg.type, seg.confidence));
      }
    }
  }

  final totalDurRaw =
      phases.fold<double>(0, (s, p) => s + (p.end_ts - p.start_ts));
  final totalDur = totalDurRaw == 0 ? 1.0 : totalDurRaw;
  var top = phases[0];
  for (final p in phases) {
    if ((p.end_ts - p.start_ts) > (top.end_ts - top.start_ts)) top = p;
  }
  final topShare = (top.end_ts - top.start_ts) / totalDur;
  final primary = topShare >= 0.5 ? top.type : 'other';
  final typeConfidence = jsRound(top.confidence * topShare * 100) / 100;

  return SegmentResult(primary, phases, typeConfidence);
}
