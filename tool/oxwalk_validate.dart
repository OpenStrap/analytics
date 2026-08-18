// VALIDATION HARNESS — score the SHIPPED pedometer against OxWalk, the first
// real annotated free-living wrist corpus this algorithm has ever met.
//
// OxWalk (Small, von Fritsch, Doherty, Khalid, Price; University of Oxford,
// Dec 2022, CC BY): 39 healthy adults, unscripted free living, Axivity AX3 on
// the DOMINANT WRIST and at the hip, 100 Hz and 25 Hz, ~1 h each. Ground truth
// is a synchronised foot-facing beltline camera annotated in ELAN — one `1` per
// heel strike, so the annotation column summed over a file IS that
// participant's true step count.
//
// It runs `pedometer()` — the real production entry point, not a copy — and it
// CHUNKS THE SIGNAL THE WAY PRODUCTION DOES. That is not a detail: `confirm=8`
// needs a contiguous run inside one buffer, so the fragment size dominates the
// answer. `AppState._ingestLiveMagsAt` accumulates `_magMin` and calls
// `pedometer` on each completed `_minuteSamples = 6000` (60 s @ 100 Hz) block,
// counting the trailing partial minute once at session end. This harness does
// exactly that (60 s of whatever the file's rate is), and prints the
// one-contiguous-buffer number as a separate line so the chunking cost is
// visible rather than hidden.
//
// The dataset is 290 MB and is NOT committed. Point the tool at an unpacked
// copy; the settled numbers are pinned as constants in
// test/onehz/steps_test.dart so a change that moves them fails loudly without
// anyone having to download anything.
//
// Usage:
//   dart run tool/oxwalk_validate.dart <path-to-OxWalk_Dec2022> [flags]
//   OXWALK_DIR=... dart run tool/oxwalk_validate.dart
//
//   --set=NAME     restrict to one dataset (repeatable).
//                  Default: Wrist_100Hz Wrist_25Hz Hip_100Hz Hip_25Hz
//   --chunk=N      override the chunk size in SAMPLES (default fs*60, which is
//                  production). Sweep it to see how much the per-minute reset
//                  is worth — on real data it is worth a great deal, in the
//                  opposite direction from the synthetic estimate.
//   --decimate=N   keep every Nth sample and score at fs/N, to find the rate
//                  cliff on real data. The live `0x33` stream's true frame rate
//                  is documented nowhere in the tree (STEPS_ALGO §5), so where
//                  this counter dies as a function of rate is a shipping fact,
//                  not a curiosity.
//   --baseline     also score a simple published-style wrist counter (VM peak
//                  detection + interval + periodicity gates) on the same
//                  signal, as a "is ours worth keeping" reference.
//
// The interval-guard ablation (StepParams.minStepIntervalS /
// maxStepIntervalS) is not a flag: those are compile-time constants on the
// shipped class, and adding an override to production code for a one-off
// ablation is worse than editing them locally for the run. Set them to
// 0.0 / 1e9, re-run, revert.

import 'dart:io';
import 'dart:math' as math;

import 'package:openstrap_analytics/onehz.dart';

const _sets = <String, double>{
  'Wrist_100Hz': 100,
  'Wrist_25Hz': 25,
  'Hip_100Hz': 100,
  'Hip_25Hz': 25,
};

class Row {
  final String pid;
  final String age;
  final int truth;
  final int chunked; // production per-minute chunking, RAW (pre-gain)
  final int oneShot; // one contiguous buffer, RAW
  Row(this.pid, this.age, this.truth, this.chunked, this.oneShot);
  double get pctErr => truth == 0 ? double.nan : (chunked - truth) / truth * 100;
  double get ratio => truth == 0 ? double.nan : chunked / truth;
}

