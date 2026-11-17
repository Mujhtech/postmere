//! Fixed-origin Google and Microsoft adapters. No provider response body or
//! credential is included in an error, log, or response to the desktop client.
use base64::{
    Engine,
    engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD},
};
use chrono::{DateTime, Duration, Utc};
use postmere_core::{AppState, config::Config, error::AppError};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use url::Url;
use uuid::Uuid;
use zeroize::{Zeroize, Zeroizing};

const GOOGLE_API: &str = "https://gmail.googleapis.com/gmail/v1/users/me/";
const GRAPH_API: &str = "https://graph.microsoft.com/v1.0/me/";
const MAX_RESPONSE: usize = 35 * 1024 * 1024;

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Provider {
    Gmail,
    Microsoft,
}

impl Provider {
    pub fn parse(value: &str) -> Result<Self, AppError> {
        match value {
            "gmail" => Ok(Self::Gmail),
            "microsoft" => Ok(Self::Microsoft),
            _ => Err(AppError::bad_request("Unknown mail provider.")),
        }
    }
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Gmail => "gmail",
            Self::Microsoft => "microsoft",
        }
    }
    fn credentials(self, config: &Config) -> Result<(&str, &str), AppError> {
        match self {
            Self::Gmail => config
                .google_client_id
                .as_deref()
                .zip(config.google_client_secret.as_deref()),
            Self::Microsoft => config
                .microsoft_client_id
                .as_deref()
                .zip(config.microsoft_client_secret.as_deref()),
        }
        .ok_or_else(AppError::unavailable)
    }
    fn token_url(self, config: &Config) -> String {
        match self {
            Self::Gmail => "https://oauth2.googleapis.com/token".into(),
            Self::Microsoft => format!(
                "https://login.microsoftonline.com/{}/oauth2/v2.0/token",
                config.microsoft_tenant
            ),
        }
    }
    pub fn redirect_uri(self, config: &Config) -> Result<String, AppError> {
        config
            .public_base_url
            .join(&format!("/v1/mail/oauth/{}/callback", self.as_str()))
            .map(|u| u.to_string())
            .map_err(|_| AppError::internal("oauth_redirect"))
    }
    pub fn authorize_url(
        self,
        config: &Config,
        state: &str,
        verifier: &str,
    ) -> Result<String, AppError> {
        self.authorize_url_with_calendar(config, state, verifier, false)
    }
    pub fn authorize_url_with_calendar(
        self,
        config: &Config,
        state: &str,
        verifier: &str,
        calendar_access: bool,
    ) -> Result<String, AppError> {
        let (client_id, _) = self.credentials(config)?;
        let base = match self {
            Self::Gmail => "https://accounts.google.com/o/oauth2/v2/auth".into(),
            Self::Microsoft => format!(
                "https://login.microsoftonline.com/{}/oauth2/v2.0/authorize",
                config.microsoft_tenant
            ),
        };
        let mut url = Url::parse(&base).map_err(|_| AppError::internal("oauth_authorize_url"))?;
        let challenge = URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes()));
        let redirect = self.redirect_uri(config)?;
        let scope = match (self, calendar_access) {
            (Self::Gmail, false) => "https://www.googleapis.com/auth/gmail.modify",
            (Self::Gmail, true) => {
                "https://www.googleapis.com/auth/gmail.modify https://www.googleapis.com/auth/calendar.events"
            }
            (Self::Microsoft, false) => "offline_access User.Read Mail.ReadWrite Mail.Send",
            (Self::Microsoft, true) => {
                "offline_access User.Read Mail.ReadWrite Mail.Send Calendars.ReadWrite"
            }
        };
        url.query_pairs_mut().extend_pairs([
            ("client_id", client_id),
            ("response_type", "code"),
            ("redirect_uri", &redirect),
            ("scope", scope),
            ("state", state),
            ("code_challenge", &challenge),
            ("code_challenge_method", "S256"),
        ]);
        if self == Self::Gmail {
            url.query_pairs_mut().extend_pairs([
                ("access_type", "offline"),
                ("prompt", "consent select_account"),
            ]);
        } else {
            url.query_pairs_mut()
                .extend_pairs([("response_mode", "query"), ("prompt", "select_account")]);
        }
        Ok(url.into())
    }
}

