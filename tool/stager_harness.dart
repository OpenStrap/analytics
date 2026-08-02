// VALIDATION HARNESS — score the SHIPPED staging decision layer against an
// external PSG-labelled corpus.
//
// Runs `classifyCardioEpochs` (the real production rules, not a
// reimplementation) over per-epoch features exported from a labelled dataset,
// and reports the metrics the literature says you must report:
//
//   * Cohen's kappa, not accuracy. Canton 2026 (Sleep Adv, PMID 42333378)
//     showed a trivial "easy-to-classify wake" baseline explains much of the
//     reported performance of published models, and that wake-rich datasets
//     inflate accuracy. A majority-class baseline is printed alongside so the
//     number can be read honestly.
//   * PER-CLASS sensitivity AND PPV. Fonseca 2018 (PMID 29620019) found a
//     temporal model traded 8 pp of N3 recall for 13 pp of N3 precision — a
//     single figure hides exactly the tradeoff we care about.
//   * The PER-SUBJECT kappa distribution, not just the pooled value. Radha
//     2019 (PMID 31578345) reports kappa 0.61 +- 0.15 over 292 subjects; the
//     SD is the whole story for "works for most, awful for a few", and the
//     count below kappa 0.2 is the population we are trying to serve better.
//
// CAVEAT, and it is a real one: the fixture supplies the dataset's OWN feature
// extraction (window lengths, artifact handling, sensor), not ours. What this
// scores is the DECISION LAYER. A change that improves the rules here should
// improve them on our device only insofar as our features carry the same
// information — which is itself an assumption worth stating out loud.
//
// Usage:
//   dart run tool/stager_harness.dart <fixture.json> [--profile]
//
// Fixture: {"epochSec": 30, "subjects": [{"subject", "stages":[..],
//           "motion":[..], "hr":[..], "hrSd":[..], "rmssd":[..],
//           "lfhf":[..], "rk":[..]}]}  — null means "not measurable".

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:openstrap_analytics/onehz.dart';

