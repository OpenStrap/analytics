// §7 Auto-workout detection. Tier HIGH (event) / ESTIMATE (type).
import type { Minute, Baseline, Profile, Metric, SessionValue, ActivityClass } from './types';
import { isHrUsable, resolveMaxHr, median, mean, round } from './util';
import { calcStrain } from './strain';
import { calcCalories } from './calories';
import { calcHrZones } from './zones';
import { calcHrRecovery } from './recovery';
import { segmentWorkout } from './har';
import type { ClassVote } from './har';

/**
 * detectSessions(minutes, baseline, profile?)
 *
 * A session starts when hr_avg ≥ RHR + 0.4*(maxHR−RHR) (≈40% HR reserve)
 * sustained ≥3 min AND mean activity over those minutes > daily median activity.
 * It ends when HR drops below the threshold for ≥3 consecutive minutes.
 * Merge sessions <5 min apart; discard sessions <5 min total.
 * Per session: start/end ts, duration, avg/max HR, strain, calories, zones,
 *   HRR60, mean+peak activity, type (ESTIMATE).
 *
 * Each session is a Metric: event confidence 0.8 (HIGH), type_confidence 0.4.
 * Confidence formula: event detection pinned 0.8 (published threshold method on
 *   authoritative HR); type heuristic pinned 0.4 (crude buckets).
 */
export function detectSessions(
  minutes: Minute[],
  baseline: Baseline,
  profile?: Profile
): Metric<SessionValue>[] {
  const sorted = [...minutes].sort((a, b) => a.ts - b.ts);
  const worn = sorted.filter(isHrUsable);
  if (worn.length === 0) return [];

  const { maxHr } = resolveMaxHr(sorted, baseline, profile);
  const rhr = baseline.resting_hr;
  const threshold = rhr + 0.4 * (maxHr - rhr);
  const dailyMedianAct = median(sorted.map((m) => m.activity)) ?? 0;

  const above = (m: Minute) => isHrUsable(m) && m.hr_avg >= threshold;

  // 1. Find candidate raw segments: contiguous runs above threshold, allowing
  //    short (<3 consecutive) below-threshold dips inside.
  type Seg = { startIdx: number; endIdx: number };
  const segs: Seg[] = [];
  let i = 0;
  while (i < worn.length) {
    if (!above(worn[i])) {
      i++;
      continue;
    }
    // start a candidate
    let j = i;
    let belowRun = 0;
    let lastAboveIdx = i;
    while (j < worn.length) {
      if (above(worn[j])) {
        belowRun = 0;
        lastAboveIdx = j;
      } else {
        belowRun++;
        if (belowRun >= 3) break; // sustained drop ends the session
      }
      j++;
    }
    segs.push({ startIdx: i, endIdx: lastAboveIdx });
    i = lastAboveIdx + 1;
  }

  // 2. Require ≥2 min sustained start AND mean activity > daily median.
  const qualified = segs.filter((s) => {
    const slice = worn.slice(s.startIdx, s.endIdx + 1);
    if (slice.length < 2) return false;
    const meanAct = mean(slice.map((m) => m.activity));
    return meanAct > dailyMedianAct;
  });

  // 3. Merge sessions <5 min apart (by ts gap between consecutive segments).
  const merged: Seg[] = [];
  for (const s of qualified) {
    if (merged.length === 0) {
      merged.push({ ...s });
      continue;
    }
    const prev = merged[merged.length - 1];
    const gapMin = (worn[s.startIdx].ts - worn[prev.endIdx].ts) / 60;
    if (gapMin < 5) {
      prev.endIdx = s.endIdx;
    } else {
      merged.push({ ...s });
    }
  }

  // 4. Discard sessions <2 min total; build outputs.
  const out: Metric<SessionValue>[] = [];
  for (const s of merged) {
    const slice = worn.slice(s.startIdx, s.endIdx + 1);
    const durationMin = (slice[slice.length - 1].ts - slice[0].ts) / 60 + 1;
    if (durationMin < 2) continue;

    const hrs = slice.map((m) => m.hr_avg);
    const avgHr = mean(hrs);
    const maxHrSeen = Math.max(...slice.map((m) => m.hr_max));
    const acts = slice.map((m) => m.activity);
    const meanAct = mean(acts);
    const peakAct = Math.max(...acts);

    const strain = calcStrain(slice, baseline, profile);
    const cals = calcCalories(slice, profile ?? {}, baseline.resting_hr, maxHr);
    const zones = calcHrZones(slice, baseline, profile);
    const hrr = calcHrRecovery(slice, baseline, profile);

    // Type: prefer the motion-based HAR classes carried per-minute from ingest (live
    // high-rate stream → Mannini classifier). Run segmentWorkout over the bout's
    // per-minute act_class to get the primary type + graceful phase breakdown. If the
    // bout has no classified minutes (flash-drained, 1 Hz, no motion texture), fall
    // back to the crude HR/activity heuristic — honestly low-confidence.
    const votes: ClassVote[] = slice
      .filter((m) => m.act_class)
      .map((m) => ({ ts: m.ts, cls: m.act_class as ActivityClass, conf: 1 }));
    let type: string;
    let typeConf: number;
    let segments: SessionValue['segments'];
    if (votes.length >= 2) {
      const seg = segmentWorkout(votes, { minPhaseSec: 120 });
      type = seg.primary;
      // Cap at 0.75: motion-classified is far better than the HR heuristic but still
      // ESTIMATE (threshold classifier, no trained model yet).
      typeConf = Math.min(0.75, Math.max(0.4, seg.type_confidence));
      segments = seg.segments.length > 1 ? seg.segments : undefined;
    } else {
      type = classifyType(meanAct, dailyMedianAct, avgHr, rhr, maxHr);
      typeConf = 0.4;
    }

    out.push({
      start_ts: slice[0].ts,
      end_ts: slice[slice.length - 1].ts,
      duration_min: round(durationMin, 0),
      avg_hr: round(avgHr, 1),
      max_hr: round(maxHrSeen, 1),
      strain: strain.score,
      trimp: strain.trimp,
      kcal: cals.kcal,
      zones: {
        zone1_min: zones.zone1_min,
        zone2_min: zones.zone2_min,
        zone3_min: zones.zone3_min,
        zone4_min: zones.zone4_min,
        zone5_min: zones.zone5_min,
        max_hr_used: zones.max_hr_used,
        max_hr_source: zones.max_hr_source,
      },
      hrr60: hrr.hrr60,
      mean_activity: round(meanAct, 4),
      peak_activity: round(peakAct, 4),
      type,
      type_confidence: round(typeConf, 2),
      segments,
      detected_type: type,
      confidence: 0.8, // event detection, HIGH
      tier: 'HIGH',
      inputs_used: ['hr_avg', 'hr_max', 'activity', 'baseline.resting_hr'],
    });
  }

  return out;
}

/** Crude ESTIMATE type buckets from activity + HR reserve. */
function classifyType(
  meanAct: number,
  dailyMedianAct: number,
  avgHr: number,
  rhr: number,
  maxHr: number
): SessionValue['type'] {
  const reserve = maxHr - rhr;
  const hrReservePct = reserve > 0 ? (avgHr - rhr) / reserve : 0;
  const highActivity = meanAct > dailyMedianAct * 2;
  if (highActivity && hrReservePct >= 0.6) return 'run/cardio';
  if (!highActivity && hrReservePct >= 0.6) return 'strength/other';
  return 'walk'; // low activity / HR < 60% reserve
}
