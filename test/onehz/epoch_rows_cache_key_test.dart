// EpochRows cache fingerprint: byte-wise hashing.
//
// A row's cache key hashes the data the row can observe. Mixing a whole 64-bit
// word per step lets two sign-bit flips cancel, so a row whose data changed in
// exactly two sign bits kept its key and a warm lookup served the old row.
import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

import 'support/epoch_input.dart';

int _fold(EpochInput input, CardioRowCache cache) {
  final er = EpochRows(rowCache: cache, anchorMs: input.t0Ms);
  input.foldInto(er, 0, input.seconds);
  er.allRows();
  return cache.misses;
}

void main() {
  // # catches: negating the x and y of one accel sample (two consecutive words
  // of the key) leaves every key identical under the word-wise mix, so no row
  // that sees the sample is looked up again.
  test('two sign-bit changes in a row\'s data change its key', () {
    final input = EpochInput.make(nightSegs(), t0Ms: kAlignedT0Ms, seed: 41);
    final cache = CardioRowCache();
    final cold = _fold(input, cache);
    expect(cold, greaterThan(20), reason: 'the first pass fills the cache');

    final i = 600;
    final a = input.accel[i];
    final accel = [...input.accel]..[i] = AccelSample(a.tsMs, -a.x, -a.y, a.z);
    final changed = EpochInput(
        input.t0Ms, input.seconds, input.hr, accel, input.rrMs, input.rrTs);

    final before = cache.misses;
    _fold(changed, cache);
    final misses = cache.misses - before;
    // A 300 s key range holds about ten 30 s epochs; every one that sees the
    // sample is recomputed.
    expect(misses, greaterThanOrEqualTo(8));
    // The same data again is all hits.
    final again = cache.misses;
    _fold(changed, cache);
    expect(cache.misses - again, 0);
  });
}
