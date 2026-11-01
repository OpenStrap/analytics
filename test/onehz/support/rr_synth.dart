// Test support: real-shaped RR generators and the real-night fixture loader.
// Deterministic (seeded), no wall clock. (Copied from the research prototypes in
// tool/incremental/synth.dart; the accelerometer generator stayed there because
// the day-curve states it feeds live in edge, not here.)
//
// "Real-shaped" means what the app really feeds correctRr:
//   * integer-millisecond RR, end-of-beat timestamps quantised to WHOLE seconds
//     (rr_ts_ms = rec_ts * 1000, several beats can share one stamp),
//   * ectopic pairs, missed beats (2x interval), extra beats (half interval),
//     multi-beat noise runs, sensor dropouts (no beats for seconds..minutes),
//   * optional counter-reset style timestamp steps backwards.
import 'dart:io';
import 'dart:math' as math;

class RrData {
  final List<double> rr;
  final List<double> ts; // epoch-ish ms, whole seconds
  RrData(this.rr, this.ts);
  int get length => rr.length;
}

class SynthConfig {
  final int seed;
  final double hours;
  final double startSec;
  final double ectopicPerMin; // premature beat + compensatory pause
  final double missedPerMin;
  final double extraPerMin;
  final double noiseRunPerMin; // run of 3..12 garbage beats
  final double gapPerHour; // dropouts of 5..900 s
  final double backwardsPerHour; // ts steps back 1..3 s (counter reset-ish)
  final double nightFraction; // fraction of the span that is "asleep"
  const SynthConfig({
    this.seed = 1,
    this.hours = 24,
    this.startSec = 1.7e9,
    this.ectopicPerMin = 0.3,
    this.missedPerMin = 0.1,
    this.extraPerMin = 0.1,
    this.noiseRunPerMin = 0.05,
    this.gapPerHour = 1.5,
    this.backwardsPerHour = 0.0,
    this.nightFraction = 0.33,
  });
}

/// Physiologically-flavoured RR: slow HR drift + RSA (0.25 Hz) + LF (0.1 Hz)
/// + white jitter, integer ms, with injected artefacts.
RrData synthRr(SynthConfig c) {
  final rnd = math.Random(c.seed);
  final rr = <double>[], ts = <double>[];
  final endT = c.hours * 3600.0;
  var t = 0.0; // seconds since start (beat clock)
  var phase = rnd.nextDouble() * 6.28;
  final nightStart = endT * 0.05;
  final nightEnd = nightStart + endT * c.nightFraction;
  void emit(double interval) {
    final v = interval.roundToDouble();
    t += v / 1000.0;
    var stamp = (c.startSec + t).floorToDouble() * 1000.0;
    rr.add(v);
    ts.add(stamp);
  }

  while (t < endT) {
    final asleep = t >= nightStart && t < nightEnd;
    // Base HR: sleep ~52 bpm, day 65..120 with activity bouts.
    final bout = (math.sin(t / 1900.0 + c.seed) + 1) / 2; // 0..1
    final bpm = asleep ? 52 + 3 * math.sin(t / 5400) : 66 + 55 * bout * bout;
    var base = 60000.0 / bpm;
    final rsaAmp = asleep ? 45.0 : 22.0 * (1 - 0.7 * bout);
    final rsaHz = asleep ? 0.24 : 0.27;
    final v = base +
        rsaAmp * math.sin(2 * math.pi * rsaHz * t + phase) +
        28 * math.sin(2 * math.pi * 0.1 * t) +
        8 * (rnd.nextDouble() - .5) * 2;
    final beatMin = v / 60000.0; // minutes per beat → per-beat probabilities
    final u = rnd.nextDouble();
    var p = c.noiseRunPerMin * beatMin;
    if (u < p) {
      final len = 3 + rnd.nextInt(10);
      for (var k = 0; k < len; k++) {
        emit(250 + rnd.nextInt(2100).toDouble());
      }
      continue;
    }
    p += c.ectopicPerMin * beatMin;
    if (u < p) {
      emit(v * (0.55 + 0.15 * rnd.nextDouble()));
      emit(v * (1.3 + 0.2 * rnd.nextDouble()));
      continue;
    }
    p += c.missedPerMin * beatMin;
    if (u < p) {
      emit(v * (1.9 + 0.2 * rnd.nextDouble()));
      continue;
    }
    p += c.extraPerMin * beatMin;
    if (u < p) {
      final f = 0.35 + 0.3 * rnd.nextDouble();
      emit(v * f);
      emit(v * (1 - f));
      continue;
    }
    p += c.gapPerHour * beatMin / 60.0;
    if (u < p) {
      final gap = 5 + rnd.nextInt(896);
      t += gap.toDouble();
      continue;
    }
    p += c.backwardsPerHour * beatMin / 60.0;
    if (u < p && ts.isNotEmpty) {
      emit(v);
      ts[ts.length - 1] = ts.last - 1000.0 * (1 + rnd.nextInt(3));
      continue;
    }
    emit(v);
  }
  return RrData(rr, ts);
}

/// The checked-in anonymised 8.9 h WHOOP-4 night (rebased to 0 s). Returns
/// null if the fixture is missing (callers decide whether to fail).
RrData? realNightRr({double startSec = 1.7e9}) {
  final f = File('test/onehz/fixtures/real_night_2026_07_rr.csv');
  if (!f.existsSync()) return null;
  final rr = <double>[], ts = <double>[];
  for (final line in f.readAsLinesSync().skip(1)) {
    if (line.trim().isEmpty) continue;
    final p = line.split(',');
    ts.add(startSec * 1000 + double.parse(p[0]));
    rr.add(double.parse(p[1]));
  }
  return RrData(rr, ts);
}

/// A whole 24 h-ish day: synthetic morning + REAL night + synthetic evening.
/// The synthetic parts carry the artefact load; the night is as recorded.
RrData realShapedDay({int seed = 7, double startSec = 1.7e9}) {
  final real = realNightRr(startSec: startSec)!;
  final nightSpanMs = real.ts.last - real.ts.first;
  final morning = synthRr(SynthConfig(
      seed: seed, hours: 5, startSec: startSec - 5 * 3600, nightFraction: 0));
  final evening = synthRr(SynthConfig(
      seed: seed + 1,
      hours: 9,
      startSec: startSec + nightSpanMs / 1000 + 120,
      nightFraction: 0));
  return RrData([...morning.rr, ...real.rr, ...evening.rr],
      [...morning.ts, ...real.ts, ...evening.ts]);
}
