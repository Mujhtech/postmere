//! Optional tracking records requests for images and redirect links. It never
//! claims to establish that a recipient read a message, and stores no raw IP.
use axum::{
    Json, Router,
    extract::{Path, Query, State},
    http::{HeaderMap, HeaderValue, StatusCode, header},
    response::{IntoResponse, Response},
    routing::get,
};
use chrono::{DateTime, Utc};
use postmere_core::{AppState, auth::AuthContext, db, error::AppError, tokens};
use postmere_providers::Outgoing;
use serde::{Deserialize, Serialize};
use serde_json::json;
use sqlx::{Postgres, Row, Transaction};
use url::Url;
use uuid::Uuid;

const NOTICE: &str = "Open counts measure image requests, not verified reads. Mail privacy proxies, link scanners, forwarding and blocked images can affect counts. Recipient attribution is available only for a single-recipient send and may reflect forwarding. Device labels are inferred from the requesting client and may be inaccurate.";
const PIXEL: &[u8] = &[
    71, 73, 70, 56, 57, 97, 1, 0, 1, 0, 128, 0, 0, 0, 0, 0, 255, 255, 255, 33, 249, 4, 1, 0, 0, 0,
    0, 44, 0, 0, 0, 0, 1, 0, 1, 0, 0, 2, 2, 68, 1, 0, 59,
];

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/t/open/{token}", get(open))
        .route("/t/link/{token}", get(click))
        .route("/v1/mail/activity", get(activity))
}

/// Rewrites quoted HTTP(S) anchors only; mailto links, fragments, local URLs and
/// other HTML attributes remain unchanged. Returned ranges refer to the exact
/// original bytes so Unicode text and unrelated markup are preserved.
pub fn trackable_hrefs(html: &str) -> Vec<(std::ops::Range<usize>, String)> {
    let lower = html.to_ascii_lowercase();
    let bytes = html.as_bytes();
    let mut position = 0;
    let mut result = vec![];
    while position < bytes.len() && result.len() < 100 {
        let Some(offset) = lower[position..].find('<') else {
            break;
        };
        let start = position + offset;
        if lower[start..].starts_with("<!--") {
            position = lower[start + 4..]
                .find("-->")
                .map(|i| start + 4 + i + 3)
                .unwrap_or(bytes.len());
            continue;
        }
        let Some(end) = tag_end(bytes, start + 1) else {
            break;
        };
        position = end + 1;
        let tag_name_end = (start + 1..end)
            .find(|i| bytes[*i].is_ascii_whitespace() || bytes[*i] == b'/')
            .unwrap_or(end);
        let tag = &lower[start + 1..tag_name_end];
        if tag == "script" || tag == "style" {
            position = lower[position..]
                .find(&format!("</{tag}"))
                .and_then(|i| tag_end(bytes, position + i + 2))
                .map(|i| i + 1)
                .unwrap_or(bytes.len());
            continue;
        }
        if tag != "a" {
            continue;
        }
        let mut p = tag_name_end;
        let mut saw_href = false;
        while p < end {
            while p < end && (bytes[p].is_ascii_whitespace() || bytes[p] == b'/') {
                p += 1
            }
            let name_start = p;
            while p < end && !bytes[p].is_ascii_whitespace() && bytes[p] != b'=' && bytes[p] != b'/'
            {
                p += 1
            }
            let name = &lower[name_start..p];
            while p < end && bytes[p].is_ascii_whitespace() {
                p += 1
            }
            if p >= end || bytes[p] != b'=' {
                if p == name_start {
                    p += 1
                }
                continue;
            }
            p += 1;
            while p < end && bytes[p].is_ascii_whitespace() {
                p += 1
            }
            if p >= end {
                break;
            }
            let quote = bytes[p];
            let quoted = quote == b'\'' || quote == b'"';
            if quoted {
                p += 1
            }
            let value_start = p;
            while p < end
                && if quoted {
                    bytes[p] != quote
                } else {
                    !bytes[p].is_ascii_whitespace()
                }
            {
                p += 1
            }
            let value_end = p;
            if quoted && p < end {
                p += 1
            }
            if name == "href" && !saw_href {
                saw_href = true;
                if quoted {
                    let decoded = html_escape::decode_html_entities(&html[value_start..value_end]);
                    if let Some(url) = safe_destination(&decoded) {
                        result.push((value_start..value_end, url.into()));
                    }
                }
            }
        }
    }
    result
}
fn tag_end(bytes: &[u8], mut position: usize) -> Option<usize> {
    let mut quote = None;
    while position < bytes.len() {
        let b = bytes[position];
        if let Some(q) = quote {
            if b == q {
                quote = None
            }
        } else if b == b'\'' || b == b'"' {
            quote = Some(b)
        } else if b == b'>' {
            return Some(position);
        }
        position += 1
    }
    None
}
fn safe_destination(value: &str) -> Option<Url> {
    if value.len() > 8_192 {
        return None;
    }
    let url = Url::parse(value).ok()?;
    if !["http", "https"].contains(&url.scheme())
        || !url.username().is_empty()
        || url.password().is_some()
    {
        return None;
    }
    let host = url.host_str()?;
    if host.eq_ignore_ascii_case("localhost")
        || host.ends_with(".localhost")
        || host.ends_with(".local")
        || !host.contains('.')
    {
        return None;
    }
    if let Ok(ip) = host.parse::<std::net::IpAddr>() {
        let blocked = match ip {
            std::net::IpAddr::V4(ip) => {
                ip.is_private()
                    || ip.is_loopback()
                    || ip.is_link_local()
                    || ip.is_unspecified()
                    || ip.is_broadcast()
            }
            std::net::IpAddr::V6(ip) => ip.is_loopback() || ip.is_unspecified(),
        };
        if blocked {
            return None;
        }
    }
    Some(url)
}