#[derive(Serialize, Deserialize)]
pub struct Credentials {
    pub access_token: String,
    pub refresh_token: Option<String>,
    pub expires_at: DateTime<Utc>,
    #[serde(default)]
    pub scopes: Vec<String>,
}
impl Drop for Credentials {
    fn drop(&mut self) {
        self.access_token.zeroize();
        self.refresh_token.zeroize();
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProviderError {
    Unauthorized,
    NotFound,
    Rejected,
    Unavailable,
    InvalidResponse,
    Ambiguous,
}
impl From<ProviderError> for AppError {
    fn from(value: ProviderError) -> Self {
        match value {
            ProviderError::Unauthorized => {
                AppError::conflict("Reconnect this mail account before continuing.")
            }
            ProviderError::NotFound => AppError::not_found(),
            ProviderError::Rejected => {
                AppError::bad_request("The mail provider rejected this operation.")
            }
            _ => AppError::unavailable(),
        }
    }
}

#[derive(Clone, Serialize, Deserialize, Debug, PartialEq, Eq)]
pub struct Address {
    pub name: Option<String>,
    pub email: String,
}
#[derive(Clone, Serialize, Deserialize, Debug)]
pub struct Attachment {
    pub id: Uuid,
    pub filename: String,
    pub mime_type: String,
    pub size_bytes: i64,
    pub provider_attachment_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub inline_data_base64: Option<String>,
}
#[derive(Clone, Serialize, Deserialize, Debug)]
pub struct Message {
    pub id: Uuid,
    pub account_id: Uuid,
    pub provider_message_id: String,
    pub provider_thread_id: String,
    pub subject: String,
    pub from: Address,
    pub to: Vec<Address>,
    pub cc: Vec<Address>,
    pub bcc: Vec<Address>,
    pub text_body: String,
    pub html_body: Option<String>,
    pub preview: String,
    pub sent_at: DateTime<Utc>,
    pub is_read: bool,
    pub is_starred: bool,
    pub mailbox: String,
    pub provider_labels: Vec<String>,
    pub attachments: Vec<Attachment>,
    pub list_unsubscribe: Vec<String>,
    pub list_unsubscribe_post: Vec<String>,
    #[serde(default)]
    pub authentication_results: Vec<String>,
    #[serde(default)]
    pub dkim_signatures: Vec<String>,
    #[serde(default)]
    pub rfc_message_id: Option<String>,
    #[serde(default)]
    pub in_reply_to: Option<String>,
    #[serde(default)]
    pub references: Vec<String>,
}
#[derive(Serialize)]
pub struct MessagePage {
    pub messages: Vec<Message>,
    pub next_cursor: Option<String>,
    pub has_more: bool,
}
#[derive(Clone, Deserialize, Serialize)]
pub struct SendAttachment {
    pub filename: String,
    pub mime_type: String,
    pub data_base64: String,
}
#[derive(Clone, Deserialize, Serialize)]
pub struct Outgoing {
    pub client_id: Uuid,
    pub account_id: Uuid,
    pub to: Vec<Address>,
    #[serde(default)]
    pub cc: Vec<Address>,
    #[serde(default)]
    pub bcc: Vec<Address>,
    pub subject: String,
    pub text_body: String,
    pub html_body: Option<String>,
    #[serde(default)]
    pub attachments: Vec<SendAttachment>,
    pub scheduled_at: Option<DateTime<Utc>>,
    pub undo_seconds: Option<i64>,
    #[serde(default)]
    pub track_opens: bool,
    #[serde(default)]
    pub track_links: bool,
    pub in_reply_to: Option<String>,
    #[serde(default)]
    pub references: Vec<String>,
    pub provider_thread_id: Option<String>,
}
#[derive(Deserialize)]
pub struct Mutation {
    pub is_read: Option<bool>,
    pub is_starred: Option<bool>,
    pub mailbox: Option<String>,
}
pub struct Identity {
    pub email: String,
    pub display_name: Option<String>,
}

pub async fn exchange_code(
    state: &AppState,
    provider: Provider,
    code: &str,
    verifier: &str,
) -> Result<Credentials, AppError> {
    let (client_id, client_secret) = provider.credentials(&state.config)?;
    let redirect = provider.redirect_uri(&state.config)?;
    let response = state
        .http
        .post(provider.token_url(&state.config))
        .form(&[
            ("grant_type", "authorization_code"),
            ("code", code),
            ("client_id", client_id),
            ("client_secret", client_secret),
            ("redirect_uri", &redirect),
            ("code_verifier", verifier),
        ])
        .send()
        .await
        .map_err(|_| AppError::unavailable())?;
    let value = read_json(response).await?;
    parse_tokens(value, None).map_err(Into::into)
}

pub async fn refresh(
    state: &AppState,
    provider: Provider,
    credentials: &Credentials,
) -> Result<Credentials, AppError> {
    let refresh = credentials
        .refresh_token
        .as_deref()
        .ok_or(ProviderError::Unauthorized)?;
    let (client_id, client_secret) = provider.credentials(&state.config)?;
    let response = state
        .http
        .post(provider.token_url(&state.config))
        .form(&[
            ("grant_type", "refresh_token"),
            ("refresh_token", refresh),
            ("client_id", client_id),
            ("client_secret", client_secret),
        ])
        .send()
        .await
        .map_err(|_| AppError::unavailable())?;
    let value = read_json(response).await?;
    let mut refreshed = parse_tokens(value, Some(refresh))?;
    if refreshed.scopes.is_empty() {
        refreshed.scopes = credentials.scopes.clone();
    }
    Ok(refreshed)
}

fn parse_tokens(
    value: Value,
    existing_refresh: Option<&str>,
) -> Result<Credentials, ProviderError> {
    let access = value
        .get("access_token")
        .and_then(Value::as_str)
        .filter(|t| !t.is_empty() && t.len() < 32_768)
        .ok_or(ProviderError::InvalidResponse)?
        .to_owned();
    let refresh = value
        .get("refresh_token")
        .and_then(Value::as_str)
        .filter(|t| !t.is_empty() && t.len() < 32_768)
        .or(existing_refresh)
        .map(str::to_owned);
    let seconds = value
        .get("expires_in")
        .and_then(Value::as_i64)
        .filter(|s| *s > 0 && *s < 604_800)
        .ok_or(ProviderError::InvalidResponse)?;
    let scopes = value
        .get("scope")
        .and_then(Value::as_str)
        .unwrap_or("")
        .split_whitespace()
        .map(str::to_owned)
        .collect();
    Ok(Credentials {
        access_token: access,
        refresh_token: refresh,
        expires_at: Utc::now() + Duration::seconds(seconds),
        scopes,
    })
}
pub fn has_calendar_scope(provider: Provider, credentials: &Credentials) -> bool {
    credentials.scopes.iter().any(|s| match provider {
        Provider::Gmail => {
            s == "https://www.googleapis.com/auth/calendar.events"
                || s == "https://www.googleapis.com/auth/calendar"
        }
        Provider::Microsoft => {
            s.eq_ignore_ascii_case("Calendars.ReadWrite")
                || s.eq_ignore_ascii_case("https://graph.microsoft.com/Calendars.ReadWrite")
        }
    })
}

pub async fn identity(
    state: &AppState,
    provider: Provider,
    token: &str,
) -> Result<Identity, ProviderError> {
    let url = match provider {
        Provider::Gmail => format!("{GOOGLE_API}profile"),
        Provider::Microsoft => format!("{GRAPH_API}?$select=mail,userPrincipalName,displayName"),
    };
    let value = request_json(state.http.get(url).bearer_auth(token)).await?;
    let email = match provider {
        Provider::Gmail => value.get("emailAddress").and_then(Value::as_str),
        Provider::Microsoft => value
            .get("mail")
            .and_then(Value::as_str)
            .or_else(|| value.get("userPrincipalName").and_then(Value::as_str)),
    }
    .filter(|s| valid_email(s))
    .ok_or(ProviderError::InvalidResponse)?
    .to_lowercase();
    Ok(Identity {
        email,
        display_name: value
            .get("displayName")
            .and_then(Value::as_str)
            .map(str::to_owned),
    })
}

pub async fn fetch_page(
    state: &AppState,
    provider: Provider,
    account: Uuid,
    token: &str,
    query: Option<&str>,
    cursor: Option<&str>,
    limit: usize,
) -> Result<MessagePage, ProviderError> {
    let limit = limit.clamp(1, 50);
    let mut url = Url::parse(match provider {
        Provider::Gmail => GOOGLE_API,
        Provider::Microsoft => GRAPH_API,
    })
    .map_err(|_| ProviderError::InvalidResponse)?
    .join("messages")
    .map_err(|_| ProviderError::InvalidResponse)?;
    match provider {
        Provider::Gmail => {
            url.query_pairs_mut()
                .append_pair("maxResults", &limit.to_string())
                .append_pair("includeSpamTrash", "true");
            if let Some(q) = query {
                url.query_pairs_mut().append_pair("q", q);
            }
            if let Some(c) = cursor {
                if c.len() > 8_192 {
                    return Err(ProviderError::Rejected);
                }
                url.query_pairs_mut().append_pair("pageToken", c);
            }
        }
        Provider::Microsoft => {
            if let Some(cursor) = cursor {
                url = validated_graph_cursor(cursor)?;
            } else {
                url.query_pairs_mut()
                    .append_pair("$top", &limit.to_string())
                    .append_pair("$select", "id");
                if let Some(q) = query {
                    url.query_pairs_mut().append_pair(
                        "$search",
                        &format!("\"{}\"", q.replace('\\', "\\\\").replace('"', "\\\"")),
                    );
                } else {
                    url.query_pairs_mut()
                        .append_pair("$orderby", "receivedDateTime desc");
                }
            }
        }
    }
    let request = state.http.get(url).bearer_auth(token);
    let value = request_json(if provider == Provider::Microsoft {
        request.header("Prefer", "IdType=\"ImmutableId\"")
    } else {
        request
    })
    .await?;
    page_from_value(state, provider, account, token, value, limit).await
}

async fn page_from_value(
    state: &AppState,
    provider: Provider,
    account: Uuid,
    token: &str,
    value: Value,
    limit: usize,
) -> Result<MessagePage, ProviderError> {
    let rows = value
        .get(if provider == Provider::Gmail {
            "messages"
        } else {
            "value"
        })
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let mut messages = Vec::with_capacity(rows.len());
    let ids = rows
        .into_iter()
        .take(limit)
        .map(|r| {
            r.get("id")
                .and_then(Value::as_str)
                .map(str::to_owned)
                .ok_or(ProviderError::InvalidResponse)
        })
        .collect::<Result<Vec<_>, _>>()?;
    // Five fixed-origin requests at a time bound both total work and latency.
    for chunk in ids.chunks(5) {
        let mut tasks = tokio::task::JoinSet::new();
        for id in chunk {
            let state = state.clone();
            let token = Zeroizing::new(token.to_owned());
            let id = id.clone();
            tasks.spawn(async move { fetch_message(&state, provider, account, &token, &id).await });
        }
        while let Some(result) = tasks.join_next().await {
            match result.map_err(|_| ProviderError::Unavailable)? {
                Ok(message) => messages.push(message),
                Err(ProviderError::NotFound) => {}
                Err(error) => return Err(error),
            }
        }
    }
    messages.sort_by(|a, b| b.sent_at.cmp(&a.sent_at).then_with(|| b.id.cmp(&a.id)));
    let next_cursor = value
        .get(if provider == Provider::Gmail {
            "nextPageToken"
        } else {
            "@odata.nextLink"
        })
        .and_then(Value::as_str)
        .map(str::to_owned);
    if provider == Provider::Microsoft {
        if let Some(c) = &next_cursor {
            validated_graph_cursor(c)?;
        }
    }
    Ok(MessagePage {
        has_more: next_cursor.is_some(),
        next_cursor,
        messages,
    })
}

fn validated_graph_cursor(cursor: &str) -> Result<Url, ProviderError> {
    let url = Url::parse(cursor).map_err(|_| ProviderError::Rejected)?;
    if cursor.len() > 16_384
        || url.scheme() != "https"
        || url.host_str() != Some("graph.microsoft.com")
        || url.port_or_known_default() != Some(443)
        || !url.username().is_empty()
        || url.password().is_some()
        || url.fragment().is_some()
        || url.path() != "/v1.0/me/messages"
    {
        return Err(ProviderError::Rejected);
    }
    Ok(url)
}

fn message_url(provider: Provider, id: &str, suffix: Option<&str>) -> Result<Url, ProviderError> {
    if id.is_empty() || id.len() > 4_096 {
        return Err(ProviderError::Rejected);
    }
    let mut url = Url::parse(match provider {
        Provider::Gmail => GOOGLE_API,
        Provider::Microsoft => GRAPH_API,
    })
    .map_err(|_| ProviderError::InvalidResponse)?;
    {
        let mut path = url
            .path_segments_mut()
            .map_err(|_| ProviderError::InvalidResponse)?;
        path.pop_if_empty().push("messages").push(id);
        if let Some(suffix) = suffix {
            path.push(suffix);
        }
    }
    Ok(url)
}

pub async fn fetch_message(
    state: &AppState,
    provider: Provider,
    account: Uuid,
    token: &str,
    id: &str,
) -> Result<Message, ProviderError> {
    let mut url = message_url(provider, id, None)?;
    if provider == Provider::Gmail {
        url.query_pairs_mut().append_pair("format", "full");
    } else {
        url.query_pairs_mut().append_pair("$select","id,conversationId,internetMessageId,subject,from,toRecipients,ccRecipients,bccRecipients,body,bodyPreview,receivedDateTime,sentDateTime,isRead,flag,isDraft,parentFolderId,internetMessageHeaders").append_pair("$expand","attachments($select=id,name,contentType,size,isInline)");
    }
    let request = state.http.get(url).bearer_auth(token);
    let value = request_json(if provider == Provider::Microsoft {
        request.header("Prefer", "IdType=\"ImmutableId\"")
    } else {
        request
    })
    .await?;
    match provider {
        Provider::Gmail => normalize_gmail(account, &value),
        Provider::Microsoft => normalize_graph(account, &value),
    }
}

/// Fetch the provider's exact RFC 5322 bytes only for cryptographic verification.
/// The caller supplies an owned provider message ID, never a URL.
pub async fn fetch_raw_message(
    state: &AppState,
    provider: Provider,
    token: &str,
    id: &str,
) -> Result<Zeroizing<Vec<u8>>, ProviderError> {
    const RAW_LIMIT: usize = 8 * 1024 * 1024;
    let mut url = message_url(
        provider,
        id,
        if provider == Provider::Microsoft {
            Some("$value")
        } else {
            None
        },
    )?;
    if provider == Provider::Gmail {
        url.query_pairs_mut().append_pair("format", "raw");
    }
    let mut request = state.http.get(url).bearer_auth(token);
    if provider == Provider::Microsoft {
        request = request.header("Prefer", "IdType=\"ImmutableId\"");
    }
    let response = request
        .send()
        .await
        .map_err(|_| ProviderError::Unavailable)?;
    let bytes = read_bytes(
        response,
        if provider == Provider::Gmail {
            12 * 1024 * 1024
        } else {
            RAW_LIMIT
        },
    )
    .await?;
    if provider == Provider::Microsoft {
        return Ok(bytes);
    }
    let value: Value =
        serde_json::from_slice(&bytes).map_err(|_| ProviderError::InvalidResponse)?;
    if value.get("id").and_then(Value::as_str) != Some(id) {
        return Err(ProviderError::InvalidResponse);
    }
    let raw = value
        .get("raw")
        .and_then(Value::as_str)
        .ok_or(ProviderError::InvalidResponse)?;
    let decoded = Zeroizing::new(decode_urlsafe(raw)?);
    if decoded.len() > RAW_LIMIT {
        return Err(ProviderError::InvalidResponse);
    }
    Ok(decoded)
}

pub async fn fetch_attachment(
    state: &AppState,
    provider: Provider,
    token: &str,
    message: &str,
    attachment: &str,
) -> Result<Vec<u8>, ProviderError> {
    let mut url = message_url(provider, message, Some("attachments"))?;
    url.path_segments_mut()
        .map_err(|_| ProviderError::InvalidResponse)?
        .push(attachment);
    let value = request_json(state.http.get(url).bearer_auth(token)).await?;
    let encoded = value
        .get(if provider == Provider::Gmail {
            "data"
        } else {
            "contentBytes"
        })
        .and_then(Value::as_str)
        .ok_or(ProviderError::InvalidResponse)?;
    if encoded.len() > 34 * 1024 * 1024 {
        return Err(ProviderError::Rejected);
    }
    if provider == Provider::Gmail {
        decode_urlsafe(encoded)
    } else {
        STANDARD
            .decode(encoded)
            .map_err(|_| ProviderError::InvalidResponse)
    }
}

pub async fn mutate(
    state: &AppState,
    provider: Provider,
    token: &str,
    id: &str,
    mutation: &Mutation,
) -> Result<Option<String>, ProviderError> {
    if let Some(mailbox) = &mutation.mailbox {
        if !["inbox", "archive", "trash"].contains(&mailbox.as_str()) {
            return Err(ProviderError::Rejected);
        }
    }
    if provider == Provider::Gmail {
        let mut add = vec![];
        let mut remove = vec![];
        if let Some(read) = Some(mutation.is_read).flatten() {
            if read {
                remove.push("UNREAD")
            } else {
                add.push("UNREAD")
            }
        }
        if let Some(star) = Some(mutation.is_starred).flatten() {
            if star {
                add.push("STARRED")
            } else {
                remove.push("STARRED")
            }
        }
        if let Some(mailbox) = &mutation.mailbox {
            match mailbox.as_str() {
                "inbox" => {
                    add.push("INBOX");
                    remove.push("TRASH");
                }
                "archive" => {
                    remove.extend(["INBOX", "TRASH"]);
                }
                "trash" => {
                    add.push("TRASH");
                    remove.push("INBOX");
                }
                _ => {}
            }
        }
        request_json(
            state
                .http
                .post(message_url(provider, id, Some("modify"))?)
                .bearer_auth(token)
                .json(&json!({"addLabelIds":add,"removeLabelIds":remove})),
        )
        .await?;
        Ok(None)
    } else {
        let mut patch = serde_json::Map::new();
        if let Some(read) = mutation.is_read {
            patch.insert("isRead".into(), json!(read));
        }
        if let Some(star) = mutation.is_starred {
            patch.insert(
                "flag".into(),
                json!({"flagStatus":if star{"flagged"}else{"notFlagged"}}),
            );
        }
        if !patch.is_empty() {
            request_json(
                state
                    .http
                    .patch(message_url(provider, id, None)?)
                    .bearer_auth(token)
                    .json(&patch),
            )
            .await?;
        }
        if let Some(mailbox) = &mutation.mailbox {
            let destination = match mailbox.as_str() {
                "inbox" => "inbox",
                "archive" => "archive",
                _ => "deleteditems",
            };
            let value = request_json(
                state
                    .http
                    .post(message_url(provider, id, Some("move"))?)
                    .bearer_auth(token)
                    .json(&json!({"destinationId":destination})),
            )
            .await?;
            return Ok(value.get("id").and_then(Value::as_str).map(str::to_owned));
        }
        Ok(None)
    }
}

/// A network error after send begins is ambiguous. The durable queue must never
/// retry it automatically, because either provider may already have accepted it.
pub async fn send(
    state: &AppState,
    provider: Provider,
    token: &str,
    from: &str,
    outgoing: &Outgoing,
) -> Result<Option<String>, ProviderError> {
    let request = match provider {
        Provider::Gmail => {
            let mut payload = json!({"raw":URL_SAFE_NO_PAD.encode(build_mime(from,outgoing)?)});
            if let Some(thread) = &outgoing.provider_thread_id {
                payload["threadId"] = json!(thread)
            }
            state
                .http
                .post(format!("{GOOGLE_API}messages/send"))
                .bearer_auth(token)
                .json(&payload)
        }
        Provider::Microsoft => {
            // Graph MIME mode preserves standard reply headers; its JSON
            // internetMessageHeaders property supports custom X- headers only.
            state
                .http
                .post(format!("{GRAPH_API}sendMail"))
                .bearer_auth(token)
                .header(reqwest::header::CONTENT_TYPE, "text/plain")
                .body(STANDARD.encode(build_mime(from, outgoing)?))
        }
    };
    let response = request.send().await.map_err(|_| ProviderError::Ambiguous)?;
    if response.status().is_client_error() {
        return Err(if response.status().as_u16() == 401 {
            ProviderError::Unauthorized
        } else {
            ProviderError::Rejected
        });
    }
    if !response.status().is_success() {
        return Err(ProviderError::Ambiguous);
    }
    if provider == Provider::Microsoft {
        return Ok(None);
    }
    let value = read_json(response)
        .await
        .map_err(|_| ProviderError::Ambiguous)?;
    Ok(value.get("id").and_then(Value::as_str).map(str::to_owned))
}

async fn request_json(request: reqwest::RequestBuilder) -> Result<Value, ProviderError> {
    read_json(
        request
            .send()
            .await
            .map_err(|_| ProviderError::Unavailable)?,
    )
    .await
}
async fn read_json(response: reqwest::Response) -> Result<Value, ProviderError> {
    let bytes = read_bytes(response, MAX_RESPONSE).await?;
    serde_json::from_slice(&bytes).map_err(|_| ProviderError::InvalidResponse)
}
async fn read_bytes(
    mut response: reqwest::Response,
    limit: usize,
) -> Result<Zeroizing<Vec<u8>>, ProviderError> {
    match response.status().as_u16() {
        200..=299 => {}
        401 | 403 => return Err(ProviderError::Unauthorized),
        404 => return Err(ProviderError::NotFound),
        429 | 500..=599 => return Err(ProviderError::Unavailable),
        _ => return Err(ProviderError::Rejected),
    }
    if response.content_length().is_some_and(|n| n > limit as u64) {
        return Err(ProviderError::InvalidResponse);
    }
    let mut bytes = Zeroizing::new(Vec::new());
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|_| ProviderError::Unavailable)?
    {
        if bytes.len() + chunk.len() > limit {
            return Err(ProviderError::InvalidResponse);
        }
        bytes.extend_from_slice(&chunk);
    }
    Ok(bytes)
}

pub fn valid_email(value: &str) -> bool {
    if value.is_empty()
        || value.len() > 254
        || value
            .chars()
            .any(|c| c.is_control() || c.is_whitespace() || "<>(),;:\\\"".contains(c))
    {
        return false;
    }
    let mut parts = value.split('@');
    let local = parts.next().unwrap_or("");
    let domain = parts.next().unwrap_or("");
    !local.is_empty()
        && !domain.is_empty()
        && domain.contains('.')
        && !domain.starts_with('.')
        && !domain.ends_with('.')
        && parts.next().is_none()
}

fn stable_id(account: Uuid, kind: &str, id: &str) -> Uuid {
    let mut hash = Sha256::new();
    hash.update(account.as_bytes());
    hash.update(kind.as_bytes());
    hash.update([0]);
    hash.update(id.as_bytes());
    let digest = hash.finalize();
    let mut bytes = [0_u8; 16];
    bytes.copy_from_slice(&digest[..16]);
    Uuid::from_bytes(bytes)
}

fn header_values(value: &Value, name: &str) -> Vec<String> {
    value
        .get("headers")
        .and_then(Value::as_array)
        .map(|headers| {
            headers
                .iter()
                .filter(|h| {
                    h.get("name")
                        .and_then(Value::as_str)
                        .is_some_and(|n| n.eq_ignore_ascii_case(name))
                })
                .filter_map(|h| h.get("value").and_then(Value::as_str).map(str::to_owned))
                .collect()
        })
        .unwrap_or_default()
}
fn decoded_header(value: &str) -> String {
    let raw = format!("X: {value}");
    mailparse::parse_header(raw.as_bytes())
        .map(|(h, _)| h.get_value())
        .unwrap_or_else(|_| value.to_owned())
}
fn parse_addresses(value: &str) -> Vec<Address> {
    let Ok(list) = mailparse::addrparse(value) else {
        return vec![];
    };
    list.iter()
        .flat_map(|address| match address {
            mailparse::MailAddr::Single(a) => vec![Address {
                name: a.display_name.clone(),
                email: a.addr.clone(),
            }],
            mailparse::MailAddr::Group(g) => g
                .addrs
                .iter()
                .map(|a| Address {
                    name: a.display_name.clone(),
                    email: a.addr.clone(),
                })
                .collect(),
        })
        .collect()
}
fn decode_urlsafe(value: &str) -> Result<Vec<u8>, ProviderError> {
    URL_SAFE_NO_PAD
        .decode(value.trim_end_matches('='))
        .map_err(|_| ProviderError::InvalidResponse)
}

pub fn normalize_gmail(account: Uuid, value: &Value) -> Result<Message, ProviderError> {
    let id = value
        .get("id")
        .and_then(Value::as_str)
        .ok_or(ProviderError::InvalidResponse)?;
    let payload = value.get("payload").ok_or(ProviderError::InvalidResponse)?;
    let header = |name| header_values(payload, name).join(", ");
    let labels: Vec<String> = value
        .get("labelIds")
        .and_then(Value::as_array)
        .map(|a| {
            a.iter()
                .filter_map(Value::as_str)
                .map(str::to_owned)
                .collect()
        })
        .unwrap_or_default();
    let has = |label: &str| labels.iter().any(|s| s == label);
    let mailbox = if has("TRASH") {
        "trash"
    } else if has("DRAFT") {
        "drafts"
    } else if has("SENT") {
        "sent"
    } else if has("INBOX") {
        "inbox"
    } else {
        "archive"
    };
    let timestamp = value
        .get("internalDate")
        .and_then(Value::as_str)
        .and_then(|s| s.parse::<i64>().ok())
        .and_then(DateTime::from_timestamp_millis)
        .or_else(|| {
            DateTime::parse_from_rfc2822(&header("Date"))
                .ok()
                .map(|d| d.with_timezone(&Utc))
        })
        .ok_or(ProviderError::InvalidResponse)?;
    let mut text = String::new();
    let mut html = String::new();
    let mut attachments = vec![];
    gmail_parts(
        account,
        id,
        payload,
        &mut text,
        &mut html,
        &mut attachments,
        0,
    )?;
    Ok(Message {
        id: stable_id(account, "message", id),
        account_id: account,
        provider_message_id: id.into(),
        provider_thread_id: value
            .get("threadId")
            .and_then(Value::as_str)
            .unwrap_or(id)
            .into(),
        subject: decoded_header(&header("Subject")),
        from: parse_addresses(&header("From"))
            .into_iter()
            .next()
            .unwrap_or(Address {
                name: None,
                email: String::new(),
            }),
        to: parse_addresses(&header("To")),
        cc: parse_addresses(&header("Cc")),
        bcc: parse_addresses(&header("Bcc")),
        text_body: text,
        html_body: (!html.is_empty()).then_some(html),
        preview: value
            .get("snippet")
            .and_then(Value::as_str)
            .unwrap_or("")
            .into(),
        sent_at: timestamp,
        is_read: !has("UNREAD"),
        is_starred: has("STARRED"),
        mailbox: mailbox.into(),
        provider_labels: labels,
        attachments,
        list_unsubscribe: header_values(payload, "List-Unsubscribe"),
        list_unsubscribe_post: header_values(payload, "List-Unsubscribe-Post"),
        authentication_results: header_values(payload, "Authentication-Results"),
        dkim_signatures: header_values(payload, "DKIM-Signature"),
        rfc_message_id: message_ids(&header("Message-ID")).into_iter().next(),
        in_reply_to: message_ids(&header("In-Reply-To")).into_iter().next(),
        references: message_ids(&header("References")),
    })
}

fn gmail_parts(
    account: Uuid,
    message: &str,
    part: &Value,
    text: &mut String,
    html: &mut String,
    attachments: &mut Vec<Attachment>,
    depth: usize,
) -> Result<(), ProviderError> {
    if depth > 40 {
        return Err(ProviderError::InvalidResponse);
    }
    let mime = part
        .get("mimeType")
        .and_then(Value::as_str)
        .unwrap_or("application/octet-stream");
    let filename = part.get("filename").and_then(Value::as_str).unwrap_or("");
    let body = part.get("body").unwrap_or(&Value::Null);
    if !filename.is_empty() {
        let provider_id = body
            .get("attachmentId")
            .and_then(Value::as_str)
            .map(str::to_owned);
        let part_id = part
            .get("partId")
            .and_then(Value::as_str)
            .unwrap_or(filename);
        attachments.push(Attachment {
            id: stable_id(account, "attachment", &format!("{message}:{part_id}")),
            filename: decoded_header(filename),
            mime_type: mime.into(),
            size_bytes: body.get("size").and_then(Value::as_i64).unwrap_or(0),
            provider_attachment_id: provider_id,
            inline_data_base64: body.get("data").and_then(Value::as_str).map(str::to_owned),
        });
    } else if let Some(encoded) = body.get("data").and_then(Value::as_str) {
        let bytes = decode_urlsafe(encoded)?;
        let content = String::from_utf8_lossy(&bytes);
        if mime.eq_ignore_ascii_case("text/plain") {
            if !text.is_empty() {
                text.push('\n')
            }
            text.push_str(&content)
        } else if mime.eq_ignore_ascii_case("text/html") {
            html.push_str(&content)
        }
    }
    if let Some(parts) = part.get("parts").and_then(Value::as_array) {
        for child in parts {
            gmail_parts(account, message, child, text, html, attachments, depth + 1)?
        }
    }
    Ok(())
}

fn graph_addresses(value: Option<&Value>) -> Vec<Address> {
    value
        .and_then(Value::as_array)
        .map(|a| {
            a.iter()
                .filter_map(|v| graph_address(v.get("emailAddress")))
                .collect()
        })
        .unwrap_or_default()
}
fn graph_address(value: Option<&Value>) -> Option<Address> {
    let v = value?;
    Some(Address {
        name: v.get("name").and_then(Value::as_str).map(str::to_owned),
        email: v.get("address").and_then(Value::as_str)?.into(),
    })
}

pub fn normalize_graph(account: Uuid, value: &Value) -> Result<Message, ProviderError> {
    let id = value
        .get("id")
        .and_then(Value::as_str)
        .ok_or(ProviderError::InvalidResponse)?;
    let sent = value
        .get("receivedDateTime")
        .or_else(|| value.get("sentDateTime"))
        .and_then(Value::as_str)
        .and_then(|s| DateTime::parse_from_rfc3339(s).ok())
        .map(|d| d.with_timezone(&Utc))
        .ok_or(ProviderError::InvalidResponse)?;
    let body = value.get("body").unwrap_or(&Value::Null);
    let content = body.get("content").and_then(Value::as_str).unwrap_or("");
    let is_html = body
        .get("contentType")
        .and_then(Value::as_str)
        .is_some_and(|s| s.eq_ignore_ascii_case("html"));
    let preview = value
        .get("bodyPreview")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_owned();
    let attachments = value
        .get("attachments")
        .and_then(Value::as_array)
        .map(|a| {
            a.iter()
                .filter_map(|a| {
                    let aid = a.get("id").and_then(Value::as_str)?;
                    Some(Attachment {
                        id: stable_id(account, "attachment", &format!("{id}:{aid}")),
                        filename: a
                            .get("name")
                            .and_then(Value::as_str)
                            .unwrap_or("Attachment")
                            .into(),
                        mime_type: a
                            .get("contentType")
                            .and_then(Value::as_str)
                            .unwrap_or("application/octet-stream")
                            .into(),
                        size_bytes: a.get("size").and_then(Value::as_i64).unwrap_or(0),
                        provider_attachment_id: Some(aid.into()),
                        inline_data_base64: None,
                    })
                })
                .collect()
        })
        .unwrap_or_default();
    let headers =
        json!({"headers":value.get("internetMessageHeaders").cloned().unwrap_or(json!([]))});
    // Graph folder IDs are opaque. The sync layer resolves known folder IDs;
    // draft state can be classified without a folder lookup.
    let mailbox = if value.get("isDraft").and_then(Value::as_bool) == Some(true) {
        "drafts"
    } else {
        "archive"
    };
    Ok(Message {
        id: stable_id(account, "message", id),
        account_id: account,
        provider_message_id: id.into(),
        provider_thread_id: value
            .get("conversationId")
            .and_then(Value::as_str)
            .unwrap_or(id)
            .into(),
        subject: value
            .get("subject")
            .and_then(Value::as_str)
            .unwrap_or("")
            .into(),
        from: graph_address(value.get("from").and_then(|v| v.get("emailAddress"))).unwrap_or(
            Address {
                name: None,
                email: String::new(),
            },
        ),
        to: graph_addresses(value.get("toRecipients")),
        cc: graph_addresses(value.get("ccRecipients")),
        bcc: graph_addresses(value.get("bccRecipients")),
        text_body: if is_html {
            preview.clone()
        } else {
            content.into()
        },
        html_body: is_html.then(|| content.into()),
        preview,
        sent_at: sent,
        is_read: value
            .get("isRead")
            .and_then(Value::as_bool)
            .unwrap_or(false),
        is_starred: value
            .get("flag")
            .and_then(|v| v.get("flagStatus"))
            .and_then(Value::as_str)
            == Some("flagged"),
        mailbox: mailbox.into(),
        provider_labels: value
            .get("parentFolderId")
            .and_then(Value::as_str)
            .map(|s| vec![s.into()])
            .unwrap_or_default(),
        attachments,
        list_unsubscribe: header_values(&headers, "List-Unsubscribe"),
        list_unsubscribe_post: header_values(&headers, "List-Unsubscribe-Post"),
        authentication_results: header_values(&headers, "Authentication-Results"),
        dkim_signatures: header_values(&headers, "DKIM-Signature"),
        rfc_message_id: value
            .get("internetMessageId")
            .and_then(Value::as_str)
            .filter(|s| valid_message_id(s))
            .map(str::to_owned),
        in_reply_to: message_ids(&header_values(&headers, "In-Reply-To").join(" "))
            .into_iter()
            .next(),
        references: message_ids(&header_values(&headers, "References").join(" ")),
    })
}

pub async fn graph_folders(
    state: &AppState,
    token: &str,
) -> Result<Vec<(String, String)>, ProviderError> {
    let mut result = vec![];
    for (name, mailbox) in [
        ("inbox", "inbox"),
        ("sentitems", "sent"),
        ("drafts", "drafts"),
        ("deleteditems", "trash"),
        ("archive", "archive"),
    ] {
        let value = request_json(
            state
                .http
                .get(format!("{GRAPH_API}mailFolders/{name}?$select=id"))
                .bearer_auth(token),
        )
        .await?;
        if let Some(id) = value.get("id").and_then(Value::as_str) {
            result.push((id.into(), mailbox.into()))
        }
    }
    Ok(result)
}

pub fn build_mime(from: &str, message: &Outgoing) -> Result<Vec<u8>, ProviderError> {
    if !valid_email(from) {
        return Err(ProviderError::Rejected);
    }
    fn header(value: &str) -> String {
        format!("=?UTF-8?B?{}?=", STANDARD.encode(value))
    }
    fn recipients(values: &[Address]) -> Result<String, ProviderError> {
        values
            .iter()
            .map(|a| {
                if !valid_email(&a.email) {
                    return Err(ProviderError::Rejected);
                }
                Ok(match &a.name {
                    Some(n) if !n.is_empty() => format!("{} <{}>", header(n), a.email),
                    _ => a.email.clone(),
                })
            })
            .collect::<Result<Vec<_>, _>>()
            .map(|v| v.join(",\r\n "))
    }
    fn encoded(bytes: &[u8]) -> String {
        STANDARD
            .encode(bytes)
            .as_bytes()
            .chunks(76)
            .map(|c| String::from_utf8_lossy(c).into_owned())
            .collect::<Vec<_>>()
            .join("\r\n")
    }
    let mixed = format!("postmere-mixed-{}", Uuid::new_v4());
    let alt = format!("postmere-alt-{}", Uuid::new_v4());
    let mut mime = format!(
        "From: {from}\r\nTo: {}\r\nSubject: {}\r\nDate: {}\r\nMessage-ID: <{}@postmere.local>\r\nMIME-Version: 1.0\r\n",
        recipients(&message.to)?,
        header(&message.subject),
        Utc::now().to_rfc2822(),
        message.client_id
    );
    if let Some(id) = &message.in_reply_to {
        if !valid_message_id(id) {
            return Err(ProviderError::Rejected);
        }
        mime.push_str(&format!("In-Reply-To: {id}\r\n"));
    }
    if !message.references.is_empty() {
        if message.references.len() > 100
            || message.references.iter().any(|id| !valid_message_id(id))
        {
            return Err(ProviderError::Rejected);
        }
        mime.push_str(&format!(
            "References: {}\r\n",
            message.references.join("\r\n ")
        ));
    }
    if !message.cc.is_empty() {
        mime.push_str(&format!("Cc: {}\r\n", recipients(&message.cc)?))
    }
    if !message.bcc.is_empty() {
        mime.push_str(&format!("Bcc: {}\r\n", recipients(&message.bcc)?))
    }
    mime.push_str(&format!("Content-Type: multipart/mixed; boundary=\"{mixed}\"\r\n\r\n--{mixed}\r\nContent-Type: multipart/alternative; boundary=\"{alt}\"\r\n\r\n--{alt}\r\nContent-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\n\r\n{}\r\n",encoded(message.text_body.as_bytes())));
    if let Some(html) = &message.html_body {
        mime.push_str(&format!("--{alt}\r\nContent-Type: text/html; charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\n\r\n{}\r\n",encoded(html.as_bytes())))
    }
    mime.push_str(&format!("--{alt}--\r\n"));
    for attachment in &message.attachments {
        if !valid_mime_type(&attachment.mime_type) {
            return Err(ProviderError::Rejected);
        }
        let bytes = STANDARD
            .decode(&attachment.data_base64)
            .map_err(|_| ProviderError::Rejected)?;
        let filename = url::form_urlencoded::byte_serialize(attachment.filename.as_bytes())
            .collect::<String>();
        mime.push_str(&format!("--{mixed}\r\nContent-Type: {}\r\nContent-Disposition: attachment; filename*=UTF-8''{filename}\r\nContent-Transfer-Encoding: base64\r\n\r\n{}\r\n",attachment.mime_type,encoded(&bytes)));
    }
    mime.push_str(&format!("--{mixed}--\r\n"));
    Ok(mime.into_bytes())
}
pub fn valid_mime_type(value: &str) -> bool {
    !value.is_empty()
        && value.len() < 128
        && value.contains('/')
        && value
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || b"/-+._".contains(&c))
}
pub fn valid_message_id(value: &str) -> bool {
    value.len() >= 5
        && value.len() <= 254
        && value.starts_with('<')
        && value.ends_with('>')
        && value[1..value.len() - 1].contains('@')
        && value[1..value.len() - 1]
            .bytes()
            .all(|b| b.is_ascii_graphic() && b != b'<' && b != b'>')
}
fn message_ids(value: &str) -> Vec<String> {
    value
        .split_whitespace()
        .filter(|s| valid_message_id(s))
        .take(100)
        .map(str::to_owned)
        .collect()
}

