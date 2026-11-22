//! The contract every plugin implements. Tool names, JSON arguments and card
//! results mirror an MCP `tools/call`, so a remote MCP transport can implement
//! the same trait without changing the host or the app.
use crate::card::{Card, ToolResult};
use crate::detect::MailText;
use chrono::NaiveDate;
use postmere_providers::Message;
use serde::Serialize;
use serde_json::{Map, Value};

pub struct Context<'a> {
    pub message: &'a Message,
    pub text: &'a MailText,
    pub settings: &'a Map<String, Value>,
    pub today: NaiveDate,
}

impl Context<'_> {
    pub fn setting_bool(&self, key: &str, default: bool) -> bool {
        self.settings
            .get(key)
            .and_then(Value::as_bool)
            .unwrap_or(default)
    }
    pub fn setting_str<'b>(&'b self, key: &str, default: &'b str) -> &'b str {
        self.settings
            .get(key)
            .and_then(Value::as_str)
            .unwrap_or(default)
    }
}

#[derive(Debug, PartialEq, Eq)]
pub enum ToolError {
    UnknownTool,
    InvalidArguments(&'static str),
    NotApplicable(&'static str),
}

pub trait Plugin: Send + Sync {
    fn manifest(&self) -> Manifest;
    /// The card shown at the top of the message, if this message is relevant.
    fn banner(&self, context: &Context) -> Option<Card>;
    /// Message actions offered in the reader's menus for this message.
    fn actions(&self, context: &Context) -> Vec<MessageAction>;
    fn call(&self, tool: &str, context: &Context, args: &Value) -> Result<ToolResult, ToolError>;
}

#[derive(Clone, Debug, Serialize)]
pub struct Manifest {
    pub id: &'static str,
    pub name: &'static str,
    pub summary: &'static str,
    pub version: u32,
    pub icon: &'static str,
    pub tint: &'static str,
    /// Services this plugin covers, for their marks in Settings.
    pub brands: Vec<&'static str>,
    pub permissions: Vec<Permission>,
    pub settings: Vec<SettingField>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Permission {
    MessageRead,
}

impl Permission {
    pub fn description(self) -> &'static str {
        match self {
            Self::MessageRead => "Reads the message you're viewing. Nothing leaves your server.",
        }
    }
}

#[derive(Clone, Debug, Serialize)]
pub struct SettingField {
    pub key: &'static str,
    pub title: &'static str,
    #[serde(flatten)]
    pub kind: SettingKind,
}

#[derive(Clone, Debug, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum SettingKind {
    Toggle {
        default: bool,
    },
    Choice {
        options: Vec<(&'static str, &'static str)>,
        default: &'static str,
    },
}

impl SettingField {
    pub fn default_value(&self) -> Value {
        match &self.kind {
            SettingKind::Toggle { default } => Value::Bool(*default),
            SettingKind::Choice { default, .. } => Value::String((*default).into()),
        }
    }
    pub fn accepts(&self, value: &Value) -> bool {
        match (&self.kind, value) {
            (SettingKind::Toggle { .. }, Value::Bool(_)) => true,
            (SettingKind::Choice { options, .. }, Value::String(s)) => {
                options.iter().any(|(key, _)| key == s)
            }
            _ => false,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct MessageAction {
    pub tool: &'static str,
    pub title: String,
    pub icon: &'static str,
    #[serde(skip_serializing_if = "Value::is_null")]
    pub args: Value,
}
