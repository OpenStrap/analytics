// Ported 1:1 from src/__tests__/analytics.test.ts. Every assertion + fixture
// is represented verbatim (same inputs, expected numbers, epsilon tolerances).
import 'dart:math' as math;
import 'package:test/test.dart';
import 'package:openstrap_analytics/openstrap_analytics.dart';
import '_harness.dart';

final baseline = const Baseline(
  resting_hr: 50,
  max_hr: 190,
  sleep_need_min: 480,
  skin_temp: 34.0,
  chronic_strain: 10,
);

void main() {
  test('§1 calcRestingHR', () {
    final mins = [40, 42, 44, 46, 48, 50]
        .asMap()
        .entries
        .map((e) => mkMin((e.key * 60).toDouble(), e.value.toDouble()))
        .toList();
    final r = calcRestingHR(mins, const SleepWindow(onset_ts: 0, wake_ts: 5 * 60));
    expect(r.resting_hr ?? -1, closeTo(40.5, 0.01));
    expect(r.tier == 'HIGH', isTrue);
    expect(r.confidence, closeTo(6 / 240, 0.001));

    final r2 = calcRestingHR(mins, null);
    expect(r2.resting_hr != null, isTrue);
    expect(r2.confidence <= 0.5, isTrue);

    final off = calcRestingHR([], const SleepWindow(onset_ts: 0, wake_ts: 60));
    expect(off.resting_hr == null && off.confidence == 0, isTrue);
  });

  test('§2 calcStrain', () {
    final rest =
        List.generate(30, (i) => mkMin((i * 60).toDouble(), 50));
    final rs = calcStrain(rest, baseline);
    expect(rs.trimp, closeTo(0, 1e-9));
    expect(rs.score, closeTo(0, 1e-9));

    final hard =
        List.generate(30, (i) => mkMin((i * 60).toDouble(), 150));
    final hs = calcStrain(hard, baseline);
    expect(hs.trimp, closeTo(54.0477, 0.01));
    expect(hs.score, closeTo(9.89, 0.01));
    expect(hs.confidence, closeTo(1, 1e-9));
    expect(hs.max_hr_source == 'measured', isTrue);

    final gapped = <Minute>[
      ...List.generate(15, (i) => mkMin((i * 60).toDouble(), 150)),
      ...List.generate(10,
          (i) => mkMin(((i + 15) * 60).toDouble(), 0, 0, const MinOpts(wrist_on: false))),
      ...List.generate(15, (i) => mkMin(((i + 25) * 60).toDouble(), 150)),
    ];
    final cont =
        List.generate(30, (i) => mkMin((i * 60).toDouble(), 150));
    expect(calcStrain(gapped, baseline).trimp,
        closeTo(calcStrain(cont, baseline).trimp, 1e-9));

    final insane =
        List.generate(1000, (i) => mkMin((i * 60).toDouble(), 190));
    expect(calcStrain(insane, baseline).score <= 21, isTrue);
  });

  test('§3 calcHrZones', () {
    final mins = [100, 120, 150, 160, 175]
        .asMap()
        .entries
        .map((e) => mkMin((e.key * 60).toDouble(), e.value.toDouble()))
        .toList();
    final z = calcHrZones(mins, baseline);
    expect(z.zone1_min == 1, isTrue);
    expect(z.zone2_min == 1, isTrue);
    expect(z.zone3_min == 1, isTrue);
    expect(z.zone4_min == 1, isTrue);
    expect(z.zone5_min == 1, isTrue);
    expect(z.max_hr_source == 'measured', isTrue);

    final noMaxBaseline = const Baseline(
        resting_hr: 50,
        max_hr: 0,
        sleep_need_min: 480,
        skin_temp: 34.0,
        chronic_strain: 10);
    final ageOnly = calcHrZones(
        [mkMin(0, 0, 0, const MinOpts(wrist_on: false))],
        noMaxBaseline,
        const Profile(age: 40));
    expect(ageOnly.max_hr_source == 'age' && ageOnly.max_hr_used == 180, isTrue);
  });

  test('§4 calcCalories', () {
    final one = [mkMin(0, 120)];
    final c = calcCalories(one, const Profile(age: 30, weight_kg: 70), 60);
    expect(c.kcal, closeTo(7.73, 0.2));
    expect(c.tier == 'ESTIMATE' && c.label.contains('est.'), isTrue);
    final atRest =
        calcCalories([mkMin(0, 60)], const Profile(age: 30, weight_kg: 70), 60);
    expect(atRest.kcal < 0.01, isTrue);
    final low =
        calcCalories([mkMin(0, 40)], const Profile(age: 30, weight_kg: 70), 60);
    expect(low.kcal >= 0, isTrue);
    final cm = calcCalories(
        one, const Profile(age: 30, weight_kg: 70, sex: 'm'), 60);
    expect(cm.kcal != c.kcal, isTrue);
    final fullRestDay =
        List.generate(1440, (i) => mkMin((i * 60).toDouble(), 58));
    final fr = calcCalories(
        fullRestDay, const Profile(age: 29, weight_kg: 75, sex: 'm'), 58);
    expect(fr.kcal < 20, isTrue);
  });

  test('§5 calcSleep', () {
    final mins = <Minute>[];
    for (var i = 0; i < 5; i++) mins.add(mkMin((i * 60).toDouble(), 70, 2000));
    for (var i = 5; i < 205; i++) mins.add(mkMin((i * 60).toDouble(), 45, 50));
    for (var i = 205; i < 210; i++) mins.add(mkMin((i * 60).toDouble(), 72, 2000));
    final s = calcSleep(mins, baseline);
    expect(s.duration_min >= 195, isTrue);
    expect(s.efficiency > 0.99, isTrue);
    expect(s.onset_ts == 5 * 60, isTrue);
    expect(s.stages != null && s.stages_beta == true, isTrue);
    expect(s.tier == 'HIGH', isTrue);
    expect(s.inputs_used.contains('baseline.skin_temp'), isTrue);

    final frag = <Minute>[];
    for (var i = 0; i < 5; i++) frag.add(mkMin((i * 60).toDouble(), 70, 2000));
    for (var i = 5; i < 100; i++) frag.add(mkMin((i * 60).toDouble(), 45, 50));
    for (var i = 100; i < 110; i++) frag.add(mkMin((i * 60).toDouble(), 72, 1800));
    for (var i = 110; i < 205; i++) frag.add(mkMin((i * 60).toDouble(), 45, 50));
    for (var i = 205; i < 210; i++) frag.add(mkMin((i * 60).toDouble(), 72, 2000));
    final f = calcSleep(frag, baseline);
    expect(f.onset_ts == 5 * 60, isTrue);
    expect(f.wake_ts == 204 * 60, isTrue);
    expect(f.in_bed_min == 200, isTrue);
    expect(f.duration_min == 190, isTrue);
    expect(f.efficiency > 0.9 && f.efficiency < 1, isTrue);

    final e = calcSleep([], baseline);
    expect(e.duration_min == 0 && e.confidence == 0, isTrue);

    final split = <Minute>[];
    for (var i = 0; i < 5; i++) split.add(mkMin((i * 60).toDouble(), 70, 2000));
    for (var i = 5; i < 255; i++) split.add(mkMin((i * 60).toDouble(), 45, 50));
    for (var i = 255; i < 315; i++) split.add(mkMin((i * 60).toDouble(), 75, 2500));
    for (var i = 315; i < 405; i++) split.add(mkMin((i * 60).toDouble(), 72, 60));
    final sp = calcSleep(split, baseline);
    expect(sp.duration_min >= 245 && sp.duration_min <= 255, isTrue);
    expect(sp.in_bed_min <= 260, isTrue);
    expect((sp.wake_ts ?? 0) <= 255 * 60, isTrue);

    final offwrist = <Minute>[];
    for (var i = 0; i < 5; i++) offwrist.add(mkMin((i * 60).toDouble(), 70, 2000));
    for (var i = 5; i < 205; i++) offwrist.add(mkMin((i * 60).toDouble(), 45, 50));
    for (var i = 205; i < 245; i++) {
      offwrist.add(mkMin((i * 60).toDouble(), 0, 0, const MinOpts(wrist_on: false)));
    }
    for (var i = 245; i < 285; i++) offwrist.add(mkMin((i * 60).toDouble(), 70, 60));
    final ow = calcSleep(offwrist, baseline);
    expect(ow.duration_min >= 195 && ow.duration_min <= 205, isTrue);
    expect(ow.in_bed_min <= 210, isTrue);

    final aboveFloor = <Minute>[];
    for (var i = 0; i < 30; i++) aboveFloor.add(mkMin((i * 60).toDouble(), 95, 0));
    for (var i = 30; i < 430; i++) aboveFloor.add(mkMin((i * 60).toDouble(), 62, 0));
    for (var i = 430; i < 470; i++) aboveFloor.add(mkMin((i * 60).toDouble(), 95, 0));
    final af = calcSleep(aboveFloor, baseline);
    expect(af.duration_min >= 380, isTrue);

    final flatAwake = <Minute>[];
    for (var i = 0; i < 300; i++) flatAwake.add(mkMin((i * 60).toDouble(), 92, 0));
    final fa = calcSleep(flatAwake, baseline);
    expect(fa.duration_min <= 30, isTrue);

    final giant = <Minute>[];
    for (var i = 0; i < 1080; i++) giant.add(mkMin((i * 60).toDouble(), 45, 50));
    final g = calcSleep(giant, baseline);
    expect(g.in_bed_min <= 14 * 60, isTrue);
  });

  test('§5b calcSleepPeriods', () {
    final day = <Minute>[];
    for (var i = 0; i < 5; i++) day.add(mkMin((i * 60).toDouble(), 70, 2000));
    for (var i = 5; i < 205; i++) day.add(mkMin((i * 60).toDouble(), 45, 50));
    for (var i = 205; i < 305; i++) day.add(mkMin((i * 60).toDouble(), 75, 2500));
    for (var i = 305; i < 345; i++) day.add(mkMin((i * 60).toDouble(), 48, 50));
    for (var i = 345; i < 350; i++) day.add(mkMin((i * 60).toDouble(), 72, 2000));
    final v2 = calcSleepPeriods(day, baseline);
    expect(v2.periods.length == 2, isTrue);
    final mainP = v2.periods[v2.main_idx ?? -1];
    expect(mainP.is_main == true, isTrue);
    expect(mainP.duration_min >= 195, isTrue);
    final napP = v2.periods.firstWhere((p) => !p.is_main);
    expect(napP.duration_min >= 30 && napP.duration_min <= 45, isTrue);
    expect(v2.total_asleep_min >= 228, isTrue);
    expect(v2.periods.every((p) => p.confidence >= 0 && p.confidence <= 1), isTrue);

    final oneNight = <Minute>[];
    for (var i = 0; i < 5; i++) oneNight.add(mkMin((i * 60).toDouble(), 70, 2000));
    for (var i = 5; i < 205; i++) oneNight.add(mkMin((i * 60).toDouble(), 45, 50));
    for (var i = 205; i < 210; i++) oneNight.add(mkMin((i * 60).toDouble(), 72, 2000));
    final one = calcSleepPeriods(oneNight, baseline);
    expect(one.periods.length == 1 && one.periods[0].is_main, isTrue);

    final micro = <Minute>[];
    for (var i = 0; i < 5; i++) micro.add(mkMin((i * 60).toDouble(), 70, 2000));
    for (var i = 5; i < 13; i++) micro.add(mkMin((i * 60).toDouble(), 45, 50));
    for (var i = 13; i < 20; i++) micro.add(mkMin((i * 60).toDouble(), 72, 2000));
    final m2 = calcSleepPeriods(micro, baseline);
    expect(m2.periods.isEmpty && m2.confidence == 0, isTrue);

    final ep = calcSleepPeriods([], baseline);
    expect(ep.periods.isEmpty && ep.confidence == 0, isTrue);
  });

  test('§6 calcSleepRegularity', () {
    const day = 86400;
    final same = [0, 1, 2]
        .map((d) => NightSummary(
            onset_ts: (d * day + 23 * 3600).toDouble(),
            wake_ts: (d * day + 7 * 3600).toDouble()))
        .toList();
    final r = calcSleepRegularity(same);
    expect(r.sri, closeTo(100, 0.01));
    expect(r.confidence == 0.7, isTrue);

    expect(calcSleepRegularity(same.sublist(0, 2)).confidence == 0, isTrue);

    final jit = [0, 1, 2]
        .asMap()
        .entries
        .map((e) => NightSummary(
            onset_ts: (e.value * day + 23 * 3600 + e.key * 1800).toDouble(),
            wake_ts: (e.value * day + 7 * 3600).toDouble()))
        .toList();
    expect(calcSleepRegularity(jit).sri < 100, isTrue);
  });

  test('§7 detectSessions', () {
    final mins = <Minute>[];
    for (var i = 0; i < 10; i++) mins.add(mkMin((i * 60).toDouble(), 55, 1));
    for (var i = 10; i < 20; i++) {
      mins.add(mkMin((i * 60).toDouble(), 150, 100, const MinOpts(hr_max: 165)));
    }
    for (var i = 20; i < 30; i++) mins.add(mkMin((i * 60).toDouble(), 55, 1));
    final sessions = detectSessions(mins, baseline);
    expect(sessions.length == 1, isTrue);
    final ses = sessions[0];
    expect(ses.start_ts == 10 * 60, isTrue);
    expect(ses.duration_min >= 9, isTrue);
    expect(ses.confidence == 0.8 && ses.type_confidence == 0.4, isTrue);
    expect(ses.type == 'run/cardio', isTrue);
    expect(ses.strain > 0 && ses.kcal > 0, isTrue);

    final short = <Minute>[];
    for (var i = 0; i < 10; i++) short.add(mkMin((i * 60).toDouble(), 55, 1));
    for (var i = 10; i < 12; i++) short.add(mkMin((i * 60).toDouble(), 150, 100));
    for (var i = 12; i < 20; i++) short.add(mkMin((i * 60).toDouble(), 55, 1));
    expect(detectSessions(short, baseline).length == 1, isTrue);

    final tiny = <Minute>[];
    for (var i = 0; i < 10; i++) tiny.add(mkMin((i * 60).toDouble(), 55, 1));
    tiny.add(mkMin((10 * 60).toDouble(), 150, 100));
    for (var i = 11; i < 20; i++) tiny.add(mkMin((i * 60).toDouble(), 55, 1));
    expect(detectSessions(tiny, baseline).isEmpty, isTrue);

    final cyc = <Minute>[];
    for (var i = 0; i < 10; i++) cyc.add(mkMin((i * 60).toDouble(), 55, 1));
    for (var i = 10; i < 20; i++) {
      cyc.add(mkMin((i * 60).toDouble(), 140, 100,
          const MinOpts(hr_max: 150, act_class: 'cycle')));
    }
    for (var i = 20; i < 30; i++) cyc.add(mkMin((i * 60).toDouble(), 55, 1));
    final cs = detectSessions(cyc, baseline)[0];
    expect(cs.type == 'cycle' && cs.type_confidence > 0.4, isTrue);
    expect(cs.detected_type == 'cycle', isTrue);
  });

  test('§8 calcHrRecovery', () {
    final mins = <Minute>[];
    for (var i = 0; i < 5; i++) {
      mins.add(mkMin((i * 60).toDouble(), 150, 50, const MinOpts(hr_max: 155)));
    }
    mins.add(mkMin((5 * 60).toDouble(), 165, 50, const MinOpts(hr_max: 170)));
    mins.add(mkMin((6 * 60).toDouble(), 130, 10, const MinOpts(hr_max: 135)));
    final hrr = calcHrRecovery(mins, baseline);
    expect(hrr.hrr60 ?? -1, closeTo(40, 0.01));
    expect(hrr.peak_hr ?? -1, closeTo(170, 0.01));
    expect(hrr.confidence == 0.7, isTrue);

    final flat = List.generate(10, (i) => mkMin((i * 60).toDouble(), 55, 1));
    final nf = calcHrRecovery(flat, baseline);
    expect(nf.hrr60 == null && nf.confidence == 0, isTrue);
  });

  test('§9 calcLoad / calcFitnessTrend', () {
    final steady =
        List.generate(28, (i) => DailyStrain((i * 86400).toDouble(), 10));
    final load = calcLoad(steady);
    expect(load.acwr ?? -1, closeTo(1.0, 1e-9));
    expect(load.band == 'optimal', isTrue);

    final spike = List.generate(28,
        (i) => DailyStrain((i * 86400).toDouble(), i >= 21 ? 20 : 10));
    final sl = calcLoad(spike);
    expect(sl.band == 'caution' && (sl.acwr ?? 0) > 1.3, isTrue);

    expect(calcLoad(steady.sublist(0, 5)).band == 'unknown', isTrue);

    final daily = List.generate(
        28,
        (i) => DayHistory(
            resting_hr: 60 - i * 0.2, hrr60: 30 + i * 0.3));
    final ft = calcFitnessTrend(daily);
    expect(ft.direction == 'improving', isTrue);
    expect(ft.rhr_slope < 0 && ft.hrr_slope > 0, isTrue);
    // never emits a VO2max number — only direction + slopes.
    expect(ft.toJson().containsKey('vo2max'), isFalse);
  });

  test('§10 calcRecovery / calcAnomaly / calcIllness', () {
    final base = <double>[72, 75, 78, 74, 76, 73, 77, 75, 74, 76];
    final atBase = calcRecovery(75, base, date: '2026-06-13');
    expect(atBase.score!, closeTo(50, 8));
    expect(atBase.tier == 'HIGH' && atBase.note == 'HRV-based', isTrue);
    expect(atBase.drivers!.isNotEmpty && atBase.drivers![0].ref!.metric == 'hrv',
        isTrue);
    final high = calcRecovery(100, base);
    final low = calcRecovery(50, base);
    expect(high.score! > atBase.score! && low.score! < atBase.score!, isTrue);
    expect(
        calcRecovery(75, <double>[70, 72]).score == null &&
            calcRecovery(75, <double>[70, 72]).confidence == 0,
        isTrue);
    expect(calcRecovery(null, base).score == null, isTrue);

    final an = calcAnomaly(
        const AnomalyInputs(recent_rhr: [50, 51, 55, 56]), baseline);
    expect(an.signal == true && an.triggers.contains('rhr_elevated_2d'), isTrue);
    expect(an.note == 'signal, not a diagnosis', isTrue);
    final anLuteal = calcAnomaly(
        const AnomalyInputs(recent_rhr: [50, 51, 55, 56]), baseline,
        cyclePhase: 'luteal');
    expect(anLuteal.signal == false && RegExp('cycle', caseSensitive: false).hasMatch(anLuteal.note), isTrue);

    final hist = IllnessHistory(
      resting_hr: List.generate(20, (i) => 55 + (i % 3).toDouble()),
      rmssd: List.generate(20, (i) => 74 + (i % 5).toDouble()),
      skin_temp: List.generate(20, (i) => 34 + (i % 2) * 0.1),
    );
    final sick = calcIllness(
        const IllnessToday(resting_hr: 68, rmssd: 45, skin_temp: 35.2), hist);
    expect(sick.signal == true && sick.triggers.length >= 2, isTrue);
    expect(sick.note == 'a signal, not a diagnosis', isTrue);
    final well = calcIllness(
        const IllnessToday(resting_hr: 56, rmssd: 76, skin_temp: 34.05), hist);
    expect(well.signal == false, isTrue);

    final histR = IllnessHistory(
      resting_hr: hist.resting_hr,
      rmssd: hist.rmssd,
      skin_temp: hist.skin_temp,
      resp_rate: List.generate(20, (i) => 14 + (i % 2).toDouble()),
    );
    final sickResp = calcIllness(
        const IllnessToday(
            resting_hr: 56, rmssd: 45, skin_temp: 34.05, resp_rate: 19),
        histR);
    expect(sickResp.signal == true && sickResp.triggers.contains('resp'), isTrue);
    expect(sickResp.inputs_used.contains('resp_rate'), isTrue);

    const cycIn = IllnessToday(resting_hr: 64, rmssd: 76, skin_temp: 35.0);
    final noCyc = calcIllness(cycIn, hist);
    expect(
        noCyc.signal == true &&
            noCyc.triggers.contains('rhr') &&
            noCyc.triggers.contains('temp'),
        isTrue);
    final luteal = calcIllness(cycIn, hist, cyclePhase: 'luteal');
    expect(luteal.signal == false, isTrue);
    expect(RegExp('cycle', caseSensitive: false).hasMatch(luteal.note), isTrue);
    final lutealReal = calcIllness(
        const IllnessToday(
            resting_hr: 64, rmssd: 45, skin_temp: 35.0, resp_rate: 19),
        histR,
        cyclePhase: 'luteal');
    expect(lutealReal.signal == true, isTrue);
  });

  test('§11 calcBaselines', () {
    final hist = List.generate(
        30,
        (i) => DayHistory(
              resting_hr: 50 + (i % 3).toDouble(),
              sleep_duration_min: 470 + (i % 5).toDouble(),
              skin_temp: 34 + (i % 2) * 0.1,
              daily_strain: 10 + (i % 4).toDouble(),
              session_hr_max: 180 + (i % 10).toDouble(),
              zone_min: const [10, 20, 15, 5, 2],
            ));
    final bl = calcBaselines(hist, const Profile(age: 40));
    expect(bl.resting_hr != null && bl.resting_hr! >= 50 && bl.resting_hr! <= 52,
        isTrue);
    expect(bl.max_hr == 189 && bl.max_hr_source == 'measured', isTrue);
    expect(bl.chronic_strain != null, isTrue);
    expect(bl.zone_min != null && bl.zone_min![0] == 10, isTrue);
    expect(bl.confidence, closeTo(1, 1e-9));

    final quiet = hist
        .map((d) => DayHistory(
              resting_hr: d.resting_hr,
              sleep_duration_min: d.sleep_duration_min,
              skin_temp: d.skin_temp,
              daily_strain: d.daily_strain,
              session_hr_max: 150,
              zone_min: d.zone_min,
            ))
        .toList();
    final blQuiet = calcBaselines(quiet, const Profile(age: 30));
    expect(blQuiet.max_hr == 187 && blQuiet.max_hr_source == 'age', isTrue);

    final noSess = hist
        .map((d) => DayHistory(
              resting_hr: d.resting_hr,
              sleep_duration_min: d.sleep_duration_min,
              skin_temp: d.skin_temp,
              daily_strain: d.daily_strain,
              session_hr_max: null,
              zone_min: d.zone_min,
            ))
        .toList();
    final bl2 = calcBaselines(noSess, const Profile(age: 30));
    expect(bl2.max_hr == 187 && bl2.max_hr_source == 'age', isTrue);

    final seed = calcBaselines(hist.sublist(0, 3));
    expect(seed.confidence, closeTo(3 / 30, 1e-9));
  });

  test('determinism', () {
    final mins =
        List.generate(30, (i) => mkMin((i * 60).toDouble(), 150, 10));
    final a = calcStrain(mins, baseline).toJson().toString();
    final b = calcStrain(mins, baseline).toJson().toString();
    expect(a == b, isTrue);
  });

  test('buildCoach', () {
    final lo = buildCoach(const CoachInputs(
      readiness: 35,
      readiness_components: CoachReadinessComponents(0.5, 0.4, 0.6),
      resting_hr: 70,
      baseline_rhr: 60,
      rhr_recent: [60, 61, 70],
      strain_today: 5,
      acwr: 1.5,
      sleep_last_min: 300,
      sleep_need_min: 480,
      sleep_debt_min: 200,
      sleep_efficiency: 0.7,
      sri: 60,
      fitness_direction: 'flat',
      anomaly: null,
    ));
    expect(lo.strain_target!.value <= 10, isTrue);
    expect(
        lo.plan.any((s) => s.category == 'load' || s.category == 'recovery'),
        isTrue);
    expect(lo.plan.any((s) => s.id == 'sleep.debt'), isTrue);
    expect(lo.readiness_contributors.length == 3, isTrue);
    expect(lo.summary.isNotEmpty, isTrue);

    final hi = buildCoach(const CoachInputs(
      readiness: 85,
      readiness_components: CoachReadinessComponents(1, 1, 0.9),
      resting_hr: 55,
      baseline_rhr: 58,
      rhr_recent: [58, 57, 55],
      strain_today: 2,
      acwr: 0.6,
      sleep_last_min: 480,
      sleep_need_min: 480,
      sleep_debt_min: 0,
      sleep_efficiency: 0.92,
      sri: 90,
      fitness_direction: 'rising',
      anomaly: null,
    ));
    expect(hi.strain_target!.value >= 14, isTrue);
    expect(hi.plan.any((s) => s.id == 'load.low' || s.id == 'recovery.high'),
        isTrue);

    CoachInputs det() => const CoachInputs(
          readiness: 50,
          resting_hr: 60,
          baseline_rhr: 60,
          rhr_recent: [60],
          strain_today: 8,
          acwr: 1.0,
          sleep_last_min: 400,
          sleep_need_min: 480,
          sleep_debt_min: 0,
          sleep_efficiency: 0.85,
          sri: 80,
          fitness_direction: 'flat',
          anomaly: null,
        );
    expect(buildCoach(det()).toJson().toString() ==
        buildCoach(det()).toJson().toString(), isTrue);
  });

  test('§HRV time/freq/SI', () {
    final alt =
        List.generate(60, (i) => (i % 2 != 0 ? 820 : 800).toDouble());
    final td = timeDomainHrv(alt);
    expect(td.rmssd!, closeTo(20, 0.01));
    expect(td.mean_rr!, closeTo(810, 0.1));
    expect(td.mean_hr!, closeTo(60000 / 810, 0.1));
    expect(cleanRr([900, 250, 905, 2500, 910]).length == 3, isTrue);

    double acc = 0;
    final resp = <double>[];
    for (var i = 0; i < 320; i++) {
      final rr = 900 + 60 * math.sin(2 * math.pi * 0.25 * (acc / 1000));
      resp.add(rr.roundToDouble());
      acc += rr;
    }
    final fd = freqDomainHrv(resp);
    expect(fd.resp_rate != null && (fd.resp_rate! - 15).abs() < 3, isTrue);
    expect(fd.hf! > 0 && fd.lf_hf != null, isTrue);

    final tight =
        List.generate(100, (i) => 900 + (i % 3).toDouble());
    final spread =
        List.generate(100, (i) => 700 + ((i * 4) % 400).toDouble());
    final siT = baevskyStressIndex(tight).si!,
        siS = baevskyStressIndex(spread).si!;
    expect(siT > siS, isTrue);
  });

  test('§12 calcStress (HRV)', () {
    final rr = List.generate(120, (i) => 850 + (i % 5) * 8.0);
    final si = baevskyStressIndex(rr).si!;
    final noBase = calcStress(rr, []);
    expect(noBase.score == null && noBase.si != null, isTrue);
    expect(noBase.tier == 'ESTIMATE', isTrue);
    final baseSI = [
      si * 0.8,
      si * 0.9,
      si,
      si * 1.1,
      si * 1.2,
      si * 0.95,
      si * 1.05
    ];
    final withBase = calcStress(rr, baseSI);
    expect(withBase.score != null && withBase.level != null, isTrue);
    expect(withBase.drivers!.any((d) => d.label.contains('Baevsky')), isTrue);
    final tightRr = List.generate(120, (i) => 850 + (i % 2).toDouble());
    final hi = calcStress(tightRr, baseSI);
    expect((hi.score ?? 0) >= (withBase.score ?? 0), isTrue);
    expect(calcStress(rr, baseSI).toJson().toString() ==
        calcStress(rr, baseSI).toJson().toString(), isTrue);
  });

  test('§calcSpo2Index', () {
    expect(calcSpo2Index([0.85, 0.86, 0.85], 0.85).index == null, isTrue);
    expect(calcSpo2Index([0.85, 0.86], 0.85).confidence == 0, isTrue);
    final stable = List.generate(200, (_) => 0.850);
    final seed = calcSpo2Index(stable, null);
    expect(seed.index == null, isTrue);
    expect(seed.night_ratio!, closeTo(0.85, 0.001));
    final better = calcSpo2Index(List.generate(200, (_) => 0.840), 0.850);
    expect(better.index != null && better.index! > 0, isTrue);
    expect(better.confidence > 0.8, isTrue);
    final noisy = calcSpo2Index(
        List.generate(200, (i) => 0.85 + (i % 2 != 0 ? 0.08 : -0.08)), 0.850);
    expect(noisy.confidence < 0.3, isTrue);
    expect(calcSpo2Index(List.generate(200, (_) => 3.0), 0.85).index == null,
        isTrue);
  });

  test('§calcSleepStress', () {
    final calm = List.generate(240, (i) => mkMin((i * 60).toDouble(), 50, 5));
    final cs = calcSleepStress(calm, baseline);
    expect(cs.arousal_events == 0, isTrue);
    expect(cs.score != null && cs.score! < 10, isTrue);
    final restless = List.generate(240, (i) {
      final surge = i % 40 == 0;
      return mkMin((i * 60).toDouble(), surge ? 80 : 50, surge ? 3000 : 5);
    });
    final rs = calcSleepStress(restless, baseline);
    expect(rs.arousal_events >= 4, isTrue);
    expect(rs.score! > cs.score!, isTrue);
    expect(rs.events.isNotEmpty && rs.events.any((e) => e['kind'] == 'arousal'),
        isTrue);
  });

  test('§13 calcNocturnalHeart', () {
    final sleep = [48, 46, 44, 46, 48, 50, 47, 45]
        .asMap()
        .entries
        .map((e) => mkMin((e.key * 60).toDouble(), e.value.toDouble()))
        .toList();
    final day =
        List.generate(20, (i) => mkMin(((100 + i) * 60).toDouble(), 70));
    final n = calcNocturnalHeart(
        sleep, day, const Baseline(resting_hr: 50, max_hr: 190, sleep_need_min: 480, skin_temp: 34.0, chronic_strain: 10, sleeping_hr: 50));
    expect(n.sleeping_hr_avg != null && (n.sleeping_hr_avg! - 47).abs() <= 1,
        isTrue);
    expect(n.sleeping_hr_min != null && n.sleeping_hr_min! <= n.sleeping_hr_avg!,
        isTrue);
    expect(n.day_hr_avg == 70, isTrue);
    expect(n.dip_pct != null && n.dip_pct! > 0.25, isTrue);
    expect(n.elevated == false, isTrue);
    final hi = calcNocturnalHeart(
        sleep, day, const Baseline(resting_hr: 50, max_hr: 190, sleep_need_min: 480, skin_temp: 34.0, chronic_strain: 10, sleeping_hr: 42));
    expect(hi.elevated == true, isTrue);
    final none = calcNocturnalHeart(
        [], day, const Baseline(resting_hr: 50, max_hr: 190, sleep_need_min: 480, skin_temp: 34.0, chronic_strain: 10, sleeping_hr: 50));
    expect(none.sleeping_hr_avg == null && none.confidence == 0, isTrue);
  });

  test('§14 buildNotifications', () {
    NotifyInputs base({
      NotifyBodyAlert? body_alert,
      double sleep_debt_min = 0,
      double? stress_score = 40,
      NotifyStreaks? streaks,
      List<String>? new_records,
    }) =>
        NotifyInputs(
          date: '2026-06-11',
          readiness: 72,
          coach_summary: 'Solid day.',
          coach_top: const NotifyCoachTop(
              'Anchor sleep timing', 'Aim for a steady bedtime.'),
          body_alert: body_alert,
          stress_score: stress_score,
          nocturnal_elevated: false,
          sleep_debt_min: sleep_debt_min,
          acwr: 1.0,
          strain_today: 8,
          strain_target_low: 6,
          strain_target_high: 10,
          streaks: streaks,
          new_records: new_records,
        );
    final n = buildNotifications(base());
    expect(n.any((x) => x.kind == 'morning_readiness'), isTrue);
    expect(n.every((x) => x.id == '2026-06-11:${x.kind}'), isTrue);
    final alert = buildNotifications(
        base(body_alert: const NotifyBodyAlert('overtraining', 'High load.')));
    expect(alert[0].kind == 'body_alert' && alert[0].priority == 3, isTrue);
    final heavy =
        buildNotifications(base(sleep_debt_min: 200, stress_score: 80));
    expect(heavy.any((x) => x.kind == 'sleep_debt'), isTrue);
    expect(heavy.any((x) => x.kind == 'high_stress'), isTrue);
    final milestone = buildNotifications(base(
        streaks: const NotifyStreaks(wear: 7),
        new_records: const ['Lowest resting HR']));
    expect(milestone.any((x) => x.kind == 'streak_wear'), isTrue);
    expect(milestone.any((x) => x.kind.startsWith('record_')), isTrue);
    expect(n.length <= 6, isTrue);
    expect(
        buildNotifications(base()).map((e) => e.toJson().toString()).join() ==
            buildNotifications(base()).map((e) => e.toJson().toString()).join(),
        isTrue);
  });

  test('regression: SRI circular (midnight wrap)', () {
    const day = 86400;
    final straddle = [
      NightSummary(onset_ts: (0 * day + 1430 * 60).toDouble(), wake_ts: (0 * day + 440 * 60).toDouble()),
      NightSummary(onset_ts: (1 * day + 5 * 60).toDouble(), wake_ts: (1 * day + 450 * 60).toDouble()),
      NightSummary(onset_ts: (2 * day + 1435 * 60).toDouble(), wake_ts: (2 * day + 435 * 60).toDouble()),
    ];
    final r = calcSleepRegularity(straddle);
    expect(r.sri > 80, isTrue);
    final scattered = [
      NightSummary(onset_ts: (0 * day + 1320 * 60).toDouble(), wake_ts: (0 * day + 360 * 60).toDouble()),
      NightSummary(onset_ts: (1 * day + 120 * 60).toDouble(), wake_ts: (1 * day + 600 * 60).toDouble()),
      NightSummary(onset_ts: (2 * day + 1200 * 60).toDouble(), wake_ts: (2 * day + 480 * 60).toDouble()),
    ];
    expect(calcSleepRegularity(scattered).sri < r.sri, isTrue);
  });

  test('regression: sleep stage proportions', () {
    final night = <Minute>[];
    for (var i = 0; i < 5; i++) night.add(mkMin((i * 60).toDouble(), 70, 2000));
    for (var i = 5; i < 365; i++) {
      final base = 44 + 7 * (1 + math.sin(i / 25));
      final wobble = (i % 3) - 1;
      night.add(mkMin((i * 60).toDouble(), (base + wobble).roundToDouble(), 40));
    }
    for (var i = 365; i < 370; i++) night.add(mkMin((i * 60).toDouble(), 72, 2000));
    final s = calcSleep(night, baseline);
    final st = s.stages!;
    final tot = st.light_min + st.deep_min + st.rem_min;
    expect(tot > 0, isTrue);
    expect(st.rem_min / tot < 0.40, isTrue);
    expect(st.deep_min / tot > 0.05, isTrue);
    expect(st.light_min >= st.rem_min, isTrue);
  });

  test('regression: RR-driven REM staging', () {
    const onset = 0.0, wake = 280 * 60.0;
    List<double> rrFor(double hr, double rmssdTarget) {
      final meanRr = (60000 / hr).roundToDouble();
      final d = math.min(95, (rmssdTarget / 2).round());
      final out = <double>[];
      for (var j = 0; j < 48; j++) {
        out.add(meanRr + (j % 2 == 0 ? d : -d));
      }
      return out;
    }

    final night = <StageMinute>[];
    void push(int a, int b, double hr, double rmssd) {
      for (var i = a; i < b; i++) {
        night.add(StageMinute((i * 60).toDouble(), hr, rrFor(hr, rmssd)));
      }
    }

    push(0, 30, 60, 50);
    push(30, 95, 56, 90);
    push(95, 150, 60, 50);
    push(150, 215, 64, 16);
    push(215, 280, 60, 50);
    final ss = stageSleep(night, onset, wake, 90);
    final tot = ss.light_min + ss.deep_min + ss.rem_min;
    expect(tot > 0, isTrue);
    final remPct = (100 * ss.rem_min) / tot, deepPct = (100 * ss.deep_min) / tot;
    expect(remPct >= 12 && remPct <= 35, isTrue);
    expect(deepPct >= 8, isTrue);
    expect(ss.light_min >= ss.rem_min, isTrue);
    int flaps = 0;
    for (var i = 0; i < ss.hypnogram.length;) {
      var j = i;
      while (j < ss.hypnogram.length &&
          ss.hypnogram[j]['stage'] == ss.hypnogram[i]['stage']) {
        j++;
      }
      if (ss.hypnogram[i]['stage'] == 'awake' && (j - i) < 20) flaps++;
      i = j;
    }
    expect(flaps == 0, isTrue);
    final noRr = night.map((m) => StageMinute(m.ts, m.hr_avg)).toList();
    final fb = stageSleep(noRr, onset, wake, 90);
    expect((fb.light_min + fb.deep_min + fb.rem_min) > 0, isTrue);
  });

  test('§detectSleepCycles', () {
    List<double> rrFor(double rmssd) {
      final d = math.max(2, (rmssd / 2).round());
      return List.generate(40, (j) => 900 + (j % 2 != 0 ? d : -d).toDouble());
    }

    final mins = <RrMinute>[];
    for (var i = 0; i < 320; i++) {
      final rmssd = 50 + 30 * math.sin((2 * math.pi * i) / 80);
      mins.add(RrMinute((i * 60).toDouble(), rrFor(rmssd)));
    }
    final c = detectSleepCycles(mins, 0, 319 * 60);
    expect(c.n >= 2 && c.n <= 6, isTrue);
    expect(
        c.mean_duration_min != null &&
            c.mean_duration_min! >= 55 &&
            c.mean_duration_min! <= 110,
        isTrue);
    expect(c.series.isNotEmpty, isTrue);
    final noRr = detectSleepCycles(
        List.generate(200, (i) => RrMinute((i * 60).toDouble())), 0, 199 * 60);
    expect(noRr.n == 0 && noRr.cycles.isEmpty, isTrue);
  });

  test('regression: resolveMaxHr source', () {
    final quiet = <Minute>[];
    for (var i = 0; i < 60; i++) {
      quiet.add(mkMin((i * 60).toDouble(), 95 + (i % 5).toDouble(), 100,
          const MinOpts(hr_max: 110)));
    }
    final r1 = resolveMaxHr(quiet, const Baseline(max_hr: 0), const Profile(age: 29));
    expect(r1.source == 'age' && r1.maxHr == 188, isTrue);
    final effort = <Minute>[];
    for (var i = 0; i < 60; i++) {
      effort.add(mkMin((i * 60).toDouble(), 150, 5000,
          MinOpts(hr_max: i == 30 ? 198 : 150)));
    }
    final r2 =
        resolveMaxHr(effort, const Baseline(max_hr: 0), const Profile(age: 29));
    expect(r2.source == 'measured' && r2.maxHr == 198, isTrue);
    final r3 = resolveMaxHr(quiet, const Baseline(max_hr: 185), const Profile(age: 29));
    expect(r3.source == 'measured' && r3.maxHr == 185, isTrue);
  });

  test('§Steps pedometer', () {
    final rest = List<double>.filled(3000, 1.0);
    expect(pedometer(rest) == 0, isTrue);
    final walk = <double>[];
    for (var i = 0; i < 3000; i++) {
      walk.add(1.0 + 0.3 * math.sin(2 * math.pi * 1.8 * (i / 100)));
    }
    final raw = pedometer(walk);
    expect(raw >= 45 && raw <= 60, isTrue);
    expect(calcSteps([rest]) == 0, isTrue);
    expect(calcSteps([walk]).toDouble(),
        closeTo((raw * (STEP_PARAMS['GAIN'] as double) + 0.5).floorToDouble(), 0.001));
    expect(STEP_PARAMS['GAIN'] == 1.11, isTrue);
  });

  test('§Circadian calcCircadian', () {
    final mins = <Minute>[];
    for (var i = 0; i < 2 * 1440; i++) {
      final ts = (i * 60).toDouble();
      final hod = (ts / 3600).floor() % 24;
      final asleep = hod >= 1 && hod < 8;
      final hr = (asleep ? 55 : 80) + (i % 5) - 2;
      mins.add(mkMin(ts, hr.toDouble()));
    }
    final c = calcCircadian(mins);
    expect(c.amplitude != null && c.amplitude! > 5, isTrue);
    expect(c.onset_ts != null && (c.onset_ts! - 90000).abs() <= 1800, isTrue);
    expect(c.wake_ts != null && (c.wake_ts! - 115200).abs() <= 1800, isTrue);
    expect(c.settled == true, isTrue);
    expect(c.confidence > 0.5, isTrue);

    final flat = <Minute>[];
    for (var i = 0; i < 2 * 1440; i++) flat.add(mkMin((i * 60).toDouble(), 70));
    final cf = calcCircadian(flat);
    expect(cf.onset_ts == null && cf.confidence < 0.3, isTrue);
  });

  test('detectWakeState (sleep/wake ensemble)', () {
    const bl = Baseline(resting_hr: 50, max_hr: 190, sleep_need_min: 480);
    List<Minute> build(int awakeMin) {
      final out = <Minute>[];
      double t = 0;
      for (var i = 0; i < 480; i++, t += 60) {
        out.add(mkMin(t, 50, 0.01, const MinOpts(wrist_on: true)));
      }
      for (var i = 0; i < awakeMin; i++, t += 60) {
        out.add(mkMin(t, 72, 0.4, const MinOpts(steps: 20, wrist_on: true)));
      }
      return out;
    }

    final woke = detectWakeState(WakeContext(minutes: build(15), baseline: bl));
    expect(woke.state == 'awake', isTrue);
    expect(woke.wake_ts != null && (woke.wake_ts! - 480 * 60).abs() <= 180, isTrue);
    expect(woke.awake_min >= 12 && woke.awake_min <= 19, isTrue);
    expect(woke.asleep_min >= 90, isTrue);

    final tooSoon = detectWakeState(WakeContext(minutes: build(5), baseline: bl));
    expect(tooSoon.wake_ts == null, isTrue);

    final stillAsleep =
        detectWakeState(WakeContext(minutes: build(0), baseline: bl));
    expect(stillAsleep.state == 'asleep' && stillAsleep.wake_ts == null, isTrue);

    final movingTail = [
      mkMin(0, 72, 0.4, const MinOpts(steps: 20, wrist_on: true)),
      mkMin(60, 73, 0.5, const MinOpts(steps: 25, wrist_on: true)),
      mkMin(120, 71, 0.3, const MinOpts(steps: 10, wrist_on: true)),
    ];
    expect(peekRecentState(movingTail, bl) == 'awake', isTrue);
  });

  test('regression: quiet sedentary wake fires', () {
    const bl = Baseline(resting_hr: 55, max_hr: 190, sleep_need_min: 480);
    final minutes = <Minute>[];
    final rrByMin = <double, List<double>>{};
    double t = 0;
    List<double> rr(double meanMs, double sd, [int n = 40]) =>
        List.generate(n, (j) => meanMs + (j % 2 != 0 ? sd : -sd));
    for (var i = 0; i < 480; i++, t += 60) {
      minutes.add(mkMin(t, 52, 0.01, const MinOpts(wrist_on: true)));
      rrByMin[t] = rr(1150, 12);
    }
    for (var i = 0; i < 30; i++, t += 60) {
      minutes.add(mkMin(t, 74, 0.01, const MinOpts(wrist_on: true)));
      rrByMin[t] = rr(810, 60);
    }

    final ws = detectWakeState(
        WakeContext(minutes: minutes, baseline: bl, rrByMin: rrByMin));
    expect(ws.state == 'awake', isTrue);
    expect(ws.wake_ts != null && (ws.wake_ts! - 480 * 60).abs() <= 180, isTrue);
    expect(ws.asleep_min >= 90, isTrue);
    expect(ws.votes['cardiac'] == 'awake' && ws.votes['hrvArousal'] == 'awake',
        isTrue);

    final noRr = detectWakeState(WakeContext(minutes: minutes, baseline: bl));
    expect(noRr.wake_ts == null, isTrue);
  });

  test('menstrual cycle', () {
    final none = calcCycle([], '2026-06-20');
    expect(
        none.confidence == 0 &&
            none.phase == 'unknown' &&
            none.predicted_next == null,
        isTrue);

    final starts = ['2026-04-04', '2026-05-02', '2026-05-30'];
    final c = calcCycle(starts, '2026-06-06');
    expect(c.mean_length == 28, isTrue);
    expect(c.length_history.length == 2, isTrue);
    expect(c.cycle_day == 8, isTrue);
    expect(c.predicted_next == '2026-06-27', isTrue);
    expect(c.ovulation_est == '2026-06-13', isTrue);
    expect(c.fertile_start == '2026-06-08' && c.fertile_end == '2026-06-14',
        isTrue);
    expect(c.phase == 'follicular', isTrue);
    expect(c.confidence > 0.5, isTrue);

    final m = calcCycle(starts, '2026-05-31');
    expect(m.phase == 'menstruation', isTrue);

    final l = calcCycle(starts, '2026-06-20');
    expect(l.phase == 'luteal', isTrue);

    final od = calcCycle(starts, '2026-07-25');
    expect(od.phase == 'unknown' && od.confidence <= 0.2, isTrue);

    final one = calcCycle(['2026-06-10'], '2026-06-15');
    expect(
        one.mean_length == null &&
            one.predicted_next == '2026-07-08' &&
            one.confidence > 0,
        isTrue);
  });

  test('§HAR activity recognition', () {
    final sumLo = DB10_LO.fold<double>(0, (s, v) => s + v);
    final sumSq = DB10_LO.fold<double>(0, (s, v) => s + v * v);
    expect(DB10_LO.length == 20, isTrue);
    expect(sumLo, closeTo(math.sqrt2, 1e-6));
    expect(sumSq, closeTo(1, 1e-6));

    const fs = 100.0;
    const secs = 4;
    final n = (fs * secs).toInt();
    ({List<double> x, List<double> y, List<double> z}) mk(double f0, double amp,
        [double noise = 0.004]) {
      final x = <double>[], y = <double>[], z = <double>[];
      for (var i = 0; i < n; i++) {
        final t = i / fs;
        z.add(1 +
            amp * math.sin(2 * math.pi * f0 * t) +
            (((i * 7919) % 991) / 991 - 0.5) * noise);
        x.add((((i * 1103515245 + 12345) % 1000) / 1000 - 0.5) * noise);
        y.add((((i * 1103) % 997) / 997 - 0.5) * noise);
      }
      return (x: x, y: y, z: z);
    }

    final w2 = mk(2.0, 0.5);
    final f2 = extractHarFeatures(w2.x, w2.y, w2.z, fs);
    expect(f2.dom1_freq, closeTo(2.0, 0.3));
    expect(f2.dom1_ratio > 0.25, isTrue);

    final flat = mk(1.0, 0.0);
    expect(
        classifyActivityWindow(extractHarFeatures(flat.x, flat.y, flat.z, fs))
                .cls ==
            'sedentary',
        isTrue);

    final cw = classifyActivityWindow(f2);
    expect(cw.cls == 'walk', isTrue);

    final w3 = mk(2.8, 0.6);
    expect(
        classifyActivityWindow(extractHarFeatures(w3.x, w3.y, w3.z, fs)).cls ==
            'run',
        isTrue);

    final we = dwtDetailEnergies(w2.x, 6);
    expect(we.length == 6 && we.every((e) => e >= 0), isTrue);

    final votes = <ClassVote>[];
    for (var t = 0; t < 300; t += 4) {
      votes.add(ClassVote((1000 + t).toDouble(), 'walk', 0.7));
    }
    for (var t = 300; t < 600; t += 4) {
      votes.add(ClassVote((1000 + t).toDouble(), 'run', 0.7));
    }
    final seg = segmentWorkout(votes);
    expect(seg.segments.length == 2, isTrue);
    expect(seg.segments[0].type == 'walk' && seg.segments[1].type == 'run',
        isTrue);

    final blip = <ClassVote>[];
    for (var t = 0; t < 600; t += 4) {
      blip.add(ClassVote((2000 + t).toDouble(), t == 300 ? 'cycle' : 'run', 0.7));
    }
    expect(segmentWorkout(blip).segments.length == 1, isTrue);
  });

  test('§restlessness / daytime HRV / desaturation', () {
    final sleepMin = <Minute>[];
    for (var i = 0; i < 240; i++) {
      final moving = i % 30 == 0;
      sleepMin.add(Minute(
        ts: (1000 + i * 60).toDouble(),
        hr_avg: 55,
        hr_min: 54,
        hr_max: 56,
        hr_n: 60,
        activity: moving ? 0.5 : 0.01,
        steps: 0,
        wrist_on: true,
      ));
    }
    final rest = calcRestlessness(sleepMin);
    expect(rest.score != null && rest.movement_bouts >= 5, isTrue);
    expect(rest.longest_still_min > 0 && rest.mobility_pct != null, isTrue);
    expect(calcRestlessness(sleepMin.sublist(0, 5)).score == null, isTrue);

    final byMin = <RrByMinute>[];
    for (var i = 0; i < 60; i++) {
      final rr = <double>[];
      for (var k = 0; k < 12; k++) {
        rr.add(850 + ((i + k) % 5) * 15.0);
      }
      byMin.add(RrByMinute((1000 + i * 60).toDouble(), rr));
    }
    final dh = calcDaytimeHrv(byMin, 300);
    expect(dh.rmssd_median != null && dh.n_windows >= 10, isTrue);
    expect(dh.series.length == dh.n_windows && dh.lowest_ts != null, isTrue);
    expect(calcDaytimeHrv([], 300).rmssd_median == null, isTrue);

    final ratios = <double>[];
    for (var i = 0; i < 120; i++) {
      ratios.add(i % 20 < 2 ? 0.86 : 0.79);
    }
    final des = calcDesaturation(ratios, 0.80);
    expect(des.events >= 4 && des.odi != null, isTrue);
    expect(des.deepest_pct != null && des.deepest_pct! > 0, isTrue);
    final desNoBase = calcDesaturation(ratios, null);
    expect(desNoBase.events == 0 && desNoBase.confidence == 0, isTrue);
  });
}
