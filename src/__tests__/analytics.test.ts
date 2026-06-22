// Unit tests — one block per analytics function, asserting numeric expectations
// against fixed in-code fixtures. Run with: npx tsx src/__tests__/analytics.test.ts
import { assert, approx, summary, min } from './_harness';
import type { Baseline, Minute, Profile } from '../types';

import { calcRestingHR } from '../resting';
import { calcStrain } from '../strain';
import { calcHrZones } from '../zones';
import { calcCalories } from '../calories';
import { calcSleep, calcSleepPeriods } from '../sleep';
import { calcSleepRegularity } from '../regularity';
import { detectSessions } from '../sessions';
import { calcHrRecovery, calcRecovery } from '../recovery';
import { calcLoad, calcFitnessTrend } from '../trends';
import { calcAnomaly } from '../readiness';
import { calcBaselines } from '../baselines';
import { calcStress } from '../stress';
import { calcSpo2Index } from '../spo2';
import { calcSleepStress } from '../arousal';
import { calcNocturnalHeart } from '../nocturnal';
import { calcIllness } from '../illness';
import { timeDomainHrv, freqDomainHrv, baevskyStressIndex, cleanRr } from '../hrv';
import { pedometer, calcSteps, STEP_PARAMS } from '../steps';
import { resolveMaxHr } from '../util';
import { calcCircadian, stageSleep } from '../circadian';
import { detectSleepCycles } from '../cycles';
import { detectWakeState, peekRecentState } from '../wake';
import { calcCycle } from '../cycle';
import { extractHarFeatures, classifyActivityWindow, segmentWorkout, DB10_LO, dwtDetailEnergies } from '../har';
import type { ClassVote } from '../har';
import { calcRestlessness } from '../restlessness';
import { calcDaytimeHrv } from '../hrv';
import { calcDesaturation } from '../spo2';

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
  // maxHR 190 (%HRmax): 100bpm=52.6%→z1, 120=63%→z2, 150=78.9%→z3, 160=84%→z4, 175=92%→z5
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
    'age fallback maxHR = Tanaka 208−0.7·age (=180 at age 40) when no measured HR');
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

  // Regression (v3): the band's flash record (R24 — the entire overnight) carries NO
  // actigraphy, so `activity` is ~0 for every sleep minute and Cole-Kripke is inert; the
  // call is HR-driven. A night's HR legitimately runs ABOVE the 5th-pctile RHR floor, so
  // the old fixed `1.15*rhr` awake-override flagged the whole night awake → 1-min "sleep"
  // (observed in prod). The window-relative reference must detect it. rhr=50 floor, night
  // HR ~62 (well above 1.15*50=57.5), activity 0, bracketed by waking HR ~95.
  const aboveFloor: Minute[] = [];
  for (let i = 0; i < 30; i++) aboveFloor.push(min(i * 60, 95, 0));     // waking evening
  for (let i = 30; i < 430; i++) aboveFloor.push(min(i * 60, 62, 0));   // ~6.7h night, HR > RHR floor
  for (let i = 430; i < 470; i++) aboveFloor.push(min(i * 60, 95, 0));  // waking morning
  const af = calcSleep(aboveFloor, baseline);
  assert(af.duration_min >= 380,
    `above-floor night (HR>RHR, activity inert) is detected, not clipped to ~1min (got ${af.duration_min})`);

  // Regression (v3): the OTHER failure mode — with activity inert, a flat + ELEVATED
  // sedentary-awake window must NOT be manufactured into a full night. The absolute
  // backstop (HR > 1.5*RHR → awake) clips it. Flat 92 bpm for 5h, rhr 50 → 92 > 75.
  const flatAwake: Minute[] = [];
  for (let i = 0; i < 300; i++) flatAwake.push(min(i * 60, 92, 0));
  const fa = calcSleep(flatAwake, baseline);
  assert(fa.duration_min <= 30,
    `flat elevated sedentary-awake window is not mis-read as sleep (got ${fa.duration_min})`);

  // Plausibility guard: even if (pathologically) almost the whole 18h window
  // reads low-activity, a single main-sleep period must never exceed ~14h.
  const giant: Minute[] = [];
  for (let i = 0; i < 1080; i++) giant.push(min(i * 60, 45, 50)); // 18h of "asleep-looking" epochs
  const g = calcSleep(giant, baseline);
  assert(g.in_bed_min <= 14 * 60,
    `plausibility: main-sleep period capped at ~14h (got ${g.in_bed_min})`);
}