pub async fn prepare_tracking(
    state: &AppState,
    tx: &mut Transaction<'_, Postgres>,
    workspace: Uuid,
    user: Uuid,
    outbox: Uuid,
    message: &mut Outgoing,
) -> Result<(), AppError> {
    if !message.track_opens && !message.track_links {
        return Ok(());
    }
    // A confirmed rejected send may be retried; old unexposed tokens must not
    // accumulate or be reused across attempts.
    sqlx::query("DELETE FROM mail_tracking_links WHERE outbox_id=$1")
        .bind(outbox)
        .execute(&mut **tx)
        .await?;
    let recipient = if message.to.len() + message.cc.len() + message.bcc.len() == 1 {
        message
            .to
            .iter()
            .chain(&message.cc)
            .chain(&message.bcc)
            .next()
            .map(|a| a.email.clone())
    } else {
        None
    };
    let mut html = message.html_body.clone().unwrap_or_else(|| {
        format!(
            "<pre>{}</pre>",
            html_escape::encode_text(&message.text_body)
        )
    });
    if message.track_links {
        let links = trackable_hrefs(&html);
        let mut replacements = vec![];
        for (range, target) in links {
            let token = insert_link(
                tx,
                workspace,
                user,
                outbox,
                "click",
                Some(&target),
                recipient.as_deref(),
            )
            .await?;
            let url = state
                .config
                .public_base_url
                .join(&format!("/t/link/{token}"))
                .map_err(|_| AppError::internal("tracking_url"))?;
            replacements.push((range, url.to_string()));
        }
        for (range, value) in replacements.into_iter().rev() {
            html.replace_range(range, &value)
        }
    }
    if message.track_opens {
        let token = insert_link(
            tx,
            workspace,
            user,
            outbox,
            "open",
            None,
            recipient.as_deref(),
        )
        .await?;
        let url = state
            .config
            .public_base_url
            .join(&format!("/t/open/{token}.gif"))
            .map_err(|_| AppError::internal("tracking_url"))?;
        html.push_str(&format!(
            "<img src=\"{url}\" width=\"1\" height=\"1\" alt=\"\" style=\"display:none\">"
        ));
    }
    message.html_body = Some(html);
    Ok(())
}
async fn insert_link(
    tx: &mut Transaction<'_, Postgres>,
    workspace: Uuid,
    user: Uuid,
    outbox: Uuid,
    kind: &str,
    destination: Option<&str>,
    recipient: Option<&str>,
) -> Result<String, AppError> {
    let id = Uuid::new_v4();
    let token = tokens::scoped_token(workspace, user, id)?;
    sqlx::query("INSERT INTO mail_tracking_links(id,workspace_id,user_id,outbox_id,token_hash,kind,destination,recipient) VALUES($1,$2,$3,$4,$5,$6,$7,$8)").bind(id).bind(workspace).bind(user).bind(outbox).bind(tokens::token_hash(&token)).bind(kind).bind(destination).bind(recipient).execute(&mut **tx).await?;
    Ok(token)
}

