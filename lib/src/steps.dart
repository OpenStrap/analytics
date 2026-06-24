// §Steps — wrist pedometer (AN-2554). Pure math.
import 'dart:math' as math;

const _fs = 100;
const _filter = 8;
const _window = 33;
const _sens = 0.10;
const _thrOrder = 4;
const _confirm = 8;
const _maxminTimeout = 120;
const _gain = 1.11;

class StepParams {
  static const fs = _fs;
  static const filter = _filter;
  static const window = _window;
  static const sens = _sens;
  static const thrOrder = _thrOrder;
  static const confirm = _confirm;
  static const maxminTimeout = _maxminTimeout;
  static const gain = _gain;
}

// Expose locked params as a const-ish object mirror.
const STEP_PARAMS = {
  'FS': _fs,
  'FILTER': _filter,
  'WINDOW': _window,
  'SENS': _sens,
  'THR_ORDER': _thrOrder,
  'CONFIRM': _confirm,
  'MAXMIN_TIMEOUT': _maxminTimeout,
  'GAIN': _gain,
};

int pedometer(List<double> sig) {
  final n = sig.length;
  if (n < _window) return 0;
  final lp = List<double>.filled(n, 0);
  double acc = 0;
  for (var i = 0; i < n; i++) {
    acc += sig[i];
    if (i >= _filter) acc -= sig[i - _filter];
    lp[i] = acc / math.min(i + 1, _filter);
  }
  final half = _window >> 1;
  final cand = <_StepCand>[];
  for (var i = half; i < n - half; i++) {
    bool isMax = true, isMin = true;
    final v = lp[i];
    for (var j = i - half; j <= i + half; j++) {
      if (lp[j] > v) isMax = false;
      if (lp[j] < v) isMin = false;
      if (!isMax && !isMin) break;
    }
    if (isMax) {
      cand.add(_StepCand(i, true, v));
    } else if (isMin) {
      cand.add(_StepCand(i, false, v));
    }
  }
  final dyn = <double>[];
  double dynVal = sig.fold<double>(0, (s, v) => s + v) / n;
  int steps = 0, poss = 0;
  bool regulation = false;
  String state = 'max';
  double curMax = 0;
  int curMaxIdx = -1;
  for (final c in cand) {
    if (state == 'max') {
      if (c.max) {
        curMax = c.v;
        curMaxIdx = c.i;
        state = 'min';
      }
    } else {
      if (c.max) {
        if (c.v > curMax) {
          curMax = c.v;
          curMaxIdx = c.i;
        }
        continue;
      }
      if (c.i - curMaxIdx > _maxminTimeout) {
        state = 'max';
        poss = 0;
        regulation = false;
        continue;
      }
      final mx = curMax, mn = c.v;
      if (mx > dynVal + _sens / 2 && mn < dynVal - _sens / 2) {
        if (mx - mn > _sens) {
          dyn.add((mx + mn) / 2);
          if (dyn.length > _thrOrder) dyn.removeAt(0);
          dynVal = dyn.fold<double>(0, (s, v) => s + v) / dyn.length;
        }
        poss++;
        if (regulation) {
          steps++;
        } else if (poss >= _confirm) {
          steps += poss;
          regulation = true;
        }
      } else {
        poss = 0;
        regulation = false;
      }
      state = 'max';
    }
  }
  return steps;
}

int calcSteps(List<List<double>> minuteSignals) {
  int total = 0;
  for (final sig in minuteSignals) {
    total += pedometer(sig);
  }
  return (total * _gain + 0.5).floor();
}

class _StepCand {
  final int i;
  final bool max;
  final double v;
  _StepCand(this.i, this.max, this.v);
}
