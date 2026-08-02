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
//   dart run tool/stager_harness.dart <fixture.json> [flags]
//
//   --sleep-window     trim each subject to [first non-Wake, last non-Wake]
//   --dev | --holdout  score only one half of the locked subject split
//   --sweep            sweep both cutoffs on DEV, report HOLDOUT at the optimum
//   --deep-curve       deep cutoff vs call-rate / sens / PPV (DEV only)
//   --rem-cut <x>      override the REM cutoff (default: the shipped value)
//   --deep-cut <x>     override the deep cutoff (default: the shipped value)
//
// Fixture schema — every feature list must be the same length as `stages`, and
// `null` means "not measurable for this epoch" (never 0):
//   {"epochSec": 30,
//    "subjects": [{"subject": "S1", "stages": ["Wake"|"Light"|"Deep"|"REM", ..],
//                  "motion": [..], "hr": [..], "hrSd": [..],
//                  "rmssd": [..], "lfhf": [..], "rk": [..], "sdnn": [..]}]}

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:openstrap_analytics/onehz.dart';

/// 4-class labels, in the order used for the confusion matrix.
const kClasses = ['Wake', 'Light', 'Deep', 'REM'];

/// Feature lists a subject record must carry, all aligned with `stages`.
const _kFeatureKeys = ['motion', 'hr', 'hrSd', 'rmssd', 'lfhf', 'rk', 'sdnn'];

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run tool/stager_harness.dart <fixture.json> '
        '[--sleep-window] [--dev|--holdout] [--sweep] [--deep-curve] '
        '[--rem-cut x] [--deep-cut x]');
    exitCode = 64;
    return;
  }
  final fixture =
      jsonDecode(File(args.first).readAsStringSync()) as Map<String, dynamic>;
  final epochSec = (fixture['epochSec'] as num?)?.toInt() ?? 30;
  var subjects = (fixture['subjects'] as List).cast<Map<String, dynamic>>();

  final schemaErrors = _validate(subjects);
  if (schemaErrors.isNotEmpty) {
    for (final e in schemaErrors.take(10)) {
      stderr.writeln('fixture: $e');
    }
    if (schemaErrors.length > 10) {
      stderr.writeln('fixture: ... and ${schemaErrors.length - 10} more');
    }
    exitCode = 65;
    return;
  }

  // Defaults come FROM THE LIBRARY. Re-declaring them here is how a harness
  // silently stops measuring what actually ships.
  double argOf(String name, double dflt) {
    final i = args.indexOf(name);
    if (i < 0 || i + 1 >= args.length) return dflt;
    final v = double.tryParse(args[i + 1]);
    if (v == null) {
      stderr.writeln('warning: could not parse $name "${args[i + 1]}", '
          'using $dflt');
      return dflt;
    }
    return v;
  }

  final remCut = argOf('--rem-cut', kDefaultRemScoreCut);
  final deepCut = argOf('--deep-cut', kDefaultDeepScoreCut);

  // In production `cardioStager` never sees a whole recording: it is handed a
  // window that van Hees + AdvancedSleepStager.detectSleep have already picked
  // out, so its baselines (`stillCut`, the local sleeping-HR median, the RMSSD
  // reference) are estimated over mostly-sleep epochs. Scoring it over a full
  // record including a long pre-sleep wake block is a domain mismatch that
  // blames the rules for a windowing job they do not do.
  if (args.contains('--sleep-window')) {
    subjects = [
      for (final s in subjects)
        if (_trimToSleepPeriod(s) case final t?) t
    ];
    stdout.writeln('[--sleep-window] trimmed each subject to '
        '[first sleep, last sleep] — ${subjects.length} subjects');
  }

  // CALIBRATION PROTOCOL. Any cutoff chosen by looking at the data must be
  // reported on subjects that were not looked at, so every mode that sweeps a
  // cutoff runs on DEV only.
  if (args.contains('--deep-curve')) {
    final dev = _ofSplit(subjects, _Split.dev);
    if (dev.isEmpty) {
      stderr.writeln('--deep-curve needs a non-empty dev split');
      exitCode = 1;
      return;
    }
    stdout.writeln('[--deep-curve] DEV only (${dev.length} subjects), '
        'remCut=${remCut.toStringAsFixed(2)}');
    stdout.writeln('deepCut   %Deep called   Deep sens   Deep PPV   kappa');
    for (final d in [0.0, 0.2, 0.3, 0.4, 0.6, 0.8, 1.0]) {
      final m = _deepMetrics(dev, epochSec, remCut, d);
      stdout.writeln('  ${d.toStringAsFixed(1)}       '
          '${(100 * m.$1).toStringAsFixed(1).padLeft(5)}%       '
          '${(100 * m.$2).toStringAsFixed(1).padLeft(5)}%     '
          '${(100 * m.$3).toStringAsFixed(1).padLeft(5)}%    '
          '${_fmtKappa(m.$4)}');
    }
    return;
  }
  if (args.contains('--sweep')) {
    _sweep(subjects, epochSec);
    return;
  }

  final split = args.contains('--dev')
      ? _Split.dev
      : args.contains('--holdout')
          ? _Split.holdout
          : _Split.all;
  if (split != _Split.all) {
    subjects = _ofSplit(subjects, split);
    stdout.writeln('[${split.name}] ${subjects.length} subjects');
  }
  final shipped =
      remCut == kDefaultRemScoreCut && deepCut == kDefaultDeepScoreCut;
  stdout.writeln('cutoffs: rem=${remCut.toStringAsFixed(2)} '
      'deep=${deepCut.toStringAsFixed(2)}'
      '${shipped ? " (shipped)" : " (OVERRIDDEN — not what ships)"}');

  final truth = <int>[];
  final pred = <int>[];
  final perSubjectKappa = <double>[];
  var skipped = 0;

  for (final s in subjects) {
    final scored = _scoreSubject(s, epochSec, remCut, deepCut);
    if (scored == null || scored.$1.length < 30) {
      skipped++;
      continue;
    }
    truth.addAll(scored.$1);
    pred.addAll(scored.$2);
    final k = _kappa(scored.$1, scored.$2);
    if (!k.isNaN) perSubjectKappa.add(k);
  }

  if (truth.isEmpty || perSubjectKappa.isEmpty) {
    stderr.writeln('no subject produced a scoreable hypnogram '
        '($skipped skipped: abstained, too short, or unlabelled)');
    exitCode = 1;
    return;
  }

  stdout.writeln('subjects scored ${perSubjectKappa.length}'
      '${skipped > 0 ? '  (skipped $skipped: abstained/too short)' : ''}'
      '   epochs ${truth.length}');
  stdout.writeln('');

  final counts = List<int>.filled(4, 0);
  for (final t in truth) {
    counts[t]++;
  }
  final majority = counts.indexOf(counts.reduce(math.max));
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

