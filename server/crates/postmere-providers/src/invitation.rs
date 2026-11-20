//! Meeting requests can contain a calendar MIME alternative without a file attachment.
use crate::{Attachment, Provider, ProviderError, fetch_raw_message, stable_id};
use mail_parser::{MessageParser, MimeHeaders, PartType};
use postmere_core::AppState;
use serde_json::Value;
use uuid::Uuid;

const MAX_ICAL_BYTES: usize = 512 * 1024;

fn calendar_attachment(item: &Attachment) -> bool {
    let mime = item.mime_type.split(';').next().unwrap_or("").trim();
    mime.eq_ignore_ascii_case("text/calendar")
        || mime.eq_ignore_ascii_case("application/ics")
        || item.filename.to_ascii_lowercase().ends_with(".ics")
}

pub(super) fn add_graph_invitation(
    value: &Value,
    account: Uuid,
    id: &str,
    attachments: &mut Vec<Attachment>,
) {
    let request = value.get("@odata.type").and_then(Value::as_str)
        == Some("#microsoft.graph.eventMessageRequest")
        || matches!(
            value.get("meetingMessageType").and_then(Value::as_str),
            Some("meetingRequest" | "meetingCancelled")
        );
    if request && !attachments.iter().any(calendar_attachment) {
        attachments.push(Attachment {
            id: stable_id(account, "calendar-mime", id),
            filename: "Invitation.ics".into(),
            mime_type: "text/calendar".into(),
            size_bytes: 0,
            provider_attachment_id: None,
            inline_data_base64: None,
        });
    }
}

pub fn is_graph_mime_invitation(account: Uuid, message: &str, attachment: &Attachment) -> bool {
    attachment.provider_attachment_id.is_none()
        && attachment.inline_data_base64.is_none()
        && attachment.id == stable_id(account, "calendar-mime", message)
}

pub async fn fetch_calendar_invitation(
    state: &AppState,
    provider: Provider,
    token: &str,
    message: &str,
) -> Result<Vec<u8>, ProviderError> {
    let raw = fetch_raw_message(state, provider, token, message).await?;
    tokio::task::spawn_blocking(move || calendar_from_mime(&raw).ok_or(ProviderError::NotFound))
        .await
        .map_err(|_| ProviderError::Unavailable)?
}

fn calendar_from_mime(raw: &[u8]) -> Option<Vec<u8>> {
    let mail = MessageParser::default().parse(raw)?;
    mail.parts.iter().find_map(|part| {
        if matches!(part.body, PartType::Multipart(_) | PartType::Message(_)) {
            return None;
        }
        if !(part.is_content_type("text", "calendar")
            || part.is_content_type("application", "ics")
            || part
                .attachment_name()
                .is_some_and(|name| name.to_ascii_lowercase().ends_with(".ics")))
        {
            return None;
        }
        let bytes = part.contents();
        if bytes.len() > MAX_ICAL_BYTES || bytes.contains(&0) {
            return None;
        }
        let contents = std::str::from_utf8(bytes)
            .ok()?
            .trim_start_matches('\u{feff}');
        let calendar = contents.trim();
        if !calendar
            .lines()
            .next()?
            .eq_ignore_ascii_case("BEGIN:VCALENDAR")
            || !calendar
                .lines()
                .any(|line| line.eq_ignore_ascii_case("BEGIN:VEVENT"))
            || !calendar
                .lines()
                .last()?
                .eq_ignore_ascii_case("END:VCALENDAR")
        {
            return None;
        }
        Some(contents.as_bytes().to_owned())
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::{Engine, engine::general_purpose::STANDARD};
    use serde_json::json;
    const ICS: &str = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nMETHOD:REQUEST\r\nBEGIN:VEVENT\r\nUID:fixture\r\nDTSTART:20261120T140000Z\r\nSUMMARY:Calendar fixture\r\nEND:VEVENT\r\nEND:VCALENDAR";

    #[test]
    fn graph_request_uses_stable_mime_attachment_only_if_needed() {
        let account = Uuid::new_v4();
        let request = json!({"@odata.type":"#microsoft.graph.eventMessageRequest","id":"graph-owned","receivedDateTime":"2026-11-20T12:00:00Z"});
        let message = crate::normalize_graph(account, &request).unwrap();
        assert_eq!(message.attachments.len(), 1);
        assert!(is_graph_mime_invitation(
            account,
            "graph-owned",
            &message.attachments[0]
        ));
        assert!(!is_graph_mime_invitation(
            account,
            "unrelated",
            &message.attachments[0]
        ));
        let mut with_file = request.clone();
        with_file["attachments"] = json!([{"id":"real-attachment-id","name":"meeting.ics","contentType":"application/octet-stream","size":30}]);
        let message = crate::normalize_graph(account, &with_file).unwrap();
        assert_eq!(message.attachments.len(), 1);
        assert_eq!(
            message.attachments[0].provider_attachment_id.as_deref(),
            Some("real-attachment-id")
        );
        let mut no_invite = request;
        no_invite["@odata.type"] = json!("#microsoft.graph.message");
        assert!(
            crate::normalize_graph(account, &no_invite)
                .unwrap()
                .attachments
                .is_empty()
        );
        no_invite["@odata.type"] = json!("#microsoft.graph.eventMessageResponse");
        assert!(
            crate::normalize_graph(account, &no_invite)
                .unwrap()
                .attachments
                .is_empty()
        );
    }

    #[test]
    fn reads_transfer_decoded_calendar_alternative_or_ics_attachment_only() {
        let encoded = STANDARD.encode(ICS);
        let raw = format!(
            "MIME-Version: 1.0\r\nContent-Type: multipart/alternative; boundary=fixture\r\n\r\n--fixture\r\nContent-Type: text/plain\r\n\r\nJoin us.\r\n--fixture\r\nContent-Type: text/calendar; method=REQUEST\r\nContent-Transfer-Encoding: base64\r\n\r\n{encoded}\r\n--fixture--\r\n"
        );
        assert_eq!(calendar_from_mime(raw.as_bytes()).unwrap(), ICS.as_bytes());
        let raw = format!(
            "Content-Type: application/octet-stream\r\nContent-Disposition: attachment; filename=invite.ics\r\n\r\n{ICS}"
        );
        assert_eq!(calendar_from_mime(raw.as_bytes()).unwrap(), ICS.as_bytes());
        assert!(
            calendar_from_mime(format!("Content-Type: text/plain\r\n\r\n{ICS}").as_bytes())
                .is_none()
        );
        assert!(calendar_from_mime(b"Content-Type: text/calendar\r\n\r\nnot a calendar").is_none());
        let huge = format!(
            "Content-Type: text/calendar\r\n\r\n{}",
            ICS.replace("Calendar fixture", &"a".repeat(MAX_ICAL_BYTES))
        );
        assert!(calendar_from_mime(huge.as_bytes()).is_none());
    }
}