async fn open(
    State(state): State<AppState>,
    Path(token): Path<String>,
    headers: HeaderMap,
) -> Response {
    let token = token.strip_suffix(".gif").unwrap_or(&token);
    // Invalid or revoked pixels return the same image and reveal no account or
    // message information to a remote requester.
    let _ = record(&state, token, "open", &headers).await;
    (
        [
            (header::CONTENT_TYPE, "image/gif"),
            (header::CACHE_CONTROL, "no-store, max-age=0"),
        ],
        PIXEL,
    )
        .into_response()
}
async fn click(
    State(state): State<AppState>,
    Path(token): Path<String>,
    headers: HeaderMap,
) -> Result<Response, AppError> {
    let destination = record(&state, &token, "click", &headers)
        .await?
        .ok_or_else(AppError::not_found)?;
    let url = safe_destination(&destination).ok_or_else(AppError::not_found)?;
    let mut response = StatusCode::FOUND.into_response();
    response.headers_mut().insert(
        header::LOCATION,
        HeaderValue::from_str(url.as_str()).map_err(|_| AppError::not_found())?,
    );
    Ok(response)
}

pub fn classify_device(user_agent: &str) -> (&'static str, bool) {
    let ua = user_agent.to_ascii_lowercase();
    if [
        "proxy",
        "googleimage",
        "bot",
        "scanner",
        "headless",
        "preview",
        "mailprivacy",
    ]
    .iter()
    .any(|s| ua.contains(s))
    {
        return ("Proxy or automated client", true);
    }
    if ua.contains("iphone") || ua.contains("ipad") {
        ("iPhone or iPad", false)
    } else if ua.contains("android") {
        ("Android", false)
    } else if ua.contains("windows") {
        ("Windows", false)
    } else if ua.contains("macintosh") || ua.contains("mac os") {
        ("Mac", false)
    } else if ua.contains("linux") {
        ("Linux", false)
    } else {
        ("Unknown client", false)
    }
}
async fn record(
    state: &AppState,
    token: &str,
    kind: &str,
    headers: &HeaderMap,
) -> Result<Option<String>, AppError> {
    let (workspace, user, id) = tokens::parse_scoped_token(token)?;
    let mut tx = db::scoped_transaction(&state.pool, workspace, user).await?;
    let row=sqlx::query("SELECT l.outbox_id,l.destination,l.recipient,l.created_at FROM mail_tracking_links l JOIN mail_outbox o ON o.id=l.outbox_id JOIN provider_accounts a ON a.id=o.account_id JOIN memberships m ON m.workspace_id=l.workspace_id AND m.user_id=l.user_id JOIN users u ON u.id=l.user_id JOIN workspaces w ON w.id=l.workspace_id WHERE l.id=$1 AND l.token_hash=$2 AND l.kind=$3 AND o.status IN ('delivering','sent','uncertain') AND a.disabled_at IS NULL AND m.revoked_at IS NULL AND u.disabled_at IS NULL AND w.disabled_at IS NULL")
        .bind(id).bind(tokens::token_hash(token)).bind(kind).fetch_optional(&mut *tx).await?.ok_or_else(AppError::not_found)?;
    let outbox: Uuid = row.try_get("outbox_id")?;
    let recipient: Option<String> = row.try_get("recipient")?;
    let destination: Option<String> = row.try_get("destination")?;
    let created: DateTime<Utc> = row.try_get("created_at")?;
    if Utc::now() - created < chrono::Duration::days(180) {
        let agent = headers
            .get(header::USER_AGENT)
            .and_then(|v| v.to_str().ok())
            .unwrap_or("");
        let end = agent
            .char_indices()
            .map(|(i, _)| i)
            .take_while(|i| *i <= 512)
            .last()
            .unwrap_or(0);
        let agent = if agent.len() > 512 {
            &agent[..end]
        } else {
            agent
        };
        let (device, is_proxy) = classify_device(agent);
        sqlx::query("SELECT pg_advisory_xact_lock(hashtextextended($1,0))")
            .bind(id.to_string())
            .execute(&mut *tx)
            .await?;
        // Repeated cache probes within ten seconds count once. No IP address or
        // complete user-agent is persisted.
        sqlx::query("INSERT INTO mail_tracking_events(id,workspace_id,user_id,outbox_id,link_id,kind,recipient,device,is_proxy_or_bot) SELECT $1,$2,$3,$4,$5,$6,$7,$8,$9 WHERE NOT EXISTS(SELECT 1 FROM mail_tracking_events WHERE link_id=$5 AND device=$8 AND occurred_at>now()-interval '10 seconds')")
            .bind(Uuid::new_v4()).bind(workspace).bind(user).bind(outbox).bind(id).bind(kind).bind(recipient).bind(device).bind(is_proxy).execute(&mut *tx).await?;
    }
    tx.commit().await?;
    Ok(destination)
}

