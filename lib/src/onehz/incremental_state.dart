part of 'incremental.dart';

void _version(Map<String, dynamic> json, String type) {
  if (json['version'] is! int || json['version'] != 1 || json['type'] != type) {
    throw FormatException('Unsupported $type checkpoint');
  }
}

int _count(Object? value) {
  if (value is! int || value < 0) throw const FormatException('Invalid count');
  return value;
}

double _number(Object? value, {bool finite = false}) {
  if (value is num && (!finite || value.isFinite)) return value.toDouble();
  if (!finite) {
    if (value == 'NaN') return double.nan;
    if (value == 'Infinity') return double.infinity;
    if (value == '-Infinity') return double.negativeInfinity;
  }
  throw const FormatException('Invalid number');
}

Object _encode(double value) => value.isFinite
    ? value
    : value.isNaN
        ? 'NaN'
        : value > 0
            ? 'Infinity'
            : '-Infinity';
List<double> _numbers(Object? value, {bool finite = false}) {
  if (value is! List) throw const FormatException('Expected numeric list');
  return [for (final item in value) _number(item, finite: finite)];
}

Map<String, dynamic> _map(Object? value) {
  if (value is! Map<String, dynamic>)
    throw const FormatException('Expected map');
  return value;
}

bool _same(double? a, double? b) =>
    a == b || (a != null && b != null && a.isNaN && b.isNaN);
bool _prefix(List<double> previous, List<double> next) {
  if (next.length < previous.length) return false;
  for (var i = 0; i < previous.length; i++) {
    if (!_same(previous[i], next[i])) return false;
  }
  return true;
}
