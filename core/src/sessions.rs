// Port of openstrap-analytics/src/sessions.ts — auto-workout detection + typing.
use crate::calories::calc_calories;
use crate::har::{segment_workout, ClassVote};
use crate::recovery::calc_hr_recovery;
use crate::strain::calc_strain;
use crate::types::{Baseline, Minute, Profile, SessionOut, SessionZones};
use crate::util::{is_hr_usable, mean, median, resolve_max_hr, round};
use crate::zones::calc_hr_zones;

struct Seg {
    start_idx: usize,
    end_idx: usize,
}

pub fn detect_sessions(minutes: &[Minute], baseline: &Baseline, profile: Option<&Profile>) -> Vec<SessionOut> {
    let mut sorted: Vec<Minute> = minutes.to_vec();
    sorted.sort_by(|a, b| a.ts.partial_cmp(&b.ts).unwrap());
    let worn: Vec<Minute> = sorted.iter().filter(|m| is_hr_usable(m)).cloned().collect();
    if worn.is_empty() {
        return vec![];
    }

    let (max_hr, _) = resolve_max_hr(&sorted, baseline.max_hr, profile);
    let rhr = baseline.resting_hr;
    let threshold = rhr + 0.4 * (max_hr - rhr);
    let daily_median_act = median(&sorted.iter().map(|m| m.activity).collect::<Vec<_>>()).unwrap_or(0.0);

    let above = |m: &Minute| is_hr_usable(m) && m.hr_avg >= threshold;

    // 1. candidate raw segments (tolerate <3 consecutive below-threshold dips).
    let mut segs: Vec<Seg> = Vec::new();
    let mut i = 0;
    while i < worn.len() {
        if !above(&worn[i]) {
            i += 1;
            continue;
        }
        let mut j = i;
        let mut below_run = 0;
        let mut last_above = i;
        while j < worn.len() {
            if above(&worn[j]) {
                below_run = 0;
                last_above = j;
            } else {
                below_run += 1;
                if below_run >= 3 {
                    break;
                }
            }
            j += 1;
        }
        segs.push(Seg { start_idx: i, end_idx: last_above });
        i = last_above + 1;
    }

    // 2. qualify: ≥2 min sustained AND mean activity > daily median.
    let qualified: Vec<Seg> = segs
        .into_iter()
        .filter(|s| {
            let slice = &worn[s.start_idx..=s.end_idx];
            if slice.len() < 2 {
                return false;
            }
            mean(&slice.iter().map(|m| m.activity).collect::<Vec<_>>()) > daily_median_act
        })
        .collect();

    // 3. merge sessions <5 min apart.
    let mut merged: Vec<Seg> = Vec::new();
    for s in qualified {
        if merged.is_empty() {
            merged.push(s);
            continue;
        }
        let prev = merged.last_mut().unwrap();
        let gap_min = (worn[s.start_idx].ts - worn[prev.end_idx].ts) / 60.0;
        if gap_min < 5.0 {
            prev.end_idx = s.end_idx;
        } else {
            merged.push(s);
        }
    }

    // 4. discard <2 min; build outputs.
    let mut out: Vec<SessionOut> = Vec::new();
    let default_profile = Profile::default();
    let prof = profile.unwrap_or(&default_profile);
    for s in &merged {
        let slice: Vec<Minute> = worn[s.start_idx..=s.end_idx].to_vec();
        let duration_min = (slice[slice.len() - 1].ts - slice[0].ts) / 60.0 + 1.0;
        if duration_min < 2.0 {
            continue;
        }
        let hrs: Vec<f64> = slice.iter().map(|m| m.hr_avg).collect();
        let avg_hr = mean(&hrs);
        let max_hr_seen = slice.iter().map(|m| m.hr_max).fold(f64::NEG_INFINITY, f64::max);
        let acts: Vec<f64> = slice.iter().map(|m| m.activity).collect();
        let mean_act = mean(&acts);
        let peak_act = acts.iter().cloned().fold(f64::NEG_INFINITY, f64::max);

        let strain = calc_strain(&slice, baseline, profile);
        let cals = calc_calories(&slice, prof, Some(baseline.resting_hr), Some(max_hr));
        let zones = calc_hr_zones(&slice, baseline, profile);
        let hrr = calc_hr_recovery(&slice, baseline, profile);

        let votes: Vec<ClassVote> = slice
            .iter()
            .filter_map(|m| m.act_class.as_ref().map(|c| ClassVote { ts: m.ts, cls: c.clone(), conf: 1.0 }))
            .collect();
        let ty: String;
        let type_conf: f64;
        let segments: Option<Vec<crate::har::WorkoutSegment>>;
        if votes.len() >= 2 {
            let seg = segment_workout(&votes, 7, 120.0);
            ty = seg.primary;
            type_conf = 0.75f64.min(0.4f64.max(seg.type_confidence));
            segments = if seg.segments.len() > 1 { Some(seg.segments) } else { None };
        } else {
            ty = classify_type(mean_act, daily_median_act, avg_hr, rhr, max_hr);
            type_conf = 0.4;
            segments = None;
        }

        out.push(SessionOut {
            start_ts: slice[0].ts,
            end_ts: slice[slice.len() - 1].ts,
            duration_min: round(duration_min, 0),
            avg_hr: round(avg_hr, 1),
            max_hr: round(max_hr_seen, 1),
            strain: strain.score,
            trimp: strain.trimp,
            kcal: cals.kcal,
            zones: SessionZones {
                zone1_min: zones.zone1_min,
                zone2_min: zones.zone2_min,
                zone3_min: zones.zone3_min,
                zone4_min: zones.zone4_min,
                zone5_min: zones.zone5_min,
                max_hr_used: zones.max_hr_used,
                max_hr_source: zones.max_hr_source,
            },
            hrr60: hrr.hrr60,
            mean_activity: round(mean_act, 4),
            peak_activity: round(peak_act, 4),
            ty: ty.clone(),
            type_confidence: round(type_conf, 2),
            segments,
            detected_type: ty,
            confidence: 0.8,
            tier: "HIGH".to_string(),
            inputs_used: vec!["hr_avg".to_string(), "hr_max".to_string(), "activity".to_string(), "baseline.resting_hr".to_string()],
        });
    }
    out
}

fn classify_type(mean_act: f64, daily_median_act: f64, avg_hr: f64, rhr: f64, max_hr: f64) -> String {
    let reserve = max_hr - rhr;
    let hr_reserve_pct = if reserve > 0.0 { (avg_hr - rhr) / reserve } else { 0.0 };
    let high_activity = mean_act > daily_median_act * 2.0;
    if high_activity && hr_reserve_pct >= 0.6 {
        "run/cardio".to_string()
    } else if !high_activity && hr_reserve_pct >= 0.6 {
        "strength/other".to_string()
    } else {
        "walk".to_string()
    }
}
