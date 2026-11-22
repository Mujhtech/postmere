//! GitHub: reads GitHub's notification mail and shows what happened, why it
//! reached you, and a way to act. Everything comes from the message itself
//! (subject, the "view it on GitHub" link and the "You are receiving this"
//! footer), so it works on mail synced before the plugin was turned on.
//! Links are only ever offered on https://github.com.
use crate::card::{Action, Card, Component, Effect, ToolResult};
use crate::plugin::{
    Context, Manifest, MessageAction, Permission, Plugin, SettingField, SettingKind, ToolError,
};
use serde_json::Value;

pub struct GitHub;

const GITHUB: &str = "https://github.com/";

#[derive(Debug, PartialEq)]
enum Kind {
    PullRequest,
    Issue,
    Discussion,
}

#[derive(Debug, PartialEq)]
enum Notice {
    /// A pull request, issue or discussion thread.
    Thread {
        repo: String,
        kind: Kind,
        number: u64,
        title: String,
        url: String,
        event: Event,
        reason: Option<&'static str>,
        actor: Option<String>,
    },
    /// A GitHub Actions run result.
    Run {
        repo: String,
        outcome: RunOutcome,
        workflow: String,
        branch: Option<String>,
        commit: Option<String>,
        url: Option<String>,
    },
    /// Dependabot or code scanning.
    Security {
        repo: String,
        severity: Option<&'static str>,
        url: String,
    },
}

#[derive(Debug, PartialEq)]
enum Event {
    Opened,
    ReviewRequested,
    Approved,
    ChangesRequested,
    Merged(Option<String>),
    Closed,
    Reopened,
    Commented,
    Pushed,
    Other,
}

#[derive(Debug, PartialEq)]
enum RunOutcome {
    Failed,
    Cancelled,
    Succeeded,
}

fn from_github(context: &Context) -> bool {
    let email = context.message.from.email.to_ascii_lowercase();
    email.ends_with("@github.com")
}

/// "Re: [octo/app] Fix login (PR #12)" → ("octo/app", "Fix login (PR #12)").
fn repo_and_rest(subject: &str) -> Option<(String, String)> {
    let subject = subject.trim();
    let start = subject.find('[')?;
    let prefix = subject[..start].trim().to_ascii_lowercase();
    if !(prefix.is_empty() || prefix == "re:" || prefix == "fwd:") {
        return None;
    }
    let end = start + subject[start..].find(']')?;
    let repo = &subject[start + 1..end];
    let (owner, name) = repo.split_once('/')?;
    let valid = |s: &str| {
        !s.is_empty()
            && s.len() <= 100
            && s.chars()
                .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'))
    };
    (valid(owner) && valid(name)).then(|| (repo.to_owned(), subject[end + 1..].trim().to_owned()))
}

/// "Fix login (PR #12)" → ("Fix login", 12).
fn title_and_number(rest: &str) -> Option<(String, u64)> {
    let open = rest.rfind('(')?;
    let inner = rest[open + 1..].strip_suffix(')')?;
    let number = inner.rsplit_once('#')?.1.parse().ok()?;
    Some((rest[..open].trim().to_owned(), number))
}

/// The first https://github.com link in the body or the HTML part that starts
/// with `prefix` (a path under github.com), trimmed of trailing punctuation.
fn github_link(context: &Context, prefix: &str) -> Option<String> {
    let wanted = format!("{GITHUB}{prefix}");
    let from_body = context.text.body.match_indices(&wanted).map(|(at, _)| {
        context.text.body[at..]
            .split(|c: char| c.is_whitespace() || matches!(c, '<' | '>' | '"' | ')'))
            .next()
            .unwrap_or_default()
            .to_owned()
    });
    let from_links = context
        .text
        .links
        .iter()
        .filter(|(url, _)| url.starts_with(&wanted))
        .map(|(url, _)| url.clone());
    from_body
        .chain(from_links)
        .map(|url| url.trim_end_matches(['.', ',', ';']).to_owned())
        // "pull/12" must not match "pull/123".
        .filter(|url| {
            !url[wanted.len()..].starts_with(|c: char| c.is_ascii_digit())
                || !wanted.ends_with(|c: char| c.is_ascii_digit())
        })
        .find(|url| url.len() <= 512)
}

