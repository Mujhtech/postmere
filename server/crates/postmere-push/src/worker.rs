use crate::{AccountPreference, DeliveryResult, PushRequest, PushService};
use chrono::{DateTime, Utc};
use postmere_core::{AppState, auth::AuthContext, db, error::AppError};
use serde_json::{Value, json};
use sqlx::{Postgres, Row, Transaction};
use std::{sync::Arc, time::Duration};
use uuid::Uuid;
use zeroize::Zeroizing;

pub fn spawn_worker(state: AppState, service: Arc<PushService>) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        loop {
            match process_one(&state, &service).await {
                Ok(true) => {}
                Ok(false) => tokio::time::sleep(Duration::from_secs(2)).await,
                Err(_) => tokio::time::sleep(Duration::from_secs(5)).await,
            }
        }
    })
}

/// One durable queue item. Public for fixture-only tests and bounded workers.
pub async fn process_one(state: &AppState, service: &PushService) -> Result<bool, AppError> {
    let Some(transport) = service.transport.as_ref() else {
        return Ok(false);
    };
    let wakeup=sqlx::query("UPDATE push_delivery_wakeups SET lease_until=clock_timestamp()+interval '60 seconds' WHERE job_id=(SELECT job_id FROM push_delivery_wakeups WHERE due_at<=clock_timestamp() AND (lease_until IS NULL OR lease_until<clock_timestamp()) ORDER BY due_at,job_id FOR UPDATE SKIP LOCKED LIMIT 1) RETURNING job_id,workspace_id,user_id")
        .fetch_optional(&state.pool).await?;
    let Some(wakeup) = wakeup else {
        return Ok(false);
    };
    let job: Uuid = wakeup.try_get("job_id")?;
    let workspace: Uuid = wakeup.try_get("workspace_id")?;
    let user: Uuid = wakeup.try_get("user_id")?;
    let mut lookup = db::scoped_transaction(&state.pool, workspace, user).await?;
    let identity=sqlx::query("SELECT d.session_id,m.role FROM push_deliveries j JOIN push_devices d ON d.id=j.device_id JOIN memberships m ON m.workspace_id=d.workspace_id AND m.user_id=d.user_id WHERE j.id=$1")
        .bind(job).fetch_optional(&mut *lookup).await?;
    lookup.commit().await?;
    let Some(identity) = identity else {
        remove_wakeup(state, job).await?;
        return Ok(true);
    };
    let auth = AuthContext {
        assistant: false,
        workspace_id: workspace,
        user_id: user,
        session_id: identity.try_get("session_id")?,
        role: identity.try_get("role")?,
    };
    let mut tx = match auth.begin_authorized(&state.pool).await {
        Ok(tx) => tx,
        Err(error) if error.status == axum::http::StatusCode::UNAUTHORIZED => {
            cancel_job(state, &auth, job).await?;
            return Ok(true);
        }
        Err(error) => return Err(error),
    };
    let Some(item) = load_item(state, &mut tx, job, &auth, service).await? else {
        cancel_in_transaction(&mut tx, job).await?;
        tx.commit().await?;
        return Ok(true);
    };
    if item.status != "pending" {
        // Persisted 'sending' means a prior process could have reached Apple.
        // A restart never repeats an uncertain user-visible notification.
        sqlx::query("UPDATE push_deliveries SET status='uncertain',updated_at=clock_timestamp() WHERE id=$1 AND status='sending'").bind(job).execute(&mut *tx).await?;
        sqlx::query("DELETE FROM push_delivery_wakeups WHERE job_id=$1")
            .bind(job)
            .execute(&mut *tx)
            .await?;
        tx.commit().await?;
        return Ok(true);
    }
    let now = Utc::now();
    let Some(due) = item.preference.next_permitted(now, item.expires_at) else {
        cancel_in_transaction(&mut tx, job).await?;
        tx.commit().await?;
        return Ok(true);
    };
    if due > now {
        sqlx::query("UPDATE push_delivery_wakeups SET due_at=$2,lease_until=NULL WHERE job_id=$1")
            .bind(job)
            .bind(due)
            .execute(&mut *tx)
            .await?;
        tx.commit().await?;
        return Ok(true);
    }
    sqlx::query(
        "UPDATE push_deliveries SET status='sending',updated_at=clock_timestamp() WHERE id=$1",
    )
    .bind(job)
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;

    // Commit the claim before sending, then revalidate and hold identity,
    // latest token binding, consent, account and message locks through APNs.
    let mut tx = match auth.begin_authorized(&state.pool).await {
        Ok(tx) => tx,
        Err(error) if error.status == axum::http::StatusCode::UNAUTHORIZED => {
            cancel_job(state, &auth, job).await?;
            return Ok(true);
        }
        Err(error) => return Err(error),
    };
    let Some(item) = load_item(state, &mut tx, job, &auth, service).await? else {
        cancel_in_transaction(&mut tx, job).await?;
        tx.commit().await?;
        return Ok(true);
    };
    if item.status != "sending" || !item.preference.permits(Utc::now()) {
        cancel_in_transaction(&mut tx, job).await?;
        tx.commit().await?;
        return Ok(true);
    }
    let bytes = state
        .crypto
        .open(workspace, item.device_id, &item.encrypted_token)?;
    let token = Zeroizing::new(
        String::from_utf8(bytes.to_vec()).map_err(|_| AppError::internal("invalid_push_token"))?,
    );
    let payload = payload(state, &auth, &item);
    let result = transport
        .send(PushRequest {
            id: job,
            token,
            environment: item.environment.clone(),
            expires_at: item
                .preference
                .delivery_expiration(Utc::now(), item.expires_at),
            payload,
            kind: crate::PushKind::Alert,
        })
        .await;
    let status = match result {
        DeliveryResult::Accepted => "accepted",
        DeliveryResult::Rejected | DeliveryResult::InvalidToken(_) => "rejected",
        DeliveryResult::Uncertain => "uncertain",
    };
    sqlx::query("UPDATE push_deliveries SET status=$2,updated_at=clock_timestamp() WHERE id=$1 AND status='sending'").bind(job).bind(status).execute(&mut *tx).await?;
    if let DeliveryResult::InvalidToken(timestamp) = result {
        if timestamp.is_none_or(|value| value >= item.registered_at.timestamp_millis()) {
            sqlx::query(
                "UPDATE push_devices SET enabled=false,disabled_at=clock_timestamp() WHERE id=$1",
            )
            .bind(item.device_id)
            .execute(&mut *tx)
            .await?;
        }
    }
    sqlx::query("DELETE FROM push_delivery_wakeups WHERE job_id=$1")
        .bind(job)
        .execute(&mut *tx)
        .await?;
    tx.commit().await?;
    Ok(true)
}