#[derive(Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct SyncCheckpoint {
    pub phase: String,
    pub cursor: Option<String>,
    pub history_id: Option<String>,
    pub initial_history_id: Option<String>,
    pub pending_ids: Vec<String>,
    pub pending_deleted: Vec<String>,
    pub resume_cursor: Option<String>,
    pub target_history_id: Option<String>,
    pub modified_after: Option<DateTime<Utc>>,
    pub scan_started_at: Option<DateTime<Utc>>,
}
pub struct SyncBatch {
    pub messages: Vec<Message>,
    pub deleted_ids: Vec<String>,
    pub checkpoint: SyncCheckpoint,
    pub has_more: bool,
}

/// Gmail uses a full bootstrap followed by provider history. Microsoft uses a
/// lastModifiedDateTime watermark with overlap; exact cached IDs are separately
/// verified by the worker before any deletion is recorded.
pub async fn sync_batch(
    state: &AppState,
    provider: Provider,
    account: Uuid,
    token: &str,
    mut checkpoint: SyncCheckpoint,
    limit: usize,
) -> Result<SyncBatch, ProviderError> {
    let limit = limit.clamp(1, 25);
    if provider == Provider::Microsoft {
        if checkpoint.scan_started_at.is_none() {
            checkpoint.scan_started_at = Some(Utc::now())
        }
        let page = if let Some(since) = checkpoint.modified_after {
            let mut url = if let Some(cursor) = &checkpoint.cursor {
                validated_graph_cursor(cursor)?
            } else {
                Url::parse(&format!("{GRAPH_API}messages"))
                    .map_err(|_| ProviderError::InvalidResponse)?
            };
            if checkpoint.cursor.is_none() {
                url.query_pairs_mut()
                    .append_pair("$top", &limit.to_string())
                    .append_pair("$select", "id")
                    .append_pair(
                        "$filter",
                        &format!("lastModifiedDateTime ge {}", since.to_rfc3339()),
                    )
                    .append_pair("$orderby", "lastModifiedDateTime asc");
            }
            let value = request_json(
                state
                    .http
                    .get(url)
                    .bearer_auth(token)
                    .header("Prefer", "IdType=\"ImmutableId\""),
            )
            .await?;
            page_from_value(state, provider, account, token, value, limit).await?
        } else {
            fetch_page(
                state,
                provider,
                account,
                token,
                None,
                checkpoint.cursor.as_deref(),
                limit,
            )
            .await?
        };
        checkpoint.cursor = page.next_cursor;
        if checkpoint.cursor.is_none() {
            checkpoint.modified_after = checkpoint
                .scan_started_at
                .take()
                .map(|t| t - Duration::seconds(5));
            checkpoint.phase = "changed".into();
        }
        return Ok(SyncBatch {
            messages: page.messages,
            deleted_ids: vec![],
            checkpoint,
            has_more: page.has_more,
        });
    }
    if checkpoint.phase != "history" {
        if checkpoint.initial_history_id.is_none() {
            let profile = request_json(
                state
                    .http
                    .get(format!("{GOOGLE_API}profile"))
                    .bearer_auth(token),
            )
            .await?;
            checkpoint.initial_history_id = profile
                .get("historyId")
                .and_then(Value::as_str)
                .map(str::to_owned);
        }
        let page = fetch_page(
            state,
            provider,
            account,
            token,
            None,
            checkpoint.cursor.as_deref(),
            limit,
        )
        .await?;
        checkpoint.cursor = page.next_cursor;
        if checkpoint.cursor.is_none() {
            checkpoint.phase = "history".into();
            checkpoint.history_id = checkpoint.initial_history_id.take();
        }
        return Ok(SyncBatch {
            messages: page.messages,
            deleted_ids: vec![],
            checkpoint,
            has_more: page.has_more,
        });
    }
    if checkpoint.pending_ids.is_empty() && checkpoint.pending_deleted.is_empty() {
        let Some(history) = checkpoint.history_id.as_deref() else {
            checkpoint.phase = "full".into();
            return Ok(SyncBatch {
                messages: vec![],
                deleted_ids: vec![],
                checkpoint,
                has_more: true,
            });
        };
        let mut url = Url::parse(&format!("{GOOGLE_API}history"))
            .map_err(|_| ProviderError::InvalidResponse)?;
        url.query_pairs_mut()
            .append_pair("startHistoryId", history)
            .append_pair("maxResults", "20");
        if let Some(cursor) = &checkpoint.cursor {
            url.query_pairs_mut().append_pair("pageToken", cursor);
        }
        let value = match request_json(state.http.get(url).bearer_auth(token)).await {
            Ok(v) => v,
            Err(ProviderError::NotFound) => {
                return Ok(SyncBatch {
                    messages: vec![],
                    deleted_ids: vec![],
                    checkpoint: SyncCheckpoint::default(),
                    has_more: true,
                });
            }
            Err(e) => return Err(e),
        };
        let (changed, deleted) = history_changes(&value)?;
        checkpoint.pending_ids = changed;
        checkpoint.pending_deleted = deleted;
        checkpoint.resume_cursor = value
            .get("nextPageToken")
            .and_then(Value::as_str)
            .map(str::to_owned);
        checkpoint.target_history_id = value
            .get("historyId")
            .and_then(Value::as_str)
            .map(str::to_owned);
    }
    let ids: Vec<_> = checkpoint
        .pending_ids
        .drain(..checkpoint.pending_ids.len().min(limit))
        .collect();
    let mut messages = vec![];
    let mut deleted_ids: Vec<_> = checkpoint
        .pending_deleted
        .drain(..checkpoint.pending_deleted.len().min(200))
        .collect();
    for chunk in ids.chunks(5) {
        let mut tasks = tokio::task::JoinSet::new();
        for id in chunk {
            let state = state.clone();
            let token = Zeroizing::new(token.to_owned());
            let id = id.clone();
            tasks.spawn(async move {
                let result = fetch_message(&state, Provider::Gmail, account, &token, &id).await;
                (id, result)
            });
        }
        while let Some(result) = tasks.join_next().await {
            let (id, result) = result.map_err(|_| ProviderError::Unavailable)?;
            match result {
                Ok(message) => messages.push(message),
                Err(ProviderError::NotFound) => deleted_ids.push(id),
                Err(e) => return Err(e),
            }
        }
    }
    if checkpoint.pending_ids.is_empty() && checkpoint.pending_deleted.is_empty() {
        checkpoint.cursor = checkpoint.resume_cursor.take();
        if checkpoint.cursor.is_none() {
            checkpoint.history_id = checkpoint
                .target_history_id
                .take()
                .or(checkpoint.history_id);
        }
    }
    let has_more = !checkpoint.pending_ids.is_empty()
        || !checkpoint.pending_deleted.is_empty()
        || checkpoint.cursor.is_some();
    Ok(SyncBatch {
        messages,
        deleted_ids,
        checkpoint,
        has_more,
    })
}

