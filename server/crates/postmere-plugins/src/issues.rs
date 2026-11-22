//! Issue Tracking: Linear and Jira notification mail. Shows what changed on
//! the issue, its key and title, and offers the issue link, the key and a
//! branch name. Read from the message; links only on the tracker's own host.
use crate::card::{Action, Card, Component, Effect, ToolResult};
use crate::detect::{find_link, host_is, sender_domain, value_after};
use crate::plugin::{Context, Manifest, MessageAction, Permission, Plugin, ToolError};
use serde_json::Value;

pub struct Issues;

#[derive(Clone, Copy, Debug, PartialEq)]
enum Tracker {
    Linear,
    Jira,
}

impl Tracker {
    fn brand(self) -> &'static str {
        match self {
            Self::Linear => "linear",
            Self::Jira => "jira",
        }
    }
    fn name(self) -> &'static str {
        match self {
            Self::Linear => "Linear",
            Self::Jira => "Jira",
        }
    }
}

#[derive(Debug, PartialEq)]
struct Issue {
    tracker: Tracker,
    key: String,
    title: Option<String>,
    url: Option<String>,
    event: String,
    status: Option<String>,
    priority: Option<String>,
}

/// "ENG-123", "PROJ-7": 1–10 uppercase letters or digits starting with a
/// letter, a hyphen, then 1–7 digits.
fn is_key(token: &str) -> bool {
    let Some((prefix, number)) = token.split_once('-') else {
        return false;
    };
    (1..=10).contains(&prefix.len())
        && prefix.starts_with(|c: char| c.is_ascii_uppercase())
        && prefix
            .chars()
            .all(|c| c.is_ascii_uppercase() || c.is_ascii_digit())
        && (1..=7).contains(&number.len())
        && number.chars().all(|c| c.is_ascii_digit())
}

/// The first issue key in `text` and the byte offset just after it.
fn find_key(text: &str) -> Option<(String, usize)> {
    let mut start = None;
    for (i, c) in text
        .char_indices()
        .chain(std::iter::once((text.len(), ' ')))
    {
        let part = c.is_ascii_alphanumeric() || c == '-';
        match (part, start) {
            (true, None) => start = Some(i),
            (false, Some(s)) => {
                let token = text[s..i].trim_end_matches('-');
                if is_key(token) {
                    return Some((token.to_owned(), s + token.len()));
                }
                start = None;
            }
            _ => {}
        }
    }
    None
}

fn tracker(context: &Context) -> Option<Tracker> {
    let domain = sender_domain(context.message);
    if host_is(&domain, "linear.app") {
        Some(Tracker::Linear)
    } else if host_is(&domain, "atlassian.net") {
        Some(Tracker::Jira)
    } else {
        None
    }
}

fn issue_link(context: &Context, tracker: Tracker, key: &str) -> Option<String> {
    let key_lower = key.to_ascii_lowercase();
    let found = find_link(context.text, |host, path| {
        let path = path.to_ascii_lowercase();
        match tracker {
            Tracker::Linear => {
                host_is(host, "linear.app") && path.contains(&format!("/issue/{key_lower}"))
            }
            Tracker::Jira => {
                host_is(host, "atlassian.net") && path.contains(&format!("/browse/{key_lower}"))
            }
        }
    });
    found.or_else(|| {
        // Jira mail always comes from the site itself, so its address is safe to build.
        let domain = sender_domain(context.message);
        (tracker == Tracker::Jira && host_is(&domain, "atlassian.net") && domain != "atlassian.net")
            .then(|| format!("https://{domain}/browse/{key}"))
    })
}

fn actor(context: &Context, tracker: Tracker) -> Option<String> {
    let name = context.message.from.name.as_deref()?.trim();
    let name = name
        .strip_suffix(&format!("({})", tracker.name()))
        .unwrap_or(name)
        .trim();
    (!name.is_empty() && !name.eq_ignore_ascii_case(tracker.name())).then(|| name.to_owned())
}

fn short_value(value: Option<String>) -> Option<String> {
    let value = value?;
    let value = value
        .split(['.', ',', ';', '(', '|'])
        .next()
        .unwrap_or_default()
        .trim()
        .trim_matches(['"', '“', '”', '\''])
        .to_owned();
    (!value.is_empty() && value.len() <= 30 && value.split_whitespace().count() <= 4)
        .then_some(value)
}

