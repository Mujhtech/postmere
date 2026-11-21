//! Deploys: Vercel and Netlify deployment mail. Shows whether the deploy
//! failed or went live, the project, environment and branch, with links to
//! the deployment and its preview on the provider's own hosts.
use crate::card::{Action, Card, Component, Effect, ToolResult};
use crate::detect::{find_link, host_is, sender_domain, value_after};
use crate::plugin::{
    Context, Manifest, MessageAction, Permission, Plugin, SettingField, SettingKind, ToolError,
};
use serde_json::Value;

pub struct Deploys;

#[derive(Clone, Copy, Debug, PartialEq)]
enum Host {
    Vercel,
    Netlify,
}

#[derive(Clone, Copy, Debug, PartialEq)]
enum Outcome {
    Failed,
    Cancelled,
    Live,
}

#[derive(Debug, PartialEq)]
struct Deploy {
    host: Host,
    outcome: Outcome,
    project: Option<String>,
    environment: Option<&'static str>,
    branch: Option<String>,
    dashboard: Option<String>,
    preview: Option<String>,
}

fn path_segments(path: &str) -> Vec<&str> {
    path.split(['?', '#'])
        .next()
        .unwrap_or_default()
        .split('/')
        .filter(|s| !s.is_empty())
        .collect()
}

fn deploy(context: &Context) -> Option<Deploy> {
    let domain = sender_domain(context.message);
    let host = if host_is(&domain, "vercel.com") {
        Host::Vercel
    } else if host_is(&domain, "netlify.com") {
        Host::Netlify
    } else {
        return None;
    };
    let lower = &context.text.lower;
    if !lower.contains("deploy") {
        return None;
    }
    let subject = context.text.subject.to_lowercase();
    let says = |words: &[&str]| {
        words.iter().any(|w| subject.contains(w)) || words.iter().any(|w| lower.contains(w))
    };
    let outcome = if says(&["failed", "error"]) {
        Outcome::Failed
    } else if says(&["canceled", "cancelled"]) {
        Outcome::Cancelled
    } else if says(&[
        "is ready",
        "ready",
        "succeeded",
        "successful",
        "published",
        "is live",
        "deployed",
    ]) {
        Outcome::Live
    } else {
        return None;
    };
    let dashboard = find_link(context.text, |link_host, path| match host {
        Host::Vercel => link_host == "vercel.com" && path_segments(path).len() >= 3,
        Host::Netlify => link_host == "app.netlify.com" && path.starts_with("/sites/"),
    });
    let preview = find_link(context.text, |link_host, _| match host {
        Host::Vercel => host_is(link_host, "vercel.app"),
        Host::Netlify => host_is(link_host, "netlify.app"),
    });
    let project = dashboard
        .as_deref()
        .and_then(|url| url.strip_prefix("https://"))
        .and_then(|rest| {
            let segments = path_segments(rest.split_once('/')?.1);
            match host {
                Host::Vercel => segments.get(1).map(|s| (*s).to_owned()),
                Host::Netlify => segments.get(1).map(|s| (*s).to_owned()),
            }
        })
        .or_else(|| {
            // "Deploy failed for my-site" / "... for project my-app"
            let subject = &context.text.subject;
            let at = subject.to_lowercase().rfind(" for ")? + 5;
            let name = subject[at..]
                .trim_start_matches("project ")
                .split_whitespace()
                .next()?
                .trim_matches(['"', '\'', '“', '”', '.', ',']);
            (!name.is_empty() && name.len() <= 60).then(|| name.to_owned())
        });
    let environment = if lower.contains("production") {
        Some("Production")
    } else if lower.contains("preview") {
        Some("Preview")
    } else {
        None
    };
    let branch = value_after(&context.text.body, "branch:")
        .and_then(|v| v.split_whitespace().next().map(str::to_owned))
        .filter(|b| b.len() <= 100);
    Some(Deploy {
        host,
        outcome,
        project,
        environment,
        branch,
        dashboard,
        preview,
    })
}

impl Plugin for Deploys {
    fn manifest(&self) -> Manifest {
        Manifest {
            id: "postmere.deploys",
            name: "Deploys",
            summary: "Vercel and Netlify results with the project, branch and preview.",
            version: 1,
            icon: "icloud.and.arrow.up",
            tint: "teal",
            permissions: vec![Permission::MessageRead],
            settings: vec![SettingField {
                key: "show_successful",
                title: "Show successful deploys",
                kind: SettingKind::Toggle { default: true },
            }],
        }
    }