#[derive(Deserialize)]
struct ActivityRequest {
    message_id: Option<Uuid>,
}
#[derive(Serialize)]
struct Event {
    id: Uuid,
    kind: String,
    occurred_at: DateTime<Utc>,
    recipient: Option<String>,
    device: String,
    is_proxy_or_bot: bool,
}
async fn activity(
    State(state): State<AppState>,
    auth: AuthContext,
    Query(request): Query<ActivityRequest>,
) -> Result<Json<serde_json::Value>, AppError> {
    let mut tx = auth.begin(&state.pool).await?;
    let rows=sqlx::query("SELECT o.id,count(e.id) FILTER(WHERE e.kind='open') AS opens,count(e.id) FILTER(WHERE e.kind='click') AS clicks,min(e.occurred_at) FILTER(WHERE e.kind='open') AS first_open_at,max(e.occurred_at) FILTER(WHERE e.kind='open') AS last_open_at,min(e.occurred_at) FILTER(WHERE e.kind='click') AS first_click_at,max(e.occurred_at) FILTER(WHERE e.kind='click') AS last_click_at FROM mail_outbox o JOIN mail_tracking_links l ON l.outbox_id=o.id LEFT JOIN mail_tracking_events e ON e.link_id=l.id WHERE ($1::uuid IS NULL OR o.id=$1) GROUP BY o.id ORDER BY max(o.created_at) DESC LIMIT 100").bind(request.message_id).fetch_all(&mut *tx).await?;
    let mut items = vec![];
    for row in rows {
        let id: Uuid = row.try_get("id")?;
        let events=sqlx::query("SELECT id,kind,occurred_at,recipient,device,is_proxy_or_bot FROM mail_tracking_events WHERE outbox_id=$1 ORDER BY occurred_at DESC LIMIT 200").bind(id).fetch_all(&mut *tx).await?.into_iter().map(|e|Ok::<_,AppError>(Event{id:e.try_get("id")?,kind:e.try_get("kind")?,occurred_at:e.try_get("occurred_at")?,recipient:e.try_get("recipient")?,device:e.try_get("device")?,is_proxy_or_bot:e.try_get("is_proxy_or_bot")?})).collect::<Result<Vec<_>,_>>()?;
        items.push(json!({"outbox_id":id,"opens":row.try_get::<i64,_>("opens")?,"clicks":row.try_get::<i64,_>("clicks")?,"first_open_at":row.try_get::<Option<DateTime<Utc>>,_>("first_open_at")?,"last_open_at":row.try_get::<Option<DateTime<Utc>>,_>("last_open_at")?,"first_click_at":row.try_get::<Option<DateTime<Utc>>,_>("first_click_at")?,"last_click_at":row.try_get::<Option<DateTime<Utc>>,_>("last_click_at")?,"events":events}));
    }
    tx.commit().await?;
    Ok(Json(json!({"items":items,"attribution_notice":NOTICE})))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn links_only_rewrite_safe_quoted_hrefs() {
        let html = "<a href=\"https://example.com/a?x=1&amp;y=2\">café</a><a HREF='https://other.example/'>other</a><img src=\"https://example.com/a\"><a href=\"javascript:alert(1)\">bad</a><a href=\"mailto:a@example.com\">mail</a><a href=\"http://127.0.0.1/admin\">local</a>";
        let targets = trackable_hrefs(html);
        assert_eq!(targets.len(), 2);
        assert_eq!(targets[0].1, "https://example.com/a?x=1&y=2");
        assert_eq!(&html[targets[1].0.clone()], "https://other.example/");
    }
    #[test]
    fn attribution_flags_proxies_and_avoids_false_precision() {
        assert_eq!(
            classify_device("GoogleImageProxy"),
            ("Proxy or automated client", true)
        );
        assert_eq!(classify_device("Mozilla iPhone"), ("iPhone or iPad", false));
        assert_eq!(classify_device(""), ("Unknown client", false));
    }
    #[test]
    fn tracking_preserves_comments_scripts_and_non_href_attributes() {
        let html = "<!-- <a href='https://comment.example/'> --><script>const x = \"<a href='https://script.example/'>\";</script><div href='https://div.example/'></div><a data-href='https://data.example/' title='a > b' href='https://real.example/'>café</a><a href='javascript:bad' href='https://duplicate.example/'>duplicate</a>";
        let links = trackable_hrefs(html);
        assert_eq!(links.len(), 1);
        assert_eq!(links[0].1, "https://real.example/");
    }
    #[test]
    fn tokens_are_scoped_unpredictable_and_strict() {
        let w = Uuid::new_v4();
        let u = Uuid::new_v4();
        let id = Uuid::new_v4();
        let a = tokens::scoped_token(w, u, id).unwrap();
        let b = tokens::scoped_token(w, u, id).unwrap();
        assert_ne!(a, b);
        assert_eq!(tokens::parse_scoped_token(&a).unwrap(), (w, u, id));
        assert!(tokens::parse_scoped_token(&format!("{w}.{u}.{id}.short")).is_err());
    }
}