void main(List<String> args) {
  final root = args.firstWhere((a) => !a.startsWith('--'),
      orElse: () => Platform.environment['OXWALK_DIR'] ?? '');
  if (root.isEmpty || !Directory(root).existsSync()) {
    stderr.writeln('''
OxWalk data not found.

  dart run tool/oxwalk_validate.dart <path-to-OxWalk_Dec2022>

Expects the unpacked OxWalk_Dec2022 directory (Wrist_100Hz/, Wrist_25Hz/,
Hip_100Hz/, Hip_25Hz/, metadata.csv). ~290 MB, deliberately NOT committed.
Download: Oxford Research Archive, OxWalk Annotated Step Count Dataset (CC BY).
''');
    exit(2);
  }
  final want = args
      .where((a) => a.startsWith('--set='))
      .map((a) => a.substring(6))
      .toList();
  final chunkArg = args.firstWhere((a) => a.startsWith('--chunk='),
      orElse: () => '');
  final chunkOverride =
      chunkArg.isEmpty ? null : int.parse(chunkArg.substring(8));
  final baseline = args.contains('--baseline');
  final decArg =
      args.firstWhere((a) => a.startsWith('--decimate='), orElse: () => '');
  final decimate = decArg.isEmpty ? 1 : int.parse(decArg.substring(11));

  final ages = _readMetadata(File('$root/metadata.csv'));

  for (final entry in _sets.entries) {
    if (want.isNotEmpty && !want.contains(entry.key)) continue;
    final dir = Directory('$root/${entry.key}');
    if (!dir.existsSync()) {
      stderr.writeln('skip ${entry.key}: not present');
      continue;
    }
    _runSet(entry.key, entry.value, dir, ages, chunkOverride, baseline,
        decimate);
  }
}

Map<String, String> _readMetadata(File f) {
  final out = <String, String>{};
  if (!f.existsSync()) return out;
  for (final line in f.readAsLinesSync().skip(1)) {
    final p = line.split(',');
    if (p.length >= 3) out[p[0].trim()] = p[2].trim();
  }
  return out;
}

void _runSet(String name, double fsIn, Directory dir, Map<String, String> ages,
    int? chunkOverride, bool baseline, int decimate) {
  final fs = fsIn / decimate;
  final chunk = chunkOverride ?? (fs * 60).round(); // production: 1 min
  final files = dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.csv'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  final rows = <Row>[];
  final base = <Row>[];
  for (final f in files) {
    final pid = f.uri.pathSegments.last.split('_').first;
    final (full, truth) = _load(f);
    final mag = decimate == 1
        ? full
        : [for (var i = 0; i < full.length; i += decimate) full[i]];
    if (mag.length < 2) continue;
    var raw = 0;
    for (var i = 0; i < mag.length; i += chunk) {
      final end = math.min(i + chunk, mag.length);
      raw += pedometer(mag.sublist(i, end), sampleRateHz: fs);
    }
    rows.add(Row(pid, ages[pid] ?? '?', truth, raw,
        pedometer(mag, sampleRateHz: fs)));
    if (baseline) {
      final b = _baselineSteps(mag, fs);
      base.add(Row(pid, ages[pid] ?? '?', truth, b, b));
    }
  }
  _report('$name (chunk=$chunk${decimate > 1 ? ', /$decimate' : ''})', fs, rows);
  if (baseline) _report('$name — BASELINE (VM peak detector)', fs, base);
}

