// Unit tests — one block per analytics function, asserting numeric expectations
// against fixed in-code fixtures. Run with: npx tsx src/__tests__/analytics.test.ts
import { assert, approx, summary, min } from './_harness';
import type { Baseline, Minute, Profile } from '../types';

import { calcRestingHR } from '../resting';
import { calcStrain } from '../strain';
import { calcHrZones } from '../zones';
import { calcCalories } from '../calories';
import { calcSleep } from '../sleep';
import { calcSleepRegularity } from '../regularity';
import { detectSessions } from '../sessions';
import { calcHrRecovery, calcRecovery } from '../recovery';
import { calcLoad, calcFitnessTrend } from '../trends';
import { calcAnomaly } from '../readiness';
import { calcBaselines } from '../baselines';
import { calcStress } from '../stress';
import { calcSleepStress } from '../arousal';
import { calcNocturnalHeart } from '../nocturnal';
import { calcIllness } from '../illness';
import { timeDomainHrv, freqDomainHrv, baevskyStressIndex, cleanRr } from '../hrv';
import { resolveMaxHr } from '../util';

const baseline: Baseline = {
  resting_hr: 50,
  max_hr: 190,
  sleep_need_min: 480,
  skin_temp: 34.0,
  chronic_strain: 10,
};

// ── §1 calcRestingHR ─────────────────────────────────────────────────────────
console.log('--- §1 calcRestingHR ---');
{
  // sleep window 0..5min, HRs [40,42,44,46,48,50] → 5th pctile = 40.5
  const mins: Minute[] = [40, 42, 44, 46, 48, 50].map((h, i) => min(i * 60, h));
  const r = calcRestingHR(mins, { onset_ts: 0, wake_ts: 5 * 60 });
  approx(r.resting_hr ?? -1, 40.5, 0.01, 'RHR = 5th pctile of sleep-window HR');
  assert(r.tier === 'HIGH', 'RHR tier HIGH');
  approx(r.confidence, 6 / 240, 0.001, 'RHR confidence = worn_min/240');

  // no window → fallback path, confidence ≤ 0.5
  const r2 = calcRestingHR(mins, undefined);
  assert(r2.resting_hr !== null, 'fallback produces an RHR');
  assert(r2.confidence <= 0.5, 'fallback confidence capped at 0.5');

  // off-wrist excluded
  const off = calcRestingHR([], { onset_ts: 0, wake_ts: 60 });
  assert(off.resting_hr === null && off.confidence === 0, 'no data → null + conf 0');
}

// ── §2 calcStrain ──────────────────────────────────────────────────────────────
console.log('--- §2 calcStrain ---');
{
  // flat rest at RHR → 0 strain
  const rest: Minute[] = Array.from({ length: 30 }, (_, i) => min(i * 60, 50));
  const rs = calcStrain(rest, baseline);
  approx(rs.trimp, 0, 1e-9, 'rest at RHR → 0 TRIMP');
  approx(rs.score, 0, 1e-9, 'rest at RHR → 0 strain');

  // 30 min @150bpm → known trimp 54.0477, score 9.89
  const hard: Minute[] = Array.from({ length: 30 }, (_, i) => min(i * 60, 150));
  const hs = calcStrain(hard, baseline);
  approx(hs.trimp, 54.0477, 0.01, '30min@150 → TRIMP ≈ 54.05');
  approx(hs.score, 9.89, 0.01, '30min@150 → score ≈ 9.89');
  approx(hs.confidence, 1, 1e-9, '≥30 worn min → confidence 1');
  assert(hs.max_hr_source === 'measured', 'baseline max → measured source');

  // off-wrist gaps do not contribute
  const gapped: Minute[] = [
    ...Array.from({ length: 15 }, (_, i) => min(i * 60, 150)),
    ...Array.from({ length: 10 }, (_, i) => min((i + 15) * 60, 0, 0, { wrist_on: false })),
    ...Array.from({ length: 15 }, (_, i) => min((i + 25) * 60, 150)),
  ];
  const cont: Minute[] = Array.from({ length: 30 }, (_, i) => min(i * 60, 150));
  approx(calcStrain(gapped, baseline).trimp, calcStrain(cont, baseline).trimp, 1e-9,
    'off-wrist minutes excluded from strain');

  // score bounded ≤ 21
  const insane: Minute[] = Array.from({ length: 1000 }, (_, i) => min(i * 60, 190));
  assert(calcStrain(insane, baseline).score <= 21, 'strain bounded at 21');
}