/// Structural check on the fixture. A malformed record must fail loudly here,
/// not produce a confident wrong kappa.
List<String> _validate(List<Map<String, dynamic>> subjects) {
  final errs = <String>[];
  for (var i = 0; i < subjects.length; i++) {
    final s = subjects[i];
    final id = s['subject'] ?? '#$i';
    if (s['subject'] is! String) errs.add('$id: missing string "subject"');
    final stages = s['stages'];
    if (stages is! List) {
      errs.add('$id: missing "stages" list');
      continue;
    }
    for (final k in _kFeatureKeys) {
      final v = s[k];
      if (v is! List) {
        errs.add('$id: missing "$k" list');
      } else if (v.length != stages.length) {
        errs.add(
            '$id: "$k" has ${v.length} entries, "stages" has ${stages.length}');
      }
    }
  }
  return errs;
}

enum _Split { dev, holdout, all }

/// Deterministic, order-independent 50/50 partition by subject id (FNV-1a).
///
/// Splits on a MIDDLE bit, not the parity of the final hash. FNV-1a's last step
/// multiplies by an odd constant, so the low bit of the result is just the low
/// bit of `prevHash ^ lastByte` — testing `isEven` would degenerate to
/// "alternate by the last character", which for ids like S001/S002/S003 gives a
/// striped split rather than a hashed one.
_Split _splitOf(String subject) {
  var h = 0x811c9dc5;
  for (final c in subject.codeUnits) {
    h = ((h ^ c) * 0x01000193) & 0xFFFFFFFF;
  }
  return ((h >> 16) & 1) == 0 ? _Split.dev : _Split.holdout;
}