/// A simple published-STYLE wrist step counter, for reference only.
///
/// Not the Verisense code and not a validated port of it — it is the shape the
/// literature's simple wrist counters share: smooth the vector magnitude, take
/// local maxima that clear an amplitude threshold, keep only those whose
/// inter-peak interval is physiological, and require a short run of
/// consistently-spaced peaks (the periodicity/continuity gate) before crediting
/// anything. It exists to answer one question — is the shipped counter better
/// or worse than the cheapest reasonable alternative on the same signal — and
/// it should not be quoted as "Verisense scored X".
int _baselineSteps(List<double> mag, double fs) {
  final n = mag.length;
  if (n < 4) return 0;
  // ~0.1 s moving average → attenuates above ~5 Hz, keeps gait's 1.4-2.3 Hz.
  final w = math.max(1, (fs * 0.1).round());
  final lp = List<double>.filled(n, 0);
  var acc = 0.0;
  for (var i = 0; i < n; i++) {
    acc += mag[i];
    if (i >= w) acc -= mag[i - w];
    lp[i] = acc / math.min(i + 1, w);
  }
  // Local maxima over ±0.2 s, at least 0.05 g above the surrounding trough.
  final half = math.max(1, (fs * 0.2).round());
  final peaks = <int>[];
  for (var i = half; i < n - half; i++) {
    final v = lp[i];
    var isMax = true;
    var mn = v;
    for (var j = i - half; j <= i + half; j++) {
      if (lp[j] > v) {
        isMax = false;
        break;
      }
      if (lp[j] < mn) mn = lp[j];
    }
    if (isMax && v - mn >= 0.05) peaks.add(i);
  }
  // Interval + periodicity: credit a peak only inside a run of >= 3 intervals
  // that are all physiological (0.25-2.0 s) and mutually consistent (each
  // within 40% of the previous), which is what separates gait from handling.
  var steps = 0, run = 0;
  double? prevGap;
  for (var k = 1; k < peaks.length; k++) {
    final gap = (peaks[k] - peaks[k - 1]) / fs;
    final ok = gap >= 0.25 &&
        gap <= 2.0 &&
        (prevGap == null || (gap - prevGap).abs() / prevGap <= 0.40);
    if (ok) {
      run++;
      if (run == 3) {
        steps += 4; // credit the run's peaks retroactively
      } else if (run > 3) {
        steps++;
      }
    } else {
      run = 0;
    }
    prevGap = gap >= 0.25 && gap <= 2.0 ? gap : null;
  }
  return steps;
}

/// Fast CSV read: `timestamp,x,y,z,annotation`. Returns |a| per sample (g,
/// gravity included — exactly what `pedometer` expects) and the true step count.
(List<double>, int) _load(File f) {
  final mag = <double>[];
  var truth = 0;
  var first = true;
  for (final line in f.readAsLinesSync()) {
    if (first) {
      first = false;
      continue;
    }
    if (line.isEmpty) continue;
    // Split from the right: 4 commas back from the end are x,y,z,annotation.
    final c4 = line.lastIndexOf(',');
    final c3 = line.lastIndexOf(',', c4 - 1);
    final c2 = line.lastIndexOf(',', c3 - 1);
    final c1 = line.lastIndexOf(',', c2 - 1);
    if (c1 < 0) continue;
    final x = double.parse(line.substring(c1 + 1, c2));
    final y = double.parse(line.substring(c2 + 1, c3));
    final z = double.parse(line.substring(c3 + 1, c4));
    mag.add(math.sqrt(x * x + y * y + z * z));
    if (line.codeUnitAt(c4 + 1) != 0x30) truth++; // annotation != '0'
  }
  return (mag, truth);
}