    fn banner(&self, context: &Context) -> Option<Card> {
        let deploy = deploy(context)?;
        if deploy.outcome == Outcome::Live && !context.setting_bool("show_successful", true) {
            return None;
        }
        let (title, badge, tint) = match deploy.outcome {
            Outcome::Failed => ("Deploy failed", "Failed", "red"),
            Outcome::Cancelled => ("Deploy cancelled", "Cancelled", "gray"),
            Outcome::Live => ("Deployed", "Live", "green"),
        };
        let provider = match deploy.host {
            Host::Vercel => "Vercel",
            Host::Netlify => "Netlify",
        };
        let mut subtitle = deploy.project.clone().unwrap_or_else(|| provider.into());
        if let Some(environment) = deploy.environment {
            subtitle.push_str(" · ");
            subtitle.push_str(environment);
        }
        let mut card = Card::new(title)
            .subtitle(subtitle)
            .component(Component::Badge {
                label: badge.into(),
                tint: Some(tint),
            });
        if let Some(branch) = &deploy.branch {
            card = card.component(Component::Facts {
                items: vec![("Branch".into(), branch.clone())],
            });
        }
        if let Some(url) = deploy.dashboard.clone() {
            let label = if deploy.outcome == Outcome::Failed {
                "Open Logs"
            } else {
                "Open Deployment"
            };
            card = card.action(Action::open(label, "arrow.up.right", url));
        }
        if deploy.outcome == Outcome::Live
            && let Some(preview) = deploy.preview.clone()
        {
            let action = Action::open("Visit", "arrow.up.forward.square", preview);
            card = card.action(if deploy.dashboard.is_some() {
                action.secondary()
            } else {
                action
            });
        }
        if let Some(branch) = deploy.branch {
            card = card.action(Action::copy("Copy Branch", "doc.on.doc", branch));
        }
        Some(card)
    }

    fn actions(&self, context: &Context) -> Vec<MessageAction> {
        match deploy(context) {
            Some(deploy) if deploy.dashboard.is_some() => vec![MessageAction {
                tool: "open_deployment",
                title: "Open Deployment".into(),
                icon: "arrow.up.right",
                args: Value::Null,
            }],
            _ => Vec::new(),
        }
    }

    fn call(&self, tool: &str, context: &Context, _args: &Value) -> Result<ToolResult, ToolError> {
        if tool != "open_deployment" {
            return Err(ToolError::UnknownTool);
        }
        let url = deploy(context)
            .and_then(|d| d.dashboard)
            .ok_or(ToolError::NotApplicable(
                "This message has no deployment link.",
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
    use crate::testing::{card, message, run};
    use serde_json::{Map, json};

    #[test]
    fn vercel_failure() {
        let mail = message(
            "notifications@vercel.com",
            "Vercel",
            "Failed production deployment on team Acme",
            "Your deployment failed.\nBranch: main\nView logs: https://vercel.com/acme/storefront/8xKq2",
        );
        let c = card(&Deploys, &mail).unwrap();
        assert_eq!(c.title, "Deploy failed");
        assert_eq!(c.subtitle.as_deref(), Some("storefront · Production"));
        assert_eq!(c.actions[0].title, "Open Logs");
        assert_eq!(
            c.actions[0].kind,
            ActionKind::Open("https://vercel.com/acme/storefront/8xKq2".into())
        );
        assert_eq!(c.actions[1].kind, ActionKind::Copy("main".into()));
    }

    #[test]
    fn netlify_success_and_setting() {
        let mail = message(
            "team@netlify.com",
            "Netlify",
            "[Netlify] Deploy succeeded for docs-site",
            "Deploy is live: https://docs-site.netlify.app\nhttps://app.netlify.com/sites/docs-site/deploys/abc",
        );
        let c = card(&Deploys, &mail).unwrap();
        assert_eq!(c.title, "Deployed");
        assert_eq!(c.subtitle.as_deref(), Some("docs-site"));
        assert_eq!(
            c.actions[1].kind,
            ActionKind::Open("https://docs-site.netlify.app".into())
        );
        let hide = Map::from_iter([("show_successful".into(), json!(false))]);
        assert!(run(&Deploys, &mail, hide).0.is_none());
        // Marketing mail from the same sender isn't a deploy.
        assert!(
            card(
                &Deploys,
                &message(
                    "team@netlify.com",
                    "Netlify",
                    "Our new pricing",
                    "Read more"
                )
            )
            .is_none()
        );
        let spoof = message(
            "team@netlify.com",
            "Netlify",
            "Deploy failed for x",
            "https://app.netlify.com.evil.test/sites/x",
        );
        assert!(
            card(&Deploys, &spoof)
                .unwrap()
                .actions
                .iter()
                .all(|a| !matches!(a.kind, ActionKind::Open(_)))
        );
    }
}