List<Map<String, dynamic>> _ofSplit(
        List<Map<String, dynamic>> subjects, _Split want) =>
    [
      for (final s in subjects)
        if (_splitOf(s['subject'] as String) == want) s
    ];

CardioEpochFeatures _featuresOf(Map<String, dynamic> s) => CardioEpochFeatures(
      motion: _nums(s['motion'], 0),
      hr: _nums(s['hr'], double.nan),
      hrSd: _nums(s['hrSd'], 0),
      rmssd: _nums(s['rmssd'], double.nan),
      lfhf: _nums(s['lfhf'], double.nan),
      rk: _nums(s['rk'], double.nan),
      sdnn: _nums(s['sdnn'], double.nan),
    );

/// (truth, prediction) label indices for one subject, or null when the stager
/// abstained. The single place reference labels are mapped onto our 3-class +
/// deep-flag output — this loop previously existed in three scoring paths,
/// which is exactly how they drift apart.
(List<int>, List<int>)? _scoreSubject(
    Map<String, dynamic> s, int epochSec, double remCut, double deepCut) {
  final stages = (s['stages'] as List).cast<String>();
  final res = classifyCardioEpochs(_featuresOf(s),
      epochSec: epochSec, remScoreCut: remCut, deepScoreCut: deepCut);
  final out = res.base.stages;
  if (out.isEmpty) return null; // honest abstain
  final t = <int>[], p = <int>[];
  final unknown = <String>{};
  for (var e = 0; e < out.length && e < stages.length; e++) {
    final ti = kClasses.indexOf(stages[e]);
    if (ti < 0) {
      unknown.add(stages[e]);
      continue;
    }
    t.add(ti);
    p.add(switch (out[e]) {
      SleepStage.wake => 0,
      SleepStage.rem => 3,
      SleepStage.nrem => (e < res.deepFlag.length && res.deepFlag[e]) ? 2 : 1,
    });
  }
  if (unknown.isNotEmpty) {
    stderr.writeln('warning: ${s['subject']}: dropped unrecognised stage '
        'labels ${unknown.toList()..sort()}');
  }
  return (t, p);
}