fn issue(context: &Context) -> Option<Issue> {
    let tracker = tracker(context)?;
    let subject = &context.text.subject;
    let (key, after) = find_key(subject).or_else(|| find_key(&context.text.body))?;
    let title = subject
        .get(after..)
        .filter(|_| subject.contains(&key))
        .map(|rest| {
            rest.trim_start_matches([')', ']', ':', '-', '–', ' '])
                .trim()
                .to_owned()
        })
        .filter(|t| !t.is_empty());
    let lower = &context.text.lower;
    let actor = actor(context, tracker);
    let by = |verb: &str| {
        actor
            .as_ref()
            .map_or_else(|| verb.to_owned(), |a| format!("{a} {verb}"))
    };
    let status = [
        "changed the status to",
        "changed status to",
        "status changed to",
        "moved this issue to",
        "moved to",
    ]
    .iter()
    .find_map(|cue| {
        short_value(value_after(&context.text.body, cue).or_else(|| value_after(subject, cue)))
    });
    let event = if lower.contains("assigned you")
        || lower.contains("assigned to you")
        || lower.contains("assigned this issue to you")
        || lower.contains("you were assigned")
    {
        "Assigned to you".to_owned()
    } else if lower.contains("mentioned you") {
        by("mentioned you")
    } else if let Some(status) = &status {
        format!("Moved to {status}")
    } else if lower.contains("commented")
        || lower.contains("new comment")
        || subject.trim_start().to_ascii_lowercase().starts_with("re:")
    {
        by("commented")
    } else if lower.contains("created") || lower.contains("new issue") || lower.contains("opened") {
        "New issue".to_owned()
    } else if lower.contains("resolved")
        || lower.contains("completed")
        || lower.contains("marked as done")
    {
        "Done".to_owned()
    } else {
        "Issue updated".to_owned()
    };
    let priority = short_value(value_after(&context.text.body, "priority:")).filter(|p| {
        [
            "urgent", "highest", "high", "medium", "low", "lowest", "critical", "major", "minor",
        ]
        .contains(&p.to_ascii_lowercase().as_str())
    });
    Some(Issue {
        url: issue_link(context, tracker, &key),
        tracker,
        key,
        title,
        event,
        status,
        priority,
    })
}

/// "ENG-123" + "Fix login on Safari" → "eng-123-fix-login-on-safari".
fn branch_name(key: &str, title: Option<&str>) -> String {
    let mut branch = key.to_ascii_lowercase();
    if let Some(title) = title {
        let slug: Vec<String> = title
            .split(|c: char| !c.is_ascii_alphanumeric())
            .filter(|w| !w.is_empty())
            .map(str::to_ascii_lowercase)
            .collect();
        for word in slug {
            if branch.len() + word.len() + 1 > 60 {
                break;
            }
            branch.push('-');
            branch.push_str(&word);
        }
    }
    branch
}

impl Plugin for Issues {
    fn manifest(&self) -> Manifest {
        Manifest {
            id: "postmere.issues",
            name: "Issue Tracking",
            summary: "Linear and Jira updates with the issue, its status and a branch name.",
            version: 1,
            icon: "checklist",
            tint: "blue",
            brands: vec!["linear", "jira"],
            permissions: vec![Permission::MessageRead],
            settings: Vec::new(),
        }
    }

    fn banner(&self, context: &Context) -> Option<Card> {
        let issue = issue(context)?;
        let subtitle = match &issue.title {
            Some(title) => format!("{} · {title}", issue.key),
            None => issue.key.clone(),
        };
        let mut card = Card::new(&issue.event)
            .brand(issue.tracker.brand())
            .subtitle(subtitle);
        let mut facts = Vec::new();
        if let Some(status) = &issue.status {
            facts.push(("Status".to_owned(), status.clone()));
        }
        if let Some(priority) = &issue.priority {
            facts.push(("Priority".to_owned(), priority.clone()));
        }
        if !facts.is_empty() {
            card = card.component(Component::Facts { items: facts });
        }
        if let Some(url) = issue.url.clone() {
            card = card.action(Action::open(
                format!("Open in {}", issue.tracker.name()),
                "arrow.up.right",
                url,
            ));
        }
        let branch = branch_name(&issue.key, issue.title.as_deref());
        Some(
            card.action(Action::copy("Copy Key", "doc.on.doc", issue.key))
                .action(Action::copy(
                    "Copy Branch Name",
                    "chevron.left.forwardslash.chevron.right",
                    branch,
                )),
        )
    }

