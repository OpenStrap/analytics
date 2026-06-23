// Port of openstrap-analytics/src/coach.ts — deterministic coaching engine (NO AI).
use crate::util::{clamp, round};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Deserialize)]
pub struct ReadinessComponentsIn {
    pub rhr: f64,
    pub sleep_debt: f64,
    pub sleep_quality: f64,
}

#[derive(Debug, Clone, Deserialize)]
pub struct AnomalyIn {
    pub signal: bool,
    #[serde(default)]
    pub kind: Option<String>,
    #[serde(default)]
    pub note: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct CoachInputs {
    #[serde(default)]
    pub readiness: Option<f64>,
    #[serde(default)]
    pub readiness_components: Option<ReadinessComponentsIn>,
    #[serde(default)]
    pub resting_hr: Option<f64>,
    #[serde(default)]
    pub baseline_rhr: Option<f64>,
    #[serde(default)]
    pub rhr_recent: Vec<f64>,
    #[serde(default)]
    pub strain_today: Option<f64>,
    #[serde(default)]
    pub acwr: Option<f64>,
    #[serde(default)]
    pub sleep_last_min: Option<f64>,
    #[serde(default)]
    pub sleep_need_min: f64,
    #[serde(default)]
    pub sleep_debt_min: f64,
    #[serde(default)]
    pub sleep_efficiency: Option<f64>,
    #[serde(default)]
    pub sri: Option<f64>,
    #[serde(default)]
    pub fitness_direction: Option<String>,
    #[serde(default)]
    pub anomaly: Option<AnomalyIn>,
}

#[derive(Debug, Serialize)]
pub struct Why {
    pub label: String,
    pub value: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct Suggestion {
    pub id: String,
    pub category: String,
    pub title: String,
    pub body: String,
    pub severity: i64,
    pub why: Vec<Why>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub target: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct Contributor {
    pub key: String,
    pub label: String,
    pub value: Option<f64>,
    pub baseline: Option<f64>,
    pub impact: f64,
    pub note: String,
}

#[derive(Debug, Serialize)]
pub struct StrainTarget {
    pub value: f64,
    pub low: f64,
    pub high: f64,
    pub rationale: String,
}

#[derive(Debug, Serialize)]
pub struct CoachOutput {
    pub strain_target: Option<StrainTarget>,
    pub plan: Vec<Suggestion>,
    pub readiness_contributors: Vec<Contributor>,
    pub summary: String,
}

fn mean(xs: &[f64]) -> f64 {
    xs.iter().sum::<f64>() / xs.len() as f64
}
fn std(xs: &[f64]) -> f64 {
    if xs.len() < 2 {
        return 0.0;
    }
    let m = mean(xs);
    (xs.iter().map(|v| (v - m).powi(2)).sum::<f64>() / xs.len() as f64).sqrt()
}
/// JS toFixed-style fixed-decimal string.
fn tf(x: f64, n: usize) -> String {
    format!("{:.*}", n, x)
}
fn hm(min: f64) -> String {
    format!("{}h {}m", (min / 60.0).floor(), (min % 60.0).round())
}

fn strain_target(i: &CoachInputs) -> Option<StrainTarget> {
    let readiness = i.readiness?;
    let mut base = 6.0 + (clamp(readiness, 0.0, 100.0) / 100.0) * 12.0;
    let mut reasons = vec![format!("recovery {}", readiness.round())];
    if let Some(acwr) = i.acwr {
        if acwr > 1.3 {
            base = base.min(10.0);
            reasons.push(format!("load high (ACWR {})", tf(acwr, 2)));
        }
    }
    if i.anomaly.as_ref().map(|a| a.signal).unwrap_or(false) {
        base = base.min(8.0);
        reasons.push("body-strain signal".to_string());
    }
    let v = round(base, 1);
    Some(StrainTarget {
        value: v,
        low: round(0f64.max(v - 2.0), 1),
        high: round(21f64.min(v + 2.0), 1),
        rationale: reasons.join(" · "),
    })
}

fn contributors(i: &CoachInputs) -> Vec<Contributor> {
    let c = match &i.readiness_components {
        Some(c) => c,
        None => return vec![],
    };
    let (w_rhr, w_sd, w_sq) = (0.5, 0.3, 0.2);
    let w_sum = w_rhr + w_sd + w_sq;
    let pts = |w: f64, comp: f64| round(-((w / w_sum) * 100.0 * (1.0 - comp)), 1);
    let note = |comp: f64, good: &str, bad: &str| if comp >= 0.85 { good.to_string() } else { bad.to_string() };
    vec![
        Contributor {
            key: "rhr".to_string(),
            label: "Resting HR".to_string(),
            value: i.resting_hr,
            baseline: i.baseline_rhr,
            impact: pts(w_rhr, c.rhr),
            note: note(c.rhr, "at/below baseline — supporting recovery", "elevated vs baseline — dragging recovery down"),
        },
        Contributor {
            key: "sleep_debt".to_string(),
            label: "Sleep duration".to_string(),
            value: i.sleep_last_min,
            baseline: Some(i.sleep_need_min),
            impact: pts(w_sd, c.sleep_debt),
            note: note(c.sleep_debt, "met your sleep need", "short vs your need — costing recovery"),
        },
        Contributor {
            key: "sleep_quality".to_string(),
            label: "Sleep quality".to_string(),
            value: i.sleep_efficiency.map(|e| round(e * 100.0, 0)),
            baseline: None,
            impact: pts(w_sq, c.sleep_quality),
            note: note(c.sleep_quality, "efficient + consistent", "fragmented or irregular"),
        },
    ]
}

fn rules(i: &CoachInputs) -> Vec<Suggestion> {
    let mut out: Vec<Suggestion> = Vec::new();
    let tgt = strain_target(i);
    let recovery = i.readiness;
    let acwr_high = matches!(i.acwr, Some(a) if a > 1.3);
    let acwr_low = matches!(i.acwr, Some(a) if a < 0.8);
    let anomaly_signal = i.anomaly.as_ref().map(|a| a.signal).unwrap_or(false);

    let mut rhr_z: Option<f64> = None;
    if i.rhr_recent.len() >= 3 {
        if let Some(rh) = i.resting_hr {
            let prior = &i.rhr_recent[..i.rhr_recent.len() - 1];
            let s = std(prior);
            if s > 0.0 {
                rhr_z = Some((rh - mean(prior)) / s);
            }
        }
    }

    // HEALTH
    if let Some(an) = &i.anomaly {
        if an.signal {
            let mut why = vec![];
            if let (Some(rh), Some(brh)) = (i.resting_hr, i.baseline_rhr) {
                why.push(Why { label: "Resting HR".to_string(), value: format!("{} bpm", rh.round()), detail: Some(format!("baseline {}", brh.round())) });
            }
            if let Some(acwr) = i.acwr {
                why.push(Why { label: "Load (ACWR)".to_string(), value: tf(acwr, 2), detail: None });
            }
            out.push(Suggestion {
                id: "health.anomaly".to_string(),
                category: "health".to_string(),
                title: if an.kind.as_deref() == Some("overtraining") { "Back off — high load".to_string() } else { "Recovery flag".to_string() },
                body: an.note.clone().unwrap_or_else(|| "Your body is showing strain signals. Prioritise rest, hydration and easy movement today. A signal, not a diagnosis.".to_string()),
                severity: 3,
                why,
                target: tgt.as_ref().map(|t| format!("Keep strain ≤ {}", t.high)),
            });
        }
    }

    // LOAD
    if acwr_high && !anomaly_signal {
        out.push(Suggestion {
            id: "load.high".to_string(),
            category: "load".to_string(),
            title: "Ease off the gas".to_string(),
            body: "Your acute training load is well above your 28-day baseline. Stack an easy or rest day to let it settle before pushing again.".to_string(),
            severity: 2,
            why: vec![Why { label: "Load (ACWR)".to_string(), value: tf(i.acwr.unwrap(), 2), detail: Some("optimal 0.8–1.3".to_string()) }],
            target: tgt.as_ref().map(|t| format!("Target strain {}–{}", t.low, t.value)),
        });
    }
    if acwr_low && (recovery.is_none() || recovery.unwrap() >= 55.0) {
        out.push(Suggestion {
            id: "load.low".to_string(),
            category: "activity".to_string(),
            title: "Room to push".to_string(),
            body: "You're fresh and your recent load is light. A solid session today moves your fitness forward without overreaching.".to_string(),
            severity: 1,
            why: vec![Why { label: "Load (ACWR)".to_string(), value: tf(i.acwr.unwrap(), 2), detail: Some("< 0.8 = detraining zone".to_string()) }],
            target: tgt.as_ref().map(|t| format!("Aim for strain {}–{}", t.value, t.high)),
        });
    }

    // RECOVERY
    if let Some(r) = recovery {
        if r < 40.0 && !anomaly_signal {
            out.push(Suggestion {
                id: "recovery.low".to_string(),
                category: "recovery".to_string(),
                title: "Take it easy today".to_string(),
                body: "Recovery is low. Favour light movement, mobility or a walk over hard training, and protect tonight's sleep.".to_string(),
                severity: 2,
                why: vec![Why { label: "Recovery".to_string(), value: format!("{}", r.round()), detail: Some("(est.) — not HRV-based".to_string()) }],
                target: tgt.as_ref().map(|t| format!("Keep strain ≤ {}", t.value)),
            });
        }
        if r >= 70.0 && !acwr_high && !anomaly_signal {
            out.push(Suggestion {
                id: "recovery.high".to_string(),
                category: "activity".to_string(),
                title: "Green light".to_string(),
                body: "Recovery is strong — your body's ready for a harder effort if you want it.".to_string(),
                severity: 0,
                why: vec![Why { label: "Recovery".to_string(), value: format!("{}", r.round()), detail: None }],
                target: tgt.as_ref().map(|t| format!("You can target strain up to {}", t.high)),
            });
        }
    }
    if let Some(z) = rhr_z {
        if z > 1.5 && !anomaly_signal {
            out.push(Suggestion {
                id: "recovery.rhr_spike".to_string(),
                category: "recovery".to_string(),
                title: "Resting HR is up".to_string(),
                body: "Your resting HR is notably above your recent norm — often a sign of incomplete recovery, stress, alcohol or oncoming illness. Keep today gentle.".to_string(),
                severity: 2,
                why: vec![Why { label: "Resting HR".to_string(), value: format!("{} bpm", i.resting_hr.unwrap().round()), detail: Some(format!("+{}σ vs recent", tf(z, 1))) }],
                target: None,
            });
        }
    }

    // SLEEP
    if i.sleep_debt_min >= 90.0 {
        let earlier = 90f64.min((i.sleep_debt_min / 3.0 / 5.0).round() * 5.0);
        out.push(Suggestion {
            id: "sleep.debt".to_string(),
            category: "sleep".to_string(),
            title: "Pay down sleep debt".to_string(),
            body: format!("You're carrying about {} of sleep debt. Going to bed ~{} min earlier tonight will start closing the gap.", hm(i.sleep_debt_min), earlier),
            severity: 2,
            why: vec![Why { label: "Sleep debt".to_string(), value: hm(i.sleep_debt_min), detail: Some(format!("need {}/night", hm(i.sleep_need_min))) }],
            target: None,
        });
    }
    if let Some(sri) = i.sri {
        if sri < 70.0 {
            out.push(Suggestion {
                id: "sleep.consistency".to_string(),
                category: "sleep".to_string(),
                title: "Anchor your sleep timing".to_string(),
                body: "Your sleep schedule is inconsistent. Going to bed and waking within the same ~30-min window — even on weekends — is one of the biggest levers on recovery.".to_string(),
                severity: 1,
                why: vec![Why { label: "Sleep regularity".to_string(), value: format!("{}/100", sri.round()), detail: Some("higher = steadier".to_string()) }],
                target: None,
            });
        }
    }
    if let (Some(slm), Some(eff)) = (i.sleep_last_min, i.sleep_efficiency) {
        if eff < 0.8 && slm > 120.0 {
            out.push(Suggestion {
                id: "sleep.efficiency".to_string(),
                category: "sleep".to_string(),
                title: "Restless night".to_string(),
                body: "You spent a good chunk of last night awake in bed. A cooler, darker room and no screens before bed usually lift efficiency.".to_string(),
                severity: 1,
                why: vec![Why { label: "Sleep efficiency".to_string(), value: format!("{}%", (eff * 100.0).round()), detail: Some("target ≥ 85%".to_string()) }],
                target: None,
            });
        }
    }
    out
}

fn narrative(i: &CoachInputs) -> String {
    let mut parts: Vec<String> = Vec::new();
    if let Some(r) = i.readiness {
        let w = if r >= 70.0 { "Strong" } else if r >= 40.0 { "Moderate" } else { "Low" };
        parts.push(format!("{} recovery", w));
    }
    if let Some(slm) = i.sleep_last_min {
        if slm > 0.0 {
            parts.push(format!("slept {}", hm(slm)));
        }
    }
    if let Some(acwr) = i.acwr {
        let w = if acwr > 1.3 { "high load" } else if acwr < 0.8 { "light load" } else { "balanced load" };
        parts.push(w.to_string());
    }
    if parts.is_empty() {
        "Wear your strap and sync to see your daily read.".to_string()
    } else {
        parts.join(" · ")
    }
}

pub fn build_coach(i: &CoachInputs) -> CoachOutput {
    let mut plan = rules(i);
    plan.sort_by(|a, b| b.severity.cmp(&a.severity)); // stable, matches JS sort by severity desc
    plan.truncate(5);
    CoachOutput {
        strain_target: strain_target(i),
        plan,
        readiness_contributors: contributors(i),
        summary: narrative(i),
    }
}
