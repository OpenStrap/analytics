// Minute builder mirroring src/__tests__/_harness.ts `min(...)`.
import 'package:openstrap_analytics/openstrap_analytics.dart';

class MinOpts {
  final double? steps;
  final bool? wrist_on;
  final double? hr_max;
  final String? act_class;
  const MinOpts({this.steps, this.wrist_on, this.hr_max, this.act_class});
}

Minute mkMin(double ts, double hr,
    [double activity = 0, MinOpts opts = const MinOpts()]) {
  return Minute(
    ts: ts,
    hr_avg: hr,
    hr_min: hr,
    hr_max: opts.hr_max ?? hr,
    hr_n: hr > 0 ? 60 : 0,
    activity: activity,
    steps: opts.steps ?? 0,
    wrist_on: opts.wrist_on ?? hr > 0,
    act_class: opts.act_class,
  );
}
