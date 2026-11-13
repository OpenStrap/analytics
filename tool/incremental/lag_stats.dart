// Settle horizon in the wild: how many beats / seconds behind the newest beat
// is the last SETTLED output, distribution over 1-beat folds.
import 'package:openstrap_analytics/onehz.dart'
    hide RrCorrector, RrSettled, RrSnapshot, IrregularScreenState;
import 'rr_stream.dart';
import 'synth.dart';

void report(String name, RrData s) {
  final c = RrCorrector();
  final lagBeats = <int>[], lagSec = <double>[];
  var ce0 = 0;
  for (var i = 0; i < s.length; i++) {
    c.fold([s.rr[i]], tsMs: [s.ts[i]]);
    final settled = c.settledBeats;
    if (settled > ce0 || true) {
      lagBeats.add(i + 1 - settled);
      lagSec.add(settled == 0 ? 0 : (s.ts[i] - s.ts[settled - 1]) / 1000.0);
    }
    ce0 = settled;
  }
  lagBeats.sort();
  lagSec.sort();
  double q(List<num> x, double p) => x[((x.length - 1) * p).round()].toDouble();
  print('$name: beats=${s.length}  lag beats p50=${q(lagBeats, .5)} p95=${q(lagBeats, .95)} '
      'p99=${q(lagBeats, .99)} max=${lagBeats.last}   lag s p50=${q(lagSec, .5).toStringAsFixed(0)} '
      'p99=${q(lagSec, .99).toStringAsFixed(0)} max=${lagSec.last.toStringAsFixed(0)}  '
      'state buffer max beats: ${c.bufferedBeats}');
}

void main() {
  report('real night', realNightRr()!);
  report('synthetic day (default artefacts)', synthRr(const SynthConfig(seed: 3, hours: 8)));
  report('synthetic dirty', synthRr(const SynthConfig(
      seed: 4, hours: 3, ectopicPerMin: 3, missedPerMin: 2, extraPerMin: 2, noiseRunPerMin: 1, gapPerHour: 8)));
  // one-shot micro bench, 3 runs each, 32k beats
  final n = realNightRr()!;
  final sw = Stopwatch();
  final o = <int>[], r = <int>[];
  for (var k = 0; k < 3; k++) {
    sw..reset()..start();
    correctRr(n.rr, rrTsMs: n.ts);
    o.add(sw.elapsedMilliseconds);
    sw..reset()..start();
    final c = RrCorrector()..fold(n.rr, tsMs: n.ts);
    c.snapshot();
    r.add(sw.elapsedMilliseconds);
  }
  print('32k-beat night one-shot ms: oracle $o   streaming $r');
}