// ── §3 calcHrZones ───────────────────────────────────────────────────────────
console.log('--- §3 calcHrZones ---');
{
  // maxHR 190: 100bpm=52.6%→z1, 120=63%→z2, 150=78.9%→z3, 160=84%→z4, 175=92%→z5
  const mins: Minute[] = [100, 120, 150, 160, 175].map((h, i) => min(i * 60, h));
  const z = calcHrZones(mins, baseline);
  assert(z.zone1_min === 1, '100bpm → z1');
  assert(z.zone2_min === 1, '120bpm → z2');
  assert(z.zone3_min === 1, '150bpm → z3');
  assert(z.zone4_min === 1, '160bpm → z4');
  assert(z.zone5_min === 1, '175bpm → z5');
  assert(z.max_hr_source === 'measured', 'measured maxHR');

  // age-defaulted → lower base confidence (0.6 vs 0.85)
  const profileLess: Profile = {};
  const noMaxBaseline: Baseline = { ...baseline, max_hr: 0 };
  const z2 = calcHrZones(mins, noMaxBaseline, { age: 40 });
  // no measured max on minutes>0? minutes DO carry hr_max so source = measured.
  // Force age path: all hr=0 minutes can't bucket; use explicit age fallback test below.
  const ageOnly = calcHrZones(
    [min(0, 0, 0, { wrist_on: false })],
    noMaxBaseline,
    { age: 40 }
  );
  assert(ageOnly.max_hr_source === 'age' && ageOnly.max_hr_used === 180,
    'age fallback maxHR = 220−age when no measured HR');
}

// ── §4 calcCalories ──────────────────────────────────────────────────────────
console.log('--- §4 calcCalories ---');
{
  // ACTIVE calories = burn ABOVE resting. One min @120 with RHR 60, sex-avg:
  // delta/min = avg((0.6309+0.4472)/2)*(120−60)/4.184 = 0.53905*60/4.184 ≈ 7.73 kcal.
  const one: Minute[] = [min(0, 120)];
  const c = calcCalories(one, { age: 30, weight_kg: 70 }, 60);
  approx(c.kcal, 7.73, 0.2, 'one min @120 over RHR60 sex-avg ≈ 7.7 active kcal');
  assert(c.tier === 'ESTIMATE' && c.label.includes('est.'), 'calories ESTIMATE + est. label');
  // a minute AT resting HR contributes ≈0 active calories (the key fix).
  const atRest = calcCalories([min(0, 60)], { age: 30, weight_kg: 70 }, 60);
  assert(atRest.kcal < 0.01, 'minutes at resting HR → ~0 active calories (no BMR over-count)');
  // below resting clamped at 0.
  const low = calcCalories([min(0, 40)], { age: 30, weight_kg: 70 }, 60);
  assert(low.kcal >= 0, 'below-resting calories never negative');
  // sex specified changes the active value (HR coefficient differs).
  const cm = calcCalories(one, { age: 30, weight_kg: 70, sex: 'm' }, 60);
  assert(cm.kcal !== c.kcal, 'male coeff differs from sex-avg');
  // a full day spent AT resting HR must contribute ≈0 active kcal — the bug fix
  // (pre-fix this summed Keytel's BMR constant → ~5884 "active" kcal on a full day).
  const fullRestDay: Minute[] = Array.from({ length: 1440 }, (_, i) => min(i * 60, 58));
  const fr = calcCalories(fullRestDay, { age: 29, weight_kg: 75, sex: 'm' }, 58);
  assert(fr.kcal < 20, `full resting-HR day → ~0 active kcal (got ${fr.kcal}, was ~5884 pre-fix)`);
}

