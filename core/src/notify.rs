// Port of openstrap-analytics/src/notify.ts — deterministic notification engine (NO AI).
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Deserialize)]
pub struct CoachTopIn {
    pub title: String,
    pub body: String,
}
#[derive(Debug, Clone, Deserialize)]
pub struct BodyAlertIn {
    pub kind: String,
    pub note: String,
}
#[derive(Debug, Clone, Default, Deserialize)]
pub struct StreaksIn {
    #[serde(default)]
    pub wear: Option<i64>,
    #[serde(default)]
    pub strain_target: Option<i64>,
    #[serde(default)]
    pub sleep: Option<i64>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct NotifyInputs {
    pub date: String,
    #[serde(default)]
    pub readiness: Option<f64>,
    #[serde(default)]
    pub coach_summary: String,
    #[serde(default)]
    pub coach_top: Option<CoachTopIn>,
    #[serde(default)]
    pub body_alert: Option<BodyAlertIn>,
    #[serde(default)]
    pub stress_score: Option<f64>,
    #[serde(default)]
    pub nocturnal_elevated: bool,
    #[serde(default)]
    pub sleep_debt_min: f64,
    #[serde(default)]
    pub acwr: Option<f64>,
    #[serde(default)]
    pub strain_today: Option<f64>,
    #[serde(default)]
    pub strain_target_low: Option<f64>,
    #[serde(default)]
    pub strain_target_high: Option<f64>,
    #[serde(default)]
    pub streaks: Option<StreaksIn>,
    #[serde(default)]
    pub new_records: Vec<String>,
}

#[derive(Debug, Serialize)]
pub struct AppNotification {
    pub id: String,
    pub kind: String,
    pub category: String,
    pub priority: i64,
    pub title: String,
    pub body: String,
    pub window: String,
    pub quiet_ok: bool,
}

const MILESTONES: [i64; 11] = [3, 7, 14, 21, 30, 50, 75, 100, 150, 200, 365];
const MAX_NOTIFICATIONS: usize = 6;

fn hm(min: f64) -> String {
    let m = 0f64.max(min.round()) as i64;
    let h = m / 60;
    let r = m % 60;
    if h == 0 {
        format!("{}m", r)
    } else if r == 0 {
        format!("{}h", h)
    } else {
        format!("{}h {}m", h, r)
    }
}
fn tf(x: f64, n: usize) -> String {
    format!("{:.*}", n, x)
}
/// lowercase, replace each maximal run of non-[a-z0-9] with a single '_'.
fn record_kind(label: &str) -> String {
    let lower = label.to_lowercase();
    let mut out = String::from("record_");
    let mut prev_us = false;
    for ch in lower.chars() {
        if ch.is_ascii_alphanumeric() {
            out.push(ch);
            prev_us = false;
        } else if !prev_us {
            out.push('_');
            prev_us = true;
        }
    }
    out
}

pub fn build_notifications(i: &NotifyInputs) -> Vec<AppNotification> {
    let mut out: Vec<AppNotification> = Vec::new();
    let mut push = |kind: String, category: &str, priority: i64, window: &str, quiet_ok: bool, title: String, body: String| {
        out.push(AppNotification {
            id: format!("{}:{}", i.date, kind),
            kind,
            category: category.to_string(),
            priority,
            title,
            body,
            window: window.to_string(),
            quiet_ok,
        });
    };

    // 1. Health signal.
    if let Some(ba) = &i.body_alert {
        let title = match ba.kind.as_str() {
            "overtraining" => "High training load",
            "both" => "Recovery + load signal",
            _ => "Recovery signal",
        };
        push("body_alert".to_string(), "health", 3, "morning", false, title.to_string(), ba.note.clone());
    } else if i.nocturnal_elevated {
        push(
            "overnight_hr".to_string(), "health", 3, "morning", false,
            "Overnight heart rate was high".to_string(),
            "Your sleeping heart rate ran above your baseline — often an early cue of under-recovery or fighting something off. Consider an easier day. A signal, not a diagnosis.".to_string(),
        );
    }

    // 2. New personal records.
    for label in &i.new_records {
        push(record_kind(label), "milestone", 2, "any", false, "New personal record 🎉".to_string(), format!("{} — a new best. Nice work.", label));
    }

    // 3. Morning readiness.
    if let Some(r) = i.readiness {
        let rr = r.round() as i64;
        let tip = match &i.coach_top {
            Some(ct) => format!("{}: {}", ct.title, ct.body),
            None => {
                if i.coach_summary.is_empty() {
                    "Carry on with your day.".to_string()
                } else {
                    i.coach_summary.clone()
                }
            }
        };
        push("morning_readiness".to_string(), "recovery", 1, "morning", false, format!("Recovery {}/100", rr), tip);
    }

    // 4. Sleep debt nudge.
    if i.sleep_debt_min >= 120.0 {
        push(
            "sleep_debt".to_string(), "sleep", 2, "evening", false,
            format!("You're carrying {} of sleep debt", hm(i.sleep_debt_min)),
            "An earlier night would help you pay it down. Aim to wind down soon.".to_string(),
        );
    }

    // 5. High-arousal day.
    if let Some(ss) = i.stress_score {
        if ss >= 70.0 {
            push(
                "high_stress".to_string(), "health", 1, "evening", false,
                "A high-arousal day".to_string(),
                format!("Stress read {}/100 — some downtime or slow breathing tonight could help you settle.", ss.round() as i64),
            );
        }
    }

    // 6. Strain target progress.
    if let (Some(low), Some(today)) = (i.strain_target_low, i.strain_today) {
        if today < low - 1.0 {
            let high = i.strain_target_high.unwrap_or(low);
            push(
                "strain_room".to_string(), "activity", 0, "midday", false,
                "Room to move today".to_string(),
                format!("You're at {} — your target is around {}–{}.", tf(today, 1), tf(low, 0), tf(high, 0)),
            );
        }
    }

    // 7. Streak milestones.
    let s = i.streaks.clone().unwrap_or_default();
    if let Some(wear) = s.wear {
        if MILESTONES.contains(&wear) {
            push("streak_wear".to_string(), "milestone", 1, "any", false, format!("{}-day wear streak 🔥", wear), format!("You've worn your strap {} days running. Consistency is the whole game.", wear));
        }
    }
    if let Some(st) = s.strain_target {
        if MILESTONES.contains(&st) {
            push("streak_strain".to_string(), "milestone", 1, "any", false, format!("{} days on target 🔥", st), format!("You've hit your strain target {} days in a row.", st));
        }
    }

    // Rank: priority desc, stable (insertion order tiebreak).
    out.sort_by(|a, b| b.priority.cmp(&a.priority));
    out.truncate(MAX_NOTIFICATIONS);
    out
}