fn history_changes(value: &Value) -> Result<(Vec<String>, Vec<String>), ProviderError> {
    let mut changed = std::collections::BTreeSet::new();
    let mut deleted = std::collections::BTreeSet::new();
    if let Some(histories) = value.get("history").and_then(Value::as_array) {
        for record in histories {
            for field in ["messagesAdded", "labelsAdded", "labelsRemoved"] {
                if let Some(items) = record.get(field).and_then(Value::as_array) {
                    for item in items {
                        if let Some(id) = item
                            .get("message")
                            .and_then(|m| m.get("id"))
                            .and_then(Value::as_str)
                        {
                            changed.insert(id.to_owned());
                        }
                    }
                }
            }
            if let Some(items) = record.get("messagesDeleted").and_then(Value::as_array) {
                for item in items {
                    if let Some(id) = item
                        .get("message")
                        .and_then(|m| m.get("id"))
                        .and_then(Value::as_str)
                    {
                        deleted.insert(id.to_owned());
                    }
                }
            }
            if changed.len() + deleted.len() > 10_000 {
                return Err(ProviderError::InvalidResponse);
            }
        }
    }
    for id in &deleted {
        changed.remove(id);
    }
    Ok((changed.into_iter().collect(), deleted.into_iter().collect()))
}

#[cfg(test)]
mod tests {
    use super::*;
    fn outgoing() -> Outgoing {
        Outgoing {
            client_id: Uuid::new_v4(),
            account_id: Uuid::new_v4(),
            to: vec![Address {
                name: Some("Clára".into()),
                email: "clara@example.com".into(),
            }],
            cc: vec![],
            bcc: vec![Address {
                name: None,
                email: "private@example.com".into(),
            }],
            subject: "Design café ✓".into(),
            text_body: "Hello café\nSecond paragraph".into(),
            html_body: Some("<p>Hello café</p>".into()),
            attachments: vec![SendAttachment {
                filename: "résumé.pdf".into(),
                mime_type: "application/pdf".into(),
                data_base64: STANDARD.encode([0_u8, 1, 2, 255]),
            }],
            scheduled_at: None,
            undo_seconds: Some(10),
            track_opens: false,
            track_links: false,
            in_reply_to: Some("<previous@example.com>".into()),
            references: vec![
                "<first@example.com>".into(),
                "<previous@example.com>".into(),
            ],
            provider_thread_id: None,
        }
    }
    #[test]
    fn mime_roundtrips_unicode_recipients_and_binary_attachments() {
        use mailparse::MailHeaderMap;
        let message = outgoing();
        let raw = build_mime("sender@example.com", &message).unwrap();
        let parsed = mailparse::parse_mail(&raw).unwrap();
        assert_eq!(
            parsed.headers.get_first_value("Subject").unwrap(),
            message.subject
        );
        assert_eq!(
            parsed.headers.get_first_value("Bcc").unwrap(),
            "private@example.com"
        );
        assert_eq!(
            parsed.headers.get_first_value("In-Reply-To").unwrap(),
            "<previous@example.com>"
        );
        assert_eq!(
            parsed.headers.get_first_value("References").unwrap(),
            "<first@example.com> <previous@example.com>"
        );
        assert!(
            parsed
                .headers
                .get_first_value("To")
                .unwrap()
                .contains("Clára")
        );
        assert_eq!(parsed.subparts.len(), 2);
        let alternatives = &parsed.subparts[0];
        assert_eq!(
            alternatives.subparts[0].get_body().unwrap(),
            message.text_body
        );
        assert_eq!(
            alternatives.subparts[1].get_body().unwrap(),
            message.html_body.clone().unwrap()
        );
        assert_eq!(
            parsed.subparts[1].get_body_raw().unwrap(),
            vec![0, 1, 2, 255]
        );
        assert_eq!(
            parsed.subparts[1]
                .get_content_disposition()
                .params
                .get("filename")
                .unwrap(),
            "résumé.pdf"
        );
        assert!(raw.split(|b| *b == b'\n').all(|line| line.len() <= 999));
    }
    #[test]
    fn addresses_and_mime_reject_header_injection() {
        assert!(!valid_email("a@example.com\r\nBcc: victim@example.com"));
        assert!(!valid_email("a@example.com,b@example.com"));
        assert!(!valid_mime_type("text/plain\r\nX: bad"));
        let mut message = outgoing();
        message.to[0].email = "a@example.com\nBcc:x@example.com".into();
        assert_eq!(
            build_mime("sender@example.com", &message).unwrap_err(),
            ProviderError::Rejected
        );
    }
    #[test]
    fn gmail_fixture_normalizes_nested_body_flags_headers_and_attachment_ids() {
        let account = Uuid::new_v4();
        let fixture = json!({"id":"gmail-1","threadId":"thread-1","internalDate":"1730610000000","snippet":"A preview","labelIds":["INBOX","UNREAD","STARRED","CATEGORY_UPDATES"],"payload":{"mimeType":"multipart/mixed","headers":[{"name":"From","value":"\"Last, First\" <person@example.com>"},{"name":"To","value":"One <one@example.com>, Two <two@example.com>"},{"name":"Subject","value":"=?UTF-8?B?Q2Fmw6k=?="},{"name":"List-Unsubscribe","value":"<https://example.com/unsubscribe>"}],"parts":[{"partId":"0","mimeType":"text/plain","body":{"data":URL_SAFE_NO_PAD.encode("Hello café")}},{"partId":"1","mimeType":"application/pdf","filename":"plan.pdf","body":{"attachmentId":"blob-1","size":12}}]}});
        let first = normalize_gmail(account, &fixture).unwrap();
        let second = normalize_gmail(account, &fixture).unwrap();
        assert_eq!(first.id, second.id);
        assert_eq!(first.attachments[0].id, second.attachments[0].id);
        assert_eq!(first.subject, "Café");
        assert_eq!(first.from.name.as_deref(), Some("Last, First"));
        assert_eq!(first.to.len(), 2);
        assert!(!first.is_read);
        assert!(first.is_starred);
        assert_eq!(first.mailbox, "inbox");
        assert_eq!(first.text_body, "Hello café");
        assert_eq!(first.list_unsubscribe.len(), 1);
        assert_ne!(
            first.id,
            normalize_gmail(Uuid::new_v4(), &fixture).unwrap().id,
            "provider IDs must be isolated by account"
        );
    }
    #[test]
    fn microsoft_fixture_preserves_recipients_flags_and_list_headers() {
        let value = json!({"id":"ms-1","conversationId":"conversation","receivedDateTime":"2026-11-17T10:00:00Z","subject":"Review","from":{"emailAddress":{"name":"Pat","address":"pat@example.com"}},"toRecipients":[{"emailAddress":{"address":"one@example.com"}}],"ccRecipients":[{"emailAddress":{"address":"two@example.com"}}],"body":{"contentType":"HTML","content":"<p>Full body</p>"},"bodyPreview":"Full body","isRead":true,"flag":{"flagStatus":"flagged"},"parentFolderId":"folder-1","attachments":[{"id":"attachment-1","name":"document.pdf","contentType":"application/pdf","size":123}],"internetMessageHeaders":[{"name":"List-Unsubscribe-Post","value":"List-Unsubscribe=One-Click"}]});
        let m = normalize_graph(Uuid::new_v4(), &value).unwrap();
        assert!(m.is_read && m.is_starred);
        assert_eq!(m.to.len(), 1);
        assert_eq!(m.cc.len(), 1);
        assert_eq!(m.html_body.as_deref(), Some("<p>Full body</p>"));
        assert_eq!(m.attachments[0].size_bytes, 123);
        assert_eq!(m.list_unsubscribe_post.len(), 1);
    }
    #[test]
    fn graph_cursors_cannot_redirect_credentials_to_another_origin() {
        assert!(
            validated_graph_cursor("https://graph.microsoft.com/v1.0/me/messages?$skiptoken=abc")
                .is_ok()
        );
        for bad in [
            "https://evil.example/v1.0/me/messages",
            "http://graph.microsoft.com/v1.0/me/messages",
            "https://graph.microsoft.com@evil.example/v1.0/me/messages",
            "https://graph.microsoft.com/v1.0/users/other/messages",
            "https://graph.microsoft.com:444/v1.0/me/messages",
        ] {
            assert!(validated_graph_cursor(bad).is_err(), "{bad}")
        }
        let url = message_url(Provider::Gmail, "id/with?reserved#characters", None).unwrap();
        assert_eq!(url.host_str(), Some("gmail.googleapis.com"));
        assert!(url.query().is_none());
        assert!(url.fragment().is_none());
        assert!(url.path().contains("%2F"));
    }
    #[test]
    fn refresh_rotation_preserves_old_token_only_when_provider_omits_new_one() {
        let value = json!({"access_token":"new-access","expires_in":3600});
        let c = parse_tokens(value, Some("existing-refresh")).unwrap();
        assert_eq!(c.refresh_token.as_deref(), Some("existing-refresh"));
        let c = parse_tokens(
            json!({"access_token":"new","refresh_token":"rotated","expires_in":3600}),
            Some("old"),
        )
        .unwrap();
        assert_eq!(c.refresh_token.as_deref(), Some("rotated"));
        assert!(parse_tokens(json!({"access_token":"","expires_in":3600}), None).is_err());
    }
    #[test]
    fn gmail_history_distinguishes_explicit_deletions_from_changed_messages() {
        let value = json!({"history":[{"messagesAdded":[{"message":{"id":"new"}}],"labelsAdded":[{"message":{"id":"changed"}}],"labelsRemoved":[{"message":{"id":"changed"}},{"message":{"id":"deleted"}}],"messagesDeleted":[{"message":{"id":"deleted"}}]}]});
        let (changed, deleted) = history_changes(&value).unwrap();
        assert_eq!(changed, vec!["changed", "new"]);
        assert_eq!(deleted, vec!["deleted"]);
        assert_eq!(
            history_changes(&json!({"history":[]})).unwrap(),
            (vec![], vec![])
        );
    }
    #[test]
    fn calendar_capability_requires_the_granted_provider_scope() {
        let mail=parse_tokens(json!({"access_token":"test","expires_in":3600,"scope":"https://www.googleapis.com/auth/gmail.modify"}),None).unwrap();
        assert!(!has_calendar_scope(Provider::Gmail, &mail));
        let calendar=parse_tokens(json!({"access_token":"test","expires_in":3600,"scope":"Mail.ReadWrite Calendars.ReadWrite"}),None).unwrap();
        assert!(has_calendar_scope(Provider::Microsoft, &calendar));
        assert!(!has_calendar_scope(Provider::Gmail, &calendar));
    }
}