    fn actions(&self, context: &Context) -> Vec<MessageAction> {
        match issue(context) {
            Some(issue) if issue.url.is_some() => vec![MessageAction {
                tool: "open_issue",
                title: format!("Open {} in {}", issue.key, issue.tracker.name()),
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
        let url = issue(context)
            .and_then(|i| i.url)
            .ok_or(ToolError::NotApplicable("This message has no issue link."))?;
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
    fn finds_issue_keys() {
        assert_eq!(
            find_key("[ENG-123] Fix login").map(|k| k.0).as_deref(),
            Some("ENG-123")
        );
        assert_eq!(
            find_key("Re: (PROJ-7) Title").map(|k| k.0).as_deref(),
            Some("PROJ-7")
        );
        assert_eq!(find_key("utf-8 aside, a-1, A-1x").map(|k| k.0), None);
        assert_eq!(find_key("no keys here"), None);
        assert_eq!(
            branch_name("ENG-12", Some("Fix login: Safari (iOS 17)")),
            "eng-12-fix-login-safari-ios-17"
        );
    }

    #[test]
    fn linear_assignment_and_status() {
        let mail = message(
            "notifications@linear.app",
            "Linear",
            "ENG-123 Fix login on Safari",
            "Ada assigned you ENG-123\nPriority: Urgent\nhttps://linear.app/acme/issue/ENG-123/fix-login-on-safari",
        );
        let c = card(&Issues, &mail).unwrap();
        assert_eq!(c.title, "Assigned to you");
        assert_eq!(c.subtitle.as_deref(), Some("ENG-123 · Fix login on Safari"));
        assert_eq!(
            c.body,
            vec![Component::Facts {
                items: vec![("Priority".into(), "Urgent".into())]
            }]
        );
        assert_eq!(
            c.actions[0].kind,
            ActionKind::Open("https://linear.app/acme/issue/ENG-123/fix-login-on-safari".into())
        );
        assert_eq!(
            c.actions[2].kind,
            ActionKind::Copy("eng-123-fix-login-on-safari".into())
        );

        let moved = message(
            "notifications@linear.app",
            "Grace",
            "[ENG-9] Ship it",
            "Grace changed the status to In Review.",
        );
        let c = card(&Issues, &moved).unwrap();
        assert_eq!(c.title, "Moved to In Review");
        assert_eq!(c.actions[0].title, "Copy Key", "no link, so no Open action");
    }

    #[test]
    fn jira_comment_builds_site_link() {
        let mail = message(
            "jira@acme.atlassian.net",
            "Linus Torvalds (Jira)",
            "[JIRA] (PROJ-42) Crash on start",
            "Linus Torvalds commented on PROJ-42\nStill crashing.",
        );
        let c = card(&Issues, &mail).unwrap();
        assert_eq!(c.title, "Linus Torvalds commented");
        assert_eq!(c.brand, Some("jira"));
        assert_eq!(c.subtitle.as_deref(), Some("PROJ-42 · Crash on start"));
        assert_eq!(
            c.actions[0].kind,
            ActionKind::Open("https://acme.atlassian.net/browse/PROJ-42".into())
        );
        // Look-alike senders and links get nothing.
        assert!(
            card(
                &Issues,
                &message(
                    "jira@atlassian.net.evil.test",
                    "Jira",
                    "[JIRA] (PROJ-42) X",
                    ""
                )
            )
            .is_none()
        );
        let spoofed = message(
            "notifications@linear.app",
            "Linear",
            "ENG-1 X",
            "https://linear.app.evil.test/acme/issue/ENG-1",
        );
        assert!(
            card(&Issues, &spoofed)
                .unwrap()
                .actions
                .iter()
                .all(|a| !matches!(a.kind, ActionKind::Open(_)))
        );
    }
}