void _report(String name, double fs, List<Row> rows) {
  final b = StringBuffer();
  b.writeln('');
  b.writeln('═══ $name — n=${rows.length}, fs=${fs.toStringAsFixed(0)} Hz, '
      'chunk=${(fs * 60).round()} samples (production) ═══');
  b.writeln('pid    age     truth  chunked   err%   ratio   oneshot  1shot%');
  for (final r in rows) {
    b.writeln('${r.pid.padRight(6)} ${r.age.padRight(7)} '
        '${r.truth.toString().padLeft(5)} '
        '${r.chunked.toString().padLeft(7)} '
        '${r.pctErr.toStringAsFixed(1).padLeft(7)} '
        '${r.ratio.toStringAsFixed(3).padLeft(6)} '
        '${r.oneShot.toString().padLeft(8)} '
        '${(r.truth == 0 ? double.nan : (r.oneShot - r.truth) / r.truth * 100).toStringAsFixed(1).padLeft(7)}');
  }

  final errs = rows.map((r) => r.pctErr).where((e) => e.isFinite).toList();
  final diffs =
      rows.map((r) => (r.chunked - r.truth).toDouble()).toList(growable: false);
  final ratios = rows.map((r) => r.ratio).where((r) => r.isFinite).toList()
    ..sort();
  final totTruth = rows.fold<int>(0, (a, r) => a + r.truth);
  final totEst = rows.fold<int>(0, (a, r) => a + r.chunked);
  final totOne = rows.fold<int>(0, (a, r) => a + r.oneShot);

  final mape = _mean(errs.map((e) => e.abs()).toList());
  final bias = _mean(errs);
  final sdDiff = _sd(diffs);
  final mDiff = _mean(diffs);

  b.writeln('');
  b.writeln('MAPE            ${mape.toStringAsFixed(1)}%');
  b.writeln('bias (mean signed err) ${bias.toStringAsFixed(1)}%');
  b.writeln('median err%     ${_median(errs.toList()..sort()).toStringAsFixed(1)}%');
  b.writeln('err% range      ${errs.reduce(math.min).toStringAsFixed(1)} … '
      '${errs.reduce(math.max).toStringAsFixed(1)}');
  b.writeln('totals          truth=$totTruth chunked=$totEst '
      '(${((totEst - totTruth) / totTruth * 100).toStringAsFixed(1)}%) '
      'oneshot=$totOne '
      '(${((totOne - totTruth) / totTruth * 100).toStringAsFixed(1)}%)');
  b.writeln('chunking cost   ${((totEst - totOne) / totOne * 100).toStringAsFixed(1)}% '
      'vs one contiguous buffer');
  b.writeln('Bland-Altman    mean diff ${mDiff.toStringAsFixed(0)} steps, '
      'SD ${sdDiff.toStringAsFixed(0)}, LoA '
      '[${(mDiff - 1.96 * sdDiff).toStringAsFixed(0)}, '
      '${(mDiff + 1.96 * sdDiff).toStringAsFixed(0)}]');
  b.writeln('gain fits       total-ratio ${(totTruth / totEst).toStringAsFixed(3)}  '
      'median-of-ratios ${(1 / _median(ratios)).toStringAsFixed(3)}  '
      'ratio IQR [${_q(ratios, .25).toStringAsFixed(2)}, '
      '${_q(ratios, .75).toStringAsFixed(2)}]  '
      'ratio range [${ratios.first.toStringAsFixed(2)}, '
      '${ratios.last.toStringAsFixed(2)}]');
  // Does any single multiplier help? Sweep it against the same MAPE the
  // headline uses. If the error is not multiplicative this is flat and useless.
  var bestG = 1.0, bestM = double.infinity;
  for (var g = 0.20; g <= 3.001; g += 0.01) {
    final m = _mean(rows
        .where((r) => r.truth > 0)
        .map((r) => ((r.chunked * g - r.truth) / r.truth * 100).abs())
        .toList());
    if (m < bestM) {
      bestM = m;
      bestG = g;
    }
  }
  b.writeln('best gain       ${bestG.toStringAsFixed(2)} → MAPE '
      '${bestM.toStringAsFixed(1)}%  (gain 1.00 → ${mape.toStringAsFixed(1)}%)');

  // Age bands — slow walking is the documented wrist failure mode.
  final byAge = <String, List<Row>>{};
  for (final r in rows) {
    byAge.putIfAbsent(r.age, () => []).add(r);
  }
  final bands = byAge.keys.toList()..sort();
  for (final a in bands) {
    final e = byAge[a]!.map((r) => r.pctErr).where((v) => v.isFinite).toList();
    b.writeln('age $a       n=${e.length}  MAPE '
        '${_mean(e.map((v) => v.abs()).toList()).toStringAsFixed(1)}%  '
        'bias ${_mean(e).toStringAsFixed(1)}%  '
        'truth/h ${(_mean(byAge[a]!.map((r) => r.truth.toDouble()).toList())).toStringAsFixed(0)}');
  }
  stdout.write(b.toString());
}

double _mean(List<double> xs) =>
    xs.isEmpty ? double.nan : xs.reduce((a, b) => a + b) / xs.length;
double _sd(List<double> xs) {
  if (xs.length < 2) return double.nan;
  final m = _mean(xs);
  return math.sqrt(
      xs.map((v) => (v - m) * (v - m)).reduce((a, b) => a + b) / (xs.length - 1));
}

double _median(List<double> sorted) => _q(sorted, 0.5);

double _q(List<double> sorted, double p) {
  if (sorted.isEmpty) return double.nan;
  final i = p * (sorted.length - 1);
  final lo = i.floor(), hi = i.ceil();
  return sorted[lo] + (sorted[hi] - sorted[lo]) * (i - lo);
}