fn reason(lower: &str) -> Option<&'static str> {
    let sentence = &lower[lower.find("you are receiving this because")?..];
    let sentence = &sentence[..sentence.len().min(120)];
    const REASONS: &[(&str, &str)] = &[
        ("review was requested", "Review requested"),
        ("requested to review", "Review requested"),
        ("team was mentioned", "Team mentioned"),
        ("you were mentioned", "Mentioned"),
        ("you were assigned", "Assigned"),
        ("you authored", "You opened it"),
        ("you commented", "You commented"),
        ("you modified the open/close state", "You changed its state"),
        ("you are subscribed", "Watching"),
        ("you are watching", "Watching"),
    ];
    REASONS
        .iter()
        .find(|(phrase, _)| sentence.contains(phrase))
        .map(|(_, label)| *label)
}

fn event(lower: &str, number: u64, is_reply: bool, kind: &Kind) -> Event {
    let merged = format!("merged #{number} into ");
    if let Some(at) = lower.find(&merged) {
        let branch: String = lower[at + merged.len()..]
            .chars()
            .take_while(|c| !c.is_whitespace())
            .collect();
        let branch = branch.trim_end_matches('.').to_owned();
        return Event::Merged((!branch.is_empty()).then_some(branch));
    }
    if lower.contains(&format!("closed #{number}")) {
        Event::Closed
    } else if lower.contains(&format!("reopened #{number}")) {
        Event::Reopened
    } else if lower.contains("requested your review on") {
        Event::ReviewRequested
    } else if lower.contains("approved this pull request") {
        Event::Approved
    } else if lower.contains("requested changes on this pull request") {
        Event::ChangesRequested
    } else if lower.contains("pushed 1 commit")
        || (lower.contains(" commits.") && lower.contains("pushed "))
    {
        Event::Pushed
    } else if lower.contains("commented on this pull request")
        || lower.contains("commented on this issue")
        || lower.contains("commented on this discussion")
    {
        Event::Commented
    } else if !is_reply
        && (*kind != Kind::PullRequest
            || lower.contains("you can view, comment on, or merge this pull request online"))
    {
        Event::Opened
    } else if is_reply {
        Event::Commented
    } else {
        Event::Other
    }
}

fn severity(lower: &str) -> Option<&'static str> {
    ["critical", "high", "moderate", "medium", "low"]
        .into_iter()
        .find(|s| lower.contains(&format!("{s} severity")))
        .map(|s| match s {
            "critical" => "Critical",
            "high" => "High",
            "moderate" | "medium" => "Moderate",
            _ => "Low",
        })
}

/// "Run failed: CI - main (abc1234)".
fn run(repo: &str, rest: &str, context: &Context) -> Option<Notice> {
    let (status, detail) = rest.split_once(':')?;
    let status = status.trim().to_ascii_lowercase();
    let outcome = if status.ends_with("run failed") {
        RunOutcome::Failed
    } else if status.ends_with("run cancelled") || status.ends_with("run canceled") {
        RunOutcome::Cancelled
    } else if status.ends_with("run succeeded") || status.ends_with("run completed") {
        RunOutcome::Succeeded
    } else {
        return None;
    };
    let mut detail = detail.trim();
    let mut commit = None;
    if let Some(open) = detail.rfind('(')
        && let Some(sha) = detail[open + 1..].strip_suffix(')')
        && (7..=40).contains(&sha.len())
        && sha.chars().all(|c| c.is_ascii_hexdigit())
    {
        commit = Some(sha.to_owned());
        detail = detail[..open].trim();
    }
    let (workflow, branch) = match detail.rsplit_once(" - ") {
        Some((workflow, branch)) => (workflow.trim(), Some(branch.trim().to_owned())),
        None => (detail, None),
    };
    Some(Notice::Run {
        repo: repo.to_owned(),
        outcome,
        workflow: workflow.to_owned(),
        branch,
        commit,
        url: github_link(context, &format!("{repo}/actions/runs/")),
    })
}

fn notice(context: &Context) -> Option<Notice> {
    if !from_github(context) {
        return None;
    }
    let (repo, rest) = repo_and_rest(&context.text.subject)?;
    let lower = &context.text.lower;
    if let Some(run) = run(&repo, &rest, context) {
        return Some(run);
    }
    if lower.contains("dependabot")
        || lower.contains("security advisory")
        || lower.contains("code scanning")
    {
        let url = github_link(context, &format!("{repo}/security"))
            .unwrap_or_else(|| format!("{GITHUB}{repo}/security"));
        return Some(Notice::Security {
            repo,
            severity: severity(lower),
            url,
        });
    }
    let (title, number) = title_and_number(&rest)?;
    let (kind, url) = [
        (Kind::PullRequest, "pull"),
        (Kind::Issue, "issues"),
        (Kind::Discussion, "discussions"),
    ]
    .into_iter()
    .find_map(|(kind, path)| {
        github_link(context, &format!("{repo}/{path}/{number}")).map(|url| (kind, url))
    })?;
    let is_reply = context
        .text
        .subject
        .trim_start()
        .to_ascii_lowercase()
        .starts_with("re:");
    let actor = context
        .message
        .from
        .name
        .as_deref()
        .map(str::trim)
        .filter(|n| !n.is_empty() && !n.eq_ignore_ascii_case("github"))
        .map(str::to_owned);
    Some(Notice::Thread {
        event: event(lower, number, is_reply, &kind),
        reason: reason(lower),
        repo,
        kind,
        number,
        title,
        url,
        actor,
    })
}

