//! Incidents: PagerDuty and Opsgenie mail. Shows whether an incident is
//! triggered, acknowledged or resolved, its urgency and service, and links to
//! it. Acknowledging needs the provider's API, so that waits for sign-in.
use crate::card::{Action, Card, Component, Effect, ToolResult};
use crate::detect::{find_link, host_is, sender_domain, value_after};
use crate::plugin::{Context, Manifest, MessageAction, Permission, Plugin, ToolError};
use serde_json::Value;

pub struct Incidents;

#[derive(Clone, Copy, Debug, PartialEq)]
enum Provider {
    PagerDuty,
    Opsgenie,
}

#[derive(Clone, Copy, Debug, PartialEq)]
enum State {
    Triggered,
    Acknowledged,
    Resolved,
}

#[derive(Debug, PartialEq)]
struct Incident {
    provider: Provider,
    state: State,
    title: Option<String>,
    number: Option<String>,
    urgency: Option<String>,
    service: Option<String>,
    url: Option<String>,
}

fn provider(context: &Context) -> Option<Provider> {
    let domain = sender_domain(context.message);
    if host_is(&domain, "pagerduty.com") {
        Some(Provider::PagerDuty)
    } else if host_is(&domain, "opsgenie.net") || host_is(&domain, "opsgenie.com") {
        Some(Provider::Opsgenie)
    } else {
        None
    }
}

fn line_value(text: &str, cue: &str) -> Option<String> {
    value_after(text, cue).filter(|v| v.len() <= 80)
}

fn incident(context: &Context) -> Option<Incident> {
    let provider = provider(context)?;
    let subject = context.text.subject.trim();
    let subject_lower = subject.to_lowercase();
    let lower = &context.text.lower;
    // The subject carries the current state; the body may mention all three.
    let state_in = |text: &str| {
        if text.contains("resolved") {
            Some(State::Resolved)
        } else if text.contains("acknowledged") {
            Some(State::Acknowledged)
        } else if text.contains("triggered") || text.contains("alert") || text.contains("incident")
        {
            Some(State::Triggered)
        } else {
            None
        }
    };
    let state = state_in(&subject_lower).or_else(|| state_in(lower))?;
    let url = find_link(context.text, |host, path| match provider {
        Provider::PagerDuty => host_is(host, "pagerduty.com") && path.starts_with("/incidents/"),
        Provider::Opsgenie => host_is(host, "opsgenie.com") && path.contains("alert"),
    });
    // "[#1234] Disk full on db-1" / "[PagerDuty ALERT] You have 1 TRIGGERED Incident (Q1W2)"
    let mut number = None;
    let mut rest = subject;
    while rest.starts_with('[') {
        let Some(end) = rest.find(']') else { break };
        let tag = &rest[1..end];
        if let Some(n) = tag
            .strip_prefix('#')
            .filter(|n| n.chars().all(|c| c.is_ascii_digit()))
        {
            number = Some(format!("#{n}"));
        }
        rest = rest[end + 1..].trim_start();
    }
    let title = if rest.to_lowercase().starts_with("you have") || rest.is_empty() {
        line_value(&context.text.body, "description:")
            .or_else(|| line_value(&context.text.body, "summary:"))
    } else {
        Some(rest.trim_start_matches(['-', ':', ' ']).to_owned())
    }
    .filter(|t| !t.is_empty());
    if number.is_none()
        && let Some(url) = &url
        && provider == Provider::PagerDuty
    {
        number = url
            .split("/incidents/")
            .nth(1)
            .and_then(|id| id.split(['/', '?', '#']).next())
            .filter(|id| !id.is_empty() && id.len() <= 20)
            .map(str::to_owned);
    }
    let urgency = if lower.contains("high urgency") {
        Some("High".to_owned())
    } else if lower.contains("low urgency") {
        Some("Low".to_owned())
    } else {
        ["P1", "P2", "P3", "P4", "P5"]
            .into_iter()
            .find(|p| {
                subject
                    .split(|c: char| !c.is_ascii_alphanumeric())
                    .any(|w| w == *p)
            })
            .map(str::to_owned)
    };
    if url.is_none() && title.is_none() {
        return None;
    }
    Some(Incident {
        provider,
        state,
        title,
        number,
        urgency,
        service: line_value(&context.text.body, "service:"),
        url,
    })
}

impl Plugin for Incidents {
    fn manifest(&self) -> Manifest {
        Manifest {
            id: "postmere.incidents",
            name: "Incidents",
            summary: "PagerDuty and Opsgenie state, urgency and service at a glance.",
            version: 1,
            icon: "flame",
            tint: "red",
            permissions: vec![Permission::MessageRead],
            settings: Vec::new(),
        }
    }

