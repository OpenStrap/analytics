// VALIDATION HARNESS — score the SHIPPED nap detector against hand-labelled
// days.
//
// Runs `detectNaps` (the real production entry point, not a reimplementation)
// over 1 Hz days carrying human nap labels, and reports the metrics that are
// actually informative for a rare-event detector:
//
//   * EVENT-level sensitivity and PPV, not per-second accuracy. Naps occupy a
//     low-single-digit percentage of a day, so a detector that reports nothing
//     scores >97% per-second accuracy. Per-second accuracy is not printed at
//     all, because there is no honest way to read it.
//   * BOTH sensitivity and PPV, always together. The two failure modes here
//     are opposite and both real: missing the 20-45 min power nap (the regime
//     the nocturnal detector structurally rejected), and calling a still wrist
//     — desk work, a car passenger seat, a band on a table — a nap.
//   * DURATION error on matched pairs, in minutes of TIB — the only duration an
//     interval label can score (see the second caveat below). Detecting that a
//     nap happened is only half the job: the duration is what reaches sleep
//     need, though the TST that actually reaches it is not validated here.
//   * The PER-SUBJECT distribution, not just the pooled figure. Following
//     Radha 2019 (PMID 31578345) on the stager: the spread is the whole story
//     for "works for most, awful for a few".
//
// CAVEAT, and it is a real one, larger than the stager harness's. We have no
// PSG-labelled nap corpus. PSG can stage a daytime nap perfectly well — the
// MSLT is exactly that — so this is a statement about what THIS evaluation
// had access to, not a claim that a gold standard cannot exist. These labels
// are human-annotated from the accelerometer/HR trace and self-report. What
// this scores is agreement with an ANNOTATOR, on a small, self-collected
// corpus. Report it that way. It will not support a population precision
// claim, and it should never be quoted as one.
//
// A second limit, from the same source: a label is a [start, end] INTERVAL, so
// the only duration it can score is TIB. This corpus cannot validate `tstSec`
// at all — and TST is the field that feeds the sleep-need credit. Scoring TST
// against an interval label charges each nap its own awake time as error.
//
// Usage:
//   dart run tool/nap_harness.dart <fixture.json> [flags]
//
//   --iou <x>     overlap needed to call a detection a match (default 0.5)
//   --per-day     print one line per day, including the detector's own note
//
// Fixture schema — `accel` and `hr` must be the same length, 1 Hz, contiguous:
//   {"days": [
//      {"subject": "S1",
//       "tsStartSec": 1783500000,
//       "accel": [[x,y,z], ...],
//       "hr":    [72, 0, 74, ...],          // 0 means NO READING, never a zero HR
//       "mainSleep": [startIdx, endIdx],    // optional
//       "wristOff": [[startSec,endSec]],    // optional, ABSOLUTE seconds
//       "exclude":  [[startSec,endSec]],    // optional, ABSOLUTE seconds
//       "naps":     [[startSec,endSec]]     // GROUND TRUTH, seconds RELATIVE
//      }]}

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:openstrap_analytics/onehz.dart';

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run tool/nap_harness.dart <fixture.json> '
        '[--iou x] [--per-day]');
    exitCode = 64;
    return;
  }

  final Map<String, dynamic> fixture;
  try {
    fixture =
        jsonDecode(File(args.first).readAsStringSync()) as Map<String, dynamic>;
  } on FileSystemException catch (e) {
    stderr.writeln('cannot read fixture: ${e.message}');
    exitCode = 66;
    return;
  }

  final days = (fixture['days'] as List?)?.cast<Map<String, dynamic>>();
  if (days == null || days.isEmpty) {
    stderr.writeln('fixture: no "days"');
    exitCode = 65;
    return;
  }

  double argOf(String name, double dflt) {
    final i = args.indexOf(name);
    if (i < 0 || i + 1 >= args.length) return dflt;
    return double.tryParse(args[i + 1]) ?? dflt;
  }

  final iouCut = argOf('--iou', 0.5);
  final perDay = args.contains('--per-day');

  final schemaErrors = _validate(days);
  if (schemaErrors.isNotEmpty) {
    for (final e in schemaErrors.take(10)) {
      stderr.writeln('fixture: $e');
    }
    exitCode = 65;
    return;
  }

  var tp = 0, fp = 0, fn = 0, absent = 0;
  // Labelled naps on days the detector ABSTAINED on. They never reach tp/fp/fn,
  // so leaving them uncounted made sensitivity and PPV silently conditional on
  // the days the detector agreed to judge — and a detector that abstains on its
  // hard days would score better than one that tries. Reported separately, plus
  // an end-to-end recall that charges abstentions as misses.
  var absentLabels = 0;
  final durErrMin = <double>[];
  final perSubject = <String, List<int>>{}; // subject -> [tp, fp, fn]

  for (final day in days) {
    final subject = (day['subject'] as String?) ?? '?';
    final t0 = (day['tsStartSec'] as num).toInt();
    final rawAccel = (day['accel'] as List).cast<List>();
    final accel = <AccelSample>[
      for (var i = 0; i < rawAccel.length; i++)
        AccelSample(
          (t0 + i) * 1000.0,
          (rawAccel[i][0] as num).toDouble(),
          (rawAccel[i][1] as num).toDouble(),
          (rawAccel[i][2] as num).toDouble(),
        ),
    ];
    final hr = [for (final v in day['hr'] as List) (v as num).toDouble()];

    SleepWindowSpan? main;
    if (day['mainSleep'] case final List m when m.length == 2) {
      main = SleepWindowSpan((m[0] as num).toInt(), (m[1] as num).toInt());
    }

    final m = detectNaps(
      accel,
      hr,
      mainSleep: main,
      wristOff: _spans(day['wristOff']),
      exclude: _spans(day['exclude']),
    );

    final truth = [
      for (final t in (day['naps'] as List? ?? const []).cast<List>())
        [(t[0] as num).toInt(), (t[1] as num).toInt()]
    ];

    if (!m.present) {
      // An abstention is NOT a miss to be scored as if the detector had made a
      // wrong call — it is a refusal to judge. Counting it as a false negative
      // would reward a detector that guesses over one that abstains honestly.
      absent++;
      absentLabels += truth.length;
      if (perDay) {
        stdout.writeln('  $subject: ABSTAINED (${truth.length} labelled) '
            '— ${m.note}');
      }
      continue;
    }

    final got = m.value!;
    final matched = <int>{};
    var dtp = 0, dfp = 0;

    for (final nap in got) {
      var best = -1;
      var bestIou = 0.0;
      for (var k = 0; k < truth.length; k++) {
        if (matched.contains(k)) continue;
        final iou = _iou(nap.startSec, nap.endSec, truth[k][0], truth[k][1]);
        if (iou > bestIou) {
          bestIou = iou;
          best = k;
        }
      }
      if (best >= 0 && bestIou >= iouCut) {
        matched.add(best);
        dtp++;
        // TIB, not TST. A label is a [start, end] INTERVAL, so its length is
        // the whole episode — time in bed. Scoring it against `tstSec` charged
        // every matched nap its own awake time as error: a perfectly measured
        // 2 h episode at 70% efficiency reported a 36-min miss. That is the
        // exact TST/TIB conflation this detector exists to end, reappearing in
        // the tool that validates it.
        final truthSec = truth[best][1] - truth[best][0];
        durErrMin.add((nap.tibSec - truthSec).abs() / 60.0);
      } else {
        dfp++;
      }
    }
    final dfn = truth.length - matched.length;

    tp += dtp;
    fp += dfp;
    fn += dfn;
    final acc = perSubject.putIfAbsent(subject, () => [0, 0, 0]);
    acc[0] += dtp;
    acc[1] += dfp;
    acc[2] += dfn;

    if (perDay) {
      stdout.writeln('  $subject: tp=$dtp fp=$dfp fn=$dfn — ${m.note}');
    }
  }

  final sens = (tp + fn) == 0 ? null : tp / (tp + fn);
  final ppv = (tp + fp) == 0 ? null : tp / (tp + fp);

  stdout.writeln('');
  stdout.writeln('NAP DETECTOR — ${days.length} day(s), '
      '${perSubject.length} subject(s), IoU ≥ $iouCut');
  // Recall over EVERY labelled nap, including those on abstained days. The
  // sensitivity above is conditional on the days the detector judged; this one
  // is what a user actually experiences, since an abstention shows them no nap.
  final allLabels = tp + fn + absentLabels;
  final e2e = allLabels == 0 ? null : tp / allLabels;

  stdout.writeln('  labelled naps : $allLabels '
      '(${tp + fn} on judged days, $absentLabels on abstained days)');
  stdout.writeln('  detected      : ${tp + fp}');
  stdout.writeln('  abstained     : $absent day(s), '
      '$absentLabels labelled nap(s) not scored below');
  stdout.writeln('  TP=$tp  FP=$fp  FN=$fn');
  stdout.writeln('  sensitivity   : ${_pct(sens)}   '
      '(missed naps, JUDGED days only)');
  stdout.writeln('  PPV           : ${_pct(ppv)}   '
      '(false naps, JUDGED days only)');
  stdout.writeln('  end-to-end    : ${_pct(e2e)}   '
      '(recall over ALL labels; abstentions count as misses)');
  if (durErrMin.isNotEmpty) {
    final med = _median(durErrMin)!;
    final mx = durErrMin.reduce(math.max);
    // TIB, because a label is an interval. See the matching branch above —
    // this corpus cannot score TST at all.
    stdout.writeln('  |TIB error|   : median ${med.toStringAsFixed(1)} min, '
        'worst ${mx.toStringAsFixed(1)} min  (n=${durErrMin.length} matched)');
  }

  if (perSubject.length > 1) {
    stdout.writeln('');
    stdout.writeln('  per subject (the spread is the story):');
    final names = perSubject.keys.toList()..sort();
    for (final s in names) {
      final a = perSubject[s]!;
      final ss = (a[0] + a[2]) == 0 ? null : a[0] / (a[0] + a[2]);
      final pp = (a[0] + a[1]) == 0 ? null : a[0] / (a[0] + a[1]);
      stdout.writeln('    $s: sens ${_pct(ss)}  PPV ${_pct(pp)}  '
          '(tp=${a[0]} fp=${a[1]} fn=${a[2]})');
    }
  }

  stdout.writeln('');
  stdout.writeln('  READ THIS AS: agreement with a human annotator on a small '
      'self-collected corpus.');
  stdout.writeln('  We have no PSG-LABELLED nap corpus (PSG can stage naps — '
      'the MSLT does; we just');
  stdout.writeln('  do not have one). Do not quote these as population '
      'accuracy. Labels are intervals,');
  stdout.writeln('  so TIB is scored and TST is NOT validated here.');
}