/// GitHub's per-thread unsubscribe page, from the notification footer.
fn unsubscribe_link(context: &Context) -> Option<String> {
    github_link(context, "notifications/unsubscribe")
}

fn kind_name(kind: &Kind) -> &'static str {
    match kind {
        Kind::PullRequest => "Pull request",
        Kind::Issue => "Issue",
        Kind::Discussion => "Discussion",
    }
}

impl Plugin for GitHub {
    fn manifest(&self) -> Manifest {
        Manifest {
            id: "postmere.github",
            name: "GitHub",
            summary: "What happened and why, on pull request, issue and build mail.",
            version: 1,
            icon: "chevron.left.forwardslash.chevron.right",
            tint: "indigo",
            brands: vec!["github"],
            permissions: vec![Permission::MessageRead],
            settings: vec![SettingField {
                key: "show_successful_runs",
                title: "Show successful workflow runs",
                kind: SettingKind::Toggle { default: false },
            }],
        }
    }

    fn banner(&self, context: &Context) -> Option<Card> {
        match notice(context)? {
            Notice::Thread {
                repo,
                kind,
                number,
                title,
                url,
                event,
                reason,
                actor,
            } => {
                let by = |verb: &str| match &actor {
                    Some(actor) => format!("{verb} by {actor}"),
                    None => verb.to_owned(),
                };
                let (headline, tint) = match &event {
                    Event::Opened => (format!("New {}", kind_name(&kind).to_lowercase()), None),
                    Event::ReviewRequested => ("Review requested".into(), Some("orange")),
                    Event::Approved => (by("Approved"), Some("green")),
                    Event::ChangesRequested => (by("Changes requested"), Some("red")),
                    Event::Merged(Some(branch)) => {
                        (format!("Merged into {branch}"), Some("purple"))
                    }
                    Event::Merged(None) => ("Merged".into(), Some("purple")),
                    Event::Closed => ("Closed".into(), Some("gray")),
                    Event::Reopened => ("Reopened".into(), Some("green")),
                    Event::Commented => (
                        actor
                            .as_ref()
                            .map_or("New comment".into(), |a| format!("{a} commented")),
                        None,
                    ),
                    Event::Pushed => ("New commits pushed".into(), None),
                    Event::Other => (kind_name(&kind).into(), None),
                };
                let reference = format!("{repo}#{number}");
                let mut card = Card::new(headline)
                    .brand("github")
                    .subtitle(format!("{reference} · {title}"));
                if let Some(reason) = reason {
                    card = card.component(Component::Badge {
                        label: reason.into(),
                        tint: Some(tint.unwrap_or("blue")),
                    });
                }
                card = card
                    .action(Action::open("Open on GitHub", "arrow.up.right", url))
                    .action(Action::copy("Copy Reference", "doc.on.doc", reference));
                if let Some(link) = unsubscribe_link(context) {
                    card = card.action(
                        Action::open("Unsubscribe from Thread", "bell.slash", link).secondary(),
                    );
                }
                Some(card)
            }
            Notice::Run {
                repo,
                outcome,
                workflow,
                branch,
                commit,
                url,
            } => {
                if outcome == RunOutcome::Succeeded
                    && !context.setting_bool("show_successful_runs", false)
                {
                    return None;
                }
                let (headline, badge, tint) = match outcome {
                    RunOutcome::Failed => ("Workflow failed", "Failed", "red"),
                    RunOutcome::Cancelled => ("Workflow cancelled", "Cancelled", "gray"),
                    RunOutcome::Succeeded => ("Workflow succeeded", "Passed", "green"),
                };
                let mut subtitle = repo.clone();
                if let Some(branch) = &branch {
                    subtitle.push_str(" · ");
                    subtitle.push_str(branch);
                }
                let mut facts = vec![("Workflow".to_owned(), workflow)];
                if let Some(commit) = &commit {
                    facts.push(("Commit".into(), commit.chars().take(7).collect()));
                }
                let mut card = Card::new(headline)
                    .brand("github")
                    .subtitle(subtitle)
                    .component(Component::Badge {
                        label: badge.into(),
                        tint: Some(tint),
                    })
                    .component(Component::Facts { items: facts });
                card = card.action(Action::open(
                    "Open Run",
                    "arrow.up.right",
                    url.unwrap_or_else(|| format!("{GITHUB}{repo}/actions")),
                ));
                if let Some(branch) = branch {
                    card = card.action(Action::copy("Copy Branch", "doc.on.doc", branch));
                }
                Some(card)
            }
            Notice::Security {
                repo,
                severity,
                url,
            } => {
                let mut card = Card::new("Security alert").brand("github").subtitle(repo);
                if let Some(severity) = severity {
                    let tint = match severity {
                        "Critical" | "High" => "red",
                        "Moderate" => "orange",
                        _ => "yellow",
                    };
                    card = card.component(Component::Badge {
                        label: format!("{severity} severity"),
                        tint: Some(tint),
                    });
                }
                Some(card.action(Action::open("Review Alerts", "arrow.up.right", url)))
            }
        }
    }