    fn banner(&self, context: &Context) -> Option<Card> {
        let incident = incident(context)?;
        let (state, tint) = match incident.state {
            State::Triggered => ("Triggered", "red"),
            State::Acknowledged => ("Acknowledged", "orange"),
            State::Resolved => ("Resolved", "green"),
        };
        let provider = match incident.provider {
            Provider::PagerDuty => "PagerDuty",
            Provider::Opsgenie => "Opsgenie",
        };
        let title = incident
            .title
            .clone()
            .unwrap_or_else(|| format!("Incident {state}"));
        let mut subtitle = incident.service.clone().unwrap_or_else(|| provider.into());
        if let Some(number) = &incident.number {
            subtitle.push_str(" · ");
            subtitle.push_str(number);
        }
        let mut card = Card::new(title)
            .subtitle(subtitle)
            .component(Component::Badge {
                label: state.into(),
                tint: Some(tint),
            });
        if let Some(urgency) = &incident.urgency {
            card = card.component(Component::Facts {
                items: vec![("Urgency".into(), urgency.clone())],
            });
        }
        if let Some(url) = incident.url {
            card = card.action(Action::open("Open Incident", "arrow.up.right", url));
        }
        if let Some(number) = incident.number {
            card = card.action(Action::copy("Copy Number", "doc.on.doc", number));
        }
        Some(card)
    }

    fn actions(&self, context: &Context) -> Vec<MessageAction> {
        match incident(context) {
            Some(incident) if incident.url.is_some() => vec![MessageAction {
                tool: "open_incident",
                title: "Open Incident".into(),
                icon: "arrow.up.right",
                args: Value::Null,
            }],
            _ => Vec::new(),
        }
    }

    fn call(&self, tool: &str, context: &Context, _args: &Value) -> Result<ToolResult, ToolError> {
        if tool != "open_incident" {
            return Err(ToolError::UnknownTool);
        }
        let url = incident(context)
            .and_then(|i| i.url)
            .ok_or(ToolError::NotApplicable(
                "This message has no incident link.",
            ))?;
        Ok(ToolResult {
            effects: vec![Effect::Open { url }],
            ..ToolResult::default()
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::card::ActionKind;
    use crate::testing::{card, message};

    #[test]
    fn pagerduty_triggered() {
        let mail = message(
            "no-reply@pagerduty.com",
            "PagerDuty",
            "[PagerDuty ALERT] You have 1 TRIGGERED Incident (Q1W2E3)",
            "High urgency\nDescription: Disk full on db-1\nService: Payments API\nView: https://acme.pagerduty.com/incidents/Q1W2E3",
        );
        let c = card(&Incidents, &mail).unwrap();
        assert_eq!(c.title, "Disk full on db-1");
        assert_eq!(c.subtitle.as_deref(), Some("Payments API · Q1W2E3"));
        assert_eq!(
            c.body[0],
            Component::Badge {
                label: "Triggered".into(),
                tint: Some("red")
            }
        );
        assert_eq!(
            c.body[1],
            Component::Facts {
                items: vec![("Urgency".into(), "High".into())]
            }
        );
        assert_eq!(
            c.actions[0].kind,
            ActionKind::Open("https://acme.pagerduty.com/incidents/Q1W2E3".into())
        );
    }

    #[test]
    fn resolved_subject_wins_over_body() {
        let mail = message(
            "no-reply@pagerduty.com",
            "PagerDuty",
            "[#1234] Resolved: Disk full on db-1",
            "Triggered at 10:00, acknowledged at 10:05, resolved at 10:30.",
        );
        let c = card(&Incidents, &mail).unwrap();
        assert_eq!(c.title, "Resolved: Disk full on db-1");
        assert_eq!(
            c.body[0],
            Component::Badge {
                label: "Resolved".into(),
                tint: Some("green")
            }
        );
        assert_eq!(c.subtitle.as_deref(), Some("PagerDuty · #1234"));
        let opsgenie = message(
            "opsgenie@opsgenie.net",
            "Opsgenie",
            "[Opsgenie] P1 Alert: API latency high",
            "https://acme.app.opsgenie.com/alert/detail/abc",
        );
        let c = card(&Incidents, &opsgenie).unwrap();
        assert_eq!(
            c.body[1],
            Component::Facts {
                items: vec![("Urgency".into(), "P1".into())]
            }
        );
        assert!(
            card(
                &Incidents,
                &message(
                    "billing@pagerduty.com",
                    "PagerDuty",
                    "Your invoice",
                    "Thanks"
                )
            )
            .is_none()
        );
    }
}