// ── §5b calcSleepPeriods (multi-period; naps = shorter sleeps) ───────────────
console.log('--- §5b calcSleepPeriods ---');
{
  // A main night (200 min) + a separate afternoon nap (40 min), split by a long
  // awake daytime stretch. v2 must return TWO periods, longest flagged is_main.
  const day: Minute[] = [];
  for (let i = 0; i < 5; i++) day.push(min(i * 60, 70, 2000));        // awake before
  for (let i = 5; i < 205; i++) day.push(min(i * 60, 45, 50));        // 200-min night (asleep)
  for (let i = 205; i < 305; i++) day.push(min(i * 60, 75, 2500));    // 100-min awake daytime (long gap)
  for (let i = 305; i < 345; i++) day.push(min(i * 60, 48, 50));      // 40-min afternoon nap (asleep)
  for (let i = 345; i < 350; i++) day.push(min(i * 60, 72, 2000));    // awake after
  const v2 = calcSleepPeriods(day, baseline);
  assert(v2.periods.length === 2, `two sleep periods detected (got ${v2.periods.length})`);
  const mainP = v2.periods[v2.main_idx ?? -1];
  assert(mainP != null && mainP.is_main === true, 'main period flagged is_main');
  assert(mainP.duration_min >= 195, `main period ≈ 200 min (got ${mainP?.duration_min})`);
  const napP = v2.periods.find((p) => !p.is_main);
  assert(napP != null && napP.duration_min >= 30 && napP.duration_min <= 45,
    `nap treated as a shorter sleep ≈ 40 min, edge-trimmed (got ${napP?.duration_min})`);
  assert(v2.total_asleep_min >= 228, `total asleep sums both periods (got ${v2.total_asleep_min})`);
  assert(v2.periods.every((p) => p.confidence >= 0 && p.confidence <= 1), 'per-period confidence in [0,1]');

  // Single night → exactly one period (backward-consistent with calcSleep).
  const oneNight: Minute[] = [];
  for (let i = 0; i < 5; i++) oneNight.push(min(i * 60, 70, 2000));
  for (let i = 5; i < 205; i++) oneNight.push(min(i * 60, 45, 50));
  for (let i = 205; i < 210; i++) oneNight.push(min(i * 60, 72, 2000));
  const one = calcSleepPeriods(oneNight, baseline);
  assert(one.periods.length === 1 && one.periods[0].is_main, 'single night → one main period');

  // Micro-doze (< 15 min) is discarded, not surfaced as a period.
  const micro: Minute[] = [];
  for (let i = 0; i < 5; i++) micro.push(min(i * 60, 70, 2000));
  for (let i = 5; i < 13; i++) micro.push(min(i * 60, 45, 50));        // 8-min doze
  for (let i = 13; i < 20; i++) micro.push(min(i * 60, 72, 2000));
  const m2 = calcSleepPeriods(micro, baseline);
  assert(m2.periods.length === 0 && m2.confidence === 0, 'micro-doze (<15 min) discarded');

  // Empty input → no periods, conf 0.
  const ep = calcSleepPeriods([], baseline);
  assert(ep.periods.length === 0 && ep.confidence === 0, 'no data → no periods + conf 0');
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

  // a 2-min sustained bout now qualifies (threshold lowered 3/5 → 2 min).
  const short: Minute[] = [];
  for (let i = 0; i < 10; i++) short.push(min(i * 60, 55, 1));
  for (let i = 10; i < 12; i++) short.push(min(i * 60, 150, 100)); // 2 min
  for (let i = 12; i < 20; i++) short.push(min(i * 60, 55, 1));
  assert(detectSessions(short, baseline).length === 1, '2-min bout now detected');

  // a 1-min blip is still discarded.
  const tiny: Minute[] = [];
  for (let i = 0; i < 10; i++) tiny.push(min(i * 60, 55, 1));
  tiny.push(min(10 * 60, 150, 100)); // 1 min only
  for (let i = 11; i < 20; i++) tiny.push(min(i * 60, 55, 1));
  assert(detectSessions(tiny, baseline).length === 0, '1-min blip discarded');

  // Per-minute HAR class → motion-based workout type + confidence (not the HR heuristic).
  const cyc: Minute[] = [];
  for (let i = 0; i < 10; i++) cyc.push(min(i * 60, 55, 1));
  for (let i = 10; i < 20; i++) cyc.push(min(i * 60, 140, 100, { hr_max: 150, act_class: 'cycle' }));
  for (let i = 20; i < 30; i++) cyc.push(min(i * 60, 55, 1));
  const cs = detectSessions(cyc, baseline)[0];
  assert(cs.type === 'cycle' && cs.type_confidence > 0.4, `motion class → cycle (got ${cs.type}/${cs.type_confidence})`);
  assert(cs.detected_type === 'cycle', 'detected_type recorded for calibration ledger');
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

  // acute spike (EWMA, Williams 2017): prior 21 days at 10, last 7 at 20.
  // EWMA acute (λ=0.25) rises to ~18.7, chronic (λ≈0.069) to ~13.9 → acwr ~1.34
  // (caution). EWMA is deliberately smoother than the rolling-average ratio.
  const spike = Array.from({ length: 28 }, (_, i) => ({
    ts: i * 86400,
    strain: i >= 21 ? 20 : 10,
  }));
  const sl = calcLoad(spike);
  assert(sl.band === 'caution' && (sl.acwr ?? 0) > 1.3,
    `acute spike → caution (acwr ${sl.acwr})`);

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
  // §4 cycle gate: luteal phase suppresses the pure-RHR-elevation rule (expected rise).
  const anLuteal = calcAnomaly({ recent_rhr: [50, 51, 55, 56] }, baseline, { cyclePhase: 'luteal' });
  assert(anLuteal.signal === false && /cycle/i.test(anLuteal.note),
    'luteal phase suppresses pure-RHR anomaly with a cycle note');

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

  // §5 respiratory rate as a 4th Mahalanobis feature: RMSSD↓ + resp↑ fires + lists 'resp'.
  const histR = { ...hist, resp_rate: Array.from({ length: 20 }, (_, i) => 14 + (i % 2)) };
  const sickResp = calcIllness({ resting_hr: 56, rmssd: 45, skin_temp: 34.05, resp_rate: 19 }, histR);
  assert(sickResp.signal === true && sickResp.triggers.includes('resp'),
    'elevated respiratory rate drives the illness signal');
  assert(sickResp.inputs_used.includes('resp_rate'), 'resp_rate listed in inputs_used');

  // §4 cycle gating: temp+RHR rise ALONE is phase-expected → suppressed in luteal,
  //    but still fires when no cycle context is supplied.
  const cycIn = { resting_hr: 64, rmssd: 76, skin_temp: 35.0 };
  const noCyc = calcIllness(cycIn, hist);
  assert(noCyc.signal === true && noCyc.triggers.includes('rhr') && noCyc.triggers.includes('temp'),
    'temp+RHR rise → illness signal with no cycle context');
  const luteal = calcIllness(cycIn, hist, { cyclePhase: 'luteal' });
  assert(luteal.signal === false, 'luteal phase suppresses temp/RHR-only illness signal');
  assert(/cycle/i.test(luteal.note), 'suppressed signal explains the cycle phase');
  // …but HRV/resp deviations are NOT explained by the cycle → still fires.
  const lutealReal = calcIllness({ resting_hr: 64, rmssd: 45, skin_temp: 35.0, resp_rate: 19 }, histR, { cyclePhase: 'luteal' });
  assert(lutealReal.signal === true, 'HRV/resp shift still fires even in luteal phase');
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
  // Observed daily peak (189) CLEARS the age-predicted floor (age 40 → Tanaka 180),
  // so it's a genuine effort → trusted as the measured max.
  const bl = calcBaselines(hist, { age: 40 });
  assert(bl.resting_hr !== null && bl.resting_hr! >= 50 && bl.resting_hr! <= 52, 'RHR median in range');
  assert(bl.max_hr === 189 && bl.max_hr_source === 'measured', 'observed peak above age floor → measured');
  assert(bl.chronic_strain !== null, 'chronic strain computed');
  assert(bl.zone_min !== null && bl.zone_min![0] === 10, 'per-zone medians present');
  approx(bl.confidence, 1, 1e-9, '30 days → confidence 1');

  // Guard: a quiet daily peak (≤ age floor) must NOT be promoted to a measured max —
  // it would under-state HRmax and inflate zones/strain. Age floor wins instead.
  const quiet = hist.map((d) => ({ ...d, session_hr_max: 150 }));
  const blQuiet = calcBaselines(quiet, { age: 30 }); // Tanaka 187 > 150
  assert(blQuiet.max_hr === 187 && blQuiet.max_hr_source === 'age', 'quiet daily peak → age floor, not measured');

  // age fallback for maxHR when no sessions
  const noSess = hist.map((d) => ({ ...d, session_hr_max: undefined }));
  const bl2 = calcBaselines(noSess, { age: 30 });
  assert(bl2.max_hr === 187 && bl2.max_hr_source === 'age', 'no sessions + age → Tanaka 208−0.7·age maxHR');

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
  for (let i = 0; i < 320; i++) { // ≥250 s span so LF (and LF/HF) are valid per Task Force 1996
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

// ── §SpO₂ relative index (red/IR ratio) ───────────────────────────────────────
console.log('--- §calcSpo2Index ---');
{
  // Too few minutes → null, conf 0.
  assert(calcSpo2Index([0.85, 0.86, 0.85], 0.85).index === null, 'spo2: <30 min → null');
  assert(calcSpo2Index([0.85, 0.86], 0.85).confidence === 0, 'spo2: too few → conf 0');
  // No baseline yet → seed night_ratio, null index.
  const stable = Array.from({ length: 200 }, () => 0.850);
  const seed = calcSpo2Index(stable, null);
  assert(seed.index === null, 'spo2: no baseline → null index');
  approx(seed.night_ratio!, 0.85, 0.001, 'spo2: no baseline → seed night_ratio');
  // Stable clean night vs baseline → high confidence; lower ratio than baseline → positive index.
  const better = calcSpo2Index(Array.from({ length: 200 }, () => 0.840), 0.850);
  assert(better.index !== null && better.index > 0, 'spo2: lower ratio than baseline → positive index');
  assert(better.confidence > 0.8, 'spo2: stable + plenty of samples → high confidence');
  // Noisy night (high intra-night CV) → low confidence even with a baseline.
  const noisy = calcSpo2Index(Array.from({ length: 200 }, (_, i) => 0.85 + (i % 2 ? 0.08 : -0.08)), 0.850);
  assert(noisy.confidence < 0.3, 'spo2: high intra-night CV → low confidence');
  // Plausibility gate drops garbage ratios.
  assert(calcSpo2Index(Array.from({ length: 200 }, () => 3.0), 0.85).index === null, 'spo2: implausible ratios → null');
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

// ── regression: stageSleep detects REM from RR variability on a flat-HR night ──
console.log('--- regression: RR-driven REM staging ---');
{
  // A calm night where HR is nearly flat (≈60 bpm) so HR LEVEL alone CANNOT separate
  // REM from light (the real bug: REM read 0%). REM is encoded the physiological way —
  // parasympathetic withdrawal → REDUCED beat-to-beat variability (low RMSSD), with HR
  // only mildly above light. Deep = high RMSSD + lowest HR. stageSleep must use the RR
  // autonomic axis to recover a physiological REM share (15–25%), not 0.
  const ONSET = 0, WAKE = 280 * 60;
  // Build a minute's RR stream with a target RMSSD: alternate ±d around the mean RR so
  // successive |Δ| ≈ 2d ⇒ RMSSD ≈ 2d (kept < 200 ms so cleanRr doesn't drop beats).
  const rrFor = (hr: number, rmssdTarget: number): number[] => {
    const meanRr = Math.round(60000 / hr);
    const d = Math.min(95, Math.round(rmssdTarget / 2));
    const out: number[] = [];
    for (let j = 0; j < 48; j++) out.push(meanRr + (j % 2 === 0 ? d : -d));
    return out;
  };
  type SM = { ts: number; hr_avg: number; rr?: number[] };
  const night: SM[] = [];
  const push = (a: number, b: number, hr: number, rmssd: number) => {
    for (let i = a; i < b; i++) night.push({ ts: i * 60, hr_avg: hr, rr: rrFor(hr, rmssd) });
  };
  push(0, 30, 60, 50);     // light  (medium variability)
  push(30, 95, 56, 90);    // deep   (high RMSSD, lowest HR)
  push(95, 150, 60, 50);   // light
  push(150, 215, 64, 16);  // REM    (low RMSSD, mildly elevated HR)
  push(215, 280, 60, 50);  // light
  const ss = stageSleep(night, ONSET, WAKE, /*mesor*/ 90);
  const tot = ss.light_min + ss.deep_min + ss.rem_min;
  assert(tot > 0, 'RR-staged night produced stages');
  const remPct = (100 * ss.rem_min) / tot, deepPct = (100 * ss.deep_min) / tot;
  assert(remPct >= 12 && remPct <= 35, `REM recovered from RR, physiological share (got ${remPct.toFixed(0)}%)`);
  assert(deepPct >= 8, `deep detected from high-RMSSD block (got ${deepPct.toFixed(0)}%)`);
  assert(ss.light_min >= ss.rem_min, 'light remains dominant');
  // 0 short(<20 min) awake flaps in the hypnogram.
  let flaps = 0;
  for (let i = 0; i < ss.hypnogram.length;) {
    let j = i; while (j < ss.hypnogram.length && ss.hypnogram[j].stage === ss.hypnogram[i].stage) j++;
    if (ss.hypnogram[i].stage === 'awake' && (j - i) < 20) flaps++;
    i = j;
  }
  assert(flaps === 0, `no short awake flaps (got ${flaps})`);
  // Without RR, the SAME flat-HR night cannot resolve REM → graceful HR-only fallback
  // (must not throw, must not fabricate a REM-dominated night).
  const noRr = night.map((m) => ({ ts: m.ts, hr_avg: m.hr_avg }));
  const fb = stageSleep(noRr, ONSET, WAKE, 90);
  assert((fb.light_min + fb.deep_min + fb.rem_min) > 0, 'HR-only fallback still stages');
}

// ── §Sleep cycles (fractal-cycle method on HRV) ───────────────────────────────
console.log('--- §detectSleepCycles ---');
{
  // RMSSD oscillating with a ~80-min ultradian period over a 320-min night → the
  // findpeaks(20min, 0.9z) detector should recover ~4 peaks ⇒ ~3 cycles near 80 min.
  // RR is built so each minute's RMSSD ≈ target: alternate ±d ⇒ RMSSD ≈ 2d.
  const rrFor = (rmssd: number): number[] => {
    const d = Math.max(2, Math.round(rmssd / 2));
    return Array.from({ length: 40 }, (_, j) => 900 + (j % 2 ? d : -d));
  };
  const mins: { ts: number; rr: number[] }[] = [];
  for (let i = 0; i < 320; i++) {
    const rmssd = 50 + 30 * Math.sin((2 * Math.PI * i) / 80); // ~80-min cycle
    mins.push({ ts: i * 60, rr: rrFor(rmssd) });
  }
  const c = detectSleepCycles(mins, 0, 319 * 60);
  assert(c.n >= 2 && c.n <= 6, `cycles: ~3-4 ultradian cycles found (got ${c.n})`);
  assert(c.mean_duration_min != null && c.mean_duration_min >= 55 && c.mean_duration_min <= 110,
    `cycles: mean duration near the ~80-min period (got ${c.mean_duration_min})`);
  assert(c.series.length > 0, 'cycles: emits a z-series for plotting');
  // No RR → abstain cleanly (no fabricated cycles).
  const noRr = detectSleepCycles(Array.from({ length: 200 }, (_, i) => ({ ts: i * 60 })), 0, 199 * 60);
  assert(noRr.n === 0 && noRr.cycles.length === 0, 'cycles: no RR → abstains');
}

// ── regression: resolveMaxHr doesn't promote a quiet within-day peak ──────────
console.log('--- regression: resolveMaxHr source ---');
{
  // No baseline max, age present, day peaks only at 110 bpm (a quiet day). Must
  // use the age-predicted max (Tanaka: 208−0.7·29 ≈ 188) as the denominator,
  // NOT call 110 "measured".
  const quiet: Minute[] = [];
  for (let i = 0; i < 60; i++) quiet.push(min(i * 60, 95 + (i % 5), 100, { hr_max: 110 }));
  const r1 = resolveMaxHr(quiet, { max_hr: 0 }, { age: 29 });
  assert(r1.source === 'age' && r1.maxHr === 188,
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

// ── §Steps pedometer (AN-2554) ───────────────────────────────────────────────
console.log('--- §Steps pedometer ---');
{
  // Rest: flat 1g magnitude → the CONFIRM gate must read exactly 0.
  const rest: number[] = new Array(3000).fill(1.0);
  assert(pedometer(rest) === 0, 'rest signal → 0 steps (CONFIRM gate rejects non-gait)');

  // Walk: clean ~1.8 Hz cadence over 30 s @100 Hz ≈ 54 gait cycles. Magnitude
  // swings well outside the ±SENS dead-zone, so each cycle is a step.
  const walk: number[] = [];
  for (let i = 0; i < 3000; i++) walk.push(1.0 + 0.3 * Math.sin(2 * Math.PI * 1.8 * (i / 100)));
  const raw = pedometer(walk);
  assert(raw >= 45 && raw <= 60, `walk ~54 cycles → plausible step count (got ${raw})`);

  // calcSteps groups per-minute signals, sums, applies the calibration gain.
  assert(calcSteps([rest]) === 0, 'calcSteps all-rest → 0');
  approx(calcSteps([walk]), Math.round(raw * STEP_PARAMS.GAIN), 0.001,
    'calcSteps applies the ×GAIN calibration to the summed raw count');
  assert(STEP_PARAMS.GAIN === 1.11, 'locked calibration gain = 1.11');
}

// ── §Circadian — CircaCP cosinor + bounded change-point ──────────────────────
console.log('--- §Circadian calcCircadian ---');
{
  // 2 days of 1-min HR: asleep (hr≈55) hours [1,8), awake (hr≈80) otherwise.
  // Onset ≈ 01:00, wake ≈ 08:00 each day; sharp transitions.
  const mins: Minute[] = [];
  for (let i = 0; i < 2 * 1440; i++) {
    const ts = i * 60;
    const hod = Math.floor(ts / 3600) % 24;
    const asleep = hod >= 1 && hod < 8;
    const hr = (asleep ? 55 : 80) + (i % 5) - 2; // tiny deterministic jitter
    mins.push(min(ts, hr));
  }
  const c = calcCircadian(mins);
  assert(c.amplitude !== null && c.amplitude > 5, `circadian amplitude detected (got ${c.amplitude})`);
  // day-2 onset ≈ 90000s (25:00 → 01:00 day 2), wake ≈ 115200s (32:00 → 08:00 day 2)
  assert(c.onset_ts !== null && Math.abs(c.onset_ts - 90000) <= 1800, `onset ≈ 01:00 day2 (got ${c.onset_ts})`);
  assert(c.wake_ts !== null && Math.abs(c.wake_ts - 115200) <= 1800, `wake ≈ 08:00 day2 (got ${c.wake_ts})`);
  assert(c.settled === true, 'completed night marked settled');
  assert(c.confidence > 0.5, `confidence high on clean rhythm (got ${c.confidence})`);

  // flat HR (no rhythm) → abstain
  const flat: Minute[] = [];
  for (let i = 0; i < 2 * 1440; i++) flat.push(min(i * 60, 70));
  const cf = calcCircadian(flat);
  assert(cf.onset_ts === null && cf.confidence < 0.3, 'flat HR → abstains (no fabricated boundary)');
}

// ── detectWakeState (sleep/wake ensemble) ─────────────────────────────────────
{
  const bl: Baseline = { resting_hr: 50, max_hr: 190, sleep_need_min: 480 };
  // 8h sleep (low HR, still) then N min awake (elevated HR, moving + steps).
  const build = (awakeMin: number): Minute[] => {
    const out: Minute[] = [];
    let t = 0;
    for (let i = 0; i < 480; i++, t += 60) out.push(min(t, 50, 0.01, { wrist_on: true }));
    for (let i = 0; i < awakeMin; i++, t += 60) out.push(min(t, 72, 0.4, { steps: 20, wrist_on: true }));
    return out;
  };

  const woke = detectWakeState({ minutes: build(15), baseline: bl });
  assert(woke.state === 'awake', `ensemble: state awake after waking (got ${woke.state})`);
  assert(woke.wake_ts != null && Math.abs(woke.wake_ts - 480 * 60) <= 180, `ensemble: wake_ts ≈ sleep→wake boundary ±3min (got ${woke.wake_ts})`);
  assert(woke.awake_min >= 12 && woke.awake_min <= 19, `ensemble: sustained awake ~15 min ±detector fuzz (got ${woke.awake_min})`);
  assert(woke.asleep_min >= 90, `ensemble: main sleep ≥90 min (got ${woke.asleep_min})`);

  const tooSoon = detectWakeState({ minutes: build(5), baseline: bl });
  assert(tooSoon.wake_ts === null, 'ensemble: <10 min awake → no premature wake fire');

  const stillAsleep = detectWakeState({ minutes: build(0), baseline: bl });
  assert(stillAsleep.state === 'asleep' && stillAsleep.wake_ts === null, 'ensemble: mid-sleep → asleep, no wake_ts');

  const movingTail = [min(0, 72, 0.4, { steps: 20, wrist_on: true }), min(60, 73, 0.5, { steps: 25, wrist_on: true }), min(120, 71, 0.3, { steps: 10, wrist_on: true })];
  assert(peekRecentState(movingTail, bl) === 'awake', 'peek: moving + HR up → awake');
}

// ── regression: QUIET sedentary wake (HR up, NO motion, RR present) must fire ──
// The real-world bug: a user awake but still (on the phone in bed) has elevated HR
// and RR but ~zero motion. The OLD flat 2-of-3 majority let the two motion voters
// (blind to quiet wake) outvote cardiac → "asleep" → close never fired → no recovery.
// The ≥2 consensus must let the autonomic pair (cardiac + hrvArousal) carry the wake.
{
  const bl: Baseline = { resting_hr: 55, max_hr: 190, sleep_need_min: 480 };
  const minutes: Minute[] = [];
  const rrByMin = new Map<number, number[]>();
  let t = 0;
  const rr = (meanMs: number, sd: number, n = 40) => Array.from({ length: n }, (_, j) => meanMs + (j % 2 ? sd : -sd));
  for (let i = 0; i < 480; i++, t += 60) { minutes.push(min(t, 52, 0.01, { wrist_on: true })); rrByMin.set(t, rr(1150, 12)); } // sleep: low HR, still, low RR-SD
  for (let i = 0; i < 30; i++, t += 60) { minutes.push(min(t, 74, 0.01, { wrist_on: true })); rrByMin.set(t, rr(810, 60)); }   // QUIET wake: HR up, NO motion, high RR-SD

  const ws = detectWakeState({ minutes, baseline: bl, rrByMin });
  assert(ws.state === 'awake', `quiet sedentary wake detected without motion (got ${ws.state})`);
  assert(ws.wake_ts != null && Math.abs(ws.wake_ts - 480 * 60) <= 180, `quiet wake_ts at the boundary (got ${ws.wake_ts})`);
  assert(ws.asleep_min >= 90, `main sleep preserved (got ${ws.asleep_min})`);
  assert(ws.votes.cardiac === 'awake' && ws.votes.hrvArousal === 'awake', 'autonomic pair both vote awake at wake');

  // Honest degradation: same still-but-awake tail with NO RR → only 1 signal (cardiac)
  // → below the ≥2 bar → stays asleep rather than guess.
  const noRr = detectWakeState({ minutes, baseline: bl });
  assert(noRr.wake_ts === null, `no-RR + no-motion quiet wake cannot be confirmed (honest) (got ${noRr.wake_ts})`);
}

// ── menstrual cycle (log-anchored calendar method) ───────────────────────────
{
  // No logs → empty/abstain.
  const none = calcCycle([], '2026-06-20');
  assert(none.confidence === 0 && none.phase === 'unknown' && none.predicted_next === null,
    'cycle: no logs → abstain');

  // Three regular 28-day starts → median 28, prediction = last + 28.
  const starts = ['2026-04-04', '2026-05-02', '2026-05-30'];
  const c = calcCycle(starts, '2026-06-06'); // day 8 of the cycle that began 05-30
  assert(c.mean_length === 28, `cycle: median length 28 (got ${c.mean_length})`);
  assert(c.length_history.length === 2, `cycle: 2 observed lengths (got ${c.length_history.length})`);
  assert(c.cycle_day === 8, `cycle: cycle day 8 (got ${c.cycle_day})`);
  assert(c.predicted_next === '2026-06-27', `cycle: next period 06-27 (got ${c.predicted_next})`);
  assert(c.ovulation_est === '2026-06-13', `cycle: ovulation = next−14 (got ${c.ovulation_est})`);
  assert(c.fertile_start === '2026-06-08' && c.fertile_end === '2026-06-14',
    `cycle: fertile window ov−5..ov+1 (got ${c.fertile_start}..${c.fertile_end})`);
  assert(c.phase === 'follicular', `cycle: day 8 pre-ovulation → follicular (got ${c.phase})`);
  assert(c.confidence > 0.5, `cycle: confidence grows with cycles (got ${c.confidence})`);

  // Menstruation window (day ≤ 5).
  const m = calcCycle(starts, '2026-05-31'); // day 2
  assert(m.phase === 'menstruation', `cycle: day 2 → menstruation (got ${m.phase})`);

  // Luteal: after the fertile window, before next period.
  const l = calcCycle(starts, '2026-06-20'); // day 22
  assert(l.phase === 'luteal', `cycle: day 22 → luteal (got ${l.phase})`);

  // Very overdue → prediction unreliable, abstain on phase + low confidence.
  const od = calcCycle(starts, '2026-07-25'); // ~56 days since last start
  assert(od.phase === 'unknown' && od.confidence <= 0.2, `cycle: very overdue → unknown/low conf (got ${od.phase}/${od.confidence})`);

  // Single log → 28-day default, low-but-nonzero confidence.
  const one = calcCycle(['2026-06-10'], '2026-06-15');
  assert(one.mean_length === null && one.predicted_next === '2026-07-08' && one.confidence > 0,
    `cycle: single log uses 28d default (got ${one.predicted_next}/${one.confidence})`);
}

// ── §HAR — activity recognition (Mannini features + classifier + segmentation) ──
console.log('--- §HAR activity recognition ---');
{
  // db10 orthonormality invariants — catch any coefficient transcription error.
  const sumLo = DB10_LO.reduce((s, v) => s + v, 0);
  const sumSq = DB10_LO.reduce((s, v) => s + v * v, 0);
  assert(DB10_LO.length === 20, 'db10 has 20 taps');
  approx(sumLo, Math.SQRT2, 1e-6, 'db10 Σh = √2');
  approx(sumSq, 1, 1e-6, 'db10 Σh² = 1');

  // Synthetic tri-axial window: gravity on Z + a sinusoidal swing at f0 on X.
  const fs = 100, secs = 4, n = fs * secs;
  // Oscillate the magnitude (gravity axis) at f0 so SMV ≈ 1 + amp·sin(2π f0 t) — this
  // matches how the accel-vector magnitude actually varies with gait (avoids the sin²
  // frequency-doubling artifact you get from a single off-axis sinusoid).
  const mk = (f0: number, amp: number, noise = 0.004) => {
    const x: number[] = [], y: number[] = [], z: number[] = [];
    for (let i = 0; i < n; i++) {
      const t = i / fs;
      z.push(1 + amp * Math.sin(2 * Math.PI * f0 * t) + (((i * 7919) % 991) / 991 - 0.5) * noise);
      x.push((((i * 1103515245 + 12345) % 1000) / 1000 - 0.5) * noise);
      y.push((((i * 1103) % 997) / 997 - 0.5) * noise);
    }
    return { x, y, z };
  };

  // Frequency detection: a 2.0 Hz swing → dom1_freq ≈ 2.0 (within bin resolution).
  const w2 = mk(2.0, 0.5);
  const f2 = extractHarFeatures(w2.x, w2.y, w2.z, fs);
  approx(f2.dom1_freq, 2.0, 0.3, `HAR dom1_freq ≈ 2.0 (got ${f2.dom1_freq.toFixed(2)})`);
  assert(f2.dom1_ratio > 0.25, 'HAR strong sine → periodic (high dom1_ratio)');

  // Classification: flat (gravity only, tiny noise) → sedentary.
  const flat = mk(1.0, 0.0);
  assert(classifyActivityWindow(extractHarFeatures(flat.x, flat.y, flat.z, fs)).cls === 'sedentary',
    'HAR flat signal → sedentary');

  // 2 Hz strong swing → a locomotion class (walk), not sedentary/other.
  const cw = classifyActivityWindow(f2);
  assert(cw.cls === 'walk', `HAR 2 Hz → walk (got ${cw.cls})`);

  // 2.8 Hz strong swing → run.
  const w3 = mk(2.8, 0.6);
  assert(classifyActivityWindow(extractHarFeatures(w3.x, w3.y, w3.z, fs)).cls === 'run',
    'HAR 2.8 Hz → run');

  // wavelet detail energies present (6 levels), non-negative.
  const we = dwtDetailEnergies(w2.x, 6);
  assert(we.length === 6 && we.every((e) => e >= 0), 'db10 detail energies: 6 levels, ≥0');

  // Segmentation: 5 min walk → 5 min run (one continuous bout) → two phases, primary = either.
  const votes: ClassVote[] = [];
  for (let t = 0; t < 300; t += 4) votes.push({ ts: 1000 + t, cls: 'walk', conf: 0.7 });
  for (let t = 300; t < 600; t += 4) votes.push({ ts: 1000 + t, cls: 'run', conf: 0.7 });
  const seg = segmentWorkout(votes);
  assert(seg.segments.length === 2, `HAR segment: walk→run → 2 phases (got ${seg.segments.length})`);
  assert(seg.segments[0].type === 'walk' && seg.segments[1].type === 'run', 'HAR phases ordered walk then run');

  // A single-window blip inside a long run is smoothed away (no spurious phase).
  const blip: ClassVote[] = [];
  for (let t = 0; t < 600; t += 4) blip.push({ ts: 2000 + t, cls: t === 300 ? 'cycle' : 'run', conf: 0.7 });
  assert(segmentWorkout(blip).segments.length === 1, 'HAR single-window blip smoothed → one phase');
}

// ── §Restlessness / §Daytime HRV / §Desaturation ────────────────────────────
console.log('--- §restlessness / daytime HRV / desaturation ---');
{
  // Restlessness: a still night with a movement spike every 30 min → bouts detected.
  const sleepMin: Minute[] = [];
  for (let i = 0; i < 240; i++) {
    const moving = i % 30 === 0;
    sleepMin.push({ ts: 1000 + i * 60, hr_avg: 55, hr_min: 54, hr_max: 56, hr_n: 60, activity: moving ? 0.5 : 0.01, steps: 0, wrist_on: true });
  }
  const rest = calcRestlessness(sleepMin);
  assert(rest.score !== null && rest.movement_bouts >= 5, `restlessness: detects bouts (got ${rest.movement_bouts})`);
  assert(rest.longest_still_min > 0 && rest.mobility_pct !== null, 'restlessness: still stretch + mobility');
  assert(calcRestlessness(sleepMin.slice(0, 5)).score === null, 'restlessness: <20 min → null');

  // Daytime HRV: 60 min of RR bucketed into 5-min windows → per-window RMSSD series.
  const byMin: { ts: number; rr: number[] }[] = [];
  for (let i = 0; i < 60; i++) {
    const rr: number[] = [];
    for (let k = 0; k < 12; k++) rr.push(850 + ((i + k) % 5) * 15);
    byMin.push({ ts: 1000 + i * 60, rr });
  }
  const dh = calcDaytimeHrv(byMin, 300);
  assert(dh.rmssd_median !== null && dh.n_windows >= 10, `daytime HRV: windows (got ${dh.n_windows})`);
  assert(dh.series.length === dh.n_windows && dh.lowest_ts !== null, 'daytime HRV: series + lowest window');
  assert(calcDaytimeHrv([], 300).rmssd_median === null, 'daytime HRV: no RR → null');

  // Desaturation: a 2-min dip (R↑ above baseline) every 20 min → events counted.
  const ratios: number[] = [];
  for (let i = 0; i < 120; i++) ratios.push(i % 20 < 2 ? 0.86 : 0.79);
  const des = calcDesaturation(ratios, 0.80);
  assert(des.events >= 4 && des.odi !== null, `desaturation: counts dips (got ${des.events})`);
  assert(des.deepest_pct !== null && des.deepest_pct > 0, 'desaturation: reports deepest dip');
  const desNoBase = calcDesaturation(ratios, null);
  assert(desNoBase.events === 0 && desNoBase.confidence === 0, 'desaturation: no baseline → abstain');
}

summary('analytics');