/// 4-class labels, in the order used for the confusion matrix.
const kClasses = ['Wake', 'Light', 'Deep', 'REM'];

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run tool/stager_harness.dart <fixture.json>');
    exitCode = 64;
    return;
  }
  final fixture =
      jsonDecode(File(args.first).readAsStringSync()) as Map<String, dynamic>;
  final epochSec = (fixture['epochSec'] as num?)?.toInt() ?? 30;
  var subjects = (fixture['subjects'] as List).cast<Map<String, dynamic>>();

  // In production `cardioStager` never sees a whole recording: it is handed a
  // window that van Hees + AdvancedSleepStager.detectSleep have already picked
  // out, so its baselines (`stillCut`, the local sleeping-HR median, the RMSSD
  // reference) are estimated over mostly-sleep epochs. Scoring it over a full
  // record including a long pre-sleep wake block is therefore a domain
  // mismatch that flatters nothing and blames the rules for a windowing job
  // they do not do. `--sleep-window` trims each subject to
  // [first non-Wake, last non-Wake], the closest stand-in for the in-bed window
  // that the reference labels can give us.
  if (args.contains('--sleep-window')) {
    subjects = [
      for (final s in subjects)
        if (_trimToSleepPeriod(s) case final t?) t
    ];
    stdout.writeln('[--sleep-window] trimmed each subject to '
        '[first sleep, last sleep]');
  }

  // CALIBRATION PROTOCOL. Any cutoff chosen by looking at the data must be
  // reported on subjects that were not looked at. Subjects are partitioned by a
  // deterministic hash of the subject id — not by index, which would correlate
  // with whatever order the source file happened to be in — into a DEV half a
  // cutoff may be swept on and a HOLDOUT half it may not.
  if (args.contains('--sweep')) {
    _sweep(subjects, epochSec);
    return;
  }
  double argOf(String name, double dflt) {
    final i = args.indexOf(name);
    return (i >= 0 && i + 1 < args.length)
        ? (double.tryParse(args[i + 1]) ?? dflt)
        : dflt;
  }

  final remCut = argOf('--rem-cut', 0.3);
  final deepCut = argOf('--deep-cut', 0.3);
  if (args.contains('--deep-curve')) {
    stdout.writeln('deepCut   %Deep called   Deep sens   Deep PPV   kappa');
    for (final d in [0.0, 0.2, 0.3, 0.4, 0.6, 0.8, 1.0]) {
      final m = _deepMetrics(subjects, epochSec, remCut, d);
      stdout.writeln('  ${d.toStringAsFixed(1)}       '
          '${(100 * m.$1).toStringAsFixed(1).padLeft(5)}%       '
          '${(100 * m.$2).toStringAsFixed(1).padLeft(5)}%     '
          '${(100 * m.$3).toStringAsFixed(1).padLeft(5)}%    '
          '${m.$4.toStringAsFixed(3)}');
    }
    return;
  }

  final split = args.contains('--dev')
      ? _Split.dev
      : args.contains('--holdout')
          ? _Split.holdout
          : _Split.all;
  if (split != _Split.all) {
    subjects = [
      for (final s in subjects)
        if (_splitOf(s['subject'] as String) == split) s
    ];
    stdout.writeln('[${split.name}] ${subjects.length} subjects');
  }

  final truth = <int>[];
  final pred = <int>[];
  final perSubjectKappa = <double>[];

  for (var si = 0; si < subjects.length; si++) {
    final s = subjects[si];
    final stages = (s['stages'] as List).cast<String>();
    final res = classifyCardioEpochs(_featuresOf(s),
        epochSec: epochSec, remScoreCut: remCut, deepScoreCut: deepCut);
    final out = res.base.stages;
    if (out.isEmpty) continue; // honest abstain — excluded, and counted below

    final t = <int>[], p = <int>[];
    for (var e = 0; e < out.length && e < stages.length; e++) {
      final ti = kClasses.indexOf(stages[e]);
      if (ti < 0) continue;
      // Map our 3-class + deep flag onto the 4-class reference.
      final pi = switch (out[e]) {
        SleepStage.wake => 0,
        SleepStage.rem => 3,
        SleepStage.nrem =>
          (e < res.deepFlag.length && res.deepFlag[e]) ? 2 : 1,
      };
      t.add(ti);
      p.add(pi);
    }
    if (t.length < 30) continue;
    truth.addAll(t);
    pred.addAll(p);
    final k = _kappa(t, p);
    if (!k.isNaN) perSubjectKappa.add(k);
  }

  final abstained = subjects.length - perSubjectKappa.length;
  stdout.writeln('subjects scored ${perSubjectKappa.length}'
      '${abstained > 0 ? '  (abstained/too short: $abstained)' : ''}'
      '   epochs ${truth.length}');
  stdout.writeln('');

  // Trivial baselines — Canton 2026.
  final counts = List<int>.filled(4, 0);
  for (final t in truth) {
    counts[t]++;
  }
  final majority =
      counts.indexOf(counts.reduce((a, b) => a > b ? a : b));
  _report('BASELINE all-${kClasses[majority]}', truth,
      List<int>.filled(truth.length, majority));
  _report('SHIPPED classifyCardioEpochs', truth, pred);

  perSubjectKappa.sort();
  double q(double f) =>
      perSubjectKappa[(f * (perSubjectKappa.length - 1)).round()];
  final mean =
      perSubjectKappa.reduce((a, b) => a + b) / perSubjectKappa.length;
  var ss = 0.0;
  for (final k in perSubjectKappa) {
    ss += (k - mean) * (k - mean);
  }
  final sd = math.sqrt(ss / perSubjectKappa.length);
  final bad = perSubjectKappa.where((k) => k < 0.2).length;
  stdout.writeln('');
  stdout.writeln('per-subject kappa   mean ${mean.toStringAsFixed(3)}  '
      'SD ${sd.toStringAsFixed(3)}   '
      'p10 ${q(0.10).toStringAsFixed(3)}  '
      'median ${q(0.50).toStringAsFixed(3)}  '
      'p90 ${q(0.90).toStringAsFixed(3)}');
  stdout.writeln('THE BAD TAIL        kappa < 0.2 for $bad'
      ' / ${perSubjectKappa.length} subjects '
      '(${(100 * bad / perSubjectKappa.length).toStringAsFixed(0)}%)');
  stdout.writeln('');
  stdout.writeln('reference: 4-class cardiorespiratory kappa 0.60-0.66 '
      '(Radha 2019 0.61+-0.15; Bakker 2021 0.643; Sridhar 2020 0.66)');
}

enum _Split { dev, holdout, all }

/// Deterministic, order-independent 50/50 partition by subject id (FNV-1a).
_Split _splitOf(String subject) {
  var h = 0x811c9dc5;
  for (final c in subject.codeUnits) {
    h = ((h ^ c) * 0x01000193) & 0xFFFFFFFF;
  }
  return h.isEven ? _Split.dev : _Split.holdout;
}

