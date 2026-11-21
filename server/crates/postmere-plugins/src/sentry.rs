//! Sentry: error alert mail. Shows the error, whether it's new, a regression
//! or escalating, where it happened, and links to the issue on sentry.io.
use crate::card::{Action, Card, Component, Effect, ToolResult};
use crate::detect::{find_link, host_is, sender_domain, value_after};
use crate::plugin::{Context, Manifest, MessageAction, Permission, Plugin, ToolError};
use serde_json::Value;

pub struct Sentry;

#[derive(Debug, PartialEq)]
struct Alert {
    title: String,
    short_id: Option<String>,
    project: Option<String>,
    state: Option<(&'static str, &'static str)>,
    environment: Option<String>,
    release: Option<String>,
    url: Option<String>,
}

fn from_sentry(context: &Context) -> bool {
    let domain = sender_domain(context.message);
    host_is(&domain, "sentry.io") || host_is(&domain, "getsentry.com")
}

/// "PROJ-1A2" style short IDs.
fn is_short_id(token: &str) -> bool {
    token.split_once('-').is_some_and(|(a, b)| {
        !a.is_empty()
            && !b.is_empty()
            && a.len() <= 30
            && b.len() <= 10
            && a.chars()
                .all(|c| c.is_ascii_uppercase() || c.is_ascii_digit() || c == '_')
            && b.chars()
                .all(|c| c.is_ascii_uppercase() || c.is_ascii_digit())
    })
}

/// A one-token value such as "production" or "app@2.4.1".
fn token(value: Option<String>) -> Option<String> {
    let value = value?;
    let first = value
        .split_whitespace()
        .next()?
        .trim_matches(['"', ',', ';'])
        .to_owned();
    (first.len() <= 60 && value.split_whitespace().count() == 1).then_some(first)
}

fn alert(context: &Context) -> Option<Alert> {
    if !from_sentry(context) {
        return None;
    }
    // Strip "[Sentry]" / "[org]" prefixes and "Re:".
    let mut rest = context.text.subject.trim();
    loop {
        let lowered = rest.to_ascii_lowercase();
        if lowered.starts_with("re:") {
            rest = rest[3..].trim_start();
        } else if rest.starts_with('[')
            && let Some(end) = rest.find(']')
        {
            rest = rest[end + 1..].trim_start();
        } else {
            break;
        }
    }
    let (short_id, title) = match rest.split_once(" - ") {
        Some((id, title)) if is_short_id(id.trim()) => (Some(id.trim().to_owned()), title.trim()),
        _ => (None, rest),
    };
    let url = find_link(context.text, |host, path| {
        (host_is(host, "sentry.io")) && (path.contains("/issues/") || path.contains("/alerts/"))
    });
    if title.is_empty() || (url.is_none() && short_id.is_none()) {
        return None;
    }
    let lower = &context.text.lower;
    let state = if lower.contains("regression") || lower.contains("regressed") {
        Some(("Regression", "red"))
    } else if lower.contains("escalating") {
        Some(("Escalating", "orange"))
    } else if lower.contains("resolved") {
        Some(("Resolved", "green"))
    } else if lower.contains("new issue")
        || lower.contains("first seen")
        || lower.contains("new error")
    {
        Some(("New", "red"))
    } else {
        None
    };
    let body = &context.text.body;
    let project = token(value_after(body, "project:")).or_else(|| {
        short_id.as_ref().map(|id| {
            id.split('-')
                .next()
                .unwrap_or_default()
                .to_ascii_lowercase()
        })
    });
    Some(Alert {
        title: title.to_owned(),
        project,
        state,
        environment: token(value_after(body, "environment:"))
            .or_else(|| token(value_after(body, "environment\n"))),
        release: token(value_after(body, "release:"))
            .or_else(|| token(value_after(body, "release\n"))),
        short_id,
        url,
    })
}

impl Plugin for Sentry {
    fn manifest(&self) -> Manifest {
        Manifest {
            id: "postmere.sentry",
            name: "Sentry",
            summary: "The error, its state and where it happened, on Sentry alerts.",
            version: 1,
            icon: "ladybug",
            tint: "purple",
            permissions: vec![Permission::MessageRead],
            settings: Vec::new(),
        }
    }