    fn actions(&self, context: &Context) -> Vec<MessageAction> {
        let Some(notice) = notice(context) else {
            return Vec::new();
        };
        let mut actions = vec![MessageAction {
            tool: "open_on_github",
            title: "Open on GitHub".into(),
            icon: "arrow.up.right",
            args: Value::Null,
        }];
        if matches!(notice, Notice::Thread { .. }) && unsubscribe_link(context).is_some() {
            actions.push(MessageAction {
                tool: "unsubscribe_thread",
                title: "Unsubscribe from GitHub Thread".into(),
                icon: "bell.slash",
                args: Value::Null,
            });
        }
        actions
    }

    fn call(&self, tool: &str, context: &Context, _args: &Value) -> Result<ToolResult, ToolError> {
        let notice = notice(context).ok_or(ToolError::NotApplicable(
            "This isn't a GitHub notification.",
        ))?;
        let url = match tool {
            "open_on_github" => match notice {
                Notice::Thread { url, .. } | Notice::Security { url, .. } => url,
                Notice::Run { url, repo, .. } => {
                    url.unwrap_or_else(|| format!("{GITHUB}{repo}/actions"))
                }
            },
            "unsubscribe_thread" => unsubscribe_link(context).ok_or(ToolError::NotApplicable(
                "This notification has no unsubscribe link.",
            ))?,
            _ => return Err(ToolError::UnknownTool),
        };
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
    use crate::detect::MailText;
    use chrono::NaiveDate;
    use postmere_providers::Message;
    use serde_json::{Map, json};

    fn message(from: &str, name: &str, subject: &str, text: &str) -> Message {
        serde_json::from_value(json!({
            "id": uuid::Uuid::nil(), "account_id": uuid::Uuid::nil(),
            "provider_message_id": "m", "provider_thread_id": "t",
            "subject": subject, "from": {"name": name, "email": from},
            "to": [], "cc": [], "bcc": [], "text_body": text, "html_body": null,
            "preview": "", "sent_at": "2026-11-20T10:00:00Z", "is_read": false, "is_starred": false,
            "mailbox": "inbox", "provider_labels": [], "attachments": [],
            "list_unsubscribe": [], "list_unsubscribe_post": []
        }))
        .unwrap()
    }

    fn banner(message: &Message, settings: Map<String, Value>) -> Option<Card> {
        let text = MailText::new(message);
        let context = Context {
            message,
            text: &text,
            settings: &settings,
            today: NaiveDate::from_ymd_opt(2026, 11, 21).unwrap(),
        };
        GitHub.banner(&context)
    }

    const FOOTER: &str = "—\nReply to this email directly, view it on GitHub:\nhttps://github.com/octo/app/pull/12#pullrequestreview-99\nYou are receiving this because your review was requested.\nUnsubscribe: https://github.com/notifications/unsubscribe-auth/ABC123.";

    #[test]
    fn review_request_card() {
        let body = format!("@ada requested your review on: octo/app#12 Fix login.\n\n{FOOTER}");
        let mail = message(
            "notifications@github.com",
            "Ada Lovelace",
            "[octo/app] Fix login (PR #12)",
            &body,
        );
        let card = banner(&mail, Map::new()).unwrap();
        assert_eq!(card.title, "Review requested");
        assert_eq!(card.subtitle.as_deref(), Some("octo/app#12 · Fix login"));
        assert_eq!(
            card.body,
            vec![Component::Badge {
                label: "Review requested".into(),
                tint: Some("orange")
            }]
        );
        assert_eq!(
            card.actions[0].kind,
            ActionKind::Open("https://github.com/octo/app/pull/12#pullrequestreview-99".into())
        );
        assert_eq!(card.actions[1].kind, ActionKind::Copy("octo/app#12".into()));
        assert_eq!(
            card.actions[2].kind,
            ActionKind::Open("https://github.com/notifications/unsubscribe-auth/ABC123".into())
        );
    }

    #[test]
    fn reads_merges_approvals_and_comments() {
        let merged = message(
            "notifications@github.com",
            "Ada",
            "Re: [octo/app] Fix login (PR #12)",
            &format!("Merged #12 into main.\n\n{FOOTER}"),
        );
        assert_eq!(
            banner(&merged, Map::new()).unwrap().title,
            "Merged into main"
        );
        let approved = message(
            "notifications@github.com",
            "Grace",
            "Re: [octo/app] Fix login (PR #12)",
            &format!("@grace approved this pull request.\n\n{FOOTER}"),
        );
        assert_eq!(
            banner(&approved, Map::new()).unwrap().title,
            "Approved by Grace"
        );
        let comment = message(
            "notifications@github.com",
            "Linus",
            "Re: [octo/app] Crash on start (#40)",
            "Still happens on 2.1\n\n—\nhttps://github.com/octo/app/issues/40#issuecomment-1\nYou are receiving this because you were mentioned.",
        );
        let card = banner(&comment, Map::new()).unwrap();
        assert_eq!(card.title, "Linus commented");
        assert_eq!(
            card.body,
            vec![Component::Badge {
                label: "Mentioned".into(),
                tint: Some("blue")
            }]
        );
        let opened = message(
            "notifications@github.com",
            "Linus",
            "[octo/app] Crash on start (Issue #40)",
            "It crashes.\n\nhttps://github.com/octo/app/issues/40",
        );
        assert_eq!(banner(&opened, Map::new()).unwrap().title, "New issue");
    }

    #[test]
    fn workflow_runs() {
        let failed = message(
            "notifications@github.com",
            "GitHub",
            "[octo/app] Run failed: CI - feature/login (a1b2c3d4e5)",
            "CI: Some jobs were not successful\nView workflow run: https://github.com/octo/app/actions/runs/777",
        );
        let card = banner(&failed, Map::new()).unwrap();
        assert_eq!(card.title, "Workflow failed");
        assert_eq!(card.subtitle.as_deref(), Some("octo/app · feature/login"));
        assert!(card.body.contains(&Component::Facts {
            items: vec![
                ("Workflow".into(), "CI".into()),
                ("Commit".into(), "a1b2c3d".into())
            ]
        }));
        assert_eq!(
            card.actions[0].kind,
            ActionKind::Open("https://github.com/octo/app/actions/runs/777".into())
        );
        assert_eq!(
            card.actions[1].kind,
            ActionKind::Copy("feature/login".into())
        );

        let passed = message(
            "notifications@github.com",
            "GitHub",
            "[octo/app] Run succeeded: Deploy - main (a1b2c3d)",
            "",
        );
        assert!(banner(&passed, Map::new()).is_none());
        let show = Map::from_iter([("show_successful_runs".into(), json!(true))]);
        assert_eq!(banner(&passed, show).unwrap().title, "Workflow succeeded");
    }

    #[test]
    fn security_alerts_and_lookalikes() {
        let alert = message(
            "noreply@github.com",
            "GitHub",
            "[octo/app] Dependabot alert: lodash prototype pollution",
            "A high severity vulnerability was found.\nhttps://github.com/octo/app/security/dependabot/3",
        );
        let card = banner(&alert, Map::new()).unwrap();
        assert_eq!(card.title, "Security alert");
        assert_eq!(
            card.actions[0].kind,
            ActionKind::Open("https://github.com/octo/app/security/dependabot/3".into())
        );

        // Not from GitHub, or links that only look like GitHub: no card.
        let spoof = message(
            "notifications@github.example",
            "GitHub",
            "[octo/app] Fix login (PR #12)",
            FOOTER,
        );
        assert!(banner(&spoof, Map::new()).is_none());
        let elsewhere = message(
            "notifications@github.com",
            "Ada",
            "[octo/app] Fix login (PR #12)",
            "https://github.com.evil.test/octo/app/pull/12",
        );
        assert!(banner(&elsewhere, Map::new()).is_none());
        let newsletter = message(
            "noreply@github.com",
            "GitHub",
            "Your GitHub launch code",
            "Welcome",
        );
        assert!(banner(&newsletter, Map::new()).is_none());
    }
}