CardioEpochFeatures _featuresOf(Map<String, dynamic> s) => CardioEpochFeatures(
      motion: _nums(s['motion'], 0),
      hr: _nums(s['hr'], double.nan),
      hrSd: _nums(s['hrSd'], 0),
      rmssd: _nums(s['rmssd'], double.nan),
      lfhf: _nums(s['lfhf'], double.nan),
      rk: _nums(s['rk'], double.nan),
      sdnn: _nums(s['sdnn'], double.nan),
    );

/// Sweep both cutoffs on DEV only, then print the HOLDOUT score at the dev
/// optimum. The holdout column is the only one that means anything.
void _sweep(List<Map<String, dynamic>> subjects, int epochSec) {
  final dev = [
    for (final s in subjects)
      if (_splitOf(s['subject'] as String) == _Split.dev) s
  ];
  final hold = [
    for (final s in subjects)
      if (_splitOf(s['subject'] as String) == _Split.holdout) s
  ];
  stdout.writeln('dev ${dev.length} subjects | holdout ${hold.length} subjects');
  stdout.writeln('');
  stdout.writeln('  remCut  deepCut   DEV kappa  HOLDOUT kappa   '
      'holdout %REM  %Deep   (reference: ~14% REM, ~4.5% Deep)');
  var best = -1.0, bestR = 0.3, bestD = 0.3;
  final cuts = [0.0, 0.2, 0.4, 0.6, 0.8, 1.0, 1.3, 1.6, 2.0];
  for (final r in cuts) {
    for (final d in cuts) {
      final k = _scoreSet(dev, epochSec, r, d);
      if (k > best) {
        best = k;
        bestR = r;
        bestD = d;
      }
    }
  }
  for (final r in cuts) {
    final k = _scoreSet(dev, epochSec, r, bestD);
    final kh = _scoreSet(hold, epochSec, r, bestD);
    final rates = _callRates(hold, epochSec, r, bestD);
    final mark = r == bestR ? '  <- dev optimum' : '';
    stdout.writeln('   ${r.toStringAsFixed(1)}     ${bestD.toStringAsFixed(1)}'
        '      ${k.toStringAsFixed(3)}       ${kh.toStringAsFixed(3)}'
        '        ${(100 * rates.$1).toStringAsFixed(1).padLeft(5)}% '
        '${(100 * rates.$2).toStringAsFixed(1).padLeft(6)}%$mark');
  }
  stdout.writeln('');
  stdout.writeln('dev optimum remCut=${bestR.toStringAsFixed(1)} '
      'deepCut=${bestD.toStringAsFixed(1)}  '
      'DEV kappa=${best.toStringAsFixed(3)}  '
      'HOLDOUT kappa=${_scoreSet(hold, epochSec, bestR, bestD).toStringAsFixed(3)}');
  stdout.writeln('shipped   remCut=0.3 deepCut=0.3  '
      'DEV kappa=${_scoreSet(dev, epochSec, 0.3, 0.3).toStringAsFixed(3)}  '
      'HOLDOUT kappa=${_scoreSet(hold, epochSec, 0.3, 0.3).toStringAsFixed(3)}');
}

/// Fraction of epochs predicted REM and Deep — guards against a cutoff that
/// "wins" kappa by simply refusing to call the minority classes.
(double, double) _callRates(List<Map<String, dynamic>> subjects, int epochSec,
    double remCut, double deepCut) {
  var n = 0, rem = 0, deep = 0;
  for (final s in subjects) {
    final res = classifyCardioEpochs(_featuresOf(s),
        epochSec: epochSec, remScoreCut: remCut, deepScoreCut: deepCut);
    final out = res.base.stages;
    for (var e = 0; e < out.length; e++) {
      n++;
      if (out[e] == SleepStage.rem) {
        rem++;
      } else if (out[e] == SleepStage.nrem &&
          e < res.deepFlag.length &&
          res.deepFlag[e]) {
        deep++;
      }
    }
  }
  return n == 0 ? (0.0, 0.0) : (rem / n, deep / n);
}

/// (deep call rate, deep sensitivity, deep PPV, overall kappa)
(double, double, double, double) _deepMetrics(
    List<Map<String, dynamic>> subjects, int epochSec, double remCut,
    double deepCut) {
  final t = <int>[], p = <int>[];
  for (final s in subjects) {
    final stages = (s['stages'] as List).cast<String>();
    final res = classifyCardioEpochs(_featuresOf(s),
        epochSec: epochSec, remScoreCut: remCut, deepScoreCut: deepCut);
    final out = res.base.stages;
    for (var e = 0; e < out.length && e < stages.length; e++) {
      final ti = kClasses.indexOf(stages[e]);
      if (ti < 0) continue;
      t.add(ti);
      p.add(switch (out[e]) {
        SleepStage.wake => 0,
        SleepStage.rem => 3,
        SleepStage.nrem =>
          (e < res.deepFlag.length && res.deepFlag[e]) ? 2 : 1,
      });
    }
  }
  var called = 0, truthN = 0, hit = 0;
  for (var i = 0; i < t.length; i++) {
    if (p[i] == 2) called++;
    if (t[i] == 2) truthN++;
    if (t[i] == 2 && p[i] == 2) hit++;
  }
  return (
    t.isEmpty ? 0.0 : called / t.length,
    truthN == 0 ? 0.0 : hit / truthN,
    called == 0 ? 0.0 : hit / called,
    _kappa(t, p),
  );
}