struct Item {
    status: String,
    device_id: Uuid,
    message_id: Uuid,
    account_id: Uuid,
    environment: String,
    encrypted_token: Vec<u8>,
    registered_at: DateTime<Utc>,
    expires_at: DateTime<Utc>,
    preference: AccountPreference,
    message: Value,
}

async fn load_item(
    state: &AppState,
    tx: &mut Transaction<'_, Postgres>,
    job: Uuid,
    auth: &AuthContext,
    service: &PushService,
) -> Result<Option<Item>, AppError> {
    // Read opaque token key first, then lock the global latest binding before
    // device rows. Registration follows the same order.
    let key=sqlx::query("SELECT d.token_hash,d.environment,d.id,j.account_id FROM push_deliveries j JOIN push_devices d ON d.id=j.device_id WHERE j.id=$1")
        .bind(job).fetch_optional(&mut **tx).await?;
    let Some(key) = key else {
        return Ok(None);
    };
    let account: Uuid = key.try_get("account_id")?;
    // Provider sync writes message rows before updating the account. Acquire
    // its operation/cache locks before either row to preserve that ordering.
    postmere_mail::mail_sync::account_operation_lock(tx, auth.workspace_id, auth.user_id, account)
        .await?;
    postmere_mail::mail_sync::cache_write_lock(tx, auth.workspace_id, auth.user_id, account)
        .await?;
    let device: Uuid = key.try_get("id")?;
    let hash: Vec<u8> = key.try_get("token_hash")?;
    let environment: String = key.try_get("environment")?;
    let binding:Option<Uuid>=sqlx::query_scalar("SELECT device_id FROM push_token_bindings WHERE token_hash=$1 AND environment=$2 FOR SHARE")
        .bind(&hash).bind(&environment).fetch_optional(&mut **tx).await?;
    if binding != Some(device) || service.environment.as_deref() != Some(environment.as_str()) {
        return Ok(None);
    }
    let row=sqlx::query("SELECT j.status,j.device_id,j.message_id,j.account_id,least(j.expires_at,s.expires_at,s.absolute_expires_at) expires_at,d.encrypted_token,d.registered_at,p.settings,p.encrypted_sender_policy,m.normalized FROM push_deliveries j JOIN push_devices d ON d.id=j.device_id JOIN push_preferences p ON p.device_id=d.id AND p.account_id=j.account_id JOIN provider_accounts a ON a.id=j.account_id JOIN mail_messages m ON m.id=j.message_id JOIN sessions s ON s.id=d.session_id WHERE j.id=$1 AND d.session_id=$2 AND d.token_hash=$3 AND d.environment=$4 AND d.enabled AND d.disabled_at IS NULL AND p.enabled AND a.disabled_at IS NULL AND a.status='connected' AND m.deleted_at IS NULL AND m.normalized->>'mailbox'='inbox' AND m.normalized->>'is_read'='false' AND lower(m.normalized->'from'->>'email')<>lower(a.email) AND m.sent_at>=greatest(d.first_registered_at,p.enabled_since,a.push_connected_at) AND least(j.expires_at,s.expires_at,s.absolute_expires_at)>clock_timestamp() FOR SHARE OF d,p,a,m FOR UPDATE OF j")
        .bind(job).bind(auth.session_id).bind(hash).bind(&environment).fetch_optional(&mut **tx).await?;
    let Some(row) = row else {
        return Ok(None);
    };
    // LEAST ignores NULL session deadlines for persistent logins, preserving
    // the message's finite TTL. A lock wait can still cross that TTL or a
    // finite session's expiry; neither can authorize a late alert.
    let expires_at: DateTime<Utc> = row.try_get("expires_at")?;
    if expires_at <= Utc::now() {
        return Ok(None);
    }
    let mut preference: AccountPreference = serde_json::from_value(row.try_get("settings")?)
        .map_err(|_| AppError::internal("invalid_push_preferences"))?;
    let message: Value = row.try_get("normalized")?;
    let encrypted_policy: Option<Vec<u8>> = row.try_get("encrypted_sender_policy")?;
    if let Some(encrypted) = encrypted_policy {
        let resource = crate::sender_policy::policy_resource_id(auth.user_id, device, account);
        let bytes = state.crypto.open(auth.workspace_id, resource, &encrypted)?;
        preference.sender_policy = Some(
            serde_json::from_slice(&bytes)
                .map_err(|_| AppError::internal("invalid_push_sender_policy"))?,
        );
    }
    preference.validate()?;
    if preference.sender_policy.as_ref().is_some_and(|policy| {
        !policy.allows(
            message
                .get("from")
                .and_then(|from| from.get("email"))
                .and_then(Value::as_str)
                .unwrap_or(""),
        )
    }) {
        return Ok(None);
    }
    Ok(Some(Item {
        status: row.try_get("status")?,
        device_id: row.try_get("device_id")?,
        message_id: row.try_get("message_id")?,
        account_id: row.try_get("account_id")?,
        environment,
        encrypted_token: row.try_get("encrypted_token")?,
        registered_at: row.try_get("registered_at")?,
        expires_at,
        preference,
        message,
    }))
}

