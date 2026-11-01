// cvhrApneaScreen used to loop forever on a non-finite NN value: a NaN
// excursion made both `exc[i] <= prom` and `exc[i] > prom` false in
// _scoreSegment, so the scan index never advanced.
//
// A busy loop on the main isolate cannot be interrupted by the test timeout,
// so each call runs in a spawned isolate that is killed after 5 s. A hang
// therefore shows up as a clean test failure, not a stuck test run.
//
// Assertions, and why they hold:
//  * The baseline series is constant NN (800 ms), so it has no dip at all.
//    Every finite excursion is exactly 0, so no finite stretch can start a
//    cycle. Non-finite samples must not start one either (the intended
//    behaviour: a non-finite excursion is never above the prominence
//    threshold). So the cycle count must be 0, which is also the count for
//    the same series with the bad beats removed.
//  * The series are 400 beats (~320 s), long enough to pass the >=60 beat and
//    >=60 s gates and to be one gap-free segment, so the result is present.
import 'dart:isolate';

import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

const _n = 400;
const _nn = 800.0;

/// Entry point for the spawned isolate: msg = [SendPort, nn, tMs].
void _entry(List<Object> msg) {
  final port = msg[0] as SendPort;
  final nn = (msg[1] as List).cast<double>();
  final t = (msg[2] as List).cast<double>();
  final m = cvhrApneaScreen(nn, t, artifactFraction: 0.0);
  port.send(m.value?.cycleCount ?? -1);
}

/// Cycle count, -1 when the metric is absent. Fails the test on a hang.
Future<int> _count(List<double> nn) async {
  final t = <double>[for (var i = 0; i < nn.length; i++) i * _nn];
  final rp = ReceivePort();
  final iso = await Isolate.spawn(_entry, <Object>[rp.sendPort, nn, t]);
  try {
    final r = await rp.first.timeout(const Duration(seconds: 5));
    return r as int;
  } finally {
    iso.kill(priority: Isolate.immediate);
    rp.close();
  }
}

List<double> _flat() => List<double>.filled(_n, _nn);

List<double> _with(Map<int, double> bad) {
  final x = _flat();
  bad.forEach((i, v) => x[i] = v);
  return x;
}

void main() {
  const to = Timeout(Duration(seconds: 15));
  const nan = double.nan;
  const inf = double.infinity;

  test('control: flat series has no cycles', () async {
    expect(await _count(_flat()), 0);
  }, timeout: to);

  test('single NaN mid-series returns, no cycles', () async {
    expect(await _count(_with({200: nan})), 0);
  }, timeout: to);

  test('NaN run mid-series returns, no cycles', () async {
    expect(
        await _count(_with({for (var i = 150; i < 190; i++) i: nan})), 0);
  }, timeout: to);

  test('NaN at the start returns, no cycles', () async {
    expect(await _count(_with({0: nan, 1: nan, 2: nan})), 0);
  }, timeout: to);

  test('NaN at the end returns, no cycles', () async {
    expect(await _count(_with({_n - 1: nan, _n - 2: nan})), 0);
  }, timeout: to);

  test('all-NaN segment returns, no cycles', () async {
    expect(await _count(List<double>.filled(_n, nan)), 0);
  }, timeout: to);

  test('+Infinity returns, no cycles', () async {
    expect(await _count(_with({200: inf})), 0);
  }, timeout: to);

  test('-Infinity returns, no cycles', () async {
    expect(await _count(_with({200: -inf})), 0);
  }, timeout: to);

  test('mixed NaN and +-Infinity returns, no cycles', () async {
    expect(await _count(_with({50: nan, 120: inf, 260: -inf, 330: nan})), 0);
  }, timeout: to);
}
