//! Test helpers shared by plugin tests.
use crate::card::Card;
use crate::detect::MailText;
use crate::plugin::{Context, MessageAction, Plugin};
use chrono::NaiveDate;
use postmere_providers::Message;
use serde_json::{Map, Value, json};

pub fn message(from: &str, name: &str, subject: &str, text: &str) -> Message {
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

pub fn run(
    plugin: &dyn Plugin,
    message: &Message,
    settings: Map<String, Value>,
) -> (Option<Card>, Vec<MessageAction>) {
    let text = MailText::new(message);
    let context = Context {
        message,
        text: &text,
        settings: &settings,
        today: NaiveDate::from_ymd_opt(2026, 11, 21).unwrap(),
    };
    (plugin.banner(&context), plugin.actions(&context))
}

pub fn card(plugin: &dyn Plugin, message: &Message) -> Option<Card> {
    run(plugin, message, Map::new()).0
}
