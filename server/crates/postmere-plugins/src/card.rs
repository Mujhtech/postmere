//! The card vocabulary plugins use for interface. The Mac app draws every
//! component natively, so a plugin can describe content but never style it.
use serde::Serialize;
use serde_json::Value;

/// Bump when a component or field changes meaning. The app skips components it
/// does not know instead of rendering them raw.
pub const SCHEMA_VERSION: u32 = 1;

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Card {
    pub title: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub subtitle: Option<String>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub body: Vec<Component>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub actions: Vec<Action>,
}

impl Card {
    pub fn new(title: impl Into<String>) -> Self {
        Self {
            title: title.into(),
            subtitle: None,
            body: Vec::new(),
            actions: Vec::new(),
        }
    }
    pub fn subtitle(mut self, subtitle: impl Into<String>) -> Self {
        self.subtitle = Some(subtitle.into());
        self
    }
    pub fn component(mut self, component: Component) -> Self {
        self.body.push(component);
        self
    }
    pub fn action(mut self, action: Action) -> Self {
        self.actions.push(action);
        self
    }
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Component {
    Text {
        text: String,
    },
    Facts {
        items: Vec<(String, String)>,
    },
    /// Discrete steps read better than a percentage for anything with stages.
    Steps {
        labels: Vec<String>,
        current: usize,
    },
    Badge {
        label: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        tint: Option<&'static str>,
    },
    Divider,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ActionStyle {
    Primary,
    Secondary,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Action {
    pub title: String,
    pub icon: &'static str,
    pub style: ActionStyle,
    #[serde(flatten)]
    pub kind: ActionKind,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ActionKind {
    /// Open an https URL in the browser.
    Open(String),
    /// Copy text to the clipboard. Handled by the app without a round trip.
    Copy(String),
    /// Call one of the plugin's tools with arguments.
    Tool { name: String, args: Value },
}

impl Action {
    pub fn open(title: impl Into<String>, icon: &'static str, url: String) -> Self {
        Self {
            title: title.into(),
            icon,
            style: ActionStyle::Primary,
            kind: ActionKind::Open(url),
        }
    }
    pub fn copy(title: impl Into<String>, icon: &'static str, text: String) -> Self {
        Self {
            title: title.into(),
            icon,
            style: ActionStyle::Secondary,
            kind: ActionKind::Copy(text),
        }
    }
    pub fn tool(title: impl Into<String>, icon: &'static str, name: &str, args: Value) -> Self {
        Self {
            title: title.into(),
            icon,
            style: ActionStyle::Secondary,
            kind: ActionKind::Tool {
                name: name.into(),
                args,
            },
        }
    }
    pub fn secondary(mut self) -> Self {
        self.style = ActionStyle::Secondary;
        self
    }
}

/// What a tool call returns: an updated card, a short confirmation, and
/// effects the app applies locally (it owns reminders and the browser).
#[derive(Debug, Default, Serialize)]
pub struct ToolResult {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub card: Option<Card>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub toast: Option<String>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub effects: Vec<Effect>,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Effect {
    Open {
        url: String,
    },
    /// Set a follow-up reminder on the message for the morning of `date`
    /// (YYYY-MM-DD) in the user's time zone.
    Remind {
        date: String,
    },
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn cards_serialize_to_the_documented_shape() {
        let card = Card::new("Out for delivery")
            .subtitle("UPS")
            .component(Component::Steps {
                labels: vec!["Shipped".into(), "Delivered".into()],
                current: 0,
            })
            .action(Action::open(
                "Track",
                "shippingbox",
                "https://x.test".into(),
            ))
            .action(Action::tool(
                "Remind",
                "bell",
                "remind_bill",
                json!({"date": "2026-12-01"}),
            ));
        assert_eq!(
            serde_json::to_value(card).unwrap(),
            json!({
                "title": "Out for delivery",
                "subtitle": "UPS",
                "body": [{"type": "steps", "labels": ["Shipped", "Delivered"], "current": 0}],
                "actions": [
                    {"title": "Track", "icon": "shippingbox", "style": "primary", "open": "https://x.test"},
                    {"title": "Remind", "icon": "bell", "style": "secondary",
                     "tool": {"name": "remind_bill", "args": {"date": "2026-12-01"}}}
                ]
            })
        );
    }
}