List<List<int>> _spans(Object? raw) => [
      for (final s in (raw as List? ?? const []).cast<List>())
        [(s[0] as num).toInt(), (s[1] as num).toInt()]
    ];

/// Intersection over union of two [start, end) second ranges.
double _iou(int aS, int aE, int bS, int bE) {
  final lo = math.max(aS, bS), hi = math.min(aE, bE);
  final inter = hi > lo ? hi - lo : 0;
  final union = (aE - aS) + (bE - bS) - inter;
  return union <= 0 ? 0 : inter / union;
}

String _pct(double? x) =>
    x == null ? '  n/a' : '${(x * 100).toStringAsFixed(1)}%';

double? _median(List<double> xs) {
  if (xs.isEmpty) return null;
  final s = [...xs]..sort();
  final mid = s.length ~/ 2;
  return s.length.isOdd ? s[mid] : (s[mid - 1] + s[mid]) / 2;
}

List<String> _validate(List<Map<String, dynamic>> days) {
  final errs = <String>[];
  for (var i = 0; i < days.length; i++) {
    final d = days[i];
    final tag = 'day[$i] (${d['subject'] ?? '?'})';
    if (d['tsStartSec'] is! num) errs.add('$tag: missing tsStartSec');
    final accel = d['accel'];
    final hr = d['hr'];
    if (accel is! List || accel.isEmpty) {
      errs.add('$tag: missing accel');
      continue;
    }
    if (hr is! List) {
      errs.add('$tag: missing hr');
      continue;
    }
    if (accel.length != hr.length) {
      errs.add('$tag: accel ${accel.length} != hr ${hr.length}');
    }
    for (final t in (d['naps'] as List? ?? const []).cast<List>()) {
      if (t.length != 2 || (t[1] as num) <= (t[0] as num)) {
        errs.add('$tag: bad nap label $t');
      }
    }
  }
  return errs;
}
