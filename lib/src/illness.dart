// §Illness — multivariate under-recovery / illness signal (Mahalanobis).
import 'dart:math' as math;
import 'types.dart';
import 'util.dart';

class IllnessToday {
  final double? resting_hr;
  final double? rmssd;
  final double? skin_temp;
  final double? resp_rate;
  const IllnessToday({
    this.resting_hr,
    this.rmssd,
    this.skin_temp,
    this.resp_rate,
  });
}

class IllnessHistory {
  final List<double> resting_hr;
  final List<double> rmssd;
  final List<double> skin_temp;
  final List<double>? resp_rate;
  const IllnessHistory({
    required this.resting_hr,
    required this.rmssd,
    required this.skin_temp,
    this.resp_rate,
  });
}

class IllnessResult {
  final bool signal;
  final double? distance;
  final List<String> triggers;
  final String note;
  final double confidence;
  final String tier;
  final List<String> inputs_used;
  final List<Driver>? drivers;
  const IllnessResult({
    required this.signal,
    required this.distance,
    required this.triggers,
    required this.note,
    required this.confidence,
    required this.tier,
    required this.inputs_used,
    this.drivers,
  });
  Map<String, dynamic> toJson() {
    final m = <String, dynamic>{
      'signal': signal,
      'distance': distance,
      'triggers': triggers,
      'note': note,
      'confidence': confidence,
      'tier': tier,
      'inputs_used': inputs_used,
    };
    if (drivers != null) m['drivers'] = drivers!.map((d) => d.toJson()).toList();
    return m;
  }
}

List<List<double>>? _invMatrix(List<List<double>> m) {
  final n = m.length;
  final a = List.generate(
      n,
      (i) => [
            ...m[i],
            ...List.generate(n, (j) => i == j ? 1.0 : 0.0),
          ]);
  for (var col = 0; col < n; col++) {
    var piv = col;
    for (var r = col + 1; r < n; r++) {
      if (a[r][col].abs() > a[piv][col].abs()) piv = r;
    }
    if (a[piv][col].abs() < 1e-12) return null;
    final tmp = a[col];
    a[col] = a[piv];
    a[piv] = tmp;
    final d = a[col][col];
    for (var j = 0; j < 2 * n; j++) {
      a[col][j] /= d;
    }
    for (var r = 0; r < n; r++) {
      if (r == col) continue;
      final f = a[r][col];
      for (var j = 0; j < 2 * n; j++) {
        a[r][j] -= f * a[col][j];
      }
    }
  }
  return a.map((row) => row.sublist(n)).toList();
}

const _cycleExpected = {'rhr', 'temp'};

class _Feat {
  final String key;
  final String label;
  final double today;
  final List<double> hist;
  final int dir;
  _Feat(this.key, this.label, this.today, this.hist, this.dir);
}

IllnessResult calcIllness(IllnessToday today, IllnessHistory history,
    {String? cyclePhase}) {
  const note = 'a signal, not a diagnosis';
  final cand = <_Feat>[];
  if (today.resting_hr != null && history.resting_hr.length >= 7) {
    cand.add(_Feat('rhr', 'Resting HR', today.resting_hr!, history.resting_hr, 1));
  }
  if (today.rmssd != null && history.rmssd.length >= 7) {
    cand.add(_Feat('rmssd', 'HRV (RMSSD)', today.rmssd!, history.rmssd, -1));
  }
  if (today.skin_temp != null && history.skin_temp.length >= 7) {
    cand.add(_Feat(
        'temp', 'Skin temperature', today.skin_temp!, history.skin_temp, 1));
  }
  if (today.resp_rate != null && (history.resp_rate?.length ?? 0) >= 7) {
    cand.add(_Feat(
        'resp', 'Respiratory rate', today.resp_rate!, history.resp_rate!, 1));
  }

  IllnessResult none() => const IllnessResult(
        signal: false,
        distance: null,
        triggers: [],
        note: note,
        confidence: 0,
        tier: 'ESTIMATE',
        inputs_used: [],
      );
  if (cand.length < 2) return none();

  final z = cand.map((f) {
    final mu = mean(f.hist), sd = stddev(f.hist);
    return sd > 0 ? f.dir * (f.today - mu) / sd : 0.0;
  }).toList();

  final lens = cand.map((f) => f.hist.length).toList();
  final minLen = lens.reduce(math.min);
  double distance;
  final drivers = <Driver>[];
  final dim = cand.length;
  final dvec = z;
  if (dim >= 2 && minLen >= 7) {
    final tail = cand
        .map((f) => f.hist.sublist(f.hist.length - minLen))
        .toList();
    final stds = tail.map((h) {
      final s = stddev(h);
      return _MuSd(mean(h), s == 0 ? 1 : s);
    }).toList();
    final Z = <List<double>>[];
    for (var k = 0; k < tail.length; k++) {
      Z.add(tail[k].map((v) => (v - stds[k].mu) / stds[k].sd).toList());
    }
    final corr = <List<double>>[];
    for (var a = 0; a < dim; a++) {
      corr.add([]);
      for (var b = 0; b < dim; b++) {
        double s = 0;
        for (var t = 0; t < minLen; t++) {
          s += Z[a][t] * Z[b][t];
        }
        corr[a].add(s / (minLen - 1));
      }
    }
    final inv = _invMatrix(corr);
    if (inv != null) {
      double d2 = 0;
      for (var a = 0; a < dim; a++) {
        for (var b = 0; b < dim; b++) {
          d2 += dvec[a] * inv[a][b] * dvec[b];
        }
      }
      distance = math.sqrt(math.max(0, d2));
    } else {
      distance = math.sqrt(dvec.fold<double>(0, (s, v) => s + v * v));
    }
  } else {
    distance = math.sqrt(dvec.fold<double>(0, (s, v) => s + v * v));
  }

  String metricFor(String key) => key == 'rmssd'
      ? 'hrv'
      : key == 'rhr'
          ? 'rhr'
          : key == 'resp'
              ? 'resp'
              : 'temp';
  String inputName(String key) => key == 'rmssd'
      ? 'hrv_rmssd'
      : key == 'rhr'
          ? 'resting_hr'
          : key == 'resp'
              ? 'resp_rate'
              : 'skin_temp';

  final triggers = <String>[];
  for (var k = 0; k < cand.length; k++) {
    final f = cand[k];
    if (z[k] > 0.75) {
      triggers.add(f.key);
      drivers.add(Driver(
        label: f.label,
        contribution: round(z[k], 2),
        detail: '${round(z[k], 1)}σ toward illness',
        ref: MetricRef(metric: metricFor(f.key), scale: 'day'),
      ));
    }
  }

  bool signal = distance > 2.5 && triggers.length >= 2;
  String noteOut = note;
  final inCyclePhase =
      cyclePhase == 'luteal' || cyclePhase == 'menstruation';
  if (signal && inCyclePhase) {
    final corroborating =
        triggers.where((t) => !_cycleExpected.contains(t)).toList();
    if (corroborating.isEmpty) {
      signal = false;
      noteOut =
          '$note (a rise in temperature & resting HR can be expected in this phase of your cycle)';
    }
  }
  final confidence = math.min(0.6, (minLen / 30) * (cand.length / 4));

  return IllnessResult(
    signal: signal,
    distance: round(distance, 2),
    triggers: triggers,
    note: noteOut,
    confidence: round(confidence, 4),
    tier: 'ESTIMATE',
    inputs_used: cand.map((f) => inputName(f.key)).toList(),
    drivers: drivers,
  );
}

class _MuSd {
  final double mu;
  final double sd;
  _MuSd(this.mu, this.sd);
}
