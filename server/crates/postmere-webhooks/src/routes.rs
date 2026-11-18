use crate::WebhookService;
use axum::{
    Extension, Router,
    body::Bytes,
    extract::{DefaultBodyLimit, Path, RawQuery, State},
    http::{HeaderMap, StatusCode, header},
    response::{IntoResponse, Response},
    routing::post,
};
use base64::{Engine, engine::general_purpose::STANDARD};
use chrono::{DateTime, Duration, Utc};
use postmere_core::{AppState, db, error::AppError};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use sqlx::{Postgres, Row, Transaction};
use std::sync::Arc;
use uuid::Uuid;

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/v1/webhooks/gmail", post(gmail))
        .route("/v1/webhooks/microsoft/{id}", post(microsoft))
        .layer(DefaultBodyLimit::max(128 * 1024))
}
pub(crate) fn equal_hash(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && a.iter().zip(b).fold(0_u8, |x, (a, b)| x | (a ^ b)) == 0
}

/// Lock identity/account state through queueing, following revocation's order.
pub(crate) async fn active(
    tx: &mut Transaction<'_, Postgres>,
    workspace: Uuid,
    user: Uuid,
    account: Uuid,
) -> Result<bool, AppError> {
    let u: Option<Uuid> =
        sqlx::query_scalar("SELECT id FROM users WHERE id=$1 AND disabled_at IS NULL FOR SHARE")
            .bind(user)
            .fetch_optional(&mut **tx)
            .await?;
    if u.is_none() {
        return Ok(false);
    }
    let m:Option<Uuid>=sqlx::query_scalar("SELECT user_id FROM memberships WHERE workspace_id=$1 AND user_id=$2 AND revoked_at IS NULL FOR SHARE").bind(workspace).bind(user).fetch_optional(&mut **tx).await?;
    if m.is_none() {
        return Ok(false);
    }
    let w: Option<Uuid> = sqlx::query_scalar(
        "SELECT id FROM workspaces WHERE id=$1 AND disabled_at IS NULL FOR SHARE",
    )
    .bind(workspace)
    .fetch_optional(&mut **tx)
    .await?;
    if w.is_none() {
        return Ok(false);
    }
    let a:Option<Uuid>=sqlx::query_scalar("SELECT id FROM provider_accounts WHERE id=$1 AND disabled_at IS NULL AND status='connected' FOR SHARE").bind(account).fetch_optional(&mut **tx).await?;
    Ok(a.is_some())
}
pub(crate) async fn signal(
    tx: &mut Transaction<'_, Postgres>,
    workspace: Uuid,
    user: Uuid,
    account: Uuid,
) -> Result<(), AppError> {
    sqlx::query("INSERT INTO mail_sync_signals(account_id,workspace_id,user_id) VALUES($1,$2,$3) ON CONFLICT(account_id) DO UPDATE SET generation=mail_sync_signals.generation+1,due_at=LEAST(mail_sync_signals.due_at,clock_timestamp())")
        .bind(account).bind(workspace).bind(user).execute(&mut **tx).await?;
    Ok(())
}
#[derive(Deserialize)]
struct PubsubEnvelope {
    message: PubsubMessage,
    subscription: String,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PubsubMessage {
    data: String,
    message_id: String,
    publish_time: DateTime<Utc>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct GmailHint {
    email_address: String,
    history_id: String,
}

async fn gmail(
    State(state): State<AppState>,
    service: Option<Extension<Arc<WebhookService>>>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<StatusCode, AppError> {
    let service = service.ok_or_else(AppError::not_found)?.0;
    let config = service.gmail.as_ref().ok_or_else(AppError::not_found)?;
    if headers.get_all(header::AUTHORIZATION).iter().count() != 1 {
        return Err(AppError::unauthorized());
    }
    let token = headers
        .get(header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .ok_or_else(AppError::unauthorized)?;
    service
        .keys
        .lock()
        .await
        .verify(&state, token, config)
        .await?;
    let envelope: PubsubEnvelope = serde_json::from_slice(&body)
        .map_err(|_| AppError::bad_request("Invalid push envelope."))?;
    if envelope.subscription != config.subscription
        || envelope.message.message_id.is_empty()
        || envelope.message.message_id.len() > 256
        || envelope.message.data.len() > 4096
    {
        return Err(AppError::bad_request("Invalid push envelope."));
    }
    let now = Utc::now();
    // Expired/replayed envelope content is acknowledged but cannot schedule work.
    if envelope.message.publish_time < now - Duration::hours(24)
        || envelope.message.publish_time > now + Duration::minutes(5)
    {
        return Ok(StatusCode::NO_CONTENT);
    }
    let decoded = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(&envelope.message.data)
        .or_else(|_| base64::engine::general_purpose::URL_SAFE.decode(&envelope.message.data))
        .or_else(|_| STANDARD.decode(&envelope.message.data))
        .map_err(|_| AppError::bad_request("Invalid Gmail hint."))?;
    let hint: GmailHint = serde_json::from_slice(&decoded)
        .map_err(|_| AppError::bad_request("Invalid Gmail hint."))?;
    let email = hint.email_address.to_lowercase();
    let history = hint
        .history_id
        .parse::<u64>()
        .ok()
        .filter(|n| *n > 0)
        .ok_or_else(|| AppError::bad_request("Invalid Gmail history hint."))?;
    if !postmere_providers::valid_email(&email) {
        return Err(AppError::bad_request("Invalid Gmail hint."));
    }
    let routes=sqlx::query("SELECT id,workspace_id,user_id,account_id FROM provider_webhooks WHERE provider='gmail' AND mailbox_hash=$1 AND enabled")
        .bind(Sha256::digest(email.as_bytes()).as_slice()).fetch_all(&state.pool).await?;
    for route in routes {
        let workspace = route.get("workspace_id");
        let user = route.get("user_id");
        let account = route.get("account_id");
        let id: Uuid = route.get("id");
        let mut tx = db::scoped_transaction(&state.pool, workspace, user).await?;
        if !active(&mut tx, workspace, user, account).await? {
            continue;
        }
        let changed=sqlx::query("UPDATE provider_webhooks SET gmail_history=$2::text::numeric WHERE id=$1 AND enabled AND (gmail_history IS NULL OR gmail_history<$2::text::numeric)")
            .bind(id).bind(history.to_string()).execute(&mut *tx).await?.rows_affected()==1;
        if changed {
            signal(&mut tx, workspace, user, account).await?;
        }
        tx.commit().await?;
    }
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Deserialize)]
struct GraphEnvelope {
    value: Vec<GraphHint>,
}
#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct GraphHint {
    subscription_id: String,
    client_state: Option<String>,
    #[serde(default)]
    lifecycle_event: Option<String>,
    #[serde(default)]
    change_type: Option<String>,
    #[serde(default)]
    id: Option<String>,
    #[serde(default)]
    resource: Option<String>,
    #[serde(default)]
    subscription_expiration_date_time: Option<String>,
    #[serde(default)]
    encrypted_content: Option<serde_json::Value>,
}
#[derive(Serialize, Deserialize)]
struct Receipt {
    digest: String,
    at: DateTime<Utc>,
}

async fn microsoft(
    State(state): State<AppState>,
    service: Option<Extension<Arc<WebhookService>>>,
    Path(id): Path<Uuid>,
    RawQuery(query): RawQuery,
    body: Bytes,
) -> Result<Response, AppError> {
    let service = service.ok_or_else(AppError::not_found)?.0;
    if !service.microsoft {
        return Err(AppError::not_found());
    }
    if let Some(query) = query {
        if query.len() > 4096 {
            return Err(AppError::bad_request("Invalid validation request."));
        }
        let tokens: Vec<_> = url::form_urlencoded::parse(query.as_bytes())
            .filter(|(k, _)| k == "validationToken")
            .map(|(_, v)| v.into_owned())
            .collect();
        if !tokens.is_empty() {
            if tokens.len() != 1
                || tokens[0].is_empty()
                || tokens[0].len() > 2048
                || tokens[0].bytes().any(|b| b.is_ascii_control())
            {
                return Err(AppError::bad_request("Invalid validation token."));
            }
            // Endpoint validation conveys no account access or authentication.
            return Ok((
                [
                    (header::CONTENT_TYPE, "text/plain; charset=utf-8"),
                    (header::CACHE_CONTROL, "no-store"),
                ],
                tokens.into_iter().next().unwrap(),
            )
                .into_response());
        }
    }
    let envelope: GraphEnvelope =
        serde_json::from_slice(&body).map_err(|_| AppError::bad_request("Invalid Graph hints."))?;
    if envelope.value.is_empty() || envelope.value.len() > 100 {
        return Err(AppError::bad_request("Too many Graph hints."));
    }
    let route=sqlx::query("SELECT workspace_id,user_id,account_id FROM provider_webhooks WHERE id=$1 AND provider='microsoft' AND enabled")
        .bind(id).fetch_optional(&state.pool).await?;
    let Some(route) = route else {
        return Ok(StatusCode::ACCEPTED.into_response());
    };
    let workspace = route.get("workspace_id");
    let user = route.get("user_id");
    let account = route.get("account_id");
    let mut tx = db::scoped_transaction(&state.pool, workspace, user).await?;
    if !active(&mut tx, workspace, user, account).await? {
        return Ok(StatusCode::ACCEPTED.into_response());
    }
    let row=sqlx::query("SELECT provider_subscription,state_hash,recent_receipts FROM provider_webhooks WHERE id=$1 AND enabled AND expires_at>clock_timestamp() FOR UPDATE")
        .bind(id).fetch_optional(&mut *tx).await?;
    let Some(row) = row else {
        return Ok(StatusCode::ACCEPTED.into_response());
    };
    let subscription: Option<String> = row.get("provider_subscription");
    let secret: Option<Vec<u8>> = row.get("state_hash");
    let Some(secret) = secret else {
        return Ok(StatusCode::ACCEPTED.into_response());
    };
    let mut receipts: Vec<Receipt> = serde_json::from_value(row.get("recent_receipts"))
        .map_err(|_| AppError::internal("webhook_receipt_decode"))?;
    let now = Utc::now();
    receipts.retain(|r| r.at > now - Duration::minutes(10));
    let mut changed = false;
    let mut renew = false;
    let mut removed = false;
    for hint in envelope.value {
        let Some(client_state) = &hint.client_state else {
            continue;
        };
        if client_state.len() > 128
            || hint.subscription_id.len() > 512
            || subscription.as_deref() != Some(&hint.subscription_id)
            || !equal_hash(&secret, &Sha256::digest(client_state.as_bytes()))
            || hint.encrypted_content.is_some()
        {
            continue;
        }
        let lifecycle = hint.lifecycle_event.as_deref();
        if lifecycle.is_some_and(|e| {
            !matches!(
                e,
                "missed" | "subscriptionRemoved" | "reauthorizationRequired"
            )
        }) || (lifecycle.is_none()
            && !matches!(
                hint.change_type.as_deref(),
                Some("created" | "updated" | "deleted")
            ))
        {
            continue;
        }
        // Bound replay memory and never store resource identifiers or clientState.
        let encoded =
            serde_json::to_vec(&hint).map_err(|_| AppError::internal("webhook_receipt_encode"))?;
        let digest =
            base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(Sha256::digest(&encoded));
        if receipts.iter().any(|r| r.digest == digest) {
            continue;
        }
        if receipts.len() == 128 {
            receipts.remove(0);
        }
        receipts.push(Receipt { digest, at: now });
        changed = true;
        renew |= matches!(
            lifecycle,
            Some("reauthorizationRequired" | "subscriptionRemoved")
        );
        removed |= lifecycle == Some("subscriptionRemoved");
    }
    if changed {
        signal(&mut tx, workspace, user, account).await?;
        sqlx::query("UPDATE provider_webhooks SET recent_receipts=$2,renew_at=CASE WHEN $3 THEN clock_timestamp() ELSE renew_at END,provider_subscription=CASE WHEN $4 THEN NULL ELSE provider_subscription END,expires_at=CASE WHEN $4 THEN NULL ELSE expires_at END,generation=generation+CASE WHEN $3 THEN 1 ELSE 0 END,lease_until=CASE WHEN $3 THEN NULL ELSE lease_until END WHERE id=$1")
            .bind(id).bind(serde_json::to_value(receipts).map_err(|_|AppError::internal("webhook_receipt_encode"))?).bind(renew).bind(removed).execute(&mut *tx).await?;
    }
    tx.commit().await?;
    Ok(StatusCode::ACCEPTED.into_response())
}