// ── §5 calcSleep ─────────────────────────────────────────────────────────────
console.log('--- §5 calcSleep ---');
{
  // 200 min of low activity + dipped HR → asleep; bracketed by awake activity.
  const mins: Minute[] = [];
  for (let i = 0; i < 5; i++) mins.push(min(i * 60, 70, 2000)); // awake before
  for (let i = 5; i < 205; i++) mins.push(min(i * 60, 45, 50)); // asleep (HR dip + low act)
  for (let i = 205; i < 210; i++) mins.push(min(i * 60, 72, 2000)); // awake after
  const s = calcSleep(mins, baseline);
  assert(s.duration_min >= 195, `main sleep ≈ 200 min (got ${s.duration_min})`);
  // Clean block with no interior awakenings → efficiency ≈ 1.0 (no interior awake
  // epochs between first- and last-asleep).
  assert(s.efficiency > 0.99, 'efficiency ≈ 1.0 for a clean (un-fragmented) block');
  assert(s.onset_ts === 5 * 60, 'onset at first asleep minute');
  assert(s.stages !== null && s.stages_beta === true, 'stages present + flagged beta');
  assert(s.tier === 'HIGH', 'sleep tier HIGH');
  assert(s.inputs_used.includes('baseline.skin_temp'), 'temp counted as input when baseline has it');

  // Interior awakenings: in-bed span is first-asleep → last-asleep, and the
  // awake minutes in the middle count AGAINST efficiency (no longer 1.0).
  const frag: Minute[] = [];
  for (let i = 0; i < 5; i++) frag.push(min(i * 60, 70, 2000));        // awake before
  for (let i = 5; i < 100; i++) frag.push(min(i * 60, 45, 50));        // asleep
  for (let i = 100; i < 110; i++) frag.push(min(i * 60, 72, 1800));    // interior awakening (10 min)
  for (let i = 110; i < 205; i++) frag.push(min(i * 60, 45, 50));      // asleep again
  for (let i = 205; i < 210; i++) frag.push(min(i * 60, 72, 2000));    // awake after
  const f = calcSleep(frag, baseline);
  assert(f.onset_ts === 5 * 60, 'fragmented: onset at first asleep minute');
  assert(f.wake_ts === 204 * 60, 'fragmented: wake at last asleep minute (span spans the awakening)');
  assert(f.in_bed_min === 200, `fragmented: in-bed span = first→last asleep inclusive (got ${f.in_bed_min})`);
  assert(f.duration_min === 190, `fragmented: asleep minutes exclude the 10-min awakening (got ${f.duration_min})`);
  assert(f.efficiency > 0.9 && f.efficiency < 1, `fragmented: efficiency 0.9–1.0 (got ${f.efficiency})`);

  // empty input
  const e = calcSleep([], baseline);
  assert(e.duration_min === 0 && e.confidence === 0, 'no data → 0 sleep + conf 0');

  // Regression: a LONG awake gap (> MAX_GAP_MIN) must NOT bridge two low-activity
  // blocks into one giant "night". Here a 250-min night is followed by a 60-min
  // awake daytime stretch (elevated HR), then a 90-min low-activity-but-awake
  // afternoon block. The consolidated main sleep = only the 250-min night; the
  // afternoon must not be absorbed (this is the in-bed-span regression that made
  // some nights read 17h).
  const split: Minute[] = [];
  for (let i = 0; i < 5; i++) split.push(min(i * 60, 70, 2000));       // awake before
  for (let i = 5; i < 255; i++) split.push(min(i * 60, 45, 50));       // 250-min night (asleep)
  for (let i = 255; i < 315; i++) split.push(min(i * 60, 75, 2500));   // 60-min awake daytime (long gap)
  // afternoon: low activity but HR clearly elevated (> 1.15*RHR) → awake, not sleep
  for (let i = 315; i < 405; i++) split.push(min(i * 60, 72, 60));     // 90-min sedentary-but-awake
  const sp = calcSleep(split, baseline);
  assert(sp.duration_min >= 245 && sp.duration_min <= 255,
    `long-gap: main sleep = the 250-min night only (got ${sp.duration_min})`);
  assert(sp.in_bed_min <= 260,
    `long-gap: in-bed span not stretched across the day (got ${sp.in_bed_min})`);
  assert((sp.wake_ts ?? 0) <= 255 * 60,
    `long-gap: wake at end of night, not afternoon (wake_ts ${sp.wake_ts})`);

  // Regression: off-wrist epochs (wrist_on=false, no HR) carry NO sleep signal
  // and must read awake — a long off-wrist daytime stretch must break the night,
  // not bridge across it. Night, then 40 min off-wrist (band on charger), then a
  // short low-activity worn block; main sleep stays the night only.
  const offwrist: Minute[] = [];
  for (let i = 0; i < 5; i++) offwrist.push(min(i * 60, 70, 2000));    // awake before
  for (let i = 5; i < 205; i++) offwrist.push(min(i * 60, 45, 50));    // 200-min night (asleep)
  for (let i = 205; i < 245; i++) offwrist.push(min(i * 60, 0, 0, { wrist_on: false })); // 40-min off-wrist
  for (let i = 245; i < 285; i++) offwrist.push(min(i * 60, 70, 60));  // worn-but-awake daytime
  const ow = calcSleep(offwrist, baseline);
  assert(ow.duration_min >= 195 && ow.duration_min <= 205,
    `off-wrist: main sleep = the 200-min night only (got ${ow.duration_min})`);
  assert(ow.in_bed_min <= 210,
    `off-wrist: off-wrist stretch not counted as in-bed (got ${ow.in_bed_min})`);

  // Plausibility guard: even if (pathologically) almost the whole 18h window
  // reads low-activity, a single main-sleep period must never exceed ~14h.
  const giant: Minute[] = [];
  for (let i = 0; i < 1080; i++) giant.push(min(i * 60, 45, 50)); // 18h of "asleep-looking" epochs
  const g = calcSleep(giant, baseline);
  assert(g.in_bed_min <= 14 * 60,
    `plausibility: main-sleep period capped at ~14h (got ${g.in_bed_min})`);
}

// ── §6 calcSleepRegularity ───────────────────────────────────────────────────
console.log('--- §6 calcSleepRegularity ---');
{
  const DAY = 86400;
  // identical schedule 3 nights → SRI 100
  const same = [0, 1, 2].map((d) => ({
    onset_ts: d * DAY + 23 * 3600, // 23:00
    wake_ts: d * DAY + 7 * 3600, // 07:00 (next-day modulo)
  }));
  const r = calcSleepRegularity(same);
  approx(r.sri, 100, 0.01, 'identical schedule → SRI 100');
  assert(r.confidence === 0.7, 'SRI confidence 0.7 with ≥3 nights');

  // <3 nights → confidence 0
  assert(calcSleepRegularity(same.slice(0, 2)).confidence === 0, '<3 nights → conf 0');

  // jittered onset → SRI < 100
  const jit = [0, 1, 2].map((d, i) => ({
    onset_ts: d * DAY + 23 * 3600 + i * 1800,
    wake_ts: d * DAY + 7 * 3600,
  }));
  assert(calcSleepRegularity(jit).sri < 100, 'jittered onset → SRI < 100');
}

