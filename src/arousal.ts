// §Sleep stress / nocturnal arousal — "what your body did while you slept".
// Detects sympathetic ACTIVATION during sleep: heart-rate surges co-occurring
// with movement (the autonomic signature of arousals / restless / nightmare-like
// events), plus overall restlessness (motion during the sleep window). Built from
// minute HR + actigraphy over the main sleep period — no new hardware.
//
// HONESTY: we label spikes as "possible arousal events", NEVER "nightmares" — we
// can't know dream content. Tier ESTIMATE.
import type { Minute, Baseline, Metric, SleepStressValue, Driver } from './types';
import { isHrUsable, mean, stddev, round } from './util';

/**
 * calcSleepStress(sleepMinutes, baseline)
 * sleepMinutes: worn minutes within the main sleep period (onset..wake).
 * An "arousal event" = a minute whose HR jumps ≥ max(8 bpm, mean+1.5·sd of sleeping
 * HR) AND carries movement (activity above the night's sleep-mean). Consecutive
 * surge minutes collapse into one event. "restless" minutes = movement above the
 * sleeping-activity mean. Score scales with event density + restless fraction.
 */
export function calcSleepStress(sleepMinutes: Minute[], _baseline: Baseline): Metric<SleepStressValue> {
  const worn = sleepMinutes.filter(isHrUsable).sort((a, b) => a.ts - b.ts);
  const empty = (): Metric<SleepStressValue> => ({
    score: null, arousal_events: 0, restless_min: 0, mean_sleeping_hr: null, events: [],
    confidence: 0, tier: 'ESTIMATE', inputs_used: [],
  });
  if (worn.length < 20) return empty();

  const hrs = worn.map((m) => m.hr_avg);
  const meanHr = mean(hrs);
  const sdHr = stddev(hrs);
  const acts = worn.map((m) => m.activity);
  const meanAct = mean(acts);
  const surgeThresh = meanHr + Math.max(8, 1.5 * sdHr);

  let arousalEvents = 0;
  let restless = 0;
  const events: { ts: number; kind: 'arousal' | 'restless' }[] = [];
  let inSurge = false;
  for (const m of worn) {
    const moving = m.activity > meanAct && m.activity > 0;
    if (moving) restless++;
    const surge = m.hr_avg >= surgeThresh && moving;
    if (surge && !inSurge) {
      arousalEvents++;
      events.push({ ts: m.ts, kind: 'arousal' });
      inSurge = true;
    } else if (!surge) {
      inSurge = false;
      // record a few representative restless markers (not every minute) for overlay
      if (moving && m.activity > meanAct * 2 && events.length < 60) events.push({ ts: m.ts, kind: 'restless' });
    }
  }

  // Score: arousal density (events per hour) + restless fraction, mapped 0..100.
  const hours = Math.max(0.5, worn.length / 60);
  const eventsPerHour = arousalEvents / hours;
  const restlessFrac = restless / worn.length;
  const score = Math.max(0, Math.min(100, Math.round(eventsPerHour * 12 + restlessFrac * 100 * 0.5)));

  const drivers: Driver[] = [
    { label: 'Arousal events', contribution: arousalEvents, detail: `${arousalEvents} HR-surge+motion events`, ref: { metric: 'hr', scale: 'day' } },
    { label: 'Restlessness', contribution: round(restlessFrac * 100, 1), detail: `${restless} restless min`, ref: { metric: 'activity', scale: 'day' } },
  ];

  const confidence = Math.min(1, worn.length / 240);
  return {
    score, arousal_events: arousalEvents, restless_min: restless,
    mean_sleeping_hr: round(meanHr, 0), events,
    confidence: round(confidence, 4), tier: 'ESTIMATE',
    inputs_used: ['hr_avg', 'activity'], drivers,
  };
}