fn payload(state: &AppState, auth: &AuthContext, item: &Item) -> Value {
    let subject = if item.preference.show_subject {
        item.message
            .get("subject")
            .and_then(Value::as_str)
            .unwrap_or("New message")
            .chars()
            .filter(|c| !c.is_control())
            .take(180)
            .collect::<String>()
    } else {
        "Open Postmere to view the message.".into()
    };
    // A hashed, account-scoped thread key avoids leaking provider identifiers.
    use sha2::{Digest, Sha256};
    let thread = Sha256::digest(
        format!(
            "{}:{}:{}:{}",
            auth.workspace_id,
            auth.user_id,
            item.account_id,
            item.message
                .get("provider_thread_id")
                .and_then(Value::as_str)
                .unwrap_or("")
        )
        .as_bytes(),
    );
    let thread = thread
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>();
    json!({"aps":{"alert":{"title":"New message","body":subject},"sound":"default","thread-id":thread,
        // Reply, Archive and Mark as Read on the notification; see MailNotificationAction.
        "category":"postmere.message","filter-criteria":item.preference.filter_criteria},
        "postmere_push":1,"server_origin":state.config.public_base_url.origin().ascii_serialization(),
        "workspace_id":auth.workspace_id,"user_id":auth.user_id,"account_id":item.account_id,
        "message_id":item.message_id,"filter_criteria":item.preference.filter_criteria})
}

async fn cancel_in_transaction(
    tx: &mut Transaction<'_, Postgres>,
    job: Uuid,
) -> Result<(), AppError> {
    sqlx::query("UPDATE push_deliveries SET status='cancelled',updated_at=clock_timestamp() WHERE id=$1 AND status IN ('pending','sending')").bind(job).execute(&mut **tx).await?;
    sqlx::query("DELETE FROM push_delivery_wakeups WHERE job_id=$1")
        .bind(job)
        .execute(&mut **tx)
        .await?;
    Ok(())
}
async fn cancel_job(state: &AppState, auth: &AuthContext, job: Uuid) -> Result<(), AppError> {
    let mut tx = auth.begin(&state.pool).await?;
    cancel_in_transaction(&mut tx, job).await?;
    tx.commit().await?;
    Ok(())
}
async fn remove_wakeup(state: &AppState, job: Uuid) -> Result<(), AppError> {
    sqlx::query("DELETE FROM push_delivery_wakeups WHERE job_id=$1")
        .bind(job)
        .execute(&state.pool)
        .await?;
    Ok(())
}
