// §HRV — heart-rate variability from beat-to-beat RR intervals. 1:1 port.
import 'dart:math' as math;
import 'util.dart';

const List<double> VLF_BAND = [0.0033, 0.04];
const List<double> LF_BAND = [0.04, 0.15];
const List<double> HF_BAND = [0.15, 0.4];

class TimeDomainHrv {
  final double? rmssd;
  final double? sdnn;
  final double? pnn50;
  final double? mean_rr;
  final double? mean_hr;
  final int n_beats;
  const TimeDomainHrv({
    required this.rmssd,
    required this.sdnn,
    required this.pnn50,
    required this.mean_rr,
    required this.mean_hr,
    required this.n_beats,
  });
}

class FreqDomainHrv {
  final double? lf;
  final double? hf;
  final double? lf_hf;
  final double? total_power;
  final double? resp_rate;
  final double resp_conf;
  const FreqDomainHrv({
    required this.lf,
    required this.hf,
    required this.lf_hf,
    required this.total_power,
    required this.resp_rate,
    required this.resp_conf,
  });
}

List<double> cleanRr(List<double> rr) {
  final physio = rr.where((x) => x >= 300 && x <= 2000).toList();
  if (physio.length < 2) return physio;
  final out = <double>[physio[0]];
  for (var i = 1; i < physio.length; i++) {
    if ((physio[i] - out[out.length - 1]).abs() <= 200) out.add(physio[i]);
  }
  return out;
}

TimeDomainHrv timeDomainHrv(List<double> rrRaw) {
  final rr = cleanRr(rrRaw);
  final n = rr.length;
  if (n < 20) {
    return TimeDomainHrv(
        rmssd: null,
        sdnn: null,
        pnn50: null,
        mean_rr: null,
        mean_hr: null,
        n_beats: n);
  }

  final meanRr = rr.fold<double>(0, (a, b) => a + b) / n;
  final varNn =
      rr.fold<double>(0, (a, b) => a + (b - meanRr) * (b - meanRr)) / (n - 1);
  final sdnn = math.sqrt(varNn);
  double sumSq = 0;
  int nn50 = 0;
  for (var i = 1; i < n; i++) {
    final d = rr[i] - rr[i - 1];
    sumSq += d * d;
    if (d.abs() > 50) nn50++;
  }
  final rmssd = math.sqrt(sumSq / (n - 1));
  final pnn50 = (nn50 / (n - 1)) * 100;

  return TimeDomainHrv(
    rmssd: round(rmssd, 1),
    sdnn: round(sdnn, 1),
    pnn50: round(pnn50, 1),
    mean_rr: round(meanRr, 1),
    mean_hr: round(60000 / meanRr, 1),
    n_beats: n,
  );
}

class _LsBand {
  final double power;
  final double peakFreq;
  final double peakPower;
  const _LsBand(this.power, this.peakFreq, this.peakPower);
}

_LsBand _lombScargleBand(
    List<double> t, List<double> x, double fLo, double fHi, double df) {
  double power = 0, peakPower = -1, peakFreq = 0;
  for (var f = fLo; f < fHi; f += df) {
    final w = 2 * math.pi * f;
    double s2 = 0, c2 = 0;
    for (final ti in t) {
      s2 += math.sin(2 * w * ti);
      c2 += math.cos(2 * w * ti);
    }
    final tau = math.atan2(s2, c2) / (2 * w);
    double xc = 0, xs = 0, cc = 0, ss = 0;
    for (var i = 0; i < t.length; i++) {
      final arg = w * (t[i] - tau);
      final cosv = math.cos(arg), sinv = math.sin(arg);
      xc += x[i] * cosv;
      xs += x[i] * sinv;
      cc += cosv * cosv;
      ss += sinv * sinv;
    }
    final p = 0.5 *
        ((cc > 0 ? (xc * xc) / cc : 0) + (ss > 0 ? (xs * xs) / ss : 0));
    power += p * df;
    if (p > peakPower) {
      peakPower = p;
      peakFreq = f;
    }
  }
  return _LsBand(power, peakFreq, peakPower);
}