// ── §7 detectSessions ────────────────────────────────────────────────────────
console.log('--- §7 detectSessions ---');
{
  // threshold = 50 + 0.4*140 = 106 bpm. Build a 10-min high-HR + high-activity bout
  // surrounded by rest.
  const mins: Minute[] = [];
  for (let i = 0; i < 10; i++) mins.push(min(i * 60, 55, 1)); // rest, low act
  for (let i = 10; i < 20; i++) mins.push(min(i * 60, 150, 100, { hr_max: 165 })); // workout
  for (let i = 20; i < 30; i++) mins.push(min(i * 60, 55, 1)); // rest
  const sessions = detectSessions(mins, baseline);
  assert(sessions.length === 1, `exactly one session detected (got ${sessions.length})`);
  const ses = sessions[0];
  assert(ses.start_ts === 10 * 60, 'session starts at minute 10');
  assert(ses.duration_min >= 9, 'session ~10 min');
  assert(ses.confidence === 0.8 && ses.type_confidence === 0.4, 'event 0.8 / type 0.4');
  assert(ses.type === 'run/cardio', 'high act + high HR → run/cardio');
  assert(ses.strain > 0 && ses.kcal > 0, 'session carries strain + calories');

  // a <5min bout is discarded
  const tiny: Minute[] = [];
  for (let i = 0; i < 10; i++) tiny.push(min(i * 60, 55, 1));
  for (let i = 10; i < 13; i++) tiny.push(min(i * 60, 150, 100)); // only 3 min
  for (let i = 13; i < 20; i++) tiny.push(min(i * 60, 55, 1));
  assert(detectSessions(tiny, baseline).length === 0, 'bout <5 min discarded');
}

// ── §8 calcHrRecovery ────────────────────────────────────────────────────────
console.log('--- §8 calcHrRecovery ---');
{
  // peak hr_max 170 at minute 5, then drop to 130 one minute later → HRR60 = 40
  const mins: Minute[] = [];
  for (let i = 0; i < 5; i++) mins.push(min(i * 60, 150, 50, { hr_max: 155 }));
  mins.push(min(5 * 60, 165, 50, { hr_max: 170 })); // peak
  mins.push(min(6 * 60, 130, 10, { hr_max: 135 })); // +60s
  const hrr = calcHrRecovery(mins, baseline);
  approx(hrr.hrr60 ?? -1, 40, 0.01, 'HRR60 = peak 170 − 130 = 40');
  approx(hrr.peak_hr ?? -1, 170, 0.01, 'peak_hr = 170');
  assert(hrr.confidence === 0.7, 'HRR confidence 0.7 with elevated peak');

  // no elevated peak → null
  const flat: Minute[] = Array.from({ length: 10 }, (_, i) => min(i * 60, 55, 1));
  const nf = calcHrRecovery(flat, baseline);
  assert(nf.hrr60 === null && nf.confidence === 0, 'no elevated peak → null HRR');
}

// ── §9 calcLoad + calcFitnessTrend ───────────────────────────────────────────
console.log('--- §9 calcLoad / calcFitnessTrend ---');
{
  // 28 days, all strain 10 → acwr 1.0 optimal
  const steady = Array.from({ length: 28 }, (_, i) => ({ ts: i * 86400, strain: 10 }));
  const load = calcLoad(steady);
  approx(load.acwr ?? -1, 1.0, 1e-9, 'steady strain → ACWR 1.0');
  assert(load.band === 'optimal', 'ACWR 1.0 → optimal band');

  // acute spike: last 7 days at 20, prior 21 at 10 → acute 20, chronic ~12.5 → acwr 1.6
  const spike = Array.from({ length: 28 }, (_, i) => ({
    ts: i * 86400,
    strain: i >= 21 ? 20 : 10,
  }));
  const sl = calcLoad(spike);
  assert(sl.band === 'high-risk', `acute spike → high-risk (acwr ${sl.acwr})`);

  // <7 days → unknown
  assert(calcLoad(steady.slice(0, 5)).band === 'unknown', '<7 days → unknown band');

  // fitness improving: RHR declining, HRR rising over 28 days
  const daily = Array.from({ length: 28 }, (_, i) => ({
    resting_hr: 60 - i * 0.2, // declining
    hrr60: 30 + i * 0.3, // rising
  }));
  const ft = calcFitnessTrend(daily);
  assert(ft.direction === 'improving', `RHR↓ + HRR↑ → improving (got ${ft.direction})`);
  assert(ft.rhr_slope < 0 && ft.hrr_slope > 0, 'slopes have expected signs');
  // never emits a VO2max number — only direction + slopes (type guarantees this)
  assert(!('vo2max' in (ft as unknown as Record<string, unknown>)), 'no VO2max field emitted');
}

