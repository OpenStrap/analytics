// Timing: oracle correctRr vs streaming RrCorrector on a 23 h real-shaped day.
// dart run tool/incremental/bench_rr.dart
import 'dart:convert';
import 'package:openstrap_analytics/onehz.dart'
    hide RrCorrector, RrSettled, RrSnapshot, IrregularScreenState;
import 'oracle_util.dart';
import 'rr_stream.dart';
import 'synth.dart';

double ms(Stopwatch s) => s.elapsedMicroseconds / 1000.0;

void main() {
  final day = realShapedDay();
  final n = day.length;
  print('day beats=$n  span h=${(day.ts.last - day.ts.first) / 3.6e6}');
  // warm
  correctRr(day.rr.sublist(0, 4000), rrTsMs: day.ts.sublist(0, 4000));

  final sw = Stopwatch()..start();
  final oracle = correctRr(day.rr, rrTsMs: day.ts);
  print('oracle one-shot: ${ms(sw).toStringAsFixed(0)} ms '
      '(${(ms(sw) * 1000 / n).toStringAsFixed(1)} us/beat)');

  // streaming, one fold of the whole day
  sw..reset()..start();
  final one = RrCorrector();
  final s1 = one.fold(day.rr, tsMs: day.ts);
  final snap1 = one.snapshot();
  print('stream one-shot fold+snapshot: ${ms(sw).toStringAsFixed(0)} ms '
      '(${(ms(sw) * 1000 / n).toStringAsFixed(1)} us/beat)');
  final same = [...s1.nn, ...snap1.tailNn];
  print('  identical nn: ${same.length == oracle.nn.length && _eq(same, oracle.nn)}');

  // streaming, 15-minute folds, JSON restart every fold (worst case)
  final cuts = timeCuts(day.ts, 900);
  var c = RrCorrector();
  final foldMs = <double>[], snapMs = <double>[], jsonMs = <double>[];
  var bytes = 0, maxBytes = 0;
  var from = 0;
  final all = <double>[];
  for (final to in cuts) {
    sw..reset()..start();
    final s = c.fold(day.rr.sublist(from, to), tsMs: day.ts.sublist(from, to));
    foldMs.add(ms(sw));
    all.addAll(s.nn);
    sw..reset()..start();
    final snap = c.snapshot();
    snapMs.add(ms(sw));
    if (to == cuts.last) all.addAll(snap.tailNn);
    sw..reset()..start();
    final txt = jsonEncode(c.toJson());
    c = RrCorrector.fromJson(jsonRoundTrip(jsonDecode(txt) as Map<String, dynamic>));
    jsonMs.add(ms(sw));
    bytes = txt.length;
    if (bytes > maxBytes) maxBytes = bytes;
    from = to;
  }
  print('stream 15-min folds: ${cuts.length} folds');
  print('  fold      mean=${_mean(foldMs).toStringAsFixed(1)} ms  max=${_max(foldMs).toStringAsFixed(1)}  sum=${_sum(foldMs).toStringAsFixed(0)}');
  print('  snapshot  mean=${_mean(snapMs).toStringAsFixed(2)} ms  max=${_max(snapMs).toStringAsFixed(2)}');
  print('  json enc+dec+restore mean=${_mean(jsonMs).toStringAsFixed(2)} ms  max=${_max(jsonMs).toStringAsFixed(2)}  state bytes max=$maxBytes');
  print('  identical nn over 96 folds: ${_eq(all, oracle.nn)}');

  // what the app does today: whole-day correctRr at pass k
  for (final frac in [0.25, 0.5, 0.75, 1.0]) {
    final m = (n * frac).floor();
    sw..reset()..start();
    correctRr(day.rr.sublist(0, m), rrTsMs: day.ts.sublist(0, m));
    print('oracle at ${(frac * 100).round()}% of day (n=$m): ${ms(sw).toStringAsFixed(0)} ms');
  }
}

bool _eq(List<double> a, List<double> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

double _mean(List<double> x) => x.isEmpty ? 0 : _sum(x) / x.length;
double _sum(List<double> x) => x.fold(0.0, (a, b) => a + b);
double _max(List<double> x) => x.fold(0.0, (a, b) => a > b ? a : b);