FreqDomainHrv freqDomainHrv(List<double> rrRaw) {
  final rr = cleanRr(rrRaw);
  const none = FreqDomainHrv(
      lf: null,
      hf: null,
      lf_hf: null,
      total_power: null,
      resp_rate: null,
      resp_conf: 0);
  if (rr.length < 30) return none;

  final t = <double>[];
  double acc = 0;
  for (final r in rr) {
    acc += r / 1000;
    t.add(acc);
  }
  final mn = rr.fold<double>(0, (a, b) => a + b) / rr.length;
  final x = rr.map((r) => r - mn).toList();
  final span = t[t.length - 1] - t[0];
  if (span < 60) return none;
  const hfMinSpan = 60;
  const lfMinSpan = 250;
  const df = 0.005;

  final hfBand = _lombScargleBand(t, x, HF_BAND[0], HF_BAND[1], df);
  final lfValid = span >= lfMinSpan;
  final double? lf =
      lfValid ? _lombScargleBand(t, x, LF_BAND[0], LF_BAND[1], df).power : null;
  final double? vlf = lfValid
      ? _lombScargleBand(t, x, VLF_BAND[0], VLF_BAND[1], df).power
      : null;
  final double? total =
      (lf != null && vlf != null) ? vlf + lf + hfBand.power : null;

  final hfValid = span >= hfMinSpan;
  final meanHf = hfBand.power / ((HF_BAND[1] - HF_BAND[0]) / df);
  final prominence = meanHf > 0 ? hfBand.peakPower / meanHf : 0;
  final respConf =
      hfValid ? math.max(0.0, math.min(1.0, (prominence - 1) / 4)) : 0.0;
  final respRate = hfBand.peakFreq * 60;

  return FreqDomainHrv(
    lf: lf == null ? null : round(lf, 1),
    hf: round(hfBand.power, 1),
    lf_hf: (lf != null && hfBand.power > 0) ? round(lf / hfBand.power, 3) : null,
    total_power: total == null ? null : round(total, 1),
    resp_rate: respConf >= 0.3 ? round(respRate, 1) : null,
    resp_conf: round(respConf, 3),
  );
}

class BaevskyResult {
  final double? si;
  final double? sqrt_si;
  final int n_beats;
  const BaevskyResult(this.si, this.sqrt_si, this.n_beats);
}

BaevskyResult baevskyStressIndex(List<double> rrRaw) {
  final rr = cleanRr(rrRaw);
  if (rr.length < 30) return BaevskyResult(null, null, rr.length);
  const bin = 50;
  final bins = <double, int>{};
  double max = double.negativeInfinity, min = double.infinity;
  for (final r in rr) {
    final b = jsRound(r / bin) * bin;
    bins[b] = (bins[b] ?? 0) + 1;
    if (r > max) max = r;
    if (r < min) min = r;
  }
  double modeBin = 0;
  int modeCount = 0;
  for (final e in bins.entries) {
    if (e.value > modeCount) {
      modeCount = e.value;
      modeBin = e.key;
    }
  }
  final mo = modeBin / 1000;
  final aMo = (modeCount / rr.length) * 100;
  final mxDMn = (max - min) / 1000;
  if (mo <= 0 || mxDMn <= 0) return BaevskyResult(null, null, rr.length);
  final si = aMo / (2 * mo * mxDMn);
  return BaevskyResult(round(si, 1), round(math.sqrt(si), 2), rr.length);
}

class HrvStabilityResult {
  final double? cv;
  final double? mean_rmssd;
  final int n;
  final double confidence;
  final String tier;
  final List<String> inputs_used;
  const HrvStabilityResult({
    required this.cv,
    required this.mean_rmssd,
    required this.n,
    required this.confidence,
    required this.tier,
    required this.inputs_used,
  });
  Map<String, dynamic> toJson() => {
        'cv': cv,
        'mean_rmssd': mean_rmssd,
        'n': n,
        'confidence': confidence,
        'tier': tier,
        'inputs_used': inputs_used,
      };
}

HrvStabilityResult calcHrvStability(List<double> rmssdSeries) {
  final xs = rmssdSeries.where((x) => x > 0).toList();
  if (xs.length < 5) {
    return HrvStabilityResult(
      cv: null,
      mean_rmssd: null,
      n: xs.length,
      confidence: round(xs.length / 7, 3),
      tier: 'HIGH',
      inputs_used: const ['hrv_rmssd'],
    );
  }
  final m = mean(xs), sd = stddev(xs);
  return HrvStabilityResult(
    cv: m > 0 ? round((sd / m) * 100, 1) : null,
    mean_rmssd: round(m, 1),
    n: xs.length,
    confidence: round(math.min(1.0, xs.length / 14), 3),
    tier: 'HIGH',
    inputs_used: const ['hrv_rmssd'],
  );
}

class IrregularResult {
  final bool flag;
  final double? sd1;
  final double? sd2;
  final double? ratio;
  final double? pnn50;
  final double? ectopic_frac;
  final String note;
  final double confidence;
  final String tier;
  final List<String> inputs_used;
  const IrregularResult({
    required this.flag,
    required this.sd1,
    required this.sd2,
    required this.ratio,
    required this.pnn50,
    required this.ectopic_frac,
    required this.note,
    required this.confidence,
    required this.tier,
    required this.inputs_used,
  });
  Map<String, dynamic> toJson() => {
        'flag': flag,
        'sd1': sd1,
        'sd2': sd2,
        'ratio': ratio,
        'pnn50': pnn50,
        'ectopic_frac': ectopic_frac,
        'note': note,
        'confidence': confidence,
        'tier': tier,
        'inputs_used': inputs_used,
      };
}