// ── §10 calcRecovery (HRV) + calcAnomaly + calcIllness ───────────────────────
console.log('--- §10 calcRecovery / calcAnomaly / calcIllness ---');
{
  // Plews lnRMSSD z-score. Baseline ~75ms; tonight at baseline → ~50.
  const base = [72, 75, 78, 74, 76, 73, 77, 75, 74, 76];
  const atBase = calcRecovery(75, base, { date: '2026-06-13' });
  approx(atBase.score!, 50, 8, 'RMSSD at baseline → recovery ≈ 50');
  assert(atBase.tier === 'HIGH' && atBase.note === 'HRV-based', 'recovery HIGH, HRV-based');
  assert(atBase.drivers!.length >= 1 && atBase.drivers![0].ref!.metric === 'hrv', 'recovery driver links to hrv');
  const high = calcRecovery(100, base);
  const low = calcRecovery(50, base);
  assert(high.score! > atBase.score! && low.score! < atBase.score!, 'higher RMSSD → higher recovery');
  // insufficient baseline → null (honest, no heuristic fallback)
  assert(calcRecovery(75, [70, 72]).score === null && calcRecovery(75, [70, 72]).confidence === 0,
    '<5 baseline nights → recovery null');
  assert(calcRecovery(null, base).score === null, 'no RMSSD tonight → null');

  // anomaly: RHR ≥ baseline+7% for ≥2 consecutive days
  const an = calcAnomaly({ recent_rhr: [50, 51, 55, 56] }, baseline);
  assert(an.signal === true && an.triggers.includes('rhr_elevated_2d'), 'two elevated RHR days → signal');
  assert(an.note === 'signal, not a diagnosis', 'anomaly non-diagnostic note');

  // illness (Mahalanobis): RHR↑ + RMSSD↓ + temp↑ vs baseline → signal.
  const hist = {
    resting_hr: Array.from({ length: 20 }, (_, i) => 55 + (i % 3)),
    rmssd: Array.from({ length: 20 }, (_, i) => 74 + (i % 5)),
    skin_temp: Array.from({ length: 20 }, (_, i) => 34 + (i % 2) * 0.1),
  };
  const sick = calcIllness({ resting_hr: 68, rmssd: 45, skin_temp: 35.2 }, hist);
  assert(sick.signal === true && sick.triggers.length >= 2, 'illness fires on multivariate deviation');
  assert(sick.note === 'a signal, not a diagnosis', 'illness non-diagnostic note');
  const well = calcIllness({ resting_hr: 56, rmssd: 76, skin_temp: 34.05 }, hist);
  assert(well.signal === false, 'normal vector → no illness signal');
}

// ── §11 calcBaselines ────────────────────────────────────────────────────────
console.log('--- §11 calcBaselines ---');
{
  const hist = Array.from({ length: 30 }, (_, i) => ({
    resting_hr: 50 + (i % 3), // 50,51,52,...
    sleep_duration_min: 470 + (i % 5),
    skin_temp: 34 + (i % 2) * 0.1,
    daily_strain: 10 + (i % 4),
    session_hr_max: 180 + (i % 10),
    zone_min: [10, 20, 15, 5, 2] as [number, number, number, number, number],
  }));
  const bl = calcBaselines(hist);
  assert(bl.resting_hr !== null && bl.resting_hr! >= 50 && bl.resting_hr! <= 52, 'RHR median in range');
  assert(bl.max_hr === 189 && bl.max_hr_source === 'measured', 'maxHR = max observed session');
  assert(bl.chronic_strain !== null, 'chronic strain computed');
  assert(bl.zone_min !== null && bl.zone_min![0] === 10, 'per-zone medians present');
  approx(bl.confidence, 1, 1e-9, '30 days → confidence 1');

  // age fallback for maxHR when no sessions
  const noSess = hist.map((d) => ({ ...d, session_hr_max: undefined }));
  const bl2 = calcBaselines(noSess, { age: 30 });
  assert(bl2.max_hr === 190 && bl2.max_hr_source === 'age', 'no sessions + age → 220−age maxHR');

  // seed period (3 days) → low confidence
  const seed = calcBaselines(hist.slice(0, 3));
  approx(seed.confidence, 3 / 30, 1e-9, 'seed period → wide (low) confidence');
}

// (activity rollup metric — steps + active/sedentary — REMOVED in v0.)

// ── determinism ──────────────────────────────────────────────────────────────
console.log('--- determinism ---');
{
  const mins: Minute[] = Array.from({ length: 30 }, (_, i) => min(i * 60, 150, 10));
  const a = JSON.stringify(calcStrain(mins, baseline));
  const b = JSON.stringify(calcStrain(mins, baseline));
  assert(a === b, 'same input → identical output');
}