/// Sweep both cutoffs on DEV only, then print the HOLDOUT score at the dev
/// optimum. The holdout column is the only one that means anything.
void _sweep(List<Map<String, dynamic>> subjects, int epochSec) {
  final dev = _ofSplit(subjects, _Split.dev);
  final hold = _ofSplit(subjects, _Split.holdout);
  stdout.writeln('dev ${dev.length} subjects | holdout ${hold.length} subjects');
  if (dev.isEmpty || hold.isEmpty) {
    stderr.writeln('sweep needs a non-empty dev AND holdout split');
    exitCode = 1;
    return;
  }
  stdout.writeln('');
  final cuts = [0.0, 0.2, 0.4, 0.6, 0.8, 1.0, 1.3, 1.6, 2.0];
  var best = double.negativeInfinity;
  var bestR = kDefaultRemScoreCut, bestD = kDefaultDeepScoreCut;
  for (final r in cuts) {
    for (final d in cuts) {
      final k = _scoreSet(dev, epochSec, r, d);
      if (!k.isNaN && k > best) {
        best = k;
        bestR = r;
        bestD = d;
      }
    }
  }
  if (best == double.negativeInfinity) {
    stderr.writeln('sweep produced no scoreable configuration');
    exitCode = 1;
    return;
  }
  stdout.writeln('  remCut  deepCut   DEV kappa  HOLDOUT kappa   '
      'holdout %REM  %Deep');
  for (final r in cuts) {
    final k = _scoreSet(dev, epochSec, r, bestD);
    final kh = _scoreSet(hold, epochSec, r, bestD);
    final rates = _callRates(hold, epochSec, r, bestD);
    final mark = r == bestR ? '  <- dev optimum' : '';
    stdout.writeln('   ${r.toStringAsFixed(1)}     ${bestD.toStringAsFixed(1)}'
        '      ${_fmtKappa(k)}       ${_fmtKappa(kh)}'
        '        ${(100 * rates.$1).toStringAsFixed(1).padLeft(5)}% '
        '${(100 * rates.$2).toStringAsFixed(1).padLeft(6)}%$mark');
  }
  stdout.writeln('');
  stdout.writeln('dev optimum remCut=${bestR.toStringAsFixed(1)} '
      'deepCut=${bestD.toStringAsFixed(1)}  DEV ${_fmtKappa(best)}  '
      'HOLDOUT ${_fmtKappa(_scoreSet(hold, epochSec, bestR, bestD))}');
  stdout.writeln('shipped     '
      'remCut=${kDefaultRemScoreCut.toStringAsFixed(1)} '
      'deepCut=${kDefaultDeepScoreCut.toStringAsFixed(1)}  '
      'DEV ${_fmtKappa(_scoreSet(dev, epochSec, kDefaultRemScoreCut, kDefaultDeepScoreCut))}  '
      'HOLDOUT ${_fmtKappa(_scoreSet(hold, epochSec, kDefaultRemScoreCut, kDefaultDeepScoreCut))}');
  stdout.writeln('');
  stdout.writeln('NOTE: the dev optimum is NOT automatically the right choice. '
      'See the cutoff doc comment in cardio_stager.dart for why kappa on a '
      'low-deep cohort rewards suppressing deep sleep.');
}

String _fmtKappa(double k) => k.isNaN ? '  n/a' : k.toStringAsFixed(3);

/// Fraction of epochs predicted REM and Deep — guards against a cutoff that
/// "wins" kappa by simply refusing to call the minority classes.
(double, double) _callRates(List<Map<String, dynamic>> subjects, int epochSec,
    double remCut, double deepCut) {
  var n = 0, rem = 0, deep = 0;
  for (final s in subjects) {
    final scored = _scoreSubject(s, epochSec, remCut, deepCut);
    if (scored == null) continue;
    for (final p in scored.$2) {
      n++;
      if (p == 3) rem++;
      if (p == 2) deep++;
    }
  }
  return n == 0 ? (0.0, 0.0) : (rem / n, deep / n);
}

/// (deep call rate, deep sensitivity, deep PPV, overall kappa)
(double, double, double, double) _deepMetrics(
    List<Map<String, dynamic>> subjects,
    int epochSec,
    double remCut,
    double deepCut) {
  final t = <int>[], p = <int>[];
  for (final s in subjects) {
    final scored = _scoreSubject(s, epochSec, remCut, deepCut);
    if (scored == null) continue;
    t.addAll(scored.$1);
    p.addAll(scored.$2);
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
    final scored = _scoreSubject(s, epochSec, remCut, deepCut);
    if (scored == null) continue;
    t.addAll(scored.$1);
    p.addAll(scored.$2);
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
  final out = <String, dynamic>{'subject': s['subject']};
  for (final k in ['stages', ..._kFeatureKeys]) {
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
      'kappa=${_fmtKappa(_kappa(t, p))}  '
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