IrregularResult calcIrregular(List<double> rrRaw) {
  const note = 'a screen, not a diagnosis';
  final physio = rrRaw.where((x) => x >= 300 && x <= 2000).toList();
  final cleaned = cleanRr(rrRaw);
  final td = timeDomainHrv(rrRaw);
  if (physio.length < 100 ||
      td.rmssd == null ||
      td.sdnn == null ||
      td.pnn50 == null) {
    return IrregularResult(
      flag: false,
      sd1: null,
      sd2: null,
      ratio: null,
      pnn50: td.pnn50,
      ectopic_frac: null,
      note: note,
      confidence: 0,
      tier: 'ESTIMATE',
      inputs_used: const [],
    );
  }
  final sd1 = td.rmssd! / math.sqrt2;
  final sd2 = math.sqrt(
      math.max(0.0, 2 * td.sdnn! * td.sdnn! - 0.5 * td.rmssd! * td.rmssd!));
  final double? ratio = sd2 > 0 ? sd1 / sd2 : null;
  final ectopicFrac =
      physio.isNotEmpty ? 1 - cleaned.length / physio.length : 0.0;
  final flag = ectopicFrac > 0.20 && td.pnn50! > 30 && sd1 > 60;
  return IrregularResult(
    flag: flag,
    sd1: round(sd1, 1),
    sd2: round(sd2, 1),
    ratio: ratio == null ? null : round(ratio, 2),
    pnn50: td.pnn50,
    ectopic_frac: round(ectopicFrac, 3),
    note: note,
    confidence: round(math.min(1.0, physio.length / 300), 3),
    tier: 'ESTIMATE',
    inputs_used: const ['rr_intervals'],
  );
}

class DaytimeHrvResult {
  final double? rmssd_median;
  final List<Map<String, dynamic>> series;
  final double? lowest_ts;
  final int n_windows;
  final double confidence;
  final String tier;
  final List<String> inputs_used;
  const DaytimeHrvResult({
    required this.rmssd_median,
    required this.series,
    required this.lowest_ts,
    required this.n_windows,
    required this.confidence,
    required this.tier,
    required this.inputs_used,
  });
  Map<String, dynamic> toJson() => {
        'rmssd_median': rmssd_median,
        'series': series,
        'lowest_ts': lowest_ts,
        'n_windows': n_windows,
        'confidence': confidence,
        'tier': tier,
        'inputs_used': inputs_used,
      };
}

class RrByMinute {
  final double ts;
  final List<double> rr;
  const RrByMinute(this.ts, this.rr);
}

DaytimeHrvResult calcDaytimeHrv(List<RrByMinute> byMinute,
    [int bucketSec = 300]) {
  final buckets = <int, _Bucket>{};
  for (final m in byMinute) {
    if (m.rr.isEmpty) continue;
    final key = (m.ts / bucketSec).floor();
    final b = buckets[key] ?? _Bucket((key * bucketSec).toDouble(), []);
    for (final v in m.rr) {
      b.rr.add(v);
    }
    buckets[key] = b;
  }
  final series = <Map<String, dynamic>>[];
  final ordered = buckets.values.toList()..sort((a, c) => a.ts.compareTo(c.ts));
  for (final b in ordered) {
    final td = timeDomainHrv(b.rr);
    if (td.rmssd != null) series.add({'ts': b.ts, 'rmssd': td.rmssd});
  }
  if (series.length < 3) {
    return DaytimeHrvResult(
      rmssd_median: null,
      series: series,
      lowest_ts: null,
      n_windows: series.length,
      confidence: 0,
      tier: 'HIGH',
      inputs_used: const ['rr_intervals'],
    );
  }
  final vals = series.map((s) => s['rmssd'] as double).toList();
  var lowest = series[0];
  for (final s in series) {
    if ((s['rmssd'] as double) < (lowest['rmssd'] as double)) lowest = s;
  }
  return DaytimeHrvResult(
    rmssd_median: round(median(vals) ?? 0, 1),
    series: series,
    lowest_ts: lowest['ts'] as double,
    n_windows: series.length,
    confidence: round(math.min(1.0, series.length / 24), 3),
    tier: 'HIGH',
    inputs_used: const ['rr_intervals'],
  );
}

class _Bucket {
  final double ts;
  final List<double> rr;
  _Bucket(this.ts, this.rr);
}