// ── coaching engine ───────────────────────────────────────────────────────────
console.log('--- buildCoach ---');
{
  const { buildCoach } = require('../coach');
  // Low recovery + high load → "ease off", strain target capped low.
  const lo = buildCoach({
    readiness: 35, readiness_components: { rhr: 0.5, sleep_debt: 0.4, sleep_quality: 0.6 },
    resting_hr: 70, baseline_rhr: 60, rhr_recent: [60, 61, 70],
    strain_today: 5, acwr: 1.5, sleep_last_min: 300, sleep_need_min: 480,
    sleep_debt_min: 200, sleep_efficiency: 0.7, sri: 60, fitness_direction: 'flat', anomaly: null,
  });
  assert(lo.strain_target!.value <= 10, 'high ACWR caps strain target ≤10');
  assert(lo.plan.some((s: any) => s.category === 'load' || s.category === 'recovery'), 'low recovery/high load → a load/recovery suggestion');
  assert(lo.plan.some((s: any) => s.id === 'sleep.debt'), 'big sleep debt → debt suggestion');
  assert(lo.readiness_contributors.length === 3, 'three readiness contributors');
  assert(lo.summary.length > 0, 'has narrative');
  // Fresh + light load → "room to push", higher target.
  const hi = buildCoach({
    readiness: 85, readiness_components: { rhr: 1, sleep_debt: 1, sleep_quality: 0.9 },
    resting_hr: 55, baseline_rhr: 58, rhr_recent: [58, 57, 55],
    strain_today: 2, acwr: 0.6, sleep_last_min: 480, sleep_need_min: 480,
    sleep_debt_min: 0, sleep_efficiency: 0.92, sri: 90, fitness_direction: 'rising', anomaly: null,
  });
  assert(hi.strain_target!.value >= 14, 'high recovery → high strain target');
  assert(hi.plan.some((s: any) => s.id === 'load.low' || s.id === 'recovery.high'), 'fresh → push suggestion');
  // Determinism.
  assert(JSON.stringify(buildCoach({
    readiness: 50, resting_hr: 60, baseline_rhr: 60, rhr_recent: [60],
    strain_today: 8, acwr: 1.0, sleep_last_min: 400, sleep_need_min: 480,
    sleep_debt_min: 0, sleep_efficiency: 0.85, sri: 80, fitness_direction: 'flat', anomaly: null,
  })) === JSON.stringify(buildCoach({
    readiness: 50, resting_hr: 60, baseline_rhr: 60, rhr_recent: [60],
    strain_today: 8, acwr: 1.0, sleep_last_min: 400, sleep_need_min: 480,
    sleep_debt_min: 0, sleep_efficiency: 0.85, sri: 80, fitness_direction: 'flat', anomaly: null,
  })), 'coach is deterministic');
}

// ── §HRV math (RMSSD/SDNN/pNN50, Lomb–Scargle, Baevsky) ───────────────────────
console.log('--- §HRV time/freq/SI ---');
{
  // Exact RMSSD: alternating 800/820 → successive diff 20 → RMSSD = 20.
  const alt = Array.from({ length: 60 }, (_, i) => (i % 2 ? 820 : 800));
  const td = timeDomainHrv(alt);
  approx(td.rmssd!, 20, 0.01, 'alternating 800/820 → RMSSD = 20');
  approx(td.mean_rr!, 810, 0.1, 'mean RR = 810');
  approx(td.mean_hr!, 60000 / 810, 0.1, 'mean HR from RR');
  // cleanRr drops out-of-physiological + ectopic jumps.
  assert(cleanRr([900, 250, 905, 2500, 910]).length === 3, 'cleanRr drops non-physiological');
  // Respiratory peak: RR modulated at 0.25 Hz (15 brpm) → resp_rate ≈ 15.
  const t: number[] = []; let acc = 0;
  const resp: number[] = [];
  for (let i = 0; i < 200; i++) {
    const rr = 900 + 60 * Math.sin(2 * Math.PI * 0.25 * (acc / 1000));
    resp.push(Math.round(rr)); acc += rr;
  }
  const fd = freqDomainHrv(resp);
  assert(fd.resp_rate !== null && Math.abs(fd.resp_rate - 15) < 3, `RSA resp rate ≈ 15 brpm (got ${fd.resp_rate})`);
  assert(fd.hf! > 0 && fd.lf_hf !== null, 'LF/HF computed');
  // Baevsky SI: tighter RR distribution → higher SI than a spread one.
  const tight = Array.from({ length: 100 }, (_, i) => 900 + (i % 3)); // narrow
  const spread = Array.from({ length: 100 }, (_, i) => 700 + (i * 4) % 400); // wide
  const siT = baevskyStressIndex(tight).si!, siS = baevskyStressIndex(spread).si!;
  assert(siT > siS, `tighter RR ⇒ higher Baevsky SI (${siT} > ${siS})`);
}

// ── §12 calcStress (HRV-based, personal-relative) ─────────────────────────────
console.log('--- §12 calcStress (HRV) ---');
{
  const rr = Array.from({ length: 120 }, (_, i) => 850 + (i % 5) * 8);
  const si = baevskyStressIndex(rr).si!;
  // No baseline → indices only, no fabricated score.
  const noBase = calcStress(rr, []);
  assert(noBase.score === null && noBase.si !== null, 'no baseline → SI reported, score null');
  assert(noBase.tier === 'ESTIMATE', 'stress ESTIMATE');
  // With a baseline SI distribution → personal-relative score + level.
  const baseSI = [si * 0.8, si * 0.9, si, si * 1.1, si * 1.2, si * 0.95, si * 1.05];
  const withBase = calcStress(rr, baseSI);
  assert(withBase.score !== null && withBase.level !== null, 'baseline present → score + level');
  assert(withBase.drivers!.some((d) => d.label.includes('Baevsky')), 'stress driver = Baevsky SI');
  // Higher SI than baseline → higher stress score.
  const tightRr = Array.from({ length: 120 }, (_, i) => 850 + (i % 2)); // very tight → high SI
  const hi = calcStress(tightRr, baseSI);
  assert((hi.score ?? 0) >= (withBase.score ?? 0), 'higher SI vs baseline → higher stress');
  // determinism
  assert(JSON.stringify(calcStress(rr, baseSI)) === JSON.stringify(calcStress(rr, baseSI)), 'stress deterministic');
}

