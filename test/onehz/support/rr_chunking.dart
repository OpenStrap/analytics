// Shared helpers for the RR correction / streaming oracle tests.
import 'dart:convert';
import 'dart:math' as math;

/// JSON round trip through real text (what a SQLite blob would hold).
Map<String, dynamic> jsonRoundTrip(Map<String, dynamic> m) =>
    jsonDecode(jsonEncode(m)) as Map<String, dynamic>;

/// Random chunk boundaries over [0, n): sizes drawn from [sizes] (a mix of 1,
/// tiny, one-window, and huge) so every alignment against the 91/181-beat
/// windows is hit.
List<int> randomCuts(math.Random r, int n,
    {List<int> sizes = const [1, 2, 3, 7, 45, 46, 90, 91, 92, 180, 181, 500, 1500]}) {
  final cuts = <int>[];
  var at = 0;
  while (at < n) {
    final s = sizes[r.nextInt(sizes.length)];
    at = math.min(n, at + 1 + r.nextInt(s));
    cuts.add(at);
  }
  return cuts;
}

/// Cuts that fall every [sec] seconds of the beat clock: what a 15-minute
/// derive pass sees. [tsMs] sorted-ish epoch ms.
List<int> timeCuts(List<double> tsMs, double sec) {
  final cuts = <int>[];
  if (tsMs.isEmpty) return cuts;
  var next = tsMs.first + sec * 1000;
  for (var i = 0; i < tsMs.length; i++) {
    if (tsMs[i] >= next) {
      cuts.add(i);
      while (next <= tsMs[i]) {
        next += sec * 1000;
      }
    }
  }
  cuts.add(tsMs.length);
  return cuts;
}
