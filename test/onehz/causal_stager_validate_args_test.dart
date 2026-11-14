// tool/causal_stager_validate.dart: option values are read with their options.
import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

import '../../tool/causal_stager_validate.dart';

void main() {
  // # catches: `--step 60` leaves "60" among the positional arguments and the
  // tool then opens "60" as the one-Hz fixture ("fixture not found").
  test('option values are not fixture paths', () {
    final a = parseValidateArgs(['--step', '60']);
    expect(a.error, isNull);
    expect(a.pos, isEmpty);
    expect(a.stepSec, 60);
    expect(a.warmup, CausalStagerConfig.defaults.warmupEpochs);

    final b = parseValidateArgs(['--warmup', '20']);
    expect(b.pos, isEmpty);
    expect(b.warmup, 20);
    expect(b.stepSec, 30);

    final c = parseValidateArgs(
        ['a.csv', 'b.csv', '--step', '60', '--warmup', '20']);
    expect(c.pos, ['a.csv', 'b.csv']);
    expect((c.stepSec, c.warmup), (60, 20));

    final d = parseValidateArgs(['--step=45', 'a.csv', '--warmup=10', 'b.csv']);
    expect(d.pos, ['a.csv', 'b.csv']);
    expect((d.stepSec, d.warmup), (45, 10));
  });

  test('a bad command line is reported, not guessed at', () {
    expect(parseValidateArgs(['--step']).error, contains('needs a value'));
    expect(parseValidateArgs(['--step', 'x']).error, contains('positive whole'));
    expect(parseValidateArgs(['--step', '0']).error, contains('positive whole'));
    expect(parseValidateArgs(['--warmup=-3']).error, contains('positive whole'));
    expect(parseValidateArgs(['--nope']).error, contains('unknown option'));
  });

  test('no arguments means the defaults', () {
    final a = parseValidateArgs(const []);
    expect(a.error, isNull);
    expect(a.pos, isEmpty);
    expect((a.stepSec, a.warmup),
        (30, CausalStagerConfig.defaults.warmupEpochs));
  });
}