// ── §sleep-stress / nocturnal arousal ─────────────────────────────────────────
console.log('--- §calcSleepStress ---');
{
  // Calm night: flat low HR, no motion → no arousals, low score.
  const calm: Minute[] = Array.from({ length: 240 }, (_, i) => min(i * 60, 50, 5));
  const cs = calcSleepStress(calm, baseline);
  assert(cs.arousal_events === 0, 'calm night → no arousal events');
  assert(cs.score !== null && cs.score < 10, 'calm night → low sleep-stress');
  // Restless night: periodic HR surges + motion → arousal events detected.
  const restless: Minute[] = Array.from({ length: 240 }, (_, i) => {
    const surge = i % 40 === 0; // a surge every 40 min
    return min(i * 60, surge ? 80 : 50, surge ? 3000 : 5);
  });
  const rs = calcSleepStress(restless, baseline);
  assert(rs.arousal_events >= 4, `restless night → arousal events detected (got ${rs.arousal_events})`);
  assert(rs.score! > cs.score!, 'restless night scores higher than calm');
  assert(rs.events.length > 0 && rs.events.some((e) => e.kind === 'arousal'), 'arousal events listed for overlay');
}

// ── §13 calcNocturnalHeart ─────────────────────────────────────────────────────
console.log('--- §13 calcNocturnalHeart ---');
{
  const sleep: Minute[] = [48, 46, 44, 46, 48, 50, 47, 45].map((h, i) => min(i * 60, h));
  const day: Minute[] = Array.from({ length: 20 }, (_, i) => min((100 + i) * 60, 70));
  const n = calcNocturnalHeart(sleep, day, { ...baseline, sleeping_hr: 50 });
  assert(n.sleeping_hr_avg !== null && Math.abs(n.sleeping_hr_avg - 47) <= 1, 'sleeping HR avg ≈ 47');
  assert(n.sleeping_hr_min !== null && n.sleeping_hr_min <= n.sleeping_hr_avg!, 'nadir ≤ avg');
  assert(n.day_hr_avg === 70, 'day HR avg = 70');
  assert(n.dip_pct !== null && n.dip_pct > 0.25, 'nocturnal dip computed (>25%)');
  assert(n.elevated === false, 'sleeping HR below baseline → not elevated');
  // elevated vs a low baseline
  const hi = calcNocturnalHeart(sleep, day, { ...baseline, sleeping_hr: 42 });
  assert(hi.elevated === true, 'sleeping HR ≥ baseline+4 and +5% → elevated flag');
  // no HR → empty
  const none = calcNocturnalHeart([], day, { ...baseline, sleeping_hr: 50 });
  assert(none.sleeping_hr_avg === null && none.confidence === 0, 'no sleep HR → null + conf 0');
}

// ── §14 buildNotifications ─────────────────────────────────────────────────────
console.log('--- §14 buildNotifications ---');
{
  const { buildNotifications } = require('../notify');
  const base = {
    date: '2026-06-11', readiness: 72, coach_summary: 'Solid day.',
    coach_top: { title: 'Anchor sleep timing', body: 'Aim for a steady bedtime.' },
    body_alert: null, stress_score: 40, nocturnal_elevated: false,
    sleep_debt_min: 0, acwr: 1.0, strain_today: 8, strain_target_low: 6, strain_target_high: 10,
  };
  const n = buildNotifications(base);
  assert(n.some((x: any) => x.kind === 'morning_readiness'), 'fires morning readiness');
  assert(n.every((x: any) => x.id === `2026-06-11:${x.kind}`), 'ids are date:kind (idempotent)');
  // health alert outranks everything.
  const alert = buildNotifications({ ...base, body_alert: { kind: 'overtraining', note: 'High load.' } });
  assert(alert[0].kind === 'body_alert' && alert[0].priority === 3, 'body alert ranks first, priority 3');
  // sleep debt + high stress fire.
  const heavy = buildNotifications({ ...base, sleep_debt_min: 200, stress_score: 80 });
  assert(heavy.some((x: any) => x.kind === 'sleep_debt'), 'big debt → sleep_debt notification');
  assert(heavy.some((x: any) => x.kind === 'high_stress'), 'high stress → high_stress notification');
  // streak milestone + new record.
  const milestone = buildNotifications({ ...base, streaks: { wear: 7 }, new_records: ['Lowest resting HR'] });
  assert(milestone.some((x: any) => x.kind === 'streak_wear'), '7-day wear streak → milestone');
  assert(milestone.some((x: any) => x.kind.startsWith('record_')), 'new PR → record notification');
  // cap + determinism.
  assert(n.length <= 6, 'capped at 6');
  assert(JSON.stringify(buildNotifications(base)) === JSON.stringify(buildNotifications(base)),
    'notifications deterministic');
}

