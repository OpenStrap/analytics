// Full synthetic parity oracle: generate deterministic fake data, run EVERY real
// TS analytics function, and dump {name: input} + {name: ts_output}. The Rust test
// `parity_all` feeds the SAME inputs through the ported core and asserts 1:1.
import { writeFileSync } from 'fs';
import { calcStrain } from '../src/strain';
import { calcRestingHR } from '../src/resting';
import { timeDomainHrv, freqDomainHrv, baevskyStressIndex, calcHrvStability, calcIrregular, calcDaytimeHrv } from '../src/hrv';
import { calcHrZones } from '../src/zones';
import { calcCalories } from '../src/calories';
import { calcRecovery, calcHrRecovery } from '../src/recovery';
import { calcStress } from '../src/stress';
import { calcNocturnalHeart } from '../src/nocturnal';
import { calcSleepRegularity } from '../src/regularity';
import { calcLoad, calcFitnessTrend } from '../src/trends';
import { calcVo2Max, calcFitnessModel, calcMonotony } from '../src/fitness';
import { calcReadinessIndex } from '../src/readiness_index';
import { calcSpo2Index, calcDesaturation } from '../src/spo2';
import { calcSteps } from '../src/steps';
import { calcRestlessness } from '../src/restlessness';
import { calcSleepStress } from '../src/arousal';
import { calcBaselines } from '../src/baselines';
import { calcIllness } from '../src/illness';
import { calcAnomaly } from '../src/readiness';
import { calcCycle } from '../src/cycle';
import { detectSleepCycles } from '../src/cycles';
import { calcSleep, calcSleepPeriods, stageHypnogram } from '../src/sleep';
import { extractHarFeaturesFromSmv, classifyActivityWindow, segmentWorkout } from '../src/har';
import { detectSessions } from '../src/sessions';
import { calcCircadian, stageSleep } from '../src/circadian';
import { detectWakeState, peekRecentState } from '../src/wake';
import { buildCoach } from '../src/coach';
import { buildNotifications } from '../src/notify';
import type { Minute, Baseline } from '../src/types';

// deterministic pseudo-random in [0,1)
let _s = 12345;
const rnd = () => { _s = (_s * 1103515245 + 12345) & 0x7fffffff; return _s / 0x7fffffff; };

const B: Baseline = { resting_hr: 52, max_hr: 190, sleep_need_min: 480, skin_temp: 34.2, chronic_strain: 8, sleeping_hr: 54 } as any;
const PROFILE = { age: 31, weight_kg: 74, height_cm: 178, sex: 'm' as const };

function mkMin(ts: number, hr: number, act: number, opts: Partial<Minute> = {}): Minute {
  return { ts, hr_avg: hr, hr_min: Math.max(0, hr - 4), hr_max: hr + 5, hr_n: 60, activity: act, steps: 0, wrist_on: hr > 0, ...opts } as Minute;
}
// a synthetic day: 600 min, sleep block low-HR then active afternoon.
const day: Minute[] = [];
for (let i = 0; i < 600; i++) {
  const night = i < 360;
  const hr = night ? 50 + 8 * Math.sin(i / 50) + rnd() * 4 : 80 + 40 * Math.max(0, Math.sin(i / 30)) + rnd() * 6;
  const act = night ? rnd() * 0.02 : rnd() * 0.4;
  day.push(mkMin(i * 60, Math.round(hr), Math.round(act * 1000) / 1000));
}
const sleepMin = day.slice(0, 360);
const dayMin = day.slice(360);

// RR stream (ms) ~ 60000/hr with variability.
const rr: number[] = [];
for (let i = 0; i < 400; i++) rr.push(Math.round(820 + 60 * Math.sin(i / 7) + rnd() * 40 - 20));
const byMinuteRr = Array.from({ length: 40 }, (_, m) => ({ ts: m * 60, rr: rr.slice(m * 8, m * 8 + 8) }));

const dailyStrain = Array.from({ length: 30 }, (_, i) => ({ ts: i * 86400, strain: 6 + 5 * Math.sin(i / 4) + rnd() }));
const dayHist = Array.from({ length: 30 }, (_, i) => ({
  resting_hr: 52 + Math.round(3 * Math.sin(i / 5)), sleep_duration_min: 440 + Math.round(rnd() * 60),
  skin_temp: 34 + rnd() * 0.5, daily_strain: 8 + rnd() * 4, session_hr_max: 150 + Math.round(rnd() * 40),
  hrr60: 28 + Math.round(rnd() * 10), zone_min: [10, 20, 15, 5, 2] as [number, number, number, number, number],
}));
const nights = Array.from({ length: 7 }, (_, i) => ({ onset_ts: i * 86400 + 0, wake_ts: i * 86400 + 28000 + Math.round(rnd() * 1800) }));
const ratios = Array.from({ length: 200 }, () => 0.82 + rnd() * 0.06);
const minuteSignals = Array.from({ length: 5 }, () => Array.from({ length: 200 }, (_, k) => 1 + 0.3 * Math.sin(k / 3) + rnd() * 0.05));
const smv = Array.from({ length: 512 }, (_, k) => 1 + 0.4 * Math.sin((2 * Math.PI * 1.8 * k) / 30) + rnd() * 0.02);
const votes = Array.from({ length: 30 }, (_, i) => ({ ts: i * 60, cls: (i < 15 ? 'run' : 'walk') as any, conf: 0.8 }));
const sessMin = day.map((m, i) => (i >= 380 && i < 420 ? { ...m, hr_avg: 150, hr_max: 158, activity: 0.5, act_class: i < 400 ? 'run' : 'walk' } : m)) as Minute[];