double _scoreSet(List<Map<String, dynamic>> subjects, int epochSec,
    double remCut, double deepCut) {
  final t = <int>[], p = <int>[];
  for (final s in subjects) {
    final stages = (s['stages'] as List).cast<String>();
    final res = classifyCardioEpochs(_featuresOf(s),
        epochSec: epochSec, remScoreCut: remCut, deepScoreCut: deepCut);
    final out = res.base.stages;
    for (var e = 0; e < out.length && e < stages.length; e++) {
      final ti = kClasses.indexOf(stages[e]);
      if (ti < 0) continue;
      t.add(ti);
      p.add(switch (out[e]) {
        SleepStage.wake => 0,
        SleepStage.rem => 3,
        SleepStage.nrem =>
          (e < res.deepFlag.length && res.deepFlag[e]) ? 2 : 1,
      });
    }
  }
  return _kappa(t, p);
}

/// Trim a subject to the span between its first and last non-Wake epoch, i.e.
/// the sleep period. Returns null when the subject has no sleep at all or the
/// span is too short to stage.
Map<String, dynamic>? _trimToSleepPeriod(Map<String, dynamic> s) {
  final stages = (s['stages'] as List).cast<String>();
  var lo = -1, hi = -1;
  for (var i = 0; i < stages.length; i++) {
    if (stages[i] != 'Wake') {
      if (lo < 0) lo = i;
      hi = i;
    }
  }
  if (lo < 0 || hi - lo + 1 < 60) return null;
  Map<String, dynamic> out = {'subject': s['subject']};
  for (final k in ['stages', 'motion', 'hr', 'hrSd', 'rmssd', 'lfhf', 'rk', 'sdnn']) {
    out[k] = (s[k] as List).sublist(lo, hi + 1);
  }
  return out;
}

List<double> _nums(dynamic raw, double whenNull) => [
      for (final v in (raw as List))
        v == null ? whenNull : (v as num).toDouble()
    ];

void _report(String name, List<int> t, List<int> p) {
  final cm = List.generate(4, (_) => List<int>.filled(4, 0));
  for (var i = 0; i < t.length; i++) {
    cm[t[i]][p[i]]++;
  }
  var correct = 0;
  for (var i = 0; i < 4; i++) {
    correct += cm[i][i];
  }
  final acc = 100.0 * correct / t.length;
  final buf = StringBuffer('${name.padRight(30)} '
      'kappa=${_kappa(t, p).toStringAsFixed(3)}  '
      'acc=${acc.toStringAsFixed(1).padLeft(5)}%   ');
  for (var i = 0; i < 4; i++) {
    final rowSum = cm[i].reduce((a, b) => a + b);
    var colSum = 0;
    for (var r = 0; r < 4; r++) {
      colSum += cm[r][i];
    }
    final sens = rowSum == 0 ? 0.0 : 100.0 * cm[i][i] / rowSum;
    final ppv = colSum == 0 ? 0.0 : 100.0 * cm[i][i] / colSum;
    buf.write('${kClasses[i][0]} '
        '${sens.toStringAsFixed(1).padLeft(4)}/'
        '${ppv.toStringAsFixed(1).padLeft(4)}  ');
  }
  stdout.writeln(buf);
}

double _kappa(List<int> t, List<int> p) {
  final n = t.length;
  if (n == 0) return double.nan;
  final cm = List.generate(4, (_) => List<int>.filled(4, 0));
  for (var i = 0; i < n; i++) {
    cm[t[i]][p[i]]++;
  }
  var obs = 0.0, exp = 0.0;
  for (var i = 0; i < 4; i++) {
    obs += cm[i][i];
    var row = 0, col = 0;
    for (var j = 0; j < 4; j++) {
      row += cm[i][j];
      col += cm[j][i];
    }
    exp += row * col / n;
  }
  if (n - exp == 0) return double.nan;
  return (obs - exp) / (n - exp);
}