// ── regression: SRI circular statistics (midnight-wrap bug) ──────────────────
console.log('--- regression: SRI circular (midnight wrap) ---');
{
  const DAY = 86400;
  // A TIGHT schedule that straddles midnight: onsets 23:50 / 00:05 / 23:55,
  // wakes ~07:20–07:30. These are within ~15 min of each other, so a regular
  // sleeper — but a LINEAR minute-of-day std treats 23:50 (1430) and 00:05 (5)
  // as ~1425 min apart and floors SRI to 0. Circular std must score it HIGH.
  const straddle = [
    { onset_ts: 0 * DAY + 1430 * 60, wake_ts: 0 * DAY + 440 * 60 },
    { onset_ts: 1 * DAY + 5 * 60,    wake_ts: 1 * DAY + 450 * 60 },
    { onset_ts: 2 * DAY + 1435 * 60, wake_ts: 2 * DAY + 435 * 60 },
  ];
  const r = calcSleepRegularity(straddle);
  assert(r.sri > 80, `midnight-straddle tight schedule → SRI high, not floored (got ${r.sri})`);
  // Genuinely scattered onsets (spread across the clock) → low SRI.
  const scattered = [
    { onset_ts: 0 * DAY + 1320 * 60, wake_ts: 0 * DAY + 360 * 60 }, // 22:00
    { onset_ts: 1 * DAY + 120 * 60,  wake_ts: 1 * DAY + 600 * 60 }, // 02:00
    { onset_ts: 2 * DAY + 1200 * 60, wake_ts: 2 * DAY + 480 * 60 }, // 20:00
  ];
  assert(calcSleepRegularity(scattered).sri < r.sri,
    'scattered schedule scores lower than the tight straddle schedule');
}

// ── regression: sleep stages are physiologically plausible (not REM-dominated) ─
console.log('--- regression: sleep stage proportions ---');
{
  // A realistic night: low activity throughout, sleeping HR varying within a
  // narrow band (deep = lowest HR, REM = highest). The OLD estimator routed the
  // top ~38% of HR plus any >2 bpm jump into REM → 60–70% REM. The fix must keep
  // REM a minority and produce a light-dominant night with some deep.
  const night: Minute[] = [];
  for (let i = 0; i < 5; i++) night.push(min(i * 60, 70, 2000));     // awake before
  for (let i = 5; i < 365; i++) {
    // sleeping HR oscillates 44..58 with minute-to-minute wobble (REM-like noise).
    const base = 44 + 7 * (1 + Math.sin(i / 25));
    const wobble = (i % 3) - 1; // -1,0,1 every minute
    night.push(min(i * 60, Math.round(base + wobble), 40));
  }
  for (let i = 365; i < 370; i++) night.push(min(i * 60, 72, 2000));  // awake after
  const s = calcSleep(night, baseline);
  const st = s.stages!;
  const tot = st.light_min + st.deep_min + st.rem_min;
  assert(tot > 0, 'stages computed');
  assert(st.rem_min / tot < 0.40, `REM is a minority, not dominant (got ${(100*st.rem_min/tot).toFixed(0)}%)`);
  assert(st.deep_min / tot > 0.05, `some deep sleep detected (got ${(100*st.deep_min/tot).toFixed(0)}%)`);
  assert(st.light_min >= st.rem_min, `light ≥ REM (light ${st.light_min} vs REM ${st.rem_min})`);
}

// ── regression: resolveMaxHr doesn't promote a quiet within-day peak ──────────
console.log('--- regression: resolveMaxHr source ---');
{
  // No baseline max, age present, day peaks only at 110 bpm (a quiet day). Must
  // use the age-predicted max (191) as the denominator, NOT call 110 "measured".
  const quiet: Minute[] = [];
  for (let i = 0; i < 60; i++) quiet.push(min(i * 60, 95 + (i % 5), 100, { hr_max: 110 }));
  const r1 = resolveMaxHr(quiet, { max_hr: 0 }, { age: 29 });
  assert(r1.source === 'age' && r1.maxHr === 191,
    `quiet-day peak not promoted to measured (got ${r1.maxHr}/${r1.source})`);
  // A genuine hard effort above age-max IS taken as measured.
  const effort: Minute[] = [];
  for (let i = 0; i < 60; i++) effort.push(min(i * 60, 150, 5000, { hr_max: i === 30 ? 198 : 150 }));
  const r2 = resolveMaxHr(effort, { max_hr: 0 }, { age: 29 });
  assert(r2.source === 'measured' && r2.maxHr === 198,
    `real above-age effort taken as measured (got ${r2.maxHr}/${r2.source})`);
  // Baseline max always wins (stable session max).
  const r3 = resolveMaxHr(quiet, { max_hr: 185 }, { age: 29 });
  assert(r3.source === 'measured' && r3.maxHr === 185, 'baseline max_hr wins');
}

summary('analytics');