    fn banner(&self, context: &Context) -> Option<Card> {
        let alert = alert(context)?;
        let mut subtitle = alert.project.clone().unwrap_or_else(|| "Sentry".into());
        if let Some(environment) = &alert.environment {
            subtitle.push_str(" · ");
            subtitle.push_str(environment);
        }
        let mut card = Card::new(&alert.title).subtitle(subtitle);
        if let Some((label, tint)) = alert.state {
            card = card.component(Component::Badge {
                label: label.into(),
                tint: Some(tint),
            });
        }
        let mut facts = Vec::new();
        if let Some(id) = &alert.short_id {
            facts.push(("Issue".to_owned(), id.clone()));
        }
        if let Some(release) = &alert.release {
            facts.push(("Release".to_owned(), release.clone()));
        }
        if !facts.is_empty() {
            card = card.component(Component::Facts { items: facts });
        }
        if let Some(url) = alert.url {
            card = card.action(Action::open("Open in Sentry", "arrow.up.right", url));
        }
        if let Some(id) = alert.short_id {
            card = card.action(Action::copy("Copy Issue ID", "doc.on.doc", id));
        }
        Some(card)
    }

    fn actions(&self, context: &Context) -> Vec<MessageAction> {
        match alert(context) {
            Some(alert) if alert.url.is_some() => vec![MessageAction {
                tool: "open_issue",
                title: "Open in Sentry".into(),
                icon: "arrow.up.right",
                args: Value::Null,
            }],
            _ => Vec::new(),
        }
    }

    fn call(&self, tool: &str, context: &Context, _args: &Value) -> Result<ToolResult, ToolError> {
        if tool != "open_issue" {
            return Err(ToolError::UnknownTool);
        }
        let url = alert(context)
            .and_then(|a| a.url)
            .ok_or(ToolError::NotApplicable("This message has no Sentry link."))?;
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
    fn new_error_alert() {
        let mail = message(
            "noreply@md.getsentry.com",
            "Sentry",
            "[Sentry] WEB-3F - TypeError: Cannot read properties of undefined",
            "New issue\nproject: web\nenvironment: production\nrelease: web@2.4.1\nView on Sentry: https://acme.sentry.io/issues/4242/?referrer=alert_email",
        );
        let c = card(&Sentry, &mail).unwrap();
        assert_eq!(c.title, "TypeError: Cannot read properties of undefined");
        assert_eq!(c.subtitle.as_deref(), Some("web · production"));
        assert_eq!(
            c.body[0],
            Component::Badge {
                label: "New".into(),
                tint: Some("red")
            }
        );
        assert_eq!(
            c.body[1],
            Component::Facts {
                items: vec![
                    ("Issue".into(), "WEB-3F".into()),
                    ("Release".into(), "web@2.4.1".into())
                ]
            }
        );
        assert_eq!(
            c.actions[0].kind,
            ActionKind::Open("https://acme.sentry.io/issues/4242/?referrer=alert_email".into())
        );
        assert_eq!(c.actions[1].kind, ActionKind::Copy("WEB-3F".into()));
    }

    #[test]
    fn regression_without_short_id_needs_a_link() {
        let mail = message(
            "alerts@sentry.io",
            "Sentry",
            "[acme] Regression: ValueError in checkout",
            "This issue regressed.\nhttps://sentry.io/organizations/acme/issues/77/",
        );
        let c = card(&Sentry, &mail).unwrap();
        assert_eq!(c.title, "Regression: ValueError in checkout");
        assert_eq!(
            c.body[0],
            Component::Badge {
                label: "Regression".into(),
                tint: Some("red")
            }
        );
        // A newsletter from Sentry has neither an issue link nor an ID.
        assert!(
            card(
                &Sentry,
                &message(
                    "hello@sentry.io",
                    "Sentry",
                    "What's new in Sentry",
                    "https://blog.sentry.io/x"
                )
            )
            .is_none()
        );
        assert!(
            card(
                &Sentry,
                &message(
                    "noreply@sentry.io.evil.test",
                    "Sentry",
                    "[Sentry] WEB-1 - X",
                    ""
                )
            )
            .is_none()
        );
    }
}