const illToday = { resting_hr: 60, rmssd: 38, skin_temp: 34.9, resp_rate: 18 };
const illHist = {
  resting_hr: Array.from({ length: 14 }, () => 52 + rnd() * 3), rmssd: Array.from({ length: 14 }, () => 65 + rnd() * 8),
  skin_temp: Array.from({ length: 14 }, () => 34.1 + rnd() * 0.3), resp_rate: Array.from({ length: 14 }, () => 15 + rnd() * 1.5),
};
const coachIn = {
  readiness: 38, readiness_components: { rhr: 0.6, sleep_debt: 0.7, sleep_quality: 0.75 }, resting_hr: 60, baseline_rhr: 52,
  rhr_recent: [52, 53, 55, 60], strain_today: 5, acwr: 1.45, sleep_last_min: 360, sleep_need_min: 480, sleep_debt_min: 150,
  sleep_efficiency: 0.78, sri: 64, fitness_direction: 'flat', anomaly: { signal: true, kind: 'overtraining', note: 'Load spike.' },
};
const notifyIn = {
  date: '2026-06-20', readiness: 38, coach_summary: 'Low recovery · slept 6h 0m · high load', coach_top: { title: 'Ease off', body: 'Rest today.' },
  body_alert: { kind: 'overtraining', note: 'Load spike.' }, stress_score: 74, nocturnal_elevated: false, sleep_debt_min: 150,
  acwr: 1.45, strain_today: 5, strain_target_low: 8, strain_target_high: 12, streaks: { wear: 30, strain_target: 7 }, new_records: ['Best 5k!'],
};

const inputs: Record<string, any> = {};
const outputs: Record<string, any> = {};
const add = (name: string, payload: any, out: any) => { inputs[name] = payload; outputs[name] = out; };

