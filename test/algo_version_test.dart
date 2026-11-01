// Counters move for direct algorithm/output changes, including rounding and
// abstention. Dependency-only changes propagate through deps.
import 'package:openstrap_analytics/onehz.dart';
import 'package:test/test.dart';

void main() {
  test('PR output changes move their owning groups to counter 2', () {
    const changed = {
      'found.core', // Lomb-Scargle first-sample origin.
      'found.rr_correction', // Artifact-run cap, already bumped.
      'sleep.stage', // Already bumped; also owns adopted HRV staging paths.
      'hrv.freq', // HRV aggregator rounding and invalid-time abstention.
      'night.rhythm', // Cosinor/circadian and gap-aware irregular screening.
      'activity.load', // TRIMP, CTL/ATL and time-in-zone aggregation.
    };
    expect({for (final g in kAnalyticsGroupRegistry.groups)
      if (g.counter != 1) g.id: g.counter},
      {for (final id in changed) id: 2});
  });
}
