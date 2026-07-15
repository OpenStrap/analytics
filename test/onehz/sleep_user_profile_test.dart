// P2 — per-user rolling sleep profile: EWMA fold, JSON round-trip, cold-start
// blend weight, and that a stored profile is bounded (never dominant) inside
// the stager.
import 'package:test/test.dart';
import 'package:openstrap_analytics/onehz.dart';

void main() {
  group('SleepUserProfile', () {
    test('cold start: no nights ⇒ zero personal weight (pure per-night-local)',
        () {
      expect(const SleepUserProfile().personalWeight, 0.0);
      expect(const SleepUserProfile(nights: 0).personalWeight, 0.0);
    });

    test('personal weight grows with nights and hard-caps at 0.5', () {
      expect(const SleepUserProfile(nights: 7).personalWeight, closeTo(0.25, 1e-9));
      expect(const SleepUserProfile(nights: 14).personalWeight, 0.5);
      expect(const SleepUserProfile(nights: 40).personalWeight, 0.5);
    });

    test('first fold takes the observation whole (alpha=1)', () {
      const base = SleepUserProfile();
      final o = const SleepNightObservation(
        epochs: 700,
        hrFloorP5: 50,
        hrSleepMedian: 58,
        rmssdMed: 40,
      );
      final p = base.fold(o);
      expect(p.nights, 1);
      expect(p.hrFloorP5, 50);
      expect(p.hrSleepMedian, 58);
      expect(p.rmssdMed, 40);
    });

    test('subsequent folds EWMA toward new observations, absent axis untouched',
        () {
      var p = const SleepUserProfile().fold(
        const SleepNightObservation(epochs: 700, hrSleepMedian: 60, rmssdMed: 40),
      );
      // Second night: higher HR median, and NO rmssd observed this night.
      p = p.fold(const SleepNightObservation(epochs: 700, hrSleepMedian: 70));
      // alpha at n2=2 is max(1/2, 2/15)=0.5 → 60*0.5 + 70*0.5 = 65.
      expect(p.hrSleepMedian, closeTo(65, 1e-9));
      // rmssd had no new observation → retained from night 1.
      expect(p.rmssdMed, 40);
      expect(p.nights, 2);
    });

    test('EWMA alpha floors at ~2/(N+1) for settled profiles', () {
      var p = const SleepUserProfile();
      for (var i = 0; i < 30; i++) {
        p = p.fold(const SleepNightObservation(epochs: 700, hrSleepMedian: 60));
      }
      // A single deviating night barely moves a settled profile.
      final q = p.fold(const SleepNightObservation(epochs: 700, hrSleepMedian: 90));
      final a = 2.0 / (14 + 1);
      expect(q.hrSleepMedian, closeTo(60 * (1 - a) + 90 * a, 1e-6));
    });

    test('JSON round-trips and omits null axes', () {
      final p = const SleepUserProfile().fold(
        const SleepNightObservation(
          epochs: 700,
          hrFloorP5: 50,
          hrFloorP25: 55,
          hrSleepMedian: 60,
          hrArousal: 72,
          enmoStillCut: 0.01,
          enmoMoveCut: 0.05,
          lfhfMed: 1.2,
          rkMed: 3.4,
        ),
      );
      final j = p.toJson();
      expect(j.containsKey('rmssd_med'), isFalse); // never observed ⇒ omitted
      final back = SleepUserProfile.fromJson(j);
      expect(back.nights, p.nights);
      expect(back.hrFloorP5, 50);
      expect(back.hrArousal, 72);
      expect(back.lfhfMed, 1.2);
      expect(back.rmssdMed, isNull);
    });

    test('a profile consistent with the night does not destabilize staging',
        () {
      // Synthetic still, low-HR night (should read as overwhelmingly asleep).
      const n = 4 * 3600; // 4 h at 1 Hz
      final hr = List<double>.filled(n, 55.0);
      final accel = <AccelSample>[
        for (var i = 0; i < n; i++) AccelSample(i * 1000.0, 0, 0, 1.0),
      ];
      final noProfile = cardioStager(hr, accel).base;
      // A profile whose baselines AGREE with this night (median ~55, a plausibly
      // higher arousal, a lower floor). At max personal weight (0.5) the blend
      // must not turn a clean sleep night into wake.
      final benign = const SleepUserProfile(
        nights: 40, // personalWeight = 0.5 (max)
        hrSleepMedian: 55,
        hrArousal: 75,
        hrFloorP25: 50,
        hrFloorP5: 48,
      );
      final withProfile = cardioStager(hr, accel, userProfile: benign).base;
      // Both stay overwhelmingly asleep — the bounded blend is safe here.
      expect(noProfile.wakePct, lessThan(20.0));
      expect(withProfile.wakePct, lessThan(20.0));
      // Sanity: the blend actually shifted SOMETHING vs a no-op (or matched it).
      expect(
        (withProfile.wakePct - noProfile.wakePct).abs(),
        lessThan(5.0),
        reason: 'a consistent profile must not swing staging wildly',
      );
    });
  });
}