add('calc_strain', { minutes: day, baseline: B, profile: PROFILE }, calcStrain(day, B, PROFILE));
add('calc_resting_hr', { minutes: day, sleep_window: { onset_ts: 0, wake_ts: 360 * 60 } }, calcRestingHR(day, { onset_ts: 0, wake_ts: 360 * 60 }));
add('time_domain_hrv', { rr }, timeDomainHrv(rr));
add('freq_domain_hrv', { rr }, freqDomainHrv(rr));
add('baevsky_stress_index', { rr }, baevskyStressIndex(rr));
add('calc_hrv_stability', { series: [60, 64, 58, 70, 55, 62, 66] }, calcHrvStability([60, 64, 58, 70, 55, 62, 66]));
add('calc_irregular', { rr: rr.concat(rr) }, calcIrregular(rr.concat(rr)));
add('calc_daytime_hrv', { by_minute: byMinuteRr, bucket_sec: 300 }, calcDaytimeHrv(byMinuteRr, 300));
add('calc_hr_zones', { minutes: day, baseline: B, profile: PROFILE }, calcHrZones(day, B, PROFILE));
add('calc_calories', { minutes: day, profile: PROFILE, resting_hr: 52, max_hr: 190 }, calcCalories(day, PROFILE, 52, 190));
add('calc_recovery', { rmssd_today: 58, baseline_rmssd: [65, 62, 70, 60, 64, 68], date: '2026-06-20' }, calcRecovery(58, [65, 62, 70, 60, 64, 68], { date: '2026-06-20' }));
add('calc_hr_recovery', { minutes: sessMin, baseline: B, profile: PROFILE }, calcHrRecovery(sessMin, B, PROFILE));
add('calc_stress', { rr, baseline_si: [80, 95, 70, 110, 88, 92], date: '2026-06-20' }, calcStress(rr, [80, 95, 70, 110, 88, 92], { date: '2026-06-20' }));
add('calc_nocturnal_heart', { sleep_minutes: sleepMin, day_minutes: dayMin, baseline: B }, calcNocturnalHeart(sleepMin, dayMin, B as any));
add('calc_sleep_regularity', { nights }, calcSleepRegularity(nights));
add('calc_load', { daily_strain: dailyStrain }, calcLoad(dailyStrain));
add('calc_fitness_model', { daily_strain: dailyStrain }, calcFitnessModel(dailyStrain));
add('calc_monotony', { daily_strain: dailyStrain }, calcMonotony(dailyStrain));
add('calc_fitness_trend', { daily: dayHist }, calcFitnessTrend(dayHist));
add('calc_vo2max', { max_hr: 190, resting_hr: 52 }, calcVo2Max(190, 52));
add('calc_readiness_index', { recovery: 62, sleep_duration_min: 420, sleep_need_min: 480, dip_pct: 0.08, sleep_stress: 35 }, calcReadinessIndex({ recovery: 62, sleepDurationMin: 420, sleepNeedMin: 480, dipPct: 0.08, sleepStress: 35 }));
add('calc_spo2_index', { ratios, baseline_ratio: 0.85 }, calcSpo2Index(ratios, 0.85));
add('calc_desaturation', { ratios, baseline_ratio: 0.83 }, calcDesaturation(ratios, 0.83));
add('calc_steps', { minute_signals: minuteSignals }, { steps: calcSteps(minuteSignals) });
add('calc_restlessness', { sleep_minutes: sleepMin }, calcRestlessness(sleepMin));
add('calc_sleep_stress', { sleep_minutes: sleepMin, baseline: B }, calcSleepStress(sleepMin, B));
add('calc_baselines', { history: dayHist, profile: PROFILE }, calcBaselines(dayHist, PROFILE));
add('calc_illness', { today: illToday, history: illHist, cycle_phase: 'luteal' }, calcIllness(illToday, illHist, { cyclePhase: 'luteal' }));
add('calc_anomaly', { recent_rhr: [52, 56, 58, 60], skin_temp: 34.9, sleep_efficiency: 0.78, baseline_sleep_efficiency: 0.88, baseline: B, cycle_phase: null }, calcAnomaly({ recent_rhr: [52, 56, 58, 60], skin_temp: 34.9, sleep_efficiency: 0.78, baseline_sleep_efficiency: 0.88 }, B, {}));
add('calc_cycle', { starts: ['2026-05-01', '2026-05-29', '2026-06-26'], today: '2026-07-05' }, calcCycle(['2026-05-01', '2026-05-29', '2026-06-26'], '2026-07-05'));
add('detect_sleep_cycles', { minutes: byMinuteRr.concat(Array.from({ length: 80 }, (_, m) => ({ ts: (40 + m) * 60, rr: rr.slice((m % 40) * 8, (m % 40) * 8 + 8) }))), onset: 0, wake: 120 * 60 }, detectSleepCycles(byMinuteRr.concat(Array.from({ length: 80 }, (_, m) => ({ ts: (40 + m) * 60, rr: rr.slice((m % 40) * 8, (m % 40) * 8 + 8) }))), 0, 120 * 60));
add('calc_sleep', { minutes: day, baseline: B }, calcSleep(day, B));
add('calc_sleep_periods', { minutes: day, baseline: B }, calcSleepPeriods(day, B));
add('extract_har_features', { smv, fs: 30, prev_dom_freq: 0 }, extractHarFeaturesFromSmv(smv, 30, 0));
add('classify_activity', { smv, fs: 30, prev_dom_freq: 0 }, (() => { const f = extractHarFeaturesFromSmv(smv, 30, 0); const c = classifyActivityWindow(f); return { cls: c.cls, confidence: c.confidence }; })());
add('segment_workout', { votes, smooth_win: 7, min_phase_sec: 180 }, segmentWorkout(votes, { smoothWin: 7, minPhaseSec: 180 }));
add('detect_sessions', { minutes: sessMin, baseline: B, profile: PROFILE }, detectSessions(sessMin, B, PROFILE));
add('calc_circadian', { minutes: day, now: 599 * 60 }, calcCircadian(day, { now: 599 * 60 }));
add('stage_sleep', { minutes: sleepMin.map((m, i) => ({ ts: m.ts, hr_avg: m.hr_avg, rr: rr.slice((i % 40) * 8, (i % 40) * 8 + 6) })), onset: 0, wake: 360 * 60, mesor: 70 }, stageSleep(sleepMin.map((m, i) => ({ ts: m.ts, hr_avg: m.hr_avg, rr: rr.slice((i % 40) * 8, (i % 40) * 8 + 6) })), 0, 360 * 60, 70));
add('detect_wake_state', { minutes: day, baseline: B, rr_by_min: byMinuteRr, now: 599 * 60 }, (() => { const mp = new Map<number, number[]>(); byMinuteRr.forEach((x) => mp.set(Math.floor(x.ts / 60) * 60, x.rr)); return detectWakeState({ minutes: day, baseline: B, rrByMin: mp, now: 599 * 60 }); })());
add('peek_recent_state', { recent: dayMin.slice(0, 8), baseline: B }, { state: peekRecentState(dayMin.slice(0, 8), B) });
add('build_coach', coachIn, buildCoach(coachIn as any));
add('build_notifications', notifyIn, buildNotifications(notifyIn as any));

writeFileSync('core/parity_all_input.json', JSON.stringify(inputs));
writeFileSync('core/parity_all_ts.json', JSON.stringify(outputs));
console.log(`wrote ${Object.keys(inputs).length} metric cases`);
